#!/usr/bin/env bash
# Generate, recompile, build and run the synthetic repro ROMs in tests/repro/
# (no Nintendo data inside), and check how each run ends. irqleak1-3 reproduce
# the IRQ call-return leak that patches/gbarecomp/0003 fixes; overlay1, two
# code images sharing IWRAM, which 0006's RAM overlay selector handles
# (tests/repro/README.md). Needs no game ROM and, by default, no BIOS dump, so
# CI runs it.
#
#   scripts/repro-test.sh [--bios PATH] [--frames N] [--without NAME]...
#                         [--expect-failure] [CASE...]
#
#   --bios PATH        run on a 16 KiB GBA BIOS dump, recompiled with
#                      gbarecomp's BIOS config as for the game, instead of the
#                      stand-in BIOS that tests/repro/make_bios.py generates
#   --frames N         frames per run (default 2000)
#   --without NAME     A/B build: leave gbarecomp patch NAME (0003, 0006) out,
#                      and build under build/without-NAME/repro/
#                      (patches/gbarecomp/README.md). The overlay cases read
#                      their results through patch 0005's capture: without
#                      0005 they are skipped, or refused if named
#   --expect-failure   require every run to end the way its bug makes it end
#                      without the patch that fixes it, which --without must
#                      leave out. irqleak1-3, without 0003: SIGABRT (exit code
#                      134) with "generated call-return stack overflow" at the
#                      case's leaked return address. overlay1, without 0006:
#                      exit 0 under GBARECOMP_STRICT_STATIC=1, with image A's
#                      result logged for image B; overlay1heal, the same with
#                      healing on. Without CASE, runs the default cases whose
#                      patch is left out
#   CASE               irqleak1, irqleak2, irqleak3, overlay1 (the default:
#                      these four), or overlay1heal, which runs only when
#                      named (below)
#
# An irqleak run passes when it exits 0 after at least N frames, bridged F
# (0x08000200, so the leak path ran), interprets at most 10 instructions per
# frame (the fixed runs interpret 0 to 2; the leak makes the interpreter run
# the main loop), and prints none of the runtime's overflow, runaway-bridge or
# IRQ-watchdog messages. irqleak1 and irqleak2 must also print no
# "runtime_irq: dropped" line (the first part of 0003 leaves nothing to drop);
# irqleak3 must print at least one (only the second part covers its leak).
#
# overlay1 runs twice under GBARECOMP_STRICT_STATIC=1, with gbarecomp's
# capture (patch 0005) recording the program's log in EWRAM at every VBlank.
# With the selector, the run must exit 0 after at least N frames, fully
# static, with 0xA1 logged after image A and 0xB2 after image B in every
# record once a cycle has completed, and at least N/2 cycles. The second run,
# overlay1-noselector (MRA_REPRO_OVERLAY_SELECTOR=0), is the control: as on a
# gbarecomp without the patch, the same strict run must log 0xA1 after B,
# image A's code run for image B with no dispatch miss.
#
# overlay1heal (opt-in, not in the default list, not run in CI) tests 0006's
# heal-tier guard: overlay1's ROM with no corpus for either image, run with
# RAM healing on (GBARECOMP_SELFHEAL_RECOMPILE=1, GBARECOMP_RAM_OVERLAY_HEAL=1,
# the gcc backend: it needs a C++ compiler at run time, `c++` on PATH or
# GBARECOMP_HEAL_CXX). Image A's first dispatch heals 0x03000000 from A's
# bytes, and the selector claims image B without a corpus. The run must exit
# 0 after at least N frames, heal A, and log 0xA1 then 0xB2 like overlay1: B
# bridged, never run through A's heal. Its control, overlay1heal-noselector,
# must heal A too and log 0xA1 after B: a PC nobody claims gets A's heal.
#
# Runs are headless, with SDL_AUDIODRIVER=dummy and runtime healing off
# (except overlay1heal's), each in build/repro/run/RUN/, where its output is
# out.log.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

ALL_CASES="irqleak1 irqleak2 irqleak3 overlay1"
FRAMES=2000
EXPECT=pass
CASES_ARG=""
BIOS_DUMP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bios) [ $# -ge 2 ] || die "--bios needs a path"; BIOS_DUMP=$2; shift ;;
    --bios=*) BIOS_DUMP=${1#*=} ;;
    --frames) [ $# -ge 2 ] || die "--frames needs a number"; FRAMES=$2; shift ;;
    --frames=*) FRAMES=${1#*=} ;;
    --without) [ $# -ge 2 ] || die "--without needs a patch name or number"; add_without "$2"; shift ;;
    --without=*) add_without "${1#*=}" ;;
    --expect-failure) EXPECT=failure ;;
    -h | --help) sed -n '2,63p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) CASES_ARG="$CASES_ARG${CASES_ARG:+ }$1" ;;
  esac
  shift
done
case "$FRAMES" in
  '' | *[!0-9]*) die "--frames needs a positive number, not '$FRAMES'" ;;
esac
[ "$FRAMES" -gt 0 ] || die "--frames needs a positive number"
select_patch_variant

# case_patch CASE: the number of the gbarecomp patch that fixes CASE's bug.
case_patch() {
  case "$1" in
    irqleak*) echo 0003 ;;
    overlay1 | overlay1heal) echo 0006 ;;
  esac
}
# The numbers of the patches this build leaves out, separated by spaces.
left_out=" "
for name in $(without_patch_names); do left_out="$left_out${name%%-*} "; done

# Validate the cases, and run each one once even if it is named twice (two
# entries for one case would give CMake two targets with the same name).
# --expect-failure runs only cases whose patch is left out. Named cases must
# all be testable; the default list keeps those that are.
CASES=""
for c in ${CASES_ARG:-$ALL_CASES}; do
  case "$c" in
    irqleak1 | irqleak2 | irqleak3 | overlay1 | overlay1heal) ;;
    *) die "unknown case: $c (irqleak1, irqleak2, irqleak3, overlay1 or overlay1heal)" ;;
  esac
  if [ "$EXPECT" = failure ]; then
    p=$(case_patch "$c")
    case "$left_out" in
      *" $p "*) ;;
      *)
        [ -z "$CASES_ARG" ] && continue
        die "$c reproduces the bug that patch $p fixes: --expect-failure needs --without $p"
        ;;
    esac
  fi
  # The overlay cases read the program's log through patch 0005's capture.
  case "$c:$left_out" in
    overlay*:*" 0005 "*)
      if [ -z "$CASES_ARG" ]; then
        info "Skipping $c: it reads its results through patch 0005's capture, which --without 0005 leaves out"
        continue
      fi
      die "$c reads its results through patch 0005's capture: it cannot run --without 0005"
      ;;
  esac
  case " $CASES " in
    *" $c "*) ;;
    *) CASES="$CASES${CASES:+ }$c" ;;
  esac
done
[ -n "$CASES" ] ||
  die "no case to run: --expect-failure needs --without 0003 (irqleak1-3) or --without 0006 (overlay1, which also needs 0005)"
case "$BIOS_DUMP" in
  "" | /*) ;;
  *) BIOS_DUMP="$PWD/$BIOS_DUMP" ;;
esac
lock_checkout

REPRO_SRC="$MRA_ROOT/tests/repro"
REPRO_DIR="$MRA_BUILD_DIR/repro"
LOGS="$REPRO_DIR/logs"
# The fixed runs interpret one instruction per IRQ (irqleak1), two per frame
# (irqleak2) or none (irqleak3); see tests/repro/README.md.
MAX_INTERPRETED_PER_FRAME=10
# F, the function with no static entry that every irqleak IRQ handler reaches.
F_PC=0x08000200
# overlay1's log in EWRAM (tests/repro/make_rom.py, OVERLAY1): the result
# after image A, the result after image B, completed cycles.
OVERLAY_MEM="0x02000000:4;0x02000004:4;0x02000008:4"
# Wall-clock limit per run, in seconds. A fixed run takes about a second.
RUN_TIMEOUT=300
# Size limit for every file a run writes, its log included, in 1 KiB blocks
# (ulimit -f): 256 MiB.
RUN_FILE_LIMIT_KB=262144
generator=()
if command -v ninja > /dev/null 2>&1; then generator=(-G Ninja); fi

command -v python3 > /dev/null 2>&1 || die "python3 is required"
command -v perl > /dev/null 2>&1 || die "perl is required (it enforces the run time limit)"
# Before anything reads gbarecomp's files (its BIOS config, for --bios).
require_submodule

# leaked_return_pc CASE: the return address whose call-return frames leak in
# CASE, which the overflow message names on the gbarecomp pin.
leaked_return_pc() {
  case "$1" in
    irqleak1 | irqleak3) echo 0x08000188 ;;
    irqleak2) echo 0x08000194 ;;
  esac
}

# describe_exit RC: an exit code, with the cause when the run was killed by
# one of the limits above.
describe_exit() {
  case "$1" in
    142) echo "exit code 142 (SIGALRM: timed out after ${RUN_TIMEOUT} s)" ;;
    153) echo "exit code 153 (SIGXFSZ: a file it wrote hit the $((RUN_FILE_LIMIT_KB / 1024)) MiB limit)" ;;
    *) echo "exit code $1" ;;
  esac
}

# The BIOS image to recompile and to load at run time, and its config.
mkdir -p "$LOGS" "$REPRO_DIR/roms"
if [ -n "$BIOS_DUMP" ]; then
  bios=$BIOS_DUMP
  bios_config=$MRA_BIOS_CONFIG
  [ -f "$bios" ] || die "BIOS not found: $(rel "$bios")"
  [ "$(file_size "$bios")" = "$GBA_BIOS_SIZE" ] ||
    die "$(rel "$bios") is $(file_size "$bios") bytes; a GBA BIOS is exactly $GBA_BIOS_SIZE bytes"
  bios_kind="BIOS dump"
else
  bios="$REPRO_DIR/roms/repro-bios.bin"
  bios_config="$REPRO_SRC/bios.toml"
  python3 -I "$REPRO_SRC/make_bios.py" "$bios" > /dev/null
  bios_kind="stand-in BIOS"
fi
[ -f "$bios_config" ] || die "BIOS config not found: $(rel "$bios_config")"
bios_sha1=$(sha1_of "$bios")
want=$(toml_get "$bios_config" identity sha1 | tr 'A-F' 'a-f')
[ "$bios_sha1" = "$want" ] ||
  die "$(rel "$bios") has SHA-1 $bios_sha1, but $(rel "$bios_config") expects $want"
info "$bios_kind $(rel "$bios")  sha1=$bios_sha1"

build_tools

info "Recompiling the BIOS -> $(rel "$REPRO_DIR/generated/bios")"
reset_dir "$REPRO_DIR/generated/bios"
"$MRA_TOOLS_BUILD_DIR/gba_recompile" --bios "$bios" --config "$bios_config" \
  --out "$REPRO_DIR/generated/bios" > "$LOGS/recompile-bios.log" 2>&1 ||
  die "BIOS recompile failed; see $(rel "$LOGS/recompile-bios.log")"

cases_arg=""
for c in $CASES; do
  rom="$REPRO_DIR/roms/$c.gba"
  python3 -I "$REPRO_SRC/make_rom.py" "$c" "$rom" > /dev/null
  sha1=$(sha1_of "$rom")
  want=$(toml_get "$REPRO_SRC/$c.toml" identity sha1 | tr 'A-F' 'a-f')
  [ "$sha1" = "$want" ] ||
    die "$c: make_rom.py wrote SHA-1 $sha1, but $(rel "$REPRO_SRC/$c.toml") expects $want"
  info "ROM  $(rel "$rom")  sha1=$sha1"
  recompile_rom "$rom" "$REPRO_SRC/$c.toml" "$REPRO_DIR/generated/$c" "$LOGS/recompile-$c.log"
  # Clear corpora of this case left by an earlier version of its configs.
  for dir in "$REPRO_DIR/generated/$c".*; do
    if [ -d "$dir" ]; then reset_dir "$dir" && rmdir "$dir"; fi
  done
  # Further corpora of the same ROM: tests/repro/<case>.<prefix>.toml, each
  # compiled with --output-prefix <prefix>_ into generated/<case>.<prefix>/,
  # which tests/repro/CMakeLists.txt links in too. No symbol map: each map
  # registers itself as the cartridge's one.
  for extra in "$REPRO_SRC/$c".*.toml; do
    [ -f "$extra" ] || continue
    prefix=${extra##*/"$c".}
    prefix=${prefix%.toml}
    case "$prefix" in
      '' | *[!a-z0-9]*) die "$(rel "$extra"): the prefix must be lower-case letters and digits" ;;
    esac
    want=$(toml_get "$extra" identity sha1 | tr 'A-F' 'a-f')
    [ "$sha1" = "$want" ] || die "$(rel "$extra") expects ROM SHA-1 $want, not $sha1"
    recompile_rom "$rom" "$extra" "$REPRO_DIR/generated/$c.$prefix" \
      "$LOGS/recompile-$c.$prefix.log" --output-prefix "${prefix}_" --no-symbol-map
  done
  cases_arg="$cases_arg${cases_arg:+;}$c=$sha1"
done

info "Building the repro executables -> $(rel "$REPRO_DIR/native")"
run_logged "$LOGS/configure.log" \
  cmake -S "$REPRO_SRC" -B "$REPRO_DIR/native" ${generator[@]+"${generator[@]}"} \
  -DCMAKE_BUILD_TYPE=Release -DMRA_REPRO_CASES="$cases_arg" \
  -DMRA_REPRO_GENERATED_ROOT="$REPRO_DIR/generated" \
  -DGBARECOMP_GENERATED_BIOS_DIR="$REPRO_DIR/generated/bios"
grep -q "BIOS recompiled output present" "$LOGS/configure.log" ||
  die "gbarecomp did not pick up the recompiled BIOS; see $(rel "$LOGS/configure.log")"
run_logged "$LOGS/build.log" cmake --build "$REPRO_DIR/native" --parallel "$(job_count)"

# count PATTERN FILE: the number of lines of FILE that match PATTERN (ERE).
count() { grep -cE "$1" "$2" || true; }

# run_case RUN CASE [VAR=VALUE...]: run repro_CASE for FRAMES frames in
# build/repro/run/RUN/, with these variables added to its environment. Sets
# run_dir, log and rc.
run_case() {
  local name=$1 c=$2 exe
  shift 2
  exe="$REPRO_DIR/native/repro_$c"
  [ -x "$exe" ] || die "not built: $(rel "$exe")"
  run_dir="$REPRO_DIR/run/$name"
  reset_dir "$run_dir"
  log="$run_dir/out.log"
  info "Running $name for $FRAMES frames${1:+ ($*)}"
  rc=0
  # The runtime writes its coverage and miss reports into the working
  # directory. ulimit -f caps every file it writes, the log included.
  # --bios-sha1 tells the runtime which image to expect, so a stand-in BIOS
  # loads without a warning.
  (
    cd "$run_dir" || exit 1
    ulimit -f "$RUN_FILE_LIMIT_KB"
    export SDL_AUDIODRIVER=dummy GBARECOMP_SELFHEAL_RECOMPILE=0
    for assignment in "$@"; do export "${assignment?}"; done
    exec perl -e 'alarm shift; exec @ARGV; exit 127' "$RUN_TIMEOUT" \
      "$exe" --bios "$bios" --bios-sha1 "$bios_sha1" --rom "$REPRO_DIR/roms/$c.gba" \
      --bios-skip-intro --frames "$FRAMES" --no-window --save-path "$run_dir/$c.sav" \
      "$REPRO_SRC/$c.toml"
  ) > "$log" 2>&1 || rc=$?
}

# report_failure RUN PROBLEMS: record a failed run and show its log's end.
failed=""
report_failure() {
  warn "$1:$2 see $(rel "$log")"
  tail -n 20 "$log" | sed 's/^/    /' >&2
  failed="$failed $1"
}

# check_irqleak CASE: run an irqleak case and check how it ended.
check_irqleak() {
  local c=$1 leaked frames interpreted bridged_f overflow overflow_here runaway watchdog dropped problems=""
  run_case "$c" "$c"
  leaked=$(leaked_return_pc "$c")
  frames=$(sed -nE 's/.*ppu_frames=([0-9]+).*/\1/p' "$log" | tail -n 1)
  interpreted=$(sed -nE 's/.*self_heal_coverage=[A-Z_]+ dispatch_misses=[0-9]+ interpreted_insns=([0-9]+).*/\1/p' "$log" | tail -n 1)
  bridged_f=$(count "^ +bridged $F_PC " "$log")
  overflow=$(count 'generated call-return stack overflow' "$log")
  overflow_here=$(count "generated call-return stack overflow at return_pc=$leaked\$" "$log")
  runaway=$(count 'SELF-HEAL bridge for .* exceeded' "$log")
  watchdog=$(count 'did not iret' "$log")
  dropped=$(count 'runtime_irq: dropped' "$log")
  printf '  exit=%s frames=%s interpreted_insns=%s bridged_F=%s overflow=%s runaway_bridge=%s irq_watchdog=%s irq_dropped_frames=%s\n' \
    "$rc" "${frames:-?}" "${interpreted:-?}" "$bridged_f" "$overflow" "$runaway" "$watchdog" "$dropped"

  if [ "$EXPECT" = failure ]; then
    [ "$rc" = 134 ] || problems="$problems $(describe_exit "$rc"), not 134;"
    [ "$overflow_here" -gt 0 ] ||
      problems="$problems no call-return stack overflow at return_pc=$leaked;"
  else
    [ "$rc" = 0 ] || problems="$problems $(describe_exit "$rc");"
    if [ -z "$frames" ] || [ "$frames" -lt "$FRAMES" ]; then
      problems="$problems stopped at frame ${frames:-?};"
    fi
    if [ -z "$interpreted" ]; then
      problems="$problems no coverage banner;"
    elif [ "$interpreted" -gt $((MAX_INTERPRETED_PER_FRAME * FRAMES)) ]; then
      problems="$problems $interpreted interpreted instructions;"
    fi
    # Without this the run could pass without the leak path ever running,
    # for example if F got a static entry.
    [ "$bridged_f" -gt 0 ] || problems="$problems F ($F_PC) was never bridged;"
    [ "$overflow" = 0 ] || problems="$problems call-return stack overflow;"
    [ "$runaway" = 0 ] || problems="$problems runaway bridge;"
    [ "$watchdog" = 0 ] || problems="$problems IRQ watchdog;"
    # runtime_irq() drops frames a handler leaves behind (0003, second part).
    if [ "$c" = irqleak3 ]; then
      [ "$dropped" -gt 0 ] ||
        problems="$problems no 'runtime_irq: dropped' line (the second part of 0003 never ran);"
    else
      [ "$dropped" = 0 ] ||
        problems="$problems call-return frames left at IRQ exit (the first part of 0003 should leave none);"
    fi
  fi
  [ -z "$problems" ] || report_failure "$c" "$problems"
}

# check_overlay RUN CASE SELECTOR AFTER_B [VAR=VALUE...]: run CASE (overlay1
# or overlay1heal) as RUN with the capture on, and require that its hooks
# report selector=SELECTOR (on, off or unavailable), that it ran at least
# FRAMES frames, and that every capture record once a cycle has completed
# logs 0xA1 after image A and AFTER_B after image B. overlay1 runs under
# GBARECOMP_STRICT_STATIC=1 and must be fully static. overlay1heal runs with
# RAM healing on and must heal image A at 0x03000000, so that the heal tier
# has A's heal to run when image B is dispatched.
check_overlay() {
  local name=$1 c=$2 selector=$3 after_b=$4 frames coverage capture problems=""
  local after_a_seen="?" after_b_seen="?" cycles="?" mixed=0 healed=0 heal_failed=0 heal_info
  shift 4
  # A relative path in these variables is relative to the run directory.
  if [ "$c" = overlay1heal ]; then
    # A heal cache of its own, in the run directory, which run_case empties:
    # no heal from an earlier run is loaded. Verbose for the HEALED line.
    run_case "$name" "$c" GBARECOMP_SELFHEAL_RECOMPILE=1 GBARECOMP_RAM_OVERLAY_HEAL=1 \
      GBARECOMP_HEAL_BACKEND=gcc GBARECOMP_HEAL_CACHE=heal-cache GBARECOMP_SELFHEAL_VERBOSE=1 \
      GBARECOMP_CAPTURE=capture.tsv GBARECOMP_CAPTURE_MEM="$OVERLAY_MEM" \
      GBARECOMP_CAPTURE_LINE_STATE=0 "$@"
    # Not anchored: these go to stderr, the rest of the log to buffered
    # stdout, so a line may start in the middle of another.
    healed=$(count 'self_heal: HEALED RAM 0x03000000 \(arm\)' "$log")
    heal_failed=$(count 'self_heal: sync compile FAILED' "$log")
  else
    run_case "$name" "$c" GBARECOMP_STRICT_STATIC=1 \
      GBARECOMP_CAPTURE=capture.tsv GBARECOMP_CAPTURE_MEM="$OVERLAY_MEM" \
      GBARECOMP_CAPTURE_LINE_STATE=0 "$@"
  fi
  capture="$run_dir/capture.tsv"
  frames=$(sed -nE 's/.*ppu_frames=([0-9]+).*/\1/p' "$log" | tail -n 1)
  coverage=$(sed -nE 's/.*(self_heal_coverage=[A-Z_]+ dispatch_misses=[0-9]+ interpreted_insns=[0-9]+( healed_native=[0-9]+ native_calls=[0-9]+)?).*/\1/p' "$log" | tail -n 1)
  if [ -s "$capture" ]; then
    # The last record's log, and whether any record after the first
    # completed cycle logs anything else.
    read -r after_a_seen after_b_seen cycles mixed <<< "$(awk -F '\t' '
      NR == 1 {
        for (i = 1; i <= NF; i++) {
          if ($i == "mem_02000000") a = i
          if ($i == "mem_02000004") b = i
          if ($i == "mem_02000008") n = i
        }
        if (!a || !b || !n) { print "? ? ? 0"; exit }
        next
      }
      {
        if ($n != "00000000") {
          if (!seen) { fa = $a; fb = $b; seen = 1 }
          else if ($a != fa || $b != fb) mixed = 1
        }
        la = $a; lb = $b; ln = $n
      }
      END { if (a) print (la == "" ? "?" : la), (lb == "" ? "?" : lb), (ln == "" ? "?" : ln), mixed + 0 }
    ' "$capture" 2> /dev/null || echo "? ? ? 0")"
    case "$cycles" in
      [0-9A-F]*) cycles=$((16#$cycles)) ;;
    esac
  fi
  heal_info=""
  if [ "$c" = overlay1heal ]; then heal_info=" healed_A=$healed"; fi
  printf '  exit=%s frames=%s %s selector=%s%s after_A=%s after_B=%s cycles=%s\n' \
    "$rc" "${frames:-?}" "${coverage:-no coverage banner}" \
    "$(sed -nE "s/^$c: selector=([a-z]+).*/\\1/p" "$log" | head -n 1)" \
    "$heal_info" "$after_a_seen" "$after_b_seen" "$cycles"

  [ "$rc" = 0 ] || problems="$problems $(describe_exit "$rc");"
  grep -q "^$c: selector=$selector" "$log" ||
    problems="$problems the hooks did not report selector=$selector;"
  if [ -z "$frames" ] || [ "$frames" -lt "$FRAMES" ]; then
    problems="$problems stopped at frame ${frames:-?};"
  fi
  if [ "$c" = overlay1heal ]; then
    [ "$heal_failed" = 0 ] ||
      problems="$problems the heal compile failed (it needs a C++ compiler: c++ on PATH, or GBARECOMP_HEAL_CXX);"
    [ "$healed" -gt 0 ] ||
      problems="$problems image A was never healed at 0x03000000, so the heal tier had nothing to run for B;"
  else
    grep -q '^strict_static=ENABLED' "$log" || problems="$problems not run strict-static;"
    case "$coverage" in
      'self_heal_coverage=FULLY_STATIC dispatch_misses=0 interpreted_insns=0') ;;
      *) problems="$problems not fully static (${coverage:-no coverage banner});" ;;
    esac
  fi
  if [ ! -s "$capture" ]; then
    # Without a capture, the log checks below would only repeat this.
    problems="$problems no capture file (the overlay cases read their log through patch 0005's capture);"
  else
    [ "$after_a_seen" = 000000A1 ] || problems="$problems logged $after_a_seen after image A, not 000000A1;"
    [ "$after_b_seen" = "$after_b" ] || problems="$problems logged $after_b_seen after image B, not $after_b;"
    [ "$mixed" = 0 ] || problems="$problems the log changed between cycles;"
    case "$cycles" in
      '' | *[!0-9]*) problems="$problems no cycle count in the capture;" ;;
      *) [ "$cycles" -ge $((FRAMES / 2)) ] || problems="$problems only $cycles cycles;" ;;
    esac
  fi
  [ -z "$problems" ] || report_failure "$name" "$problems"
}

for c in $CASES; do
  case "$c" in
    irqleak*) check_irqleak "$c" ;;
    overlay1 | overlay1heal)
      if [ "$EXPECT" = failure ]; then
        # Without patch 0006 there is no selector: image A's body (overlay1)
        # or heal (overlay1heal) runs for B.
        check_overlay "$c" "$c" unavailable 000000A1
      else
        check_overlay "$c" "$c" on 000000B2
        # The control: the same build with the selector left uninstalled.
        check_overlay "$c-noselector" "$c" off 000000A1 MRA_REPRO_OVERLAY_SELECTOR=0
      fi
      ;;
  esac
done

[ -z "$failed" ] || die "repro test failed (expected: $EXPECT):$failed"
if [ "$EXPECT" = failure ]; then
  info "Every case failed the way its bug makes it fail, as expected"
else
  info "Repro test passed"
fi

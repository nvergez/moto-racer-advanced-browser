#!/usr/bin/env bash
# Generate, recompile, build and run the synthetic repro ROMs in tests/repro/
# (no Nintendo data inside), and check how each run ends. They reproduce the
# IRQ call-return leak that patches/gbarecomp/0003 fixes (tests/repro/README.md).
# Needs no game ROM and, by default, no BIOS dump, so CI runs it.
#
#   scripts/repro-test.sh [--bios PATH] [--frames N] [--without NAME]...
#                         [--expect-failure] [CASE...]
#
#   --bios PATH        run on a 16 KiB GBA BIOS dump, recompiled with
#                      gbarecomp's BIOS config as for the game, instead of the
#                      stand-in BIOS that tests/repro/make_bios.py generates
#   --frames N         frames per run (default 2000)
#   --without NAME     A/B build: leave gbarecomp patch NAME (0003) out, and
#                      build under build/without-NAME/repro/
#                      (patches/gbarecomp/README.md)
#   --expect-failure   require every run to end the way the leak makes it end
#                      on the gbarecomp pin: SIGABRT (exit code 134) with
#                      "generated call-return stack overflow" at the case's
#                      leaked return address. For --without 0003
#   CASE               irqleak1, irqleak2 and/or irqleak3 (default all three)
#
# A run passes when it exits 0 after at least N frames, bridged F (0x08000200,
# so the leak path ran), interprets at most 10 instructions per frame (the
# fixed runs interpret 0 to 2; the leak makes the interpreter run the main
# loop), and prints none of the runtime's overflow, runaway-bridge or
# IRQ-watchdog messages. irqleak1 and irqleak2 must also print no
# "runtime_irq: dropped" line (the first part of 0003 leaves nothing to drop);
# irqleak3 must print at least one (only the second part covers its leak).
# Runs are headless, with SDL_AUDIODRIVER=dummy and runtime healing off, each
# in build/repro/run/CASE/, where its output is out.log.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

ALL_CASES="irqleak1 irqleak2 irqleak3"
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
    -h | --help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) CASES_ARG="$CASES_ARG${CASES_ARG:+ }$1" ;;
  esac
  shift
done
case "$FRAMES" in
  '' | *[!0-9]*) die "--frames needs a positive number, not '$FRAMES'" ;;
esac
[ "$FRAMES" -gt 0 ] || die "--frames needs a positive number"
# Validate the cases, and run each one once even if it is named twice (two
# entries for one case would give CMake two targets with the same name).
CASES=""
for c in ${CASES_ARG:-$ALL_CASES}; do
  case "$c" in
    irqleak1 | irqleak2 | irqleak3) ;;
    *) die "unknown case: $c (irqleak1, irqleak2 or irqleak3)" ;;
  esac
  case " $CASES " in
    *" $c "*) ;;
    *) CASES="$CASES${CASES:+ }$c" ;;
  esac
done
case "$BIOS_DUMP" in
  "" | /*) ;;
  *) BIOS_DUMP="$PWD/$BIOS_DUMP" ;;
esac
select_patch_variant
lock_checkout

REPRO_SRC="$MRA_ROOT/tests/repro"
REPRO_DIR="$MRA_BUILD_DIR/repro"
LOGS="$REPRO_DIR/logs"
# The fixed runs interpret one instruction per IRQ (irqleak1), two per frame
# (irqleak2) or none (irqleak3); see tests/repro/README.md.
MAX_INTERPRETED_PER_FRAME=10
# F, the function with no static entry that every case's IRQ handler reaches.
F_PC=0x08000200
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

failed=""
for c in $CASES; do
  exe="$REPRO_DIR/native/repro_$c"
  [ -x "$exe" ] || die "not built: $(rel "$exe")"
  run_dir="$REPRO_DIR/run/$c"
  reset_dir "$run_dir"
  log="$run_dir/out.log"
  info "Running $c for $FRAMES frames"
  rc=0
  # The runtime writes its coverage and miss reports into the working
  # directory. ulimit -f caps every file it writes, the log included.
  # --bios-sha1 tells the runtime which image to expect, so a stand-in BIOS
  # loads without a warning.
  (
    cd "$run_dir" || exit 1
    ulimit -f "$RUN_FILE_LIMIT_KB"
    export SDL_AUDIODRIVER=dummy GBARECOMP_SELFHEAL_RECOMPILE=0
    exec perl -e 'alarm shift; exec @ARGV; exit 127' "$RUN_TIMEOUT" \
      "$exe" --bios "$bios" --bios-sha1 "$bios_sha1" --rom "$REPRO_DIR/roms/$c.gba" \
      --bios-skip-intro --frames "$FRAMES" --no-window --save-path "$run_dir/$c.sav" \
      "$REPRO_SRC/$c.toml"
  ) > "$log" 2>&1 || rc=$?

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

  problems=""
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
  if [ -n "$problems" ]; then
    warn "$c:$problems see $(rel "$log")"
    tail -n 20 "$log" | sed 's/^/    /' >&2
    failed="$failed $c"
  fi
done

[ -z "$failed" ] || die "repro test failed (expected: $EXPECT):$failed"
if [ "$EXPECT" = failure ]; then
  info "Every case failed the way the leak makes it fail, as expected"
else
  info "Repro test passed"
fi

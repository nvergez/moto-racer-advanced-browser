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
#                      "generated call-return stack overflow". For
#                      --without 0003
#   CASE               irqleak1 and/or irqleak2 (default both)
#
# A run passes when it exits 0 after at least N frames, prints none of the
# runtime's leak, runaway-bridge or IRQ-watchdog messages, and interprets at
# most 10 instructions per frame (the fixed runs interpret 1 or 2; the leak
# makes the interpreter run the main loop). Runs are headless, with
# SDL_AUDIODRIVER=dummy and runtime healing off, each in
# build/repro/run/CASE/, where its output is out.log.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

FRAMES=2000
EXPECT=pass
CASES=""
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
    -h | --help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) CASES="$CASES${CASES:+ }$1" ;;
  esac
  shift
done
case "$FRAMES" in
  '' | *[!0-9]*) die "--frames needs a positive number, not '$FRAMES'" ;;
esac
[ "$FRAMES" -gt 0 ] || die "--frames needs a positive number"
CASES=${CASES:-irqleak1 irqleak2}
for c in $CASES; do
  case "$c" in
    irqleak1 | irqleak2) ;;
    *) die "unknown case: $c (irqleak1 or irqleak2)" ;;
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
# The fixed runs interpret one instruction per IRQ (irqleak1) or two per
# frame (irqleak2); see tests/repro/README.md.
MAX_INTERPRETED_PER_FRAME=10
# Wall-clock limit per run, in seconds. A fixed run takes about a second.
RUN_TIMEOUT=300
generator=()
if command -v ninja > /dev/null 2>&1; then generator=(-G Ninja); fi

command -v python3 > /dev/null 2>&1 || die "python3 is required"
command -v perl > /dev/null 2>&1 || die "perl is required (it enforces the run time limit)"

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
  # directory. ulimit -f caps every file it writes, the log included, at
  # 256 MiB (bash counts in 1 KiB blocks). --bios-sha1 tells the runtime
  # which image to expect, so a stand-in BIOS loads without a warning.
  (
    cd "$run_dir" || exit 1
    ulimit -f 262144
    export SDL_AUDIODRIVER=dummy GBARECOMP_SELFHEAL_RECOMPILE=0
    exec perl -e 'alarm shift; exec @ARGV; exit 127' "$RUN_TIMEOUT" \
      "$exe" --bios "$bios" --bios-sha1 "$bios_sha1" --rom "$REPRO_DIR/roms/$c.gba" \
      --bios-skip-intro --frames "$FRAMES" --no-window --save-path "$run_dir/$c.sav" \
      "$REPRO_SRC/$c.toml"
  ) > "$log" 2>&1 || rc=$?

  frames=$(sed -nE 's/.*ppu_frames=([0-9]+).*/\1/p' "$log" | tail -n 1)
  interpreted=$(sed -nE 's/.*self_heal_coverage=[A-Z_]+ dispatch_misses=[0-9]+ interpreted_insns=([0-9]+).*/\1/p' "$log" | tail -n 1)
  overflow=$(count 'generated call-return stack overflow' "$log")
  runaway=$(count 'SELF-HEAL bridge for .* exceeded' "$log")
  watchdog=$(count 'did not iret' "$log")
  dropped=$(count 'runtime_irq: dropped' "$log")
  printf '  exit=%s frames=%s interpreted_insns=%s overflow=%s runaway_bridge=%s irq_watchdog=%s irq_dropped_frames=%s\n' \
    "$rc" "${frames:-?}" "${interpreted:-?}" "$overflow" "$runaway" "$watchdog" "$dropped"

  problems=""
  if [ "$EXPECT" = failure ]; then
    [ "$rc" = 134 ] || problems="$problems exit code $rc, not 134;"
    [ "$overflow" -gt 0 ] || problems="$problems no call-return stack overflow;"
  else
    [ "$rc" = 0 ] || problems="$problems exit code $rc;"
    if [ -z "$frames" ] || [ "$frames" -lt "$FRAMES" ]; then
      problems="$problems stopped at frame ${frames:-?};"
    fi
    if [ -z "$interpreted" ]; then
      problems="$problems no coverage banner;"
    elif [ "$interpreted" -gt $((MAX_INTERPRETED_PER_FRAME * FRAMES)) ]; then
      problems="$problems $interpreted interpreted instructions;"
    fi
    [ "$overflow" = 0 ] || problems="$problems call-return stack overflow;"
    [ "$runaway" = 0 ] || problems="$problems runaway bridge;"
    [ "$watchdog" = 0 ] || problems="$problems IRQ watchdog;"
    # runtime_irq() drops frames a handler leaves behind (0003, second
    # part); the first part must leave none for it to drop.
    [ "$dropped" = 0 ] || problems="$problems call-return frames left at IRQ exit;"
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

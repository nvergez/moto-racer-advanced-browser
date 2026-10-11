#!/usr/bin/env bash
# End-to-end smoke test of the recompile pipeline on freely licensed test ROMs
# (jsmolka/gba-tests, MIT). Needs no game ROM and no BIOS.
#
#   scripts/smoke-test.sh [--native-only | --web-only] [--without NAME]...
#
# 1. Fetch the test ROMs (scripts/fetch-test-roms.sh).
# 2. Recompile each with gba_recompile and its tests/smoke/*.toml config,
#    exactly as scripts/regen.sh recompiles the game.
# 3. Native: build each ROM's generated code into gbarecomp's test ROM runner
#    and run it (direct boot, no BIOS; pass = every test in the ROM passed).
#    Then build our own host executable (CMakeLists.txt, src/main.cpp) with
#    the arm.gba code in place of the game's, to check the wiring and the link.
# 4. Web (needs Emscripten): the same runners compiled to WebAssembly and run
#    under Node; gbarecomp's browser host linked with each ROM's code; and
#    web/game-lib built with emcc, as scripts/build-web.sh will use it.
#
# Not covered, because it needs a BIOS: booting through the BIOS, the
# recompiled BIOS, and running the browser bundle in a page.
#
# --without NAME leaves gbarecomp patch NAME (0003) out and builds under
# build/without-NAME/smoke (an A/B build, patches/gbarecomp/README.md).
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

NATIVE=1
WEB=1
while [ $# -gt 0 ]; do
  case "$1" in
    --native-only) WEB=0 ;;
    --web-only) NATIVE=0 ;;
    --without) [ $# -ge 2 ] || die "--without needs a patch name or number"; add_without "$2"; shift ;;
    --without=*) add_without "${1#*=}" ;;
    -h | --help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
select_patch_variant
lock_checkout

SMOKE_DIR="$MRA_BUILD_DIR/smoke"
GEN_ROOT="$SMOKE_DIR/generated"
LOGS="$SMOKE_DIR/logs"
ROMS="$MRA_ROOT/test-roms/gba-tests"
CASES="arm thumb"
generator=()
if command -v ninja > /dev/null 2>&1; then generator=(-G Ninja); fi

"$MRA_ROOT/scripts/fetch-test-roms.sh" --no-link
build_tools

cases_arg=""
for c in $CASES; do
  recompile_rom "$ROMS/$c/$c.gba" "$MRA_ROOT/tests/smoke/gba-tests-$c.toml" \
    "$GEN_ROOT/$c" "$LOGS/recompile-$c.log"
  cases_arg="$cases_arg${cases_arg:+;}$c=$ROMS/$c/$c.gba"
done

if [ "$NATIVE" = 1 ]; then
  info "Native: test ROM runners"
  run_logged "$LOGS/native-configure.log" \
    cmake -S "$MRA_ROOT/tests/smoke" -B "$SMOKE_DIR/native" ${generator[@]+"${generator[@]}"} \
    -DCMAKE_BUILD_TYPE=Release -DMRA_SMOKE_CASES="$cases_arg" \
    -DMRA_SMOKE_GENERATED_ROOT="$GEN_ROOT"
  run_logged "$LOGS/native-build.log" \
    cmake --build "$SMOKE_DIR/native" --parallel "$(job_count)"
  ctest --test-dir "$SMOKE_DIR/native" --output-on-failure -R "^smoke_"

  info "Native: our host executable (CMakeLists.txt, src/main.cpp) with the arm.gba code"
  run_logged "$LOGS/native-host-configure.log" \
    cmake -S "$MRA_ROOT" -B "$SMOKE_DIR/native-host" ${generator[@]+"${generator[@]}"} \
    -DCMAKE_BUILD_TYPE=Release \
    -DMRA_GAME_CONFIG="$MRA_ROOT/tests/smoke/gba-tests-arm.toml" \
    -DMRA_GENERATED_DIR="$GEN_ROOT/arm" \
    -DGBARECOMP_GENERATED_BIOS_DIR="$SMOKE_DIR/no-bios" \
    -DMRA_ALLOW_BIOS_PLACEHOLDER=ON
  run_logged "$LOGS/native-host-build.log" \
    cmake --build "$SMOKE_DIR/native-host" --target MotoRacerAdvanceRecomp \
    --parallel "$(job_count)"
  host="$SMOKE_DIR/native-host/MotoRacerAdvanceRecomp"
  [ -x "$host" ] || die "host executable missing"
  info "Built $(rel "$host")"
  # It cannot boot without a BIOS. Check that it starts, parses its arguments
  # and stops at exactly that point. --state-dir is what the browser page
  # always passes; without patches/gbarecomp/0001 the parser rejects it.
  if out=$("$host" --no-window --frames 1 --rom "$ROMS/arm/arm.gba" \
    --state-dir "$SMOKE_DIR/states" 2>&1); then
    die "the host ran without a BIOS, which gbarecomp should refuse: $out"
  fi
  case "$out" in
    *"BIOS resolution failed"*) info "Host starts and stops at the missing BIOS, as expected" ;;
    *) die "unexpected host output: $out" ;;
  esac
fi

if [ "$WEB" = 1 ]; then
  require_emscripten
  # ctest runs the .js runners with the Node that emcmake records as
  # CMAKE_CROSSCOMPILING_EMULATOR (emsdk ships its own).
  info "Web: test ROM runners under Node, and the browser host link"
  run_logged "$LOGS/wasm-configure.log" \
    emcmake cmake -S "$MRA_ROOT/tests/smoke" -B "$SMOKE_DIR/wasm" ${generator[@]+"${generator[@]}"} \
    -DCMAKE_BUILD_TYPE=Release -DGBARECOMP_COMPILER_CACHE=OFF \
    -DCMAKE_C_FLAGS=-pthread -DCMAKE_CXX_FLAGS=-pthread \
    -DMRA_SMOKE_CASES="$cases_arg" -DMRA_SMOKE_GENERATED_ROOT="$GEN_ROOT"
  run_logged "$LOGS/wasm-build.log" \
    cmake --build "$SMOKE_DIR/wasm" --parallel "$(job_count)"
  ctest --test-dir "$SMOKE_DIR/wasm" --output-on-failure -R "^smoke_"
  for c in $CASES; do
    [ -s "$SMOKE_DIR/wasm/web_host_$c.wasm" ] || die "web_host_$c.wasm was not linked"
    info "Linked $(rel "$SMOKE_DIR/wasm/web_host_$c.js") and .wasm"
  done

  info "Web: web/game-lib with emcc"
  run_logged "$LOGS/wasm-game-lib-configure.log" \
    emcmake cmake -S "$MRA_ROOT/web/game-lib" -B "$SMOKE_DIR/wasm-game-lib" \
    ${generator[@]+"${generator[@]}"} -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_FLAGS=-pthread -DMRA_GENERATED_DIR="$GEN_ROOT/arm"
  run_logged "$LOGS/wasm-game-lib-build.log" cmake --build "$SMOKE_DIR/wasm-game-lib"
  [ -s "$SMOKE_DIR/wasm-game-lib/libgbarecomp_game.a" ] || die "libgbarecomp_game.a missing"
  info "Built $(rel "$SMOKE_DIR/wasm-game-lib/libgbarecomp_game.a")"
fi

info "Smoke test passed"

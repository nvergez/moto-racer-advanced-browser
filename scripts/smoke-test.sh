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
#    the arm.gba code in place of the game's, to check the wiring and the link,
#    as a test build with an input replay compiled in, and check how
#    src/main.cpp takes its test variables (MRA_REPLAY, MRA_INTERP_BIOS).
# 4. Web (needs Emscripten): the same runners compiled to WebAssembly and run
#    under Node; gbarecomp's browser host linked with each ROM's code; and
#    web/game-lib built with emcc, as scripts/build-web.sh will use it, with
#    and without an input replay compiled in.
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

# A two-event input replay (A on frames 11-16) as a file and as a routes table
# (tools/replay/script2replay.py; --script needs no route manifest, so no
# Python 3.11).
REPLAYS="$SMOKE_DIR/replays"
mkdir -p "$REPLAYS"
printf 'until 10\ntap A\n' > "$REPLAYS/smoke.txt"
python3 -I "$MRA_ROOT/tools/replay/script2replay.py" "$REPLAYS/smoke.txt" -o "$REPLAYS/smoke.csv"
python3 -I "$MRA_ROOT/tools/replay/script2replay.py" --embed "$REPLAYS/replay_routes.cpp" \
  --script "smoke=$REPLAYS/smoke.txt" 2> /dev/null
printf 'mra-keyinput-v1\n20,0x3FE\n10,0x3FF\n' > "$REPLAYS/bad.csv"

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
    -DMRA_ALLOW_BIOS_PLACEHOLDER=ON \
    -DMRA_REPLAY_ROUTES="$REPLAYS/replay_routes.cpp"
  run_logged "$LOGS/native-host-build.log" \
    cmake --build "$SMOKE_DIR/native-host" --target MotoRacerAdvanceRecomp \
    --parallel "$(job_count)"
  host="$SMOKE_DIR/native-host/MotoRacerAdvanceRecomp"
  [ -x "$host" ] || die "host executable missing"
  info "Built $(rel "$host")"
  # It cannot boot without a BIOS. Check that it starts, parses its arguments
  # and stops at exactly that point. --state-dir is what the browser page
  # always passes; without patches/gbarecomp/0001 the parser rejects it.
  # host_run [VAR=VALUE...]: run it so, with only those test variables set;
  # sets $out and $rc. It runs in a directory of its own: from the repository
  # root the runtime would read ./game.toml, whose [bios] path finds the BIOS
  # dump on a machine that has one, and it would remember that BIOS in a
  # bios.cfg next to the executable for later runs.
  mkdir -p "$SMOKE_DIR/host-run"
  host_run() {
    rc=0
    rm -f "$SMOKE_DIR/native-host/bios.cfg" "$SMOKE_DIR/native-host/rom.cfg"
    out=$(cd "$SMOKE_DIR/host-run" && env -u MRA_REPLAY -u MRA_INTERP_BIOS \
      -u GBARECOMP_FORCE_INTERP -u GBARECOMP_INPUT_REPLAY "$@" "$host" --no-window \
      --frames 1 --rom "$ROMS/arm/arm.gba" --state-dir "$SMOKE_DIR/states" 2>&1) || rc=$?
  }
  host_run
  [ "$rc" != 0 ] || die "the host ran without a BIOS, which gbarecomp should refuse: $out"
  case "$out" in
    *"BIOS resolution failed"*) info "Host starts and stops at the missing BIOS, as expected" ;;
    *) die "unexpected host output: $out" ;;
  esac
  case "$out" in
    *mra_* | *"mra: "*) die "the host printed a test hook's line without its variable: $out" ;;
  esac

  # src/main.cpp's test variables (docs/phase2-plan.md, P2-02). Each one that
  # is accepted is reported before gbarecomp starts; a bad one stops the host
  # with exit code 2 and a line that starts with "mra: ".
  # expect_host WHAT CODE TEXT VAR=VALUE...: exit code CODE (any non-zero for
  # "fail") and TEXT in the output.
  expect_host() {
    local what=$1 code=$2 text=$3
    shift 3
    host_run "$@"
    case "$code" in
      fail) [ "$rc" != 0 ] || die "$what: the host exited 0: $out" ;;
      *) [ "$rc" = "$code" ] || die "$what: exit code $rc, expected $code: $out" ;;
    esac
    case "$out" in
      *"$text"*) ;;
      *) die "$what: no '$text' in: $out" ;;
    esac
  }
  expect_host "replay file" fail "mra_replay=$REPLAYS/smoke.csv events=2 frames=11-17" \
    MRA_REPLAY="$REPLAYS/smoke.csv"
  expect_host "embedded replay" fail "mra_replay=embedded:smoke events=2 frames=11-17" \
    MRA_REPLAY=embedded:smoke
  expect_host "unknown embedded route" 2 "no such route; this build embeds smoke" \
    MRA_REPLAY=embedded:nope
  expect_host "bad replay" 2 "bad.csv:3: frame 10 does not come after frame 20" \
    MRA_REPLAY="$REPLAYS/bad.csv"
  expect_host "gbarecomp's replay format" 2 "the first line must be 'mra-keyinput-v1'" \
    MRA_REPLAY="$MRA_ROOT/tests/smoke/gba-tests-arm.toml"
  expect_host "two replays" 2 "MRA_REPLAY and GBARECOMP_INPUT_REPLAY are both set" \
    MRA_REPLAY="$REPLAYS/smoke.csv" GBARECOMP_INPUT_REPLAY="$REPLAYS/smoke.csv"
  expect_host "BIOS reference" fail "mra_interp_bios=ENABLED" \
    MRA_INTERP_BIOS=1 GBARECOMP_FORCE_INTERP=1
  expect_host "BIOS reference without the interpreter" 2 \
    "MRA_INTERP_BIOS needs GBARECOMP_FORCE_INTERP=1" MRA_INTERP_BIOS=1
  info "Host test variables: replay file and embedded route taken, bad values refused"
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

  # Twice: as a normal build (empty routes table), then as a test build with
  # the replay table, which scripts/build-web.sh --replays hands over in
  # MRA_REPLAY_ROUTES. The archive must hold the matching table.
  lib="$SMOKE_DIR/wasm-game-lib/libgbarecomp_game.a"
  for routes in "" "$REPLAYS/replay_routes.cpp"; do
    info "Web: web/game-lib with emcc${routes:+, input replays embedded}"
    run_logged "$LOGS/wasm-game-lib-configure.log" \
      env MRA_REPLAY_ROUTES="$routes" emcmake cmake -S "$MRA_ROOT/web/game-lib" \
      -B "$SMOKE_DIR/wasm-game-lib" ${generator[@]+"${generator[@]}"} -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_CXX_FLAGS=-pthread -DMRA_GENERATED_DIR="$GEN_ROOT/arm"
    run_logged "$LOGS/wasm-game-lib-build.log" cmake --build "$SMOKE_DIR/wasm-game-lib"
    [ -s "$lib" ] || die "libgbarecomp_game.a missing"
    want=replay_routes_none.cpp.o
    other=replay_routes.cpp.o
    [ -z "$routes" ] || { want=replay_routes.cpp.o; other=replay_routes_none.cpp.o; }
    members=$(emar t "$lib")
    printf '%s\n' "$members" | grep -qx "$want" || die "$(rel "$lib") does not hold $want"
    if printf '%s\n' "$members" | grep -qx "$other"; then die "$(rel "$lib") also holds $other"; fi
    info "Built $(rel "$lib") (routes table: $want)"
  done
fi

info "Smoke test passed"

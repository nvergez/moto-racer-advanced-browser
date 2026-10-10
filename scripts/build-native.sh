#!/usr/bin/env bash
# Build the native (macOS/Linux) executable from the ROM and the BIOS dump.
#
#   scripts/build-native.sh [--no-regen] [--lle] [--debug]
#
#   --no-regen  reuse generated/ instead of running scripts/regen.sh first
#   --lle       per-pixel (LLE) scanline renderer instead of gbarecomp's HLE
#               default, into build/native-lle, for frame comparisons
#   --debug     CMake Debug build instead of Release
#
# Output: build/native/MotoRacerAdvanceRecomp (or build/native-lle/...).
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

REGEN=1
SCANLINE=HLE
BUILD_TYPE=Release
for arg in "$@"; do
  case "$arg" in
    --no-regen) REGEN=0 ;;
    --lle) SCANLINE=LLE ;;
    --debug) BUILD_TYPE=Debug ;;
    -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $arg" ;;
  esac
done

if [ "$REGEN" = 1 ]; then
  "$MRA_ROOT/scripts/regen.sh"
else
  verify_inputs
  require_submodule
  ensure_patches
  if [ ! -f "$MRA_GENERATED_DIR/bios/bios_recompiled.cpp" ] ||
     [ ! -f "$MRA_GENERATED_DIR/game/dispatch_table.cpp" ]; then
    die "nothing generated yet; run without --no-regen"
  fi
fi

build_dir="$MRA_BUILD_DIR/native"
[ "$SCANLINE" = LLE ] && build_dir="$MRA_BUILD_DIR/native-lle"
generator=()
if command -v ninja > /dev/null 2>&1; then generator=(-G Ninja); fi

info "Configuring $(rel "$build_dir") ($BUILD_TYPE, scanline $SCANLINE)"
mkdir -p "$MRA_BUILD_DIR"
cmake -S "$MRA_ROOT" -B "$build_dir" ${generator[@]+"${generator[@]}"} \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DGBARECOMP_SCANLINE_IMPLEMENTATION="$SCANLINE" \
  -DMRA_GAME_CONFIG="$MRA_GAME_CONFIG" \
  -DMRA_GENERATED_DIR="$MRA_GENERATED_DIR/game" \
  -DGBARECOMP_GENERATED_BIOS_DIR="$MRA_GENERATED_DIR/bios" \
  > "$build_dir.configure.log" 2>&1 || {
    cat "$build_dir.configure.log" >&2
    die "configure failed"
  }
grep -q "BIOS recompiled output present" "$build_dir.configure.log" ||
  die "gbarecomp did not pick up the recompiled BIOS; see $(rel "$build_dir.configure.log")"

info "Building MotoRacerAdvanceRecomp"
cmake --build "$build_dir" --target MotoRacerAdvanceRecomp --parallel "$(job_count)"

info "Built $(rel "$build_dir")/MotoRacerAdvanceRecomp"
cat << EOF
Headless run of 1800 frames (30 s of game time), healing off, fresh save:
  cd $build_dir && GBARECOMP_SELFHEAL_RECOMPILE=0 ./MotoRacerAdvanceRecomp \\
    --bios $MRA_BIOS --rom $MRA_ROM \\
    --frames 1800 --no-window --save-path $MRA_BUILD_DIR/saves/smoke.sav \\
    $MRA_GAME_CONFIG
EOF

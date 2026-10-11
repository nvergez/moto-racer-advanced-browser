#!/usr/bin/env bash
# Build the native (macOS/Linux) executable from the ROM and the BIOS dump.
#
#   scripts/build-native.sh [--rom PATH] [--bios PATH] [--no-regen] [--lle] [--debug]
#                           [--without NAME]...
#
#   --rom PATH      the ROM (default roms/moto-racer-advance.gba)
#   --bios PATH     the 16 KiB GBA BIOS dump (default bios/gba_bios.bin)
#   --no-regen      reuse generated/ instead of running scripts/regen.sh first
#   --lle           per-pixel (LLE) scanline renderer instead of gbarecomp's HLE
#                   default, into build/native-lle, for frame comparisons
#   --debug         CMake Debug build instead of Release
#   --without NAME  A/B build: leave gbarecomp patch NAME (0003) out, and put
#                   everything, generated code included, under
#                   build/without-NAME/ (patches/gbarecomp/README.md)
#
# Output: build/native/MotoRacerAdvanceRecomp (or build/native-lle/...).
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

REGEN=1
SCANLINE=HLE
BUILD_TYPE=Release
while [ $# -gt 0 ]; do
  case "$1" in
    --rom | --bios) [ $# -ge 2 ] || die "$1 needs a path"; set_input "$1" "$2"; shift ;;
    --rom=* | --bios=*) set_input "${1%%=*}" "${1#*=}" ;;
    --no-regen) REGEN=0 ;;
    --lle) SCANLINE=LLE ;;
    --debug) BUILD_TYPE=Debug ;;
    --without) [ $# -ge 2 ] || die "--without needs a patch name or number"; add_without "$2"; shift ;;
    --without=*) add_without "${1#*=}" ;;
    -h | --help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
select_patch_variant
lock_checkout

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
# The same command as docs/toolchain.md, "Native build", with absolute paths,
# quoted for the shell.
q() { printf '%q' "$1"; }
save="$MRA_BUILD_DIR/saves/smoke.sav"
cat << EOF
Headless run to the title screen (2700 frames), runtime healing off, fresh
save, last frame kept as a PNG under build/ (it shows the game: never commit it):
  rm -f $(q "$save")
  cd $(q "$build_dir") && GBARECOMP_SELFHEAL_RECOMPILE=0 ./MotoRacerAdvanceRecomp \\
    --bios $(q "$MRA_BIOS") --rom $(q "$MRA_ROM") \\
    --frames 2700 --no-window --save-path $(q "$save") \\
    --dump-png frame-2700.png $(q "$MRA_GAME_CONFIG")
Then read the coverage banner it prints (docs/toolchain.md, "First real-ROM smoke test").
EOF

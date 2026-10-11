#!/usr/bin/env bash
# Build the browser bundle with gbarecomp's packaging/web/build_web.sh.
#
#   scripts/build-web.sh [--rom PATH] [--bios PATH] [--no-regen]
#                        [--embed-private-rom] [--dev] [--without NAME]...
#
#   --rom PATH           the ROM (default roms/moto-racer-advance.gba)
#   --bios PATH          the 16 KiB GBA BIOS dump (default bios/gba_bios.bin)
#   --no-regen           reuse generated/ instead of running scripts/regen.sh
#   --embed-private-rom  copy the ROM and the BIOS into the bundle (local
#                        testing only; the page then needs no file picker)
#   --dev                let a page served from localhost take ?args=/?env=
#   --without NAME       A/B build: leave gbarecomp patch NAME (0003) out, into
#                        build/without-NAME/ (patches/gbarecomp/README.md)
#
# Output: build/web-PRIVATE/. Serve it with scripts/serve-web.sh.
#
# DO NOT PUBLISH the output. Even without --embed-private-rom, game.wasm is
# compiled from the recompiled ROM and the recompiled Nintendo BIOS. Whether
# and how anything is ever published is the owner's decision
# (docs/research/gbarecomp-integration.md, section 5.6, in PR #2).
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

REGEN=1
PASS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --rom | --bios) [ $# -ge 2 ] || die "$1 needs a path"; set_input "$1" "$2"; shift ;;
    --rom=* | --bios=*) set_input "${1%%=*}" "${1#*=}" ;;
    --no-regen) REGEN=0 ;;
    --embed-private-rom | --dev) PASS+=("$1") ;;
    --without) [ $# -ge 2 ] || die "--without needs a patch name or number"; add_without "$2"; shift ;;
    --without=*) add_without "${1#*=}" ;;
    -h | --help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
select_patch_variant
lock_checkout

# Fail on missing inputs before spending time on anything else.
verify_inputs
require_emscripten
require_submodule
ensure_patches

if [ "$REGEN" = 1 ]; then
  "$MRA_ROOT/scripts/regen.sh"
elif [ ! -f "$MRA_GENERATED_DIR/bios/bios_recompiled.cpp" ] ||
     [ ! -f "$MRA_GENERATED_DIR/game/dispatch_table.cpp" ]; then
  die "nothing generated yet; run without --no-regen"
fi

out="$MRA_BUILD_DIR/web-PRIVATE"
info "Building the browser bundle -> $(rel "$out")"
# The three directories keep every build product under build/, out of the
# submodule (build_web.sh defaults to <gbarecomp>/build-web-host) and out of
# web/game-lib.
# MRA_GAME_GENERATED_DIR tells web/game-lib which generated code to compile.
GBARECOMP_WEB_BUILD_DIR="$MRA_BUILD_DIR/web/runtime" \
GBARECOMP_WEB_GAME_BUILD_DIR="$MRA_BUILD_DIR/web/game" \
GBARECOMP_WEB_OUT_DIR="$out" \
MRA_GAME_GENERATED_DIR="$MRA_GENERATED_DIR/game" \
  bash "$GBARECOMP_DIR/packaging/web/build_web.sh" ${PASS[@]+"${PASS[@]}"} \
  "$MRA_ROOT/web/game-lib" "$MRA_GENERATED_DIR/bios" \
  "$MRA_ROM" "$MRA_BIOS" "$MRA_GAME_CONFIG"

cat > "$out/DO-NOT-PUBLISH.txt" << 'EOF'
Local build of the Moto Racer Advance browser port.

game.wasm in this directory is compiled from the recompiled game ROM and the
recompiled GBA BIOS, so this bundle contains copyrighted code even when it
holds no ROM or BIOS file. Do not upload, deploy, share or commit it.
EOF
info "Done. Serve it locally with scripts/serve-web.sh"

#!/usr/bin/env bash
# Build the browser bundle with gbarecomp's packaging/web/build_web.sh.
#
#   scripts/build-web.sh [--no-regen] [--embed-private-rom] [--dev]
#
#   --no-regen           reuse generated/ instead of running scripts/regen.sh
#   --embed-private-rom  copy the ROM and the BIOS into the bundle (local
#                        testing only; the page then needs no file picker)
#   --dev                let a page served from localhost take ?args=/?env=
#
# Output: build/web-PRIVATE/. Serve it with scripts/serve-web.sh.
#
# DO NOT PUBLISH the output. Even without --embed-private-rom, game.wasm is
# compiled from the recompiled ROM and the recompiled Nintendo BIOS. Whether
# and how anything is ever published is the owner's decision
# (docs/research/gbarecomp-integration.md, section 5.6).
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

REGEN=1
PASS=()
for arg in "$@"; do
  case "$arg" in
    --no-regen) REGEN=0 ;;
    --embed-private-rom | --dev) PASS+=("$arg") ;;
    -h | --help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $arg" ;;
  esac
done

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

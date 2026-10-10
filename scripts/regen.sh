#!/usr/bin/env bash
# Regenerate the recompiled C++ from the BIOS dump and the ROM. This is the
# only generation step: the native and the web builds compile the same output.
#
#   scripts/regen.sh [--rom PATH] [--bios PATH]
#
# Needs the ROM (default roms/moto-racer-advance.gba), the BIOS dump (default
# bios/gba_bios.bin) and game.toml (see scripts/lib/common.sh for the
# environment overrides).
# Writes generated/bios and generated/game (both gitignored: they are
# translations of copyrighted code) and logs to build/logs/.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --rom | --bios) [ $# -ge 2 ] || die "$1 needs a path"; set_input "$1" "$2"; shift ;;
    --rom=* | --bios=*) set_input "${1%%=*}" "${1#*=}" ;;
    -h | --help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

verify_inputs
build_tools
mkdir -p "$MRA_LOG_DIR"
recompile="$MRA_TOOLS_BUILD_DIR/gba_recompile"

info "Recompiling the BIOS -> $(rel "$MRA_GENERATED_DIR/bios")"
reset_dir "$MRA_GENERATED_DIR/bios"
"$recompile" --bios "$MRA_BIOS" --config "$MRA_BIOS_CONFIG" \
  --out "$MRA_GENERATED_DIR/bios" > "$MRA_LOG_DIR/recompile-bios.log" 2>&1 ||
  die "BIOS recompile failed; see $(rel "$MRA_LOG_DIR/recompile-bios.log")"

recompile_rom "$MRA_ROM" "$MRA_GAME_CONFIG" "$MRA_GENERATED_DIR/game" \
  "$MRA_LOG_DIR/recompile.log"

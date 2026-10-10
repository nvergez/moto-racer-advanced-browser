#!/usr/bin/env bash
# Run gbaharness on the ROM and BIOS after checking their SHA-1s.
#
# Usage: run_harness.sh [--rom FILE] [--bios FILE] [--no-hash-check] --out DIR [gbaharness options...]
#   --rom FILE       default: $MRA_ROM (roms/moto-racer-advance.gba)
#   --bios FILE      default: $MRA_BIOS (bios/gba_bios.bin)
#   --no-hash-check  allow a ROM or BIOS whose SHA-1 differs from the pinned ones
#   --out DIR        relative paths resolve under $MRA_OUT (analysis-out/, gitignored);
#                    so do relative --wav and --save paths
# Environment: HARNESS_BIN (default: $MRA_OUT/bin/gbaharness, see build.sh).
# Every other option goes to gbaharness unchanged; see ../README.md or run
# "$HARNESS_BIN --help".
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib.sh"
BIN="${HARNESS_BIN:-$MRA_OUT/bin/gbaharness}"
ROM="$MRA_ROM"
BIOS="$MRA_BIOS"
CHECK=1
OUT=""
args=()
# out_file OPTION PATH: resolve an output file and create its directory.
out_file() {
  local p
  p="$(mra_out_path "$2")"
  mkdir -p "$(dirname "$p")"
  args+=("$1" "$p")
}
while [ $# -gt 0 ]; do
  case "$1" in
    --rom) ROM="$2"; shift 2 ;;
    --rom=*) ROM="${1#*=}"; shift ;;
    --bios) BIOS="$2"; shift 2 ;;
    --bios=*) BIOS="${1#*=}"; shift ;;
    --no-hash-check) CHECK=0; shift ;;
    --out) OUT="$(mra_out_path "$2")"; shift 2 ;;
    --out=*) OUT="$(mra_out_path "${1#*=}")"; shift ;;
    --wav|--save) out_file "$1" "$2"; shift 2 ;;
    --wav=*|--save=*) out_file "${1%%=*}" "${1#*=}"; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
[ -n "$OUT" ] || mra_die "--out DIR is required"
[ -x "$BIN" ] || mra_die "harness not built: run $HERE/build.sh (or set HARNESS_BIN)"
if [ "$CHECK" = 1 ]; then
  mra_check_sha1 "$ROM" "$MRA_ROM_SHA1" ROM
  mra_check_sha1 "$BIOS" "$MRA_BIOS_SHA1" BIOS
fi
mkdir -p "$OUT"
exec "$BIN" --rom "$ROM" --bios "$BIOS" --out "$OUT" ${args[@]+"${args[@]}"}

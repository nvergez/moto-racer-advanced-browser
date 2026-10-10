#!/usr/bin/env bash
# Build the Ghidra project from scratch:
#   1. import the ROM as a raw ARMv4T little-endian binary at 0x08000000
#   2. GbaSetup.java: memory map, I/O register labels, header labels, ARM entry
#   3. MapRomCopy.java: byte-map RAM ranges onto the ROM bytes copied there
#      (copies verified with the harness, see docs/research/phase1-findings.md):
#        IWRAM 0x03000000+0x7D84 <- ROM 0x083F6820  race program IWRAM image
#        overlay IWRAM_BOOT 0x03000000+0x834 <- ROM 0x081596FC  front-end IWRAM image
#        EWRAM 0x02000000+0xBFC <- ROM 0x08158B00  front-end .data initial values
#      These addresses are for the pinned ROM (SHA-1 b91bad8e...) only.
#   4. full auto-analysis
#   5. SeedFromHarness.java: disassemble and create functions at dynamically
#      observed call targets and executed addresses, per game state
#   6. AnalysisSummary.java
#
# Usage: ghidra_import.sh [--rom FILE] [--bios FILE] [--seed DIR]
#   --rom FILE   default: $MRA_ROM (roms/moto-racer-advance.gba)
#   --bios FILE  default: $MRA_BIOS; only used to make missing seed data
#   --seed DIR   harness seed data (default: $MRA_OUT/seed; made by make_seed_data.sh if missing)
# Writes the project to $MRA_GHIDRA_PROJECT_DIR (default: analysis-out/ghidra).
# Refuses to overwrite an existing project. To rebuild, build into a new
# MRA_GHIDRA_PROJECT_DIR and swap directories, so concurrent readers never see
# a half-written project.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SEED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rom) export MRA_ROM="$2"; shift 2 ;;
    --bios) export MRA_BIOS="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    *) sed -n '2,25p' "$0" >&2; exit 2 ;;
  esac
done
unset MRA_GHIDRA_PROGRAM
source "$HERE/ghidra_env.sh"
SEED="$(mra_out_path "${SEED:-seed}")"
PROJ="$MRA_GHIDRA_PROJECT_DIR"
mra_check_sha1 "$MRA_ROM" "$MRA_ROM_SHA1" ROM
if [ -e "$PROJ/$MRA_GHIDRA_PROJECT.gpr" ]; then
  mra_die "project exists: $PROJ/$MRA_GHIDRA_PROJECT.gpr"
fi
[ -f "$SEED/race/calls.tsv" ] || "$HERE/make_seed_data.sh" "$SEED"
mkdir -p "$PROJ"
basename "$MRA_ROM" > "$PROJ/program-name.txt"
"$ANALYZE_HEADLESS" "$PROJ" "$MRA_GHIDRA_PROJECT" \
  -import "$MRA_ROM" \
  -loader BinaryLoader -loader-baseAddr 0x08000000 -loader-blockName ROM \
  -processor ARM:LE:32:v4t -cspec default \
  -scriptPath "$MRA_GHIDRA_SCRIPTS" \
  -preScript GbaSetup.java \
  -preScript MapRomCopy.java dst=0x03000000 src=0x083F6820 len=0x7D84 name=IWRAM_IMAGE \
  -preScript MapRomCopy.java dst=0x03000000 src=0x081596FC len=0x834 name=IWRAM_BOOT overlay=true \
  -preScript MapRomCopy.java dst=0x02000000 src=0x08158B00 len=0xBFC name=EWRAM_DATA \
  -postScript SeedFromHarness.java calls="$SEED/all/calls.tsv" coverage="$SEED/all/coverage.tsv" range=0x08000000-0x09FFFFFF fix=true out="$PROJ/seed-rom.txt" \
  -postScript SeedFromHarness.java calls="$SEED/race/calls.tsv" coverage="$SEED/race/coverage.tsv" range=0x03000000-0x03007D83 out="$PROJ/seed-iwram.txt" \
  -postScript SeedFromHarness.java calls="$SEED/menu/calls.tsv" coverage="$SEED/menu/coverage.tsv" range=0x03000000-0x03000833 space=IWRAM_BOOT out="$PROJ/seed-iwram-boot.txt" \
  -postScript AnalysisSummary.java out="$PROJ/summary.txt" \
  -log "$PROJ/import.log" -scriptlog "$PROJ/import-script.log"
cat "$PROJ"/seed-*.txt "$PROJ/summary.txt"

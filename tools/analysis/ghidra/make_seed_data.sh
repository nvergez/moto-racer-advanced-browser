#!/usr/bin/env bash
# Produce the dynamic seed data used by ghidra_import.sh (coverage and call
# targets), split by game state because IWRAM holds different code per state:
#   all    frames 0-4400 (ROM seeding)
#   menu   frames 300-3289: low IWRAM holds the front-end image (ROM 0x081596FC)
#   race   frames 3290-4400: IWRAM holds the race image (ROM 0x083F6820)
# Frame boundaries were measured with the harness on boot_to_race.txt with a
# fresh save (see docs/research/phase1-findings.md).
#
# Usage: make_seed_data.sh [OUTDIR]   (default: $MRA_OUT/seed; relative paths resolve under $MRA_OUT)
# ROM and BIOS come from $MRA_ROM and $MRA_BIOS (see ../lib.sh).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib.sh"
OUT="$(mra_out_path "${1:-seed}")"
RUN="$HERE/../harness/run_harness.sh"
SCRIPT="$HERE/../input/boot_to_race.txt"
mkdir -p "$OUT"
"$RUN" --out "$OUT/all"  --script "$SCRIPT" --coverage --calls --quiet
"$RUN" --out "$OUT/menu" --script "$SCRIPT" --frames 3289 --coverage --calls --step-frames 300-3289 --quiet
"$RUN" --out "$OUT/race" --script "$SCRIPT" --coverage --calls --step-frames 3290-4400 --quiet
echo "seed data in $OUT/{all,menu,race}/{coverage,calls}.tsv"

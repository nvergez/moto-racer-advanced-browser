#!/usr/bin/env bash
# Open-BIOS A/B in the mGBA harness: run the same input scripts under the
# retail BIOS and the Cult-of-GBA BIOS, from the cartridge entry (--skip-bios)
# and through each BIOS's own boot, and keep only what ab_report.py needs.
# See docs/research/open-bios-ab.md.
#
# Usage: run_ab.sh --cult-bios FILE [--retail-bios FILE] [--out DIR]
#                  [--variants "retail-skip cult-skip retail-boot cult-boot"]
#                  [--routes "boot_to_race full_race_cross ..."]
#                  [--tag NAME --harness-args "ARGS"] [--no-result-shots]
#   --cult-bios FILE   bios.bin from https://github.com/Cult-of-GBA/BIOS at commit
#                      a30e9a96df083628b650724b7d4d7112b4070b98 (MIT). Its SHA-1 is
#                      checked. Never commit it: keep it outside the repository or
#                      in a gitignored path (*bios*.bin and bios/ are ignored).
#   --retail-bios FILE default $MRA_BIOS (the owner's dump, SHA-1 checked)
#   --out DIR          default open-bios-ab (relative paths resolve under $MRA_OUT)
#   --harness-args A   extra gbaharness options for every route run (word-split),
#                      e.g. "--openbus 0xEAFFFFFE"; use with --tag
#   --tag NAME         write to OUT/VARIANT.NAME instead of OUT/VARIANT
#                      (letters, digits, '.', '_' and '-' only)
#   --no-result-shots  skip the results-overlay screenshots (below)
# Environment: HARNESS_BIN, MRA_ROM, MRA_OUT (see ../lib.sh).
#
# Each run writes OUT/VARIANT/ROUTE/{script.txt,summary.json,trace.tsv,swi.tsv,
# swicycles.tsv,biosreads.tsv,pctrace.tsv,stderr.log,shots/,...}, and
# OUT/VARIANT/handoff.tsv. Everything there is derived from the ROM: it stays
# under analysis-out/ and is never committed.
#
# Results overlay: the finishing position is only on screen. For every run
# whose trace has a finished race display (DISPCNT 0x1741), the route is run
# again to F = the last frame of that display - 60 (harness frames; in
# retail-equivalent frames, race-display end - 60 + shift) with
# "--frames F --shot-at F", which writes ROUTE/result/shots/fNNNNNN.png.
# ab_report.py --result-shot-frame ROUTEDIR prints F. The rerun traces frame F
# too, and this script fails at the end if that row differs from the main
# run's (the screenshot would then not show the traced run).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib.sh"
RUN="$HERE/../harness/run_harness.sh"
CULT_SHA1=2e41f9d30ecdf1c4540edf89ac16f49bf327edb7   # Cult-of-GBA/BIOS a30e9a9 bios.bin
RETAIL_HANDOFF_FRAME=271   # first cartridge instruction on a retail boot (harness frame; open-bios-ab.md)
# 0x0201A370-0x0201A37F: lap 1-3 times and best lap in frames while the race
# program runs (found on full_race_cross; see open-bios-ab.md, race results).
LAPS=0x0201A370:4,0x0201A374:4,0x0201A378:4,0x0201A37C:4

CULT=""
RETAIL="$MRA_BIOS"
OUT="open-bios-ab"
VARIANTS="retail-skip cult-skip retail-boot cult-boot"
ROUTES="boot_to_race full_race_cross race_gp_finish race_traffic_finish options_save multiplayer_lobby"
TAG=""
HARGS=""
SHOTS=1
while [ $# -gt 0 ]; do
  case "$1" in
    --no-result-shots) SHOTS=0; shift; continue ;;
    --cult-bios|--retail-bios|--out|--variants|--routes|--tag|--harness-args)
      [ $# -ge 2 ] || mra_die "$1 needs a value" ;;
    *) mra_die "unknown option $1" ;;
  esac
  case "$1" in
    --cult-bios) CULT="$2" ;;
    --retail-bios) RETAIL="$2" ;;
    --out) OUT="$2" ;;
    --variants) VARIANTS="$2" ;;
    --routes) ROUTES="$2" ;;
    --tag) TAG="$2" ;;
    --harness-args) HARGS="$2" ;;
  esac
  shift 2
done

script_for() {
  if [ -f "$HERE/input/$1.txt" ]; then echo "$HERE/input/$1.txt"
  elif [ -f "$HERE/../input/$1.txt" ]; then echo "$HERE/../input/$1.txt"
  else mra_die "no input script for route $1"; fi
}

# Check every argument before anything is deleted: the loop below replaces
# each variant's output directory.
[ -n "$CULT" ] || mra_die "--cult-bios FILE is required"
case "$TAG" in
  *[!A-Za-z0-9._-]*) mra_die "--tag may only contain letters, digits, '.', '_' and '-': $TAG" ;;
esac
[ -n "$VARIANTS" ] || mra_die "--variants is empty"
for v in $VARIANTS; do
  case "$v" in
    retail-skip|cult-skip|retail-boot|cult-boot) ;;
    *) mra_die "unknown variant $v" ;;
  esac
done
[ -n "$ROUTES" ] || mra_die "--routes is empty"
for r in $ROUTES; do
  script_for "$r" > /dev/null
done
mra_check_sha1 "$MRA_ROM" "$MRA_ROM_SHA1" ROM
mra_check_sha1 "$RETAIL" "$MRA_BIOS_SHA1" "retail BIOS"
mra_check_sha1 "$CULT" "$CULT_SHA1" "Cult-of-GBA BIOS"
OUT="$(mra_out_path "$OUT")"
mkdir -p "$OUT"

hargs=()
if [ -n "$HARGS" ]; then
  # shellcheck disable=SC2206
  hargs=($HARGS)
fi
mismatch=0

for v in $VARIANTS; do
  case "$v" in
    retail-skip) bios="$RETAIL"; skip=(--skip-bios) ;;
    cult-skip) bios="$CULT"; skip=(--skip-bios) ;;
    retail-boot) bios="$RETAIL"; skip=() ;;
    cult-boot) bios="$CULT"; skip=() ;;
  esac
  vdir="$OUT/$v${TAG:+.$TAG}"
  rm -rf "$vdir"
  mkdir -p "$vdir/handoff"
  # Handoff probe: the state when the CPU first reaches the cartridge entry, and its frame.
  "$RUN" --no-hash-check --bios "$bios" --out "$vdir/handoff" ${skip[@]+"${skip[@]}"} --frames 600 \
    --dump-at-pc 0x08000000 --trace-swi --quiet 2> "$vdir/handoff/stderr.log" || mra_die "$v: handoff probe failed"
  hdir=""
  for d in "$vdir"/handoff/dumps/f*_pc08000000; do
    if [ -d "$d" ]; then hdir="$d"; break; fi
  done
  [ -n "$hdir" ] || mra_die "$v: the cartridge entry was not reached within 600 frames"
  hframe="$(basename "$hdir" | sed -E 's/^f0*([0-9]+)_v.*/\1/')"
  by=$((hframe - RETAIL_HANDOFF_FRAME))
  printf '%s\thandoff_frame\t%s\tshift\t%s\n' "$v" "$hframe" "$by" | tee "$vdir/handoff.tsv"
  for r in $ROUTES; do
    rdir="$vdir/$r"
    mkdir -p "$rdir"
    src="$(script_for "$r")"
    python3 -I "$HERE/shift_script.py" "$src" "$rdir/script.txt" --by "$by"
    extra=()
    if [ ${#hargs[@]} -gt 0 ]; then extra=("${hargs[@]}"); fi
    case "$r" in
      boot_to_race|full_race_cross|race_gp_finish|race_traffic_finish)
        # Race main loop (race IWRAM image): 0x03001CFC runs once per iteration right
        # after the VCOUNT>=170 busy-wait, 0x03001D6C once at the end of its work.
        extra+=(--trace-pc 0x03001CFC,0x03001D6C) ;;
      options_save)
        rm -f "$rdir/game.sav"
        extra+=(--save "$rdir/game.sav") ;;
    esac
    "$RUN" --no-hash-check --bios "$bios" --out "$rdir" ${skip[@]+"${skip[@]}"} --script "$rdir/script.txt" \
      --trace 0-40000 --trace-ram --trace-mem "$LAPS" \
      --trace-swi --swi-cycles --log-bios-reads --log-level 0x47 --quiet ${extra[@]+"${extra[@]}"} 2> "$rdir/stderr.log" \
      || mra_die "$v/$r failed (see $rdir/stderr.log)"
    echo "$(basename "$vdir")/$r done"
    [ "$SHOTS" = 1 ] || continue
    f="$(python3 -I "$HERE/ab_report.py" --result-shot-frame "$rdir")"
    [ -n "$f" ] || continue
    # Results overlay (see the header): same BIOS, start, script and
    # --harness-args as the run above, checked on frame F's trace row.
    mkdir -p "$rdir/result"
    "$RUN" --no-hash-check --bios "$bios" --out "$rdir/result" ${skip[@]+"${skip[@]}"} --script "$rdir/script.txt" \
      --frames "$f" --shot-at "$f" --trace "$f-$f" --trace-ram --trace-mem "$LAPS" --quiet ${hargs[@]+"${hargs[@]}"} \
      2> "$rdir/result/stderr.log" || mra_die "$v/$r: results-overlay run failed (see $rdir/result/stderr.log)"
    main_row="$(awk -F '\t' -v f="$f" '$1 == f' "$rdir/trace.tsv")"
    shot_row="$(awk -F '\t' -v f="$f" '$1 == f' "$rdir/result/trace.tsv")"
    if [ -n "$main_row" ] && [ "$main_row" = "$shot_row" ]; then
      echo "$(basename "$vdir")/$r results overlay at harness frame $f: $rdir/result/shots"
    else
      echo "$(basename "$vdir")/$r: the results-overlay run differs from the traced run at frame $f" >&2
      mismatch=1
    fi
  done
done
echo "outputs in $OUT; compare with: python3 -I $HERE/ab_report.py $OUT"
[ "$mismatch" = 0 ] || mra_die "a results-overlay run did not match its traced run (see above)"

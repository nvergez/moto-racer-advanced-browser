#!/usr/bin/env bash
# Open-BIOS A/B in the mGBA harness: run the same input scripts under the
# retail BIOS and the Cult-of-GBA BIOS, from the cartridge entry (--skip-bios)
# and through each BIOS's own boot, and keep only what ab_report.py needs.
# See docs/research/open-bios-ab.md.
#
# Usage: run_ab.sh --cult-bios FILE [--retail-bios FILE] [--out DIR]
#                  [--variants "retail-skip cult-skip retail-boot cult-boot"]
#                  [--routes "boot_to_race full_race_cross ... cup"]
#                  [--tag NAME --harness-args "ARGS"] [--no-result-shots]
#   --cult-bios FILE   bios.bin from https://github.com/Cult-of-GBA/BIOS at commit
#                      a30e9a96df083628b650724b7d4d7112b4070b98 (MIT). Its SHA-1 is
#                      checked. Never commit it: keep it outside the repository or
#                      in a gitignored path (*bios*.bin and bios/ are ignored).
#   --retail-bios FILE default $MRA_BIOS (the owner's dump, SHA-1 checked)
#   --out DIR          default open-bios-ab (relative paths resolve under $MRA_OUT)
#   --routes LIST      input scripts by name, from ./input or ../input (default:
#                      the six routes of the doc and the cup)
#   --harness-args A   extra gbaharness options for every route run (word-split),
#                      e.g. "--openbus 0xEAFFFFFE"; use with --tag
#   --tag NAME         write to OUT/VARIANT.NAME instead of OUT/VARIANT
#                      (letters, digits, '.', '_' and '-' only)
#   --no-result-shots  skip the results-overlay screenshots (below)
# Environment: HARNESS_BIN, MRA_ROM, MRA_OUT (see ../lib.sh).
#
# Each run writes OUT/VARIANT/ROUTE/{script.txt,summary.json,trace.tsv,swi.tsv,
# swicycles.tsv,biosreads.tsv,pctrace.tsv,game.sav,stderr.log,shots/,...}, and
# OUT/VARIANT/handoff.tsv. A call replaces the outputs of the variants and
# routes it runs and keeps the other routes' outputs in OUT, so "--routes cup"
# adds the cup to an earlier run of the other routes. Everything there is
# derived from the ROM: it stays under analysis-out/ and is never committed.
#
# Every route is run the same way: traced from its first frame to the frame
# its script ends on (this script fails if trace.tsv stops before
# summary.json's end_frame), with the race main loop's PCs (pctrace.tsv; no
# rows outside races) and from a fresh save, which the harness writes back to
# ROUTE/game.sav at the end.
#
# Results overlay: the finishing position is only on screen. For every run
# with finished races (ab_report.py: a race display, DISPCNT 0x1741, that ends
# before the run does, with lap 1-3 times set), the route is run again up to
# the last of the frames F = the last frame of each finished race display - 60
# (harness frames; in retail-equivalent frames, race-display end - 60 + shift)
# with "--frames F_last --shot-at F_1,...,F_last", which writes
# ROUTE/result/shots/fNNNNNN.png for each race. ab_report.py
# --result-shot-frames ROUTEDIR prints the F list. The rerun traces those
# frames too, and this script fails at the end if any of those rows differs
# from the main run's (the screenshot would then not show the traced run).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib.sh"
RUN="$HERE/../harness/run_harness.sh"
CULT_SHA1=2e41f9d30ecdf1c4540edf89ac16f49bf327edb7   # Cult-of-GBA/BIOS a30e9a9 bios.bin
RETAIL_HANDOFF_FRAME=271   # first cartridge instruction on a retail boot (harness frame; open-bios-ab.md)
# 0x0201A370-0x0201A37F: lap 1-3 times and best lap in frames while the race
# program runs (found on full_race_cross; see open-bios-ab.md, race results).
LAPS=0x0201A370:4,0x0201A374:4,0x0201A378:4,0x0201A37C:4
# Race main loop (race IWRAM image): 0x03001CFC runs once per iteration right
# after the VCOUNT>=170 busy-wait, 0x03001D6C once at the end of its work.
# --swi-cycles already steps every frame, so tracing them costs little.
RACE_LOOP_PCS=0x03001CFC,0x03001D6C
# Trace every frame the run reaches: the run ends where its script does, and
# the check after each run makes sure trace.tsv got there.
TRACE_ALL=0-99999999

CULT=""
RETAIL="$MRA_BIOS"
OUT="open-bios-ab"
VARIANTS="retail-skip cult-skip retail-boot cult-boot"
ROUTES="boot_to_race full_race_cross race_gp_finish race_traffic_finish options_save multiplayer_lobby cup"
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
# each variant's handoff probe and the outputs of the routes it runs.
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
  case "$r" in
    handoff|*[!A-Za-z0-9_]*) mra_die "not a route name: $r" ;;
  esac
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
  rm -rf "$vdir/handoff" "$vdir/handoff.tsv"
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
    rm -rf "$rdir"
    mkdir -p "$rdir"
    src="$(script_for "$r")"
    python3 -I "$HERE/shift_script.py" "$src" "$rdir/script.txt" --by "$by"
    "$RUN" --no-hash-check --bios "$bios" --out "$rdir" ${skip[@]+"${skip[@]}"} --script "$rdir/script.txt" \
      --save "$rdir/game.sav" --trace "$TRACE_ALL" --trace-ram --trace-mem "$LAPS" --trace-pc "$RACE_LOOP_PCS" \
      --trace-swi --swi-cycles --log-bios-reads --log-level 0x47 --quiet ${hargs[@]+"${hargs[@]}"} 2> "$rdir/stderr.log" \
      || mra_die "$v/$r failed (see $rdir/stderr.log)"
    end="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["end_frame"])' "$rdir/summary.json")"
    last="$(awk -F '\t' 'END { print $1 }' "$rdir/trace.tsv")"
    [ "$last" = "$end" ] || mra_die "$v/$r: trace.tsv ends at frame $last, the run at frame $end"
    echo "$(basename "$vdir")/$r done (harness frames 1-$end)"
    [ "$SHOTS" = 1 ] || continue
    frames="$(python3 -I "$HERE/ab_report.py" --result-shot-frames "$rdir")"
    [ -n "$frames" ] || continue
    f_last="${frames##*,}"
    # Results overlay (see the header): same BIOS, start, script, fresh save and
    # --harness-args as the run above, checked on the trace rows of the shot frames.
    mkdir -p "$rdir/result"
    "$RUN" --no-hash-check --bios "$bios" --out "$rdir/result" ${skip[@]+"${skip[@]}"} --script "$rdir/script.txt" \
      --save "$rdir/result/game.sav" --frames "$f_last" --shot-at "$frames" --trace "$frames" --trace-ram \
      --trace-mem "$LAPS" --quiet ${hargs[@]+"${hargs[@]}"} \
      2> "$rdir/result/stderr.log" || mra_die "$v/$r: results-overlay run failed (see $rdir/result/stderr.log)"
    for f in $(echo "$frames" | tr ',' ' '); do
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
done
echo "outputs in $OUT; compare with: python3 -I $HERE/ab_report.py $OUT"
[ "$mismatch" = 0 ] || mra_die "a results-overlay run did not match its traced run (see above)"

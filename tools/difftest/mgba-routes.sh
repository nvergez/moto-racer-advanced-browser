#!/usr/bin/env bash
# Run the manifest's routes in the mGBA harness and check them (P2-04).
#
# Usage: tools/difftest/mgba-routes.sh [--keep] [--manifest FILE] [ROUTE...]
#   ROUTE...    routes to run (default: every route in tools/difftest/routes.toml);
#               a route that starts from another route's save pulls that one in
#   --keep      keep run b's output (by default it is deleted once the route
#               passes; a failing route keeps it)
#
# For each route, two runs (a and b) from boot, each with a fresh copy of the
# route's starting save, then:
#   - determinism: trace.tsv of a and b are byte-identical, and so are their
#     final saves;
#   - the run stops exactly at the route's frame count;
#   - the route's checkpoints hold on run a, on their recorded frames
#     (routes.py check --exact);
#   - the final save matches the manifest: unchanged for sram = "none",
#     changed for "written", and equal to save_sha1 when that is set.
# A route whose starting-save route failed is reported as failed without
# running. Outputs go to $MRA_OUT/routes/<route>-a|b/ and <route>-a|b.sav
# (analysis-out/, gitignored; they are derived from the ROM). Exit status 1 if
# any route fails.
#
# Environment: as tools/analysis/harness/run_harness.sh (MRA_ROM, MRA_BIOS,
# MRA_OUT, HARNESS_BIN). Bash 3.2 compatible, like scripts/lib/common.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/analysis/lib.sh
source "$HERE/../analysis/lib.sh"
RUN_HARNESS="$HERE/../analysis/harness/run_harness.sh"
MANIFEST="$HERE/routes.toml"
KEEP=0
routes=()
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --manifest)
      if [ $# -lt 2 ] || [ -z "$2" ]; then mra_die "--manifest needs a file"; fi
      MANIFEST="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) mra_die "unknown option $1" ;;
    *) routes+=("$1"); shift ;;
  esac
done

rp() { python3 -I "$HERE/routes.py" --manifest "$MANIFEST" "$@"; }
sha1_of() { shasum -a 1 "$1" | cut -d' ' -f1; }

# Fail before the first run when an input is missing: otherwise every run
# fails on its own, with the cause only in its log.
HARNESS="${HARNESS_BIN:-$MRA_OUT/bin/gbaharness}"
[ -x "$HARNESS" ] || mra_die "harness not built: $HARNESS (run tools/analysis/harness/build.sh or set HARNESS_BIN)"
# The manifest's frames hold for the pinned ROM and BIOS only, so there is no
# override here (routes.py validate checks that the manifest has the same pins).
check_input() {  # LABEL FILE SHA1
  [ -f "$2" ] || mra_die "$1 not found: $2 (set MRA_$1)"
  [ "$(sha1_of "$2")" = "$3" ] || mra_die "$1 SHA-1 mismatch: $2 is not the pinned $3"
}
check_input ROM "$MRA_ROM" "$MRA_ROM_SHA1"
check_input BIOS "$MRA_BIOS" "$MRA_BIOS_SHA1"

rp validate >/dev/null
# Starting-save routes are added and everything is put in manifest order,
# where a starting-save route always comes before the routes that use it.
order="$(rp plan ${routes[@]+"${routes[@]}"})"

TRACE_MEM="$(rp trace-mem)"
FRESH_SHA1="$(python3 -I -c 'import hashlib; print(hashlib.sha1(b"\xff" * 32768).hexdigest())')"
OUT_ROOT="$(mra_out_path routes)"
mkdir -p "$OUT_ROOT"

total=0
failed=""
# shellcheck disable=SC2086  # one route name per line; routes.py allows no spaces in names
for r in $order; do
  total=$((total + 1))
  script="$(rp get "$r" script)"
  frames="$(rp get "$r" frames)"
  start_save="$(rp get "$r" start_save)"
  sram="$(rp get "$r" sram)"
  save_sha1="$(rp get "$r" save_sha1)"
  echo "== $r: $script, $frames frames${start_save:+, starting save from $start_save}"
  # Outputs of an earlier invocation must not pass for this one's.
  rm -rf "$OUT_ROOT/$r-a" "$OUT_ROOT/$r-b"
  rm -f "$OUT_ROOT/$r-a.sav" "$OUT_ROOT/$r-b.sav" "$OUT_ROOT/$r-a.log" "$OUT_ROOT/$r-b.log"
  problems=""
  start_file=""
  start_sha1="$FRESH_SHA1"
  if [ -n "$start_save" ]; then
    start_file="$OUT_ROOT/$start_save-a.sav"
    case "$failed " in
      *" $start_save "*) problems="; starting save: route $start_save failed" ;;
      *)
        if [ -f "$start_file" ]; then
          start_sha1="$(sha1_of "$start_file")"
        else
          problems="; starting save $start_file is missing"
        fi ;;
    esac
  fi
  if [ -z "$problems" ]; then
    for k in a b; do
      out="$OUT_ROOT/$r-$k"
      sav="$OUT_ROOT/$r-$k.sav"
      # The harness loads --save and writes the run's save back to it: always
      # pass a fresh copy, never the original.
      [ -z "$start_file" ] || cp "$start_file" "$sav"
      if ! "$RUN_HARNESS" --out "$out" --script "$MRA_REPO/$script" --frames "$frames" \
          --save "$sav" --trace "1-$frames" --trace-mem "$TRACE_MEM" >"$out.log" 2>&1; then
        problems="$problems; run $k failed (see $out.log)"
        continue
      fi
      end="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["end_frame"])' "$out/summary.json")"
      [ "$end" = "$frames" ] || problems="$problems; run $k ended at frame $end, not $frames"
    done
  fi
  if [ -z "$problems" ]; then
    cmp -s "$OUT_ROOT/$r-a/trace.tsv" "$OUT_ROOT/$r-b/trace.tsv" ||
      problems="$problems; trace.tsv differs between runs a and b"
    cmp -s "$OUT_ROOT/$r-a.sav" "$OUT_ROOT/$r-b.sav" ||
      problems="$problems; final save differs between runs a and b"
    rp check "$r" "$OUT_ROOT/$r-a/trace.tsv" --exact || problems="$problems; checkpoints"
    got="$(sha1_of "$OUT_ROOT/$r-a.sav")"
    echo "final save SHA-1 $got"
    case "$sram" in
      none) [ "$got" = "$start_sha1" ] || problems="$problems; save written although sram = none" ;;
      written) [ "$got" != "$start_sha1" ] || problems="$problems; save not written although sram = written" ;;
    esac
    if [ -n "$save_sha1" ] && [ "$got" != "$save_sha1" ]; then
      problems="$problems; final save SHA-1 differs from the manifest's $save_sha1"
    fi
  fi
  if [ -z "$problems" ]; then
    # Run b only shows that the route is deterministic: keep it when anything
    # failed, so a difference can be looked at.
    [ "$KEEP" = 1 ] || rm -rf "$OUT_ROOT/$r-b" "$OUT_ROOT/$r-b.sav" "$OUT_ROOT/$r-b.log"
    echo "PASS $r"
  else
    echo "FAIL $r: ${problems#; }"
    failed="$failed $r"
  fi
done

echo
if [ -z "$failed" ]; then
  echo "all $total routes pass"
else
  echo "routes that failed:$failed"
  exit 1
fi

#!/usr/bin/env bash
# Play a route of tools/difftest/routes.toml on two engines with the same
# inputs, check that the gbarecomp run follows the route, and compare the two
# runs' VBlank-start captures (docs/phase2-plan.md, P2-09; ADR 0001,
# decision 5). Needs the ROM and the BIOS.
#
#   scripts/replay-test.sh ROUTE --against interp|mgba [options]
#
#   --against interp   comparison 1: the recompiled build against gbarecomp's
#                      interpreter running the BIOS too (GBARECOMP_FORCE_INTERP=1
#                      MRA_INTERP_BIOS=1), exact on fb and the RAM hashes
#   --against mgba     comparison 2: gbarecomp against the mGBA harness, with
#                      the route's allowlist
#   --against none     no comparison: run the gbarecomp side only and check
#                      that it follows the route
#   --test KIND        the gbarecomp side of --against mgba or none: interp
#                      (the default until P2-10: GBARECOMP_FORCE_INTERP=1),
#                      reference (interp with MRA_INTERP_BIOS=1) or recompiled
#   --reference KIND   the reference of --against interp: bios (the default)
#                      or plain, the interpreter alone, whose SWIs run the
#                      recompiled BIOS: a difference with bios but not with
#                      plain is in the BIOS translation
#   --frames [A-]B     compare frames A-B (default 1 to the route's end) and
#                      stop the runs at B; the route's checkpoints after the
#                      runs end are not checked
#   --frame-map SPEC   pair frames across a known offset (compare.py --help)
#   --allowlist FILE   default: tools/difftest/allowlists/ROUTE.toml, if any
#   --script FILE      play this input script instead of the route's; the
#                      checkpoints stay the route's (a script with an input
#                      moved off its screen must fail them)
#   --replay-offset K  apply the gbarecomp side's inputs K frames late (early
#                      if negative): a wrong convention must make the run fail
#   --max-detail N     frames re-run with line records and raw frames
#                      (default 1200; 0 for none)
#   --fp-ring FRAME    then run both gbarecomp sides of --against interp up to
#                      FRAME with gbarecomp's fingerprint ring armed and diff
#                      their last instructions (tools/difftest/fpdiff.py): FRAME
#                      is the first frame whose capture differs
#   --fp-records N     fingerprint records kept per side (default 500000,
#                      about 110 MB of CSV; at most 2000000)
#   --exe PATH         the game executable (default build/native/MotoRacerAdvanceRecomp)
#   --out DIR          outputs (default build/replay-test/ROUTE-AGAINST)
#   --keep             keep the detail captures (line records, raw frames)
#                      and the fingerprint tails, which show the game
#   --rom PATH, --bios PATH
#
# The steps: the replay (tools/replay/script2replay.py), both runs in
# parallel with the per-frame capture (P2-03), tools/difftest/routes.py check
# on the gbarecomp capture (and on mGBA's), tools/difftest/compare.py, then,
# for the frames whose CRCs differ, both runs again with line records and raw
# frames and compare.py with them. A route that starts from another route's
# save runs that route first on each engine. Runs are headless and muted
# (SDL_AUDIODRIVER=dummy), with GBARECOMP_SELFHEAL_RECOMPILE=0 and a fresh
# save, as docs/phase2-plan.md asks.
#
# Exit 0 when both runs end normally, the gbarecomp run follows the route and
# the comparison passes; 1 otherwise; 2 on a usage or setup error. Outputs are
# derived from the ROM: they stay under build/ (gitignored). Environment:
# HARNESS_BIN and MRA_OUT as for tools/analysis (the harness binary).
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage_error() {
  printf 'replay-test.sh: %s\n' "$*" >&2
  exit 2
}

ROUTE=""
AGAINST=""
TEST_KIND=interp
REF_KIND=bios
RANGE=""
FRAME_MAP=""
ALLOWLIST=""
SCRIPT=""
OFFSET=0
MAX_DETAIL=1200
FP_FRAME=""
FP_RECORDS=500000
EXE="$MRA_BUILD_DIR/native/MotoRacerAdvanceRecomp"
OUT=""
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --against | --test | --reference | --frames | --frame-map | --allowlist | --script | --replay-offset | \
      --max-detail | --fp-ring | --fp-records | --exe | --out | --rom | --bios)
      [ $# -ge 2 ] || usage_error "$1 needs a value"
      case "$1" in
        --against) AGAINST=$2 ;;
        --test) TEST_KIND=$2 ;;
        --reference) REF_KIND=$2 ;;
        --frames) RANGE=$2 ;;
        --frame-map) FRAME_MAP=$2 ;;
        --allowlist) ALLOWLIST=$2 ;;
        --script) SCRIPT=$2 ;;
        --replay-offset) OFFSET=$2 ;;
        --max-detail) MAX_DETAIL=$2 ;;
        --fp-ring) FP_FRAME=$2 ;;
        --fp-records) FP_RECORDS=$2 ;;
        --exe) EXE=$2 ;;
        --out) OUT=$2 ;;
        --rom | --bios) set_input "$1" "$2" ;;
      esac
      shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h | --help) sed -n '2,59p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) usage_error "unknown option $1" ;;
    *)
      [ -z "$ROUTE" ] || usage_error "one route only ($ROUTE, $1)"
      ROUTE=$1; shift ;;
  esac
done
[ -n "$ROUTE" ] || usage_error "name a route (python3 -I tools/difftest/routes.py list)"
case "$AGAINST" in interp | mgba | none) ;; *) usage_error "--against interp, mgba or none is required" ;; esac
case "$TEST_KIND" in interp | reference | recompiled) ;; *) usage_error "--test interp, reference or recompiled" ;; esac
case "$REF_KIND" in bios | plain) ;; *) usage_error "--reference bios or plain" ;; esac
case "$OFFSET" in -[0-9]* | [0-9]*) ;; *) usage_error "--replay-offset needs a number of frames" ;; esac
case "$MAX_DETAIL" in *[!0-9]* | "") usage_error "--max-detail needs a number" ;; esac
case "$FP_RECORDS" in *[!0-9]* | "") usage_error "--fp-records needs a number" ;; esac
if [ -n "$FP_FRAME" ]; then
  [ "$AGAINST" = interp ] || usage_error "--fp-ring is for --against interp (both sides are gbarecomp)"
  case "$FP_FRAME" in *[!0-9]* | "") usage_error "--fp-ring needs a frame number" ;; esac
fi

DIFFTEST="$MRA_ROOT/tools/difftest"
rp() { python3 -I "$DIFFTEST/routes.py" "$@"; }
command -v python3 > /dev/null 2>&1 || usage_error "python3 (3.11 or newer) is required"
python3 -I -c 'import sys; sys.exit(sys.version_info < (3, 11))' ||
  usage_error "python3 3.11 or newer is required (tomllib)"
route_frames=$(rp get "$ROUTE" frames) || usage_error "unknown route $ROUTE"
route_script="$MRA_ROOT/$(rp get "$ROUTE" script)"

# The compared window, and how long the runs go.
first=1
last=$route_frames
if [ -n "$RANGE" ]; then
  case "$RANGE" in
    *-*) first=${RANGE%-*}; last=${RANGE#*-} ;;
    *) last=$RANGE ;;
  esac
  case "$first$last" in *[!0-9]*) usage_error "--frames A-B or --frames B" ;; esac
  if [ "$first" -lt 1 ] || [ "$first" -gt "$last" ]; then usage_error "--frames: bad range $RANGE"; fi
fi
partial=""
[ "$last" -ge "$route_frames" ] || partial=--partial
# A frame map can pair a REF frame with a later TEST frame: run TEST that far.
reach=0
if [ -n "$FRAME_MAP" ]; then
  reach=$(python3 -I -c '
import re, sys
r = 0
for tok in sys.argv[1].split(","):
    m = re.search(r":(?:([+-]?\d+)|~(\d+))\s*$", tok)
    if m:
        r = max(r, int(m.group(1)) if m.group(1) else int(m.group(2)))
print(max(r, 0))' "$FRAME_MAP")
fi
test_last=$((last + reach))

if [ -n "$SCRIPT" ]; then
  case "$SCRIPT" in /*) ;; *) SCRIPT="$PWD/$SCRIPT" ;; esac
  [ -f "$SCRIPT" ] || usage_error "script not found: $SCRIPT"
fi
if [ "$AGAINST" = mgba ] && [ -z "$ALLOWLIST" ] && [ -f "$DIFFTEST/allowlists/$ROUTE.toml" ]; then
  ALLOWLIST="$DIFFTEST/allowlists/$ROUTE.toml"
fi

[ -x "$EXE" ] || usage_error "no game executable at $(rel "$EXE"): run scripts/build-native.sh"
require_inputs
# The manifest's frames hold for one ROM and one BIOS (routes.toml's pins).
[ "$(sha1_of "$MRA_ROM")" = "$(toml_get "$DIFFTEST/routes.toml" "" rom_sha1)" ] ||
  usage_error "$(rel "$MRA_ROM") is not the ROM the route manifest was recorded on"
[ "$(sha1_of "$MRA_BIOS")" = "$(toml_get "$DIFFTEST/routes.toml" "" bios_sha1)" ] ||
  usage_error "$(rel "$MRA_BIOS") is not the BIOS the route manifest was recorded on"
HARNESS="${HARNESS_BIN:-${MRA_OUT:-$MRA_ROOT/analysis-out}/bin/gbaharness}"
if [ "$AGAINST" = mgba ]; then
  [ -x "$HARNESS" ] || usage_error "harness not built: $HARNESS (tools/analysis/harness/build.sh, or set HARNESS_BIN)"
fi

OUT=${OUT:-$MRA_BUILD_DIR/replay-test/$ROUTE-$AGAINST}
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
mkdir -p "$OUT"
rm -rf "$OUT/ref" "$OUT/test" "$OUT/detail" "$OUT/fp"
rm -f "$OUT"/*.tsv "$OUT"/*.log "$OUT"/*.txt "$OUT"/*.json "$OUT"/*.csv

MEM=$(rp trace-mem)
SPEC="$MRA_ROOT/tools/capture/spec.txt"

# The two sides: "harness" or gbarecomp with its backend variables.
if [ "$AGAINST" != interp ]; then
  REF_ENGINE=harness
  case "$TEST_KIND" in
    interp) TEST_VARS="GBARECOMP_FORCE_INTERP=1" ;;
    reference) TEST_VARS="GBARECOMP_FORCE_INTERP=1 MRA_INTERP_BIOS=1" ;;
    recompiled) TEST_VARS="" ;;
  esac
  REF_VARS=""
  ref_desc="mGBA harness"
  if [ "$AGAINST" = none ]; then
    REF_ENGINE=none
    ref_desc="none"
  fi
else
  REF_ENGINE=gbarecomp
  case "$REF_KIND" in
    bios) REF_VARS="GBARECOMP_FORCE_INTERP=1 MRA_INTERP_BIOS=1"; ref_desc="interpreter with the BIOS interpreted" ;;
    plain) REF_VARS="GBARECOMP_FORCE_INTERP=1"; ref_desc="plain interpreter (recompiled BIOS)" ;;
  esac
  TEST_KIND=recompiled
  TEST_VARS=""
fi
test_desc="gbarecomp $TEST_KIND"

# ---- the replay
replay="$OUT/replay.csv"
if [ -n "$SCRIPT" ]; then
  python3 -I "$MRA_ROOT/tools/replay/script2replay.py" "$SCRIPT" --frames "$route_frames" -o "$replay"
  harness_script=$SCRIPT
else
  python3 -I "$MRA_ROOT/tools/replay/script2replay.py" --route "$ROUTE" -o "$replay"
  harness_script=$route_script
fi
test_replay=$replay
if [ "$OFFSET" != 0 ]; then
  test_replay="$OUT/replay-offset.csv"
  if [ -n "$SCRIPT" ]; then
    python3 -I "$MRA_ROOT/tools/replay/script2replay.py" "$SCRIPT" --frames "$route_frames" \
      --offset "$OFFSET" -o "$test_replay"
  else
    python3 -I "$MRA_ROOT/tools/replay/script2replay.py" --route "$ROUTE" --offset "$OFFSET" -o "$test_replay"
  fi
fi

# ---- running the engines
# run_gbarecomp DIR LOG SAVE FRAMES REPLAY VARS [VAR=VALUE...]: one headless
# run from DIR (gbarecomp writes its miss reports into the current directory).
# Prints the exit status.
run_gbarecomp() {
  local dir=$1 log=$2 save=$3 frames=$4 replay_file=$5 vars=$6 status=0
  shift 6
  mkdir -p "$dir"
  # shellcheck disable=SC2086  # VARS is a list of VAR=VALUE words
  (cd "$dir" && exec env SDL_AUDIODRIVER=dummy GBARECOMP_SELFHEAL_RECOMPILE=0 $vars \
    ${replay_file:+MRA_REPLAY="$replay_file"} "$@" \
    "$EXE" --bios "$MRA_BIOS" --rom "$MRA_ROM" --frames "$frames" --no-window \
    --save-path "$save" "$MRA_GAME_CONFIG") > "$log" 2>&1 || status=$?
  echo "$status"
}

# run_harness DIR LOG SAVE FRAMES SCRIPT [options...]: prints the exit status.
run_harness() {
  local dir=$1 log=$2 save=$3 frames=$4 script=$5 status=0
  shift 5
  HARNESS_BIN=$HARNESS "$MRA_ROOT/tools/analysis/harness/run_harness.sh" --rom "$MRA_ROM" --bios "$MRA_BIOS" \
    --out "$dir" --script "$script" --frames "$frames" --save "$save" "$@" > "$log" 2>&1 || status=$?
  echo "$status"
}

# start_save SIDE DIR VARS: the save the route starts from on that side, made
# by running the routes it depends on; prints its path (empty for a fresh save).
start_save() {
  local side=$1 dir=$2 vars=$3 prev="" r frames script save status
  for r in $(rp plan "$ROUTE"); do
    [ "$r" != "$ROUTE" ] || break
    frames=$(rp get "$r" frames)
    script="$MRA_ROOT/$(rp get "$r" script)"
    save="$dir/start-$r.sav"
    rm -f "$save"
    [ -z "$prev" ] || cp "$prev" "$save"
    if [ "$side" = harness ]; then
      status=$(run_harness "$dir/start-$r" "$dir/start-$r.log" "$save" "$frames" "$script")
    else
      python3 -I "$MRA_ROOT/tools/replay/script2replay.py" --route "$r" -o "$dir/start-$r.csv"
      status=$(run_gbarecomp "$dir/start-$r" "$dir/start-$r.log" "$save" "$frames" "$dir/start-$r.csv" "$vars")
    fi
    if [ "$status" != 0 ] || [ ! -f "$save" ]; then
      echo "start route $r failed on $side (see $dir/start-$r.log)" >&2
      return 1
    fi
    prev=$save
  done
  printf '%s\n' "$prev"
}

# capture_side SIDE NAME FRAMES [extra capture options]: run one side with the
# per-frame capture into $OUT/NAME.tsv. Prints the exit status.
capture_side() {
  local side=$1 name=$2 frames=$3 vars=$4 replay_file=$5 dir="$OUT/$2" save sav0 status
  shift 5
  mkdir -p "$dir"
  save="$dir/run.sav"
  rm -f "$save"
  sav0=$(cat "$OUT/${name%-detail}.start" 2> /dev/null || true)
  [ -z "$sav0" ] || cp "$sav0" "$save"
  if [ "$side" = harness ]; then
    status=$(run_harness "$dir/harness" "$OUT/$name.log" "$save" "$frames" "$harness_script" \
      --capture --capture-spec "$SPEC" --capture-mem "$MEM" --capture-frames "1-$frames" "$@")
    if [ -f "$dir/harness/capture.tsv" ]; then
      mv "$dir/harness/capture.tsv" "$OUT/$name.tsv"
      [ ! -f "$dir/harness/capture.lines.tsv" ] || mv "$dir/harness/capture.lines.tsv" "$OUT/$name.lines.tsv"
      [ ! -d "$dir/harness/capture.raw" ] || mv "$dir/harness/capture.raw" "$OUT/$name.raw"
    fi
  else
    status=$(run_gbarecomp "$dir" "$OUT/$name.log" "$save" "$frames" "$replay_file" "$vars" \
      GBARECOMP_CAPTURE="$OUT/$name.tsv" GBARECOMP_CAPTURE_SPEC="@$SPEC" GBARECOMP_CAPTURE_MEM="$MEM" \
      GBARECOMP_CAPTURE_FRAMES="1-$frames" "$@")
  fi
  echo "$status"
}

describe_run() {  # NAME STATUS: the exit status and where the run stopped
  local final
  final=$(grep -E '^final_pc=|^done: frames' "$OUT/$1.log" 2> /dev/null | tail -n 1 |
    sed -E 's/.*(ppu_vcount=[0-9]+ ppu_frames=[0-9]+).*/\1/; s/^done: (frames [0-9.]+).*/\1/' || true)
  printf '  %-5s exit %s%s\n' "$1" "$2" "${final:+, $final}"
}

info "$ROUTE --against $AGAINST: REF $ref_desc, TEST $test_desc, frames $first-$last${FRAME_MAP:+, frame map $FRAME_MAP}"
if [ -n "$(rp get "$ROUTE" start_save)" ]; then
  info "Starting saves: running $(rp plan "$ROUTE" | grep -vx "$ROUTE" | tr '\n' ' ')first"
  mkdir -p "$OUT/start-ref" "$OUT/start-test"
  if [ "$REF_ENGINE" != none ]; then
    start_save "$REF_ENGINE" "$OUT/start-ref" "$REF_VARS" > "$OUT/ref.start" || exit 1
  fi
  start_save gbarecomp "$OUT/start-test" "$TEST_VARS" > "$OUT/test.start" || exit 1
fi

ref_pid=""
if [ "$REF_ENGINE" = none ]; then
  info "Running the gbarecomp side (log: $(rel "$OUT")/test.log)"
  echo 0 > "$OUT/ref.status"
else
  info "Running both sides (logs: $(rel "$OUT")/ref.log, test.log)"
  if [ "$REF_ENGINE" = harness ]; then
    capture_side harness ref "$last" "" "" > "$OUT/ref.status" &
  else
    capture_side gbarecomp ref "$last" "$REF_VARS" "$replay" > "$OUT/ref.status" &
  fi
  ref_pid=$!
fi
capture_side gbarecomp test "$test_last" "$TEST_VARS" "$test_replay" > "$OUT/test.status"
[ -z "$ref_pid" ] || wait "$ref_pid" || true
ref_status=$(cat "$OUT/ref.status")
test_status=$(cat "$OUT/test.status")
[ "$REF_ENGINE" = none ] || describe_run ref "$ref_status"
describe_run test "$test_status"
problems=""
[ "$ref_status" = 0 ] || problems="$problems; the REF run exited with $ref_status"
[ "$test_status" = 0 ] || problems="$problems; the TEST run exited with $test_status"
if [ ! -s "$OUT/test.tsv" ] || { [ "$REF_ENGINE" != none ] && [ ! -s "$OUT/ref.tsv" ]; }; then
  echo "FAIL: a run wrote no capture (see the logs in $(rel "$OUT"))"
  exit 1
fi

# ---- the final save, against the manifest's mGBA save (reported only; P2-11
# gates saves)
want_save=$(rp get "$ROUTE" save_sha1)
if [ -n "$want_save" ] && [ "$last" -ge "$route_frames" ] && [ -f "$OUT/test/run.sav" ]; then
  got_save=$(sha1_of "$OUT/test/run.sav")
  if [ "$got_save" = "$want_save" ]; then
    echo "  final save of the gbarecomp run: SHA-1 $got_save, equal to mGBA's (routes.toml)"
  else
    echo "  final save of the gbarecomp run: SHA-1 $got_save, mGBA's is $want_save (routes.toml): different (reported only)"
  fi
fi

# ---- route following
info "Route checkpoints, gbarecomp side ($TEST_KIND)"
if ! rp check "$ROUTE" "$OUT/test.tsv" ${partial:+"$partial"} | tee "$OUT/route-test.txt"; then
  problems="$problems; the gbarecomp run does not follow the route"
fi
if [ "$REF_ENGINE" = none ]; then
  echo
  if [ -z "$problems" ]; then
    echo "PASS $ROUTE: the gbarecomp run ($TEST_KIND) follows the route"
    exit 0
  fi
  echo "FAIL $ROUTE: ${problems#; }"
  exit 1
elif [ "$REF_ENGINE" = harness ]; then
  info "Route checkpoints, mGBA side"
  rp check "$ROUTE" "$OUT/ref.tsv" ${partial:+"$partial"} > "$OUT/route-ref.txt" ||
    problems="$problems; the mGBA run does not follow the route"
  tail -n 1 "$OUT/route-ref.txt"
else
  info "Route checkpoints, reference side"
  rp check "$ROUTE" "$OUT/ref.tsv" ${partial:+"$partial"} > "$OUT/route-ref.txt" ||
    problems="$problems; the reference run does not follow the route"
  tail -n 1 "$OUT/route-ref.txt"
fi

# ---- comparison, per-frame pass
compare_args=(--against "$AGAINST" --frames "$first-$last" --max-detail "$MAX_DETAIL")
[ -z "$FRAME_MAP" ] || compare_args+=(--frame-map "$FRAME_MAP")
[ -z "$ALLOWLIST" ] || compare_args+=(--allowlist "$ALLOWLIST")
info "Comparing (per-frame records)"
cmp_status=0
python3 -I "$DIFFTEST/compare.py" "$OUT/ref.tsv" "$OUT/test.tsv" "${compare_args[@]}" \
  --detail-out "$OUT/detail-frames.tsv" --json "$OUT/compare-frames.json" \
  --frame-report "$OUT/frames.tsv" > "$OUT/compare-frames.txt" || cmp_status=$?
[ "$cmp_status" -le 1 ] || { cat "$OUT/compare-frames.txt"; die "compare.py failed (exit $cmp_status)"; }
report="$OUT/compare-frames.txt"

# ---- detail pass: line records and raw frames of the frames whose CRCs differ
if [ "$MAX_DETAIL" -gt 0 ] && [ -s "$OUT/detail-frames.tsv" ]; then
  # At most 32 entries per capture list (both engines): merge the closest
  # ranges until the list fits. The extra frames cost only disk.
  lists=$(python3 -I -c '
import sys
cols = ([], [])
for line in open(sys.argv[1]):
    a, b = line.split("\t")[:2]
    cols[0].append(int(a)); cols[1].append(int(b))
for frames in cols:
    rs = []
    for f in sorted(set(frames)):
        if rs and f == rs[-1][1] + 1: rs[-1][1] = f
        else: rs.append([f, f])
    while len(rs) > 32:
        i = min(range(len(rs) - 1), key=lambda k: rs[k + 1][0] - rs[k][1])
        rs[i][1] = rs[i + 1][1]; del rs[i + 1]
    print(",".join("%d-%d" % (a, b) for a, b in rs), max(frames), sum(b - a + 1 for a, b in rs))' \
    "$OUT/detail-frames.tsv")
  ref_list=$(printf '%s\n' "$lists" | sed -n 1p | cut -d' ' -f1)
  ref_max=$(printf '%s\n' "$lists" | sed -n 1p | cut -d' ' -f2)
  ref_count=$(printf '%s\n' "$lists" | sed -n 1p | cut -d' ' -f3)
  test_list=$(printf '%s\n' "$lists" | sed -n 2p | cut -d' ' -f1)
  test_max=$(printf '%s\n' "$lists" | sed -n 2p | cut -d' ' -f2)
  test_count=$(printf '%s\n' "$lists" | sed -n 2p | cut -d' ' -f3)
  need=$(wc -l < "$OUT/detail-frames.tsv" | tr -d ' ')
  info "Detail: $need frames to look at; re-running both sides to frames $ref_max and $test_max with line records and raw frames ($ref_count and $test_count frames, about $(((ref_count + test_count) * 116 / 1000)) MB)"
  mkdir -p "$OUT/detail"
  cp "$OUT/ref.tsv" "$OUT/detail/ref-pass1.tsv"
  cp "$OUT/test.tsv" "$OUT/detail/test-pass1.tsv"
  for side in ref test; do
    if [ "$side" = ref ]; then max=$ref_max; list=$ref_list; else max=$test_max; list=$test_list; fi
    if [ "$side" = ref ] && [ "$REF_ENGINE" = harness ]; then
      capture_side harness ref-detail "$max" "" "" --capture-lines "$list" --capture-raw "$list" \
        > "$OUT/detail/ref.status" &
    elif [ "$side" = ref ]; then
      capture_side gbarecomp ref-detail "$max" "$REF_VARS" "$replay" GBARECOMP_CAPTURE_LINES="$list" \
        GBARECOMP_CAPTURE_RAW="$list" > "$OUT/detail/ref.status" &
    else
      capture_side gbarecomp test-detail "$max" "$TEST_VARS" "$test_replay" GBARECOMP_CAPTURE_LINES="$list" \
        GBARECOMP_CAPTURE_RAW="$list" > "$OUT/detail/test.status" &
    fi
  done
  wait
  # Runs are deterministic (docs/research/phase2-diagnosis.md section 7.6): the
  # detail runs must give the same per-frame records as the first runs.
  for side in ref test; do
    if [ "$side" = ref ]; then max=$ref_max; else max=$test_max; fi
    n=$((max + 1))
    if ! cmp -s <(head -n "$n" "$OUT/$side-detail.tsv") <(head -n "$n" "$OUT/detail/$side-pass1.tsv"); then
      problems="$problems; the $side detail run's per-frame records differ from the first run's (not deterministic?)"
    fi
  done
  set +e
  python3 -I "$DIFFTEST/compare.py" "$OUT/ref.tsv" "$OUT/test.tsv" "${compare_args[@]}" \
    --ref-lines "$OUT/ref-detail.lines.tsv" --test-lines "$OUT/test-detail.lines.tsv" \
    --ref-raw "$OUT/ref-detail.raw" --test-raw "$OUT/test-detail.raw" \
    --json "$OUT/compare.json" --frame-report "$OUT/frames.tsv" > "$OUT/compare.txt"
  cmp_status=$?
  set -e
  [ "$cmp_status" -le 1 ] || { cat "$OUT/compare.txt"; die "compare.py failed (exit $cmp_status)"; }
  report="$OUT/compare.txt"
  if [ "$KEEP" = 0 ]; then
    rm -rf "$OUT/ref-detail.raw" "$OUT/test-detail.raw" "$OUT/ref-detail" "$OUT/test-detail" "$OUT/detail"
    rm -f "$OUT/ref-detail.lines.tsv" "$OUT/test-detail.lines.tsv"
  fi
else
  cp "$OUT/compare-frames.json" "$OUT/compare.json"
  cp "$OUT/compare-frames.txt" "$OUT/compare.txt"
fi
cat "$report"
[ "$cmp_status" = 0 ] || problems="$problems; the comparison fails"

# ---- fingerprint ring (comparison 1)
if [ -n "$FP_FRAME" ]; then
  info "Fingerprint ring: both sides to frame $FP_FRAME, last $FP_RECORDS instructions each"
  mkdir -p "$OUT/fp"
  for side in ref test; do
    if [ "$side" = ref ]; then vars=$REF_VARS; rep=$replay; else vars=$TEST_VARS; rep=$test_replay; fi
    run_gbarecomp "$OUT/fp/$side" "$OUT/fp/$side.log" "$OUT/fp/$side.sav" "$FP_FRAME" "$rep" "$vars" \
      GBARECOMP_INSN_TRACE=1 MRA_FP_TAIL="$OUT/fp/$side.csv" MRA_FP_TAIL_RECORDS="$FP_RECORDS" \
      > "$OUT/fp/$side.status" &
  done
  wait
  python3 -I "$DIFFTEST/fpdiff.py" "$OUT/fp/ref.csv" "$OUT/fp/test.csv" --costs 20 | tee "$OUT/fpdiff.txt" || true
  [ "$KEEP" = 1 ] || rm -f "$OUT/fp/ref.csv" "$OUT/fp/test.csv"
fi

echo
if [ -z "$problems" ]; then
  echo "PASS $ROUTE --against $AGAINST (report: $(rel "$OUT")/compare.txt)"
else
  echo "FAIL $ROUTE --against $AGAINST: ${problems#; } (report: $(rel "$OUT")/compare.txt)"
  exit 1
fi

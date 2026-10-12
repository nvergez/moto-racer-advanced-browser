#!/usr/bin/env bash
# Test scripts/replay-test.sh's option checks and how it treats its output
# directory, without game data: every run below stops with exit 2 before an
# engine starts (a bad option, an --out the runner refuses, or the missing
# ROM). Needs python3 3.11 or newer (the route manifest); CI runs it.
#
#   tests/tooling/replay-test-args-test.sh
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
runner=$repo/scripts/replay-test.sh
unset MRA_BUILD_DIR MRA_GENERATED_DIR MRA_WITHOUT_PATCHES MRA_PATCH_VARIANT MRA_PATCH_STATE_DIR

work=$(mktemp -d "${TMPDIR:-/tmp}/replay-test-args.XXXXXX")
# shellcheck disable=SC2317  # called by the trap
cleanup() {
  if [ -n "${KEEP_WORK:-}" ]; then echo "# kept $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT
# Relative paths in this test must never reach the real repository.
cd "$work"
out=$work/out
# A stand-in for the game executable: the runs stop before they start it.
stub=$work/stub-game
printf '#!/bin/sh\nexit 99\n' > "$stub"
chmod +x "$stub"
no_rom=$work/no-such-rom.gba

count=0
failures=0
pass() {
  count=$((count + 1))
  printf 'ok %d - %s\n' "$count" "$1"
}
fail() {
  count=$((count + 1))
  failures=$((failures + 1))
  printf 'not ok %d - %s\n' "$count" "$1"
  sed 's/^/#   /' "$out"
}

# refused DESC TEXT ARGS...: the runner exits 2 and prints TEXT.
refused() {
  local desc=$1 text=$2 status=0
  shift 2
  "$runner" "$@" > "$out" 2>&1 || status=$?
  if [ "$status" = 2 ] && grep -qF -- "$text" "$out"; then pass "$desc"; else fail "$desc (exit $status)"; fi
}

base=(boot_to_race --exe "$stub" --rom "$no_rom")
d=$work/o
refused "--frames -5" "--frames A-B or --frames B" "${base[@]}" --against none --frames -5 --out "$d"
refused "--frames 5-" "--frames A-B or --frames B" "${base[@]}" --against none --frames 5- --out "$d"
refused "--frames 0" "bad range 0" "${base[@]}" --against none --frames 0 --out "$d"
refused "--frames 9-3" "bad range 9-3" "${base[@]}" --against none --frames 9-3 --out "$d"
refused "--replay-offset 1x" "--replay-offset needs a whole number" "${base[@]}" --against none --replay-offset 1x --out "$d"
refused "--fp-records 0" "--fp-records: 1 to 2000000" "${base[@]}" --against interp --fp-records 0 --out "$d"
refused "--fp-records 2000001" "--fp-records: 1 to 2000000" "${base[@]}" --against interp --fp-records 2000001 --out "$d"
refused "--max-detail 5001" "--max-detail: at most 5000" "${base[@]}" --against mgba --max-detail 5001 --out "$d"
refused "--timeout x" "--timeout needs a number" "${base[@]}" --against none --timeout x --out "$d"
refused "--test with --against interp" "--test is for --against mgba or none" "${base[@]}" --against interp --test reference --out "$d"
refused "--reference without --against interp" "--reference is for --against interp" "${base[@]}" --against mgba --reference plain --out "$d"
if [ ! -e "$d" ]; then pass "no output directory made for a refused option"; else fail "an option error made $d"; fi

# A directory the runner did not make is refused, and left as it is.
d=$work/mine
mkdir -p "$d/test"
echo notes > "$d/notes.txt"
echo mine > "$d/test/mine.md"
refused "--out: a non-empty directory without the marker" "replay-test.sh did not make it" \
  "${base[@]}" --against none --out "$d"
if [ -f "$d/notes.txt" ] && [ -f "$d/test/mine.md" ] && [ ! -e "$d/.replay-test-out" ]; then
  pass "the refused directory is untouched"
else
  fail "the refused directory was changed"
fi

# Inside the repository, outputs go under build/ only.
refused "--out inside the repository, outside build/" "outputs go under build/" \
  "${base[@]}" --against none --out "$repo/docs/replay-test-args-test"
if [ ! -e "$repo/docs/replay-test-args-test" ]; then pass "nothing made in docs/"; else fail "made docs/replay-test-args-test"; fi
refused "--out at the repository root" "outputs go under build/" "${base[@]}" --against none --out "$repo"

# An empty directory is taken, and marked. The run then stops at the ROM.
d=$work/empty
mkdir -p "$d"
refused "--out: an empty directory is taken (then the ROM is missing)" "ROM not found" \
  "${base[@]}" --against none --out "$d"
if [ -f "$d/.replay-test-out" ]; then pass "the runner marks its directory"; else fail "no marker in $d"; fi

# In a directory the runner made, a new run deletes the runner's own outputs
# of the earlier run, the starting save of another route among them, and
# nothing else.
mkdir -p "$d/start-test" "$d/test"
echo save > "$d/start-test/start-options_save.sav"
echo "$d/start-test/start-options_save.sav" > "$d/test.start"
echo old > "$d/compare.txt"
echo old > "$d/test/run.sav"
echo notes > "$d/notes.txt"
refused "--out: the runner's own directory is taken again" "ROM not found" \
  "${base[@]}" --against none --out "$d"
left=""
for name in test.start start-test compare.txt test; do
  [ ! -e "$d/$name" ] || left="$left $name"
done
if [ -z "$left" ]; then pass "an earlier run's outputs are gone"; else fail "left from the earlier run:$left"; fi
if [ -f "$d/notes.txt" ]; then pass "a file the runner did not write stays"; else fail "notes.txt was deleted"; fi

echo "1..$count"
if [ "$failures" -gt 0 ]; then
  echo "# $failures of $count checks failed"
  exit 1
fi

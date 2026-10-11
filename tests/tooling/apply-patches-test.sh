#!/usr/bin/env bash
# Test scripts/apply-patches.sh and A/B builds (--without) on a toy
# repository. Needs git 2.32 or newer, and CMake for the A/B build part; no
# game data, no network and no compiler, so CI runs it.
#
#   tests/tooling/apply-patches-test.sh
#
# A copy of this repository's scripts/ runs in a scratch repository root whose
# gbarecomp/ is a toy git repository with two stacked patches: 0001 edits
# line 10 of f.txt, 0002 edits line 12 and adds sub/new.txt. 0002 was written
# on top of 0001, so line 10 is in its context. PR #5's apply-patches.sh
# (a7efc60) is run on the same case first; that part needs this repository's
# history and is skipped in a shallow clone.
# The checks below pass helper functions to check(), which shellcheck cannot
# see being called.
# shellcheck disable=SC2317
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)

# Hermetic git: no user or system config (signing, hooks, diff prefixes).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX
unset MRA_BUILD_DIR MRA_GENERATED_DIR MRA_WITHOUT_PATCHES MRA_PATCH_VARIANT \
  MRA_PATCH_STATE_DIR

work=$(mktemp -d "${TMPDIR:-/tmp}/apply-patches-test.XXXXXX")
cleanup() {
  chmod -R u+w "$work" 2> /dev/null || true
  if [ -n "${KEEP_WORK:-}" ]; then echo "# kept $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT
# Relative paths in this test must never reach the real repository.
cd "$work"
out=$work/out

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
  if [ "${2:-}" = show ] && [ -f "$out" ]; then sed 's/^/#   /' "$out"; fi
}
skip() {
  count=$((count + 1))
  printf 'ok %d - %s # SKIP %s\n' "$count" "$1" "$2"
}
# run_ok DESC CMD...: CMD succeeds. Its output goes to $out.
run_ok() {
  local desc=$1
  shift
  if "$@" > "$out" 2>&1; then pass "$desc"; else fail "$desc" show; fi
}
# run_fails DESC CMD...: CMD fails.
run_fails() {
  local desc=$1
  shift
  if "$@" > "$out" 2>&1; then fail "$desc (it succeeded)" show; else pass "$desc"; fi
}
# check DESC CMD...: a condition.
check() {
  local desc=$1
  shift
  if "$@"; then pass "$desc"; else fail "$desc" show; fi
}
said() { grep -q -- "$1" "$out"; }
said_all() {
  local pattern
  for pattern in "$@"; do said "$pattern" || return 1; done
}
# file_matches FILE PATTERN...: FILE has a line matching each PATTERN.
file_matches() {
  local file=$1 pattern
  shift
  for pattern in "$@"; do grep -q -- "$pattern" "$file" || return 1; done
}
# not_newer FILE...: no FILE was written since $work/ref.
not_newer() {
  local file
  for file in "$@"; do [ ! "$file" -nt "$work/ref" ] || return 1; done
}
in_dir() {
  local dir=$1
  shift
  (cd "$dir" && "$@")
}
has_line() { grep -qx -- "$2" "$1"; }
lacks_line() { ! grep -qx -- "$2" "$1"; }

# make_root DIR: a repository root with this repository's scripts and a toy
# gbarecomp/ at its "pin". The toy has what require_submodule looks for, and
# a CMake project whose build copies f.txt, so that the test can see which
# tree each build directory was built from.
make_root() {
  local root=$1 g=$1/gbarecomp i
  mkdir -p "$root/patches/gbarecomp" "$g/external/arm-recomp-core/cmake"
  cp -R "$repo/scripts" "$root/scripts"
  : > "$g/external/arm-recomp-core/cmake/ArmRecompCore.cmake"
  for i in $(seq 1 20); do echo "line $i"; done > "$g/f.txt"
  printf 'build/\n' > "$g/.gitignore"
  cat > "$g/CMakeLists.txt" << 'EOF'
cmake_minimum_required(VERSION 3.20)
project(toy NONE)
add_custom_target(copy_f ALL
  COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_SOURCE_DIR}/f.txt ${CMAKE_BINARY_DIR}/f.txt)
enable_testing()
add_test(NAME toy_built
  COMMAND ${CMAKE_COMMAND} -E compare_files ${CMAKE_SOURCE_DIR}/f.txt ${CMAKE_BINARY_DIR}/f.txt)
EOF
  git -C "$g" -c init.defaultBranch=main init -q
  git -C "$g" add -A
  git -C "$g" commit -q -m pin
}

# set_line FILE N TEXT
set_line() {
  awk -v n="$2" -v t="$3" 'NR == n { print t; next } { print }' "$1" > "$1.new"
  mv "$1.new" "$1"
}

# make_patches ROOT: 0001 (line 10), then 0002 on top of it (line 12 and a
# new file in a new directory).
make_patches() {
  local g=$1/gbarecomp p=$1/patches/gbarecomp
  set_line "$g/f.txt" 10 "line 10 A"
  { printf 'Toy patch A: line 10.\n\n'; git -C "$g" diff; } > "$p/0001-a.patch"
  git -C "$g" add f.txt
  set_line "$g/f.txt" 12 "line 12 B"
  mkdir -p "$g/sub"
  echo "added by B" > "$g/sub/new.txt"
  git -C "$g" add -N sub/new.txt
  { printf 'Toy patch B: line 12 and sub/new.txt, on top of A.\n\n'; git -C "$g" diff; } > "$p/0002-b.patch"
  git -C "$g" reset -q --hard
  rm -rf "$g/sub"
}

root=$work/root
g=$root/gbarecomp
apply=$root/scripts/apply-patches.sh
make_root "$root"
make_patches "$root"
clean_status() { [ -z "$(git -C "$g" status --porcelain)" ]; }
has_a() { has_line "$g/f.txt" "line 10 A"; }
has_b() { has_line "$g/f.txt" "line 12 B" && [ -f "$g/sub/new.txt" ]; }
lacks_b() { lacks_line "$g/f.txt" "line 12 B" && [ ! -e "$g/sub" ]; }
has_ab() { has_a && has_b; }
a_only() { has_a && lacks_b; }

# --- PR #5's script on the same case -----------------------------------------

old=$work/old
if git -C "$repo" cat-file -e a7efc60:scripts/apply-patches.sh 2> /dev/null; then
  make_root "$old"
  cp "$root"/patches/gbarecomp/*.patch "$old/patches/gbarecomp/"
  git -C "$repo" show a7efc60:scripts/apply-patches.sh > "$old/scripts/apply-patches.sh"
  git -C "$repo" show a7efc60:scripts/lib/common.sh > "$old/scripts/lib/common.sh"
  run_ok "PR #5's script: the first run applies both patches" "$old/scripts/apply-patches.sh"
  run_fails "PR #5's script: the second run stops on the stacked pair" "$old/scripts/apply-patches.sh"
  check "PR #5's script: ... because 0001 neither applies nor reverts on the full tree" \
    said "0001-a.patch neither applies nor reverts cleanly"
else
  skip "PR #5's script fails on the stacked pair" "a7efc60 is not in this clone's history"
fi

# --- Apply, re-apply, check, reverse -----------------------------------------

run_fails "--check on the pin exits 1" "$apply" --check
run_ok "applies the stack" "$apply"
check "the tree has 0001 and 0002" has_ab
touch -t 200001010000 "$g/f.txt" "$g/sub/new.txt"
touch -t 200101010000 "$work/ref"
run_ok "re-applies" "$apply"
check "the re-apply reports the stamp as up to date" said "(up to date)"
check "the re-apply wrote nothing" not_newer "$g/f.txt" "$g/sub/new.txt"
rm -rf "$root/build"
run_ok "re-applies without a stamp" "$apply"
check "... and finds the series in place" said "(already in place)"
check "... and wrote nothing" not_newer "$g/f.txt"
run_ok "--check passes" "$apply" --check
check "--check says OK" said "^OK: "
run_ok "--reverse" "$apply" --reverse
check "--reverse restores the pin, and removes the added file and directory" clean_status
check "... with no sub/ left" test ! -e "$g/sub"
run_fails "--check fails after --reverse" "$apply" --check
check "... and says the tree is the pin" said "is the pin, not"

# --- --without, and a lost stamp ---------------------------------------------

run_ok "--without 0002" "$apply" --without 0002
check "the tree has 0001 only" a_only
run_ok "--check --without 0002 passes" "$apply" --check --without 0002
run_fails "--check without --without fails" "$apply" --check
run_fails "an unknown --without stops" "$apply" --without 0009
check "... with a message" said "no patch in patches/gbarecomp matches '0009'"
rm -rf "$root/build"
run_ok "with the stamp deleted, a leading part of the series is still recognized" "$apply"
check "... and the full series is applied" has_ab
check "... and it says where it came from" said "was the pin plus 0001"

# --- A/B build with 0002 left out --------------------------------------------

if command -v cmake > /dev/null 2>&1; then
  engine=$root/scripts/test-engine.sh
  run_ok "normal build (scripts/test-engine.sh)" "$engine"
  check "build/gbarecomp is built from the full series" has_line "$root/build/gbarecomp/f.txt" "line 12 B"
  touch -t 200001010000 "$root/build/gbarecomp/f.txt"
  run_ok "A/B build (scripts/test-engine.sh --without 0002 -R toy_built)" "$engine" --without 0002 -R toy_built
  ab=$root/build/without-0002/gbarecomp
  ab_without_b() { has_line "$ab/f.txt" "line 10 A" && lacks_line "$ab/f.txt" "line 12 B"; }
  normal_untouched() {
    not_newer "$root/build/gbarecomp/f.txt" && has_line "$root/build/gbarecomp/f.txt" "line 12 B"
  }
  one_stamp() {
    [ -f "$root/build/gbarecomp-patches/stamp" ] && [ ! -e "$root/build/without-0002/gbarecomp-patches" ]
  }
  check "the A/B build is in build/without-0002/gbarecomp, built without 0002" ab_without_b
  check "the normal build directory was not touched" normal_untouched
  check "the stamp stays in build/, not in the A/B directory" one_stamp
  run_ok "the next normal build" "$engine"
  check "... restores the full series" has_ab
  check "... and rebuilds build/gbarecomp from it" has_line "$root/build/gbarecomp/f.txt" "line 12 B"
  check "... and leaves the A/B build as it was" lacks_line "$ab/f.txt" "line 12 B"
  run_ok "MRA_WITHOUT_PATCHES=0002 selects the same A/B directory" \
    env MRA_WITHOUT_PATCHES=0002 "$engine"
  check "... (no nested without-0002/without-0002)" test ! -e "$ab/without-0002"
  run_ok "and the normal build again" "$engine"
else
  skip "A/B build with 0002 left out" "cmake not found"
fi

# --- Hand edits ---------------------------------------------------------------

set_line "$g/f.txt" 5 "line 5 by hand"
cp "$g/f.txt" "$work/edited"
run_fails "a hand edit stops the script" "$apply"
check "... with a message that names the file" said_all "no known patch series explains" "f.txt"
check "... and the edit is kept" cmp -s "$g/f.txt" "$work/edited"
run_fails "--reverse refuses too" "$apply" --reverse
check "... and keeps the edit" cmp -s "$g/f.txt" "$work/edited"
run_fails "--check reports it" "$apply" --check
if command -v cmake > /dev/null 2>&1; then
  run_fails "a build stops too (ensure_patches)" "$root/scripts/test-engine.sh"
  check "... and keeps the edit" cmp -s "$g/f.txt" "$work/edited"
fi
echo "notes" > "$g/notes.txt"
run_fails "a new file stops it as well" "$apply"
check "... and names it" said "notes.txt"
rm "$g/notes.txt"

# --- --diff and --write-patch ------------------------------------------------

run_ok "--diff" "$apply" --diff
only_hand_edit() { said "^+line 5 by hand" && ! said "line 12 B"; }
check "--diff shows only the hand edit" only_hand_edit
run_ok "--write-patch saves it as 0003" "$apply" --write-patch "$root/patches/gbarecomp/0003-c.patch"
check "... and says the tree is now the series" said "is now the pin plus the series"
run_ok "the series with 0003 is in place" "$apply" --check
{ printf 'Toy patch C: line 5 (header).\n\n'; cat "$root/patches/gbarecomp/0003-c.patch"; } > "$work/c"
mv "$work/c" "$root/patches/gbarecomp/0003-c.patch"
run_ok "a header added to 0003 is accepted" "$apply"
set_line "$g/f.txt" 6 "line 6 by hand"
run_ok "--write-patch refreshes 0003 (path relative to the current directory)" \
  in_dir "$root" "$apply" --write-patch patches/gbarecomp/0003-c.patch
check "... keeps its header" has_line "$root/patches/gbarecomp/0003-c.patch" "Toy patch C: line 5 (header)."
check "... and holds both edits" \
  file_matches "$root/patches/gbarecomp/0003-c.patch" "^+line 5 by hand" "^+line 6 by hand"
run_ok "the refreshed series is in place" "$apply" --check

# --- A patch that does not apply ---------------------------------------------

sed 's/line 10 A/line 10 X/' "$root/patches/gbarecomp/0001-a.patch" |
  sed 's/^-line 10$/-line 10 nowhere/' > "$root/patches/gbarecomp/0004-bad.patch"
cp "$g/f.txt" "$work/before"
run_fails "a patch that does not apply stops the script" "$apply"
check "... naming it" said "0004-bad.patch does not apply"
check "... before writing anything" cmp -s "$g/f.txt" "$work/before"
rm "$root/patches/gbarecomp/0004-bad.patch"
run_ok "without it, the series is in place" "$apply" --check

# --- An interrupted run ------------------------------------------------------

if [ "$(id -u)" != 0 ]; then
  run_ok "--without 0002 (0001 and 0003 applied)" "$apply" --without 0002
  mkdir "$g/sub"
  chmod a-w "$g/sub"
  run_fails "a run that cannot write sub/new.txt stops halfway" "$apply"
  check "... with f.txt already written" has_line "$g/f.txt" "line 12 B"
  chmod u+w "$g/sub"
  run_ok "the next run recognizes the half-written tree" "$apply"
  check "... says so" said "interrupted"
  run_ok "... and completes the series" "$apply" --check
else
  skip "interrupted run" "running as root, so permissions cannot make a write fail"
fi

# --- An A/B build whose stamp is gone ----------------------------------------

run_ok "--without 0002 again (not a leading part of the series)" "$apply" --without 0002
rm -rf "$root/build"
run_ok "with the stamp deleted after an A/B build, the tree is still recognized" "$apply"
check "... as the series without 0002" said "(without 0002)"

# --- A series committed earlier ----------------------------------------------

# The root becomes a repository: commit X has 0001, 0002 and 0003-c; commit Y
# replaces 0003-c with 0003-d. The tree is then put back to X's series by
# hand, with no stamp: X's series is not a leading part of Y's, so only the
# history can explain it.
git -C "$root" -c init.defaultBranch=main init -q
printf '/gbarecomp/\n/build/\n' > "$root/.gitignore"
git -C "$root" add .gitignore patches scripts
git -C "$root" commit -q -m X
x=$(git -C "$root" rev-parse HEAD)
run_ok "--without 0003 (0001 and 0002 applied)" "$apply" --without 0003
set_line "$g/f.txt" 15 "line 15 D"
run_ok "a new 0003-d from a hand edit" \
  "$apply" --write-patch "$root/patches/gbarecomp/0003-d.patch" --without 0003
git -C "$root" rm -q patches/gbarecomp/0003-c.patch
git -C "$root" add patches/gbarecomp/0003-d.patch
git -C "$root" commit -q -m Y
run_ok "the series of Y is in place" "$apply" --check
git -C "$root" show "$x:patches/gbarecomp/0003-c.patch" > "$work/c.patch"
run_ok "--without 0003 again" "$apply" --without 0003
git -C "$g" apply "$work/c.patch"
rm -rf "$root/build"
run_ok "a tree at X's series, with no stamp, is recognized from the history" "$apply"
check "... which it says" said "was the series of commit"
run_ok "... and Y's series is in place" "$apply" --check
d_not_c() { has_line "$g/f.txt" "line 15 D" && lacks_line "$g/f.txt" "line 5 by hand"; }
check "... with 0003-d and not 0003-c" d_not_c

echo "1..$count"
if [ "$failures" != 0 ]; then
  echo "$failures of $count checks failed" >&2
  exit 1
fi
echo "All $count checks passed"

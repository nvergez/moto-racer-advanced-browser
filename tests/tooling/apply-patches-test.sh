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
# history and is skipped in a shallow clone. Later sections add 0003 (lines 5
# and 6), refresh 0001 under 0002, leave out 0001 that 0002 needs, hold the
# build lock from another process, record the toy's pin as a gitlink and give
# the toy another nested repository. The toy's external/arm-recomp-core is a
# nested repository, as in gbarecomp; the last section gives it a series of
# its own in patches/arm-recomp-core/, two stacked patches again, and runs
# the same checks on it.
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
not_said() { ! said "$1"; }
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
# gbarecomp/ at its "pin". The toy has what require_submodule looks for, in
# a nested repository at external/arm-recomp-core (with n.txt, which the
# nested series edits), and a CMake project whose build copies f.txt and
# n.txt, so that the test can see which trees each build directory was built
# from.
make_root() {
  local root=$1 g=$1/gbarecomp i
  local core=$g/external/arm-recomp-core
  mkdir -p "$root/patches/gbarecomp" "$core/cmake"
  cp -R "$repo/scripts" "$root/scripts"
  : > "$core/cmake/ArmRecompCore.cmake"
  for i in $(seq 1 20); do echo "core $i"; done > "$core/n.txt"
  git -C "$core" -c init.defaultBranch=main init -q
  git -C "$core" add -A
  git -C "$core" commit -q -m core
  for i in $(seq 1 20); do echo "line $i"; done > "$g/f.txt"
  printf 'build/\n' > "$g/.gitignore"
  cat > "$g/CMakeLists.txt" << 'EOF'
cmake_minimum_required(VERSION 3.20)
project(toy NONE)
add_custom_target(copy_f ALL
  COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_SOURCE_DIR}/f.txt ${CMAKE_BINARY_DIR}/f.txt
  COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_SOURCE_DIR}/external/arm-recomp-core/n.txt
          ${CMAKE_BINARY_DIR}/n.txt)
enable_testing()
add_test(NAME toy_built
  COMMAND ${CMAKE_COMMAND} -E compare_files ${CMAKE_SOURCE_DIR}/f.txt ${CMAKE_BINARY_DIR}/f.txt)
add_test(NAME toy_built_core
  COMMAND ${CMAKE_COMMAND} -E compare_files ${CMAKE_SOURCE_DIR}/external/arm-recomp-core/n.txt
          ${CMAKE_BINARY_DIR}/n.txt)
EOF
  git -C "$g" -c init.defaultBranch=main init -q
  # (a warning about the embedded repository, which becomes a gitlink)
  git -C "$g" add -A 2> /dev/null
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
  check "the A/B build says, at the end, what it leaves in gbarecomp/" \
    said "gbarecomp/ is left without 0002"
  check "... and releases the lock it held" test ! -L "$root/build/gbarecomp-patches/lock"
  run_ok "the next normal build" "$engine"
  check "... restores the full series" has_ab
  check "... and rebuilds build/gbarecomp from it" has_line "$root/build/gbarecomp/f.txt" "line 12 B"
  check "... and leaves the A/B build as it was" lacks_line "$ab/f.txt" "line 12 B"
  run_ok "MRA_WITHOUT_PATCHES=0002 selects the same A/B directory" \
    env MRA_WITHOUT_PATCHES=0002 "$engine"
  check "... (no nested without-0002/without-0002)" test ! -e "$ab/without-0002"
  run_ok "and the normal build again" "$engine"
  check "... which says nothing about a variant" not_said "is left without"
else
  skip "A/B build with 0002 left out" "cmake not found"
fi
run_fails "serve-web.sh --without 0002 serves the A/B bundle" "$root/scripts/serve-web.sh" --without 0002 9999
check "... from build/without-0002/web-PRIVATE (none was built here)" \
  said "no bundle in build/without-0002/web-PRIVATE"

# --- Hand edits ---------------------------------------------------------------

# Discarding them the way the refusal message says. (`git checkout -- f.txt`
# would also drop what 0001 and 0002 change in f.txt.)
set_line "$g/f.txt" 11 "line 11 by hand"
echo "notes" > "$g/notes.txt"
discard() { "$apply" --diff | git -C "$g" apply -R; }
run_ok "the refusal message's way to discard hand edits" discard
clean_series() { [ ! -e "$g/notes.txt" ] && has_ab && "$apply" --check > /dev/null 2>&1; }
check "... leaves exactly the series" clean_series
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
check "... and says the tree is now the series" said "is now the pin plus 0001, 0002, 0003"
run_ok "the series with 0003 is in place" "$apply" --check
{ printf 'Toy patch C: line 5 (header).\n\n'; cat "$root/patches/gbarecomp/0003-c.patch"; } > "$work/c"
mv "$work/c" "$root/patches/gbarecomp/0003-c.patch"
run_ok "a header added to 0003 is accepted" "$apply"
set_line "$g/f.txt" 6 "line 6 by hand"
run_ok "--write-patch refreshes 0003 (path relative to the current directory)" \
  in_dir "$root" "$apply" --write-patch patches/gbarecomp/0003-c.patch
check "... keeps its header" has_line "$root/patches/gbarecomp/0003-c.patch" "Toy patch C: line 5 (header)."
blank_under_header() {
  [ -z "$(sed -n 2p "$root/patches/gbarecomp/0003-c.patch")" ] &&
    sed -n 3p "$root/patches/gbarecomp/0003-c.patch" | grep -q '^diff --git '
}
check "... with the blank line under it" blank_under_header
check "... and holds both edits" \
  file_matches "$root/patches/gbarecomp/0003-c.patch" "^+line 5 by hand" "^+line 6 by hand"
run_ok "the refreshed series is in place" "$apply" --check

# --- Refreshing a patch that a later one stacks on ---------------------------

# The series is 0001 (line 10), 0002 (line 12 and sub/new.txt, on top of
# 0001) and 0003 (lines 5 and 6).
p=$root/patches/gbarecomp
for n in 0001-a 0002-b 0003-c; do cp "$p/$n.patch" "$work/$n.orig"; done
same_patch() { cmp -s "$p/$1.patch" "$work/$1.orig"; }
run_ok "--write-patch 0003 with nothing changed" "$apply" --write-patch "$p/0003-c.patch"
check "... leaves it byte for byte, the blank line under its header included" same_patch 0003-c
run_ok "--write-patch 0001, which 0002 stacks on, with nothing changed" \
  "$apply" --write-patch "$p/0001-a.patch"
check "... leaves it byte for byte" same_patch 0001-a
set_line "$g/f.txt" 18 "line 18 by hand"
run_ok "--write-patch 0001 with an edit away from 0002's lines" "$apply" --write-patch "$p/0001-a.patch"
check "... takes the later patches out of the tree first" said "(0002, 0003 taken out of the tree first)"
check "... puts the edit in 0001" file_matches "$p/0001-a.patch" "^+line 10 A" "^+line 18 by hand"
later_unchanged() { same_patch 0002-b && same_patch 0003-c; }
check "... leaves 0002 and 0003 as they were" later_unchanged
run_ok "... and the series gives the tree" "$apply" --check
set_line "$g/f.txt" 18 "line 18"
run_ok "--write-patch 0001 with the edit undone" "$apply" --write-patch "$p/0001-a.patch"
check "... gives back the original 0001" same_patch 0001-a

set_line "$g/f.txt" 11 "line 11 by hand"
cp "$g/f.txt" "$work/edited"
run_fails "--write-patch 0001 with an edit among 0002's context lines stops" \
  "$apply" --write-patch "$p/0001-a.patch"
check "... naming both patches" said_all "overlap 0002-b.patch" "comes after 0001-a.patch"
unchanged_0001() { same_patch 0001-a && cmp -s "$g/f.txt" "$work/edited"; }
check "... with 0001 and the tree as they were" unchanged_0001
# The way patches/gbarecomp/README.md describes: leave 0002 out, edit, save
# 0001, then redo 0002 on top of it.
set_line "$g/f.txt" 11 "line 11"
run_ok "the README's way: --without 0002" "$apply" --without 0002
set_line "$g/f.txt" 11 "line 11 by hand"
run_ok "... the edit, then --write-patch 0001 --without 0002" \
  "$apply" --write-patch "$p/0001-a.patch" --without 0002
check "... puts the edit in 0001" file_matches "$p/0001-a.patch" "^+line 10 A" "^+line 11 by hand"
run_fails "... after which 0002 no longer applies" "$apply"
check "... which the script says" said "0002-b.patch does not apply on top of"
run_fails "... git apply --reject puts back the parts of 0002 that still apply" \
  git -C "$g" apply --reject "$p/0002-b.patch"
check "... (sub/new.txt)" test -f "$g/sub/new.txt"
set_line "$g/f.txt" 12 "line 12 B"
rm -f "$g/f.txt.rej"
run_ok "... the rest by hand, then --write-patch 0002" "$apply" --write-patch "$p/0002-b.patch"
check "... which takes 0003 out of the tree first" said "(0003 taken out of the tree first)"
run_ok "... and the refreshed series is in place" "$apply"
check "... as it is" said "(already in place)"
for n in 0001-a 0002-b 0003-c; do cp "$work/$n.orig" "$p/$n.patch"; done
run_ok "back to the original patches" "$apply"
check "... from the tree the script last wrote" said "as this script last wrote it"
has_abc() { has_ab && has_line "$g/f.txt" "line 5 by hand" && has_line "$g/f.txt" "line 11"; }
check "... which has 0001, 0002 and 0003 again" has_abc

# --- Leaving out a patch that a later one stacks on --------------------------

run_fails "--without 0001 stops, since 0002 stacks on it" "$apply" --without 0001
check "... naming both, and what to do" \
  said_all "0002-b.patch does not apply without 0001, which it stacks on" "(--without 0002)"
check "... before writing anything" has_abc
run_ok "--without 0001 --without 0002" "$apply" --without 0001 --without 0002
c_only() { lacks_line "$g/f.txt" "line 10 A" && lacks_b && has_line "$g/f.txt" "line 5 by hand"; }
check "... leaves 0003 only" c_only
check "... and says the tree stays like this" said "stays like this until the next normal"
rm -rf "$root/build"
run_fails "with two patches left out and the stamp deleted, the tree is not recognized" "$apply"
check "... and the message says to run the same --without again" \
  said_all "with the same --without options instead" "which would save a patch that undoes them"
check "... before writing anything" c_only
run_ok "the same --without options again" "$apply" --without 0001 --without 0002
check "... find the tree in place" said "(already in place)"
run_ok "after which a normal run restores the series" "$apply"
check "... all of it" has_abc

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

# --- One build or switch at a time --------------------------------------------

lock=$root/build/gbarecomp-patches/lock
check "no run leaves the lock behind" test ! -L "$lock"
# Another script that holds the lock for two seconds.
# shellcheck disable=SC2016  # expanded by the inner bash
bash -c '. "$1/scripts/lib/common.sh"; lock_checkout; : > "$2"; sleep 2' holder "$root" "$work/held" &
holder=$!
i=0
while [ ! -e "$work/held" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
run_ok "a switch while another script holds the lock" "$apply" --without 0002
wait "$holder" || true
check "... waits for it, and says so" said "waiting for holder (pid $holder"
check "... then switches" a_only
check "... and releases the lock" test ! -L "$lock"
true &
dead=$!
wait "$dead"
mkdir -p "$(dirname "$lock")"
ln -s "$dead 0-0-0 build-native.sh 00:00:00" "$lock"
run_ok "a lock left by a process that is gone" "$apply"
check "... is removed, with a warning" said "removing a stale lock: build-native.sh (pid $dead"
check "... and the switch happens" has_ab
ln -s "$$ 0-0-0 test 00:00:00" "$lock"
run_ok "--check does not wait for the lock (held by this test)" "$apply" --check
rm -f "$lock"
mkdir "$lock"
run_fails "a directory in the lock's place stops a switch" "$apply"
check "... with a message" said "is a directory, not a lock these scripts made"
rmdir "$lock"

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

# --- The commit this repository records for gbarecomp -------------------------

# The root records the toy's pin as a submodule would (a gitlink in its
# index), then another commit.
git -C "$root" update-index --add --cacheinfo "160000,$(git -C "$g" rev-parse HEAD),gbarecomp"
run_ok "--check passes when gbarecomp is at the recorded commit" "$apply" --check
git -C "$root" update-index --cacheinfo "160000,$(git -C "$root" rev-parse HEAD),gbarecomp"
run_fails "--check fails when it is not" "$apply" --check
check "... and says why" said "but this repository records"
run_ok "a normal run goes on" "$apply"
check "... with a warning" said "warning: gbarecomp has .* checked out, but this repository records"
git -C "$root" update-index --force-remove gbarecomp
run_ok "without the gitlink, --check passes again" "$apply" --check

# --- A nested submodule off its commit ---------------------------------------

# The toy gets a nested repository, recorded at its second commit.
run_ok "--reverse, to add a commit to the toy" "$apply" --reverse
nest=$g/ext
git -C "$g" -c init.defaultBranch=main init -q ext
echo one > "$nest/n.txt"
git -C "$nest" add n.txt
git -C "$nest" commit -q -m one
echo two > "$nest/n.txt"
git -C "$nest" commit -q -a -m two
git -C "$g" add ext 2> /dev/null # (a warning about the embedded repository)
git -C "$g" commit -q -m "nested repository"
run_ok "the series applies on the new pin" "$apply"
git -C "$nest" checkout -q HEAD~1
run_fails "--write-patch stops when a nested submodule is off its commit" \
  "$apply" --write-patch "$work/nested.patch"
check "... with a message" said "nested submodules of gbarecomp are not at their pinned commit"
check "... and writes nothing" test ! -e "$work/nested.patch"
run_fails "--diff stops too" "$apply" --diff
check "... with the same message" said "nested submodules of gbarecomp are not at their pinned commit"
run_fails "and so does a normal run" "$apply"
git -C "$nest" checkout -q main
run_ok "with it back, the series is in place" "$apply" --check

# --- The nested series (patches/arm-recomp-core) ----------------------------

# The toy's external/arm-recomp-core gets a series of its own, as gbarecomp
# has: 0001 edits line 10 of n.txt, 0002 (written on top of 0001) line 12
# and adds sub2/new.txt. gbarecomp's series (0001, 0002, 0003-d) stays.
core=$g/external/arm-recomp-core
np=$root/patches/arm-recomp-core
mkdir -p "$np"
set_line "$core/n.txt" 10 "core 10 NA"
{ printf 'Toy nested patch A: line 10.\n\n'; git -C "$core" diff; } > "$np/0001-na.patch"
git -C "$core" add n.txt
set_line "$core/n.txt" 12 "core 12 NB"
mkdir -p "$core/sub2"
echo "added by NB" > "$core/sub2/new.txt"
git -C "$core" add -N sub2/new.txt
{ printf 'Toy nested patch B: line 12 and sub2/new.txt, on top of A.\n\n'; git -C "$core" diff; } > "$np/0002-nb.patch"
git -C "$core" reset -q --hard
rm -rf "$core/sub2"
has_na() { has_line "$core/n.txt" "core 10 NA"; }
has_nb() { has_line "$core/n.txt" "core 12 NB" && [ -f "$core/sub2/new.txt" ]; }
lacks_nb() { lacks_line "$core/n.txt" "core 12 NB" && [ ! -e "$core/sub2" ]; }
core_clean() { [ -z "$(git -C "$core" status --porcelain)" ]; }
gbarecomp_full() { has_ab && has_line "$g/f.txt" "line 15 D"; }
both_full() { has_na && has_nb && gbarecomp_full; }

run_fails "--check with the nested series not applied fails" "$apply" --check
check "... says so for the nested tree" said "NO: gbarecomp/external/arm-recomp-core is the pin, not the pin plus 0001, 0002"
check "... and OK for gbarecomp" said "^OK: gbarecomp is the pin plus 0001, 0002, 0003"
run_ok "a normal run applies the nested series" "$apply"
check "... both nested patches, on top of gbarecomp's series" both_full
check "... and says which series it is" said "arm-recomp-core [0-9a-f]*: the pin plus 0001, 0002"
check "... with gbarecomp's series in place" said "(up to date)"
run_ok "--check passes with both series applied" "$apply" --check
check "... and says OK for each" said_all "^OK: gbarecomp is" "^OK: gbarecomp/external/arm-recomp-core is the pin plus 0001, 0002"
touch -t 200001010000 "$core/n.txt" "$core/sub2/new.txt"
touch -t 200101010000 "$work/ref"
run_ok "re-applies" "$apply"
check "... writing nothing" not_newer "$core/n.txt" "$core/sub2/new.txt"
run_ok "--reverse restores both pins" "$apply" --reverse
check "... the nested tree too, sub2/ included" core_clean
check "... and gbarecomp's" clean_status
run_ok "applied again" "$apply"
check "... both series" both_full

run_ok "--without arm-recomp-core/0002" "$apply" --without arm-recomp-core/0002
na_only() { has_na && lacks_nb && gbarecomp_full; }
check "... leaves out the nested 0002 only" na_only
check "... and says so" said "left out .*0002-nb.patch"
run_ok "--check --without arm-recomp-core/0002 passes" "$apply" --check --without arm-recomp-core/0002
run_ok "--without patches/arm-recomp-core/0002-nb.patch names the same patch" \
  "$apply" --check --without "$np/0002-nb.patch"
run_ok "--without 0003 is gbarecomp's 0003" "$apply" --without 0003
d_out_core_full() { has_ab && lacks_line "$g/f.txt" "line 15 D" && has_na && has_nb; }
check "... and leaves the nested series whole" d_out_core_full
run_fails "an unknown nested patch stops" "$apply" --without arm-recomp-core/0009
check "... with a message" said "no patch in patches/arm-recomp-core matches 'arm-recomp-core/0009'"
run_fails "an unqualified name of a nested patch stops" "$apply" --without 0002-nb
check "... and says how to name it" said "qualify the name: arm-recomp-core/0002-nb"
check "... before writing anything" d_out_core_full
# A mistyped series must not fall back to gbarecomp's patch of that number.
run_fails "a name in an unknown series stops" "$apply" --without arm-recomp/0002
check "... with a message" said "unknown patch series 'arm-recomp' in 'arm-recomp/0002'"
run_fails "... also when gbarecomp has a patch of that number" "$apply" --without foo/0003
check "... before writing anything" d_out_core_full
run_fails "... and --check stops too" "$apply" --check --without foo/0003
check "... with the same message" said "unknown patch series 'foo' in 'foo/0003'"
run_ok "a normal run restores both" "$apply"
check "... series" both_full
run_ok "a relative path to a nested patch, from its directory" \
  in_dir "$np" "$apply" --without ./0002-nb.patch
check "... names the nested 0002" na_only
run_ok "a normal run restores both" "$apply"
check "... series" both_full
rm -rf "$root/build"
run_ok "--without arm-recomp-core/0002 with no stamps" "$apply" --without arm-recomp-core/0002
rm -rf "$root/build"
run_ok "with the stamps deleted, a leading part of the nested series is recognized" "$apply"
check "... and it says where it came from" said "arm-recomp-core: the pin plus 0001, 0002 (was the pin plus 0001)"

# Hand edits in the nested tree.
set_line "$core/n.txt" 5 "core 5 by hand"
cp "$core/n.txt" "$work/core-edited"
run_fails "a hand edit in the nested tree stops the script" "$apply"
check "... naming the nested tree and the file" \
  said_all "gbarecomp/external/arm-recomp-core has changes that no known patch series explains" "n.txt"
check "... and keeps the edit" cmp -s "$core/n.txt" "$work/core-edited"
run_fails "--check reports it" "$apply" --check
if command -v cmake > /dev/null 2>&1; then
  run_fails "a build stops too" "$root/scripts/test-engine.sh"
  check "... and keeps the edit" cmp -s "$core/n.txt" "$work/core-edited"
fi
run_ok "--diff" "$apply" --diff
nested_diff() { said "^+++ b/external/arm-recomp-core/n.txt" && said "^+core 5 by hand" && ! said "core 12 NB"; }
check "--diff shows the nested edit only, with its path in gbarecomp" nested_diff
discard_all() { "$apply" --diff | git -C "$g" apply -R; }
run_ok "the --diff output undoes it with git -C gbarecomp apply -R" discard_all
check "... which leaves exactly the series" both_full
run_ok "... as --check says" "$apply" --check

# --write-patch in the nested series.
set_line "$core/n.txt" 5 "core 5 NC"
run_ok "--write-patch patches/arm-recomp-core/0003-nc.patch" \
  "$apply" --write-patch "$np/0003-nc.patch"
nested_paths() { file_matches "$np/0003-nc.patch" "^diff --git a/n.txt b/n.txt" "^+core 5 NC"; }
check "... with paths relative to the nested repository" nested_paths
check "... and says the tree is now the series" said "is now the pin plus 0001, 0002, 0003"
run_ok "the nested series with 0003 is in place" "$apply" --check
gbarecomp_patches_unchanged() {
  local f names=""
  for f in "$root"/patches/gbarecomp/*; do names="$names ${f##*/}"; done
  [ "$names" = " 0001-a.patch 0002-b.patch 0003-d.patch" ]
}
check "gbarecomp's series was not touched" gbarecomp_patches_unchanged
set_line "$core/n.txt" 18 "core 18 by hand"
run_ok "--write-patch refreshes the nested 0001 under 0002 and 0003" \
  in_dir "$root" "$apply" --write-patch patches/arm-recomp-core/0001-na.patch
check "... taking them out of the tree first" said "(0002, 0003 taken out of the tree first)"
check "... and puts the edit in 0001" file_matches "$np/0001-na.patch" "^+core 10 NA" "^+core 18 by hand"
run_ok "... and the series gives the tree" "$apply" --check
set_line "$core/n.txt" 18 "core 18"
run_ok "the edit undone, 0001 refreshed again" "$apply" --write-patch "$np/0001-na.patch"
run_fails "--write-patch with --series naming the other series stops" \
  "$apply" --write-patch "$np/0003-nc.patch" --series gbarecomp
check "... with a message" said "is a patch of the arm-recomp-core series, not of gbarecomp"
set_line "$core/n.txt" 7 "core 7 by hand"
run_ok "--write-patch FILE --series arm-recomp-core, for a FILE elsewhere" \
  "$apply" --write-patch "$work/core-extra.patch" --series arm-recomp-core
check "... writes the nested change" file_matches "$work/core-extra.patch" "^diff --git a/n.txt b/n.txt" "^+core 7 by hand"
set_line "$core/n.txt" 7 "core 7"
run_ok "with the edit undone, the series is in place" "$apply" --check

# A/B builds that leave a nested patch out.
if command -v cmake > /dev/null 2>&1; then
  engine=$root/scripts/test-engine.sh
  run_ok "A/B build: scripts/test-engine.sh --without arm-recomp-core/0003" "$engine" --without arm-recomp-core/0003
  ab=$root/build/without-arm-recomp-core-0003/gbarecomp
  ab_without_nc() { has_line "$ab/n.txt" "core 12 NB" && lacks_line "$ab/n.txt" "core 5 NC"; }
  check "... builds into build/without-arm-recomp-core-0003, without the nested 0003" ab_without_nc
  check "... and says what it leaves in gbarecomp/" said "gbarecomp/ is left without arm-recomp-core/0003"
  run_ok "an A/B build without patches of both series" "$engine" --without 0003 --without arm-recomp-core/0003
  check "... goes to build/without-0003-arm-recomp-core-0003" test -f "$root/build/without-0003-arm-recomp-core-0003/gbarecomp/n.txt"
  check "... and names both" said "gbarecomp/ is left without 0003, arm-recomp-core/0003"
  run_ok "the next normal build" "$engine"
  check "... restores both series" has_line "$core/n.txt" "core 5 NC"
  check "... and builds from them" has_line "$root/build/gbarecomp/n.txt" "core 5 NC"
else
  skip "A/B builds without a nested patch" "cmake not found"
fi

# The nested repository off its pinned commit, or recorded at another one.
# The commit holds only moved.txt: the series' changes stay in the working
# tree, outside the nested repository's index.
echo "moved" > "$core/moved.txt"
git -C "$core" add moved.txt
git -C "$core" commit -q -m moved
run_fails "a nested repository moved to another commit stops gbarecomp's series" "$apply"
check "... with a message" said "nested submodules of gbarecomp are not at their pinned commit"
run_fails "--check reports it" "$apply" --check
git -C "$core" reset -q HEAD~1
rm "$core/moved.txt"
run_ok "back at its commit, the series are in place" "$apply" --check
core_pin=$(git -C "$core" rev-parse HEAD)
git -C "$g" update-index --cacheinfo "160000,$(git -C "$g" rev-parse HEAD),external/arm-recomp-core"
run_fails "--check fails when gbarecomp's index records another commit for it" "$apply" --check
check "... and says why" said "gbarecomp/external/arm-recomp-core has .* checked out, but gbarecomp records"
git -C "$g" update-index --cacheinfo "160000,$core_pin,external/arm-recomp-core"
run_ok "with the recorded commit back, --check passes" "$apply" --check
run_ok "--reverse --series arm-recomp-core restores the nested pin only" "$apply" --reverse --series arm-recomp-core
nested_only_reversed() { core_clean && gbarecomp_full; }
check "... and leaves gbarecomp's series" nested_only_reversed
run_ok "and a normal run applies it again" "$apply"
check "... all of it" has_line "$core/n.txt" "core 5 NC"

echo "1..$count"
if [ "$failures" != 0 ]; then
  echo "$failures of $count checks failed" >&2
  exit 1
fi
echo "All $count checks passed"

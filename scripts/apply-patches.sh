#!/usr/bin/env bash
# Apply the patch series to gbarecomp's working tree, and to that of its
# nested submodule external/arm-recomp-core, as stacks: patches/gbarecomp/
# *.patch in name order, each on top of gbarecomp's pinned commit plus the
# patches before it, then patches/arm-recomp-core/*.patch the same way on
# top of the commit gbarecomp pins for arm-recomp-core. Never commits inside
# either repository.
#
#   scripts/apply-patches.sh            make each tree its pin plus its series
#   scripts/apply-patches.sh --check    report whether they are (exit 0) or
#                                       not (exit 1); change nothing
#   scripts/apply-patches.sh --reverse  restore the pins
#   scripts/apply-patches.sh --diff     print what the trees have on top of
#                                       their pin plus their series, as one
#                                       patch relative to gbarecomp/
#   scripts/apply-patches.sh --write-patch FILE
#                                       save a tree's changes as FILE,
#                                       keeping FILE's header. FILE's
#                                       directory picks the series
#                                       (patches/SERIES/), gbarecomp
#                                       elsewhere unless --series says. For
#                                       a FILE in patches/SERIES/, its place
#                                       in the series decides the base: the
#                                       pin plus the patches before it, with
#                                       the patches after it taken out of
#                                       the tree
#
#   --without NAME   leave a patch out: its number (0003) or file name, and
#                    for the nested series arm-recomp-core/NUMBER. Can be
#                    repeated. The build scripts take it too, and build into
#                    build/without-NAME/; their next normal run restores the
#                    full series.
#   --series SERIES  only this series: gbarecomp or arm-recomp-core
#   -q, --quiet      print nothing unless a tree changes
#
# Each series is applied to a scratch index, and only the files whose
# content changes are written. A tree may start from any state the script
# can explain: the pin, a leading part of the series, the series with one
# patch left out, what the script last wrote (its stamp, in
# build/gbarecomp-patches/, the nested series' in a subdirectory), or the
# series of one of the last 100 commits of the current branch that changed
# its patch directory. Anything else is a hand edit: the script stops before
# writing anything in that tree and lists the files. Builds and switches in
# one checkout run one at a time (lock_checkout). See
# patches/gbarecomp/README.md.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

MODE=apply
QUIET=0
OUT=""
ONLY=""
ARGS=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check ;;
    --reverse) MODE=reverse ;;
    --diff) MODE="diff" ;;
    --write-patch) [ $# -ge 2 ] || die "--write-patch needs a file"; MODE="write"; OUT=$2; shift ;;
    --write-patch=*) MODE="write"; OUT=${1#*=} ;;
    --without) [ $# -ge 2 ] || die "--without needs a patch name or number"; add_without "$2"; shift ;;
    --without=*) add_without "${1#*=}" ;;
    --series) [ $# -ge 2 ] || die "--series needs a series name"; ONLY=$2; shift ;;
    --series=*) ONLY=${1#*=} ;;
    -q | --quiet) QUIET=1 ;;
    -h | --help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
[ "$MODE" != write ] || [ -n "$OUT" ] || die "--write-patch needs a file"
if [ -n "$ONLY" ]; then series_repo "$ONLY" > /dev/null || exit 1; fi
if [ "$MODE" = write ]; then
  case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
  [ -d "$(dirname "$OUT")" ] || die "no such directory: $(dirname "$OUT")"
fi

require_submodule
# Set by a calling git hook, these would point git at another repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX

# --- Top level: one run of this script per series ----------------------------

# The script runs itself once per series, with _MRA_APPLY_SERIES naming it,
# so that each series gets the same checks and the same messages. The modes
# that write hold the lock here, and the runs below share it.
if [ -z "${_MRA_APPLY_SERIES:-}" ]; then
  # Every --without name, checked before any tree is touched.
  without_patch_list > /dev/null || exit 1
  run_list=$MRA_PATCH_SERIES
  if [ "$MODE" = write ]; then
    picked=""
    for s in $MRA_PATCH_SERIES; do
      d=$(series_patch_dir "$s")
      if [ -d "$d" ] && [ "$(dirname "$OUT")" -ef "$d" ]; then picked=$s; fi
    done
    if [ -n "$picked" ] && [ -n "$ONLY" ] && [ "$picked" != "$ONLY" ]; then
      die "$(rel "$OUT") is a patch of the $picked series, not of $ONLY"
    fi
    run_list=${picked:-${ONLY:-gbarecomp}}
  elif [ -n "$ONLY" ]; then
    run_list=$ONLY
  fi
  case "$MODE" in apply | reverse | write) lock_checkout ;; esac
  status=0
  for s in $run_list; do
    rc=0
    _MRA_APPLY_SERIES=$s "$MRA_ROOT/scripts/apply-patches.sh" ${ARGS[@]+"${ARGS[@]}"} || rc=$?
    [ "$rc" != 0 ] || continue
    status=$rc
    # --check and --diff go on with the next series; the modes that write
    # stop at the first series that refuses, before touching the next one.
    case "$MODE" in check | diff) ;; *) exit "$rc" ;; esac
  done
  exit "$status"
fi

# --- One series --------------------------------------------------------------

series=$_MRA_APPLY_SERIES
sub=$(series_repo "$series")
MRA_PATCH_DIR=$(series_patch_dir "$series")
# gbarecomp's path to the nested repository, for --diff.
nested_prefix=""
[ "$series" = gbarecomp ] || nested_prefix=${sub#"$GBARECOMP_DIR"/}/

# A nested repository must be a checkout of its own. Without one (a
# submodule that was never initialized), git would work on gbarecomp
# instead: an empty series has nothing to do, any other one stops.
own_checkout() {
  local top
  [ -d "$sub" ] || return 1
  top=$(git -C "$sub" rev-parse --show-toplevel 2> /dev/null) || return 1
  [ "$(cd "$top" && pwd -P)" = "$(cd "$sub" && pwd -P)" ]
}
if ! own_checkout; then
  [ -n "$(patch_series "$series")" ] || exit 0
  die "$(rel "$sub") is not a git checkout of its own, so patches/$series cannot be applied to it. Run scripts/setup.sh first."
fi

pin=$(git -C "$sub" rev-parse --verify --quiet 'HEAD^{commit}') ||
  die "$(rel "$sub") has no commit checked out"
pin_tree=$(git -C "$sub" rev-parse 'HEAD^{tree}')
short_pin=$(git -C "$sub" rev-parse --short HEAD)
real_objects=$(git -C "$sub" rev-parse --path-format=absolute --git-path objects) ||
  die "git 2.31 or newer is required"

state_dir=$(series_state_dir "$series")
mkdir -p "$state_dir/objects"
state=$(cd "$state_dir" && pwd)
stamp=$state/stamp
objects=$state/objects
tmp=$(mktemp -d "$state/run.XXXXXX")
# shellcheck disable=SC2317  # called through at_exit
remove_tmp() { rm -rf "$tmp"; }
at_exit remove_tmp
# The modes that write wait for any build or switch in progress (the top
# level already holds the lock: this returns at once).
case "$MODE" in apply | reverse | write) lock_checkout ;; esac

# The pin is the commit checked out in the repository. When the repository
# above it records another one (a checkout or a pull that moved it without
# `git submodule update`), say so: the series is not applied to the pin the
# repository builds. gbarecomp's commit is recorded by this repository,
# arm-recomp-core's by gbarecomp.
if [ "$series" = gbarecomp ]; then
  above=$MRA_ROOT
  above_name="this repository"
else
  above=$GBARECOMP_DIR
  above_name=$(rel "$GBARECOMP_DIR")
fi
recorded_pin() {
  local top
  top=$(git -C "$above" rev-parse --show-toplevel 2> /dev/null) || return 0
  [ "$(cd "$top" && pwd -P)" = "$(cd "$above" && pwd -P)" ] || return 0
  git -C "$above" ls-files -s -- "${sub#"$above"/}" 2> /dev/null |
    awk '$1 == "160000" && $3 == "0" { print $2; exit }'
}
recorded=$(recorded_pin)
if [ -n "$recorded" ] && [ "$recorded" != "$pin" ]; then
  moved="$(rel "$sub") has $short_pin checked out, but $above_name records $(printf '%.7s' "$recorded") for it"
  back="To go back to the recorded commit: scripts/apply-patches.sh --reverse, then scripts/setup.sh. To move the pin instead: patches/gbarecomp/README.md, \"Moving the pin\"."
  if [ "$MODE" = check ]; then
    echo "NO: $moved. $back"
    exit 1
  fi
  warn "$moved, and the series is applied to what is checked out. $back"
fi

# git in the series' repository, with the objects this script creates
# (scratch indexes, the trees it compares) kept in build/: nothing is added
# to that repository. Never use it for another repository, such as a nested
# submodule: these variables would apply there too. (The nested series runs
# in a process of its own, with its own objects.)
sgit() {
  GIT_OBJECT_DIRECTORY=$objects GIT_ALTERNATE_OBJECT_DIRECTORIES=$real_objects \
    git -C "$sub" "$@"
}
# sgit_idx INDEX ARGS...: the same, on a scratch index file.
sgit_idx() {
  local idx=$1
  shift
  GIT_INDEX_FILE=$idx sgit "$@"
}

# Lists of patch names are strings of words: names hold no white space.
words() {
  local w out=""
  for w in $1; do out="$out${out:+ }$w"; done
  printf '%s\n' "$out"
}
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
# first_names N: the first N names of the full series.
first_names() {
  local n out="" i=0
  for n in $all_names; do
    [ "$i" -lt "$1" ] || break
    out="$out${out:+ }$n"
    i=$((i + 1))
  done
  printf '%s\n' "$out"
}

# short_name NAME: 0003 for 0003-some-fix.patch.
short_name() {
  case "$1" in
    [0-9]*-*) printf '%s\n' "${1%%-*}" ;;
    *) printf '%s\n' "${1%.patch}" ;;
  esac
}

# opt_name NAME: how --without names the patch: 0003, or
# arm-recomp-core/0001 in the nested series.
opt_name() { patch_label "$series" "$1"; }

# short_list NAMES: "0001, 0002".
short_list() {
  local n out=""
  for n in $1; do
    out="$out${out:+, }$(short_name "$n")"
  done
  printf '%s\n' "$out"
}

# describe NAMES: "the pin" or "the pin plus 0001, 0002".
describe() {
  local out
  out=$(short_list "$1")
  if [ -z "$out" ]; then echo "the pin"; else echo "the pin plus $out"; fi
}

# sorts_after A B: A comes after B in the series' order (LC_ALL=C sort).
sorts_after() {
  [ "$1" != "$2" ] &&
    [ "$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort | tail -n 1)" = "$1" ]
}

# The tree of the working tree as it is: tracked files, and new files that
# the repository's .gitignore does not exclude. A nested repository counts
# as the commit it has checked out, whatever its working tree holds.
worktree_tree() {
  local idx=$tmp/worktree.idx
  rm -f "$idx"
  sgit_idx "$idx" read-tree HEAD
  sgit_idx "$idx" add -A
  sgit_idx "$idx" write-tree
}

# Nested repositories that have a series of their own (in gbarecomp,
# external/arm-recomp-core): their content is that series' business, and
# only a commit other than the pinned one counts here.
managed=""
for s in $MRA_PATCH_SERIES; do
  r=$(series_repo "$s")
  case "$r" in "$sub"/?*) managed="$managed${managed:+ }${r#"$sub"/}" ;; esac
done

# Nested submodules that are not at the commit the repository pins or (for
# one without a series) have local changes: no patch series explains those.
changed_submodules() {
  git -C "$sub" diff-index --ignore-submodules=none HEAD |
    awk -v managed="$managed" '
      BEGIN { n = split(managed, m, " "); for (i = 1; i <= n; i++) own[m[i]] = 1 }
      $1 == ":160000" || $2 == "160000" {
        same = ($3 == $4)
        sub(/^[^\t]*\t/, "")
        if (same && ($0 in own)) next
        printf "%s ", $0
      }'
}

# Identity of a series: its file names and contents, in order.
series_id() {
  local n
  for n in "$@"; do
    printf '%s %s\n' "$n" "$(git hash-object --no-filters -- "$MRA_PATCH_DIR/$n")"
  done | git hash-object --stdin
}

# series_trees strict|partial INDEX NAME...: apply the patches in order on
# the pin, in a scratch index, and print the tree after each one. At a patch
# that does not apply, "strict" stops the script with git's message and
# "partial" stops quietly.
series_trees() {
  local how=$1 idx=$2 n names
  shift 2
  names="$*"
  rm -f "$idx"
  sgit_idx "$idx" read-tree HEAD
  for n in "$@"; do
    if ! sgit_idx "$idx" apply --cached --whitespace=nowarn -- "$MRA_PATCH_DIR/$n" 2> "$tmp/apply.err"; then
      [ "$how" = strict ] || return 0
      sed 's/^/  /' "$tmp/apply.err" >&2
      apply_failed "$n" "$names"
    fi
    sgit_idx "$idx" write-tree
  done
}

# apply_failed NAME NAMES: stop because patch NAME of the series NAMES does
# not apply. When NAMES leaves out patches before NAME (--without, or the
# FILE of --write-patch) and NAME applies with them, NAME stacks on them.
apply_failed() {
  local n=$1 names=$2 m prefix="" left=""
  for m in $all_names; do
    [ "$m" != "$n" ] || break
    prefix="$prefix $m"
    in_list "$m" "$names" || left="$left${left:+ }$m"
  done
  # shellcheck disable=SC2086  # names are split on purpose (no white space)
  if [ -n "$left" ] && [ -n "$(series_result $prefix "$n")" ]; then
    left=$(short_list "$left")
    die "$n does not apply without $left, which it stacks on. Leave it out too (--without $(opt_name "$n")), or refresh it so that it applies without $left (patches/gbarecomp/README.md). Nothing was changed in $(rel "$sub")."
  fi
  die "$n does not apply on top of $series $short_pin plus the patches before it. Refresh it or drop it (patches/gbarecomp/README.md). Nothing was changed in $(rel "$sub")."
}

# series_result NAME...: the tree the series gives, or nothing when one of
# its patches does not apply.
series_result() {
  local trees count
  trees=$(series_trees partial "$tmp/other.idx" "$@")
  count=$(printf '%s' "$trees" | grep -c . || true)
  if [ "$count" = $# ]; then last_tree "$trees"; fi
}

# last_tree TREES: the result of a series, the pin for an empty one.
last_tree() {
  if [ -n "$1" ]; then printf '%s\n' "${1##*$'\n'}"; else printf '%s\n' "$pin_tree"; fi
}

# A new file that the repository ignores would never show in worktree_tree.
check_not_ignored() {
  local path
  sgit diff-tree -r -z --name-only --diff-filter=A "$pin_tree" "$1" |
    while IFS= read -r -d '' path; do
      if git -C "$sub" check-ignore -q --no-index -- "$path"; then
        die "the series adds $path, which the .gitignore of $(rel "$sub") excludes, so this script cannot track it. Put the file elsewhere."
      fi
    done
}

stamp_get() {
  if [ -f "$stamp" ]; then sed -n "s/^$1=//p" "$stamp" | head -n 1; fi
}

# write_stamp STATE TREE [FROM]
write_stamp() {
  {
    echo "# Written by scripts/apply-patches.sh: the $series tree it last produced."
    echo "pin=$pin"
    echo "series=$target_id"
    echo "patches=$target_names"
    echo "without=$without_names"
    echo "tree=$2"
    echo "state=$1"
    if [ $# -ge 3 ]; then echo "from=$3"; fi
  } > "$tmp/stamp"
  mv -f "$tmp/stamp" "$stamp"
}

have_tree() { sgit cat-file -e "$1^{tree}" 2> /dev/null; }

# is_mix TREE FROM TO: every path where TREE differs from TO has FROM's
# version, as after a switch from FROM to TO that was interrupted.
is_mix() {
  local tree=$1 from=$2 to=$3 path
  if ! have_tree "$from" || ! have_tree "$to"; then return 1; fi
  sgit diff-tree -r -z --name-only "$to" "$tree" | {
    while IFS= read -r -d '' path; do
      [ "$(sgit ls-tree "$tree" -- "$path")" = "$(sgit ls-tree "$from" -- "$path")" ] || exit 1
    done
  }
}

# A series committed earlier in this repository (the stamp is gone after
# build/ is deleted, and pulling may bring several new patches at once): the
# last 100 commits reachable from HEAD that changed patches/SERIES/. A
# series from another branch is not found once the stamp is gone.
explain_from_history() {
  local tree=$1 top c entries key seen="" blob ok t
  top=$(git -C "$MRA_ROOT" rev-parse --show-toplevel 2> /dev/null) || return 1
  [ "$(cd "$top" && pwd -P)" = "$(cd "$MRA_ROOT" && pwd -P)" ] || return 1
  for c in $(git -C "$MRA_ROOT" rev-list --max-count=100 HEAD -- "patches/$series" 2> /dev/null); do
    entries=$(git -C "$MRA_ROOT" ls-tree "$c" -- "patches/$series/" | grep '\.patch$' || true)
    [ -n "$entries" ] || continue
    key=$(printf '%s' "$entries" | git hash-object --stdin)
    case " $seen " in *" $key "*) continue ;; esac
    seen="$seen $key"
    rm -f "$tmp/history.idx"
    sgit_idx "$tmp/history.idx" read-tree HEAD
    ok=1
    for blob in $(printf '%s\n' "$entries" | awk '{ print $3 }'); do
      git -C "$MRA_ROOT" cat-file blob "$blob" > "$tmp/history.patch"
      if ! sgit_idx "$tmp/history.idx" apply --cached --whitespace=nowarn -- "$tmp/history.patch" 2> /dev/null; then
        ok=0
        break
      fi
    done
    [ "$ok" = 1 ] || continue
    t=$(sgit_idx "$tmp/history.idx" write-tree)
    if [ "$t" = "$tree" ]; then
      EXPLAIN="the series of commit $(git -C "$MRA_ROOT" rev-parse --short "$c")"
      return 0
    fi
  done
  return 1
}

# explain TREE: set EXPLAIN to the known state TREE is, or return 1.
EXPLAIN=""
explain() {
  local tree=$1 t i=0 n names=""
  if [ "$tree" = "$pin_tree" ]; then EXPLAIN="the pin"; return 0; fi
  if [ "$tree" = "$target_tree" ]; then EXPLAIN=$(describe "$target_names"); return 0; fi
  for t in $full_trees; do
    i=$((i + 1))
    names=$(first_names "$i")
    if [ "$t" = "$tree" ]; then EXPLAIN=$(describe "$names"); return 0; fi
  done
  if [ "$(stamp_get pin)" = "$pin" ]; then
    t=$(stamp_get tree)
    if [ "$tree" = "$t" ]; then
      EXPLAIN="$(describe "$(stamp_get patches)"), as this script last wrote it"
      return 0
    fi
    if [ "$(stamp_get state)" = switching ] && is_mix "$tree" "$(stamp_get from)" "$t"; then
      EXPLAIN="halfway to $(describe "$(stamp_get patches)") (an interrupted run)"
      return 0
    fi
  fi
  # The series with one patch left out: an A/B build whose stamp is gone.
  for n in $all_names; do
    names=""
    for t in $all_names; do [ "$t" = "$n" ] || names="$names $t"; done
    # shellcheck disable=SC2086
    t=$(series_result $names)
    if [ -n "$t" ] && [ "$t" = "$tree" ]; then
      EXPLAIN="$(describe "$names") (without $(short_name "$n"))"
      return 0
    fi
  done
  explain_from_history "$tree"
}

# The known state closest to the tree, and what differs, for messages.
show_unexplained() {
  local best="" best_n="" best_desc="" t n i=0 names
  set -- "$pin_tree" "the pin"
  for t in $full_trees; do
    i=$((i + 1))
    names=$(first_names "$i")
    set -- "$@" "$t" "$(describe "$names")"
  done
  set -- "$@" "$target_tree" "$(describe "$target_names")"
  t=$(stamp_get tree)
  if [ -n "$t" ] && have_tree "$t"; then set -- "$@" "$t" "$(describe "$(stamp_get patches)")"; fi
  while [ $# -ge 2 ]; do
    n=$(sgit diff-tree -r --name-only "$1" "$W" | wc -l | tr -d ' ')
    if [ -z "$best_n" ] || [ "$n" -lt "$best_n" ]; then best=$1 best_n=$n best_desc=$2; fi
    shift 2
  done
  echo "  Compared with $best_desc:"
  sgit diff-tree -r --name-status "$best" "$W" | sed 's/^/    /'
}

refuse_hand_edit() {
  {
    echo "error: $(rel "$sub") has changes that no known patch series explains (a hand edit?). Nothing was changed in it."
    show_unexplained
    echo "  To see them: scripts/apply-patches.sh --diff --series $series."
    echo "  To keep them as a patch: scripts/apply-patches.sh --write-patch patches/$series/NNNN-name.patch"
    echo "  (on top of the full series; it keeps the header of an existing file)."
    echo "  To discard them: scripts/apply-patches.sh --diff --series $series | git -C $(rel "$GBARECOMP_DIR") apply -R"
    echo "  After an A/B build that left two or more patches out, once build/ is deleted: run"
    echo "  scripts/apply-patches.sh with the same --without options instead (not --write-patch,"
    echo "  which would save a patch that undoes them). The next normal run then restores the series."
  } >&2
  exit 1
}

# switch_tree FROM TO: rewrite the files that differ, and only those.
switch_tree() {
  local from=$1 to=$2 idx=$tmp/target.idx path dir now
  write_stamp switching "$to" "$from"
  sgit diff-tree -r -z --name-only --diff-filter=D "$from" "$to" > "$tmp/remove"
  sgit diff-tree -r -z --name-only --diff-filter=AMT "$from" "$to" > "$tmp/write"
  while IFS= read -r -d '' path; do
    rm -f "$sub/$path" || die "could not remove $path from $(rel "$sub")"
    # Directories that an earlier series added and that are now empty.
    dir=$(dirname "$path")
    while [ "$dir" != . ] && rmdir "$sub/$dir" 2> /dev/null; do
      dir=$(dirname "$dir")
    done
  done < "$tmp/remove"
  rm -f "$idx"
  sgit_idx "$idx" read-tree "$to"
  if ! sgit_idx "$idx" checkout-index -f -z --stdin < "$tmp/write"; then
    die "could not write the files above in $(rel "$sub"). Fix the cause and run the script again: it recognizes the half-written tree."
  fi
  now=$(worktree_tree)
  [ "$now" = "$to" ] ||
    die "internal error: after writing, $(rel "$sub") is not the expected tree ($now instead of $to)"
  write_stamp "done" "$to"
  written=$(tr -cd '\000' < "$tmp/write" | wc -c | tr -d ' ')
  removed=$(tr -cd '\000' < "$tmp/remove" | wc -c | tr -d ' ')
}

report() {
  local n
  [ "$QUIET" = 0 ] || return 0
  info "$series $short_pin: $(describe "$target_names")"
  for n in $all_names; do
    if in_list "$n" "$target_names"; then
      printf '  %-12s %s\n' applied "$n"
    elif [ "$MODE" = reverse ]; then
      printf '  %-12s %s\n' "not applied" "$n"
    else
      printf '  %-12s %s\n' "left out" "$n"
    fi
  done
}

# After a switch with patches left out, the last line of the output.
left_out_note() {
  [ "$QUIET" = 0 ] && [ -n "$without_names" ] || return 0
  echo "  $(rel "$sub")/ stays like this until the next normal build script or scripts/apply-patches.sh run."
}

# --- The series and the tree -------------------------------------------------

all_names=$(patch_series "$series") || exit 1
all_names=$(words "$all_names")
out_name=""
if [ "$MODE" = write ] && [ -d "$MRA_PATCH_DIR" ] &&
   [ "$(dirname "$OUT")" -ef "$MRA_PATCH_DIR" ] && in_list "${OUT##*/}" "$all_names"; then
  out_name=${OUT##*/}
fi
without_names=""
if [ "$MODE" != reverse ]; then
  without_names=$(without_patch_names "$series") || exit 1
  without_names=$(words "$without_names")
fi
target_names=""
if [ "$MODE" != reverse ]; then
  for n in $all_names; do
    in_list "$n" "$without_names" && continue
    [ "$n" = "$out_name" ] && continue
    [ -s "$MRA_PATCH_DIR/$n" ] || die "$(rel "$MRA_PATCH_DIR/$n") is empty"
    target_names="$target_names${target_names:+ }$n"
  done
fi
# shellcheck disable=SC2086  # names are split on purpose (no white space)
target_id=$(series_id $target_names)

W=$(worktree_tree)
nested=$(changed_submodules)

# --- --diff and --write-patch ------------------------------------------------

# take_out TREE NAME...: TREE with the patches NAME... taken back out, the
# last one first, in a scratch index: the tree without the patches that come
# after the FILE of --write-patch.
take_out() {
  local tree=$1 idx=$tmp/takeout.idx n reversed=""
  shift
  for n in "$@"; do reversed="$n${reversed:+ }$reversed"; done
  rm -f "$idx"
  sgit_idx "$idx" read-tree "$tree"
  for n in $reversed; do
    sgit_idx "$idx" apply --cached -R --whitespace=nowarn -- "$MRA_PATCH_DIR/$n" 2> /dev/null && continue
    if sgit_idx "$idx" apply --cached --check --whitespace=nowarn -- "$MRA_PATCH_DIR/$n" 2> /dev/null; then
      die "$(rel "$sub") does not have $n, which comes after ${OUT##*/}. If an A/B build or --without left it out, pass the same --without options to --write-patch. Nothing was written."
    fi
    die "the changes in $(rel "$sub") overlap $n (its changed lines or the three lines around them), and $n comes after ${OUT##*/} in the series: the script cannot tell which of the two they belong to. Nothing was written. Save them as a new patch at the end of the series instead, or move them into ${OUT##*/} as patches/gbarecomp/README.md describes (\"Changing a patch that a later one stacks on\")."
  done
  sgit_idx "$idx" write-tree
}

if [ "$MODE" = diff ] || [ "$MODE" = write ]; then
  [ -z "$nested" ] ||
    die "nested submodules of $(rel "$sub") are not at their pinned commit or have local changes: $nested(see git -C $(rel "$sub") submodule status). A patch cannot hold that; put them back first. Nothing was written."
  if [ "$MODE" = diff ]; then
    # shellcheck disable=SC2086
    target_trees=$(series_trees strict "$tmp/target.idx" $target_names) || exit 1
    base_tree=$(last_tree "$target_trees")
    new_tree=$W
  else
    # FILE's place in the series (its name) decides what it is written
    # against: the pin plus the patches before it. The patches after it are
    # taken out of the tree, so that the patch applies at its place and the
    # later ones still apply on top of it. A FILE outside patches/SERIES/
    # is written against the whole series.
    before_names="" after_names="" place=""
    case "$OUT" in
      *.patch)
        if [ -d "$MRA_PATCH_DIR" ] && [ "$(dirname "$OUT")" -ef "$MRA_PATCH_DIR" ]; then
          place=${OUT##*/}
        fi
        ;;
    esac
    for n in $target_names; do
      if [ -n "$place" ] && sorts_after "$n" "$place"; then
        after_names="$after_names${after_names:+ }$n"
      else
        before_names="$before_names${before_names:+ }$n"
      fi
    done
    # shellcheck disable=SC2086
    base_trees=$(series_trees strict "$tmp/target.idx" $before_names) || exit 1
    base_tree=$(last_tree "$base_trees")
    new_tree=$W
    if [ -n "$after_names" ]; then
      # shellcheck disable=SC2086
      new_tree=$(take_out "$W" $after_names) || exit 1
    fi
  fi
  diff_cmd=(sgit diff-tree -p -r --binary --no-ext-diff --src-prefix=a/ --dst-prefix=b/ "$base_tree" "$new_tree")
  if [ "$MODE" = diff ]; then
    # Paths relative to gbarecomp/, for every series, so that the output of
    # all series is one patch that `git -C gbarecomp apply` takes (git
    # writes the files of a nested repository there too).
    sgit diff-tree -p -r --binary --no-ext-diff --src-prefix="a/$nested_prefix" \
      --dst-prefix="b/$nested_prefix" "$base_tree" "$new_tree"
    exit 0
  fi
  # The header is everything above the first 'diff --git' line, blank lines
  # included, byte for byte.
  : > "$tmp/out.patch"
  if [ -f "$OUT" ]; then sed '/^diff --git /,$d' "$OUT" > "$tmp/out.patch"; fi
  if [ -s "$tmp/out.patch" ] && [ -n "$(tail -c 1 "$tmp/out.patch")" ]; then
    echo >> "$tmp/out.patch"
  fi
  has_header=0
  if grep -q '[^[:space:]]' "$tmp/out.patch"; then has_header=1; fi
  "${diff_cmd[@]}" >> "$tmp/out.patch"
  on=$(describe "$before_names")
  if [ -n "$after_names" ]; then on="$on ($(short_list "$after_names") taken out of the tree first)"; fi
  grep -q '^diff --git ' "$tmp/out.patch" ||
    die "nothing to write: $(rel "$sub") has nothing on top of $on"
  mv -f "$tmp/out.patch" "$OUT"
  info "Wrote $(rel "$OUT"): $(grep -c '^diff --git ' "$OUT") file(s) on top of $on"
  if [ "$has_header" = 0 ]; then
    warn "add a header above the first 'diff --git' line: what the patch fixes, why, and how it was tested (patches/gbarecomp/README.md)"
  fi
  if [ -n "$place" ]; then
    names=""
    for n in $(patch_series "$series"); do
      in_list "$n" "$without_names" || names="$names $n"
    done
    # shellcheck disable=SC2086
    now=$(series_result $names)
    if [ "$now" = "$W" ]; then
      info "$(rel "$sub") is now $(describe "$names")"
    else
      warn "the series with the new ${OUT##*/} does not give the current tree. scripts/apply-patches.sh --check reports the state."
    fi
  fi
  exit 0
fi

# --- --check -----------------------------------------------------------------

if [ "$MODE" = check ]; then
  # shellcheck disable=SC2086
  target_trees=$(series_trees strict "$tmp/target.idx" $target_names) || exit 1
  target_tree=$(last_tree "$target_trees")
  if [ "$W" = "$target_tree" ] && [ -z "$nested" ]; then
    report
    echo "OK: $(rel "$sub") is $(describe "$target_names")"
    exit 0
  fi
  if [ -n "$nested" ]; then
    echo "NO: nested submodules of $(rel "$sub") are not at their pinned commit or have local changes: $nested"
    exit 1
  fi
  # shellcheck disable=SC2086
  full_trees=$(series_trees partial "$tmp/full.idx" $all_names)
  if explain "$W"; then
    opts=""
    for n in $without_names; do opts="$opts --without $(opt_name "$n")"; done
    echo "NO: $(rel "$sub") is $EXPLAIN, not $(describe "$target_names")."
    echo "Run scripts/apply-patches.sh$opts to switch it."
  else
    echo "NO: $(rel "$sub") has changes that no known patch series explains (a hand edit?)."
    show_unexplained
  fi
  exit 1
fi

# --- Apply, or --reverse -----------------------------------------------------

[ -z "$nested" ] ||
  die "nested submodules of $(rel "$sub") are not at their pinned commit or have local changes: $nested(see git -C $(rel "$sub") submodule status). No patch series explains that; nothing was changed."

# Nothing to do when the stamp says this exact tree is what the series gives.
if [ "$(stamp_get state)" = "done" ] && [ "$(stamp_get pin)" = "$pin" ] &&
   [ "$(stamp_get series)" = "$target_id" ] && [ "$(stamp_get tree)" = "$W" ]; then
  report
  [ "$QUIET" = 1 ] || echo "  (up to date)"
  left_out_note
  exit 0
fi

# shellcheck disable=SC2086
target_trees=$(series_trees strict "$tmp/target.idx" $target_names) || exit 1
target_tree=$(last_tree "$target_trees")
check_not_ignored "$target_tree"
if [ "$W" = "$target_tree" ]; then
  write_stamp "done" "$W"
  report
  [ "$QUIET" = 1 ] || echo "  (already in place)"
  left_out_note
  exit 0
fi

if [ "$target_names" = "$all_names" ]; then
  full_trees=$target_trees
else
  # shellcheck disable=SC2086
  full_trees=$(series_trees partial "$tmp/full.idx" $all_names)
fi
explain "$W" || refuse_hand_edit
was=$EXPLAIN
switch_tree "$W" "$target_tree"
report
info "$series: $(describe "$target_names") (was $was): $written file(s) written, $removed removed"
left_out_note

#!/usr/bin/env bash
# Apply the gbarecomp patch series to the submodule's working tree as a
# stack: patches/gbarecomp/*.patch in name order, each on top of the pinned
# commit plus the patches before it. Never commits inside the submodule.
#
#   scripts/apply-patches.sh            make the tree the pin plus the series
#   scripts/apply-patches.sh --check    report whether it is (exit 0) or not
#                                       (exit 1); change nothing
#   scripts/apply-patches.sh --reverse  restore the pin
#   scripts/apply-patches.sh --diff     print what the tree has on top of the
#                                       pin plus the series
#   scripts/apply-patches.sh --write-patch FILE
#                                       write that difference to FILE, keeping
#                                       FILE's header; if FILE is part of the
#                                       series, the base leaves it out
#
#   --without NAME   leave a patch out: its number (0003) or file name. Can be
#                    repeated. The build scripts take it too, and build into
#                    build/without-NAME/; their next normal run restores the
#                    full series.
#   -q, --quiet      print nothing unless the tree changes
#
# The series is applied to a scratch index, and only the files whose content
# changes are written. The tree may start from any state the script can
# explain: the pin, a leading part of the series, what the script last wrote
# (its stamp, build/gbarecomp-patches/), or a series committed earlier in this
# repository. Anything else is a hand edit: the script stops before writing
# anything and lists the files. See patches/gbarecomp/README.md.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

MODE=apply
QUIET=0
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check ;;
    --reverse) MODE=reverse ;;
    --diff) MODE=diff ;;
    --write-patch) [ $# -ge 2 ] || die "--write-patch needs a file"; MODE=write; OUT=$2; shift ;;
    --write-patch=*) MODE=write; OUT=${1#*=} ;;
    --without) [ $# -ge 2 ] || die "--without needs a patch name or number"; add_without "$2"; shift ;;
    --without=*) add_without "${1#*=}" ;;
    -q | --quiet) QUIET=1 ;;
    -h | --help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
[ "$MODE" != write ] || [ -n "$OUT" ] || die "--write-patch needs a file"

require_submodule
# Set by a calling git hook, these would point git at another repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX

sub=$GBARECOMP_DIR
pin=$(git -C "$sub" rev-parse --verify --quiet 'HEAD^{commit}') ||
  die "$(rel "$sub") has no commit checked out"
pin_tree=$(git -C "$sub" rev-parse 'HEAD^{tree}')
short_pin=$(git -C "$sub" rev-parse --short HEAD)
real_objects=$(git -C "$sub" rev-parse --path-format=absolute --git-path objects) ||
  die "git 2.31 or newer is required"

mkdir -p "$MRA_PATCH_STATE_DIR/objects"
state=$(cd "$MRA_PATCH_STATE_DIR" && pwd)
stamp=$state/stamp
objects=$state/objects
tmp=$(mktemp -d "$state/run.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# git in the submodule, with the objects this script creates (scratch
# indexes, the trees it compares) kept in build/: nothing is added to the
# submodule's repository. Never use it for another repository, such as a
# nested submodule: these variables would apply there too.
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

# describe NAMES: "the pin" or "the pin plus 0001, 0002".
describe() {
  local n out=""
  for n in $1; do
    out="$out${out:+, }$(short_name "$n")"
  done
  if [ -z "$out" ]; then echo "the pin"; else echo "the pin plus $out"; fi
}

# The tree of the working tree as it is: tracked files, and new files that
# gbarecomp's .gitignore does not exclude.
worktree_tree() {
  local idx=$tmp/worktree.idx
  rm -f "$idx"
  sgit_idx "$idx" read-tree HEAD
  sgit_idx "$idx" add -A
  sgit_idx "$idx" write-tree
}

# Nested submodules (external/arm-recomp-core) that are not at the commit
# gbarecomp pins or have local changes: no patch series explains those.
changed_submodules() {
  git -C "$sub" diff-index --ignore-submodules=none HEAD |
    awk '$1 == ":160000" || $2 == "160000" { sub(/^[^\t]*\t/, ""); printf "%s ", $0 }'
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
  local how=$1 idx=$2 n
  shift 2
  rm -f "$idx"
  sgit_idx "$idx" read-tree HEAD
  for n in "$@"; do
    if ! sgit_idx "$idx" apply --cached --whitespace=nowarn -- "$MRA_PATCH_DIR/$n" 2> "$tmp/apply.err"; then
      [ "$how" = strict ] || return 0
      sed 's/^/  /' "$tmp/apply.err" >&2
      die "$n does not apply on top of gbarecomp $short_pin plus the patches before it. Refresh it or drop it (patches/gbarecomp/README.md). Nothing was changed."
    fi
    sgit_idx "$idx" write-tree
  done
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

# A new file that gbarecomp ignores would never show in worktree_tree.
check_not_ignored() {
  local path
  sgit diff-tree -r -z --name-only --diff-filter=A "$pin_tree" "$1" |
    while IFS= read -r -d '' path; do
      if git -C "$sub" check-ignore -q --no-index -- "$path"; then
        die "the series adds $path, which gbarecomp's .gitignore excludes, so this script cannot track it. Put the file elsewhere."
      fi
    done
}

stamp_get() {
  if [ -f "$stamp" ]; then sed -n "s/^$1=//p" "$stamp" | head -n 1; fi
}

# write_stamp STATE TREE [FROM]
write_stamp() {
  {
    echo "# Written by scripts/apply-patches.sh: the gbarecomp tree it last produced."
    echo "pin=$pin"
    echo "series=$target_id"
    echo "patches=$target_names"
    echo "without=$without_names"
    echo "tree=$2"
    echo "state=$1"
    if [ $# -ge 3 ]; then echo "from=$3"; fi
  } > "$stamp.tmp"
  mv -f "$stamp.tmp" "$stamp"
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
# build/ is deleted, and pulling may bring several new patches at once).
explain_from_history() {
  local tree=$1 top c entries key seen="" blob ok t
  top=$(git -C "$MRA_ROOT" rev-parse --show-toplevel 2> /dev/null) || return 1
  [ "$(cd "$top" && pwd -P)" = "$(cd "$MRA_ROOT" && pwd -P)" ] || return 1
  for c in $(git -C "$MRA_ROOT" rev-list --max-count=100 HEAD -- patches/gbarecomp 2> /dev/null); do
    entries=$(git -C "$MRA_ROOT" ls-tree "$c" -- patches/gbarecomp/ | grep '\.patch$' || true)
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
    echo "error: $(rel "$sub") has changes that no known patch series explains (a hand edit?). Nothing was changed."
    show_unexplained
    echo "  To keep them as a patch: scripts/apply-patches.sh --write-patch patches/gbarecomp/NNNN-name.patch"
    echo "  (on top of the full series; it keeps the header of an existing file). To see them: --diff."
    echo "  To discard them instead: git -C $(rel "$sub") checkout -- <file>, and delete the new files."
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
  write_stamp done "$to"
  written=$(tr -cd '\000' < "$tmp/write" | wc -c | tr -d ' ')
  removed=$(tr -cd '\000' < "$tmp/remove" | wc -c | tr -d ' ')
}

report() {
  local n
  [ "$QUIET" = 0 ] || return 0
  info "gbarecomp $short_pin: $(describe "$target_names")"
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

# --- The series and the tree -------------------------------------------------

all_names=$(patch_series) || exit 1
all_names=$(words "$all_names")
out_name=""
if [ "$MODE" = write ]; then
  case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
  [ -d "$(dirname "$OUT")" ] || die "no such directory: $(dirname "$OUT")"
  if [ "$(dirname "$OUT")" -ef "$MRA_PATCH_DIR" ] && in_list "${OUT##*/}" "$all_names"; then
    out_name=${OUT##*/}
  fi
fi
without_names=""
if [ "$MODE" != reverse ]; then
  without_names=$(without_patch_names) || exit 1
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

# --- --diff and --write-patch ------------------------------------------------

if [ "$MODE" = diff ] || [ "$MODE" = write ]; then
  # shellcheck disable=SC2086
  target_trees=$(series_trees strict "$tmp/target.idx" $target_names) || exit 1
  target_tree=$(last_tree "$target_trees")
  diff_cmd=(sgit diff-tree -p -r --binary --no-ext-diff --src-prefix=a/ --dst-prefix=b/ "$target_tree" "$W")
  if [ "$MODE" = diff ]; then
    "${diff_cmd[@]}"
    exit 0
  fi
  header=""
  if [ -f "$OUT" ]; then header=$(sed '/^diff --git /,$d' "$OUT"); fi
  {
    if [ -n "$header" ]; then printf '%s\n' "$header"; fi
    "${diff_cmd[@]}"
  } > "$tmp/out.patch"
  grep -q '^diff --git ' "$tmp/out.patch" ||
    die "nothing to write: $(rel "$sub") is exactly $(describe "$target_names")"
  mv -f "$tmp/out.patch" "$OUT"
  info "Wrote $(rel "$OUT"): $(grep -c '^diff --git ' "$OUT") file(s) on top of $(describe "$target_names")"
  if [ -z "$header" ]; then
    warn "add a header above the first 'diff --git' line: what the patch fixes, why, and how it was tested (patches/gbarecomp/README.md)"
  fi
  if [ "$(dirname "$OUT")" -ef "$MRA_PATCH_DIR" ]; then
    names=""
    for n in $(patch_series); do
      in_list "$n" "$without_names" || names="$names $n"
    done
    # shellcheck disable=SC2086
    now=$(series_trees partial "$tmp/full.idx" $names)
    now=$(last_tree "$now")
    if [ "$now" = "$W" ]; then
      info "$(rel "$sub") is now the pin plus the series"
    else
      warn "the series with the new ${OUT##*/} does not give the current tree: a later patch probably overlaps it. Refresh the later patches too; scripts/apply-patches.sh --check reports the state."
    fi
  fi
  exit 0
fi

nested=$(changed_submodules)

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
    for n in $without_names; do opts="$opts --without $(short_name "$n")"; done
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
if [ "$(stamp_get state)" = done ] && [ "$(stamp_get pin)" = "$pin" ] &&
   [ "$(stamp_get series)" = "$target_id" ] && [ "$(stamp_get tree)" = "$W" ]; then
  report
  [ "$QUIET" = 1 ] || echo "  (up to date)"
  exit 0
fi

# shellcheck disable=SC2086
target_trees=$(series_trees strict "$tmp/target.idx" $target_names) || exit 1
target_tree=$(last_tree "$target_trees")
check_not_ignored "$target_tree"
if [ "$W" = "$target_tree" ]; then
  write_stamp done "$W"
  report
  [ "$QUIET" = 1 ] || echo "  (already in place)"
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
info "gbarecomp: $(describe "$target_names") (was $was): $written file(s) written, $removed removed"

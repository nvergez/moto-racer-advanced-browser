#!/usr/bin/env bash
# Apply patches/gbarecomp/*.patch, in name order, to the working tree of the
# gbarecomp submodule. Never commits inside the submodule.
#
#   scripts/apply-patches.sh             apply what is not applied yet
#   scripts/apply-patches.sh --check     report the state, change nothing
#   scripts/apply-patches.sh --reverse   take every patch back out (do this
#                                        before moving the submodule pin)
#
# Idempotent: an applied patch is detected (it reverse-applies cleanly) and
# skipped. A patch that neither applies nor reverse-applies stops the script:
# refresh it against the new pin or drop it. See patches/gbarecomp/README.md.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

MODE=apply
case "${1:-}" in
  "") ;;
  --check) MODE=check ;;
  --reverse) MODE=reverse ;;
  -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown option: $1" ;;
esac

require_submodule
patch_dir="$MRA_ROOT/patches/gbarecomp"
patches=()
for p in "$patch_dir"/*.patch; do
  [ -f "$p" ] && patches+=("$p")
done
if [ "${#patches[@]}" -eq 0 ]; then
  info "No local gbarecomp patches (patches/gbarecomp/ is empty)"
  exit 0
fi
if [ "$MODE" = reverse ]; then
  reversed=()
  i=${#patches[@]}
  while [ "$i" -gt 0 ]; do
    i=$((i - 1))
    reversed+=("${patches[$i]}")
  done
  patches=("${reversed[@]}")
fi

pin=$(git -C "$GBARECOMP_DIR" rev-parse --short HEAD)
info "gbarecomp patches ($MODE) at $pin"
for p in "${patches[@]}"; do
  name=$(basename "$p")
  if git -C "$GBARECOMP_DIR" apply --reverse --check "$p" > /dev/null 2>&1; then
    state=applied
  elif git -C "$GBARECOMP_DIR" apply --check "$p" > /dev/null 2>&1; then
    state=unapplied
  else
    die "$name neither applies nor reverts cleanly on gbarecomp $pin; refresh or drop it"
  fi
  case "$MODE:$state" in
    apply:unapplied)
      git -C "$GBARECOMP_DIR" apply "$p"
      printf '  applied          %s\n' "$name" ;;
    apply:applied) printf '  already applied  %s\n' "$name" ;;
    reverse:applied)
      git -C "$GBARECOMP_DIR" apply --reverse "$p"
      printf '  reverted         %s\n' "$name" ;;
    reverse:unapplied) printf '  not applied      %s\n' "$name" ;;
    check:applied) printf '  applied          %s\n' "$name" ;;
    check:unapplied) printf '  not applied      %s\n' "$name" ;;
  esac
done

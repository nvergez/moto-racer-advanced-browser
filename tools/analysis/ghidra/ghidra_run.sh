#!/usr/bin/env bash
# Run one GhidraScript from this directory against the analyzed program and
# print the script's own output (Ghidra's log goes to a log file).
#
# Usage: ghidra_run.sh [--project DIR | --copy DIR] [--write] SCRIPT.java [script args...]
#   default      read-only run on a throwaway clone of the shared project
#                ($MRA_GHIDRA_PROJECT_DIR, default analysis-out/ghidra), so any
#                number of runs can happen at once (Ghidra locks a project even
#                with -readOnly). Changes the script makes are discarded.
#   --project D  use the project in directory D instead (e.g. a private copy).
#   --write      save the script's changes (only on a private copy; refused on
#                the shared project).
#   --copy D     copy the shared project to D first if D does not exist yet, then
#                use it (implies --project D). Relative paths resolve under $MRA_OUT.
# Script output goes to stdout unless the script gets out=FILE. FILE is checked
# like --out in run_harness.sh: a relative path resolves under $MRA_OUT, and a
# path git would track is refused.
# Env: GHIDRA_LOG (default: a temp file; checked like out=FILE),
# GHIDRA_KEEP_LOG=1 prints its path.
# The throwaway clone and failure logs go to ${TMPDIR:-/tmp}.
set -euo pipefail
source "$(dirname "$0")/ghidra_env.sh"
proj_dir="$MRA_GHIDRA_PROJECT_DIR"
write=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project) proj_dir="$(mra_out_path "$2")"; shift 2 ;;
    --copy)
      d="$(mra_out_path "$2")"
      if [ ! -e "$d/$MRA_GHIDRA_PROJECT.gpr" ]; then
        mkdir -p "$d"
        cp -R "$MRA_GHIDRA_PROJECT_DIR/$MRA_GHIDRA_PROJECT.gpr" "$MRA_GHIDRA_PROJECT_DIR/$MRA_GHIDRA_PROJECT.rep" "$d/"
        rm -f "$d/$MRA_GHIDRA_PROJECT.lock" "$d/$MRA_GHIDRA_PROJECT.lock~"
      fi
      proj_dir="$d"; shift 2 ;;
    --write) write=1; shift ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] || { sed -n '2,20p' "$0"; exit 2; }
script="$1"; shift
# The Java side opens out=FILE as given, so resolve and check it here, before
# anything runs. Other script arguments pass through unchanged.
args=()
user_out=0
for a in "$@"; do
  case "$a" in
    out=*)
      p="$(mra_out_path "${a#out=}")"
      mkdir -p "$(dirname "$p")"
      args+=("out=$p"); user_out=1 ;;
    *) args+=("$a") ;;
  esac
done
log=""
if [ -n "${GHIDRA_LOG:-}" ]; then
  log="$(mra_out_path "$GHIDRA_LOG")"
  mkdir -p "$(dirname "$log")"
fi
# Ghidra bundles its own ListFunctions.java (Features/FunctionID/ghidra_scripts)
# and searches script dirs in an unspecified order, so a bare name can resolve
# to Ghidra's copy. Pass ours by absolute path when it exists (accepted by
# Ghidra 12.1.4 headless, although its README asks for a bare name).
[ -f "$MRA_GHIDRA_SCRIPTS/$script" ] && script="$MRA_GHIDRA_SCRIPTS/$script"
[ -e "$proj_dir/$MRA_GHIDRA_PROJECT.gpr" ] || mra_die "no project at $proj_dir (run ghidra_import.sh first)"
shared="$(cd "$MRA_GHIDRA_PROJECT_DIR" && pwd -P)"
mine="$(cd "$proj_dir" && pwd -P)"
if [ "$write" = 1 ] && [ "$shared" = "$mine" ]; then
  echo "refusing --write on the shared project; use --copy DIR" >&2; exit 2
fi
ro=(-readOnly); [ "$write" = 1 ] && ro=()
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ghidra_run.XXXXXX")"
cleanup() { case "$tmp" in */ghidra_run.*) [ "${GHIDRA_KEEP_LOG:-0}" = 1 ] || rm -rf -- "$tmp" ;; esac; }
trap cleanup EXIT
if [ "$shared" = "$mine" ]; then
  # Clone the shared project (APFS clonefile when available) and use the clone.
  mkdir -p "$tmp/proj"
  cp -cR "$proj_dir/$MRA_GHIDRA_PROJECT.gpr" "$proj_dir/$MRA_GHIDRA_PROJECT.rep" "$tmp/proj/" 2>/dev/null ||
    cp -R "$proj_dir/$MRA_GHIDRA_PROJECT.gpr" "$proj_dir/$MRA_GHIDRA_PROJECT.rep" "$tmp/proj/"
  rm -f "$tmp/proj/$MRA_GHIDRA_PROJECT.lock" "$tmp/proj/$MRA_GHIDRA_PROJECT.lock~"
  proj_dir="$tmp/proj"
fi
[ -n "$log" ] || log="$tmp/headless.log"
[ "$user_out" = 1 ] || args+=("out=$tmp/out.txt")
set +e
"$ANALYZE_HEADLESS" "$proj_dir" "$MRA_GHIDRA_PROJECT" -process "$MRA_GHIDRA_PROGRAM" -noanalysis ${ro[@]+"${ro[@]}"} \
  -scriptPath "$MRA_GHIDRA_SCRIPTS" -postScript "$script" "${args[@]}" > "$log" 2>&1
rc=$?
set -e
if [ $rc -ne 0 ] || grep -q "SCRIPT ERROR\|Unable to lock\|ERROR REPORT" "$log"; then
  if [ -z "${GHIDRA_LOG:-}" ]; then cp "$log" "${TMPDIR:-/tmp}/ghidra_run_failed.$$.log"; log="${TMPDIR:-/tmp}/ghidra_run_failed.$$.log"; fi
  echo "ghidra_run: failed (exit $rc); log: $log" >&2
  grep -n "ERROR\|Exception\|lock" "$log" | head -20 >&2
  exit 1
fi
[ "$user_out" = 0 ] && cat "$tmp/out.txt"
[ "${GHIDRA_KEEP_LOG:-0}" = 1 ] && echo "# log: $log" >&2
exit 0

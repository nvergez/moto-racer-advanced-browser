# Shared settings for the Ghidra helper scripts. Source it from bash; every
# value can be overridden from the environment before sourcing.
#   GHIDRA_HOME             Ghidra install dir (default: ~/tools/ghidra/ghidra_12.1.4_PUBLIC)
#   MRA_ROM, MRA_BIOS, MRA_OUT, MRA_REPO   see ../lib.sh
#   MRA_GHIDRA_PROJECT_DIR  directory holding the project (default: $MRA_OUT/ghidra)
#   MRA_GHIDRA_PROJECT      project name (default: mra)
#   MRA_GHIDRA_PROGRAM      program name in the project (default: recorded by
#                           ghidra_import.sh, otherwise the ROM's file name)
_ghidra_scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_ghidra_scripts_dir/../lib.sh"
: "${GHIDRA_HOME:=$HOME/tools/ghidra/ghidra_12.1.4_PUBLIC}"
: "${MRA_GHIDRA_PROJECT_DIR:=$MRA_OUT/ghidra}"
MRA_GHIDRA_PROJECT_DIR="$(mra_out_path "$MRA_GHIDRA_PROJECT_DIR")"
: "${MRA_GHIDRA_PROJECT:=mra}"
if [ -z "${MRA_GHIDRA_PROGRAM:-}" ]; then
  if [ -f "$MRA_GHIDRA_PROJECT_DIR/program-name.txt" ]; then
    MRA_GHIDRA_PROGRAM="$(cat "$MRA_GHIDRA_PROJECT_DIR/program-name.txt")"
  else
    MRA_GHIDRA_PROGRAM="$(basename "$MRA_ROM")"
  fi
fi
MRA_GHIDRA_SCRIPTS="$_ghidra_scripts_dir"
ANALYZE_HEADLESS="$GHIDRA_HOME/support/analyzeHeadless"
export GHIDRA_HOME MRA_GHIDRA_PROJECT_DIR MRA_GHIDRA_PROJECT MRA_GHIDRA_PROGRAM MRA_GHIDRA_SCRIPTS ANALYZE_HEADLESS

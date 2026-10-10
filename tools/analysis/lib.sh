# Shared settings for the analysis scripts. Source it from bash; every value
# can be overridden from the environment before sourcing.
#
#   MRA_REPO   repository root (default: derived from this file's location)
#   MRA_ROM    ROM image  (default: $MRA_REPO/roms/moto-racer-advance.gba, gitignored)
#   MRA_BIOS   BIOS image (default: $MRA_REPO/bios/gba_bios.bin, gitignored)
#   MRA_OUT    output root (default: $MRA_REPO/analysis-out, gitignored)
#
# Everything the scripts write is derived from the ROM and must stay out of
# git, so outputs go under $MRA_OUT. mra_out_path refuses paths inside the
# work tree that git would track. It needs python3 (see py/outpath.py).

_mra_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MRA_REPO:=$(cd "$_mra_lib_dir/../.." && pwd)}"
: "${MRA_ROM:=$MRA_REPO/roms/moto-racer-advance.gba}"
: "${MRA_BIOS:=$MRA_REPO/bios/gba_bios.bin}"
: "${MRA_OUT:=$MRA_REPO/analysis-out}"
export MRA_REPO MRA_ROM MRA_BIOS MRA_OUT

# Pinned inputs. ROM: Moto Racer Advance (Europe) (En,Fr,De,Es,It), A9MP,
# matches the No-Intro entry. BIOS: the official GBA BIOS (mGBA checksum
# 0xBAAE187F). See docs/research/phase1-findings.md.
MRA_ROM_SHA1=b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0
MRA_BIOS_SHA1=300c20df6731a33952ded8c436f7f186d25d3492

mra_die() { echo "$(basename "$0"): $*" >&2; exit 1; }

# mra_check_sha1 FILE EXPECTED LABEL
mra_check_sha1() {
  [ -f "$1" ] || mra_die "$3 not found: $1"
  local got
  got="$(shasum -a 1 "$1" | cut -d' ' -f1)"
  [ "$got" = "$2" ] || mra_die "$3 SHA-1 mismatch: $1 is $got, expected $2 (pass --no-hash-check to override)"
}

# mra_out_path PATH: print the absolute output path, with "..", "." and
# symlinks resolved. Relative paths resolve under $MRA_OUT. A path inside the
# work tree must be gitignored; paths outside the repository are accepted.
# The rule lives in py/outpath.py, shared with the Python helpers.
mra_out_path() {
  command -v python3 >/dev/null 2>&1 || mra_die "python3 is required to check output paths"
  python3 -I "$_mra_lib_dir/py/outpath.py" "$1" || exit 1
}

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
# work tree that git would track.

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

# mra_out_path PATH: print an absolute output path. Relative paths resolve
# under $MRA_OUT. Absolute paths inside the work tree must be gitignored.
mra_out_path() {
  local p="$1"
  case "$p" in
    /*) ;;
    *) p="$MRA_OUT/$p" ;;
  esac
  case "$p/" in
    "$MRA_REPO"/*)
      if git -C "$MRA_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
         ! git -C "$MRA_REPO" check-ignore -q --no-index "$p/x" 2>/dev/null; then
        mra_die "refusing to write ROM-derived output to a tracked path: $p (use $MRA_OUT)"
      fi
      ;;
  esac
  printf '%s\n' "$p"
}

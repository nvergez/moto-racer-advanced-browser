#!/usr/bin/env bash
# Download the freely licensed test ROMs used by the smoke test into
# test-roms/ (gitignored) and check their SHA-256.
#
#   scripts/fetch-test-roms.sh [--no-link]
#
# Source: jsmolka/gba-tests (MIT), pinned below. The ROMs are the binaries
# committed in that repository, assembled upstream with FASMARM; building them
# here would need an x86 FASMARM, so we take the published files and pin them
# by hash instead. Their headers carry the standard GBA header logo bytes, like
# every GBA ROM, which is one more reason they stay out of git.
#
# Also links gbarecomp/third_party/gba_suite to them (gitignored inside
# gbarecomp), which enables gbarecomp's own test_rom_arm and test_rom_thumb
# ctest targets. --no-link skips that.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

GBA_TESTS_REPO=jsmolka/gba-tests
GBA_TESTS_COMMIT=a7113b67e63f83a9b321696ddd7042ccfad6c881
DEST="$MRA_ROOT/test-roms/gba-tests"

LINK=1
for arg in "$@"; do
  case "$arg" in
    --no-link) LINK=0 ;;
    -h | --help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $arg" ;;
  esac
done

command -v curl > /dev/null 2>&1 || die "curl is required"

# path in the upstream repository, then its SHA-256 at GBA_TESTS_COMMIT
FILES="
LICENSE         b59a9ed235d76752c977f04116bc72155a14af48176bdbf50d7e5c29fca35aa7
arm/arm.gba     77ee88662552bdc885c1080c0172ff119d54db791bd73b21808cf1ff1fe5b40e
thumb/thumb.gba b5cb2291df4ab314b31c598acd9bff2ccfa0b38efff29daadfe97422ce369b67
"

info "Fetching $GBA_TESTS_REPO@${GBA_TESTS_COMMIT:0:7} -> $(rel "$DEST")"
printf '%s\n' "$FILES" | while read -r path want; do
  [ -n "$path" ] || continue
  out="$DEST/$path"
  if [ -f "$out" ] && [ "$(sha256_of "$out")" = "$want" ]; then
    printf '  ok      %s\n' "$path"
    continue
  fi
  mkdir -p "$(dirname "$out")"
  url="https://raw.githubusercontent.com/$GBA_TESTS_REPO/$GBA_TESTS_COMMIT/$path"
  curl -fsSL --retry 3 -o "$out.part" "$url" || die "download failed: $url"
  got=$(sha256_of "$out.part")
  if [ "$got" != "$want" ]; then
    rm -f "$out.part"
    die "$path: SHA-256 $got, expected $want"
  fi
  mv "$out.part" "$out"
  printf '  fetched %s\n' "$path"
done

if [ "$LINK" = 1 ]; then
  require_submodule
  # A real directory (gbarecomp ignores `third_party/gba_suite/`, which does
  # not match a symlink) holding copies, so the submodule stays clean.
  suite="$GBARECOMP_DIR/third_party/gba_suite"
  [ -L "$suite" ] && rm -f "$suite"
  for rom in arm/arm.gba thumb/thumb.gba; do
    mkdir -p "$suite/$(dirname "$rom")"
    cp "$DEST/$rom" "$suite/$rom"
  done
  info "Copied arm.gba and thumb.gba to $(rel "$suite") for gbarecomp's test_rom_* targets"
  info "Re-configure gbarecomp (scripts/test-engine.sh does) to pick them up"
fi

#!/usr/bin/env bash
# Build gbarecomp natively (all its targets) and run its test suite. Needs no
# ROM and no BIOS.
#
#   scripts/test-engine.sh [--without NAME]... [ctest arguments...]
#
# Build tree: build/gbarecomp (shared with scripts/regen.sh, which only builds
# the gba_recompile and gba_scan targets there). Run scripts/fetch-test-roms.sh
# first to add gbarecomp's test_rom_arm and test_rom_thumb tests.
# --without NAME leaves gbarecomp patch NAME (0003) out and builds into
# build/without-NAME/gbarecomp (an A/B build, patches/gbarecomp/README.md).
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --without) [ $# -ge 2 ] || die "--without needs a patch name or number"; add_without "$2"; shift 2 ;;
    --without=*) add_without "${1#*=}"; shift ;;
    *) break ;;
  esac
done
select_patch_variant

require_submodule
ensure_patches
generator=()
if command -v ninja > /dev/null 2>&1; then generator=(-G Ninja); fi
# Always re-run the configure step: it is what notices test ROMs added since.
info "Configuring gbarecomp -> $(rel "$MRA_TOOLS_BUILD_DIR")"
cmake -S "$GBARECOMP_DIR" -B "$MRA_TOOLS_BUILD_DIR" ${generator[@]+"${generator[@]}"} \
  -DCMAKE_BUILD_TYPE=Release
info "Building gbarecomp"
cmake --build "$MRA_TOOLS_BUILD_DIR" --parallel "$(job_count)"
info "Running gbarecomp's tests"
ctest --test-dir "$MRA_TOOLS_BUILD_DIR" --output-on-failure --parallel "$(job_count)" "$@"

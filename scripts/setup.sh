#!/usr/bin/env bash
# Prepare a fresh clone: check prerequisites, fetch the pinned gbarecomp
# submodule and the one nested submodule the build needs, apply our local
# patches, and report which private inputs are still missing.
#
#   scripts/setup.sh [--with-netplay]
#
# Nested submodules of gbarecomp:
#   external/arm-recomp-core          always (the build needs it)
#   external/recomp-net, rbengine     only with --with-netplay
#                                     (GBARECOMP_NETPLAY, off by default)
#   platform/android/third_party/SDL  never: Android only. Marked
#                                     `update = none` in gbarecomp's local git
#                                     config, so a later recursive update skips it.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

NETPLAY=0
for arg in "$@"; do
  case "$arg" in
    --with-netplay) NETPLAY=1 ;;
    -h | --help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $arg" ;;
  esac
done

missing=0
# check <required|optional> <command> <why>: print the first line of
# `<command> --version`, or why it matters when it is absent.
check() {
  if command -v "$2" > /dev/null 2>&1; then
    printf '  %-8s %s\n' "$2" "$("$2" --version 2>&1 | head -n1)"
  elif [ "$1" = required ]; then
    printf '  %-8s MISSING: %s\n' "$2" "$3"
    missing=1
  else
    printf '  %-8s not found (optional: %s)\n' "$2" "$3"
  fi
}

info "Prerequisites"
check required git "needed for the submodules"
check required cmake "3.20 or newer"
check required c++ "Apple clang from the Xcode Command Line Tools, or g++/clang++"
check required python3 "3.9 or newer, used by gbarecomp's tools and tests"
check optional ninja "CMake falls back to Makefiles"
check optional node "enables gbarecomp's web unit tests"
if ! command -v emcc > /dev/null 2>&1 && [ -f "$(emsdk_env_script)" ]; then
  printf '  %-8s via %s (the web scripts source it)\n' emcc "$(emsdk_env_script)"
else
  check optional emcc "web builds only; see docs/toolchain.md"
fi
if command -v sdl2-config > /dev/null 2>&1; then
  printf '  %-8s %s\n' sdl2 "$(sdl2-config --version)"
else
  printf '  %-8s not found (optional: without SDL2 the native build is headless only)\n' sdl2
fi
[ "$missing" = 0 ] || die "install the missing tools above, then run this script again"

read -r cmake_major cmake_minor << EOF
$(cmake --version | head -n1 | sed -E 's/[^0-9]*([0-9]+)\.([0-9]+).*/\1 \2/')
EOF
if [ "$cmake_major" -lt 3 ] || { [ "$cmake_major" -eq 3 ] && [ "$cmake_minor" -lt 20 ]; }; then
  die "CMake 3.20 or newer is required"
fi

info "Fetching gbarecomp (pinned submodule)"
git -C "$MRA_ROOT" submodule sync --quiet -- gbarecomp
git -C "$MRA_ROOT" submodule update --init -- gbarecomp
git -C "$GBARECOMP_DIR" config submodule.platform/android/third_party/SDL.update none
git -C "$GBARECOMP_DIR" submodule update --init -- external/arm-recomp-core
if [ "$NETPLAY" = 1 ]; then
  git -C "$GBARECOMP_DIR" submodule update --init -- external/recomp-net external/rbengine
fi
printf '  gbarecomp %s\n' "$(git -C "$GBARECOMP_DIR" rev-parse HEAD)"
git -C "$GBARECOMP_DIR" submodule status | sed 's/^/  /'

"$MRA_ROOT/scripts/apply-patches.sh"

info "Private inputs (never committed, never downloaded)"
for input in "$MRA_ROM" "$MRA_BIOS"; do
  if [ -f "$input" ]; then
    printf '  present  %s\n' "$(rel "$input")"
  else
    printf '  missing  %s\n' "$(rel "$input")"
  fi
done

cat << 'EOF'

Next steps (docs/toolchain.md has the details):
  scripts/test-engine.sh        build gbarecomp and run its unit tests
  scripts/smoke-test.sh         recompile and run free test ROMs (no BIOS needed)
  scripts/build-native.sh       needs the ROM, the BIOS and a filled-in game.toml
  scripts/build-web.sh          same, plus Emscripten
EOF

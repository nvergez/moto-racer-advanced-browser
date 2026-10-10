#!/usr/bin/env bash
# Build libmgba 0.10.5 (static, GBA core only, no frontends) and gbaharness.
#
# Usage: tools/analysis/harness/build.sh
#
# Environment (all optional):
#   MGBA_SRC     mGBA source checkout    (default: $MRA_OUT/mgba/mgba-0.10.5, cloned if missing)
#   MGBA_BUILD   static libmgba build    (default: $MRA_OUT/mgba/build-static, built if missing)
#   HARNESS_BIN  output binary           (default: $MRA_OUT/bin/gbaharness)
#   CC           C compiler              (default: cc)
# Nothing here reads the ROM or the BIOS. Tested on macOS (arm64, Apple clang);
# the Linux build is untested.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib.sh"
MGBA_SRC="${MGBA_SRC:-$MRA_OUT/mgba/mgba-0.10.5}"
MGBA_BUILD="${MGBA_BUILD:-$MRA_OUT/mgba/build-static}"
HARNESS_BIN="${HARNESS_BIN:-$MRA_OUT/bin/gbaharness}"
CC="${CC:-cc}"
MGBA_TAG=0.10.5
MGBA_COMMIT=26b7884bc25a5933960f3cdcd98bac1ae14d42e2

if [ ! -d "$MGBA_SRC" ]; then
  mkdir -p "$(dirname "$MGBA_SRC")"
  git clone --depth 1 --branch "$MGBA_TAG" https://github.com/mgba-emu/mgba.git "$MGBA_SRC"
fi
got="$(git -C "$MGBA_SRC" rev-parse HEAD)"
[ "$got" = "$MGBA_COMMIT" ] || mra_die "mGBA source at $got, expected $MGBA_COMMIT (tag $MGBA_TAG)"

if [ ! -f "$MGBA_BUILD/libmgba.a" ]; then
  mkdir -p "$MGBA_BUILD"
  cmake -S "$MGBA_SRC" -B "$MGBA_BUILD" -G Ninja -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_STATIC=ON -DBUILD_SHARED=OFF -DBUILD_QT=OFF -DBUILD_SDL=OFF -DUSE_FFMPEG=OFF -DUSE_MINIZIP=OFF \
    -DUSE_LIBZIP=OFF -DUSE_SQLITE3=OFF -DUSE_ELF=OFF -DUSE_LUA=OFF -DENABLE_SCRIPTING=OFF -DUSE_LZMA=OFF \
    -DUSE_DISCORD_RPC=OFF -DUSE_EDITLINE=OFF -DUSE_PNG=OFF -DM_CORE_GB=OFF -DBUILD_GL=OFF -DBUILD_GLES2=OFF \
    -DBUILD_GLES3=OFF -DUSE_EPOXY=OFF -DBUILD_LTO=OFF
  cmake --build "$MGBA_BUILD"
fi

mkdir -p "$(dirname "$HARNESS_BIN")"
EXTRA_LIBS=""
[ "$(uname)" = Darwin ] && EXTRA_LIBS="-framework CoreFoundation"
# Same feature defines as libmgba's own compile, so struct layouts match.
"$CC" -std=c11 -O2 -g -Wall -Wno-unused-function \
  -DBUILD_STATIC -DM_CORE_GBA -DUSE_DEBUGGERS -DUSE_GDB_STUB -DUSE_PTHREADS -DUSE_ZLIB -DHAVE_CRC32 \
  -DHAVE_LOCALTIME_R -DHAVE_STRDUP -DHAVE_STRLCPY -DHAVE_STRNDUP -DHAVE_XLOCALE -D_DARWIN_C_SOURCE \
  -I"$MGBA_BUILD/include" -I"$MGBA_SRC/include" -I"$MGBA_SRC/src" \
  "$HERE/gbaharness.c" "$MGBA_BUILD/libmgba.a" -lz -lpthread $EXTRA_LIBS -o "$HARNESS_BIN"
echo "built $HARNESS_BIN"

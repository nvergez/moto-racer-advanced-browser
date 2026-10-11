#!/usr/bin/env bash
# Serve the local browser bundle at http://127.0.0.1:<port>/ with the
# Cross-Origin-Opener-Policy / Cross-Origin-Embedder-Policy headers that
# pthreads (SharedArrayBuffer) need. Uses gbarecomp's packaging/web/serve.py,
# which listens on 127.0.0.1 only.
#
#   scripts/serve-web.sh [--without NAME]... [port]     (default 8080)
#
# Build the bundle first with scripts/build-web.sh. It contains code compiled
# from the game: keep it on this machine. --without NAME serves the A/B
# bundle that scripts/build-web.sh --without NAME built, from
# build/without-NAME/web-PRIVATE (patches/gbarecomp/README.md).
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

port=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --without) [ $# -ge 2 ] || die "--without needs a patch name or number"; add_without "$2"; shift ;;
    --without=*) add_without "${1#*=}" ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$port" ] || die "unexpected argument: $1"; port=$1 ;;
  esac
  shift
done
select_patch_variant
port=${port:-8080}
case "$port" in
  '' | *[!0-9]*) die "port must be a number, got: $port" ;;
esac

dir="$MRA_BUILD_DIR/web-PRIVATE"
if [ ! -f "$dir/game.js" ] || [ ! -f "$dir/index.html" ]; then
  if [ -n "$MRA_PATCH_VARIANT" ]; then
    die "no bundle in $(rel "$dir"). Run scripts/build-web.sh with the same --without options first (it needs the ROM and the BIOS)."
  fi
  die "no bundle in $(rel "$dir"). Run scripts/build-web.sh first (it needs the ROM and the BIOS)."
fi
require_submodule
command -v python3 > /dev/null 2>&1 || die "python3 is required"
exec python3 "$GBARECOMP_DIR/packaging/web/serve.py" "$dir" "$port"

#!/usr/bin/env bash
# Serve the local browser bundle at http://127.0.0.1:<port>/ with the
# Cross-Origin-Opener-Policy / Cross-Origin-Embedder-Policy headers that
# pthreads (SharedArrayBuffer) need. Uses gbarecomp's packaging/web/serve.py,
# which listens on 127.0.0.1 only.
#
#   scripts/serve-web.sh [port]     (default 8080)
#
# Build the bundle first with scripts/build-web.sh. It contains code compiled
# from the game: keep it on this machine.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

case "${1:-}" in
  -h | --help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
port=${1:-8080}
case "$port" in
  '' | *[!0-9]*) die "port must be a number, got: $port" ;;
esac

dir="$MRA_BUILD_DIR/web-PRIVATE"
if [ ! -f "$dir/game.js" ] || [ ! -f "$dir/index.html" ]; then
  die "no bundle in $(rel "$dir"). Run scripts/build-web.sh first (it needs the ROM and the BIOS)."
fi
require_submodule
command -v python3 > /dev/null 2>&1 || die "python3 is required"
exec python3 "$GBARECOMP_DIR/packaging/web/serve.py" "$dir" "$port"

# shellcheck shell=bash
# Shared helpers for scripts/*.sh. Source this file; do not run it.
#
# Every path can be overridden from the environment, which is how the smoke
# test and CI reuse these helpers without the game's ROM or BIOS. The scripts
# that need the private inputs also take --rom PATH and --bios PATH, which
# set the first two:
#   MRA_ROM            ROM to recompile          (roms/moto-racer-advance.gba)
#   MRA_BIOS           16 KiB GBA BIOS dump      (bios/gba_bios.bin)
#   MRA_GAME_CONFIG    game config               (game.toml)
#   MRA_BIOS_CONFIG    BIOS recompile config     (gbarecomp/bios/gba_bios.toml)
#   MRA_BUILD_DIR      all build output          (build)
#   MRA_GENERATED_DIR  recompiled C++ output     (generated)
#
# Keep this file compatible with the bash 3.2 that ships with macOS: no
# associative arrays, no mapfile, and guard empty arrays under `set -u`.

MRA_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GBARECOMP_DIR="$MRA_ROOT/gbarecomp"

MRA_ROM=${MRA_ROM:-$MRA_ROOT/roms/moto-racer-advance.gba}
MRA_BIOS=${MRA_BIOS:-$MRA_ROOT/bios/gba_bios.bin}
MRA_GAME_CONFIG=${MRA_GAME_CONFIG:-$MRA_ROOT/game.toml}
MRA_BIOS_CONFIG=${MRA_BIOS_CONFIG:-$GBARECOMP_DIR/bios/gba_bios.toml}
MRA_BUILD_DIR=${MRA_BUILD_DIR:-$MRA_ROOT/build}
MRA_GENERATED_DIR=${MRA_GENERATED_DIR:-$MRA_ROOT/generated}

# Native gbarecomp build: gba_recompile, gba_scan and the engine's unit tests.
MRA_TOOLS_BUILD_DIR="$MRA_BUILD_DIR/gbarecomp"
# shellcheck disable=SC2034  # used by the scripts that source this file
MRA_LOG_DIR="$MRA_BUILD_DIR/logs"

# The retail BIOS every gbarecomp game expects (gba::GbaBios::kExpectedSha1,
# gbarecomp/bios/gba_bios.toml [identity]).
NINTENDO_BIOS_SHA1=300c20df6731a33952ded8c436f7f186d25d3492
GBA_BIOS_SIZE=16384
# gba_recompile stops discovering functions at 4096 by default, silently.
# Mario Kart: Super Circuit needs up to ~21k; this is its value.
MRA_MAX_FUNCTIONS=${MRA_MAX_FUNCTIONS:-65536}
# The Emscripten release gbarecomp's web host was validated with.
MRA_EMSCRIPTEN_VERSION=6.0.10
# toml++ (MIT), the single header gba_recompile includes. Without
# gbarecomp/third_party/tomlpp/toml.hpp (ignored by gbarecomp), every new
# build tree clones toml++ with FetchContent; setup.sh puts the header there
# once. Same commit as gbarecomp's FetchContent_Declare at the pin; the
# SHA-256 was checked against that checkout.
# shellcheck disable=SC2034  # used by setup.sh
TOMLPP_COMMIT=30172438cee64926dc41fdd9c11fb3ba5b2ba9de
# shellcheck disable=SC2034  # used by setup.sh
TOMLPP_SHA256=6b5172ad4dd6519aec67b919181fa7a38a2234131e5b2afa232dfe444819783e

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}
warn() { printf 'warning: %s\n' "$*" >&2; }
info() { printf '==> %s\n' "$*"; }

# Path relative to the repository root, for messages.
rel() {
  case "$1" in
    "$MRA_ROOT"/*) printf '%s\n' "${1#"$MRA_ROOT"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

job_count() {
  sysctl -n hw.ncpu 2> /dev/null || nproc 2> /dev/null || echo 4
}

file_size() { wc -c < "$1" | tr -d ' '; }

# SHA-1 of a file, lowercase hex: shasum (macOS), sha1sum (GNU) or Python.
sha1_of() {
  local digest=""
  if command -v shasum > /dev/null 2>&1; then
    digest=$(shasum -a 1 "$1" | cut -d' ' -f1)
  elif command -v sha1sum > /dev/null 2>&1; then
    digest=$(sha1sum "$1" | cut -d' ' -f1)
  elif command -v python3 > /dev/null 2>&1; then
    digest=$(python3 -c 'import hashlib,sys;print(hashlib.sha1(open(sys.argv[1],"rb").read()).hexdigest())' "$1")
  else
    die "no SHA-1 tool found (shasum, sha1sum or python3)"
  fi
  digest=$(printf '%s' "$digest" | tr 'A-F' 'a-f')
  printf '%s' "$digest" | grep -Eq '^[0-9a-f]{40}$' || die "could not hash $1"
  printf '%s\n' "$digest"
}

sha256_of() {
  local digest=""
  if command -v shasum > /dev/null 2>&1; then
    digest=$(shasum -a 256 "$1" | cut -d' ' -f1)
  elif command -v sha256sum > /dev/null 2>&1; then
    digest=$(sha256sum "$1" | cut -d' ' -f1)
  else
    die "no SHA-256 tool found (shasum or sha256sum)"
  fi
  printf '%s\n' "$digest" | tr 'A-F' 'a-f'
}

# Value of `key` in `[section]` of a flat TOML file, unquoted. Comments are
# stripped the way gbarecomp's runtime reader does it (everything after '#').
toml_get() {
  awk -v want_section="$2" -v want_key="$3" '
    {
      line = $0
      sub(/#.*/, "", line)
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == "") next
      if (line ~ /^\[.*\]$/) {
        section = substr(line, 2, length(line) - 2)
        gsub(/^[ \t]+|[ \t]+$/, "", section)
        next
      }
      eq = index(line, "=")
      if (section != want_section || eq == 0) next
      key = substr(line, 1, eq - 1)
      gsub(/[ \t]+$/, "", key)
      if (key != want_key) next
      value = substr(line, eq + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }' "$1"
}

# set_input <--rom|--bios> <path>: handle the --rom/--bios options. Exports the
# result so the scripts these call (build-native.sh runs regen.sh) see it too.
set_input() {
  local path=$2
  case "$path" in
    "") die "$1 needs a path" ;;
    /*) ;;
    *) path="$PWD/$path" ;;
  esac
  case "$1" in
    --rom) MRA_ROM=$path ;;
    --bios) MRA_BIOS=$path ;;
    *) die "set_input: unknown option $1" ;;
  esac
  export MRA_ROM MRA_BIOS
}

require_submodule() {
  if [ ! -f "$GBARECOMP_DIR/CMakeLists.txt" ] ||
     [ ! -f "$GBARECOMP_DIR/external/arm-recomp-core/cmake/ArmRecompCore.cmake" ]; then
    die "the gbarecomp submodule is not initialized. Run scripts/setup.sh first."
  fi
}

# Stop with one message that lists every missing or malformed private input.
require_inputs() {
  local problems="" size
  if [ ! -f "$MRA_ROM" ]; then
    problems="$problems
  - ROM not found: $(rel "$MRA_ROM")
    Dump Moto Racer Advance (Europe) from a cartridge you own and copy the
    dump there, or pass --rom PATH."
  fi
  if [ ! -f "$MRA_BIOS" ]; then
    problems="$problems
  - GBA BIOS not found: $(rel "$MRA_BIOS")
    Dump it from GBA-family hardware you own and copy it there, or pass
    --bios PATH. gbarecomp recompiles it at build time and loads it at run
    time."
  else
    size=$(file_size "$MRA_BIOS")
    if [ "$size" != "$GBA_BIOS_SIZE" ]; then
      problems="$problems
  - $(rel "$MRA_BIOS") is $size bytes; a GBA BIOS is exactly $GBA_BIOS_SIZE bytes."
    fi
  fi
  if [ -n "$problems" ]; then
    die "this step needs the private inputs, which are not in place:$problems
  roms/ and bios/ are gitignored. Never download either file.
  See docs/toolchain.md, \"Inputs\"."
  fi
}

# Refuse a game config that still holds the scaffold's "TBD" placeholders:
# gba_recompile would only fail later with a less helpful message.
require_game_config() {
  [ -f "$MRA_GAME_CONFIG" ] || die "game config not found: $(rel "$MRA_GAME_CONFIG")"
  local placeholders
  placeholders=$(grep -nE '^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*=[[:space:]]*"TBD"' \
    "$MRA_GAME_CONFIG" || true)
  if [ -n "$placeholders" ]; then
    die "$(rel "$MRA_GAME_CONFIG") still has placeholders that depend on the ROM:
$placeholders
  Fill them in from the ROM you dumped (docs/toolchain.md, \"The game
  config\"), then run this script again."
  fi
}

# Check the ROM and BIOS against the identity recorded in the game config.
verify_inputs() {
  require_inputs
  require_game_config

  local rom_sha1 want_identity want_rom size want_size
  rom_sha1=$(sha1_of "$MRA_ROM")
  want_identity=$(toml_get "$MRA_GAME_CONFIG" identity sha1 | tr 'A-F' 'a-f')
  want_rom=$(toml_get "$MRA_GAME_CONFIG" rom sha1 | tr 'A-F' 'a-f')
  [ -n "$want_identity" ] || die "$(rel "$MRA_GAME_CONFIG") has no [identity].sha1"
  if [ -n "$want_rom" ] && [ "$want_rom" != "$want_identity" ]; then
    die "$(rel "$MRA_GAME_CONFIG"): [rom].sha1 ($want_rom) differs from [identity].sha1 ($want_identity)"
  fi
  [ "$rom_sha1" = "$want_identity" ] ||
    die "$(rel "$MRA_ROM") has SHA-1 $rom_sha1, but $(rel "$MRA_GAME_CONFIG") expects $want_identity (a different ROM revision or a bad dump)"

  size=$(file_size "$MRA_ROM")
  want_size=$(toml_get "$MRA_GAME_CONFIG" program size)
  if [ -n "$want_size" ] && [ "$((want_size))" != "$size" ]; then
    die "$(rel "$MRA_ROM") is $size bytes, but [program].size in $(rel "$MRA_GAME_CONFIG") is $want_size"
  fi

  local bios_sha1 want_bios
  bios_sha1=$(sha1_of "$MRA_BIOS")
  want_bios=$(toml_get "$MRA_GAME_CONFIG" bios sha1 | tr 'A-F' 'a-f')
  want_bios=${want_bios:-$NINTENDO_BIOS_SHA1}
  [ "$bios_sha1" = "$want_bios" ] ||
    die "$(rel "$MRA_BIOS") has SHA-1 $bios_sha1, expected $want_bios ([bios].sha1). gba_recompile refuses any other BIOS image."
  info "ROM  $(rel "$MRA_ROM")  sha1=$rom_sha1"
  info "BIOS $(rel "$MRA_BIOS")  sha1=$bios_sha1"
}

# Make sure patches/gbarecomp/ is applied (idempotent; stops on a conflict).
ensure_patches() {
  "$MRA_ROOT/scripts/apply-patches.sh" > /dev/null
}

# Configure (once) and build the native gbarecomp tools.
build_tools() {
  require_submodule
  ensure_patches
  local generator=()
  if command -v ninja > /dev/null 2>&1; then generator=(-G Ninja); fi
  if [ ! -f "$MRA_TOOLS_BUILD_DIR/CMakeCache.txt" ]; then
    info "Configuring gbarecomp -> $(rel "$MRA_TOOLS_BUILD_DIR")"
    cmake -S "$GBARECOMP_DIR" -B "$MRA_TOOLS_BUILD_DIR" ${generator[@]+"${generator[@]}"} \
      -DCMAKE_BUILD_TYPE=Release
  fi
  info "Building gba_recompile and gba_scan"
  cmake --build "$MRA_TOOLS_BUILD_DIR" --target gba_recompile gba_scan --parallel "$(job_count)"
}

# run_logged <log> <command...>: run a noisy step into a log file; on failure
# show its tail and stop.
run_logged() {
  local log=$1
  shift
  mkdir -p "$(dirname "$log")"
  if ! "$@" > "$log" 2>&1; then
    tail -n 40 "$log" >&2
    die "failed: $1 (full log: $(rel "$log"))"
  fi
}

# Path with repeated slashes squeezed and no trailing slash, so that the
# prefix checks in reset_dir compare like with like.
norm_path() {
  local p
  p=$(printf '%s' "$1" | tr -s /)
  case "$p" in
    / | "") ;;
    */) p=${p%/} ;;
  esac
  printf '%s\n' "$p"
}

# Empty a generated-output directory: the only `rm -rf` in the scripts. The
# directory comes from MRA_GENERATED_DIR or MRA_BUILD_DIR, which the
# environment can override, so check it rather than trust it. It must be an
# absolute path with no "." or ".." component, strictly inside the
# repository or the build directory, outside gbarecomp/, roms/ and bios/, and
# it must not be or contain the repository root, the ROM, the BIOS or a
# config in use.
reset_dir() {
  local dir root build tree keep
  dir=$(norm_path "$1")
  root=$(norm_path "$MRA_ROOT")
  build=$(norm_path "$MRA_BUILD_DIR")
  case "$dir" in
    /*) ;;
    *) die "refusing to delete $dir: not an absolute path (set MRA_BUILD_DIR and MRA_GENERATED_DIR to absolute paths)" ;;
  esac
  case "$dir/" in
    */./* | */../*) die "refusing to delete $dir: it has a '.' or '..' component" ;;
  esac
  case "$dir" in
    "$root"/?* | "$build"/?*) ;;
    *) die "refusing to delete $dir: not inside $root or $build" ;;
  esac
  for tree in "$GBARECOMP_DIR" "$MRA_ROOT/roms" "$MRA_ROOT/bios"; do
    tree=$(norm_path "$tree")
    case "$dir" in
      "$tree" | "$tree"/*) die "refusing to delete $dir: it is inside $tree" ;;
    esac
  done
  for keep in "$MRA_ROOT" "$GBARECOMP_DIR" "$MRA_ROOT/roms" "$MRA_ROOT/bios" \
              "$MRA_ROM" "$MRA_BIOS" "$MRA_GAME_CONFIG" "$MRA_BIOS_CONFIG"; do
    case "$keep" in
      /*) ;;
      *) keep="$PWD/$keep" ;;
    esac
    keep=$(norm_path "$keep")
    case "$keep" in
      "$dir" | "$dir"/*) die "refusing to delete $dir: it contains $keep" ;;
    esac
  done
  rm -rf "$dir"
  mkdir -p "$dir"
}

# recompile_rom <rom> <config> <out dir> <log>
# gba_recompile with the function cap raised, then check the cap was not
# reached: past it, gba_recompile drops seeds without a warning.
recompile_rom() {
  local rom=$1 config=$2 out=$3 log=$4 total
  info "Recompiling $(rel "$rom") -> $(rel "$out")"
  reset_dir "$out"
  mkdir -p "$(dirname "$log")"
  "$MRA_TOOLS_BUILD_DIR/gba_recompile" --rom "$rom" --config "$config" \
    --out "$out" --max-functions "$MRA_MAX_FUNCTIONS" > "$log" 2>&1 ||
    die "gba_recompile failed; see $(rel "$log")"
  total=$(sed -nE 's/^[[:space:]]*TOTAL emitted:[[:space:]]+([0-9]+).*/\1/p' "$log" | tail -n1)
  [ -n "$total" ] || die "no discovery summary in $(rel "$log")"
  if [ "$total" -ge "$MRA_MAX_FUNCTIONS" ]; then
    die "gba_recompile emitted $total functions, the --max-functions cap: raise MRA_MAX_FUNCTIONS"
  fi
  info "$total functions emitted (cap $MRA_MAX_FUNCTIONS); log: $(rel "$log")"
}

# Put emcc on PATH: keep one that is already there, else source an emsdk
# ($EMSDK, then ~/emsdk). Warn when the version differs from the validated one.
emsdk_env_script() { printf '%s\n' "${EMSDK:-$HOME/emsdk}/emsdk_env.sh"; }

require_emscripten() {
  if ! command -v emcc > /dev/null 2>&1; then
    local env_sh
    env_sh=$(emsdk_env_script)
    if [ -f "$env_sh" ]; then
      # shellcheck disable=SC1090
      . "$env_sh" > /dev/null 2>&1
    fi
  fi
  command -v emcc > /dev/null 2>&1 || die "emcc not found. Install Emscripten $MRA_EMSCRIPTEN_VERSION with emsdk (docs/toolchain.md, \"Emscripten\"), or put emcc on PATH."
  local version
  version=$(emcc --version | head -n1 | sed -E 's/.* ([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
  if [ "$version" != "$MRA_EMSCRIPTEN_VERSION" ]; then
    warn "emcc is $version; gbarecomp's web host was validated with $MRA_EMSCRIPTEN_VERSION"
  fi
  info "emcc $version ($(command -v emcc))"
}

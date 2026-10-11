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
# A/B builds (patches/gbarecomp/README.md): the build scripts take
# --without NAME, which sets the first variable below. Both directories above
# then move under $MRA_BUILD_DIR/without-NAME/, so a build with a patch left
# out never writes the normal build or generated/:
#   MRA_WITHOUT_PATCHES  patches to leave out, separated by spaces: 0003
#                        for patches/gbarecomp/0003-*.patch,
#                        arm-recomp-core/0001 for the nested series  (none)
#   MRA_PATCH_STATE_DIR  apply-patches.sh's stamps and scratch objects (the
#                        nested series' in a subdirectory of the same name),
#                        and the checkout lock (lock_checkout)
#                        ($MRA_BUILD_DIR/gbarecomp-patches, never per variant)
#
# Keep this file compatible with the bash 3.2 that ships with macOS: no
# associative arrays, no mapfile, and guard empty arrays under `set -u`.

MRA_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GBARECOMP_DIR="$MRA_ROOT/gbarecomp"
# The patch series (patches/gbarecomp/README.md), in the order
# scripts/apply-patches.sh applies them. Each is a directory patches/SERIES/
# of *.patch files, applied as a stack to the working tree of one repository
# (series_repo): gbarecomp, then its nested submodule arm-recomp-core.
MRA_PATCH_SERIES="gbarecomp arm-recomp-core"
# The gbarecomp series' directory, the default series of --without names.
MRA_PATCH_DIR="$MRA_ROOT/patches/gbarecomp"

MRA_ROM=${MRA_ROM:-$MRA_ROOT/roms/moto-racer-advance.gba}
MRA_BIOS=${MRA_BIOS:-$MRA_ROOT/bios/gba_bios.bin}
MRA_GAME_CONFIG=${MRA_GAME_CONFIG:-$MRA_ROOT/game.toml}
MRA_BIOS_CONFIG=${MRA_BIOS_CONFIG:-$GBARECOMP_DIR/bios/gba_bios.toml}
MRA_BUILD_DIR=${MRA_BUILD_DIR:-$MRA_ROOT/build}
MRA_GENERATED_DIR=${MRA_GENERATED_DIR:-$MRA_ROOT/generated}

# One stamp per submodule checkout, whatever variant is being built. A script
# called by another inherits it, with the variant's directories (below).
MRA_PATCH_STATE_DIR=${MRA_PATCH_STATE_DIR:-$MRA_BUILD_DIR/gbarecomp-patches}
export MRA_PATCH_STATE_DIR
MRA_WITHOUT_PATCHES=${MRA_WITHOUT_PATCHES:-}
# MRA_PATCH_VARIANT is internal: select_patch_variant exports it, together
# with the variant's MRA_BUILD_DIR and MRA_GENERATED_DIR, so that a script it
# runs (build-native.sh runs regen.sh) uses the same directories.
_mra_variant_inherited=${MRA_PATCH_VARIANT:-}
MRA_PATCH_VARIANT=${MRA_PATCH_VARIANT:-}
_mra_base_build_dir=$MRA_BUILD_DIR
_mra_base_generated_dir=$MRA_GENERATED_DIR

set_build_subdirs() {
  # Native gbarecomp build: gba_recompile, gba_scan and the engine's unit tests.
  MRA_TOOLS_BUILD_DIR="$MRA_BUILD_DIR/gbarecomp"
  # shellcheck disable=SC2034  # used by the scripts that source this file
  MRA_LOG_DIR="$MRA_BUILD_DIR/logs"
}
set_build_subdirs

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

# at_exit FUNCTION: call FUNCTION when the script exits, whatever the exit
# status, after the functions registered before it. Scripts that source this
# file use it instead of `trap ... EXIT`, which would replace the others.
_mra_exit_hooks=""
at_exit() {
  _mra_exit_hooks="$_mra_exit_hooks $1"
  trap _mra_run_exit_hooks EXIT
}
# shellcheck disable=SC2317  # called by the trap
_mra_run_exit_hooks() {
  local hook
  for hook in $_mra_exit_hooks; do "$hook" || true; done
}

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

# Make the submodule's tree the pin plus patches/gbarecomp/, and its nested
# arm-recomp-core the commit gbarecomp pins plus patches/arm-recomp-core/
# (minus the patches MRA_WITHOUT_PATCHES leaves out). Silent when they
# already are; stops on a patch that does not apply and on changes no known
# series explains.
ensure_patches() {
  "$MRA_ROOT/scripts/apply-patches.sh" --quiet
}

# --- One build at a time in a checkout ----------------------------------------
# gbarecomp/ holds one patch series at a time, and every build reads it, so a
# build must not run while another script switches the series (an A/B build
# and a normal one). The build scripts, and apply-patches.sh when it may
# write, hold this lock for their whole run; another one waits for it. A
# script run by the holder (build-native.sh runs regen.sh, which runs
# apply-patches.sh) shares it through MRA_LOCK_TOKEN. A build by hand
# (cmake --build) takes no lock.
#
# The lock is a symbolic link, created atomically, whose target is never
# followed: it holds the holder's pid, a token, its name and the time.
checkout_lock() { printf '%s\n' "$MRA_PATCH_STATE_DIR/lock"; }

# pid_alive PID: a process with that pid exists (possibly another user's).
pid_alive() {
  kill -0 "$1" 2> /dev/null || ps -p "$1" > /dev/null 2>&1
}

_mra_lock_owned=0
lock_checkout() {
  local lock target pid token name since waited=0 tries=0
  lock=$(checkout_lock)
  if [ -n "${MRA_LOCK_TOKEN:-}" ] && target=$(readlink "$lock" 2> /dev/null); then
    read -r pid token name since <<< "$target"
    [ "$token" != "$MRA_LOCK_TOKEN" ] || return 0
  fi
  mkdir -p "$MRA_PATCH_STATE_DIR"
  if [ -d "$lock" ] && [ ! -L "$lock" ]; then
    die "$(rel "$lock") is a directory, not a lock these scripts made. Remove it if no build is running."
  fi
  MRA_LOCK_TOKEN="$$-$RANDOM$RANDOM-$(date +%s)"
  until ln -s "$$ $MRA_LOCK_TOKEN ${0##*/} $(date +%H:%M:%S)" "$lock" 2> /dev/null; do
    if ! target=$(readlink "$lock" 2> /dev/null); then
      # Released between the two calls, or the link cannot be made at all.
      tries=$((tries + 1))
      [ "$tries" -lt 5 ] || die "could not create the lock $(rel "$lock")"
      continue
    fi
    read -r pid token name since <<< "$target"
    case "$pid" in
      '' | *[!0-9]*) die "$(rel "$lock") is not a lock these scripts made. Remove it if no build is running." ;;
    esac
    if ! pid_alive "$pid"; then
      # Only a script killed with SIGKILL leaves one. Two scripts that find
      # it at the same instant could both go on; that is not guarded against.
      warn "removing a stale lock: $name (pid $pid), which took it at $since, is no longer running"
      rm -f "$lock"
      continue
    fi
    if [ "$waited" = 0 ]; then
      warn "waiting for $name (pid $pid, running since $since) to finish: scripts that build or switch gbarecomp/ run one at a time in a checkout. To build two series at once, use a second git worktree. If no such script is running, remove $(rel "$lock")."
      waited=1
    fi
    sleep 1
  done
  export MRA_LOCK_TOKEN
  _mra_lock_owned=1
  at_exit unlock_checkout
  # The holder of an A/B build says, at the end, what it leaves in gbarecomp/.
  if [ -n "$MRA_PATCH_VARIANT" ]; then at_exit variant_notice; fi
}

# shellcheck disable=SC2317  # called through at_exit
unlock_checkout() {
  local lock target
  [ "$_mra_lock_owned" = 1 ] || return 0
  _mra_lock_owned=0
  lock=$(checkout_lock)
  target=$(readlink "$lock" 2> /dev/null) || return 0
  case " $target " in
    *" $MRA_LOCK_TOKEN "*) rm -f "$lock" ;;
  esac
}

# After an A/B build: gbarecomp/ keeps the variant until the next normal run.
# shellcheck disable=SC2317  # called through at_exit
variant_notice() {
  local series stamp without n list=""
  for series in $MRA_PATCH_SERIES; do
    stamp="$(series_state_dir "$series")/stamp"
    [ -f "$stamp" ] || continue
    [ "$(sed -n 's/^state=//p' "$stamp" | head -n 1)" = "done" ] || continue
    without=$(sed -n 's/^without=//p' "$stamp" | head -n 1)
    for n in $without; do list="$list${list:+, }$(patch_label "$series" "$n")"; done
  done
  [ -n "$list" ] || return 0
  info "gbarecomp/ is left without $list. The next normal build script, or scripts/apply-patches.sh, restores the full series; a build by hand before that compiles this variant."
}

# series_repo SERIES: the repository whose working tree SERIES patches.
series_repo() {
  case "$1" in
    gbarecomp) printf '%s\n' "$GBARECOMP_DIR" ;;
    arm-recomp-core) printf '%s\n' "$GBARECOMP_DIR/external/arm-recomp-core" ;;
    *) die "unknown patch series: $1 (one of: $MRA_PATCH_SERIES)" ;;
  esac
}

# series_patch_dir SERIES: patches/SERIES.
series_patch_dir() {
  series_repo "$1" > /dev/null || exit 1
  printf '%s\n' "$MRA_ROOT/patches/$1"
}

# series_state_dir SERIES: where apply-patches.sh keeps SERIES's stamp and
# scratch objects. The nested series' directory is inside gbarecomp's.
series_state_dir() {
  case "$1" in
    gbarecomp) printf '%s\n' "$MRA_PATCH_STATE_DIR" ;;
    *) series_repo "$1" > /dev/null || exit 1; printf '%s\n' "$MRA_PATCH_STATE_DIR/$1" ;;
  esac
}

# patch_label SERIES FILE: how messages and options name a patch: 0003 for
# patches/gbarecomp/0003-some-fix.patch, arm-recomp-core/0001 for a patch of
# the nested series.
patch_label() {
  local short
  case "$2" in
    [0-9]*-*) short=${2%%-*} ;;
    *) short=${2%.patch} ;;
  esac
  if [ "$1" = gbarecomp ]; then printf '%s\n' "$short"; else printf '%s/%s\n' "$1" "$short"; fi
}

# patch_series [SERIES]: the file names of a series (patches/SERIES/*.patch,
# gbarecomp by default), in name order, one per line. Names are restricted
# to letters, digits, '.', '_' and '-' so that callers can split the list on
# white space.
patch_series() {
  local dir p base list=""
  dir=$(series_patch_dir "${1:-gbarecomp}") || exit 1
  for p in "$dir"/*.patch; do
    [ -f "$p" ] || continue
    base=${p##*/}
    case "$base" in
      *[!A-Za-z0-9._-]*) die "unsupported patch file name: $(rel "$p") (use letters, digits, '.', '_' and '-')" ;;
    esac
    list="$list$base
"
  done
  printf '%s' "$list" | LC_ALL=C sort
}

# match_patch SERIES WANT: the file names in SERIES that WANT designates
# (its number, or its file name without .patch), exact match first.
match_patch() {
  local list p base exact="" matches=""
  list=$(patch_series "$1") || exit 1
  for p in $list; do
    base=${p%.patch}
    if [ "$base" = "$2" ]; then
      exact=$p
    elif [ "${base#"$2"-}" != "$base" ]; then
      matches="$matches${matches:+ }$p"
    fi
  done
  if [ -n "$exact" ]; then printf '%s\n' "$exact"; else printf '%s\n' "$matches"; fi
}

# resolve_patch NAME: SERIES/FILE, the one patch that NAME designates: its
# number (0003), its file name with or without .patch, or a path to it. A
# name in the nested series is qualified with the series' name or directory
# (arm-recomp-core/0001, patches/arm-recomp-core/0001-x.patch); any other
# name designates a patch of patches/gbarecomp/.
resolve_patch() {
  local want=${1##*/} series=gbarecomp dir s found count other
  case "$1" in
    */*)
      dir=${1%/*}
      dir=${dir##*/}
      for s in $MRA_PATCH_SERIES; do [ "$dir" != "$s" ] || series=$s; done
      ;;
  esac
  want=${want%.patch}
  [ -n "$want" ] || die "empty patch name"
  found=$(match_patch "$series" "$want") || exit 1
  # shellcheck disable=SC2086  # file names hold no white space
  count=$(set -- $found; echo $#)
  if [ "$count" = 1 ]; then
    printf '%s/%s\n' "$series" "$found"
  elif [ "$count" = 0 ]; then
    other=""
    if [ "$series" = gbarecomp ] && [ "$1" = "${1##*/}" ]; then
      for s in $MRA_PATCH_SERIES; do
        [ "$s" != gbarecomp ] || continue
        [ -z "$(match_patch "$s" "$want")" ] || other="$other${other:+ or }$s/$want"
      done
    fi
    [ -z "$other" ] || die "no patch in patches/gbarecomp matches '$1'. For the nested series, qualify the name: $other"
    die "no patch in patches/$series matches '$1'"
  else
    die "'$1' matches several patches in patches/$series: $found"
  fi
}

# add_without NAME: handle --without NAME (call select_patch_variant after
# the options are parsed).
add_without() {
  [ -n "$1" ] || die "--without needs a patch name or number"
  MRA_WITHOUT_PATCHES="${MRA_WITHOUT_PATCHES:+$MRA_WITHOUT_PATCHES }$1"
}

# The patches MRA_WITHOUT_PATCHES leaves out, as SERIES/FILE, one per line,
# in series order and then name order. Stops on a name that does not
# designate exactly one patch: a typo must not build the full series into
# an A/B directory.
without_patch_list() {
  local name resolved list="" series sorted
  for name in $MRA_WITHOUT_PATCHES; do
    resolved=$(resolve_patch "$name") || exit 1
    list="$list$resolved
"
  done
  sorted=$(printf '%s' "$list" | LC_ALL=C sort -u)
  [ -n "$sorted" ] || return 0
  for series in $MRA_PATCH_SERIES; do
    printf '%s\n' "$sorted" | sed -n "\\|^$series/|p"
  done
}

# without_patch_names [SERIES]: the file names of the patches of SERIES
# (gbarecomp by default) that MRA_WITHOUT_PATCHES leaves out, sorted, one
# per line. Stops on any name that does not designate exactly one patch.
without_patch_names() {
  local series=${1:-gbarecomp} list
  series_repo "$series" > /dev/null || exit 1
  list=$(without_patch_list) || exit 1
  [ -n "$list" ] || return 0
  printf '%s\n' "$list" | sed -n "s|^$series/||p"
}

# Point the build directories at the variant MRA_WITHOUT_PATCHES selects:
# $MRA_BUILD_DIR/without-0003[-0007...]/, with generated code inside it; a
# patch of the nested series adds its label with '-' for '/', as in
# without-0011-arm-recomp-core-0001/. Without any patch left out, keep the
# normal directories.
select_patch_variant() {
  local names name label suffix=""
  names=$(without_patch_list) || exit 1
  for name in $names; do
    label=$(patch_label "${name%%/*}" "${name#*/}")
    suffix="$suffix${suffix:+-}$(printf '%s' "$label" | tr / -)"
  done
  if [ -n "$_mra_variant_inherited" ]; then
    # Called from a script that already selected the variant.
    [ "$suffix" = "$_mra_variant_inherited" ] ||
      die "this script runs inside an A/B build without-$_mra_variant_inherited; it cannot select without-${suffix:-nothing}"
    return 0
  fi
  MRA_PATCH_VARIANT=$suffix
  if [ -z "$suffix" ]; then
    MRA_BUILD_DIR=$_mra_base_build_dir
    MRA_GENERATED_DIR=$_mra_base_generated_dir
  else
    MRA_BUILD_DIR="$_mra_base_build_dir/without-$suffix"
    MRA_GENERATED_DIR="$MRA_BUILD_DIR/generated"
    export MRA_WITHOUT_PATCHES MRA_PATCH_VARIANT MRA_BUILD_DIR MRA_GENERATED_DIR
  fi
  set_build_subdirs
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

# embed_replays <out.cpp>: write the routes table with every route's input
# replay (tools/replay/script2replay.py --embed, from tools/difftest/routes.toml)
# for a test build. Rewritten only when its content changes.
embed_replays() {
  command -v python3 > /dev/null 2>&1 || die "python3 is required for --replays"
  python3 -I "$MRA_ROOT/tools/replay/script2replay.py" --embed "$1" ||
    die "could not write the input replays to $(rel "$1")"
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

# recompile_rom <rom> <config> <out dir> <log> [gba_recompile option...]
# gba_recompile with the function cap raised, then check the cap was not
# reached: past it, gba_recompile drops seeds without a warning. Further
# arguments go to gba_recompile (for example --output-prefix P).
recompile_rom() {
  local rom=$1 config=$2 out=$3 log=$4 total
  shift 4
  info "Recompiling $(rel "$rom") -> $(rel "$out")"
  reset_dir "$out"
  mkdir -p "$(dirname "$log")"
  "$MRA_TOOLS_BUILD_DIR/gba_recompile" --rom "$rom" --config "$config" \
    --out "$out" --max-functions "$MRA_MAX_FUNCTIONS" "$@" > "$log" 2>&1 ||
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

# An A/B build selected through the environment (MRA_WITHOUT_PATCHES), or
# inherited from the script that runs this one. Scripts that take --without
# call select_patch_variant again once their options are parsed.
if [ -n "$MRA_WITHOUT_PATCHES" ] || [ -n "$_mra_variant_inherited" ]; then
  select_patch_variant
fi

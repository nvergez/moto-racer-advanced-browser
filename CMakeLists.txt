# Native host for the recompiled Moto Racer Advance.
#
# Normally driven by scripts/build-native.sh, which first regenerates
# generated/bios (from bios/gba_bios.bin) and generated/game (from the ROM).
# Modeled on mstan/MarioKartSuperCircuitRecomp, except for linking: that repo
# passes -Wl,--start-group unconditionally, which Apple's ld rejects, so we use
# gbarecomp's target_link_gbarecomp_runtime_stack() instead.
cmake_minimum_required(VERSION 3.20)
project(MotoRacerAdvanceRecomp C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(GBARECOMP_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/gbarecomp"
    CACHE PATH "gbarecomp checkout (the pinned submodule)")
set(MRA_GAME_CONFIG "${CMAKE_CURRENT_SOURCE_DIR}/game.toml"
    CACHE FILEPATH "Game config; its [game].name and [identity].sha1 are built in")
set(MRA_GENERATED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/generated/game"
    CACHE PATH "gba_recompile output for the ROM")
# gbarecomp reads this cache variable. Defining it first keeps BIOS-derived
# output in our ignored generated/ tree instead of inside the submodule.
set(GBARECOMP_GENERATED_BIOS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/generated/bios"
    CACHE PATH "gba_recompile --bios output")
option(MRA_ALLOW_BIOS_PLACEHOLDER
    "Link without a recompiled BIOS (smoke tests only: the runtime then boots through BIOS HLE)"
    OFF)
# Test builds only (docs/phase2-plan.md, P2-02): the C++ source with the
# routes' input replays that tools/replay/script2replay.py --embed writes under
# build/ (scripts/build-native.sh --replays). src/main.cpp looks routes up in it
# for MRA_REPLAY=embedded:ROUTE. Empty, the default: an empty table.
set(MRA_REPLAY_ROUTES "" CACHE FILEPATH
    "Test builds only: embedded input replays (script2replay.py --embed); empty for none")

if(NOT EXISTS "${GBARECOMP_ROOT}/CMakeLists.txt")
    message(FATAL_ERROR
        "gbarecomp not found at ${GBARECOMP_ROOT}. Run scripts/setup.sh first.")
endif()
if(NOT MRA_ALLOW_BIOS_PLACEHOLDER AND
   NOT EXISTS "${GBARECOMP_GENERATED_BIOS_DIR}/bios_recompiled.cpp")
    message(FATAL_ERROR
        "No recompiled BIOS in ${GBARECOMP_GENERATED_BIOS_DIR}.\n"
        "Run scripts/build-native.sh, which recompiles bios/gba_bios.bin first.")
endif()

# Value of `key` in `[section]` of a flat TOML file, unquoted. Mirrors
# toml_get in scripts/lib/common.sh and gbarecomp's runtime reader: text after
# '#' is a comment.
function(mra_toml_get file section key out_var)
    file(STRINGS "${file}" lines)
    set(current "")
    set(value "")
    foreach(line IN LISTS lines)
        string(REGEX REPLACE "#.*" "" line "${line}")
        string(STRIP "${line}" line)
        if(line MATCHES "^\\[(.*)\\]$")
            string(STRIP "${CMAKE_MATCH_1}" current)
        elseif(current STREQUAL section AND
               line MATCHES "^([A-Za-z0-9_]+)[ \t]*=[ \t]*\"?([^\"]*)\"?$")
            if(CMAKE_MATCH_1 STREQUAL key)
                set(value "${CMAKE_MATCH_2}")
                break()
            endif()
        endif()
    endforeach()
    set(${out_var} "${value}" PARENT_SCOPE)
endfunction()

if(NOT EXISTS "${MRA_GAME_CONFIG}")
    message(FATAL_ERROR "Game config not found: ${MRA_GAME_CONFIG}")
endif()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${MRA_GAME_CONFIG}")
mra_toml_get("${MRA_GAME_CONFIG}" game name MRA_GAME_NAME)
mra_toml_get("${MRA_GAME_CONFIG}" identity sha1 MRA_ROM_SHA1)
string(LENGTH "${MRA_ROM_SHA1}" _mra_sha1_length)
if(NOT MRA_ROM_SHA1 MATCHES "^[0-9a-fA-F]+$" OR NOT _mra_sha1_length EQUAL 40)
    message(FATAL_ERROR
        "[identity].sha1 in ${MRA_GAME_CONFIG} is \"${MRA_ROM_SHA1}\", not a SHA-1.\n"
        "Fill in game.toml from the ROM first (docs/toolchain.md).")
endif()
string(TOLOWER "${MRA_ROM_SHA1}" MRA_ROM_SHA1)
if(MRA_GAME_NAME STREQUAL "")
    set(MRA_GAME_NAME "Moto Racer Advance")
endif()

if(EXISTS "${MRA_GENERATED_DIR}/recompiled.cpp")
    message(FATAL_ERROR
        "Stale monolithic ${MRA_GENERATED_DIR}/recompiled.cpp: regenerate with scripts/regen.sh.")
endif()
file(GLOB MRA_GENERATED_SOURCES CONFIGURE_DEPENDS "${MRA_GENERATED_DIR}/*.cpp")
if(NOT MRA_GENERATED_SOURCES)
    message(FATAL_ERROR
        "No generated code in ${MRA_GENERATED_DIR}. Run scripts/build-native.sh.")
endif()

add_subdirectory("${GBARECOMP_ROOT}" gbarecomp_build EXCLUDE_FROM_ALL)

configure_file(src/mra_build_config.h.in
    "${CMAKE_CURRENT_BINARY_DIR}/generated_config/mra_build_config.h" @ONLY)

if(MRA_REPLAY_ROUTES)
    get_filename_component(MRA_REPLAY_ROUTES_SOURCE "${MRA_REPLAY_ROUTES}" ABSOLUTE
        BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
    if(NOT EXISTS "${MRA_REPLAY_ROUTES_SOURCE}")
        message(FATAL_ERROR "MRA_REPLAY_ROUTES: ${MRA_REPLAY_ROUTES_SOURCE} not found")
    endif()
    message(STATUS "Test build: input replays embedded from ${MRA_REPLAY_ROUTES_SOURCE}")
else()
    set(MRA_REPLAY_ROUTES_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/src/replay_routes_none.cpp")
endif()

add_executable(MotoRacerAdvanceRecomp src/main.cpp "${MRA_REPLAY_ROUTES_SOURCE}"
    ${MRA_GENERATED_SOURCES})

# Keep the large guest shards cheaper to compile than the runtime, as MKSC
# does. The dispatch table and symbol map stay ordinary small units.
set(MRA_SHARDS ${MRA_GENERATED_SOURCES})
list(FILTER MRA_SHARDS INCLUDE REGEX "/recompiled_[0-9]+\\.cpp$")
if(MRA_SHARDS)
    set_source_files_properties(${MRA_SHARDS} PROPERTIES COMPILE_OPTIONS "-O1;-g0")
endif()

target_include_directories(MotoRacerAdvanceRecomp PRIVATE
    "${CMAKE_CURRENT_BINARY_DIR}/generated_config"
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
    "${MRA_GENERATED_DIR}"
    "${GBARECOMP_ROOT}/src/armv4t"
    "${GBARECOMP_ROOT}/src/gba"
    "${GBARECOMP_ROOT}/src/runtime"
    "${GBARECOMP_ROOT}/src/debug")
target_link_gbarecomp_runtime_stack(MotoRacerAdvanceRecomp)

if(APPLE)
    # Generated code maps guest calls onto the host stack. Windows and the web
    # reserve 16 MiB; a macOS main thread gets 8 MiB unless asked. This does
    # not reach the std::thread that `--tcp` creates (512 KiB on macOS), so
    # prefer --tcp-observe for debugging.
    target_link_options(MotoRacerAdvanceRecomp PRIVATE "LINKER:-stack_size,0x1000000")
endif()

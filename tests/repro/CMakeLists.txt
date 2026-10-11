# Native executables for the synthetic repro ROMs (tests/repro/README.md).
# Driven by scripts/repro-test.sh, which first generates each ROM, recompiles
# it with gba_recompile and its tests/repro/<case>.toml, and recompiles a BIOS
# image into GBARECOMP_GENERATED_BIOS_DIR.
#
# For each case it builds repro_<case>: our own src/main.cpp, which runs
# gbarecomp's full runtime (run_game), linked with that case's generated code,
# tests/repro/<case>_hooks.cpp if there is one, and the recompiled BIOS. The
# runtime library is built once for all cases.
cmake_minimum_required(VERSION 3.20)
project(mra_repro C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

get_filename_component(MRA_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(GBARECOMP_ROOT "${MRA_ROOT}/gbarecomp" CACHE PATH "gbarecomp checkout")
set(MRA_REPRO_GENERATED_ROOT "" CACHE PATH
    "Directory with one gba_recompile output directory per case")
set(MRA_REPRO_CASES "" CACHE STRING
    "Cases as <name>=<ROM SHA-1>, ;-separated (the SHA-1 is built in, as for the game)")
set(GBARECOMP_GENERATED_BIOS_DIR "" CACHE PATH "gba_recompile --bios output")

if(NOT MRA_REPRO_CASES)
    message(FATAL_ERROR "Set MRA_REPRO_CASES; scripts/repro-test.sh does.")
endif()
# The runtime would link a placeholder BIOS table otherwise, and every IRQ
# would then go through the interpreter: not the path the repros exercise.
if(NOT EXISTS "${GBARECOMP_GENERATED_BIOS_DIR}/bios_recompiled.cpp")
    message(FATAL_ERROR
        "No recompiled BIOS in '${GBARECOMP_GENERATED_BIOS_DIR}'. Set "
        "GBARECOMP_GENERATED_BIOS_DIR; scripts/repro-test.sh does.")
endif()

add_subdirectory("${GBARECOMP_ROOT}" gbarecomp_build EXCLUDE_FROM_ALL)

foreach(case IN LISTS MRA_REPRO_CASES)
    if(NOT case MATCHES "^([A-Za-z0-9_]+)=([0-9a-f]+)$")
        message(FATAL_ERROR "Bad MRA_REPRO_CASES entry: ${case}")
    endif()
    set(name "${CMAKE_MATCH_1}")
    set(gen "${MRA_REPRO_GENERATED_ROOT}/${name}")
    file(GLOB gen_sources CONFIGURE_DEPENDS "${gen}/*.cpp")
    if(NOT gen_sources)
        message(FATAL_ERROR "No generated code in ${gen}")
    endif()

    # src/main.cpp reads the game name and the ROM SHA-1 from this header.
    set(MRA_GAME_NAME "${name}")
    set(MRA_ROM_SHA1 "${CMAKE_MATCH_2}")
    configure_file("${MRA_ROOT}/src/mra_build_config.h.in"
        "${CMAKE_CURRENT_BINARY_DIR}/${name}_config/mra_build_config.h" @ONLY)

    # A case may add host code of its own, such as a function-entry hook.
    set(case_sources "")
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${name}_hooks.cpp")
        set(case_sources "${CMAKE_CURRENT_SOURCE_DIR}/${name}_hooks.cpp")
    endif()

    add_executable(repro_${name} "${MRA_ROOT}/src/main.cpp" ${gen_sources}
        ${case_sources})
    target_include_directories(repro_${name} PRIVATE
        "${CMAKE_CURRENT_BINARY_DIR}/${name}_config"
        "${gen}"
        "${GBARECOMP_ROOT}/src/armv4t"
        "${GBARECOMP_ROOT}/src/gba"
        "${GBARECOMP_ROOT}/src/runtime"
        "${GBARECOMP_ROOT}/src/debug")
    target_link_gbarecomp_runtime_stack(repro_${name})
    if(APPLE)
        # Same main-thread stack as the game executable (CMakeLists.txt).
        target_link_options(repro_${name} PRIVATE "LINKER:-stack_size,0x1000000")
    endif()
endforeach()

# Smoke test of the recompile pipeline on free test ROMs (no BIOS needed).
# Driven by scripts/smoke-test.sh, which first runs gba_recompile on each ROM
# with its tests/smoke/*.toml config.
#
# For each case it builds smoke_<case>: gbarecomp's test_rom_runner (direct
# boot at the cartridge entry, no BIOS; the result is r12, 0 = every test
# passed) linked with the generated code. ctest runs it natively, or under
# Node when configured with emcmake.
#
# With Emscripten it also links web_host_<case>: gbarecomp's browser host
# main() with the generated code and the canonical browser link options, the
# link step a game build needs. It is not run (that needs a BIOS and a page).
cmake_minimum_required(VERSION 3.20)
project(mra_smoke C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

get_filename_component(MRA_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(GBARECOMP_ROOT "${MRA_ROOT}/gbarecomp" CACHE PATH "gbarecomp checkout")
set(MRA_SMOKE_GENERATED_ROOT "" CACHE PATH
    "Directory with one gba_recompile output directory per case")
set(MRA_SMOKE_CASES "" CACHE STRING "Cases as <name>=<rom path>, ;-separated")
# Never pick up a recompiled BIOS: the test ROMs boot without one.
set(GBARECOMP_GENERATED_BIOS_DIR "${CMAKE_CURRENT_BINARY_DIR}/no-bios"
    CACHE PATH "Deliberately empty")
if(EMSCRIPTEN)
    # gbarecomp refuses an Emscripten configure without its browser backend.
    set(GBARECOMP_WEB_HOST ON CACHE BOOL "" FORCE)
endif()

if(NOT MRA_SMOKE_CASES)
    message(FATAL_ERROR "Set MRA_SMOKE_CASES; scripts/smoke-test.sh does.")
endif()

add_subdirectory("${GBARECOMP_ROOT}" gbarecomp_build EXCLUDE_FROM_ALL)
enable_testing()

foreach(case IN LISTS MRA_SMOKE_CASES)
    if(NOT case MATCHES "^([A-Za-z0-9_]+)=(.+)$")
        message(FATAL_ERROR "Bad MRA_SMOKE_CASES entry: ${case}")
    endif()
    set(name "${CMAKE_MATCH_1}")
    set(rom "${CMAKE_MATCH_2}")
    set(gen "${MRA_SMOKE_GENERATED_ROOT}/${name}")
    file(GLOB gen_sources CONFIGURE_DEPENDS "${gen}/*.cpp")
    if(NOT gen_sources)
        message(FATAL_ERROR "No generated code in ${gen}")
    endif()

    add_executable(smoke_${name}
        "${GBARECOMP_ROOT}/tools/test_rom_runner/main.cpp" ${gen_sources})
    target_include_directories(smoke_${name} PRIVATE
        "${gen}" "${GBARECOMP_ROOT}/src/armv4t")
    target_link_gbarecomp_runtime_stack(smoke_${name})
    if(EMSCRIPTEN)
        target_compile_options(smoke_${name} PRIVATE -mtail-call)
        # Node, with direct access to the host file system for the ROM path.
        # Memory and stack sizes as in gbarecomp's browser link options.
        target_link_options(smoke_${name} PRIVATE
            -pthread -mtail-call -sENVIRONMENT=node,worker -sNODERAWFS=1
            -sEXIT_RUNTIME=1 -sALLOW_MEMORY_GROWTH -sINITIAL_MEMORY=134217728
            -sSTACK_SIZE=16777216 -sDEFAULT_PTHREAD_STACK_SIZE=16777216)
    elseif(APPLE)
        target_link_options(smoke_${name} PRIVATE "LINKER:-stack_size,0x1000000")
    endif()
    add_test(NAME smoke_${name} COMMAND smoke_${name} "${rom}")
    set_tests_properties(smoke_${name} PROPERTIES
        PASS_REGULAR_EXPRESSION "RESULT: PASS" TIMEOUT 120)

    if(EMSCRIPTEN)
        add_executable(web_host_${name}
            "${GBARECOMP_ROOT}/packaging/web/main.cpp" ${gen_sources})
        target_include_directories(web_host_${name} PRIVATE
            "${gen}" "${GBARECOMP_ROOT}/src/armv4t" "${GBARECOMP_ROOT}/src/runtime")
        target_compile_options(web_host_${name} PRIVATE -mtail-call)
        target_link_gbarecomp_runtime_stack(web_host_${name})
        gbarecomp_web_host_link_options(web_options)
        target_link_options(web_host_${name} PRIVATE ${web_options})
    endif()
endforeach()

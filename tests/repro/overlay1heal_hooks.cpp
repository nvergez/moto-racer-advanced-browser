// RAM overlay selector for the opt-in overlay1heal repro (tests/repro/
// README.md), linked into repro_overlay1heal only. It tests the heal-tier
// guard of gbarecomp patch 0006: PCs the selector claims must never reach the
// self-heal tier, whose heals are keyed by PC and mode only.
//
// overlay1heal is overlay1's ROM with no corpus for either IWRAM image
// (overlay1heal.toml), run with RAM healing on (scripts/repro-test.sh). The
// selector compares the live IWRAM word at the dispatch target with image A's
// ROM source, as overlay1_hooks.cpp does. For A it answers 0 (not claimed):
// A's first dispatch is then an ordinary miss, and the heal tier compiles a
// heal of 0x03000000 from A's bytes. For anything else, image B included, it
// answers -1 (claimed, no compiled image matches). With 0006, B's dispatch is
// a miss that is bridged, and logs 0xB2. If the heal tier saw it, it would
// run A's heal for B, which logs 0xA1.
//
// MRA_REPRO_OVERLAY_SELECTOR=0 leaves it uninstalled, which shows that: no PC
// is claimed, and B runs A's heal. Built against a gbarecomp without 0006
// (MRA_HAVE_RAM_OVERLAY_SELECT=0, set by tests/repro/CMakeLists.txt), this
// file installs nothing. It prints which of the three applies, for
// scripts/repro-test.sh.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "gba_bus.h"
#include "runtime_arm.h"
#include "runtime_bus_bridge.h"

namespace {

#if MRA_HAVE_RAM_OVERLAY_SELECT
constexpr uint32_t kIwram = 0x03000000u;
constexpr uint32_t kRomBase = 0x08000000u;
constexpr uint32_t kImageA = 0x08000400u, kSizeA = 0x10u;
constexpr uint32_t kSizeB = 0x14u;  // image B, the longer one

uint32_t word_at(const uint8_t* p) {
    uint32_t v;
    std::memcpy(&v, p, sizeof v);
    return v;
}

int select_image(uint32_t pc, int /*thumb*/, const void** /*table*/, unsigned* /*len*/) {
    const uint32_t off = pc - kIwram;
    if (off >= kSizeB) return 0;  // outside both images
    gba::GbaBus* bus = gbarecomp::active_bus();
    if (!bus) return -1;
    const uint32_t word = off & ~3u;
    if (word < kSizeA &&
        word_at(bus->iwram_ptr() + word) ==
            word_at(bus->rom_ptr() + (kImageA - kRomBase) + word))
        return 0;
    return -1;
}
#endif

// Installed before main(): run_game() resets the selector only when it
// returns, and nothing else sets it in this executable.
struct InstallSelector {
    InstallSelector() {
#if MRA_HAVE_RAM_OVERLAY_SELECT
        const char* env = std::getenv("MRA_REPRO_OVERLAY_SELECTOR");
        const bool off = env && std::strcmp(env, "0") == 0;
        if (!off) g_runtime_ram_overlay_select = select_image;
        std::printf("overlay1heal: selector=%s\n", off ? "off" : "on");
#else
        std::printf("overlay1heal: selector=unavailable (this gbarecomp has no "
                    "g_runtime_ram_overlay_select)\n");
#endif
        std::fflush(stdout);
    }
} install_selector;

}  // namespace

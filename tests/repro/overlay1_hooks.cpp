// RAM overlay selector for the overlay1 repro (tests/repro/README.md), linked
// into repro_overlay1 only.
//
// overlay1 copies two code images, A and B, in turn to IWRAM 0x03000000 and
// calls each there (tests/repro/make_rom.py, OVERLAY1). Image A is in the main
// corpus (overlay1.toml); image B in a second one, compiled with
// `gba_recompile --output-prefix ovl_` (overlay1.ovl.toml). This selector,
// installed through gbarecomp's g_runtime_ram_overlay_select (patch 0006),
// compares the live IWRAM word at the dispatch target with the word at the
// same offset of each image's ROM source: A's answers 0 (the main table), B's
// answers 1 with ovl_kDispatchTable, and neither answers -1 (a dispatch miss).
// It checks only that one word, so it relies on the images differing at every
// offset, which make_rom.py guarantees. It reads the bus's backing arrays,
// never bus_read_*, which has side effects.
//
// MRA_REPRO_OVERLAY_SELECTOR=0 leaves it uninstalled: the main table then
// answers for 0x03000000 whichever image is resident, the behavior of a
// gbarecomp without the patch. Built against such a gbarecomp
// (MRA_HAVE_RAM_OVERLAY_SELECT=0, set by tests/repro/CMakeLists.txt from
// runtime_arm.h), this file installs nothing. It prints which of the three
// applies, for scripts/repro-test.sh.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "gba_bus.h"
#include "runtime_arm.h"
#include "runtime_bus_bridge.h"

#if MRA_HAVE_RAM_OVERLAY_SELECT
// The layout gba_recompile emits in every generated dispatch table.
struct DispatchEntry { uint32_t addr; uint8_t thumb; uint8_t resume; void (*fn)(void); };
extern "C" const DispatchEntry ovl_kDispatchTable[];
extern "C" const unsigned ovl_kDispatchTableLen;
#endif

namespace {

#if MRA_HAVE_RAM_OVERLAY_SELECT
constexpr uint32_t kIwram = 0x03000000u;
constexpr uint32_t kRomBase = 0x08000000u;
constexpr uint32_t kImageA = 0x08000400u, kSizeA = 0x10u;  // main corpus
constexpr uint32_t kImageB = 0x08000500u, kSizeB = 0x14u;  // ovl_ corpus

uint32_t word_at(const uint8_t* p) {
    uint32_t v;
    std::memcpy(&v, p, sizeof v);
    return v;
}

int select_image(uint32_t pc, int /*thumb*/, const void** table, unsigned* len) {
    const uint32_t off = pc - kIwram;
    if (off >= kSizeB) return 0;  // outside both images (B is the longer one)
    gba::GbaBus* bus = gbarecomp::active_bus();
    if (!bus) return -1;
    const uint32_t word = off & ~3u;
    const uint32_t live = word_at(bus->iwram_ptr() + word);
    const uint8_t* rom = bus->rom_ptr();
    if (word < kSizeA && live == word_at(rom + (kImageA - kRomBase) + word))
        return 0;
    if (live == word_at(rom + (kImageB - kRomBase) + word)) {
        *table = ovl_kDispatchTable;
        *len = ovl_kDispatchTableLen;
        return 1;
    }
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
        std::printf("overlay1: selector=%s\n", off ? "off" : "on");
#else
        std::printf("overlay1: selector=unavailable (this gbarecomp has no "
                    "g_runtime_ram_overlay_select)\n");
#endif
        std::fflush(stdout);
    }
} install_selector;

}  // namespace

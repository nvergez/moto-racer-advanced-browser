// Function-entry hook for the irqleak3 repro (tests/repro/README.md), linked
// into repro_irqleak3 only.
//
// F (0x08000200) is `bx lr` and has no static entry, so every call to it is
// bridged. This hook performs F's return instead: it sets R15 to LR and
// reports the call as handled. runtime_bridge_interpret() checks the hook
// registry before it interprets each instruction, and when a hook handles the
// call it returns at once; in IRQ-continuation mode it does so without popping
// the caller's call-return frame (src/runtime/runtime_arm_default_aborts.cpp,
// the gba_mod_function_entry() check in the interpreter loop, at the gbarecomp
// pin). That exit does not reach the heal-to-static check that the first part
// of patches/gbarecomp/0003 fixes, so only the second part (runtime_irq()
// drops frames left above the IRQ's entry depth) stops the leak here.
//
// The registry is part of gbarecomp's runtime whether or not mods are built
// (GBARECOMP_ENABLE_MODS is off here), and nothing else enables or disables
// hooks in this build, so the hook is registered and enabled once, before
// main().
#include <cstdio>
#include <cstdlib>

#include "mod_function_hooks.h"

namespace {

constexpr const char* kHookId = "repro.irqleak3.f";
constexpr uint32_t kF = 0x08000200u;

int return_to_caller(uint32_t /*addr*/, int /*thumb*/, ArmCpuState* cpu) {
    cpu->R[15] = cpu->R[14] & ~1u;  // F's `bx lr`; its caller is ARM code
    return 1;
}

struct InstallHook {
    InstallHook() {
        if (!gba_mod_register_function_entry_plugin(kHookId, kF, 0,
                                                    return_to_caller) ||
            !gba_mod_set_function_hook_enabled(kHookId, 1)) {
            std::fprintf(stderr, "irqleak3: cannot install the hook at 0x%08X\n",
                         kF);
            std::abort();
        }
    }
} install_hook;

}  // namespace

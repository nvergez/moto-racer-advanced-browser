# ADR 0001: Port the game by static recompilation with gbarecomp

**Status:** Accepted pending owner review
**Date:** 2026-10-10
**Closes:** the Phase 1 exit in [plan.md](../plan.md) ("`docs/adr/0001-*.md` confirming static recompilation, or switching approach, with evidence").
**Pins:** ROM Moto Racer Advance (Europe) `A9MP`, SHA-1 `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0`; retail BIOS SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492`; gbarecomp `5e89943528aee7bc1c399bdbd035364a4b41dd10`; mGBA 0.10.5 through `tools/analysis/harness`.
**Evidence:** [phase1-findings.md](../research/phase1-findings.md), [gbarecomp-integration.md](../research/gbarecomp-integration.md), [open-bios.md](../research/open-bios.md), PR #5 (toolchain and first build, merged as `a7efc60`; [toolchain.md](../toolchain.md)), and [phase2-diagnosis.md](../research/phase2-diagnosis.md). Section references below (§) point into the diagnosis unless a file is named.

## Context

The project ports the game to the browser and then improves on it ([plan.md](../plan.md)). [initial-findings.md](../research/initial-findings.md) chose static recompilation provisionally, to be confirmed by Phase 1.

What Phase 1 established ([phase1-findings.md](../research/phase1-findings.md)):

- The game was built with ARM's own toolchain (likely), so a byte-matching decompilation is impractical.
- Races are mode 1 affine backgrounds plus affine sprites, at 60 Hz. There is no software rasterizer.
- The cartridge holds two separately linked programs, a front end and a race program. Each copies its own ARM code image to IWRAM `0x03000000` with a CPU loop. The images overlap in `0x03000000`-`0x03000833` and differ there. About 94% of race instructions run from the race image. No code is modified after it is installed (verified dynamically).
- The BIOS surface is small (six SWIs), but the race takes the BIOS IRQ path about 229 times per frame and reads BIOS memory through a NULL pointer.

What the first build (PR #5) and the Phase 2 diagnosis showed:

- gbarecomp builds on macOS and discovers 2,259 functions. The native build boots to the title, but aborts at 3,600 frames with healing off, and the browser bundle aborts right after the title.
- The aborts come from a gbarecomp bug: an IRQ-continuation bridge leaves a call-return frame behind, and a later miss takes it as its stop PC (§1.1). A 17-line patch fixes it, natively and in the browser.
- 30 of the 35 ROM misses disappear with `static_resume_all = true` (§2.1). Five are armcc switch slots that need reviewed seeds (§2.2).
- gbarecomp cannot tell the two IWRAM images apart. Declaring the race image alone runs the wrong code with no error (§3.1). Runtime healing runs stale code (§3.3), and running whole images through the existing RAM dispatch hook, which is meant for small position-independent routines, overflows the browser's call stack (§3.3).
- A prototype that compiles each image as its own corpus and picks the corpus per dispatch from the live IWRAM bytes is fully static on two routes, natively and in the browser (§3.2, option C).
- Frames differ from mGBA for identified reasons: one gbarecomp PPU bug (§5.1), blend arithmetic that differs by at most one step (§5.2), mid-frame write timing in about 0.5% of front-end frames (§5.4), a missing OBJ cycle budget (§5.6). Races leave lockstep with mGBA from the camera fly-in, in every gbarecomp backend, interpreter included, which points to emulation timing rather than recompilation (§6). The interpreter reference runs BIOS SWIs as recompiled code unless the BIOS is interpreted too; with it interpreted, the sampled race frames do not change (§7.1).

## Decision

### 1. Static recompilation with gbarecomp, at the pinned commit, plus a short queue of local patches

We confirm static recompilation and gbarecomp. The engine stays pinned at `5e89943`. Every fix we need lives in `patches/gbarecomp/` (the mechanism from PR #5), with a README row, and each is offered upstream when the owner decides. No patch is committed inside the submodule.

Evidence that the approach works on this ROM (§3.2, option C prototype, on top of the fixes in §1.1 and §2.1):

- `boot_to_race` (4,400 frames) and `full_race_cross` (25,000 frames, a whole 3-lap race and the return to the front end): `self_heal_coverage=FULLY_STATIC dispatch_misses=0 interpreted_insns=0`, and `GBARECOMP_STRICT_STATIC=1` passes on both.
- 500 of 500 sampled frames are pixel-identical to gbarecomp's interpreter reference (`GBARECOMP_FORCE_INTERP=1`). That reference interprets the cartridge code and the IRQ handlers but runs BIOS SWIs as the same recompiled code as the build under test (§7.1). With the BIOS interpreted too, the reference still matched option C on all 88 sampled frames of `boot_to_race` (§7.1); the full race was not re-run that way.
- The same code in headless Chromium runs the full race with 0 misses, and 500 of 500 framebuffer CRCs equal the native frames.
- Every gbarecomp problem that stops the game from running is fixed by a small local patch (17 lines for the call-return leak, about 40 for the overlay selector, 1 for the end-of-run watchdog) or avoided by configuration. The rest affect fidelity, not whether the game runs (§5, §6); the one PPU bug among them takes a 27-line patch.

Conditions of these measurements (§3.2): inputs were applied, and the sampled frames captured, at VBlank start by a diagnostic-only engine patch (`GBARECOMP_DIAG_VBLANK_REPLAY=1`), which P2-02 and P2-03 replace with committed mechanisms. The race corpus also had roots that this ADR does not list (`0x030044C0` Thumb, `0x030044D0` ARM, reviewed in P2-10). Counts measured after those replacements may differ; the zero counts are what must hold.

What this evidence does not cover yet: the GP, Traffic, abort, restart, options-save and multiplayer routes; link play; race fidelity against mGBA (§6). Those are Phase 2 tasks.

### 2. IWRAM overlays: two corpora and a resident-image selector in the dispatcher

This is option C in §3.2.

- **Race image = main corpus.** `game.toml` declares `[[code_copy]] runtime_start = 0x03000000, source_start = 0x083F6820, size = 0x49C4`, with reviewed IWRAM roots.
- **Front-end image = second corpus.** A second config declares `[[code_copy]] runtime_start = 0x03000000, source_start = 0x081596FC, size = 0x834` with its own roots, plus `entry_pc = 0x03000000` and `static_resume_all = true` as in the prototype (without resume entries, returns into front-end IWRAM code after an SWI unwind would be misses, §2.1). `scripts/regen.sh` compiles it with the existing `gba_recompile --output-prefix fe_`. That gives a separate `fe_kDispatchTable`.
- **Engine patch.** A gbarecomp patch (about 40 lines) adds a game-owned selector, `g_runtime_ram_overlay_select`, consulted for RAM PCs in `dispatch_resolve` and `runtime_has_static_entry`. It returns 0 (use the main table), 1 plus a table (look the PC up there; the engine enters the entry as it would a static hit, keeping tail calls, resume aliases and the yield ABI), or -1 (an ordinary dispatch miss).
- **Our selector** (`src/`, about 60 lines) compares the live 32-bit IWRAM word at the target PC with the same offset in each image's ROM source. A match picks that corpus. No match is a dispatch miss, so strict static mode aborts on it instead of running the wrong body.

Why the per-dispatch signature check rather than a flag set by the image loaders (option B): it does not depend on the loaders being the only writers, an entry word that matches neither image is a dispatch miss (so strict static mode aborts instead of running a body), and its cost is one IWRAM read per RAM dispatch (about 2,000 per frame in a race).

What it checks, and what it does not: the selector validates only the 32-bit word at the dispatch target. Direct B/BL inside a selected body are C calls by name and are never re-checked (`external/arm-recomp-core/profiles/armv4t_gba/arm_codegen.cpp:510-548`, arm-recomp-core `1f13cdf`, the submodule commit at our pin). And a CPU copy writes one word at a time, so in the middle of a copy every word still matches the old image or the new one: a dispatch then would select a corpus silently, not miss. Correctness therefore rests on the invariants below, not on the check alone.

Invariants it relies on, each checked:

- None of the 525 overlapping words is equal between the two images (measured). Our selector will re-check this from the ROM at startup and refuse to run if it ever fails.
- No code is modified after install, apart from the two IRQ tables, which are data (Phase 1, verified dynamically).
- No code executes in the overlap while an image is being copied. Measured in the mGBA harness (writes to `0x03000000`-`0x03000833`, IME and `0x03007FFC`, and the PCs executed in the overlap), the game clears IME and zeroes the IRQ vector `[0x03007FFC]` before every copy and sets them again only after it:
  - boot: IME stays 0 through the race-image copy (frame 279) and the front-end copy (293); the vector `0x03000708` and IME are set at 294; the first overlap PC executes at 295;
  - race load (`boot_to_race`): IME cleared and vector zeroed at 3286, copy at 3290, vector `0x03004844` and IME set at 3293, and no overlap PC executes in 3287-3292;
  - race exit (`full_race_cross`): IME cleared and vector zeroed at 21789, front-end copy at 21794, vector `0x03000708` and IME set at 21795.

  P2-11 repeats this check on every route.

Conditions that come with it:

- **RAM healing stays off** (`GBARECOMP_RAM_OVERLAY_HEAL` unset). Heals are keyed by PC only (§3.3). The patch should also skip the heal tier for PCs the selector claims. Our executable will refuse to start with RAM healing on.
- **Coverage is proven per route** under `GBARECOMP_STRICT_STATIC=1`, and correctness by comparing the recompiled build with gbarecomp's interpreter (decision 5).
- **Hooks are keyed per image.** Phase 4 hooks into IWRAM code must name the image (race or `fe_`), not only the address.
- **Link play is unsupported** until the selector is saved and restored with the multiplayer `RuntimeArmContext` (`runtime_arm.cpp:1603-1635`).

**Fallback** if the patch has to be dropped before upstream takes it: option D (race image static, front end interpreted through `g_runtime_force_interp_hook`). It works natively and in the browser and needs no change to gbarecomp's runtime, but its predicate is game-owned code, so the browser build still needs our own main (patch 0008, or our own link step; §3.2). It is never strict-static, costs a predicate call per instruction, and dropped frames in the browser menus. A patch-free alternative that keeps the front end static, a merged dispatch table (see "Alternatives considered"), is untested and would be prototyped first if the patch had to go.

**Upstream fit.** gbarecomp's documented mechanism for executable bytes that change under a static entry is `g_runtime_force_interp_hook`, that is option D (`src/armv4t/runtime_arm.h:72-78`), which lowers the odds that upstream accepts the selector (U5) as written. Upstream already has pieces of a multi-image design:

- `--output-prefix` exists "so multiple immutable code images can be linked into one executable" (`tools/gba_recompile/main.cpp:139-141`; upstream commit `2be1b81`, "support namespaced multi-image output").
- `RuntimeArmContext::program_dispatch` is documented as "Optional per-program dispatch, required when heterogeneous images are implemented" (`src/armv4t/runtime_context.h:44-46`), and `dispatch_resolve` consults it first (`runtime_arm.cpp:869-870`). It applies only with a resumable (multiplayer) context, though, and the callback runs the body itself, the contract that made option A fail in the browser.
- A per-program registry that binds each program's dispatch tables and fails closed on unknown PCs is planned (`docs/MIXED_CARTRIDGE_MULTIPLAYER.md`, "Implementation order", step 1), for mixed-cartridge multiplayer rather than overlays.

So U5 is best shaped as a resolve-style `program_dispatch` (return the entry, let the engine enter it) that also works without a resumable context, rather than as a new global.

### 3. Companion configuration and engine fixes

These are required whatever the overlay mechanism:

- `static_resume_all = true` (§2.1), only together with the call-return leak patch (§1.1). Without the patch, the setting makes leaks more frequent (§2.1).
- The leak patch (§1.1) and the one-line IRQ-depth guard on the end-of-run quit (§1.2), so that runs stop exactly at `--frames`.
- Reviewed seeds, each with a `note` giving its evidence: the 239 armcc switch slots (§2.2), the hidden roots (`0x030004DE`, `0x0800255C`, `0x08002580`, `0x080025B0`, `0x08004168`; §2.3), `[[code_copy]]` for the two EWRAM SRAM routines, and whatever the route gates find. The 47 seeds the prototype took unreviewed from miss reports are inputs to that review, not entries to copy.
- A project-owned main in the browser build, so the selector exists in the browser: a one-line patch adding `GBARECOMP_WEB_MAIN` and `GBARECOMP_WEB_MAIN_FLAGS` overrides to `build_web.sh` (U8 in §9). A patch-free route exists: our own link step, as PR #5's smoke tests already do (`tests/smoke/CMakeLists.txt:72-80`, `gbarecomp_web_host_link_options()`) and as [toolchain.md](../toolchain.md) plans for Phase 3. But `build_web.sh` also builds the page around the binary (expected hashes, `--embed-private-rom`, `--dev`, the AudioWorklet DSP, the exported config), which our own step would have to copy and keep in step with each engine bump. Phase 2 takes the one-line patch; Phase 3, which builds the player's page, revisits it.

### 4. BIOS: the retail dump for development and testing; an open BIOS as the target for players

**Development and Phase 2 testing use the owner's retail BIOS dump** (SHA-1 `300c20df…`), kept in the gitignored `bios/` directory, never committed, and loaded on both sides of every comparison (mGBA harness and gbarecomp). Runs keep the BIOS boot intro, because the mGBA reference boots through it and both sides must start the same way. `[bios].skip_intro` would also leave the BG2/BG3 affine matrices at zero in gbarecomp ([toolchain.md](../toolchain.md), known issue 6). Races do not depend on that, since HBlank DMA0 writes BG2PA-PD on every line (Phase 1 §2), but the mode 4 screens outside races would if the game never writes the matrix there (**unverified**).

This revises [open-bios.md](../research/open-bios.md) §6, which recommended the Cult-of-GBA BIOS for development, written when no dump was available. Reasons:

- The owner now has a dump.
- All Phase 1 and Phase 2 evidence, and every mGBA baseline we have, uses the retail BIOS.
- Phase 2 measures recompilation and emulation correctness. Swapping the BIOS at the same time would add a second source of divergence: open-bios.md §5.2 expects timing drift between BIOS implementations, and requires the same BIOS on both sides of the exit test.
- The Cult-of-GBA boot does not reach the cartridge under gbarecomp at our pin. It halts with IME off, and gbarecomp ends HALT only on an interrupt the CPU takes ([toolchain.md](../toolchain.md), known issue 5).

**For players, the target remains an open-source BIOS**: Cult-of-GBA recompiled, in our own cleaned repository (open-bios.md option A′), so a player supplies only the ROM. It is a direction, not a validated choice. It needs, in order:

1. An mGBA A/B against retail with drift-tolerant metrics (open-bios.md §5.3). Phase 1 already gives the SWI census (six SWIs) and the open-bus facts: Cult-of-GBA leaves the retail after-IRQ value `0xE55EC002`.
2. A fix for gbarecomp's HALT exit condition.
3. Strict static coverage of the open BIOS.
4. The A′ cleanup.

If it fails, the fallbacks are open-bios.md options F (player's own BIOS, interpreted) or local builds only.

**Out of scope here:** whether any browser bundle is published at all. Every bundle contains code translated from the game, and that decision belongs to the owner before Phase 3 hosting ([gbarecomp-integration.md](../research/gbarecomp-integration.md) §5.6; open-bios.md, "Related issue outside this doc's scope").

### 5. Differential-testing baseline

**Inputs.** The harness input scripts in `tools/analysis/input/` are the source of truth for routes. One converter turns a script into a gbarecomp replay. Inputs are applied at VBlank start, and all tools name frames by the harness (mGBA) counter: a capture taken at VBlank start while gbarecomp's PPU `frame_count` is k shows harness frame k+1 (§7.3). The exact replay offset is validated by a Phase 2 task, because the two conventions used so far were not cross-checked (§7.3). Each route also carries checkpoints: game-state events that the captures show on both engines, such as DISPCNT becoming `0x1741` when a race starts, or the resident IWRAM image changing. A gbarecomp run counts only if they hold. Inputs are timed on mGBA's frames and races are not in lockstep (§6), so a replay can drift onto another screen, and comparison 1 cannot notice: both backends drift the same way.

**Captures.** Where a headless `--frames N` run stops, and so which frame `--dump-png` writes, depends on the backend and on the game state: the recompiled build and the interpreter can end one frame apart (§7.3). Every comparison across backends or with mGBA therefore uses captures taken at VBlank start, never `--dump-png`. The sample point is after the VBlank-timed DMA and before the VBlank IRQ is raised, on both engines (gbarecomp runs the VBlank DMA, then the input hook, then raises the IRQ, `runtime_bus_bridge.cpp:597-604`); P2-03 implements it and establishes the matching point in mGBA.

**Reference.** mGBA 0.10.5 through our libmgba harness (deterministic), with the retail BIOS, full BIOS boot, a fresh save and the same scripted inputs.

**Two comparisons, two questions:**

1. **Recompilation correctness: recompiled build against gbarecomp's interpreter** (`GBARECOMP_FORCE_INTERP=1`), **with the BIOS interpreted too.** On its own, the interpreter backend interprets the cartridge code and the IRQ handlers but sends every SWI through `runtime_swi` to the recompiled BIOS (§7.1), so a translation bug in the six BIOS SWIs would be the same on both sides. In the reference run our main therefore installs `g_runtime_force_interp_hook` returning 1 for PCs below `0x4000`; `dispatch_resolve` consults it before the BIOS table (`runtime_arm.cpp:874-880`), so this needs no engine patch (P2-02). With it, the reference's coverage banner reads `NOT_STATIC` (each BIOS entry is a bridge), so no gate reads that banner. The target is bit-exact: framebuffer CRC and per-region RAM hashes, both taken at VBlank start, on every frame. Both sides share gbarecomp's device model, so we expect any difference to be a recompiler, dispatch or overlay bug. That expectation is **unverified** for RAM: the prototype compared 500 sampled framebuffers and no RAM (§3.2), and gbarecomp's own cross-backend state hash deliberately leaves out bookkeeping that legitimately differs between backends (`COSIM_ORACLE.md:123-131`). P2-09 measures RAM-hash equality before it becomes a gate; if some state differs for a documented backend reason, the fallback is a named list of excluded regions, each with its cause, or a different sampling point. To localize a divergence, gbarecomp's per-instruction fingerprint ring (`GBARECOMP_INSN_TRACE=1` with `GBARECOMP_FP_SAVE`, `runtime.cpp:2089-2094`, `runtime_arm.cpp:300-307`; it keeps about 8M instructions, `runtime_arm.cpp:382-388`) diffs two runs instruction by instruction. The recompiled side also runs under `GBARECOMP_STRICT_STATIC=1`.
2. **Emulation fidelity: gbarecomp against mGBA**, in two layers (§7.2):
   - *Layer 1, exact:* render-time per-scanline state (video registers with unused bits masked, palette[0], and CRCs of OAM, palette and VRAM, sampled where each engine renders the line).
   - *Layer 2, pixels at 5-bit precision:* exact on lines with no color effect; ±1 step per channel only on lines with an active brightness or alpha effect, the proven bound of the arithmetic difference (§5.2).
   - Plus per-frame hashes of game-state RAM, excluding regions shown to differ for timing reasons only (for example the IRQ stack slot `0x03007F9C`, Phase 1 §6). The regions and their masked sub-ranges are part of P2-03's capture schema, because hashes are taken at capture time; P2-09 compares them.

   Every remaining difference is either fixed or listed in a per-route allowlist with its cause. The comparator reports the first divergence (frame, line, column).

**Renderer.** gbarecomp's default HLE scanline renderer, the one the browser build uses. The LLE build (`scripts/build-native.sh --lle`) is a cross-check at each engine bump: the two were byte-identical on 2,717 boot and 410 race frames (§5.3).

**Run conditions.** Headless, `SDL_AUDIODRIVER=dummy`, fresh save, `GBARECOMP_SELFHEAL_RECOMPILE=0`, RAM healing off. Both engines were deterministic under these conditions (§7.6). Store CRCs, hashes and diff summaries, never raw frames; frames show game graphics and are never committed.

**Evidence rules.** A match on a static screen is not evidence (§7.4). Frames sampled for a check are chosen where the renderer is busy (§7.5).

Concretely, Phase 2's exit ("a full cup plays identically to mGBA under the input replays", [plan.md](../plan.md)) means:

- the gbarecomp runs follow the cup route (its checkpoints hold);
- comparison 1 is exact on every frame of the cup;
- comparison 2 passes with only allowlisted, explained differences;
- race results (finishing position and time per race) equal mGBA's.

## Alternatives considered

### Overall approach

| Alternative | Why rejected |
|---|---|
| Wrap an emulator (mGBA compiled to WebAssembly) | Works today, but gives the same result as existing sites, with no function-level hook points for the Phase 4 work ([initial-findings.md](../research/initial-findings.md)). It remains the fallback in plan.md's risk table; the evidence above shows no need for it. |
| Matching decompilation, then port | The ARM proprietary toolchain (likely; Phase 1 §3) makes a byte-matching decompilation impractical. Non-matching hand-written C stays possible for the subsystems Phase 4 touches (plan.md Phase 5). |
| Remake | The goal is this game, not one like it. |

### IWRAM overlays (measured in §3.2)

| Alternative | Why rejected |
|---|---|
| A. Signature check in the existing `g_runtime_ram_dispatch_hook`, no engine patch | Passes natively, but the hook runs each body inside the callback, so host frames nest (5,106 deep in the intro decoder) and the browser fails with `RangeError: Maximum call stack size exceeded` at about frame 1,400. The hook is documented as a canonicalizer for position-independent code copied to transient RAM (`runtime_arm.h:65-70`); running whole images through it was our misuse, not a gbarecomp defect. |
| Merged dispatch table, no engine patch (**unverified**, not prototyped) | Compile both images with `--output-prefix` and link our own `kDispatchTable`/`kDispatchTableLen`, the symbols the runtime looks up (`runtime_arm.cpp:34-41`), merged from the generated tables. Each overlap entry points to a trampoline that checks the live word and `GBARECOMP_TAIL_CALL`s the resident image's body (`runtime_arm.h:220`, `:228`), or calls `runtime_dispatch_miss` when that image has no function there. Feasible on paper and needs no engine change. Costs: it depends on the generated `DispatchEntry` layout, which each generated table redeclares rather than taking from a public header (`tools/gba_recompile/main.cpp:570`), and on the sorted-table lookup (`runtime_arm.cpp:815-840`); the trampoline must set `g_runtime_resume_pc` from the selected image's own entry; and `runtime_has_static_entry` would answer "yes" for a PC that only the non-resident image has, which changes how bridges and heals stop. The first thing to prototype if the selector patch has to be dropped. |
| B. Image flag set by `[[mod_function_hook]]` callbacks on the two loaders | Same browser failure when paired with the hook. With the selector it works, but it trusts that the loaders are the only writers, and mod hooks are disabled when the mod runtime reactivates plugins (`mod_runtime.cpp:2065`). Kept only as an optional debug cross-check. |
| D. Interpret the front-end image through `g_runtime_force_interp_hook` | Never strict-static, a predicate call per instruction (2.32 billion in a full race), and interpreted menus that drop frames in the browser. It is gbarecomp's documented mechanism for code that changes under a static entry (`runtime_arm.h:72-78`). Kept as the fallback. |
| E. Runtime healing (PR #5's approach) | Runs the front-end body inside the race (heals keyed by PC only), then aborts. Unavailable in the browser, where the race loop is bridged and aborts. |
| N. Declare the race image only | Silent corruption: exit 0, 1.16 billion interpreted instructions, 3 of 65 menu frames correct. |
| Both images in one corpus | A corpus holds one function per (address, instruction set) (§3.1). |
| Guarded `[[code_copy]]` in the recompiler (Phase 1's option 3) | Would need recompiler, config and dispatch changes: overlay configs drop a second `[[code_copy]]` with the same `runtime_start`. The selector is the runtime half of that idea with a much smaller patch. Not prototyped. |

### BIOS

| Alternative | Why rejected |
|---|---|
| Cult-of-GBA for development (open-bios.md §6) | Mixes two sources of divergence while Phase 2 measures recompilation, and does not boot under gbarecomp at our pin (decision 4). |
| gbarecomp's opt-in HLE (`[bios].hle = true`) or mGBA's HLE for testing | Approximate SWI timing, and mGBA-derived on both sides, so the two would not be independent (open-bios.md §5.3). |
| Ship the retail BIOS translation in the bundle (gbarecomp's default, open-bios.md option E) | Distributes a translation of Nintendo's BIOS. |

### Differential testing

| Alternative | Why rejected |
|---|---|
| Pixel-exact equality with mGBA | Fails on every fade frame (up to about 36,000 pixels differ by one step) for an arithmetic difference that is proven bounded, and whose hardware truth is unknown (§5.2). |
| Pixels with a tolerance and no per-line state | Hides real timing bugs: frame 320 against 321 (a wrong BLDY) differs by only one step (§7.2). |
| A test-only build with mGBA's blend arithmetic | The tested renderer would no longer be the shipped one, and hardware may match neither. |
| gbarecomp's interpreter or co-simulation only | Shares the device model with the recompiled code, so it cannot see PPU or timing differences ([gbarecomp-integration.md](../research/gbarecomp-integration.md) §4). It is comparison 1, not the whole baseline. |
| gbarecomp's mGBA oracle over TCP | Needs a separate mGBA build, and gbarecomp's `--tcp` mode ignores `GBARECOMP_INPUT_REPLAY` (gbarecomp-integration.md §4). Our harness already gives deterministic dumps and per-scanline logs. |
| LLE renderer as the default | Identical output on this game (§5.3), and not what the browser build uses. |

## Consequences

**Positive**

- A path to a fully static, hookable build on native and web, with measured results on two routes.
- Failures are loud: strict static mode turns any uncovered or unmatched RAM dispatch into an abort, and comparison 1 catches wrong code that coverage cannot see.
- The baseline separates recompilation bugs (comparison 1) from emulation fidelity (comparison 2), so each difference has an owner.

**Negative and costs**

- We carry about nine local gbarecomp patches by the end of Phase 2 (PR #5's two plus the queue in [phase2-plan.md](../phase2-plan.md)) on a fast-moving engine. Each engine bump means re-applying and re-testing them, plus the LLE cross-check.
- Two generated corpora: a second `gba_recompile` pass, two generated directories in CMake, +1.5 MB native and +1.25 MB wasm, and 81 ROM functions duplicated under `fe_`.
- The browser build needs our own main, which Phase 3 needs anyway.
- ROM-based tests can only run where the ROM and BIOS are: the owner's machine. CI runs only tests without game data, such as the synthetic repro ROMs and the comparator's unit tests.
- Coverage is per route. New routes (championship, league, Ultimate, link play) can still find gaps after release, as they did for gbarecomp's other games.
- Healing must stay off for RAM code on every target, so a gap in IWRAM coverage on an untested route falls back to the interpreter bridge. In the browser, that freezes the page until the gap is fixed, unless the optional bridge frame-boundary patch is adopted (§1.4).

**Open risk**

- Races leave lockstep with mGBA (§6), so the exit test as defined may fail for reasons outside recompilation. Phase 2 investigates first. If the cause is a timing-model difference that neither engine is known to get right, the owner decides between fixing gbarecomp's timing, anchoring replays to game events, or revising the exit criterion. The proposed fallback: keep comparison 1 exact, keep comparison 2 exact through the front end, and in races compare up to the first divergence and then on race results.

**Follow-ups**

- [phase2-plan.md](../phase2-plan.md) turns these decisions into tasks.
- Revisit this ADR if upstream takes a different overlay API (its planned per-program registry, or `program_dispatch` without a resumable context, is the likely shape, decision 2), if the race-lockstep investigation changes the baseline, if P2-09 finds that RAM hashes legitimately differ between backends, or when the open-BIOS validation concludes.

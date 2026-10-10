# Phase 2 diagnosis

**Date:** 2026-10-10
**Scope:** Why the first gbarecomp build of the game (PR #5) misbehaves, and what it takes to fix it: the runtime aborts and watchdogs, the dispatch misses, the two code images that share IWRAM, the browser abort, and the frames that differ from mGBA. The decisions drawn from it are in [ADR 0001](../adr/0001-port-via-static-recompilation.md); the work is planned in [phase2-plan.md](../phase2-plan.md).
**Status:** Native and headless-browser runs on one machine, against mGBA 0.10.5. Nothing was checked on hardware. All fixes below are prototypes in scratch copies of gbarecomp; none is in the repository yet.

## Pins

Every address, frame number and line number below depends on these.

| | |
|---|---|
| ROM | Moto Racer Advance (Europe) `A9MP`, SHA-1 `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0` |
| BIOS | retail, SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492` |
| gbarecomp | `5e89943528aee7bc1c399bdbd035364a4b41dd10` with our patches 0001 and 0002 (PR #5). Source citations (`file:line`) are at this commit |
| Repository base | `build/toolchain-and-scaffold` at `b90e960` (PR #5), because `main` had no `game.toml` yet. PR #5 has since merged as `a7efc60`, and its files there are identical to `b90e960` (`git diff b90e960 a7efc60` changes only files that came from `main`) |
| Reference | libmgba 0.10.5 through `tools/analysis/harness` (deterministic: repeated runs give identical dumps) |
| Browser | headless Chromium (Playwright 1.64.0, chromium-headless-shell 1248), audio muted; emsdk 6.0.10 |
| Machine | Apple M4 Pro, macOS; native runs headless with `SDL_AUDIODRIVER=dummy` |

Frame numbers are the harness (mGBA) frame counter on the `boot_to_race` route (`tools/analysis/input/boot_to_race.txt`) unless stated otherwise. Section 7.3 explains how gbarecomp's own frame counter maps to it. "VBlank N" is gbarecomp's VBlank-start counter, as printed by the instrumented builds of section 1; it runs close to, but is not the same as, the harness frame number.

## How the evidence was produced

Four investigations ran in parallel, each in its own scratch directory outside the repository, with its own patched copy of gbarecomp:

| Topic | Question |
|---|---|
| runtime-bugs | The IRQ watchdog, the 3,600-frame abort, results that change with `--frames`, and the 35 ROM dispatch misses |
| web-abort | Why the browser bundle aborts after the title screen |
| iwram-overlays | How to compile the two IWRAM code images that share `0x03000000` |
| ppu-diffs | Why frames differ from mGBA, and what the differential-test baseline should be |

Prototype code, logs, frame dumps and the patched gbarecomp copies stay local: they contain or were produced from ROM-derived output. Two investigations (runtime-bugs and web-abort) found the same main bug independently, with different instrumentation; their results agree.

Labels:

- **verified**: reproduced, with the evidence given;
- **likely**: supported by evidence, but the mechanism or a step was not isolated;
- **unverified**: a hypothesis.

Owners: **our config** (`game.toml`, seeds), **our code** (our tools, scripts and comparisons, and how our code uses gbarecomp's APIs), **gbarecomp bug**, **gbarecomp missing feature**, or **unknown** (an emulation-fidelity difference where neither gbarecomp nor mGBA is known to match hardware).

## Summary

| # | Symptom | Root cause | Owner | Confidence | Fix |
|---|---|---|---|---|---|
| 1 | Abort after 200M interpreted instructions at `0x08003E70`: natively at guest frame ~2,717, in the browser right after the title | An IRQ-continuation bridge leaves a call-return frame behind; a later mainline miss takes it as its stop PC | gbarecomp bug | verified | Patch (§1.1) |
| 2 | IRQ watchdog, "handler at depth 1 did not iret after 4000000 dispatches" | The sticky end-of-run quit has no IRQ-depth guard | gbarecomp bug | verified | One-line patch (§1.2) |
| 3 | Results depend on `--frames` | End-of-run handling plus #1; deterministic | gbarecomp bug | verified | #1 and #2 (§1.3) |
| 4 | The interpreter bridge never presents a frame, polls input or honors `--frames` | Present-in-place runs only from generated code | gbarecomp missing feature | verified | Static coverage; optional patch (§1.4) |
| 5 | Inside a bridge, BIOS IntrWait and the SWI handler run interpreted | The interpreter does not model HALT; the bus `halted` flag stays set | gbarecomp bug | verified | Report upstream; harmless once coverage is static (§1.5) |
| 6 | 30 of 35 ROM misses | Return addresses after a BL, reached after the SWI unwind; no resume entries | our config | verified | `static_resume_all = true` (§2.1) |
| 7 | 5 ROM misses, 2 more hidden behind them | armcc switch tables of B instructions are not decoded | gbarecomp missing feature | verified | Reviewed `[[extra_func]]` per case slot (§2.2) |
| 8 | 2 IWRAM misses, 4 hidden roots | The front-end IWRAM image is not declared | our config (blocked on #10) | verified | Overlay strategy (§3) |
| 9 | Call-return stack overflow at `return_pc=0x00000BD4` | Grows one entry per frame while `0x08004168` is bridged once per frame | gbarecomp bug (suspected) | unverified | Seed `0x08004168`; re-test with #1's patch (§2.4) |
| 10 | Declaring the race image alone runs the wrong code without any error | gbarecomp keys code by (address, instruction set) only | gbarecomp missing feature | verified | Selector patch plus a second corpus (§3) |
| 11 | RAM healing runs stale front-end code in the race, then aborts | Heals are keyed by PC and mode, never validated or invalidated | gbarecomp missing feature | verified | Keep RAM healing off (§3.3) |
| 12 | `g_runtime_ram_dispatch_hook` overflows the browser call stack | The hook runs each body inside the callback, one host frame per dispatch; it is documented for small position-independent routines, and the prototype ran whole images through it | our code (hook used outside its documented purpose) | verified | Do not use the hook for this (§3.3) |
| 13 | Without static IWRAM code the race freezes, then aborts | The race main loop is bridged and never returns | our config plus #4 | verified | Overlay strategy (§3) |
| 14 | BIOS logo fade (frames 220-269) differs from mGBA by up to 31 steps | OBJ pixels ignore BLDCNT bit 4 | gbarecomp bug | verified | Patch (§5.1) |
| 15 | Fades and race haze differ by exactly 1 step | Different blend arithmetic; hardware truth unknown | unknown | verified (bound) | ±1 tolerance on effect lines (§5.2) |
| 16 | "One frame ahead", "off by two steps" in PR #5 | The two tools number frames differently | our code | verified | Alignment rule (§7.3) |
| 17 | Isolated front-end frames differ by 2+ steps on a few lines | Mid-frame writes land 3-6 lines apart in about 0.5% of frames | unknown | verified | Per-line state comparison, allowlist (§5.4) |
| 18 | Race start grid sprites differ by up to 30 steps | gbarecomp has no per-line OBJ cycle budget | gbarecomp missing feature | verified | Patch, as a fidelity option (§5.6) |
| 19 | Race sprites on haze lines differ by 2-5 steps | Brightness on semi-transparent OBJs that BLDCNT does not select | unknown | likely | Hardware test first (§5.7) |
| 20 | Races leave lockstep with mGBA from the camera fly-in on | The race program starts one frame later in gbarecomp (CPU timing at the hand-off) | unknown | likely | Investigation task (§6) |
| 21 | PR #5's title frames "match mGBA" while the build is broken | Static screen; the run was spinning in BIOS IntrWait | (consequence of #1) | verified | Never accept static-screen matches (§7.4) |

Not causes, checked and ruled out: anything browser-specific (§4), HLE versus LLE rendering (§5.3), per-scanline race haze and HBlank IRQ timing (§5.5).

---

## 1. Runtime bugs

### 1.1 IRQ-continuation bridges leak call-return frames (the 0x08003E70 abort)

**Symptom.** Natively with healing off, `--frames 3600` ends with `SELF-HEAL bridge for 0x08003E70 exceeded 200000000 instructions without returning to stop_pc=0x08004E10 (current pc=0x00000364)`, exit code 134. The browser bundle, which has no runtime healing, aborts with the same message after about 1,332 published frames, right after the title appears. **verified** (both investigations, natively and in Chromium).

**Mechanism.** **verified** with instrumented copies of gbarecomp (bridge entry and exit logs, an IRQ-exit depth check):

1. The front end's IWRAM code has no static entry, because the image is not declared (§3). The VCount IRQ handler (ROM, native code) calls the IWRAM sound mixer with `bl 0x08011B00` at `0x08004E0C`, which pushes the return address `0x08004E10`. `0x08011B00` is a veneer (`ldr r12,[pc]; bx r12`) to `0x030004DD`, the front-end mixer in Thumb.
2. The mixer is run by the interpreter in IRQ-continuation mode. That mode does not stop at its stop PC; it "heals to static" at the first PC that has a static entry. Here that is `0x08004E10`, which has one only because `b 0x08004E10` at `0x08004D5C` targets it. The bridge does not pop the frame the BL pushed (`src/runtime/runtime_arm_default_aborts.cpp:640-643`; no-pop branch for IRQ continuations at :676).
3. `runtime_irq()` raises and restores `g_call_return_floor` around the handler, but never restores `g_call_return_depth` (`src/armv4t/runtime_arm.cpp:1569-1575`). gbarecomp's resumable (multiplayer) path does restore it (`runtime_arm.cpp:1268`). So the stale `0x08004E10` frames survive the IRQ return: `IRQ_LEAK vbl=867 ret=0x00000348 entry_depth=0 exit_depth=2 stack=08004E10 08004E10`.
4. At VBlank 1029 the mainline returns from the 30-frame wait routine `0x080033E8` to `0x08003E70`. That address has no static entry (no resume entries, §2.1). The bridge sees call depth 2 instead of 0, treats the miss as a nested call and takes the stale `0x08004E10` from the top of the stack as its stop PC (`runtime_arm_default_aborts.cpp:464`): `BRIDGE_IN vbl=1029 pc=0x08003E70 stop=0x08004E10 depth=2`.
5. `0x08004E10` only ever runs in IRQ mode, and IRQs go to native code, so the interpreter never reaches it. In mGBA (harness `--trace-pc`), `0x08004E0C` and `0x08004E10` execute only with CPSR mode `0x92`, 6,036 times between frames 609 and 2800. The bridge interprets the whole game until the 200M cap (`kBridgeIterationCap`, `runtime_arm_default_aborts.cpp:86`) at VBlank 2717.

The browser takes the same path. It reports only 1,332 published frames at the abort because the bridge presents no frames (§1.4); nothing about it is browser-specific (§4).

**Minimal repro, no Nintendo data.** Two synthetic 4 KiB ROMs built by small Python scripts reproduce the chain on the pristine pin. Both leave the header logo zero and run with `--bios-skip-intro`.

- Repro 1 (SHA-1 `5ce18c7c345bcf14a1650d2d628e93b7e2159c6a`): a VBlank IRQ handler at `0x08000180` does a `bl` to a veneer that tail-calls, through a pointer in EWRAM, a function with no static entry. Config: `static_resume_all = true`, `speculative_literal_harvest = false`, `[bios] skip_intro`, `[[extra_func]]` `0x08000180`. Run with `GBARECOMP_SELFHEAL_RECOMPILE=0 --bios-skip-intro --no-window --frames 2000`: after 1,024 IRQs, `generated call-return stack overflow at return_pc=0x08000188`, exit 134.
- Repro 2 (SHA-1 `b59d626bc60fefd820bd9d4ae2c283f38383e031`): `static_resume_all = false`; the handler's BL returns to a loop label (`0x08000194`) that is also a static entry, and the main loop calls a `VBlankIntrWait` wrapper. The bridge for `0x080000FC` gets the IRQ-only `0x08000194` as its stop PC, interprets 84M instructions by frame 600 and overflows by frame 2000.

**Fix (prototype, 17 lines, two parts).** (a) When an IRQ-continuation bridge heals at a static entry, call `runtime_call_should_return(pc)` so the frame whose return the interpreter just carried out is popped, as a generated return would pop it. (b) At the end of `runtime_irq()`, truncate `g_call_return_depth` to its value at handler entry, as the resumable path does. Each part alone fixes the game; together they also pass both synthetic repros and gbarecomp's 52 tests. With the fix, the stock config runs 3,600, 5,400 and 12,000 frames natively with no abort, the browser bundle runs 6,011 frames, and interpreted instructions over 2,700 frames fall from 227,860,069 to 119,865,640. **verified**. Frame 2700 is also byte-identical to the unfixed build, but that is the static title screen, and the unfixed build was then running inside the stale bridge, so the match says nothing about guest behavior (§7.4). Whether the fix leaves guest behavior unchanged is **unverified**: the check that can show it is comparison 1 against the interpreter over busy frames, through VBlank-start captures ([phase2-plan.md](../phase2-plan.md), P2-05).

The web-abort investigation wrote part (b) alone as a 13-line patch; it is the same change.

Risk: part (a) matches return addresses by value, as `runtime_call_should_return` already does, so a loop head equal to a pending return address could pop early. gbarecomp already has that ambiguity.

### 1.2 End-of-run IRQ watchdog

**Symptom.** `runtime_irq: handler at depth 1 did not iret after 4000000 dispatches (R15=0x00000018, cpsr=...92) — abandoning`: once in 1,800- to 2,715-frame runs, 173 times in the 1,300-frame run ([toolchain.md](../toolchain.md), problem 1).

**Cause.** **verified**. It only happens after `--frames` is reached. Headless present-in-place sets a sticky quit flag at the first eligible VBlank after the limit. From then on `runtime_should_yield()` returns true at every generated instruction, including inside IRQ handlers: the quit check at `src/runtime/runtime_bus_bridge.cpp:1035` has no IRQ-depth guard, while the VBlank-yield check below it (:1054) has one. An IRQ that arrives after the quit dispatches `0x18`, the recompiled BIOS vector yields at once, and the drive loop (`runtime_arm.cpp:1555-1567`) re-dispatches 4,000,000 times before abandoning the IRQ. IRQs keep arriving only while an interpreter bridge is still running and ticking the clock, so the count of messages is the number of IRQs between the quit and the end of that bridge: 1 when it ends in the same frame, 173 for `--frames 1300`, 569 for 1100, 772 at 12,000. In every run, every watchdog event comes after the quit event.

**Fix.** `if (g_frame_present_quit && g_irq_nest_depth == 0u) return true;`. With that guard there were 0 watchdogs at 1,300, 2,700, 3,600 and 12,000 frames. **verified**.

### 1.3 Results that depend on `--frames`

**Cause.** **verified**: deterministic end-of-run behavior, not nondeterminism and not heal-cache state. The quit request is seen only by generated code at IRQ depth 0 in User or System mode; the interpreter bridge never checks it. The stale bridge from §1.1 runs from VBlank 1029 until something interpreted reaches `0x08004E10`, which only happens after the quit, when the abandoned VCount handler is interpreted and calls the mixer. Unfixed stop frames by `N`: `N` ≤ 1028 stops at `N`; 1100 and 1300 stop at 1391; 1800 at 1804; 2000 at 2018; 2450 at 2462; 2700 at 2706; 2714 at 2715; `N` ≥ 2716 aborts at VBlank 2717. With `GBARECOMP_PRESENT_IN_PLACE=0` there is no quit hook at all; the stale-stop bridge starts at VBlank 609 on the miss at `0x08003D84` and aborts at 2270.

Evidence of determinism: two runs at `N=2000` give identical logs and PNGs; the stock and instrumented builds give identical PNGs at 1,300 and 2,700. The heal cache is not read with `GBARECOMP_SELFHEAL_RECOMPILE=0` (`src/runtime/overlay_loader.cpp:445-453` returns before the warm load at :481).

With §1.1, §1.2 and the bridge frame boundary of §1.4, every `N` tested (1000, 1300, 2700, 2716, 3600, 5400, 12000) stops exactly at `N`. The `GBARECOMP_PRESENT_IN_PLACE=0` path can still overshoot while a bridge runs (3,600 stopped at 3,644), because it has no hook to poll. Once all code on a route is static there are no bridges, and the question disappears (inference from the mechanism; the fully static configurations in §3 stop exactly at `N`).

Why `--dump-png` changes the end of a 2,700-frame run (exactly 2,700 frames and no watchdog, against 2,706 and one watchdog without it) is **unverified**.

### 1.4 The bridge has no frame boundary

A bridge interprets a missed subtree until it returns to its caller. While it runs, no generated prologue runs at IRQ depth 0, so:

- no frame is presented: in the browser, about 55 frames per second were published until about 21 s (published frame ~1030, where the bridge starts), then only 1047, 1104, 1137, 1155, 1169, 1222, 1287 and 1332 at 2-second intervals until the abort at 35.8 s (**likely**: the timing matches, but presentation was not instrumented);
- no input is applied: `GBARECOMP_INPUT_REPLAY` is applied in the runner loop only (`src/runtime/runtime.cpp`, `apply_input_replay`), so in the race-loop bridge of §3 the bike stays at 0 km/h with the lap timer at 0"00 (gbarecomp frames 3830, 4000 and 4400 are identical; mGBA shows 173 km/h at 4000) (**verified**);
- `--frames` cannot stop the run (§1.3);
- a legitimately long call, such as a RAM main loop that only returns when the race ends, hits the 200M cap.

Two prototype patches add a frame boundary to the bridge. Both call the present hook at the first instruction after a VBlank start, in User or System mode outside IRQs, and end the bridge on a quit request:

- runtime-bugs (39 lines with the quit guard of §1.2): returns from the bridge on quit; the guest then unwinds.
- web-abort (60 lines): also resets the 200M cap whenever a frame is presented, returns without overwriting the CPU when the hook loaded a save state (checked through `g_runtime_state_epoch`; untested), and logs once per bridge that it is presenting frames.

With §1.1 and the web-abort version, the stock browser bundle (IWRAM still interpreted) played the `boot_to_race` route from a frame-indexed replay into a race, at about 60 published frames per second, to lap 2 with no abort in 200 s. **verified** in two runs. Without §1.1, the same patch only hides the leak: the game keeps running inside the stale bridge.

Trade-off: it turns a loud runaway into slow interpretation, and an unpaced bridge reached about 200M instructions in 12-17 s in headless Chromium on the M4 Pro, against roughly 7.5M instructions per second needed at 60 fps (estimate, **unverified**). With full static coverage (§3) no bridge runs on the routes tested, so this patch is a safety net for untested routes in the browser, not part of the fix. The ADR leaves it as a later decision.

### 1.5 Stale HALT inside a bridge

**verified**: the interpreter writes HALTCNT through the raw bus and does not model HALT, so the bus `halted` flag stays 1. `runtime_should_yield()` ends with `return halted;` (`runtime_bus_bridge.cpp:1138`), so every native prologue reached from the bridge's `runtime_swi()` unwinds at once, and R15 comes back as `0x348` (then `0x08` once per frame): `swi-returned-elsewhere ... pc=0x00000348 cpsr=0x2000001F halted=1`. The interpreter then interprets BIOS IntrWait and the SWI handler. IRQs are still delivered and VBlanks advance, so the result is functionally correct, but the path differs from native.

This likely explains the storm of IME and HALTCNT writes (about 10,000 per frame at BIOS PCs `0x344`, `0x35C` and `0x370`, against 1.7 per frame in mGBA) that the ppu-diffs investigation saw from about frame 2439 in the static healing-off build (inference: the storm falls inside the stale bridge of §1.1, whose last 64 PCs loop in IntrWait `0x344`-`0x374`; not tested separately).

## 2. Dispatch misses in ROM code

PR #5's config had 37 misses on boot to the title: 35 in ROM, 2 in IWRAM.

### 2.1 Thirty misses are return addresses

**verified**. After every SWI, gbarecomp unwinds the whole host stack: `GBARECOMP_TAIL_SWI` returns, the BL site's R15 check fails, and the cancel cascade runs to the runner or to the IRQ drive loop, which re-dispatches R15 (`runtime_arm.cpp:1500-1508`; `runtime_arm.h:225-231`). The guest's next `bx lr` or `pop {pc}` then dispatches a mid-function return address, which has no entry when `static_resume_all` is off. A classifier script confirmed that each of the 30 follows a `bl`. Examples: `0x080042C8` (after `bl 0x8011af4`, the DivArm veneer, 511 times), `0x08003E70`, `0x08003D84`, `0x08004DC0`, `0x0801289C`.

gbarecomp's `docs/TOML_SCHEMA.md` describes `static_resume_all` as needed "for strict end-to-end AOT builds because an IRQ or SWI may resume at any instruction boundary". With it, `gba_recompile` emits 20,401 resume aliases across 2,001 host functions, and misses drop from 37 to 10-11. It also removes the 0x08003E70 abort without the §1.1 patch, by giving that address an entry, but the leak remains and gets more frequent (275 to 459 leaked frames per run), and any IRQ-path miss then leaks one frame per call (§2.4). So `static_resume_all` and the §1.1 patch go together.

Under input replay, PR #5's config without `static_resume_all` aborts in the front end before any race (`SELF-HEAL bridge for 0x08003D84 ... stop_pc=0x08004E10` at about frame 2,250). The same config with `static_resume_all = true` reaches the race with menus pixel-identical to mGBA through frame 3300. That the mechanism is §1.1 plus missing resume entries is **likely**; that the setting removes the abort is **verified**.

The miss report flagged `0x08001E44`.. and `0x08002630`.. as jump-table candidates. They are consecutive BL return sites (a false positive of the heuristic, which flags runs of adjacent misses).

### 2.2 armcc switch tables

**verified**. Five misses are case slots of armcc switch statements: `0x08011B98`, `0x08011BB8`, `0x08011BD4` (32-case table at `0x08011B90`) and `0x08012460`, `0x08012480` (11-case table at `0x08012458`). armcc compiles a switch as `cmp rM,#N; addls pc,pc,rM,lsl #2; b default; b case0; ...`. gbarecomp's finder treats the `addls` as an unresolved indirect branch and ends the function there: its PC-write evaluator needs a shift of 0 and a known `rM` (`src/recompile/function_finder.cpp:1030-1039`), and automatic table detection handles abs32 data tables only (:905-908). `[[jump_table]]` has no format for a table of B instructions either (`abs32`, `abs16`, `pcrel_thumb` and `pcrel_arm` all read data words), so each slot needs an `[[extra_func]]`. Code reached only through those slots stays undiscovered, which hides two more misses (`0x08011DDC`, `0x08011DE8`).

A ROM scan finds 20 such dispatchers (Phase 1 counted 20 `addls pc` switches): 16 in ROM code, with 239 case slots sized from the preceding `cmp` and checked to be all `b` instructions, and 4 in the race IWRAM image. Adding the 239 slots as `[[extra_func]]` takes discovery from 2,259 to 2,728 functions and removes these 7 misses, with no other change in behavior. The list is generated, so every entry still needs human review and a `note` (the `game.toml` rules). A wrong bound would decode data as code; the `cmp` bound and the all-`b` check reduce that risk.

### 2.3 IWRAM misses and hidden roots

**verified**. The 2 IWRAM misses (`0x030004DC` Thumb, `0x03000708` ARM) are the front-end image, which is not declared because it shares `0x03000000` with the race image (§3). Interpreting it accounts for most interpreted instructions and triggers §1.1. With §1.1 fixed, at 2,700 frames 75.2% of 119.9M interpreted instructions are one call of `0x03000000` (the intro player, 90.2M) and 24.5% are `0x030004DC` (the mixer).

Declaring the front-end image exposes four roots that were hidden inside interpreted IRQ code: `0x030004DE` (Thumb target of `bx r0`), `0x0800255C` and `0x080025B0` (front-end IRQ table at `0x030007B0`; slot 2 is `0x0800255C`, slot 3 `0x08002580`, the rest `0x080025B0`, from mGBA IWRAM dumps at frames 600, 2000 and 3000), and `0x08004168` (target of a tail jump through a function pointer at `0x0800485C`).

A configuration with the switch slots, the front-end image, the two EWRAM SRAM routines and these roots was fully static on the boot to the title: 0 misses and 0 interpreted instructions to 12,000 frames, exact `--frames`, frames identical to mGBA at 1300, 1800, 2700, 3600 and 5400, and 15 s instead of 81 s for 12,000 frames. It is **not safe for races**: the race image would run the front end's compiled bodies at the same addresses without any error (§3). It proves only that the boot path can be static.

### 2.4 Call-return overflow at 0x00000BD4 (unverified cause)

With the front-end image static and `static_resume_all` on but `0x08004168` still a miss bridged about once per frame, `generated call-return stack overflow at return_pc=0x00000BD4` appeared around frame 2,450 (VBlank ~2422). The stack grew by one entry per frame (0, 105, 205, ... 898 at frames 300-2300) up to `kCallReturnStackSize` (1,024). Seeding `0x08004168` keeps the depth at 0. The overflow happened with two different overlay mechanisms, so it is independent of them. **unverified** cause: probably the bridge restoring the call-return stack around a per-frame miss while IRQ code runs natively. Whether the §1.1 patch alone also prevents it was not tested.

## 3. The two IWRAM code images

Phase 1 found that the front end (ROM `0x081596FC`, 0x834 bytes) and the race program (ROM `0x083F6820`, 0x49C4 bytes) each copy their own ARM code image to IWRAM `0x03000000`, and that about 94% of race instructions run from the race image ([phase1-findings.md](phase1-findings.md), §4).

### 3.1 Why gbarecomp cannot tell them apart

**verified** (source reading and a control run):

- A corpus holds one function per (address, instruction set): the finder's visit key and early return (`src/recompile/function_finder.cpp:34`, `:475`).
- `map_addr_to_source` uses the first `[[code_copy]]` range that contains the address (`function_finder.cpp:105-125`), and overlay configs drop a `[[code_copy]]` whose `runtime_start` matches an existing one (`tools/gba_recompile/config.cpp:941-947`).
- At run time, `dispatch_resolve` and the heal tier look a function up by PC and CPSR.T only (`runtime_arm.cpp:860-920`; `overlay_loader.cpp:35`).
- Generated bodies read their literal pools through the bus at the runtime PC, so a body is only valid while its own image is resident.
- In the race corpus, `0x03000708` ARM is a resume alias inside the race function at `0x030006F4`, and `0x030004DC` Thumb is a speculative Thumb function decoded from race ARM bytes. In the front end, those same addresses are the IRQ dispatcher and the mixer stub.

**Control run (option N).** Declaring only the race image as a `[[code_copy]]` and replaying `boot_to_race` for 4,400 frames: exit code 0, no error message, 1,156,417,995 unmapped accesses and 1,156,415,124 interpreted instructions, 197 s. Only 3 of 65 sampled menu frames are pixel-identical to mGBA, against 58 of 65 for every correct variant. This is why overlay handling is required rather than optional.

**The images are easy to tell apart.** None of the 525 overlapping 32-bit words is equal between the two images (first words `0xE92D4FF3` and `0xE3A00640`). Live IWRAM matches the front-end ROM source at frame 2450 except the IRQ table at `0x030007B0`-`0x030007E3`, and the race source at frame 4200 except `0x030048E8`-`0x0300491B`, consistent with Phase 1's finding that nothing else is written after install.

### 3.2 Options measured

All options except E and N use the same two corpora: the race image as the main corpus (`[[code_copy]]` `0x03000000` from `0x083F6820`, size `0x49C4`, plus the two SRAM routines, `static_resume_all`, and roots `0x03004844`, `0x030009A4`, `0x0300170C`, `0x03001CB0`, `0x03001BC4`, `0x03000000`, `0x030044D0` in ARM and `0x030044C0`, `0x030044C2` in Thumb), and the front-end image compiled alone from a second config (`[[code_copy]]` `0x03000000` from `0x081596FC`, size `0x834`, `entry_pc` `0x03000000`, `static_resume_all = true`, roots `0x030004DC`/`0x030004DE` Thumb and `0x030004EC`, `0x03000708` ARM) with the existing `gba_recompile --output-prefix fe_` (`tools/gba_recompile/main.cpp:139-141`, `:1422-1426`). That yields a second dispatch table, `fe_kDispatchTable`. Routes: `boot_to_race` (4,400 frames) and `full_race_cross` (25,000 frames, including the switch from the race back to the front end). "Interpreter reference" means gbarecomp's interpreter backend (`GBARECOMP_FORCE_INTERP=1`): it interprets the cartridge code and the IRQ handlers, but BIOS SWIs run as recompiled BIOS code, the same as in the build under test (§7.1).

Conditions of every run in this section, native and browser: inputs were applied at VBlank start, and frames were captured at VBlank start, by a diagnostic-only engine patch (`GBARECOMP_DIAG_VBLANK_REPLAY=1` and VBlank-start shot dumps; its shots are named by harness frame, §7.3). That patch is not proposed for the repository; P2-02 and P2-03 replace it. The race config also compiled option B's two `[[mod_function_hook]]` guards on the loaders (`0x080001F4`, `0x08159F94`), whose callbacks were disabled outside options B and "select plus flag". The race mixer's entries, from the ROM bytes: the ROM veneer at `0x0816280C` (`ldr r12,[pc]; bx r12`) jumps to `0x030044C1`, so `0x030044C0` is a Thumb entry, and its first instruction is `bx r0`; `0x030044C2` is the Thumb code that the caller's `r0` selects (it was a runtime miss), and it ends with `add r0,pc,#8; bx r0`, which enters ARM `0x030044D0`. Phase 1 names one or the other ([phase1-findings.md](phase1-findings.md) §4: `0x030044C2` in the findings table, `0x030044C0` in the proposed `game.toml`); both are real entries. How the finder reaches each of them without a seed is **unverified**.

| Option | How it picks the image | Native result | Browser result | Verdict |
|---|---|---|---|---|
| **C. Overlay table selector** (engine patch, about 40 lines) | New `g_runtime_ram_overlay_select`, consulted in `dispatch_resolve` and `runtime_has_static_entry` for RAM PCs. The game-owned selector compares the live IWRAM word at the target PC with each image's ROM source and returns 0 (use the static table), 1 plus a table (look the PC up there; the engine enters the entry itself, so tail calls, resume aliases and the yield ABI are kept) or -1 (an ordinary dispatch miss) | `boot_to_race`: `FULLY_STATIC`, 0 misses, 0 interpreted, 6.0 s. Full race: `FULLY_STATIC`, 0 misses, 0 interpreted, 42.8 s. `GBARECOMP_STRICT_STATIC=1` passes on both (5.6 s, 41.3 s). 51,061,920 selector calls in the full race (about 2,000 per frame), 0 without a matching image. No host-frame nesting by construction: the patch returns the selected entry from `dispatch_resolve`, and `runtime_dispatch_tail` enters it with `GBARECOMP_TAIL_CALL` (`runtime_arm.cpp:943-947`), a guaranteed tail call under Emscripten (`runtime_arm.h:215-220`); the browser's full race ran without the `RangeError` that option A hits (host stack depth itself was not measured). 500 of 500 sampled frames identical to the interpreter reference | Full race, 25,000 frames, `FULLY_STATIC`, 0 misses, exit 0, 55.5 fps (headless pacing cap). 500 of 500 framebuffer CRCs equal the native frames | **Adopted** |
| A. Signature-checked `g_runtime_ram_dispatch_hook` (no engine patch) | The existing hook checks the live word; for the front end it looks up `fe_kDispatchTable`, sets `g_runtime_resume_pc` and calls the body itself | Both routes `FULLY_STATIC`, strict passes, 500/500 frames identical. But up to 5,106 nested host frames in the intro decoder loop (`0x03000230`/`0x0300025C`), and 1,952,336 hook-dispatched bodies return with a changed call-return depth | `RangeError: Maximum call stack size exceeded` at about 26.8 s (frame ~1,400, intro) | Rejected: browser |
| B. Loader hooks set a flag (`[[mod_function_hook]]` on `0x080001F4` and `0x08159F94`) | The loader callbacks record the image being installed and decline, so the copy runs unchanged | The callbacks fired twice each over the full race; the flag agreed with the signature check on all 51,061,920 calls. With A's hook: same as A. With C's selector: same as C | With A's hook: same stack overflow | Rejected as primary: trusts that the loaders are the only writers; saves one IWRAM read per dispatch |
| D. Race image static, front end interpreted (`g_runtime_force_interp_hook`) | A predicate returns true for image PCs while the word at `0x03000000` is not the race image's first word. It runs before every generated instruction (`runtime_bus_bridge.cpp:1020-1031`) | `boot_to_race` 10.2 s: 104.2M bridged plus 26.2M stepped instructions, predicate called 161M times. Full race 59.9 s, predicate called 2.32 billion times. 1 recorded miss (`0x03000708`), `NOT_STATIC`. Frames identical to the interpreter reference | `boot_to_race` completes, 88 of 88 CRCs match, but only 4,400 of 5,121 guest frames presented (52.4 fps) | Fallback only: never strict-static, per-instruction cost, interpreted menus drop frames, no hooks for front-end code |
| E. Runtime healing, no IWRAM `[[code_copy]]` (PR #5) | `GBARECOMP_RAM_OVERLAY_HEAL=1` natively; the browser has no healing | Healing on (cold and warm cache): race frames differ from 3300, abort around frame 4,100 at a wild PC (`SELF-HEAL bridge for 0x126CC000`). Healing off: abort around frame 5,100 (§3.4) | Abort at 80.5 s (§3.4) | Rejected: runs the wrong code |
| N. Naive `[[code_copy]]` of the race image (control) | None | §3.1: silent corruption | not run | Rejected |

Running the race image on the static table and the front end on its own corpus also needs `static_resume_all` (§2.1) and reviewed ROM seeds: the prototype used 47 seeds taken from miss reports without review.

The overlay prototypes also used a project-owned browser link step: `packaging/web/build_web.sh` always links `packaging/web/main.cpp` (`build_web.sh:212-222`), so game-owned code such as the selector cannot reach the browser without either our own link step or a small patch adding `GBARECOMP_WEB_MAIN` and `GBARECOMP_WEB_MAIN_FLAGS` overrides (the prototype's choice).

Limits of these results:

- Not run with option C: GP and Traffic races, abort to the menu, restart, the multiplayer lobby, the options save. Phase 1 found that the same two loaders handle all of them (likely, **unverified** for C).
- The patch does not save and restore the selector in the multiplayer `RuntimeArmContext` (`runtime_arm.cpp:1603-1635`), so link play is untested.
- `runtime_dispatch_miss` still consults the heal tier, so `GBARECOMP_RAM_OVERLAY_HEAL` must stay off (it is off by default).
- The selector checks only the word at the dispatch target, so it relies on no self-modifying code (Phase 1, verified dynamically), on no equal words in the overlap at a dispatch target (measured: 0 of 525), and on no overlap code running while an image is being copied. A word-by-word copy leaves every word matching one image or the other, so a dispatch mid-copy would select a corpus, not miss. The last condition was measured in mGBA on boot, race load and race exit: IME is 0 and the IRQ vector `[0x03007FFC]` is zeroed during every copy (ADR 0001, decision 2).
- The prologue scan adds speculative Thumb functions decoded from ARM bytes to both corpora (82 IWRAM Thumb roots in the race corpus). They are dead code unless dispatched, but they are not real functions.
- The front-end corpus walks into 81 ROM roots through tracked BX and duplicates them under the `fe_` prefix: +1.5 MB native and +1.25 MB wasm compared with a build without overlays. No link collisions were seen.
- Strict static proves coverage on a route, not correctness. Correctness here comes from the comparison with the interpreter reference, which covered 500 sampled framebuffers and no RAM, and ran BIOS SWIs as recompiled code on both sides; with the BIOS interpreted too, 88 of 88 sampled `boot_to_race` frames still matched (§7.1). That RAM matches bit for bit at VBlank start is **unverified**. The two backends also end a run in different states (full race: `final_pc=0x0800e8ac ppu_vcount=160` recompiled, `final_pc=0x0800e8d4 ppu_vcount=43` interpreter), which is why comparisons use VBlank-start captures (§7.3).
- The counts above were measured with the diagnostic VBlank-start replay and the extra roots listed at the top of this section. With P2-02's replay, or with a different root set, the counts can differ; the zero counts are what must hold.

### 3.3 Why the existing mechanisms fail

**RAM healing runs stale code** (**verified**). RAM heals are keyed by PC and mode only (`heal_key`, `overlay_loader.cpp:35`), with no check of the live bytes and no invalidation. They are compiled synchronously from a snapshot taken at the first miss (`overlay_loader.cpp:509-528`) and never warm-loaded, because `region_bytes` rejects RAM PCs (`overlay_loader.cpp:384`; `warm_loaded=0`). The heal for `0x03000000` is built from the front-end image (its body starts with `stmdb sp!,{r0,r1,r4-r11,lr}`, the front end's first word). The race then calls `0x03000000` (mGBA call trace: from `0x0300317C` at frame 3613) and runs the front-end body. Frames match the interpreter until 3250, differ from 3300, and the run aborts around frame 4,100. With the same setting, the ppu-diffs investigation saw a black screen for the whole race.

**`g_runtime_ram_dispatch_hook` nests host frames** (**verified**). The hook must run the body inside the callback, because `dispatch_resolve` returns `nullptr` after it (`runtime_arm.cpp:882-894`). Every fall-through or indirect transfer inside the front-end image goes back through the dispatcher and the hook, adding a host frame instead of a tail call. Natively each VBlank yield unwinds the stack, so it survives, even under `GBARECOMP_STRICT_STATIC`; wasm does not. This is the hook working as documented, not a gbarecomp defect: `runtime_arm.h:65-70` describes it as an "optional game-owned canonicalizer for position-independent code copied to transient RAM addresses" that "returns non-zero after dispatching a byte-verified target", and other gbarecomp game repositories use it only for short, position-independent leaf routines. Running whole overlay images through it was the prototype's choice (option A).

### 3.4 Without static IWRAM code, the race cannot run in the browser

**verified**. The race main loop `0x03001CB0` is entered from ROM (`gf_tfunc_0815AF42`) and only returns when the race ends. Without a static entry it runs in a nested bridge whose stop PC (`0x0815AF4A`) is far away, and the bridge has no frame boundary (§1.4). Natively with healing off: `SELF-HEAL bridge for 0x03001CB0 exceeded 200000000 instructions without returning to stop_pc=0x0815AF4A` at about frame 5,100 (about 1,800 race frames). In the browser, with the §1.1 fix applied, the page froze at published frame 3,748 about 12 s before the same abort. Healing is unavailable in wasm (`overlay_loader.cpp:427-431`), so static IWRAM code is the only fast path there.

## 4. Nothing browser-specific

**verified**. The browser abort is gbarecomp's own bridge cap (`std::abort` in `runtime_bridge_interpret`), with the same address, stop PC and current PC as the native run. A build with `--profiling-funcs` gives the stack `abort <- runtime_bridge_interpret <- dispatch_resolve <- runtime_dispatch_with_exchange_tail <- runtime_dispatch <- run_game <- main`. Every browser run logs the save mount, `Audio processor ready`, `host_backend=web abi=2` and no out-of-memory or pthread error; the page reports a queue overflow count of 0. With the §1.1 and §1.4 patches the page ran for 200-240 s (over 13,000 published frames) with no runtime error.

For browser regression tests, drive routes with a frame-indexed input replay rather than timed key presses: the mapping from published frames to guest frames varied between runs, and a keyboard route keyed on published frames reached the title in one run and the intro in another (cause **unverified**).

## 5. Frame differences against mGBA

### 5.1 OBJ ignores BLDCNT bit 4 (BIOS logo fade)

**verified**, gbarecomp bug. An OBJ pixel only counts as a color-effect 1st target when the OBJ is semi-transparent; BLDCNT bit 4 (OBJ is a 1st target) is ignored, so brightness and alpha never apply to normal sprites (`src/gba/gba_ppu.cpp:1299-1301` and `:2009` set `t1 = blend_enabled(ux) && obj_mode == 1`). The BIOS logo is made of normal 8bpp OBJs, so it stays at full brightness while mGBA fades it to white. The same code serves both the native compositor (shared by HLE and LLE) and the wide compositor.

- The BIOS writes BLDCNT=`0x3FBF` at frame 219 line 163 (PC `0x1CDC`), then BLDY 1 to 16 every 2 frames from frame 220 (PC `0x1D14`); gbarecomp's `GBARECOMP_MMIO_DUMP` shows the same PCs, values and scanlines.
- mGBA OAM at frame 240: entries 0-8 are mode-0 8bpp OBJs, 16-24 their OBJ-window copies; DISPCNT=`0x9802`, WINOUT=`0x3F27`.
- Fix (17 lines added, 10 removed): `t1 = blend && (mode 1 || BLDCNT bit 4)`, with a separate semi-transparency flag so the forced-alpha rule (`top[x].layer == 4` at `:1369` and `:2129`) stays limited to semi-transparent OBJs. Frame 240 drops from 3,622 differing pixels to 300, all 1 step in red (color `0x7D4A` brightened at BLDY=11: mGBA (25,25,31), gbarecomp (24,25,31)). It changes exactly frames 220-269 out of 2,717, and frames 1-330 then have no difference beyond ±1.

Minimal repro: mode 0, OBJ enabled, one normal mode-0 OBJ, BLDCNT=`0x0090` (OBJ 1st target, brighten), BLDY=16. Expected a white sprite; gbarecomp draws it unchanged.

### 5.2 Blend arithmetic differs by at most one step

**verified** bound, hardware truth **unknown**. gbarecomp works in 5-bit, with a 6-bit green that uses palette bit 15, and rounds +8 for brighten and alpha and +7 for darken (`gba_ppu.cpp:497-541`). mGBA 0.10.5 (32-bit color build) expands colors to 8 bits and computes on the packed word with truncation. A model of each formula, applied to the pre-effect image rebuilt from the mGBA dump, reproduces its own engine exactly (38,400 of 38,400 pixels at frames 300 and 321), and the two models disagree on exactly the pixels that differ (2,034 and 2,033). An exhaustive table over all 32 values and every EVY (and EVA/EVB) gives differences only in {-1, 0, +1}. gbarecomp's commit `f2273fb` asserts its rounding but cites no source.

Consequence: up to about 36,000 pixels per fade frame, and 135,109 pixels over the race fly-in, differ by exactly one step, on lines with an active effect whose registers are identical in both engines.

### 5.3 HLE and LLE renderers are identical here

**verified**. Stock HLE and LLE builds produce byte-identical frames and identical render-time line state: 2,717 of 2,717 boot frames, and 410 of 410 race frames (interpreter replay, frames 3290-3699), with and without the §5.1 fix. They share `render_scanline_internal`. Bitmap modes 3 and 5 are untested (the game uses mode 4 only outside races).

### 5.4 Mid-frame write timing

**verified** symptom, cause **unknown**. A few front-end frames show larger, timing-shaped differences: 294, 296, 607, 610, 1031, 1393-1395, 1864, 1873, 2149-2165, 2188, 2482, 2498 and 2968-2973. For example, at frame 610 the BLDY `0x10` write takes effect at line 117 in mGBA and line 123 in gbarecomp (3,155 pixels off by 2 steps on rows 117-122); at 2968-2973 a menu icon's palette is written mid-frame. Matching 4,218 IO writes between the harness's write log and `GBARECOMP_MMIO_DUMP` (interpreter, frames 1-3249): 4,188 on the same scanline, 9 one line earlier, 21 three to six lines later. All three gbarecomp backends (static with healing off, healed, interpreter) show the same profile, so it is a CPU, DMA or wait-state timing difference, not the renderer. Render-time line logs from both engines (registers plus CRCs of OAM, palette and VRAM): of 434,720 boot lines, about 320 lines in 15 frames differ in state.

### 5.5 Race haze and HBlank IRQ timing are fine

**verified**. Once frames are aligned (§6), every per-line register the race writes is identical line for line: 0 of 21,760 lines differ over the fly-in (mGBA frames 3304-3439). Over the countdown and race (3441-3900), 178 of 73,600 lines differ: 177 are row-0 palette[0] (the handler's VBlank junk value, Phase 1 §2) and 1 is the known missed HBlank line (frame 3831 line 78). Why the row-0 values differ is **unverified** (likely the number of IRQs dropped around VBlank DMA3, which depends on game state).

### 5.6 No OBJ cycle budget

**verified**, gbarecomp missing feature. GBATEK documents a per-line OBJ rendering budget of 1210 cycles (954 with DISPCNT bit 5): a normal OBJ costs its width, an affine OBJ 10 + 2 × its bounding width. mGBA models it and drops OBJs past the budget; gbarecomp draws all 128 (`gba_ppu.cpp:1231`, `:1917`). On the race start grid, lines 66-80 need 1,982-2,260 cycles (mGBA OAM at frame 3424), so mGBA drops 15-22 OBJs per line. A budget prototype (native compositor only) takes the sprite differences of 2 steps or more on register-identical fly-in lines from 17,690 pixels to 0. How hardware handles a partly drawn last OBJ and off-screen OBJs is **unverified**.

Shipping it is a product choice: far crowd and rival sprites vanish on crowded lines, as on hardware, which works against Phase 4 widescreen margins. A switch fits both.

### 5.7 Brightness on semi-transparent OBJs

**likely**, hardware truth **unknown**. On haze lines (BLDCNT `0x00E4` or `0x00A4`: 1st target BG2 and backdrop, OBJ not selected), gbarecomp darkens or brightens semi-transparent OBJs; mGBA applies brightness to OBJs only when BLDCNT bit 4 is set (mGBA `software-obj.c:149-182`). GBATEK is ambiguous. A prototype of mGBA's rule, on top of the budget prototype, takes haze-line differences of 2 steps or more from 937 pixels to 0, and 87 of 146 fly-in frames become pixel-exact; what remains is §5.2 plus 9 pixels on lines whose OAM was written at a different time. Visible effect: whether race sprites get the distance haze. It needs a hardware test before it changes shipping behavior.

## 6. Races leave lockstep with mGBA

**Symptom** (**verified**). In every gbarecomp variant, including the interpreter reference, races differ from mGBA from the camera fly-in (frame 3350); rival positions differ by frame 3450, and the race ends earlier than in mGBA (mGBA's race display ends at frame 21788). Against mGBA, the interpreter reference matches 58 of 65 sampled menu frames (the 7 others are the fade and BIOS-logo differences of §5), 1 of 370 race frames and 0 of 65 post-race frames. Every correct overlay variant matches the interpreter reference on 65/65, 370/370 and 65/65. So the divergence is in gbarecomp's emulation, not in the recompiled cartridge code. The interpreter reference runs BIOS SWIs as recompiled code (§7.1); with the BIOS interpreted too, all 88 sampled `boot_to_race` frames, race frames up to 4400 included, are unchanged, so on those samples the BIOS translation is not the cause either (P2-13 checks every race frame).

**Likely cause.** The hand-off from the front end to the race program completes later in the frame in gbarecomp and crosses a frame boundary: DISPCNT becomes 0 at frame 3291 line 80 in mGBA but at 3292 in gbarecomp, and `0x1741` appears at 3303 in mGBA and 3304 in gbarecomp. Inputs then land on different game frames. The best-matching frame offset is -1 at 3350 and 3400 and 0 from 3620 on, but with OAM, VRAM and palette CRCs differing on most lines; from 3900 on, about 20,000 pixels differ per frame once RIGHT is held. IO writes in the race drift by a median of +228 lines (one frame). Which engine matches hardware is unknown.

Not yet ruled out: the game's random-number source (game-facts question 17), and the NULL-pointer BIOS read (Phase 1 §6), whose value both engines should take from the same open-bus latch (gbarecomp models it, **likely**).

This is the main open risk for Phase 2's exit criterion ("a full cup plays identically to mGBA"); [phase2-plan.md](../phase2-plan.md) gives it its own task.

## 7. Comparison method findings

### 7.1 What two engines are being compared

The interpreter reference (`GBARECOMP_FORCE_INTERP=1`) shares gbarecomp's device model (PPU, DMA, timers, IRQ delivery) with the recompiled code. Comparing the two isolates recompilation and dispatch bugs: every correct overlay variant was pixel-identical to it. Comparing with mGBA tests the device model and timing, where §5 and §6 show differences that are not recompilation bugs.

**The reference does not interpret the BIOS SWIs** (**verified**, source and runs). The run loop and the IRQ drive loop step the cartridge code and the IRQ handlers through the interpreter (`runtime.cpp:2165-2171`, `runtime_arm.cpp:1543-1552`). An interpreted `swi`, though, is routed "through the recompiled BIOS" (`runtime_arm_default_aborts.cpp:821-830`): `runtime_swi` dispatches the SWI vector `0x08` (`runtime_arm.cpp:1402-1405`), which `dispatch_resolve` finds in the recompiled BIOS table, and the log says `bios_backend=LLE (recompiled BIOS)`. `runtime_arm.h:234-240` describes the backend this way: it reuses "runtime_tick / runtime_swi for the device/IRQ/BIOS path".

- Run evidence: with `GBARECOMP_ABORT_AFTER_BRANCHES=0`, which aborts at the first loop branch taken in generated code (`arm_codegen.cpp:465-470`, arm-recomp-core `1f13cdf`), the reference aborts at `pc=0x000003D0` (target `0x000003C8`) right after the game's first `swi 0x07` (DivArm, return address `0x0801191A`), and the trace shows `dispatch pc=0x00000008`. Measured with the iwram-overlays prototype's interpreter build, no input.
- Why it matters: the game calls the BIOS often. On `boot_to_race` up to frame 3450, the harness logs 2,106 DivArm, 1,442 VBlankIntrWait, 968 CpuFastSet, 67 LZ77UnCompWram and 4 RLUnCompWram calls. Against this reference, a translation bug in a BIOS SWI handler would be the same on both sides, so comparison 1 could not see it.

**Interpreting the BIOS too needs no engine patch** (**verified** on samples). A game-owned `g_runtime_force_interp_hook` that returns 1 for PCs below `0x4000` sends every BIOS dispatch to the interpreter, because `dispatch_resolve` consults it before the BIOS table (`runtime_arm.cpp:874-880`). With such a hook in a scratch main linked against the prototype's objects:

- with the branch abort armed, a 600-frame boot and the whole `boot_to_race` replay (4,400 frames) ran without aborting, so no generated loop ran;
- on `boot_to_race`, all 88 VBlank-start shots (every 50 frames) are byte-identical to those of the plain reference and of option C under `GBARECOMP_STRICT_STATIC=1`, race frames up to 4400 included, and the final cycle count is the same (425,568,482);
- HALT is handled as in the plain reference (**likely**, from the counts; not traced): the bridges ran only 5,378 instructions in the whole run (the banner's `interpreted_insns`), while the run loop's interpreted steps rose by 2.85M (303.7M to 306.5M, from the prototype's per-frame stats). So each bridge hands back almost at once, at the first BIOS PC with a static entry (`runtime_arm_default_aborts.cpp:640-643`), and the run loop steps the rest of the BIOS and models HALT (`runtime.cpp:2149-2158`); the IntrWait spin of §1.5 does not happen;
- the banner reads `NOT_STATIC dispatch_misses=1`, because each BIOS entry goes through a bridge, so no gate may read the reference's banner;
- RAM was not compared, and `full_race_cross` was not run this way.

ADR 0001 adopts this as the comparison 1 reference (P2-02 adds the hook, P2-09 uses it). The plain reference stays useful to split a failure between the BIOS translation and the cartridge code.

### 7.2 Two layers for the comparison with mGBA

The ppu-diffs investigation compared engines at two levels, and both were needed:

1. **Render-time per-line state, exact.** Video registers, palette[0], and CRCs of OAM, palette and VRAM at the moment each line is rendered (gbarecomp renders at HBlank start, `runtime_bus_bridge.cpp:577`, then HBlank DMA at :595; mGBA renders in `drawScanline` at HBlank start). The harness's existing `lines.tsv` samples when VCOUNT changes, which is not the same point. Mask unused bits: BLDALPHA reads back raw in gbarecomp (`0xFF11`) and masked in mGBA (`0x1F11`), on 960 lines of frames 182-187; BLDY uses 5 bits. At frame 1 line 0, gbarecomp has BG2PA/PD and BG3PA/PD = 0 before the BIOS initializes them (related to known issue 6 in [toolchain.md](../toolchain.md)).
2. **Pixels at 5-bit precision.** Exact on lines with no color effect. ±1 step per channel only on lines where an effect is active (BLDCNT effect 1-3 with a nonzero EVA/EVB/EVY, or a semi-transparent OBJ), which §5.2 shows is the largest arithmetic difference.

A pixel tolerance alone would hide timing bugs: comparing frame 320 with frame 321 (BLDY 3 against 2) gives 1,070 pixels off by just one step. Layer 1 catches it.

### 7.3 Frame numbering

**verified** for captures taken at VBlank start. gbarecomp increments its PPU `frame_count` at the line 227 to 0 wrap (`gba_ppu.cpp:216-224`); the harness counts VBlank starts. A capture taken at VBlank start while `frame_count` is k shows harness frame k+1 (the iwram-overlays diagnostic patch names its VBlank-start shots this way, and they line up with the harness's shots). Compared at matching frames, PR #5's "frame 320 off by one or two steps" is one step only (2,033 pixels); PR #5's "frames 180 and 280 one frame ahead" is the same offset.

**Where `--frames N` stops, and so what `--dump-png` writes, depends on the backend and on the game state.** **verified** with the §3.2 prototype builds (interpreter reference and option C), headless with `SDL_AUDIODRIVER=dummy`, reading `ppu_vcount` and `ppu_frames` on the final line:

- The recompiled build stopped at `ppu_vcount=160` with `ppu_frames=N` at N = 3000 (no input) and 4400 (`boot_to_race` replay). Its dump is harness frame N+1.
- The interpreter reference stopped at `ppu_vcount=0` at N = 3000 (with and without the replay), 3800 and 4400 (replay), so its dump is harness frame N. At N = 320 it stopped at `ppu_vcount=160`, like the recompiled build.
- At N = 4400 on `boot_to_race`, the interpreter's dump is pixel-identical to the VBlank-start shot of harness frame 4400, and the recompiled build's dump differs from that shot by 20,549 pixels. At N = 3000 the two dumps are identical only because the title screen does not change (§7.4).
- Mechanism, **likely** but not traced: the runner breaks out as soon as `frame_count` reaches the limit between two of its steps (`runtime.cpp:4261-4264`), which for the interpreter can be right after the wrap, while generated code returns to the runner only at a yield point such as VBlank start. Why the interpreter stops at line 160 at N = 320 was not investigated.

The rule: every comparison across backends, or with mGBA, uses captures taken at VBlank start (the `input_frame` hook or a capture patch), never `--dump-png`. A `--dump-png` comparison is valid only between two runs whose final lines show the same `ppu_vcount` and `ppu_frames`, and only on a frame where the screen changes.

Input replay: `GBARECOMP_INPUT_REPLAY` applies an event once `ppu.frame_count()` reaches its frame, from the runner loop only. With the stock replay, writing an event for harness frame N at frame N-2 (converted from the harness's `trace.tsv`) gave the best match on `boot_to_race`: 818 exact frames in 2400-4005, against 226 for N-1, which diverges at frame 2453. The iwram-overlays prototype applied inputs at VBlank start through a diagnostic patch instead, with its own converter numbering. The two conventions were not cross-checked, and neither has been validated inside races (§6). The plan makes one convention and its validation a task.

### 7.4 Matches on static screens prove nothing

**verified**. PR #5's smoke test found title frames 2450 and 2700 identical to mGBA. At that point the static healing-off run was inside the stale bridge of §1.1, spinning in the BIOS IntrWait loop (§1.5): about 10,000 writes per frame to IME and HALTCNT from frame 2439 on, against 692 and 691 IME writes over frames 2000-2400 in mGBA and the interpreter. The title screen does not change, so the pixels still matched. Frames sampled for a check must be ones where the screen is changing, and the per-line state of §7.2 makes this harder to miss.

### 7.5 Sample frames that exercise the renderer

From the ppu-diffs investigation: BIOS frames 1-270 (alpha, brighten, OBJ window); license fade 294-326 (darken, mid-frame BLDY); intro and title; menus (mode 1, VCount palette split); race fly-in 3303-3440 (HBlank DMA affine, HBlank IRQ haze, 30+ affine semi-transparent OBJs).

### 7.6 Determinism

**verified**. Headless with `SDL_AUDIODRIVER=dummy`, a fresh save, and `GBARECOMP_SELFHEAL_RECOMPILE=0` (or a fixed warm cache), runs were bit-identical run to run, and `--frames` does not change earlier frames. The interpreter reference is also deterministic (2,000 of 2,000 frames identical across runs). Raw frames are 115,200 bytes each; keep CRCs and diffs, not frames.

## 8. Corrections to [toolchain.md](../toolchain.md) (PR #5)

- Problem 1 (IRQ watchdog) is an end-of-run artifact (§1.2), not a hang during play.
- Problem 2 (the 3,600-frame abort) is the leaked call-return frame of §1.1. 198.75M of the 228.6M interpreted instructions in the 2,700-frame run come from that one mis-stopped bridge (`0x08003E70`, VBlanks 1029-2706), not from IWRAM code in general.
- Problem 3 (results depend on `--frames`) is deterministic end-of-run behavior (§1.3).
- Known issue 13: the browser abort is §1.1, not a browser problem (§4).
- The miss fragment's two jump-table candidates are BL return sites (§2.1).
- The title-frame matches are on a static screen during the runaway bridge (§7.4).

## 9. Upstream candidates

For the owner to decide; nothing has been filed. Each needs the repro rewritten without our ROM where possible.

| # | Candidate | Where (at the pin) | Minimal repro | Prototype fix |
|---|---|---|---|---|
| U1 | IRQ-continuation bridge leaks call-return frames; `runtime_irq()` does not restore `g_call_return_depth` | `runtime_arm_default_aborts.cpp:640-643`, `:676`; `runtime_arm.cpp:1569-1575` (resumable path restores at `:1268`) | The two synthetic ROMs of §1.1 | 17 lines (§1.1) |
| U2 | Sticky present-in-place quit has no IRQ-depth guard; `runtime_irq()` spins 4M dispatches and abandons the IRQ | `runtime_bus_bridge.cpp:1035` (guarded check at `:1054`) | Any headless `--frames` run that ends while a bridge runs | 1 line (§1.2) |
| U3 | The interpreter bridge never offers a frame boundary: no present, no input, no `--frames`; input replay applied only in the runner loop; the 200M cap aborts legitimate long calls | `runtime_arm_default_aborts.cpp` bridge loop, `:86`; `runtime.cpp` `apply_input_replay` | A RAM main loop reached through a miss | Two designs (§1.4) |
| U4 | Stale HALT inside a bridge; native prologues reached from the bridge yield at once | `runtime_bus_bridge.cpp:1138` | Any bridged subtree that calls VBlankIntrWait | none yet |
| U5 | RAM overlays: an API to select a dispatch table per resident image (or a resolve-style variant of the RAM dispatch hook). Upstream's documented answer for code that changes under a static entry is `g_runtime_force_interp_hook` (`runtime_arm.h:72-78`, our option D), which lowers the odds that a selector is accepted as written. Upstream plans a per-program registry that binds dispatch tables and fails closed on unknown PCs, for mixed-cartridge multiplayer (`docs/MIXED_CARTRIDGE_MULTIPLAYER.md`, "Implementation order", step 1), and already has `RuntimeArmContext::program_dispatch`, "required when heterogeneous images are implemented" (`runtime_context.h:44-46`, consulted first at `runtime_arm.cpp:869-870`), which works only with a resumable context and runs the body inside the callback. Shape the proposal as a resolve-style `program_dispatch` that also works without a resumable context | `runtime_arm.cpp:882-894` | A ROM that copies two different ARM routines to the same IWRAM address at different times; compile one with the main corpus and one with `--output-prefix` | About 40 lines (§3.2, option C) |
| U6 | Documentation request only: state in `runtime_arm.h` that `g_runtime_ram_dispatch_hook` runs the body inside the callback, so each dispatch adds a host frame and the hook suits leaf routines only. Not a defect: the documented contract (`runtime_arm.h:65-70`) is narrow, and our prototype went beyond it | `runtime_arm.h:65-70` | n/a | Fold into U5 if U5 is filed |
| U7 | RAM heal tier keyed by (PC, mode) only, with no live-byte check or invalidation; RAM heals never warm-loaded | `overlay_loader.cpp:35`, `:384`; the CRC is known at install time (`overlay_compile.cpp:320`) | Same as U5 with `GBARECOMP_RAM_OVERLAY_HEAL=1` | none yet |
| U8 | `build_web.sh` always links `packaging/web/main.cpp`, so game-owned hooks cannot reach the browser | `packaging/web/build_web.sh:212-222` | n/a | `GBARECOMP_WEB_MAIN` and `GBARECOMP_WEB_MAIN_FLAGS` overrides, 1 line |
| U9 | `--output-prefix` is documented only in the tool's usage text, as a way to link "multiple immutable code images" into one executable (upstream commit `2be1b81`, "support namespaced multi-image output"); nothing in the runtime looks up a prefixed table without a resumable context, no test at the pin uses it, and a prefixed corpus walks into ROM roots (81 duplicated here) | `tools/gba_recompile/main.cpp:139-141`, `:1422-1426` | Same as U5 | A scan limit for prefixed corpora (idea only) |
| U10 | Input replay lags mGBA's VBlank-start counter and is starved during bridges | `runtime.cpp` `apply_input_replay`; `runtime_set_vblank_input_hook` exists | Replay any trace on a build with a long-running bridge | Apply at VBlank start |
| U11 | Finder: armcc `addls pc,pc,rM,lsl #2` tables of B instructions; `[[jump_table]]` has no B-table format | `function_finder.cpp:1030-1039`, `:905-908` | Any armcc-built ARM switch | none yet |
| U12 | Miss-fragment heuristic flags runs of adjacent BL return sites as jump-table candidates; it could suggest `resume = true` or `static_resume_all` instead | miss fragment writer (`runtime_arm_default_aborts.cpp:179`) | §2.1 | none yet |
| U13 | OBJ pixels ignore BLDCNT bit 4; the forced-alpha test must use a semi-transparency flag | `gba_ppu.cpp:1299-1301`, `:2009`, `:1369`, `:2129`, and the wide margin provider | §5.1 | 17 lines added, 10 removed |
| U14 | No per-line OBJ cycle budget | `gba_ppu.cpp:1231`, `:1917` | 20+ 32x32 affine OBJs on one line | Prototype, native compositor only |
| U15 | Headless per-frame framebuffer dump (`GBARECOMP_FRAMEDUMP_DIR` works only in the windowed loop, `runtime.cpp:4217`) and a public way to observe presentation or scanlines (`GbaPpu::PresentationObserver` exists, `run_game` does not expose the PPU) | as cited | n/a | Diagnostic prototypes |
| U16 | The MMIO capture ring (`kMmioCapRingSize = 1<<18`, `gba_io.h:59`) wraps after about 2,500 frames of this game; make it configurable | as cited | n/a | Prototype |
| U17 | Question, not a defect report: the source of the +8/+7 blend rounding with the 6-bit green (commit `f2273fb`), and whether semi-transparent OBJs get brightness when BLDCNT does not select OBJ | `gba_ppu.cpp:497-541` | Needs hardware data | n/a |
| U18 | **Unverified**: the call-return stack grows one entry per frame while a ROM miss is bridged once per frame and the IRQ handler runs natively | §2.4 | Not reduced yet | n/a |

Already listed in [toolchain.md](../toolchain.md) and `patches/gbarecomp/README.md` (PR #5): HALT ends only on an interrupt the CPU takes (known issue 5, which blocks the Cult-of-GBA BIOS boot), `skip_intro` leaves the BG2/BG3 affine matrices at zero (known issue 6), and the co-simulation coordinator's Windows-only `creationflags`.

## 10. Caveats about the evidence

- The shared disk filled up (ENOSPC) during the investigations. Some frame dumps were deleted after scoring; their summaries and logs remain. One overlay matrix run hit the full disk while writing its log, and its result was consistent with the other healing runs.
- In the runtime-bugs investigation, another process changed files in its scratch directory during the session. Its final patches and results were re-verified from scratch in an isolated subdirectory; early intermediate artifacts are not relied on here.
- gbarecomp's `symbol_import_golden` test failed once right after a build and passed in three reruns (cause **unverified**; it tests a Python tool, not the runtime).
- Browser speed was measured in headless Chromium only, which caps at about 55 fps. Real browsers and slower devices were not measured.

## Open questions

1. Will upstream take a RAM overlay selector (U5), prefer a resolve-style hook, or point to `g_runtime_force_interp_hook` (its documented mechanism, option D)? Its planned per-program registry, or its `program_dispatch` made usable without a resumable context, is the closest fit. Until then we carry the patch; a merged dispatch table built by our own code (ADR 0001, alternatives; **unverified**) might avoid the patch.
2. Do the GP, Traffic, abort, restart, options-save and multiplayer-lobby routes pass strict static with option C? (Likely; not run.)
3. Why does the race program start one frame later in gbarecomp (§6)? Which engine's CPU, DMA and wait-state timing matches hardware there, and for the mid-frame writes of §5.4?
4. How does the game seed its random numbers, and does a race play out identically from the same inputs (game-facts question 17)?
5. Hardware truth for blend rounding (§5.2), brightness on semi-transparent OBJs (§5.7) and the OBJ budget's edge cases (§5.6). A small test ROM on the owner's hardware would settle all three.
6. Row-0 palette junk and the missed HBlank lines in races: do they come from different numbers of IRQs dropped during VBlank DMA3?
7. IRQ return addresses differ from mGBA by about one instruction inside BIOS CpuFastSet and LZ77 loops (15 of 762 IRQs in the first 700 frames of a fully static boot). Does it matter?
8. Does the §1.1 patch alone prevent the §2.4 overflow?
9. Should the bridge frame boundary (§1.4) ship as a safety net in the browser, and should its cap reset be bounded?
10. Does presenting frames from inside the interpreter have side effects in windowed play (pause, fast-forward, rewind)? Only headless and browser runs were tested.

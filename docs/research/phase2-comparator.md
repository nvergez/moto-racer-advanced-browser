# The comparator and the replay test runner: first results

**Date:** 2026-10-11
**Scope:** P2-09 of [phase2-plan.md](../phase2-plan.md): what the comparator and the runner ([tools/difftest/README.md](../../tools/difftest/README.md)) report on `boot_to_race` against mGBA, how each difference was classified into the route's allowlist, the measurement of RAM-hash equality between the recompiled build and the interpreter reference (comparison 1, ADR 0001 decision 5), and whether every route of the manifest follows its checkpoints on gbarecomp's interpreter.
**Status:** Native runs of gbarecomp and of the mGBA harness, and reading of gbarecomp's source at the pin. Nothing was checked on hardware.

## Pins

| | |
|---|---|
| ROM | Moto Racer Advance (Europe) `A9MP`, SHA-1 `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0` |
| BIOS | retail, SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492` |
| gbarecomp | `5e89943528aee7bc1c399bdbd035364a4b41dd10` with patches 0001-0006 (`main` at `dd12c69`), nested arm-recomp-core `1f13cdfd3b437a7a3919285f381987bd43f5234a`; `file:line` citations are at these commits |
| Game config | `game.toml` of `main` at `dd12c69` (P2-05's): IWRAM code interpreted |
| mGBA | libmgba 0.10.5 (`26b7884`) through `tools/analysis/harness` |
| Machine | Apple M4 Pro, macOS; native runs headless with `SDL_AUDIODRIVER=dummy`, `GBARECOMP_SELFHEAL_RECOMPILE=0` and a fresh save |

"Reference" is the BIOS-interpreting interpreter of P2-02 (`GBARECOMP_FORCE_INTERP=1 MRA_INTERP_BIOS=1`), "interpreter" the plain one (`GBARECOMP_FORCE_INTERP=1`), "recompiled" the same executable without either. Frame numbers are harness frames. Captures are P2-03's with `tools/capture/spec.txt` and the route fields; replays are P2-02's. Unless a section says otherwise, the runs were made with `scripts/replay-test.sh` (commands in section 7). Captures, line records, raw frames and fingerprint tails stayed in a scratch directory and were deleted after use.

## 1. Summary

- **Against mGBA, `boot_to_race` reproduces the diagnosis.** On frames 1-3,289 (the front end) layer 1 differs on 56 frames and the frame CRC on 427. With the pixels compared at 5-bit precision and one step of tolerance on effect lines, 307 of the 427 pass: the blend rounding of diagnosis §5.2. The other 120 fail layer 2 for three causes: the OBJ 1st-target bug on the BIOS logo (222-269) and on the game's two fades (2453-2481, 3258-3289), 109 frames, P2-08's patch; the timing-shaped frames of §5.4 whose pixels differ beyond one step (610, 1031, 2188, 2482, 2498); and 2968-2973, an OBJ priority difference over an affine BG (P2-02). The 56 layer-1 frames are frame 1 (the affine registers before the BIOS sets them) and 55 frames where a write lands on another line than in mGBA, the state equal again later in the frame or on the next one: §5.4's list plus 2483 and the menu frames P2-02 found. With the route's allowlist (seven entries) the route passes, race frames included under an entry for the race starting one frame late (P2-13, until P2-21). A replay one frame early or late fails (section 5).
- **RAM against mGBA** differs where a copy into RAM runs across the VBlank start (one 4 KiB block per frame, a different one each frame, equal again the next frame: 17 front-end frames of EWRAM, one of IWRAM) and, on 891 front-end frames, in the stack area, only in the words an IRQ entry pushes. Both are allowlisted with that evidence (section 3.2).
- **Comparison 1: RAM-hash equality measured.** On `boot_to_race` 1-4,400 and a 3,600-frame boot without input, every RAM-hash difference between the recompiled build and the reference has one of three causes, none of them a legitimate difference between backends, so `comparison1.toml` excludes no region:
  1. the IWRAM code that still runs in interpreter bridges (the stale HALT of diagnosis §1.5 and the intro player's IntrWait storm): every difference but frames 295-296 and 3303 disappears on a scratch build with the front end's IWRAM image compiled, as P2-05 found; P2-10 removes the bridges;
  2. **a gbarecomp code-generation timing bug, new (U21):** generated code charges an instruction's opcode-fetch wait states as they were before the instruction, the interpreter as they are after it. The game's store to WAITCNT at `0x080025D0` (frame 294) costs 9 cycles in generated code and 7 in the interpreter; the 2 cycles move the next IRQ to another instruction, so the IRQ stack differs on frames 295-296 and a write lands one line later on frame 294 (section 4.2);
  3. **another one, new (U22):** generated code ticks an exception return's cost, which delivers pending IRQs, before restoring the CPSR, so an IRQ that became pending during a SWI is taken one instruction later than in the interpreter. It is why the recompiled BIOS and the interpreted BIOS differ on frame 3303, in the recompiled build as in the plain interpreter, and the first of the differences P2-13 handed over on `full_race_cross`; whether it explains the others is **unverified** (section 4.3).

  Both bugs need a change in arm-recomp-core's code generator, the nested submodule the patch tooling cannot carry (owner decision 9). Until they are fixed, comparison 1 will fail on P2-10's static build wherever they show (section 4.4).
- **Route following.** Every route of the manifest follows its checkpoints on the reference, the cup included, and `boot_to_race` and `full_race_cross` on the plain interpreter (section 6). A replay with one menu input moved off its screen fails its checkpoint, on both engines.
- **Tools** ([tools/difftest/README.md](../../tools/difftest/README.md)): `tools/difftest/compare.py`, the comparator; `scripts/replay-test.sh`, the runner; `tools/difftest/fpdiff.py` with `MRA_FP_TAIL` in `src/main.cpp`, which diff two runs instruction by instruction and found both bugs.

## 2. What the runner does

`scripts/replay-test.sh ROUTE --against interp|mgba|none` converts the route's script into a replay, runs both sides in parallel with the per-frame capture, checks the route's checkpoints on the gbarecomp capture (and on the other one), runs `compare.py` on the per-frame records, then re-runs both sides with line records and raw frames for the frames whose CRCs differ and runs `compare.py` again with them. The second runs' per-frame records must equal the first runs' (determinism, diagnosis §7.6): they did in every run below.

Costs on `boot_to_race` against mGBA, 4,400 frames: 41 s for the whole run, both passes included (the interpreter dominates), with 1,200 detailed frames (the cap) at about 116 KB per frame and side, 286 MB, deleted at the end unless `--keep`. Comparison 1 on frames 1-3,290 with `--fp-ring 295`: 23 s.

## 3. `boot_to_race` against mGBA

Command: `scripts/replay-test.sh boot_to_race --against mgba` (gbarecomp side: the interpreter). Result with [allowlists/boot_to_race.toml](../../tools/difftest/allowlists/boot_to_race.toml): `RESULT: PASS (4400 frames compared)`.

| Check | Frames that differ | Pass in detail | Allowlisted |
|---|---|---|---|
| layer 1 | 1,078 (56 front end, 1,022 race) | | 1,078 |
| layer 2 (`fb` differs) | 1,532 (427 front end) | 308 (307 front end, and 3292) | 1,224 |
| `ram_ewram` | 1,129 (17 front end) | | 1,129 |
| `ram_iwram` | 1,098 (1 front end) | | 1,098 |
| `ram_iwram_stacks` | 1,999 (891 front end) | | 1,999 |

Frames 3286-4400 are the race and its load: covered by `race-starts-one-frame-late` (section 3.3). The front end, frames 1-3,289:

### 3.1 Line state and pixels

The 307 front-end frames that pass layer 2 are the 300 blend frames P2-02 listed (16-23, 134-175, 297-324, 568-606, 609, 611-638, 1002-1030, 1032-1059, 1363-1392, 1397-1414, 2167-2187, 2190-2217), 220-221, the first two frames of the BIOS logo fade (BLDY 1, so the missing brightness is at most one step), and 607, 1393-1395 and 2483, whose line state differs (section below) but whose pixels stay within the tolerance. On all of them every pixel that differs is on a line with an effect and off by one step per channel at most: the bound diagnosis §5.2 proved for the blend arithmetic.

| Allowlist entry | Frames | Check | Evidence |
|---|---|---|---|
| `obj-1st-target` | 222-269, 2453-2481, 3258-3289 (109) | layer 2 | Line state equal; P2-02 showed that every pixel off by more than one step is the brightness missing on a normal OBJ (diagnosis §5.1, phase2-replay.md §3). P2-08's patch should empty this entry |
| `mid-frame-write-timing` | 55 frames, listed in the entry | layer 1, and layer 2 on 610, 1031, 2188, 2482, 2498 | The line state differs on a band of lines (OAM, PAL, VRAM, BLDY, BG0CNT or BG2CNT) and is equal again later in the same frame on all of them but 2188, whose difference lasts to line 159 and is gone on frame 2189 (its DMA3 spans the VBlank start, phase2-capture.md §1). §5.4's frames, plus 2483 and the menu frames P2-02 found (2490-3254: one line of PAL, OAM or VRAM_OBJ, the menus' VCount palette writes and OBJ uploads) |
| `obj-priority-over-affine-bg` | 2968-2973 | layer 2 | Line state equal (but line 25 of 2972, a menu palette write); pixels differ only where two OBJs overlap BG2 (phase2-replay.md §3). Which engine matches hardware is **unverified** |
| `affine-reset-values` | 1 | layer 1 | Line 0 only: BG2PA, BG2PD, BG3PA, BG3PD are 0 in gbarecomp and 0x0100 in mGBA until the BIOS writes them (diagnosis §7.2) |

Which engine's timing matches hardware for the mid-frame writes is **unverified**, as in the diagnosis. The convergence check above was made on the line records of both engines, kept with `--keep` (scratch script, not committed).

### 3.2 RAM

Located with captures whose spec splits a region into small ones (EWRAM in 64 regions of 4 KiB, IWRAM in 32 of 1 KiB, the stack area in 64 of 8 bytes, unmasked), both engines, `boot_to_race` 1-3,290 (scratch specs, not committed: `ram` entries only):

- **EWRAM**, 17 front-end frames (294-295, 596-606, 608-609, 2155, 2482): on each one block differs, never the same block on two frames in a row (596: `0x02001000`, 597: `0x02005000`, 598: `0x02008000` ... 609: `0x02033000`; 294: `0x0202E000`; 295: `0x02034000`; 2155: `0x0202D000`; 2482: `0x0202C000`), and the next frame is equal. A copy or decompression in progress at the VBlank start, caught at another point in each engine: the same timing as section 3.1. **IWRAM** differs on 607 only, in `0x03001C00`-`0x03001FFF`. Entry `ram-snapshot-timing`.
- **Stacks**, 891 front-end frames. The 8-byte slots that differ: `0x03007F88`-`0x03007F8F` (882 frames), `0x03007F98`-`0x03007F9F` (1,058, unmasked here; the spec masks `0x03007F9C`), `0x03007F90`-`0x03007F97` (31), `0x03007F70`-`0x03007F87` (26 together), `0x03007E60`-`0x03007E67` (9) and `0x03007E78`-`0x03007E7F` (2). The BIOS IRQ handler pushes r0-r3, r12 and lr below `0x03007FA0` (GBATEK, "BIOS RAM Usage"), so `0x03007F88`-`0x03007F9F` is the frame of the last IRQ and `0x03007F70`-`0x03007F87` a nested one; `0x03007E60`-`0x03007E7F` is below the main thread's stack (`sp` is `0x03007E64` to `0x03007EE8` in the instruction streams of section 4). These hold the registers of whatever an interrupt stopped, and the two engines' IRQ timing differs (P2-13: no IRQ entry cycles and no IRQ delay in gbarecomp, phase2-race-lockstep.md §3 and §5). That they are dead at the sample point is **likely**, not shown: the captures do not hold the stack pointers. Entry `irq-frames-on-stacks`, frames 1-3,289. The spec is unchanged: its only mask stays `0x03007F9C`, so comparison 1, where these words must be equal, keeps them.

### 3.3 Race frames, and the frame map

From 3286 on (the race program clears its `.bss` one frame later, then the race image arrives at 3291 instead of 3290), the race is out of lockstep with mGBA because of the two gbarecomp timing differences P2-13 found. A frame map does not realign it on this gbarecomp: with `--frame-map 3290-4399:+1`, IWRAM is equal on 3290-3607 and `fb` on most fly-in frames (3294-3307 but 3296), but EWRAM differs on every frame from 3293 and layer 1 on all of them, and from the first race input (3609) everything differs. A `~2` search over 3280-4399 picks +1 on most of 3302-3607 (-1 on 3568 and 3581) and 0 from 3614 on, where every offset differs anyway. So the race frames are one allowlist entry, `race-starts-one-frame-late`, with P2-21 as the task that should remove it. The frame map is there for P2-14 and later studies on fixed builds.

## 4. Comparison 1: RAM-hash equality

### 4.1 Runs

| Run | Recompiled against the reference: frames that differ |
|---|---|
| `boot_to_race`, frames 1-4,400 (the recompiled run continues to 5,127 and aborts there with exit code 134, the race loop's bridge, P2-05 §5, so the runner fails it on that too) | `fb` 2185, 2188-2189; `ram_ewram` 2185-2187; `ram_iwram` 2185-2271; `ram_iwram_stacks` 120 frames (295-296, 1396-1476, 1546, 1623-1625, 1630, 1637, 1840, 1847, 1862, 2165-2189, 2255-2256, 3303) |
| Boot without input, 3,600 frames | the same up to 2271, and `ram_iwram_stacks` on 2853-2995 (262 frames in all), `io_writes` and `halt_writes` on 2853-2873: the intro player runs again after the title |
| Scratch build with the front end's IWRAM image in the main corpus (P2-05 §6's experiment, not committed), both runs above to 3,290 and 3,600 frames | `ram_iwram_stacks` 295-296 only; reported, not gated: `lines` 294 and the clock at 295 (-2 cycles) |

So, as P2-05 measured, the bridges explain everything but 295-296 and 3303. The plan's possible fallback, a list of regions that legitimately differ, is not needed for any of them: the two that remain are bugs.

### 4.2 Frames 294-296: the cost of the store to WAITCNT (U21)

`scripts/replay-test.sh boot_to_race --against interp --frames 1-3290 --fp-ring 295` (and the same on a boot without input) runs both sides to frame 295 with the fingerprint ring and diffs the last 500,000 instructions:

```
TIMING DIVERGENCE ... (state equal): clock B - A +2
  the instruction at 080025D0 (ARM) cost 7 cycles in A and 9 in B
STATE DIVERGENCE ...: pc, cpsr, sp, lr, r15 differ
  A: cycles=82499646 pc=000012B2 ...
  B: cycles=82499648 pc=00000018 ...
```

A is the reference, B the recompiled build. `0x080025D0` is `strh r0, [r4, #4]` with `r4 = 0x04000200` and `r0 = 0x4014`: the front end's IRQ setup function (`0x080025B4`, P2-05 §3) writes WAITCNT, which changes the ROM wait states (from 0, the reset value), at about line 56 of frame 294. From there to the VBlank start that ends frame 294 the two streams have the same state with clocks 2 cycles apart; the VBlank IRQ is then taken one instruction earlier in the recompiled build, so the registers the BIOS pushes differ (the 4-byte stack regions that differ on 295-296 are `0x03007F8C`, `0x03007F90` and `0x03007F9C`: r1, r2 and lr). The layer-1 difference on line 73 of frame 294 (a write that lands a line later in the recompiled build, P2-05 §6) comes from the same 2 cycles, a write that falls on the other side of the line's render point (**likely**: it is the only difference in the streams before that line).

Why, from the source: generated code initializes an instruction's cycle count with its opcode-fetch wait states (`uint32_t _cyc = ...`, arm-recomp-core `arm_codegen.cpp:1536-1537`, from `cost_with_fetch`, `:1528`, which reads `g_runtime_waits`, `:168-179`) before the instruction's memory access; the interpreter adds them after executing it (`bus.code_wait`, `interpreter.cpp:1206-1213`). Both read the same table, which the WAITCNT write updates. So a store that changes WAITCNT is charged the old wait states in generated code and the new ones in the interpreter. **Verified** by the fingerprint diff (2 cycles at that instruction, every earlier one equal); the reason is read from the code. mGBA 0.10.5 takes the instruction's S fetch before the store and its N-S adjustment after it (`isa-arm.c`, `ARM_PREFETCH_CYCLES` and `ARM_STORE_POST_BODY`), so it matches neither exactly; what hardware does is **unverified**. Upstream candidate U21 (diagnosis §9).

The game writes WAITCNT when the front end starts. Whether the race program writes it too, which would add a frame at each race start and return, was not checked (**unverified**).

### 4.3 Frame 3303: an IRQ at the return from a SWI (U22)

`ram_iwram_stacks` on 3303 differs between the reference and the recompiled build, and between the reference and the plain interpreter (P2-02 found the latter). Fingerprint tails of all three to frame 3303 (scratch runs with `MRA_FP_TAIL`, `boot_to_race` replay):

- reference against the plain interpreter: 966,493 equal records, then at cycle 927,698,255 the reference takes an IRQ (PC `0x18`) and the interpreter runs `0x0816258A` first; the clocks are equal;
- reference against the recompiled build: 916,763 equal records (frames 3294 on, with the race loop in a bridge), then the same divergence at the same cycle.

The record before is the BIOS's `movs pc, lr` at `0x188`, the return from a SWI: it restores the caller's CPSR, with IRQs enabled, while an IRQ is pending. The reference interprets it; the interpreter and the recompiled build run the recompiled BIOS. Generated code ticks the instruction's cost, which is where `runtime_tick` delivers pending IRQs, before `runtime_exception_return` restores the CPSR (arm-recomp-core `arm_codegen.cpp:712-717`; the LDM forms at `:1088-1093` and `:1173-1175` too), so the IRQ is still masked and waits for the next instruction's tick. The interpreter's step stores the restored CPSR, then ticks (`runtime_arm_default_aborts.cpp:847-854`), and takes the IRQ at once. **Verified** for this frame by the fingerprint diffs; the mechanism is read from the code. Upstream candidate U22.

It is a difference between the recompiled BIOS and the interpreted BIOS, the case comparison 1's BIOS-interpreting reference exists to catch (diagnosis §7.1).

**`full_race_cross`, the differences P2-13 handed over** (phase2-race-lockstep.md §7.1). The reference against the plain interpreter, 25,000 frames, `compare.py --against interp`: `fb` differs on 9692 and 16306, `ram_ewram` on 21551, 21555 and 21566, `ram_iwram_stacks` on 25 frames (3303, 21543-21563, 21565-21567), and, reported only, `lines` on 9692, 16306, 21562-21563 and the clock at the record on 493 frames (-10 to +4 cycles), as P2-13 found. The first is frame 3303, the U22 event above. The clocks then differ by a few cycles on some frames and agree on others for the rest of the race. A fingerprint tail of 1,000,000 instructions before frame 9692 starts with the clocks already 4 cycles apart, so it cannot show which event made 9692 differ: `fpdiff.py` anchors on the state and says the divergence is before its window. Classification: the differences are between the recompiled and the interpreted BIOS, so they are U22 or another BIOS-translation difference; U22 is the only one found, and that it explains 9692 and 16306 is **unverified**. Localizing them needs a window that starts where the clocks agree (a longer tail, or a fingerprint dump that starts at a given cycle).

### 4.4 What it means for P2-10

Comparison 1 gates from P2-10 on, on every frame. On P2-10's static build the bridge differences should go, but U21 and U22 stay: at least frames 295-296 of every boot (U21) and every frame where an IRQ is pending at the end of a SWI (U22). They cannot be excluded as regions, since they are bugs and U22 changes frames. Fixing them needs arm-recomp-core's code generator (owner decision 9, which P2-21 is already waiting for); a gbarecomp-side fix for U22 may be possible in `runtime_exception_return` (deliver a pending IRQ after restoring the CPSR) and was not tried. Proposed follow-up: one task for both, like P2-21, with synthetic repros, measured by `scripts/replay-test.sh ROUTE --against interp`.

## 5. A wrong replay offset fails

`scripts/replay-test.sh boot_to_race --against mgba --frames 1-3290 --replay-offset K` (the gbarecomp side's inputs K frames late), with the allowlist:

| K | Main menu (mGBA 2524) | Layer 1 failing | Layer 2 failing | EWRAM failing | IWRAM failing | Result |
|---|---|---|---|---|---|---|
| 0 | 2524 | 0 | 0 | 0 | 0 | PASS |
| +1 | 2525 | 595 | 468 | 715 | 563 | FAIL, 731 frames |
| -1 | 2523 | 683 | 532 | 771 | 647 | FAIL, 816 frames |

The checkpoints still hold at ±1 (the slack is there for races that end at other frames), so the comparison is what catches a wrong convention.

## 6. Route following on every route

`scripts/replay-test.sh ROUTE --against none --test reference` for every route (`--test interp` for the last two rows): only the gbarecomp side runs, and the runner checks its checkpoints. Every run exited 0.

| Route | Gbarecomp side | Checkpoints: gbarecomp frame (mGBA frame) | Follows |
|---|---|---|---|
| `boot_to_race` | reference | main_menu 2524 (2524), race_image 3291 (3290), race_display 3304 (3303) | yes |
| `full_race_cross` | reference | main_menu 2524, race_image 3291 (3290), race_display 3304 (3303), race_over 21549 (21794) | yes |
| `race_gp` | reference | main_menu 2524, gp_track_select 3008 (3008), race_image 3333 (3332), race_display 3347 (3346) | yes |
| `race_traffic` | reference | main_menu 2524, traffic_track_select 3020 (3020), race_image 3345 (3344), race_display 3359 (3358) | yes |
| `abort_race` | reference | main_menu 2524, race_image 3291, race_display 3304, aborted 4304 (4303) | yes |
| `restart_race` | reference | main_menu 2524, race_image 3291, race_display 3304, restart_blank 4286 (4286), race_display_again 4305 (4304) | yes |
| `two_races` | reference | main_menu 2524, race1_display 3304 (3303), race1_aborted 4304 (4303), texas_selected 4610 (4610), race2_display 5124 (5123), race2_aborted 6324 (6323) | yes |
| `options_save` | reference | main_menu 2524, francais_selected 3049 (3049), back_on_main_menu 3416 (3416) | yes |
| `boot_with_save` | reference, from its own `options_save` save | save_loaded 596 (596), main_menu 2484 (2484), left_main_menu 2660 (2660), back_on_main_menu 2788 (2788) | yes |
| `multiplayer_lobby` | reference | main_menu 2524, lobby 2773 (2773), back_on_main_menu 3263 (3263) | yes |
| `cup` | reference | main_menu 2524, unlocked 2761 (2761), race1_display 3594 (3593), race1_result 22406 (22404), race1_recorded 24532 (24532), race2_display 26080 (26079), race2_result 42310 (42308), race2_recorded 44432 (44432), race3_display 45981 (45980), race3_result 59575 (59864), cup_complete 62032 (62032) | yes |
| `boot_to_race` | interpreter | main_menu 2524, race_image 3291 (3290), race_display 3304 (3303) | yes |
| `full_race_cross` | interpreter | main_menu 2524, race_image 3291 (3290), race_display 3304 (3303), race_over 21549 (21794) | yes |

Every race starts one frame after mGBA's (P2-13), and `full_race_cross`'s race ends 245 frames earlier, inside the slack P2-04 left. On the cup the results differ from mGBA's as P2-13 found for this gbarecomp (phase2-race-lockstep.md §4): race 3's result comes 289 frames earlier and the player has 4 Cross Rookie points after race 3 instead of 3 (`expect` is a result, reported and not required for following the route), and the final save's SHA-1 is `390257e6704900e6d8a39a96be289913cdcf1c27`, not mGBA's `f6743468…`. The runner reports the final save and does not gate it (P2-11 gates saves).

**A moved input fails.** A copy of `boot_to_race.txt` with the `wait 60` after `tap START` shortened to `wait 2`, so that the `tap A` meant for the language menu comes before it is up (`--script`, scratch file): on both engines the main menu comes at 2658 instead of 2524, still before its deadline, and the race image at 3645 (gbarecomp) and 3644 (mGBA), after the input that relies on it (3609): `route boot_to_race: 2 checkpoint(s) failed`, and the runner fails.

## 7. Reproducing

From the repository root, with the ROM and BIOS in `roms/` and `bios/`, `scripts/build-native.sh` and `tools/analysis/harness/build.sh` done:

```sh
scripts/replay-test.sh boot_to_race --against mgba                       # section 3
scripts/replay-test.sh boot_to_race --against mgba --frames 1-3290 --replay-offset 1   # section 5
scripts/replay-test.sh boot_to_race --against interp                     # section 4.1
scripts/replay-test.sh boot_to_race --against interp --frames 1-3290 --fp-ring 295     # section 4.2
for r in $(python3 -I tools/difftest/routes.py list); do
  scripts/replay-test.sh "$r" --against none --test reference; done      # section 6
```

The fine-grained RAM captures of section 3.2 use a copy of `tools/capture/spec.txt` whose `ram` entries split a region, passed to both engines (`GBARECOMP_CAPTURE_SPEC=@FILE`, `--capture-spec FILE`), and `tools/capture/capture.py join`. The scratch build of section 4.1 appends the front end's image and its roots to a copy of `game.toml` and builds it with `MRA_GAME_CONFIG`, `MRA_BUILD_DIR` and `MRA_GENERATED_DIR` set to scratch paths, as P2-05 §6 did.

## 8. Not done here, and follow-ups

- **Allowlists for the other routes.** Only `boot_to_race` has one; P2-11 and P2-19 build the others when they run them against mGBA. The front-end entries carry over to every route that boots the same way.
- **U21 and U22** need fixing before comparison 1 can pass on P2-10's build (section 4.4): a task like P2-21, waiting on decision 9.
- **The race program and WAITCNT** (section 4.2): whether U21 also shows at race start and return.
- **The stack words against mGBA** are allowlisted on the evidence of which words differ; showing that they are dead at the sample point needs the stack pointers at VBlank start, which the capture does not record.
- **2968-2973** (OBJ priority over an affine BG) and the affine reset values of frame 1 need hardware data to say which engine is right.
- **`full_race_cross` 9692 and 16306** (section 4.3): localize them with a fingerprint window that starts where the two runs' clocks agree.
- **Layer 2's effect lines** are an over-approximation ([tools/difftest/README.md](../../tools/difftest/README.md), "What is compared"): a semi-transparent OBJ cannot be told from the line records alone. If it lets a real difference through, the line records would need OAM's blend bits.

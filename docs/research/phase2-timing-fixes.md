# GamePak prefetch reset and IRQ entry cycles

**Date:** 2026-10-11, revised 2026-10-12 (review round 1: `0012`'s DMA condition, the traces of section 6, `irqentry2`) and 2026-10-13 (review round 2: the round-1 results measured again, section 6's account of bridges and tick lengths corrected)
**Scope:** P2-21 of [phase2-plan.md](../phase2-plan.md): turn the two timing fixes that [phase2-race-lockstep.md](phase2-race-lockstep.md) (P2-13) found and prototyped into patches with synthetic repros, carry the part that lives in gbarecomp's nested submodule `external/arm-recomp-core` with a second patch series, and measure the result on `boot_to_race`, `full_race_cross` and the cup against mGBA, with P2-13's tooling (P2-03's captures joined on the frame column, and `tools/difftest/timeline.py`).
**Status:** Measured on the M4 Pro. Not measured on hardware: the fixes copy mGBA's model, which gbarecomp names as its reference; whether either engine matches hardware is **unverified**, as in P2-13. mGBA's IRQ and DMA latencies are not copied (owner decision 4).

## Pins

| | |
|---|---|
| ROM | Moto Racer Advance (Europe) `A9MP`, SHA-1 `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0` |
| BIOS | retail, SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492` |
| gbarecomp | `5e89943528aee7bc1c399bdbd035364a4b41dd10` with `patches/gbarecomp/` 0001-0006, 0011 and 0012 (its revised condition, section 1; "first version" is the one this branch first had); nested `external/arm-recomp-core` at `1f13cdfd3b437a7a3919285f381987bd43f5234a` with `patches/arm-recomp-core/0001`. "Stock" is the A/B build `--without 0011 --without 0012 --without arm-recomp-core/0001`, which is `main`'s series |
| Game config | `game.toml` of `main` at `dd12c69` (P2-05): IWRAM code interpreted in bridges |
| mGBA | libmgba 0.10.5 (`26b7884`) through `tools/analysis/harness`, built from this branch |
| Machine | Apple M4 Pro, macOS; native runs headless with `SDL_AUDIODRIVER=dummy`, `GBARECOMP_SELFHEAL_RECOMPILE=0` and a fresh save |

Frame numbers are harness frames. "BIOS reference" is gbarecomp with `GBARECOMP_FORCE_INTERP=1 MRA_INTERP_BIOS=1` (P2-02); "recompiled" is the normal build. Both run P2-02's replay (`MRA_REPLAY`) and capture with `tools/capture/spec.txt` and these memory fields: the route fields (`routes.py trace-mem`), the race's random number state `0x02000720:2`, the front-end counter that seeds it `0x0203FCCC:2`, the lap words `0x0201A370`-`0x0201A37C` and CP1-CP7's cup points `0x0203FC53:4`, `0x0203FC57:4` ([phase2-routes.md](phase2-routes.md) §3).

## Summary

- **The patches.** `patches/arm-recomp-core/0001` adds `Bus::prefetch_reset`, calls it from `Interpreter::step` after any instruction that wrote R15, and resets `last_prefetched_pc` after the refill of every direct branch in generated code. `patches/gbarecomp/0011` is the runtime's half: the GBA bus overrides the reset, and `runtime_refill_cycles` (every PC write known only at run time) resets too. `patches/gbarecomp/0012` charges IRQ entry's refill, 2 cycles at the BIOS vector, unless a DMA held the bus during the instruction that just ran, wherever its cycles were charged (in `runtime_tick`, or after the write that started an immediate DMA). They are P2-13's prototypes C and B as patches, with headers ready for upstream (U19, U20).
- **The tooling.** `scripts/apply-patches.sh` now applies a second stacked series, `patches/arm-recomp-core/`, to the nested submodule, with the same checks, states, `--write-patch`, `--diff`, stamps and A/B builds (`--without arm-recomp-core/0001`); `tests/tooling/apply-patches-test.sh` covers it on a toy nested repository (246 checks, 157 before). A `--without` name in an unknown series now stops instead of naming a gbarecomp patch.
- **Synthetic repros** (`tests/repro/`, no Nintendo data): `prefetch1` and `irqentry1` give mGBA 0.10.5's cycle counts on generated code and on the interpreter with the patches, and the pin's other counts without them; `irqentry2`, an IRQ raised during an immediate DMA, gives mGBA's counts with `0012` and fails with its first version (section 2).
- **The race starts on mGBA's frame.** On `boot_to_race`, the race image arrives at frame 3290 and the race is displayed from 3303, as in mGBA, on the BIOS reference and on the recompiled build (stock: 3291 and 3304). The hand-off's instruction timeline equals mGBA's to the cycle (section 3).
- **`full_race_cross` plays as in mGBA** on the BIOS reference: race display 3303-21788, laps 5444, 6108 and 6110 frames, the random number state equal on all 25,000 frames, EWRAM and IWRAM equal on every race frame but 3 of the load (section 4). The recompiled build cannot run a race to its end on `main`'s config (it stops at the bridge cap at frame 5,127, as before); its race frames up to 4,400 equal the BIOS reference's.
- **The cup ends with mGBA's positions and points**: every rider's points after each of the three races, and the final standing. Races 1 and 2 have mGBA's lap times; race 3's last lap is 122 frames shorter, and the random number state differs from frames 18287, 41445 and 51426 on, as P2-13's prototype B found: what remains is IRQ and DMA latency (owner decision 4). The final save differs from mGBA's in the same 8 bytes as P2-13's (section 5).
- **Comparison 1 on `boot_to_race`**: the frame CRCs of the recompiled build and the BIOS reference differ on the same three frames as on `main` (2185, 2188-2189, P2-05's recorded deviation). No frame differs, in any column, that did not differ on `main`, and 14 that did are equal now. Frame 294 differs in another column than on `main`: its EWRAM hash instead of its line state. Its cause is in the pin: at the game's WAITCNT write (`0x080025D0`), generated code charges 9 cycles and the interpreter 7 (mGBA 6), and which column shows the 2-cycle offset depends on the series; with `0012` it is the EWRAM hash, a RAM-hash column of exit criterion 2, so P2-21's "no regression in comparison 1" holds on that frame only if the owner accepts it (the plan's decision 10). It remains after P2-10, and it is not a bridge effect: the recompiled run bridges nothing on that frame, and the reference's bridges, one SWI-vector branch per SWI, stay after P2-10 and are inert (section 6). `0012`'s first version also made one line's palette differ on 3294; the trace led to its revised condition.

## 1. What changed

| | Where | What |
|---|---|---|
| arm-recomp-core `0001` | `profiles/armv4t_gba/bus.h`, `interpreter.cpp`, `arm_codegen.cpp` | `Bus::prefetch_reset()` (no-op by default); `Interpreter::step` calls it when `wrote_pc`, after the instruction's own stalls; `emit_direct_branch` emits `g_runtime_waits.last_prefetched_pc = 0u;` after the static refill, on every path |
| gbarecomp `0011` | `gba_bus.h`, `runtime_arm_default_aborts.cpp`, `runtime_wait_inline.h`, `ws_sidecar.cpp`, `tests/codegen/test_main.cpp`, `tests/armv4t/interpreter_smoke.cpp`, `docs/CPU_TIMING.md` | `GbaBus::prefetch_reset` and the force-interp adapter's forward; the reset in `runtime_refill_cycles`; the widescreen sidecar restores the position after its shadow draws; `codegen_tests`' bus forwards it; a new `interpreter_smoke` case |
| gbarecomp `0012` | `runtime_bus_bridge.cpp`, `docs/CPU_TIMING.md` | `drain_dma_steal` sets a flag whenever it charges a DMA's cycles (from `runtime_tick`, or from `runtime_resync_horizon` after the write that started an immediate DMA); `runtime_tick` reads and clears it at every IRQ check and charges `2 + runtime_refill_cycles(0x18, 0)` before `runtime_irq` when it was clear, pumped like the HALT wake delay. The first version tested the cycles drained in the same `runtime_tick` only (section 6) |
| tooling | `scripts/apply-patches.sh`, `scripts/lib/common.sh`, `tests/tooling/apply-patches-test.sh`, `scripts/repro-test.sh` | the nested series (patches/gbarecomp/README.md, "The nested series"); the timing cases |
| repros | `tests/repro/make_rom.py`, `prefetch1.toml`, `irqentry1.toml`, `irqentry2.toml`, `make_bios.py`, `bios.toml` | the three ROMs; the stand-in BIOS's unused vectors branch forward so that mGBA loads it (SHA-1 `c767007db5d7cb3eb1b992c285906e5025755c6b`) |

Where P2-13's prototypes differed: prototype B gated the IRQ entry cycles behind an environment variable, and `0012` does not; prototype C named the reset `prefetch_flush`, did not reset at IRQ entry, and did not restore the position after the widescreen sidecar's shadow draws. Like prototype C, and unlike P2-13's variant A', `0001` resets in `Interpreter::step` rather than at its two call sites in gbarecomp: that keeps `codegen_tests`, which steps the interpreter directly, able to compare the two backends' buffer positions.

The two halves of the prefetch fix depend on each other: `0011` overrides a virtual that arm-recomp-core's `0001` adds, so it does not build without it, and `0001` alone builds but leaves the interpreter without the reset while generated static branches have it. A/B builds leave out both or neither (`--without 0011 --without arm-recomp-core/0001`). `0012` stands alone: without `0011` it adds the cycles but not the reset at IRQ entry, which is never observable anyway (the IRQ returns to the cartridge through a PC write that resets it). Its first version did not apply without `0011`: its `docs/CPU_TIMING.md` section sat right after `0011`'s, in that hunk's context. The section now follows "Cost of one instruction". `scripts/apply-patches.sh --check --without 0011` builds the variant, `0012` alone applies to the pin's files (`git apply --check`), and `scripts/repro-test.sh --without 0011 --without arm-recomp-core/0001 --expect-failure prefetch1` builds with `0012` and gives 1673, 1673 and 1141 on both backends.

## 2. Unit tests and synthetic repros

`scripts/test-engine.sh`: 52 of 52 gbarecomp tests pass with the series (with the gba-tests test ROMs). `codegen_tests` compares the interpreter's and the generated code's cycles and buffer position for every instruction of its corpus, relocated into the cartridge under five WAITCNT and EWRAM settings, one of them with the position seeded just ahead of the instruction. Mutations, each made by hand, built and reverted (not committed):

| Removed | Fails |
|---|---|
| the interpreter's call (`if (wrote_pc) bus.prefetch_reset();`) | `interpreter_smoke` on every kind of PC write (`prefetch_reset_on_pc_write: b reset the buffer 0 time(s) (expected 1)`, ...), and `codegen_tests` on its 18 PC-writing cases (26 of 131 runs) |
| the codegen's reset after a static refill | `codegen_tests` on the 4 static branches: `arm_b_forward`, `arm_bl`, `arm_b_backward`, `thumb_beq_taken` (4 of 131 runs) |
| the reset in `runtime_refill_cycles` | `codegen_tests` on the 14 PC writes known only at run time: BX (`arm_bx_to_arm`, `arm_bx_to_thumb`, `arm_bx_lr_to_thumb_sets_t`, `thumb_bx_lr_to_arm_clears_t`), MOV and ADD to PC (`arm_mov_pc_lr`, `arm_mov_pc_reg_shift`, `thumb_mov_pc_clears_bit0`, `arm_add_pc_imm`, `arm_add_pc_pc_r0`, `arm_add_pc_pc_r0_lsl2`), POP and LDM with PC (`arm_pop_r4_pc`, `thumb_pop_r4_pc`, `arm_ldmia_pc_computed`, `arm_ldmia_empty_wb`) (22 of 131 runs) |

`scripts/repro-test.sh` ([tests/repro/README.md](../../tests/repro/README.md), "CPU timing against mGBA"), each case on generated code (`GBARECOMP_STRICT_STATIC=1`, fully static) and on the interpreter with the BIOS interpreted too; mGBA's values from the harness on the same ROM and BIOS image (`--skip-bios`):

| Case | mGBA 0.10.5 | All patches, both backends | Stock, both backends |
|---|---|---|---|
| `prefetch1` (3 loops: ARM `bcc`, ARM `bxcc`, THUMB) | 1424, 1424, 892 | 1424, 1424, 892 | 1673, 1673, 1141 |
| `irqentry1`, stand-in BIOS (loop, loop with one IRQ, IRQ count) | 2596, 2748, 1 | 2596, 2748, 1 | 2596, 2746, 1 |
| `irqentry1`, retail BIOS | 2596, 2747, 1 | 2596, 2747, 1 | not run |
| `irqentry2`, stand-in BIOS (DMA alone, DMA with one IRQ inside, IRQ count) | 789, 939, 1 | 789, 939, 1 | 789, 939, 1 (`--without 0012`); `0012`'s first version: 789, 941, 1 |
| `irqentry2`, retail BIOS | 789, 938, 1 | 789, 938, 1 | not run |

The stock column is the A/B build `--without 0011 --without 0012 --without arm-recomp-core/0001 --expect-failure prefetch1 irqentry1`, which passes: every value the bugs change differs from mGBA's. The irqleak and overlay1 cases give their recorded results with the series and with the new stand-in BIOS, on both BIOS images.

`irqentry2` (added in review round 1) is `irqentry1`'s program with the timed work replaced by one store to DMA3CNT, an immediate DMA3 of 64 words from EWRAM to EWRAM (about 770 cycles); in its second run, timer 1 overflows about 256 cycles after it starts, while the DMA holds the bus. mGBA charges no refill for that IRQ's entry: 939 - 789 = 150 cycles, `irqentry1`'s 152 less the refill. Generated code and the interpreter charge an immediate DMA's cycles after the store that starts it, so `0012`'s first version, which looked for DMA cycles drained in the same `runtime_tick`, charged the refill there: 941, on both backends. The pin charges no IRQ entry at all and gives mGBA's values too, so the case has no `--expect-failure` run (`scripts/repro-test.sh` refuses one). The values above were measured on 2026-10-12, the first version's by putting its file back in `patches/gbarecomp/` for one run.

## 3. `boot_to_race`: the hand-off

4,400 frames, each gbarecomp capture joined with mGBA's (`tools/capture/capture.py join`). A number is how many frames differ in that column; the `fb` column is left out, since the renderers differ (diagnosis §5), as in P2-13's section 4.

| Build | Race image / display | Front end 1-3289: lines, EWRAM, IWRAM, I/O writes | Race 3290-4400 (1,111 frames): lines, EWRAM, IWRAM, I/O writes, FIFO A |
|---|---|---|---|
| mGBA | 3290 / 3303 | | |
| BIOS reference, stock | 3291 / 3304 | 56, 21, 1, 2 | 1022, 1108, 1097, 459, 518 |
| BIOS reference, P2-21 | 3290 / 3303 | 38, 3, 0, 0 | 8, 3, 0, 0, 0 |
| recompiled, stock | 3291 / 3304 | 57, 24, 88, 45 | 1022, 1108, 1097, 459, 518 |
| recompiled, P2-21 | 3290 / 3303 | 39, 7, 87, 42 | 8, 3, 0, 0, 0 |
| BIOS reference, P2-21 without `0012` | 3290 / 3303 | | random number state from 3885, IWRAM from 4277 |

With `0012`'s first version the P2-21 rows were P2-13's rows B and C, frame for frame: 44 and 45 frames of front-end line state, the other columns as above. The revised condition leaves 38 and 39: 7 frames are gone on both backends (2972, 3002, 3004, 3017, 3039, 3042, 3045) and one is new (2973, next to 2972, among the frames 2968-2973 that P2-02 found and P2-09 classifies). The stock rows are P2-13's "Stock" row and its unchanged recompiled build. With P2-21 the random number state equals mGBA's on all 4,400 frames on both backends. The 8 race frames of line state are the load (3293-3302, VRAM and palette written while the screen shows the backdrop), the 3 EWRAM frames 3295, 3297 and 3300. The recompiled build's extra front-end differences (87 IWRAM frames, 2185-2271, and the I/O writes) are the HALT write storm of an interpreter bridge running the BIOS IntrWait (diagnosis §1.5, P2-05), not timing; they are gone once IWRAM code is compiled (P2-10). As on `main`, the recompiled run does not stop at 4,400: its race loop runs in a bridge until the 200M-instruction cap at frame 5,127 (exit 134; `SELF-HEAL bridge for 0x03001CB0 exceeded 200000000 instructions`), on the stock build too (diagnosis §3.4).

**The instruction timeline of the hand-off** (`timeline.py`, mGBA's `--trace-pc 0x00000000-0x0FFFFFFF --trace-pc-cycles --step-frames 3286-3290` against the BIOS reference's clock probe from record 3285 to record 3291, `GBARECOMP_CYC_LO=922659584 GBARECOMP_CYC_HI=924344961`):

```
at 08159FD0 (mGBA clock 922676780): gbarecomp +0
at 08159FE0 (mGBA clock 923874894): gbarecomp +0
instructions: mGBA 187588 (187543 main-line, 1 IRQs), gbarecomp 266993 (266993 main-line, 0 IRQs, 0 idle ticks while halted); matched 187543
clock difference gbarecomp - mGBA at the last matched instruction: +0
  changed by instruction costs: +0; next to IRQs: +0 (0 changes); by skipped loop iterations: +0 (0)
```

On the stock build the same command printed +1815 and +219644 at the two watches and `instruction 08159FD8: +217829 over 54458 changes` (P2-13 §2). Every one of the 187,543 matched instructions now has mGBA's clock. (gbarecomp's probe runs past mGBA's last record, to record 3291, hence the unmatched instructions.) The output above is the revised `0012`'s (2026-10-12); the first version printed the same, and so did a fresh build and fresh mGBA trace in review round 2 (2026-10-13), as did the frame 3885 counts below.

**Frame 3885, IRQ entries** (mGBA's `--step-frames 3885` against the probe from record 3884 to 3885, `--line0 1090916288`): IRQ entries on VBlank lines cost 2 cycles in mGBA (58 of 60 measured) and in gbarecomp (57 of 60); on visible lines 30 in mGBA (158 of 160) and in gbarecomp (155 of 160), the HBlank DMA hiding the refill. The clock difference at the end of the frame is -2 cycles. With `0012`'s first version it was +5, as with prototype B (P2-13 §3: +5, against -138 with the prefetch reset alone), with 60 of 61 VBlank entries and 158 of 160 visible ones at mGBA's cost. The remaining differences next to IRQs are mGBA's IRQ and DMA latencies, which neither version copies (decision 4).

## 4. `full_race_cross`

25,000 frames, BIOS reference.

| Build | Race image / display | Lap words (frames) | Race frames 3290-21788 (18,499): lines, EWRAM, IWRAM, I/O, FIFO A |
|---|---|---|---|
| mGBA | 3290 / 3303-21788 | 5444, 6108, 6110 | |
| stock (P2-13) | 3291 / 3304-21542 | 5200, 6110, 6106 | one frame apart throughout |
| P2-21 | 3290 / 3303-21788 | 5444, 6108, 6110 | 29, 3, 0, 0, 0 |
| P2-21, `0012`'s first version | 3290 / 3303-21788 | 5444, 6108, 6110 | 28, 3, 0, 0, 0 |

The random number state, the front-end counter and the lap words equal mGBA's on all 25,000 frames, with either version of `0012`. The 29 frames of line state are the 8 of the load and 21 single lines where the HBlank handler's palette write lands on the other side of a line (P2-13 §4); EWRAM differs on 3295, 3297 and 3300. Against the first version, 3 of those single lines are gone (4572, 4843, 10983) and 4 are new (4717, 8733, 13339, 16606); over all 25,000 frames the line state differs on 71 frames instead of 76 (the front end's 7 and 1 of section 3 included). The mGBA capture was taken again for this comparison (2026-10-12, the same harness and command), and both captures once more in review round 2 (2026-10-13), with the same counts. After the race, 4 frames of line state and one frame each of EWRAM (21797) and IWRAM (21794) differ. The IRQ stack region differs on 4 race frames (3293, 3303, 3304, 3306), on 894 of the front end's 3,289 frames and on 896 of the 3,212 after the race, as P2-13 measured with prototype B; P2-09 classifies stack differences. The stock row is P2-13's (not re-run here: its `boot_to_race` row above reproduces).

## 5. The cup

63,542 frames (`cup`), BIOS reference. Race images arrive at 3580, 26066 and 45966, and the races are displayed from 3593, 26079 and 45980, in both engines.

| Build | Race 1 laps | Race 2 laps | Race 3 laps | Points after races 1, 2, 3 (player, CP1-CP7) | Final standing |
|---|---|---|---|---|---|
| mGBA | 5784, 6139, 6106 | 5241, 5107, 5107 | 4470, 4260, 4376 | 1,3,2,5,4,8,6,7; 2,7,7,7,7,16,12,14; 3,9,12,11,10,22,20,21 | 7 (8th of 8) |
| P2-21 | the same | the same | 4470, 4260, 4254 | the same | the same |

The points and the cup record (`0x0203FC50`-`0x0203FC59`) equal mGBA's on every frame but 59742-59863, where race 3 ends 122 frames earlier in gbarecomp (display to 59722 instead of 59844) and its points are written earlier. The random number state differs from frame 18287 in race 1, 41445 in race 2 and 51426 in race 3, each time until the race ends: the draws that read VCOUNT within a few cycles of a line boundary, which P2-13 §5 traced to the IRQ and DMA latencies P2-21 does not copy. The final save (mGBA's SHA-1 `f6743468e8ecd41f21a5e3d58cdc83ab4c9e2128`, the route manifest's) differs in 8 bytes, `0x114`, `0x115`, `0x11C`, `0x11D`, `0x124`, `0x125` and the checksum `0xCC8`-`0xCC9`, the same as P2-13's prototype B. This is P2-13's row B, frame for frame. Exit criterion 3 on the cup (every frame and every race time equal) is still the owner's decision 4.

The cup was run again with the revised `0012` (2026-10-12), against a new mGBA capture whose final save has the manifest's SHA-1: everything above holds unchanged. The race images, DISPCNT, the lap words, the points and the cup record are equal to the first version's run on every frame, the random number state diverges from the same three frames, and the final save differs from mGBA's in the same 8 bytes. The two gbarecomp runs differ only within race 3 after frame 53025, where both had left mGBA's random number state (from 51426). Review round 2 (2026-10-13) ran the cup once more on a fresh build, against a fresh mGBA capture whose save again has the manifest's SHA-1: the same race image and display frames, points, cup record, divergence frames and 8 save bytes.

## 6. Comparison 1

`boot_to_race`, recompiled build against the BIOS reference of the same series, both 4,400 frames:

| Series | 1-3290: fb, lines, EWRAM, IWRAM, stacks, I/O, FIFO A, HALT writes | 3291-4400 | Clocks differ |
|---|---|---|---|
| stock | 3 (2185, 2188-2189), 5 (294, 1864, 1873, 2188-2189), 3 (2185-2187), 87, 119, 43, 71, 43 | stacks on 3303 | 371 frames |
| P2-21 without `0012` | 3 (2185, 2188-2189), 4 (1864, 1873, 2188-2189), 3 (2185-2187), 87, 117, 42, 71, 42 | fb and lines on 4315 | 443 |
| P2-21, `0012`'s first version | 3 (2185, 2188-2189), 2 (2188-2189), 4 (294, 2185-2187), 87, 107, 42, 71, 42 | lines on 3294, stacks on 3303 | 709 |
| P2-21 | 3 (2185, 2188-2189), 2 (2188-2189), 4 (294, 2185-2187), 87, 107, 42, 71, 42 | stacks on 3303 | 110 |

The stock row reproduces P2-05's measurement exactly ([phase2-resume-roots.md](phase2-resume-roots.md) §3). The frame CRCs differ on the same three frames in every series, P2-05's recorded deviation (a HALT flag left set by the intro player's bridge). "Clocks differ" counts the frames whose record clock (`cycles`) differs between the two backends. Review round 2 (2026-10-13) captured the stock and P2-21 rows again on fresh builds and got them frame for frame, with the same clock counts and the same sets of frames below; it also probed frames 294 and 3293 again, with the results below.

Against stock, P2-21 makes no frame differ that did not differ before, in any column, and 14 frames that differed are equal now: 1864 and 1873 (line state) and 12 frames of the stack region (295, 296, 1476, 1546, 1623-1625, 1630, 1637, 1840, 1847, 1862). The union of the frames that differ in fb, EWRAM or IWRAM still grows from 87 to 88: frame 294 differs in both series, in its line state on stock and in its EWRAM hash with P2-21. Over all columns, 203 frames differ on stock and 189 with P2-21 (190 with `0012`'s first version, 200 without `0012`).

**Frame 294, traced.** The clock probe over records 293 to 294 on both backends (`GBARECOMP_CYC_LO=82218760 GBARECOMP_CYC_HI=82499700`, 296 frames), aligned instruction by instruction (`tools/difftest/probediff.py`), finds the first difference at the game's WAITCNT write, `strh r0, [r4, #4]` at `0x080025D0` (r0 = `0x4014`: ROM waits 3/1, prefetch buffer on; r4 = `0x04000200`, literals at `0x08002684`-`0x0800268B`). Generated code charges it 9 cycles, the interpreter 7, mGBA 6 (`--trace-pc 0x080025B0-0x080025E0 --trace-pc-cycles --step-frames 294`; with P2-21 the three engines agree up to that instruction, which starts at clock 82287385, and the stock build reaches it 2 cycles early, at 82287383). Generated code computes the instruction's fetch wait, `g_runtime_waits.n32[8]`, at the start of the instruction, before the store, so with WAITCNT's old value (arm-recomp-core `profiles/armv4t_gba/arm_codegen.cpp:168-179` and `:1530-1535` with the series; the generated block for `0x080025D0` reads it first); the interpreter adds `code_wait` after it has executed the instruction (arm-recomp-core `profiles/armv4t_gba/interpreter.cpp:1206-1213` with the series), so with the new value. Where mGBA's 6 comes from (its prefetch cycles before the store, its stall with the new prefetch bit) is **unverified**. The recompiled build stays 2 cycles behind for the rest of the frame, so the VBlank IRQ interrupts it one instruction earlier than the reference (in the BIOS loop at `0x12B0`), and the two VBlank-start records sample different states. The record clocks are equal again from frame 296. The stock build gives the same 7 and 9 at the same instruction, so this is a difference between gbarecomp's backends at the pin, not one P2-21 adds. Which column the offset reaches at the next VBlank-start record depends on what else moved: the line state on stock (the difference P2-05 left to P2-09), only the clock without `0012`, the EWRAM hash with it. The hashes of frame 294: on stock both backends give EWRAM `011C3608` and different line states (`DC07ACC3` on the reference, `23A6396A` on the recompiled build); with P2-21 both line states are mGBA's `924D5329`, the reference's EWRAM is mGBA's `DC192DD4`, and the recompiled build's is `E0D116C8`. So `0012` does not create the offset, but its IRQ entry cycles are what carry it into the EWRAM hash on this frame, a RAM-hash column of exit criterion 2: whether that meets P2-21's "no regression in comparison 1" is the plan's decision 10. `0x080025D0` is cartridge code, compiled in the recompiled build and stepped by the interpreter in the reference, so the difference stays after P2-10: it needs a fix in gbarecomp (both backends differ from mGBA here) or an entry in P2-09's list with this cause.

**Frame 3294 with `0012`'s first version, traced.** The probe over records 3292 to 3294 (`GBARECOMP_CYC_LO=924625857 GBARECOMP_CYC_HI=925187700`) shows the race program's start-up writing DMA3CNT from IWRAM (`0x030000A8`, an immediate DMA of 11,266 cycles) just before VBlank, and the VBlank IRQ taken at the end of that instruction. In the reference, the force-interp backend drained the DMA right after the write (`runtime_resync_horizon`), so the `runtime_tick` that took the IRQ had charged no DMA and the first version charged the refill. In the recompiled build, that IWRAM code ran in a self-heal bridge, which steps the bus directly, so the DMA was drained inside `runtime_tick` and the refill was hidden. The 2 cycles moved a palette write of the next frame's line 4 across the line. In mGBA the vector runs at 924909708 (`--trace-pc` of frames 3293-3294). With its IRQ latency of 7 cycles, the IRQ is likely raised after its DMA has ended, so that its entry pays the refill (inferred from mGBA's model, not traced in mGBA). gbarecomp copies neither latency, so the IRQ is pending when the DMA's instruction ends, and the patch's own rule, a DMA that holds the bus hides the refill, says to hide it. The revised condition does, on both sides: neither probe now has an `irq_entry` after the DMA, the clocks are equal after the next instruction, and 3294 no longer differs. `irqentry2` (section 2) reproduces the case on generated code and on the interpreter. Of the 709 frames where the first version's record clocks differed, 708 had instructions in a bridge on the recompiled side, 294 being the exception. With the revised condition 110 frames differ, fewer than on stock (371), 109 of them with bridged instructions on the recompiled side, 294 again the exception. At 3293 what remains is a record taken at another master clock for the same device time: the DMA's cycles are charged at the write on one side and at the end of the instruction on the other, so the flush that crosses VBlank start happens 2 cycles apart, and the clocks agree again at the next instruction. The other 108 were not traced (**unverified**); where a DMA is drained no longer changes an IRQ entry's cost.

**The reference's own bridges.** The BIOS reference bridges BIOS code too: `MRA_INTERP_BIOS` sends every dispatch to a BIOS PC through `runtime_bridge_interpret` (gbarecomp `src/armv4t/runtime_arm.cpp:897-901` with the series), which steps the bus directly (`src/runtime/runtime_arm_default_aborts.cpp:447` and `:560`). That stays after P2-10. Measured, those bridges cannot meet the condition above: the run's miss report lists one bridged entry, `0x00000008`, the SWI vector; the bridge stops at the first PC with a static entry, `0x140`; in both probed windows every bridged instruction is that vector's `b 0x140`, run with IRQs masked (CPSR `0x93`). The bridge count of the capture (5,365 instructions on 3,054 of the 4,400 frames, 176 on frame 294) counts these branches, one per SWI. They do no data access and take no IRQ. With the revised condition, where a DMA is drained no longer decides the IRQ entry's cost anyway. The first version of this section put the transients down to the self-heal bridge's raw-bus stepping, untraced, and counted only the recompiled run's bridges ("294 has none"); it left out that the reference bridges too (176 instructions on frame 294), and frame 294, whose new difference is on the side that bridges nothing there, did not fit. The traces above replace that account: 294's cause is the WAITCNT write, and the reference's bridges are inert.

**How much a tick covers.** Review round 2 asked whether "DMA cycles charged in the same `runtime_tick`" could depend on how many cycles a tick covers, which might differ between generated code and per-instruction stepping. It does not: every backend calls `runtime_tick` once per instruction. Generated code ticks each instruction's cost at its boundary (arm-recomp-core `profiles/armv4t_gba/arm_codegen.cpp:1602-1611` with the series, and on each control-flow exit before it), the force-interp step after each instruction (`src/runtime/runtime_arm_default_aborts.cpp:855` with the series) and the self-heal bridge after each instruction (`:604`); the pin's own comment says the same (`src/runtime/runtime_bus_bridge.cpp:852-854` with the series). The probes above show one `tick` per instruction on both sides. Device time is materialized in batches up to the next event, by the same code on every backend; only the self-heal bridge's raw-bus accesses skip the catch-up and the DMA drain that the other two run around I/O accesses, which is what differed at 3294. So "the instruction that just ran" is the same window everywhere; what differed was where in that window the DMA's cycles were drained, which the revised condition no longer looks at.

**For P2-09 and P2-10.** They should not count on these differences going away with the recompiled build's bridges. Frame 294's offset is in cartridge code, which both sides run after P2-10 as before. The reference keeps one bridge per SWI after P2-10. Of the 110 frames whose record clocks still differ, only 294 and 3293 are traced; 3293's comes from IWRAM code that the recompiled build bridges, so it may go once IWRAM is compiled (not measured), and the other 108 are **unverified**. Comparison 1 checks frame CRCs and RAM hashes, not the clock, so a clock difference matters where it reaches one of them, as 294's does. The plan's P2-09 and P2-10 sections say this.

## 7. What is left

- **IRQ and DMA latency** (owner decision 4, [phase2-race-lockstep.md](phase2-race-lockstep.md) §8 point 2): the cup's random number state still diverges in each race, and race 3's time differs. P2-21 copies neither mGBA's IRQ delay nor its DMA start delay.
- **Full races on the recompiled build** wait for P2-10: on `main`'s config the race loop runs in an interpreter bridge, which stops at the 200M-instruction cap at frame 5,127 with or without these patches. The recompiled build's race frames up to 4,400 equal the BIOS reference's but for one frame of stacks (3303), as on `main`.
- **The WAITCNT write's cost** (section 6, frame 294): generated code charges a store that changes WAITCNT with the old wait states for the next fetch, the interpreter with the new ones, and mGBA differs from both. It is in the pin, not in these patches, and it stays after P2-10, where comparison 1 gates: P2-09 lists it with this cause, or a gbarecomp patch fixes it (both backends would then need mGBA's cost, which is **unverified** in its parts).
- **tools/bios_smoke**, gbarecomp's own interpreter oracle, keeps its own IRQ loop with no entry cycles; it gets the prefetch reset through `GbaBus`. Not changed here.
- **Multiplayer session execution** takes IRQs in `runtime_should_yield`, without entry cycles. Link play is out of Phase 2's scope.

## Reproducing

From the repository root, with `scripts/setup.sh` run, the harness built and `build/native` built (`scripts/build-native.sh`). P2-13's "Reproducing" section gives the capture and probe commands; with this series:

```sh
mkdir -p build/replays build/cap
for r in boot_to_race full_race_cross cup; do
  python3 -I tools/replay/script2replay.py --route $r -o build/replays/$r.csv; done
MEM="$(python3 -I tools/difftest/routes.py trace-mem),0x02000720:2,0x0203FCCC:2,0x0201A370:4,0x0201A374:4,0x0201A378:4,0x0201A37C:4,0x0203FC53:4,0x0203FC57:4"

# mGBA, per route (4400, 25000, 63542 frames)
tools/analysis/harness/run_harness.sh --out runs/cup --script tools/analysis/input/cup.txt --frames 63542 \
  --save runs/cup.sav --capture --capture-spec tools/capture/spec.txt --capture-mem "$MEM"

# gbarecomp, BIOS reference (drop the first two variables for the recompiled build)
(cd build/native && export GBARECOMP_FORCE_INTERP=1 MRA_INTERP_BIOS=1 MRA_REPLAY=../replays/cup.csv \
   GBARECOMP_CAPTURE=../cap/cup.tsv GBARECOMP_CAPTURE_SPEC=@../../tools/capture/spec.txt GBARECOMP_CAPTURE_MEM="$MEM" &&
 <native run, 63542 frames>)
python3 -I tools/capture/capture.py join analysis-out/runs/cup/capture.tsv build/cap/cup.tsv

# stock: the same with the A/B build
scripts/build-native.sh --without 0011 --without 0012 --without arm-recomp-core/0001
# then run build/without-0011-0012-arm-recomp-core-0001/native/MotoRacerAdvanceRecomp the same way

# synthetic repros, with and without the fixes
scripts/repro-test.sh prefetch1 irqentry1 irqentry2
scripts/repro-test.sh --without 0011 --without 0012 --without arm-recomp-core/0001 --expect-failure prefetch1 irqentry1
scripts/repro-test.sh --without 0011 --without arm-recomp-core/0001 --expect-failure prefetch1   # 0012 stays in
scripts/repro-test.sh --without 0012 irqentry2                                                    # passes too

# section 6: the clock probe over two records on both backends (LO, HI: the cycles
# column of the two records, here 293 and 294; 3292 and 3294 for frame 3293), and
# mGBA's clock over the same instructions
(cd build/native && export MRA_REPLAY=../replays/boot_to_race.csv \
   GBARECOMP_CYC_LO=82218760 GBARECOMP_CYC_HI=82499700 && <native run, 296 frames> 2> ../cap/cyc294-rec.log)
# the same with GBARECOMP_FORCE_INTERP=1 MRA_INTERP_BIOS=1 into ../cap/cyc294-ref.log
tools/analysis/harness/run_harness.sh --out runs/b2r-f294 --script tools/analysis/input/boot_to_race.txt \
  --frames 295 --trace-pc 0x080025B0-0x080025E0 --trace-pc-cycles --step-frames 294
python3 -I tools/difftest/probediff.py build/cap/cyc294-ref.log build/cap/cyc294-rec.log --max 1
```

`probediff.py` matches the two logs' `tick` events in order (the same instruction stream on both backends until their clocks part; a tick's `pc` is the next instruction's) and prints each change of the clock difference with the events around it.

`<native run, N frames>` is the command of [phase2-plan.md](../phase2-plan.md), "Commands used below". Runs take about 20 s for `boot_to_race`, 2.6 min for `full_race_cross` and 7 min for the cup on the BIOS reference; captures are 0.6 to 13 MB. Capture files and logs are derived from the ROM: keep them under `build/` or `analysis-out/`.

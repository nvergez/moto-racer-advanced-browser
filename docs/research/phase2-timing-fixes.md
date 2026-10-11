# GamePak prefetch reset and IRQ entry cycles

**Date:** 2026-10-11
**Scope:** P2-21 of [phase2-plan.md](../phase2-plan.md): turn the two timing fixes that [phase2-race-lockstep.md](phase2-race-lockstep.md) (P2-13) found and prototyped into patches with synthetic repros, carry the part that lives in gbarecomp's nested submodule `external/arm-recomp-core` with a second patch series, and measure the result on `boot_to_race`, `full_race_cross` and the cup against mGBA, with P2-13's tooling (P2-03's captures joined on the frame column, and `tools/difftest/timeline.py`).
**Status:** Measured on the M4 Pro. Not measured on hardware: the fixes copy mGBA's model, which gbarecomp names as its reference; whether either engine matches hardware is **unverified**, as in P2-13. mGBA's IRQ and DMA latencies are not copied (owner decision 4).

## Pins

| | |
|---|---|
| ROM | Moto Racer Advance (Europe) `A9MP`, SHA-1 `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0` |
| BIOS | retail, SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492` |
| gbarecomp | `5e89943528aee7bc1c399bdbd035364a4b41dd10` with `patches/gbarecomp/` 0001-0006, 0011 and 0012; nested `external/arm-recomp-core` at `1f13cdfd3b437a7a3919285f381987bd43f5234a` with `patches/arm-recomp-core/0001`. "Stock" is the A/B build `--without 0011 --without 0012 --without arm-recomp-core/0001`, which is `main`'s series |
| Game config | `game.toml` of `main` at `dd12c69` (P2-05): IWRAM code interpreted in bridges |
| mGBA | libmgba 0.10.5 (`26b7884`) through `tools/analysis/harness`, built from this branch |
| Machine | Apple M4 Pro, macOS; native runs headless with `SDL_AUDIODRIVER=dummy`, `GBARECOMP_SELFHEAL_RECOMPILE=0` and a fresh save |

Frame numbers are harness frames. "BIOS reference" is gbarecomp with `GBARECOMP_FORCE_INTERP=1 MRA_INTERP_BIOS=1` (P2-02); "recompiled" is the normal build. Both run P2-02's replay (`MRA_REPLAY`) and capture with `tools/capture/spec.txt` and these memory fields: the route fields (`routes.py trace-mem`), the race's random number state `0x02000720:2`, the front-end counter that seeds it `0x0203FCCC:2`, the lap words `0x0201A370`-`0x0201A37C` and CP1-CP7's cup points `0x0203FC53:4`, `0x0203FC57:4` ([phase2-routes.md](phase2-routes.md) §3).

## Summary

- **The patches.** `patches/arm-recomp-core/0001` adds `Bus::prefetch_reset`, calls it from `Interpreter::step` after any instruction that wrote R15, and resets `last_prefetched_pc` after the refill of every direct branch in generated code. `patches/gbarecomp/0011` is the runtime's half: the GBA bus overrides the reset, and `runtime_refill_cycles` (every PC write known only at run time) resets too. `patches/gbarecomp/0012` charges IRQ entry's refill, 2 cycles at the BIOS vector, unless DMA cycles were charged in the same `runtime_tick`. They are P2-13's prototypes C and B as patches, with headers ready for upstream (U19, U20).
- **The tooling.** `scripts/apply-patches.sh` now applies a second stacked series, `patches/arm-recomp-core/`, to the nested submodule, with the same checks, states, `--write-patch`, `--diff`, stamps and A/B builds (`--without arm-recomp-core/0001`); `tests/tooling/apply-patches-test.sh` covers it on a toy nested repository (236 checks, 157 before).
- **Synthetic repros** (`tests/repro/`, no Nintendo data): `prefetch1` and `irqentry1` give mGBA 0.10.5's cycle counts on generated code and on the interpreter with the patches, and the pin's other counts without them (section 2).
- **The race starts on mGBA's frame.** On `boot_to_race`, the race image arrives at frame 3290 and the race is displayed from 3303, as in mGBA, on the BIOS reference and on the recompiled build (stock: 3291 and 3304). The hand-off's instruction timeline equals mGBA's to the cycle (section 3).
- **`full_race_cross` plays as in mGBA** on the BIOS reference: race display 3303-21788, laps 5444, 6108 and 6110 frames, the random number state equal on all 25,000 frames, EWRAM and IWRAM equal on every race frame but 3 of the load (section 4). The recompiled build cannot run a race to its end on `main`'s config (it stops at the bridge cap at frame 5,127, as before); its race frames up to 4,400 equal the BIOS reference's.
- **The cup ends with mGBA's positions and points**: every rider's points after each of the three races, and the final standing. Races 1 and 2 have mGBA's lap times; race 3's last lap is 122 frames shorter, and the random number state differs from frames 18287, 41445 and 51426 on, as P2-13's prototype B found: what remains is IRQ and DMA latency (owner decision 4). The final save differs from mGBA's in the same 8 bytes as P2-13's (section 5).
- **Comparison 1 on `boot_to_race`**: the frame CRCs of the recompiled build and the BIOS reference differ on the same three frames as on `main` (2185, 2188-2189, P2-05's recorded deviation). Two other columns differ on one frame each where they did not before (EWRAM on 294, the palette of one line on 3294), and three line-state differences of `main` are gone: few-cycle differences in when a write lands, which exist on `main` too and occur, but for frame 294, only on frames where an interpreter bridge runs (section 6).

## 1. What changed

| | Where | What |
|---|---|---|
| arm-recomp-core `0001` | `profiles/armv4t_gba/bus.h`, `interpreter.cpp`, `arm_codegen.cpp` | `Bus::prefetch_reset()` (no-op by default); `Interpreter::step` calls it when `wrote_pc`, after the instruction's own stalls; `emit_direct_branch` emits `g_runtime_waits.last_prefetched_pc = 0u;` after the static refill, on every path |
| gbarecomp `0011` | `gba_bus.h`, `runtime_arm_default_aborts.cpp`, `runtime_wait_inline.h`, `ws_sidecar.cpp`, `tests/codegen/test_main.cpp`, `tests/armv4t/interpreter_smoke.cpp`, `docs/CPU_TIMING.md` | `GbaBus::prefetch_reset` and the force-interp adapter's forward; the reset in `runtime_refill_cycles`; the widescreen sidecar restores the position after its shadow draws; `codegen_tests`' bus forwards it; a new `interpreter_smoke` case |
| gbarecomp `0012` | `runtime_bus_bridge.cpp`, `docs/CPU_TIMING.md` | `drain_dma_steal` returns the cycles it charged; `runtime_tick` charges `2 + runtime_refill_cycles(0x18, 0)` before `runtime_irq` when it charged none, pumped like the HALT wake delay |
| tooling | `scripts/apply-patches.sh`, `scripts/lib/common.sh`, `tests/tooling/apply-patches-test.sh`, `scripts/repro-test.sh` | the nested series (patches/gbarecomp/README.md, "The nested series"); the timing cases |
| repros | `tests/repro/make_rom.py`, `prefetch1.toml`, `irqentry1.toml`, `make_bios.py`, `bios.toml` | the two ROMs; the stand-in BIOS's unused vectors branch forward so that mGBA loads it (SHA-1 `c767007db5d7cb3eb1b992c285906e5025755c6b`) |

Where P2-13's prototypes differed: prototype B gated the IRQ entry cycles behind an environment variable, and `0012` does not; prototype C named the reset `prefetch_flush`, did not reset at IRQ entry, and left the widescreen sidecar to its fate. Its interpreter reset was in `Interpreter::step`, not at the call sites (P2-13's variant A'): that keeps `codegen_tests`, which steps the interpreter directly, able to compare the two backends' buffer positions.

The two halves of the prefetch fix depend on each other: `0011` overrides a virtual that arm-recomp-core's `0001` adds, so it does not build without it, and `0001` alone builds but leaves the interpreter without the reset while generated static branches have it. A/B builds leave out both or neither (`--without 0011 --without arm-recomp-core/0001`). `0012` stands alone: without `0011` it adds the cycles but not the reset at IRQ entry, which is never observable anyway (the IRQ returns to the cartridge through a PC write that resets it).

## 2. Unit tests and synthetic repros

`scripts/test-engine.sh`: 52 of 52 gbarecomp tests pass with the series (with the gba-tests test ROMs). `codegen_tests` compares the interpreter's and the generated code's cycles and buffer position for every instruction of its corpus, relocated into the cartridge under five WAITCNT and EWRAM settings, one of them with the position seeded just ahead of the instruction. Mutations, each made by hand, built and reverted (not committed):

| Removed | Fails |
|---|---|
| the interpreter's call (`if (wrote_pc) bus.prefetch_reset();`) | `interpreter_smoke` (`prefetch_reset_on_pc_write: b reset the buffer 0 time(s) (expected 1)`, and the other PC writes) |
| the codegen's reset after a static refill | `codegen_tests`: `arm_b_forward`, `arm_bl`, `arm_b_backward`, `thumb_beq_taken` |
| the reset in `runtime_refill_cycles` | `codegen_tests`: `arm_pop_r4_pc`, `arm_ldmia_pc_computed`, `arm_ldmia_empty_wb`, `thumb_pop_r4_pc` |

`scripts/repro-test.sh` ([tests/repro/README.md](../../tests/repro/README.md), "CPU timing against mGBA"), each case on generated code (`GBARECOMP_STRICT_STATIC=1`, fully static) and on the interpreter with the BIOS interpreted too; mGBA's values from the harness on the same ROM and BIOS image (`--skip-bios`):

| Case | mGBA 0.10.5 | All patches, both backends | Stock, both backends |
|---|---|---|---|
| `prefetch1` (3 loops: ARM `bcc`, ARM `bxcc`, THUMB) | 1424, 1424, 892 | 1424, 1424, 892 | 1673, 1673, 1141 |
| `irqentry1`, stand-in BIOS (loop, loop with one IRQ, IRQ count) | 2596, 2748, 1 | 2596, 2748, 1 | 2596, 2746, 1 |
| `irqentry1`, retail BIOS | 2596, 2747, 1 | 2596, 2747, 1 | not run |

The stock column is the A/B build `--without 0011 --without 0012 --without arm-recomp-core/0001 --expect-failure prefetch1 irqentry1`, which passes: every value the bugs change differs from mGBA's. The irqleak and overlay1 cases give their recorded results with the series and with the new stand-in BIOS, on both BIOS images.

## 3. `boot_to_race`: the hand-off

4,400 frames, each gbarecomp capture joined with mGBA's (`tools/capture/capture.py join`). A number is how many frames differ in that column; the `fb` column is left out, since the renderers differ (diagnosis §5), as in P2-13's section 4.

| Build | Race image / display | Front end 1-3289: lines, EWRAM, IWRAM, I/O writes | Race 3290-4400 (1,111 frames): lines, EWRAM, IWRAM, I/O writes, FIFO A |
|---|---|---|---|
| mGBA | 3290 / 3303 | | |
| BIOS reference, stock | 3291 / 3304 | 56, 21, 1, 2 | 1022, 1108, 1097, 459, 518 |
| BIOS reference, P2-21 | 3290 / 3303 | 44, 3, 0, 0 | 8, 3, 0, 0, 0 |
| recompiled, stock | 3291 / 3304 | 57, 24, 88, 45 | 1022, 1108, 1097, 459, 518 |
| recompiled, P2-21 | 3290 / 3303 | 45, 7, 87, 42 | 8, 3, 0, 0, 0 |
| BIOS reference, P2-21 without `0012` | 3290 / 3303 | | random number state from 3885, IWRAM from 4277 |

The P2-21 rows are P2-13's rows B and C, frame for frame; the stock rows are its "Stock" row and its unchanged recompiled build. With P2-21 the random number state equals mGBA's on all 4,400 frames on both backends. The 8 race frames of line state are the load (3293-3302, VRAM and palette written while the screen shows the backdrop), the 3 EWRAM frames 3295, 3297 and 3300. The recompiled build's extra front-end differences (87 IWRAM frames, 2185-2271, and the I/O writes) are the HALT write storm of an interpreter bridge running the BIOS IntrWait (diagnosis §1.5, P2-05), not timing; they are gone once IWRAM code is compiled (P2-10). As on `main`, the recompiled run does not stop at 4,400: its race loop runs in a bridge until the 200M-instruction cap at frame 5,127 (exit 134; `SELF-HEAL bridge for 0x03001CB0 exceeded 200000000 instructions`), on the stock build too (diagnosis §3.4).

**The instruction timeline of the hand-off** (`timeline.py`, mGBA's `--trace-pc 0x00000000-0x0FFFFFFF --trace-pc-cycles --step-frames 3286-3290` against the BIOS reference's clock probe from record 3285 to record 3291, `GBARECOMP_CYC_LO=922659584 GBARECOMP_CYC_HI=924344961`):

```
at 08159FD0 (mGBA clock 922676780): gbarecomp +0
at 08159FE0 (mGBA clock 923874894): gbarecomp +0
instructions: mGBA 187588 (187543 main-line, 1 IRQs), gbarecomp 266993 (266993 main-line, 0 IRQs, 0 idle ticks while halted); matched 187543
clock difference gbarecomp - mGBA at the last matched instruction: +0
  changed by instruction costs: +0; next to IRQs: +0 (0 changes); by skipped loop iterations: +0 (0)
```

On the stock build the same command printed +1815 and +219644 at the two watches and `instruction 08159FD8: +217829 over 54458 changes` (P2-13 §2). Every one of the 187,543 matched instructions now has mGBA's clock. (gbarecomp's probe runs past mGBA's last record, to record 3291, hence the unmatched instructions.)

**Frame 3885, IRQ entries** (mGBA's `--step-frames 3885` against the probe from record 3884 to 3885, `--line0 1090916290`): IRQ entries on VBlank lines cost 2 cycles in mGBA (58 of 60 measured) and in gbarecomp (60 of 61); on visible lines 30 in both (158 of 160), the HBlank DMA hiding the refill. The clock difference at the end of the frame is +5 cycles, as with prototype B (P2-13 §3: +5, against -138 with the prefetch reset alone).

## 4. `full_race_cross`

25,000 frames, BIOS reference.

| Build | Race image / display | Lap words (frames) | Race frames 3290-21788 (18,499): lines, EWRAM, IWRAM, I/O, FIFO A |
|---|---|---|---|
| mGBA | 3290 / 3303-21788 | 5444, 6108, 6110 | |
| stock (P2-13) | 3291 / 3304-21542 | 5200, 6110, 6106 | one frame apart throughout |
| P2-21 | 3290 / 3303-21788 | 5444, 6108, 6110 | 28, 3, 0, 0, 0 |

The random number state, the front-end counter and the lap words equal mGBA's on all 25,000 frames. The 28 frames of line state are the 8 of the load and 20 single lines where the HBlank handler's palette write lands on the other side of a line (P2-13 §4); EWRAM differs on 3295, 3297 and 3300. After the race, 4 frames of line state and one frame each of EWRAM (21797) and IWRAM (21794) differ. The IRQ stack region differs on 4 race frames (3293, 3303, 3304, 3306), on 894 of the front end's 3,289 frames and on 896 of the 3,212 after the race, as P2-13 measured with prototype B; P2-09 classifies stack differences. The stock row is P2-13's (not re-run here: its `boot_to_race` row above reproduces).

## 5. The cup

63,542 frames (`cup`), BIOS reference. Race images arrive at 3580, 26066 and 45966, and the races are displayed from 3593, 26079 and 45980, in both engines.

| Build | Race 1 laps | Race 2 laps | Race 3 laps | Points after races 1, 2, 3 (player, CP1-CP7) | Final standing |
|---|---|---|---|---|---|
| mGBA | 5784, 6139, 6106 | 5241, 5107, 5107 | 4470, 4260, 4376 | 1,3,2,5,4,8,6,7; 2,7,7,7,7,16,12,14; 3,9,12,11,10,22,20,21 | 7 (8th of 8) |
| P2-21 | the same | the same | 4470, 4260, 4254 | the same | the same |

The points and the cup record (`0x0203FC50`-`0x0203FC59`) equal mGBA's on every frame but 59742-59863, where race 3 ends 122 frames earlier in gbarecomp (display to 59722 instead of 59844) and its points are written earlier. The random number state differs from frame 18287 in race 1, 41445 in race 2 and 51426 in race 3, each time until the race ends: the draws that read VCOUNT within a few cycles of a line boundary, which P2-13 §5 traced to the IRQ and DMA latencies P2-21 does not copy. The final save (mGBA's SHA-1 `f6743468e8ecd41f21a5e3d58cdc83ab4c9e2128`, the route manifest's) differs in 8 bytes, `0x114`, `0x115`, `0x11C`, `0x11D`, `0x124`, `0x125` and the checksum `0xCC8`-`0xCC9`, the same as P2-13's prototype B. This is P2-13's row B, frame for frame. Exit criterion 3 on the cup (every frame and every race time equal) is still the owner's decision 4.

## 6. Comparison 1

`boot_to_race`, recompiled build against the BIOS reference of the same series, both 4,400 frames:

| Series | 1-3290: fb, lines, EWRAM, IWRAM, stacks, I/O, FIFO A, HALT writes | 3291-4400 |
|---|---|---|
| stock | 3 (2185, 2188-2189), 5 (294, 1864, 1873, 2188-2189), 3 (2185-2187), 87, 119, 43, 71, 43 | stacks on 3303 |
| P2-21 | 3 (2185, 2188-2189), 2 (2188-2189), 4 (294, 2185-2187), 87, 107, 42, 71, 42 | lines on 3294, stacks on 3303 |
| P2-21 without `0012` | 3 (2185, 2188-2189), 4 (1864, 1873, 2188-2189), 3 (2185-2187), 87, 117, 42, 71, 42 | fb and lines on 4315 |

The stock row reproduces P2-05's measurement exactly ([phase2-resume-roots.md](phase2-resume-roots.md) §3). The frame CRCs differ on the same three frames with P2-21, P2-05's recorded deviation (a HALT flag left set by the intro player's bridge). Two single-frame differences are new: EWRAM on frame 294 and the line state on 3294.

Both are few-cycle differences in when something is written relative to the VBlank-start record or to a line's rendering. On 3294 the full line records (`GBARECOMP_CAPTURE_LINES=294,3294`, `capture.py lines`) differ on one line, line 4, in its palette CRC only: a palette write of the race program's start-up lands on the other side of that line in the two backends. The record's clock (`cycles`) of the two backends differs around both frames: on 294 and 295 by -2 and +2 cycles with P2-21 (on `main`, by -2 on 295, with the line state differing on 294: P2-05 found that one on a build without IWRAM bridges too, and left it to P2-09), and on 3293 and 3294 by +2 and -1. The clocks are equal again on the next frame: the game's waits (IntrWait, the race loop's wait for VCOUNT 170) absorb them. Over the 4,400 frames, the record clocks differ on 371 frames on the stock build, 443 without `0012` and 709 with P2-21; on every series, each of those frames but 294 has instructions in an interpreter bridge in the recompiled run (P2-03's `bridge_insns` column; 294 has none). The self-heal bridge steps the bus directly, without the device catch-up and the DMA drain that generated code and the force-interp backend run around their I/O accesses (both go through the accessors of `runtime_bus_bridge.cpp`: `runtime_mmio_catch_up` before, `runtime_resync_horizon` after a write), so a DMA's stolen cycles can be charged at another instruction there. That `0012`'s condition, "DMA cycles charged in the same `runtime_tick`", then sees them in another tick inside bridges, which would explain the extra frames, is **likely**, not traced. Without bridges (P2-10's static build), generated code and the force-interp backend drain DMA at the same points (from the code; not measured). P2-10's gate on comparison 1 will show whether any of these remain.

## 7. What is left

- **IRQ and DMA latency** (owner decision 4, [phase2-race-lockstep.md](phase2-race-lockstep.md) §8 point 2): the cup's random number state still diverges in each race, and race 3's time differs. P2-21 copies neither mGBA's IRQ delay nor its DMA start delay.
- **Full races on the recompiled build** wait for P2-10: on `main`'s config the race loop runs in an interpreter bridge, which stops at the 200M-instruction cap at frame 5,127 with or without these patches. The recompiled build's race frames up to 4,400 equal the BIOS reference's but for one frame of line state (3294) and one of stacks (3303).
- **tools/bios_smoke**, gbarecomp's own interpreter oracle, keeps its own IRQ loop with no entry cycles; it gets the prefetch reset through `GbaBus`. Not changed here.
- **Multiplayer session execution** takes IRQs in `runtime_should_yield`, without entry cycles. Link play is out of Phase 2's scope.

## Reproducing

From the repository root, with `scripts/setup.sh` run, the harness built and `build/native` built (`scripts/build-native.sh`). P2-13's "Reproducing" section gives the capture and probe commands; with this series:

```sh
mkdir -p build/replays
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
scripts/repro-test.sh prefetch1 irqentry1
scripts/repro-test.sh --without 0011 --without 0012 --without arm-recomp-core/0001 --expect-failure prefetch1 irqentry1
```

`<native run, N frames>` is the command of [phase2-plan.md](../phase2-plan.md), "Commands used below". Runs take about 20 s for `boot_to_race`, 2.6 min for `full_race_cross` and 7 min for the cup on the BIOS reference; captures are 0.6 to 13 MB. Capture files and logs are derived from the ROM: keep them under `build/` or `analysis-out/`.

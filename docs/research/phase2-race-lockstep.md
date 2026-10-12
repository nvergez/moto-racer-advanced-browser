# Why races leave lockstep with mGBA

**Date:** 2026-10-11
**Scope:** P2-13 of [phase2-plan.md](../phase2-plan.md): why every gbarecomp backend leaves lockstep with mGBA from the race on ([phase2-diagnosis.md](phase2-diagnosis.md) §6), whether it can be fixed, and what it means for Phase 2's exit criterion 3. Also the plan's side questions: the BIOS translation on every race frame, how the game seeds its random numbers ([game-facts.md](game-facts.md) question 17), and the NULL-pointer BIOS read ([phase1-findings.md](phase1-findings.md) §6).
**Status:** Measured with P2-02's replays and P2-03's captures on gbarecomp's interpreter (and, for the hand-off, its recompiled build), against mGBA 0.10.5. The fixes below were tried in scratch copies of gbarecomp outside the repository; P2-21 turned prototypes B and C into patches of this repository ([phase2-timing-fixes.md](phase2-timing-fixes.md)). Nothing was checked on hardware.

## Pins

| | |
|---|---|
| ROM | Moto Racer Advance (Europe) `A9MP`, SHA-1 `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0` |
| BIOS | retail, SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492` |
| gbarecomp | `5e89943528aee7bc1c399bdbd035364a4b41dd10` with patches 0001-0006 (`main` at `f093eaa`), nested `external/arm-recomp-core` at `1f13cdfd3b437a7a3919285f381987bd43f5234a`. `file:line` citations are at these commits, before our patches (0003-0006 change some of the cited files, not the cited code) |
| Game config | `game.toml` of `main` at `f093eaa`: IWRAM code interpreted |
| mGBA | libmgba 0.10.5 (`26b7884`) through `tools/analysis/harness`; gbarecomp names mGBA `1d201b22` as the reference of its timing model, and the function cited from it below is the same there (read on GitHub) |
| Machine | Apple M4 Pro, macOS; native runs headless with `SDL_AUDIODRIVER=dummy`, `GBARECOMP_SELFHEAL_RECOMPILE=0` and a fresh save |

Frame numbers are harness frames. "Interpreter" is gbarecomp with `GBARECOMP_FORCE_INTERP=1`; "BIOS reference" adds `MRA_INTERP_BIOS=1` (P2-02), so that every instruction, the BIOS's included, is stepped by the interpreter. Unless stated otherwise the gbarecomp runs below are the BIOS reference with P2-02's replay (`MRA_REPLAY`), and both engines capture with `tools/capture/spec.txt`, the route fields of `routes.py trace-mem` and extra memory fields named where used. A clock is the master cycle counter of either engine (the capture's `cycles` column, which both engines keep on the same video timeline: [phase2-capture.md](phase2-capture.md) §1). Labels as in the diagnosis: **verified**, **likely**, **unverified**.

## Summary

- **The race starts one frame late in gbarecomp because its GamePak prefetch model never forgets what it prefetched when the CPU branches.** mGBA resets the prefetch position on every write to the PC (`lastPrefetchedPc = 0` in `GBASetActiveRegion`, which `ARMWritePC` calls); gbarecomp's port of the same function (`rwt_prefetch_stall`, which its comments call "exactly mGBA GBAMemoryStall") has no such reset. In a loop that runs from cartridge ROM and stores to RAM, gbarecomp then believes the opcodes after the loop are already in the buffer and gives the store fewer free fetches. The race program's start-up clears 54,459 words (217,836 bytes) of EWRAM with such a loop (`0x08159FD4`): 26 cycles per iteration in gbarecomp, 22 in mGBA, 217,829 cycles (0.78 frame) more over the loop's 54,460 iterations, so the race image arrives at frame 3291 instead of 3290 and every later input lands one game frame off. **Verified** (section 2).
- **A second, smaller difference makes the races drift apart even without the first: gbarecomp charges no cycles for entering an IRQ.** mGBA charges the pipeline refill at the vector (2 cycles), except when a DMA holds the CPU, which hides them. In races, where an HBlank IRQ comes every line, gbarecomp gains 2 cycles per line on the 68 lines of VBlank, about 136 cycles per frame. With only the first difference fixed, the race's random number generator, which adds VCOUNT to its state, reads one line earlier at frame 3885 of `boot_to_race` and the race diverges from there. **Verified** against mGBA; which engine matches hardware is **unverified** (section 3).
- **With both fixed (scratch prototypes), the races are in lockstep with mGBA.** `full_race_cross` gives mGBA's race (display 3303-21788, lap times 5444, 6108 and 6110 frames), with equal EWRAM and IWRAM hashes on every race frame but 3 during the load, the stack region's hash different on 4 frames as the race starts (3293, 3303, 3304, 3306), and equal per-line state on all but 28 of 18,499 race frames (8 during the load, 20 single lines). On the cup, all three races give mGBA's positions and points, races 1 and 2 its times; race 3's last lap is 122 frames shorter. On the unchanged gbarecomp, the first race is already one frame off and the player finishes 7th instead of 8th in race 3 (section 4).
- **What is left is IRQ and DMA latency, where mGBA's own model is empirical.** mGBA takes an IRQ 7 cycles after it is raised, an HBlank IRQ 13 (its source calls the extra 6 cycles a fudge factor of unknown origin), and starts a DMA 3 cycles after it is triggered; gbarecomp does both at once. Modelling both in the prototype too keeps the cup's first two races in lockstep (equal RNG state on every frame of both, equal RAM on all but one race frame), but race 3 still diverges at frame 51426, where mGBA's RNG draw reads VCOUNT on the first cycle of a line and gbarecomp's 2 cycles earlier. **Verified** for the measured frames (section 5).
- **Not the cause:** the BIOS translation (the BIOS reference and the plain interpreter give the same race results and random numbers on `full_race_cross`, section 7.1) and the NULL-pointer BIOS read (the same value, `0xE55EC002`, in both engines on all 771 reads of `boot_to_race`, section 7.2).
- **How the race draws random numbers** (game-facts question 17, for races): a 9-bit state in the word at `0x02000720`, seeded at race start from a front-end counter that advances once per frame in the menus, then `state = (state + VCOUNT + 1) & 0x1FF` at every draw, which returns entry `state` of a 512-halfword table in ROM at `0x083F5690`. A race therefore depends on how long the player spent in the menus and on the scanline of every draw (section 6).
- **Recommendation** (section 8): fix the first two differences in gbarecomp (a timing patch with synthetic repros). The interpreter's prefetch reset and the IRQ entry cost can be ordinary gbarecomp patches; only the reset in generated code needs a change in arm-recomp-core, which our patch tooling cannot carry yet (an owner decision), and the parts should land together. That removes the one-frame offset and makes `full_race_cross` and the cup's positions and points match. Exit criterion 3 as written (every frame and every race time of the cup equal to mGBA's) also needs gbarecomp to copy mGBA's IRQ and DMA latencies, including its unexplained offsets, and even then a cup can still diverge on a single cycle: whether to require that, or to revise the criterion, is the owner's decision. Event-anchored replays (P2-20) are not needed for this.

## 1. Method

Two kinds of measurement, both on the same route, replay and frame window in the two engines:

- **Per-frame captures** (P2-03): one record at each VBlank start, joined on the frame column. The extra memory fields used here: the race's RNG state `0x02000720:2`, the front-end counter `0x0203FCCC:2`, the lap words `0x0201A370`-`0x0201A37C` (frames per lap, **likely**: [open-bios-ab.md](open-bios-ab.md) §1) and the Cross Rookie record `0x0203FC50`-`0x0203FC59` ([phase2-routes.md](phase2-routes.md) §3).
- **Instruction timelines.** mGBA: the harness's `pctrace.tsv` with a new `--trace-pc-cycles` column, the clock before each instruction ([tools/analysis/README.md](../../tools/analysis/README.md)). gbarecomp: its existing clock probe, `GBARECOMP_CYC_LO`/`GBARECOMP_CYC_HI` (`src/runtime/runtime_bus_bridge.cpp:620-640`), which logs every advance of the clock in a window with the PC after it. [`tools/difftest/timeline.py`](../../tools/difftest/timeline.py) rebuilds gbarecomp's instruction stream from it, splits both streams into main-line code and IRQ handlers, matches the main-line instructions one to one and attributes every change in the clock difference to an instruction's cost, to an IRQ, or to a busy-wait loop that ran a different number of times. Its header gives the commands. A harness frame F runs from the VBlank start of record F-1 to that of record F, so the timeline of frames F to G is mGBA's `--step-frames F-G` against gbarecomp's probe from record F-1's clock to record G's. Each figure below names its window, and "Reproducing" gives the commands.

The fixes were tried in five scratch copies of the patched gbarecomp, built with this repository's `CMakeLists.txt` (`-DGBARECOMP_ROOT=<copy>`) and, for the recompiled build, a scratch `gba_recompile` run into a scratch generated directory. Nothing from them is committed. They are described precisely enough in sections 2-5 to redo.

| Prototype | Changes |
|---|---|
| A | the prefetch reset on every PC write, in the interpreter only (`Interpreter::step`, after a PC write). A variant written for the review of this document, A', resets it instead in gbarecomp's two callers of `Interpreter::step` when the step returns `Branched` or `ExceptionReturn`, with no arm-recomp-core change; its `boot_to_race` capture gives row A of section 4 exactly (section 8) |
| B | A, plus 2 cycles at IRQ entry unless a DMA's stolen cycles were charged in the same `runtime_tick` |
| C | B, plus the prefetch reset in generated code (after the refill of every static branch in `arm_codegen.cpp`, and in `runtime_refill_cycles`, which charges every other PC write), regenerated |
| D | B, plus mGBA's IRQ latency: an IRQ is taken 7 cycles after IE&IF becomes nonzero (13 for HBlank), and 7 cycles after a CPSR or IME change makes a pending IRQ eligible |
| E | D, plus a 3-cycle delay before a DMA's stolen cycles are charged |

## 2. Where the hand-off gains a frame

**The divergence starts at frame 3286** (`boot_to_race`, BIOS reference against mGBA). From the first input (2451) to 3285 the two engines have equal IWRAM hashes on every frame and equal EWRAM hashes on every frame but 2482, and the clocks of the records agree to within 15 cycles. Then:

| Frame | mGBA: image word, I/O writes | gbarecomp: image word, I/O writes |
|---|---|---|
| 3286-3289 | front end (`E92D4FF3`); 7, then 0 | the same; EWRAM differs from 3286 |
| 3290 | race program (`E3A00640`); 0 | front end; 0 |
| 3291 | race; DISPCNT 0 | race; DISPCNT 0 |
| 3293 | 485 I/O writes (the race program starts working) | 0 |
| 3294 | 1144 | 736 |
| 3303 | DISPCNT `0x1741` (race displayed) | DISPCNT 0; `0x1741` from 3304 |

There is no I/O write and no VBlank wait in frames 3287-3290: the CPU runs straight-line code from ROM. mGBA's `pctrace.tsv` for frames 3286-3290 shows what: the race program's start-up at `0x08159F64` (ARM, in ROM) copies the 456 words (`0x720` bytes) of `.data` to EWRAM (`0x08159FB0`-`0x08159FBC`), clears the 54,459 words (`0x352EC` bytes, `0x02000720`-`0x02035A0B`) of `.bss` (`0x08159FD4`-`0x08159FDC`), and only then copies the race image to IWRAM (`0x0815A000`-`0x0815A024`, from frame 3290 line 6 in mGBA). The sizes and the `.bss` start are the literals at `0x0815A064`, `0x0815A06C` and `0x0815A068`. Each loop runs one pass more than it stores: the last compare fails, and its conditional store does nothing (457 and 54,460 passes in mGBA's trace). The clear loop is three instructions:

```
08159FD4  cmp   r1, r2
08159FD8  strcc r3, [r1], #4      ; EWRAM
08159FDC  bcc   08159FD4
```

Its cost, from the instruction timelines (clock at `0x08159FD0`, before the loop, and at `0x08159FE0`, after it). The window is mGBA's frames 3286-3290 against gbarecomp's probe from record 3285 to record 3291: gbarecomp leaves the loop after record 3290, so a probe that stops there sees only 53,288 of the loop's 54,460 passes.

| | Before the loop | After it | Per iteration | `cmp` / `strcc` / `bcc` |
|---|---|---|---|---|
| mGBA | 922,676,780 | 923,874,894 | 22.0 | 4 / 4 / 14 |
| gbarecomp | 922,678,595 | 924,094,538 | 26.0 | 4 / 8 / 14 |

The per-instruction costs are those of consecutive clocks in each timeline. `timeline.py` attributes the difference to the stores: `instruction 08159FD8: +217829 over 54458 changes`, which is the difference of the two columns above (1,415,943 - 1,198,114). mGBA's `strcc` costs 4 cycles on all 54,460 passes. gbarecomp's costs 4 on the first, 5 on the second and 8 on the next 54,457, while the prefetch position settles, then 4 on the last pass, which does not store: 4 more on 54,457 stores and 1 more on one. The `.data` copy's store at `08159FB8` behaves the same way (`+1817 over 455 changes`), so gbarecomp is 1,815 cycles behind when the clear loop starts (`--watch 08159FD0`). The first store of the image copy (`0x0815A004`) runs 189,098 cycles before mGBA's record 3290 in mGBA and 30,546 cycles after it in gbarecomp. **Verified.**

**Why the store costs 4 more.** The game sets WAITCNT to enable the GamePak prefetch buffer. Both engines model the buffer the same way, with mGBA's `GBAMemoryStall`: while code runs from ROM, a data access outside ROM lets the buffer fetch up to 8 halfwords ahead, minus those it already holds (`lastPrefetchedPc - PC < 16`), and the fetched opcodes become free.

- mGBA 0.10.5 forgets the buffer's position on every PC write: `ARMWritePC` (`include/mgba/internal/arm/isa-inlines.h:73-81`), called by every branch, exception entry and return, calls `setActiveRegion`, and `GBASetActiveRegion` sets `memory->lastPrefetchedPc = 0` (`src/gba/memory.c:273`). So at each iteration the store finds an empty buffer, 5 halfwords are fetched during its 6-cycle EWRAM access, and it costs 4 cycles (`GBAMemoryStall`, `src/gba/memory.c:1736-1780`). mGBA `1d201b22` has the same reset in `GBASetActiveRegion` and the same `GBAMemoryStall`.
- gbarecomp ports `GBAMemoryStall` as `rwt_prefetch_stall` (`src/armv4t/runtime_wait_model.h:26-67`; `src/gba/gba_waitstates.h:47`: "Exactly mGBA GBAMemoryStall") and shares it between the interpreter and generated code, but nothing resets `last_prefetched_pc` except a machine reset (`src/gba/gba_waitstates.cpp:47`) and a state load. After the branch back, the position is still 14 bytes ahead of the store's PC, so 7 halfwords count as already fetched, only 1 more fits, and the store costs 8.

How real hardware treats the buffer on a branch is not described in GBATEK's prefetch section (**unverified**); keeping prefetched opcodes from after the loop across a branch to its start is not plausible, and in any case gbarecomp departs from the model it states it follows. This is a gbarecomp bug relative to its own reference.

The plan's hypothesis (the race program's CPU copy of its image at load) was close: it is the start-up code just before that copy.

**The same bug in the front end.** With prototype A, the front end of `boot_to_race` (frames 1-3289) also moves closer to mGBA: EWRAM hashes differ on 8 frames instead of 21, IWRAM on none instead of 1 (607), I/O-write counts on none instead of 2 (1393-1394), per-line state on 47 frames instead of 56. Seven of the timing-shaped frames of diagnosis §5.4 (294, 607, 1864, 1873, 2149, 2157, 2165) become equal.

## 3. The second difference: IRQ entry

With prototype A, the race image arrives at 3290 and the race is displayed from 3303, as in mGBA. Race frames then stay equal in IWRAM up to 4276, but the RNG state differs from frame 3885 on (`0x6F` in mGBA, `0x6E` in gbarecomp): the RNG routine at `0x03000000` read VCOUNT 205 in mGBA and 204 in gbarecomp.

The timeline of frame 3885 (prototype A; mGBA's frame 3885 against the probe from record 3884 to record 3885, with `--line0` at record 3884's clock) shows how gbarecomp got there early. The race's main loop waits for VCOUNT 170 at `0x03001CEC`-`0x03001CF8` and both engines leave the wait at the same clock (`0x03001CFC`, difference 0). The RNG is called at line 205; by then gbarecomp is 76 cycles ahead, and it keeps gaining 2 cycles at almost every IRQ of the VBlank lines, none on visible lines. The cost of every main-line instruction is the same in both engines; the difference is at IRQ entry. Overhead of an IRQ entry: the cycles between the start of the interrupted instruction and the vector, beyond that instruction's usual cost (`timeline.py --line0`):

| Lines | mGBA overhead | gbarecomp overhead | mGBA entry, cycle in line | gbarecomp entry |
|---|---|---|---|---|
| VBlank (160-227), 69 IRQs | 2 (58 of 60 measured) | 0 (59 of 61) | 1023 (and later, to the instruction boundary) | 1008 |
| Visible (0-159), 160 IRQs | 30 (158 of 160) | 30 (155 of 159) | 1041 | 1038 |

- mGBA: entering an IRQ calls `ARMWritePC` (`src/arm/arm.c:123-139`), 2 cycles at the zero-wait BIOS vector. On visible lines the HBlank DMA that rewrites the road's registers (DMA0) is still running when the IRQ is raised; while a DMA holds the CPU, mGBA's loop advances the CPU to the next event and the 2 cycles disappear in it (`src/gba/gba.c:300-339`, `cpuBlocked`).
- gbarecomp: `runtime_tick` takes the IRQ at the first instruction boundary after it is pending and charges nothing for the entry (`src/runtime/runtime_bus_bridge.cpp:774-806`; `runtime_irq`, `src/armv4t/runtime_arm.cpp:1436-1496`, sets PC to `0x18` without cycles). Only a wake from HALT adds 7 cycles (`kIrqWakeDelayCycles`, `src/gba/gba_irq.h:28`).

So gbarecomp gains 2 cycles per VBlank line, about 136 per frame, which the busy-wait at VCOUNT 170 resets every frame. Enough to move a VCOUNT read across a line boundary now and then. With prototype B the two engines enter VBlank-line IRQs with the same overhead, the clock difference at the RNG call of frame 3885 is +1 instead of -76, and at the end of the frame +5 instead of -138. The ARM7TDMI's real exception-entry cost was not checked against hardware or the processor's documentation here (**unverified**); mGBA's 2 cycles are its pipeline refill.

## 4. With both fixed

Captures against mGBA. "Stock" is the BIOS reference of `main`. Columns are per-frame hashes and counts (P2-03): a number is how many frames differ.

`boot_to_race`, 4,400 frames:

| Build | Race image / display | Front end 1-3289: lines, EWRAM, IWRAM, I/O writes | Race 3290-4400 (1,111 frames): lines, EWRAM, IWRAM, I/O writes, FIFO A |
|---|---|---|---|
| mGBA | 3290 / 3303 | | |
| Stock | 3291 / 3304 | 56, 21, 1, 2 | 1022, 1108, 1097, 459, 518 |
| A | 3290 / 3303 | 47, 8, 0, 0 | 503, 526, 124 (from 4277), 71, 122 |
| B | 3290 / 3303 | 44, 3, 0, 0 | 8, 3, 0, 0, 0 |
| C, recompiled build | 3290 / 3303 | 45, 7, 87, 42 | 8, 3, 0, 0, 0 |
| D | 3290 / 3303 | 44, 3, 0, 0 | 2, 0, 0, 0, 0 |

The RNG state is equal on all 4,400 frames with B and D. C is the recompiled build (generated code for ROM, IWRAM code in interpreter bridges, as on `main`); the unchanged recompiled build differs from mGBA on 57, 24, 88 and 45 front-end frames in the same columns, and in the race as stock does. Both recompiled builds differ from mGBA in `halt_writes` on frames 1396-1416, 2165-2185 and 2189, the HALT write storm of a bridge that runs the BIOS's IntrWait (diagnosis §1.5), and their IWRAM differences follow it (2185-2271); that is not timing, and it is gone once IWRAM code is compiled (P2-10). The recompiled build cannot run a race to its end on `main`'s config (diagnosis §3.4): both runs stop at the bridge's 200M-instruction cap at frame 5,127, so only 4,400 frames are compared. The `fb` column differs on most race frames in every build, from the renderer differences of diagnosis §5 (blend rounding, OBJ budget, semi-transparent OBJs): with equal per-line state, pixels differ only where the renderers do.

`full_race_cross`, 25,000 frames:

| Build | Race display | Lap words (frames) | Race frames 3290-21788 (18,499): lines, EWRAM, IWRAM, I/O, FIFO A |
|---|---|---|---|
| mGBA | 3303-21788 | 5444, 6108, 6110 (4'54"36) | |
| Stock | 3304-21542 | 5200, 6110, 6106 (4'50"26) | (one frame apart throughout) |
| B | 3303-21788 | 5444, 6108, 6110 | 28, 3, 0, 0, 0 |

With B, the 28 frames of per-line differences are 8 frames of the load (3293-3302: VRAM and palette written while the screen shows only the backdrop) and 20 single frames where one line's palette entry 0, which the HBlank handler writes, differs (for example frame 4406 line 41, 4572 line 56; `capture.py lines` on line records of both engines). EWRAM differs on 3 load frames (3295, 3297, 3300), IWRAM never; after the race, 4 frames of lines and one frame each of EWRAM and IWRAM differ. The tables leave out the hash of the stack region (`ram_iwram_stacks`, `0x03007000`-`0x03007FFF`): with B it differs from mGBA on 4 race frames, 3293, 3303, 3304 and 3306, the same 4 on `boot_to_race` and `full_race_cross`. It also differs on 894 of the 3,289 front-end frames of both routes, and on 896 of the 3,212 frames after the race of `full_race_cross`. P2-09 classifies stack differences (section 8).

The cup (`cup`, 63,542 frames: Cross Rookie, three races):

| Build | Race 1 laps | Race 2 laps | Race 3 laps | Points per race (player, CP1-CP7) | RNG state differs from |
|---|---|---|---|---|---|
| mGBA | 5784, 6139, 6106 | 5241, 5107, 5107 | 4470, 4260, 4376 | 1,3,2,5,4,8,6,7; 1,4,5,2,3,8,6,7; 1,2,5,4,3,6,8,7 | |
| Stock | the same | the same | 4301, 4260, 4254 | 1,3,5,2,4,6,7,8; 1,4,5,2,3,7,8,6; 2,5,4,3,1,8,6,7 | 3583 (race 1 starts a frame late) |
| B | the same | the same | 4470, 4260, 4254 | as mGBA | 18287 (race 1), 41445 (race 2), 51426 (race 3) |
| D | the same | the same | 4470, 4260, 4254 | as mGBA | 51426 (race 3) |
| E | the same | the same | 4470, 4260, 4254 | as mGBA | 51426 (race 3) |

Stock gbarecomp, one frame off from the start of each race, still gives the player mGBA's times in races 1 and 2 (open-loop inputs that hold A make the player's own laps insensitive to the rivals), but the rivals finish in another order in all three races and the player is 7th in race 3 (2 points instead of 1), so the cup totals differ; its final save differs from mGBA's (`f6743468…`) in 19 bytes. With B, D or E every rider's points in every race are mGBA's, and so is the final record (`0x0203FC50`-`0x0203FC59`); race 3's last lap is 122 frames (2.03 s) shorter. Their final save differs from mGBA's in 8 bytes, `0x114`-`0x125` (six) and the checksum at `0xCC8`-`0xCC9`: the same bytes, and the same race 3 lap times, as the Cult-of-GBA BIOS run from the cartridge entry ([open-bios-ab.md](open-bios-ab.md) §4). The same race, perturbed by a few cycles another way, takes the same other branch.

## 5. What remains: IRQ and DMA latency

With B, the races of the cup still diverge (frames 18287, 41445, 51426), each time at an RNG draw whose VCOUNT read falls within a few cycles of a line boundary. At 18287 mGBA's draw loads VCOUNT 1 cycle after line 210 starts and gbarecomp's 2 cycles earlier, before it (instruction timelines of that frame on `cup`, prototype B: mGBA's frame 18287 against the probe from record 18286 to record 18287). The remaining differences are in how soon an IRQ or a DMA follows its trigger:

- **IRQ latency.** mGBA takes an IRQ when an event fires `GBA_IRQ_DELAY` = 7 cycles after IE&IF becomes nonzero (`src/gba/gba.c:27`, `GBATestIRQ` at `:560-566`, `_triggerIRQ` at `:950`), and re-tests a pending IRQ the same way when the CPSR or IE/IF/IME change. The HBlank IRQ is raised with `cyclesLate - 6`, so it comes 13 cycles after HBlank starts; the source says "TODO: Where does this fudge factor come from?" (`src/gba/video.c:215`). gbarecomp takes it at the first instruction boundary (section 3), 13-15 cycles earlier on VBlank lines. On its own this moves no instruction's clock (the main line does the same work before or after the handler), but it decides which instruction is interrupted and when the handler writes its registers: the 20 single-line palette differences of section 4 are the HBlank handler's palette write landing on the other side of a line's rendering (**likely**: with mGBA's IRQ latency added, prototype D, race 1 of the cup has per-line differences on 9 frames instead of B's 17, and with the DMA start too, prototype E, on 3).
- **DMA start.** mGBA starts a DMA 3 cycles after its trigger ("DMAs take 3 cycles to start", `src/gba/dma.c:115`; HBlank and VBlank DMA likewise, `:147-179`); gbarecomp charges a DMA's stolen cycles at once (`drain_dma_steal`, `src/runtime/runtime_bus_bridge.cpp:669-687`). With D, the visible-line IRQs enter at cycle 1038 of the line in gbarecomp and 1041 in mGBA, and at frame 51426 gbarecomp leaves the VCOUNT 170 wait 3 cycles early and reads VCOUNT at the RNG draw 3 cycles early, on the other side of the line boundary that mGBA's read hits on its first cycle.
- **Sound FIFO DMA.** In both engines a FIFO is refilled when fewer than 4 words are left at a sample (mGBA `GBAAudioSampleFIFO`, `src/gba/audio.c:343`; gbarecomp `fifo_needs_dma`, `src/gba/gba_audio.cpp:603-606`). Yet the race timelines show a pair of clock-difference changes, +10 then -10 cycles four lines later, repeating every 12 lines: the period at which FIFO A (timer 0 reload `0xFC64`, 924 cycles per sample, 18,157 Hz; the harness's `io.json` at frame 4200) consumes 4 words. Most likely the refill DMA is charged some lines apart in the two engines (**unverified**). The FIFO bytes per frame are equal, so only the order of events within the frame differs.

Prototype D (mGBA's IRQ latency) keeps races 1 and 2 of the cup in lockstep: equal RNG state on every frame of both races, equal IWRAM and FIFO bytes on every race frame, and equal EWRAM and I/O-write counts on every race frame but 15452, a frame [open-bios-ab.md](open-bios-ab.md) §5 found sensitive the same way between BIOS images. Race 3 diverges at 51426: mGBA's draw loads VCOUNT on the first cycle of line 219, gbarecomp's 3 cycles earlier; it left the VCOUNT 170 wait 3 cycles early in that frame (timelines of D and E: mGBA's frame 51426 against the probe from record 51425 to record 51426). Prototype E (the 3-cycle DMA start on top) moves the visible-line IRQ entries to mGBA's cycle (1041), and the cup's per-race results and RNG divergence are the same as D's: at 51426 gbarecomp still reads 2 cycles early. The timeline of that frame still shows the FIFO refill pairs, and gbarecomp is already 2 cycles early when it leaves the VCOUNT 170 wait.

These are model details where mGBA's values are partly empirical (the fudge factor) and none was checked on hardware. gbarecomp can copy them; it cannot be shown that the copy matches hardware, and as long as any cycle differs, a VCOUNT-fed RNG draw at a line boundary can still flip. The cup draws the RNG 942 times in mGBA (`--watch-write 0x02000720-0x02000723`: 479 from the call at `0x03003180`, 361 from `0x08161B3F`, 61 from `0x0815D598`, 20 from `0x030031B8`, and the start-up draws of each race).

## 6. The race's random numbers (game-facts question 17)

**Verified** on `boot_to_race` in mGBA (harness `--watch-write 0x02000720-0x02000723,0x0203FCCC-0x0203FCCF`, `--watch-read` on the same, `--trace-pc 0x03000000-0x0300007F --trace-pc-regs`), and the routine's instruction words read from the ROM:

- **Draw.** The race image's routine at `0x03000000` (ROM source `0x083F6820`, Phase 1 §4) loads VCOUNT and the word at `0x02000720` (the first word of the race program's `.bss`, section 2), adds them plus one, keeps the low 9 bits (`lsl #23` then `lsr #23`: `E1A00B80` at `0x03000018` and `E1A00BA0` at `0x0300001C`), stores the result back and returns the halfword at ROM `0x083F5690 + 2 × state`, so the table has 512 entries (the literals at `0x03000198` and `0x0300019C` hold `0x02000720` and `0x083F5690`). That is `state = (state + VCOUNT + 1) & 0x1FF`. mGBA's writes agree: at frame 3293 line 40 the first draw takes the state from `0x2E8` to `0x111` (with `& 0x3FF` it would be `0x311`) and the seventh from `0x1DE` to `0x007`; at frame 3885 line 205 it goes from `0x1A1` to `0x06F` (section 3; `0x26F` with `& 0x3FF`). P2-17 found the routine ([open-bios-ab.md](open-bios-ab.md) §5).
- **Seed.** The race program's start-up clears the state with the rest of its `.bss` (`0x08159FD8`, frame 3286). At race start (frame 3293 line 39) Thumb code at `0x0815B0C0` reads the 32-bit word at `0x0203FCCC` (`0x2E8` on `boot_to_race`) and `0x0815B0C6` stores it as the state, unmasked; seven draws follow at once, the first of which masks it.
- **The seed source.** `0x0203FCCC` is offset `0xCCC` of the save block the front end keeps in RAM ([phase2-routes.md](phase2-routes.md) §3). Front-end code increments it in the menus: 744 writes on `boot_to_race` from the instructions at `0x0800574C`, `0x08006174`, `0x0800736C` and `0x08007F2C`, the last at frame 3255, once per frame on the frames sampled (on 3201-3210 it goes from `0x2B1` to `0x2BA`). [open-bios-ab.md](open-bios-ab.md) §5 saw it advance twice in one frame under one BIOS image and once under the other, which changed a whole race. It is part of the save, so it also carries over between sessions. Whether the front end has other random sources was not checked.
- **During the race** the RNG is drawn in bursts of one draw every 16 frames from the call at `0x03003180`, near VCOUNT 204, and from other callers (`0x08161B3F`, `0x0815D598`, `0x030031B8`); 942 draws over the cup (section 5).

So a race is a function of the menu frame count before it and of the scanline at each draw. Given the same inputs from the same state, mGBA plays it identically (the harness is deterministic); another engine plays it identically only if every draw reads the same VCOUNT, that is, if its CPU, IRQ and DMA timing agree to within the distance of each draw from a line boundary.

## 7. Other checks from the plan

### 7.1 The BIOS translation on every race frame

The BIOS reference against the plain interpreter, whose SWIs run the recompiled BIOS (diagnosis §7.1), both unchanged (`capture.py join`):

- `boot_to_race`, 4,400 frames: equal in every column on every frame, except `ram_iwram_stacks` on frame 3303 (as P2-02 found).
- `full_race_cross`, 25,000 frames: the same race (display 3304-21542, the same lap words) and the same RNG state on every frame. `fb` differs on 2 frames (9692, 16306), the line state on 4 (9692, 16306, 21562-21563), EWRAM on 3 at the end of the race (21551, 21555, 21566), the stacks on 25; the clocks at the records differ by -10 to +4 cycles on 493 race frames. The cause of these small differences between running a SWI's BIOS routine within one interpreter step and stepping it is **unverified**; P2-09 decides how comparison 1 treats them.

So the BIOS translation is not why races leave lockstep with mGBA.

### 7.2 The NULL-pointer BIOS read

On `boot_to_race` mGBA logs 771 reads of each of the bytes `0x0`-`0x3` by the race code at `0x03001458`-`0x03001464` (frames 3302-4400, `--log-bios-reads`), always `02 C0 5E E5`, the word `0xE55EC002`. A scratch probe in gbarecomp's BIOS-region read (prototype C's interpreter build, which follows mGBA's race frame for frame) logs the same 771 reads of each byte with the same values. **Verified** on that build; the unchanged build takes the value from the same open-bus latch (`GbaBus::read8`, `src/gba/gba_bus.cpp:213-220` at the pin), so its value should not differ (**likely**).

### 7.3 The I/O-write drift

The plan suggested matching I/O writes between `writes.tsv` and `GBARECOMP_MMIO_DUMP`. The instruction timelines locate the gain directly, to the instruction, so the I/O drift was only used as a per-frame count (`io_writes`, section 2); the +228-line median drift the diagnosis measured in races is the one-frame offset.

## 8. Recommendation and decisions

1. **Fix the prefetch reset and the IRQ entry cost in gbarecomp**, as one timing patch with synthetic repros (follow-up task below). Both are departures from mGBA, which gbarecomp names as its reference, and the first is a departure from gbarecomp's own documented model. Together they remove the one-frame offset at every race start and give mGBA's results on `full_race_cross` and mGBA's positions and points on the cup. Without them, criterion 3 fails from the first frame of every race measured (`boot_to_race`, `full_race_cross` and the cup's three races all start one frame late).
   - **The prefetch reset in the interpreter can be an ordinary gbarecomp patch.** gbarecomp calls `Interpreter::step` from two places of its own, the bridge (`src/runtime/runtime_arm_default_aborts.cpp:556`) and the force-interp step (`:803`), and both get the step's `Result`, which is `Branched` after any PC write that is not an exception return (`external/arm-recomp-core/profiles/armv4t_gba/interpreter.cpp:1214-1231`). Resetting `g_runtime_waits.last_prefetched_pc` there, when the step returns `Branched` or `ExceptionReturn`, is the same as resetting it at the PC write: only the buffer stall reads or writes the position (`rwt_prefetch_stall`, `src/armv4t/runtime_wait_model.h:44`, `:58`), and the refill's fetch waits do not. Prototype A' does this and gives row A of section 4 exactly: its `boot_to_race` capture against mGBA's differs on 47, 8, 0 and 0 front-end frames and on 503, 526, 124 (from 4277), 71 and 122 race frames, with the RNG state different from frame 3885 (its B' variant, with the IRQ entry cost, gives row B exactly). No `Bus` or `GbaBus` method is needed.
   - **So can the reset for generated code that writes the PC at run time**, which calls gbarecomp's own `runtime_refill_cycles` (`src/armv4t/runtime_wait_inline.h:22`, emitted by `dynamic_refill_stmt`, `arm_codegen.cpp:227-233`), **and the IRQ entry cost** (`runtime_tick`, `src/runtime/runtime_bus_bridge.cpp:774-806`, before `runtime_irq`).
   - **Only the reset after a static branch needs arm-recomp-core.** Code generation inlines the refill of every direct branch (`arm_codegen.cpp:461`, `static_refill_expr`) as reads of `g_runtime_waits` (`fetch_wait_expr`, `:168-179`) and calls no function that gbarecomp could change. arm-recomp-core is a nested submodule, and `scripts/apply-patches.sh` refuses any change in it (patches/gbarecomp/README.md, "How the series is applied"). **Owner decision** (decision 9 of [phase2-plan.md](../phase2-plan.md)): how to carry that change: extend the patch tooling with a series for the nested submodule, or another way.
   - The parts should land together. With the interpreter's reset alone, the interpreter would charge ROM loops like the one of section 2 differently from generated code, whose static branches would still keep the position (by construction; not measured), and comparison 1 between the interpreter and the recompiled build would lose its parity.
2. **Exit criterion 3 on the cup is an owner decision.** With the two fixes of point 1, a cup can still diverge because of IRQ and DMA latency (section 5), where mGBA's model is partly empirical and neither engine is known to match hardware. Options:
   - (a) also copy mGBA's IRQ delay (7 cycles, 13 for HBlank), its 3-cycle DMA start and whatever orders its FIFO DMA, and re-measure the cup; this ties gbarecomp to mGBA's quirks rather than to hardware, and a single-cycle difference anywhere can still flip a draw;
   - (b) revise criterion 3 for races: equal positions and points and every frame equal up to the first RNG draw that reads another VCOUNT, with that frame and the rest of the race allowlisted with this document as the cause, and race times within a stated tolerance ([open-bios-ab.md](open-bios-ab.md) §4: in mGBA alone, another BIOS image moved a lap by up to 2.8 s and a race by up to 4.9 s);
   - (c) for testing only, feed the RNG draws the VCOUNT values of the mGBA run (a test hook on the routine at `0x03000000`), so that comparison 2 can stay exact over whole races; this checks everything else frame for frame, but changes the game in the test build.
3. **P2-20 is not triggered by this task.** The offset at race start is a timing bug, not something replays can anchor away, and with the fix the races start on mGBA's frames.

### Follow-ups

- **Done in P2-21** ([phase2-timing-fixes.md](phase2-timing-fixes.md)): patches `0011` and `0012`, and `0001` of a new series for arm-recomp-core (`patches/arm-recomp-core/`, which the patch tooling now carries: decision 9), with the synthetic repros `prefetch1` and `irqentry1`. Its results on `boot_to_race`, `full_race_cross` and the cup reproduce rows B and C of section 4. The proposal as written for it: **New task (proposed P2-21): timing patch.** The prefetch reset on every PC write and the 2-cycle IRQ entry hidden by a running DMA. All of it can be ordinary gbarecomp patches (the reset at the two `Interpreter::step` call sites and in `runtime_refill_cycles`, the entry cost in `runtime_tick`) except the reset after the static-branch refill in `arm_codegen.cpp`, which needs tooling for the nested submodule (point 1). Synthetic repro ROMs (no Nintendo data): a ROM loop `cmp; strcc [EWRAM]; bcc` with WAITCNT `0x4317`, timed with a timer (mGBA 22 cycles per iteration, the pin 26), and an IRQ-entry timing check with no DMA running. gbarecomp's `codegen_tests` already compare codegen and interpreter prefetch positions (docs/CPU_TIMING.md in gbarecomp) and should cover the reset; `timing_mgba_differential` needs an mGBA executable and is optional. Acceptance: P2-13's (`boot_to_race` race frames 3290-4400 and `full_race_cross` as in section 4, recompiled build too once P2-10 lands), and comparison 1 unchanged between the interpreter and the recompiled build. Depends on the owner decision of point 1.
- **If the owner picks option (a):** IRQ and DMA latency patches on top, measured on the cup.
- **P2-09:** classify the BIOS-reference against plain-interpreter differences of section 7.1, and expect `ram_iwram_stacks` to differ against mGBA wherever IRQ latency differs (with B: race frames 3293, 3303, 3304 and 3306, section 4).
- **P2-15:** the FIFO A refill DMA appears to land a few lines apart in the two engines (section 5, **unverified**) while per-frame FIFO bytes are equal.
- **Upstream candidates** for the owner (nothing filed), added to [phase2-diagnosis.md](phase2-diagnosis.md) §9: U19, gbarecomp's prefetch model never resets on a PC write (repro: the loop above); U20, no cycles for IRQ entry.

## Reproducing

From the repository root, with the harness built and `build/native` built (`scripts/build-native.sh`). The commands below give the per-frame comparison of section 4 and the instruction timeline of section 2:

```sh
mkdir -p build/replays build/cap
python3 -I tools/replay/script2replay.py --route boot_to_race -o build/replays/boot_to_race.csv
MEM="$(python3 -I tools/difftest/routes.py trace-mem),0x02000720:2,0x0203FCCC:2,0x0201A370:4,0x0201A374:4,0x0201A378:4,0x0201A37C:4"

# mGBA: per-frame records, and the instruction timeline of frames 3286-3290
tools/analysis/harness/run_harness.sh --out runs/b2r --script tools/analysis/input/boot_to_race.txt --frames 4400 \
  --capture --capture-spec tools/capture/spec.txt --capture-mem "$MEM"
tools/analysis/harness/run_harness.sh --out runs/b2r-f3286 --script tools/analysis/input/boot_to_race.txt --frames 3291 \
  --trace-pc 0x00000000-0x0FFFFFFF --trace-pc-cycles --step-frames 3286-3290

# gbarecomp, BIOS reference: per-frame records, then the clock probe over the same window.
# LO and HI: the cycles column of records 3285 and 3291 of build/cap/b2r.tsv
# (922659584 and 924344961 for the stock build).
(cd build/native && export GBARECOMP_FORCE_INTERP=1 MRA_INTERP_BIOS=1 MRA_REPLAY=../replays/boot_to_race.csv \
   GBARECOMP_CAPTURE=../cap/b2r.tsv GBARECOMP_CAPTURE_SPEC=@../../tools/capture/spec.txt GBARECOMP_CAPTURE_MEM="$MEM" &&
 <native run, 4400 frames>)
(cd build/native && export GBARECOMP_FORCE_INTERP=1 MRA_INTERP_BIOS=1 MRA_REPLAY=../replays/boot_to_race.csv \
   GBARECOMP_CYC_LO=<LO> GBARECOMP_CYC_HI=<HI> && <native run, 3292 frames> 2> ../cap/cyc3285-3291.log)

python3 -I tools/capture/capture.py join analysis-out/runs/b2r/capture.tsv build/cap/b2r.tsv
python3 -I tools/difftest/timeline.py analysis-out/runs/b2r-f3286/pctrace.tsv build/cap/cyc3285-3291.log \
  --watch 08159FD0,08159FE0
```

On the stock build the last command prints `at 08159FD0 (mGBA clock 922676780): gbarecomp +1815`, `at 08159FE0 (mGBA clock 923874894): gbarecomp +219644`, `instruction 08159FD8: +217829 over 54458 changes` and `instruction 08159FB8: +1817 over 455 changes`.

The windows behind the other timelines follow the same pattern (section 1: harness frame F lies between records F-1 and F). LO and HI come from the capture of the build being probed, and `--line0` is LO:

| Figures | Route, build | mGBA `--step-frames` (`--frames`) | gbarecomp probe, records LO to HI (frames run) |
|---|---|---|---|
| Section 2, the hand-off | `boot_to_race`, stock | 3286-3290 (3291) | 3285 to 3291 (3292) |
| Section 3, frame 3885 | `boot_to_race`, A and B | 3885 (3886) | 3884 to 3885 (3886) |
| Section 5, frame 18287 | `cup`, B | 18287 (18288) | 18286 to 18287 (18288) |
| Section 5, frame 51426 | `cup`, D and E | 51426 (51427) | 51425 to 51426 (51427) |

`<native run, N frames>` is the command of [phase2-plan.md](../phase2-plan.md), "Commands used below". The probe wrote 18 MB for the six records of section 2 and 11 MB for frame 3885 of the stock build; keep windows to a few frames. Runs take about 19 s for `boot_to_race`, 2.5 min for `full_race_cross` and 7 min for the cup on the interpreter. Capture files and logs are derived from the ROM: keep them under `build/` or `analysis-out/`.

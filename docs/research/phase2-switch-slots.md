# armcc switch-table case slots

**Date:** 2026-10-11
**Scope:** P2-06 of [phase2-plan.md](../phase2-plan.md): the scanner for armcc switch tables in ARM code (`tools/seeds/find_switch_tables.py`), the 239 case slots of the 16 tables in ROM code as reviewed `game.toml` entries, and what the build does with them.
**Status:** Static reading of the ROM (the scanner, cross-checked with `llvm-objdump`), mGBA coverage on ten routes, and native gbarecomp runs. IWRAM code is still interpreted on this build (P2-10 compiles it).

## Pins

| | |
|---|---|
| ROM | Moto Racer Advance (Europe) `A9MP`, SHA-1 `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0` |
| BIOS | retail, SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492` |
| gbarecomp | `5e89943528aee7bc1c399bdbd035364a4b41dd10` with patches 0001-0006 (`main` at `dd12c69`); `file:line` citations are at the pin |
| Game config | "base" is `main`'s `game.toml` (P2-05's config), "new" is this branch's: base plus the 239 entries |
| mGBA | libmgba 0.10.5 through `tools/analysis/harness` |
| Tools | Python 3.11.6; Apple LLVM 21.0.0 `llvm-objdump` |
| Machine | Apple M4 Pro, macOS; native runs headless with `SDL_AUDIODRIVER=dummy`, `GBARECOMP_SELFHEAL_RECOMPILE=0` and a fresh save |

Native runs are the plan's ("Commands used below"), each from its own working directory, with P2-03's capture (`tools/capture/spec.txt` and the route fields of `routes.py trace-mem`) and, for `boot_to_race`, P2-02's replay (`MRA_REPLAY`, from `script2replay.py tools/analysis/input/boot_to_race.txt`), as in [phase2-resume-roots.md](phase2-resume-roots.md). Missed PCs come from the exit report (`bridged 0x... (mode) xN`), or, for runs that abort, from `GBARECOMP_SELFHEAL_VERBOSE=1` (each missed PC once). mGBA coverage is `tools/analysis/harness/run_harness.sh --out DIR --script tools/analysis/input/ROUTE.txt --frames N --coverage`, N the route's frame count in `tools/difftest/routes.toml`. Capture files, logs, coverage files and disassembly stayed in a scratch directory.

## 1. The pattern

armcc compiles a dense `switch` in ARM code as a computed jump into a table of branches:

```
cmp   rM, #N                  the bound
addls pc, pc, rM, lsl #2      the dispatcher, at D
b     default                 D + 4, taken when rM > N
b     case_0                  D + 8
...
b     case_N                  D + 8 + 4 * N
```

gbarecomp's finder treats the `addls` as an indirect branch it cannot resolve: its PC-write evaluator accepts only an unshifted register whose value it knows (`src/recompile/function_finder.cpp:1030-1039`). Its automatic table detection reads data words only (`emit_jump_table` returns unless the stride is 4 and the table abs32, `:905-908`), and `[[jump_table]]`'s four formats (`abs32`, `abs16`, `pcrel_thumb`, `pcrel_arm`, `docs/TOML_SCHEMA.md`) all read data words too, not `b` instructions. So each case slot needs an `[[extra_func]]` (diagnosis §2.2; upstream candidate U11). The default slot does not: for a conditional indirect branch the finder roots the fall-through (`function_finder.cpp:1814-1820`).

## 2. The scanner

`tools/seeds/find_switch_tables.py` ([README](../../tools/seeds/README.md); the checks are listed at its top) takes every 4-byte aligned word of the ROM that encodes `add<cond> pc, pc, rM, lsl #2`, walks back to the `cmp rM, #imm` that bounds it, and keeps the table only if the default slot and every case slot is an unconditional `b` into the same region. Between the `cmp` and the dispatcher it allows at most 15 unconditional instructions that write neither `rM` nor the flags and do not branch. It classifies tables by region, with the four code copies of [phase1-findings.md](phase1-findings.md) section 4 built in for this ROM, and reports, without rejecting, any `b` or `bl` in the ROM that lands between a `cmp` and its dispatcher, and any `b` right after a table's last slot. Its unit tests (`tools/seeds/tests`, run in CI) use hand-encoded ARM words only.

`python3 -I tools/seeds/find_switch_tables.py roms/moto-racer-advance.gba` finds 20 dispatchers, all `addls`, none rejected and none flagged for review: Phase 1's count of `addls pc` switches ([phase1-findings.md](phase1-findings.md) section 3) and the diagnosis's 16 tables with 239 slots in ROM code plus 4 in the race image (§2.2).

| Dispatcher | Program | `cmp` | Cases | Case slots | Default target | Distinct case targets |
|---|---|---|---|---|---|---|
| `0x080003FC` | front end | `r1, 13` at `0x080003F4` | 14 | `0x08000404`-`0x08000438` | `0x08000564` | 14 |
| `0x08002DA0` | front end | `r14, 12` at `0x08002D9C` | 13 | `0x08002DA8`-`0x08002DD8` | `0x08002E80` | 9 |
| `0x08002F4C` | front end | `r1, 12` at `0x08002F48` | 13 | `0x08002F54`-`0x08002F84` | `0x080031AC` | 9 |
| `0x08003EDC` | front end | `r0, 4` at `0x08003ED8` | 5 | `0x08003EE4`-`0x08003EF4` | `0x08003F18` | 5 |
| `0x08008308` | front end | `r12, 5` at `0x08008304` | 6 | `0x08008310`-`0x08008324` | `0x080085D8` | 6 |
| `0x080090D8` | front end | `r0, 5` at `0x080090D4` | 6 | `0x080090E0`-`0x080090F4` | `0x08009374` | 6 |
| `0x0800BFCC` | front end | `r4, 18` at `0x0800BFB4` | 19 | `0x0800BFD4`-`0x0800C01C` | `0x0800C1A4` | 13 |
| `0x0800C318` | front end | `r6, 11` at `0x0800C2F8` | 12 | `0x0800C320`-`0x0800C34C` | `0x0800C3F0` | 10 |
| `0x08010200` | front end | `r0, 12` at `0x080101FC` | 13 | `0x08010208`-`0x08010238` | `0x08010468` | 11 |
| `0x08010590` | front end | `r1, 21` at `0x0801058C` | 22 | `0x08010598`-`0x080105EC` | `0x08010888` | 20 |
| `0x08011B90` | front end | `r2, 31` at `0x08011B8C` | 32 | `0x08011B98`-`0x08011C14` | `0x08011C28` | 13 |
| `0x08011D14` | front end | `r2, 14` at `0x08011D10` | 15 | `0x08011D1C`-`0x08011D54` | `0x08011C28` | 5 |
| `0x08012458` | front end | `r0, 10` at `0x08012454` | 11 | `0x08012460`-`0x08012488` | `0x08012644` | 10 |
| `0x081603E0` | race, ROM code | `r0, 10` at `0x081603DC` | 11 | `0x081603E8`-`0x08160410` | `0x08160678` | 10 |
| `0x08163338` | race, ROM code | `r0, 31` at `0x08163334` | 32 | `0x08163340`-`0x081633BC` | `0x081635E8` | 13 |
| `0x081634DC` | race, ROM code | `r1, 14` at `0x081634D8` | 15 | `0x081634E4`-`0x0816351C` | `0x081635E8` | 5 |
| `0x083F81A4` | race IWRAM image, runs at `0x03001984` | `r0, 9` at `0x083F81A0` | 10 | `0x083F81AC`-`0x083F81D0` | `0x083F81D4` | 1 |
| `0x083F83DC` | race IWRAM image, `0x03001BBC` | `r0, 5` at `0x083F83D8` | 6 | `0x083F83E4`-`0x083F83F8` | `0x083F8434` | 5 |
| `0x083F8460` | race IWRAM image, `0x03001C40` | `r0, 9` at `0x083F845C` | 10 | `0x083F8468`-`0x083F848C` | `0x083F8490` | 1 |
| `0x083FA698` | race IWRAM image, `0x03003E78` | `r0, 7` at `0x083FA694` | 8 | `0x083FA6A0`-`0x083FA6BC` | `0x083FA778` | 8 |

"Front end" is `0x08000100`-`0x08159F2F`, "race, ROM code" the race program from `0x08159F30` outside its IWRAM image, and the race IWRAM image is ROM `0x083F6820`-`0x083FB1E3`, copied to `0x03000000` (Phase 1 §3 and §4). The 16 tables in ROM code have 239 case slots; the 4 in the race image have 34, given here at their ROM addresses with the runtime address of the dispatcher (runtime = `0x03000000` + ROM - `0x083F6820`). Two of those, at `0x03001984` and `0x03001C40`, branch from every slot to the instruction right after the table: switches whose cases are all empty.

The `cmp` is right before the dispatcher in 17 tables. In the other three it is earlier, inside the function's prologue: 2 instructions before at `0x080003FC` (with `ldr r0, [r4, #0xC]` between), 6 at `0x0800BFCC` and 8 at `0x0800C318` (moves and loads of other registers). These are the cases where a scanner that requires the `cmp` to be adjacent would leave the table unsized; the runtime-bugs prototype the scanner is ported from searched up to 40 instructions back for any `cmp rM, #imm` without checking what lies between.

## 3. Review of the tables

**Against an independent disassembler.** For each of the 20 tables, the bytes from the `cmp` to one word past the last slot were disassembled with `llvm-objdump --triple=armv4t-none-eabi` and compared with the scanner's result: the `cmp` register and immediate, the `addls pc, pc, rM, lsl #2` line, the instructions in between (none branches, writes PC, sets flags or writes `rM`), that the default slot and every case slot disassembles as `b` (not `bl`, not conditional), and that their targets equal the scanner's. All 20 agree. The word after the last slot is not a `b` in any table, so no bound is visibly one too small. In 18 tables that word is a case target; in the other two (`0x08002DA0`, `0x08002F4C`) it is the target of the `bgt` a few instructions before the `cmp` (at `0x08002D94` and `0x08002F40`), the other branch of the comparison that leads to the table. No word of the ROM that encodes a `b` or `bl` targets an instruction between a `cmp` and its dispatcher.

**Against the prototype.** The runtime-bugs prototype's configuration (`configs/c2.toml` of the diagnosis's scratch directory) has 239 `[[extra_func]]` case slots for the same 16 dispatchers with the same case counts; the diagnosis measured that configuration (§2.2).

**What mGBA executes.** mGBA coverage on every route of the manifest that starts from a fresh save (`boot_to_race`, `options_save`, `multiplayer_lobby`, `full_race_cross`, `race_gp`, `race_traffic`, `abort_race`, `restart_race`, `two_races` and `cup`, 63,542 frames) executes 7 of the 16 ROM dispatchers and 12 of the 239 slots:

| Dispatcher | Slots executed (case index) | Routes |
|---|---|---|
| `0x080003FC` | 0 | `cup` only (once) |
| `0x08002DA0` | 0 | all ten |
| `0x08002F4C` | 0, 11 | all ten; 11 on `cup` only |
| `0x08003EDC` | 0, 1 | all ten; 1 on `options_save` |
| `0x08010590` | 0 | `multiplayer_lobby` only |
| `0x08011B90` | 0, 8, 15 | all ten |
| `0x08012458` | 0, 8 | all ten |
| race image `0x03001BBC` | 0 | every route with a race |
| race image `0x03003E78` | 2 | `cup` only |

The other 227 ROM slots, and all slots of the three tables of the race program's ROM code, are not reached on these routes. Their evidence is the static reading above, which is why P2-06 seeds whole tables from the scan rather than from miss reports. On `boot_to_race` the eight slots mGBA executes are exactly the eight case-slot misses P2-05 left on that route.

## 4. Generation

`scripts/regen.sh` (`build/logs/recompile.log`), and the function roots of the two `dispatch_table.cpp` files compared:

| | Base | New |
|---|---|---|
| `extra_func` entries | 8 | 247 |
| Functions emitted | 2,278 (ARM 1,623, Thumb 655) | 2,747 (ARM 2,088, Thumb 659) |
| Found by the walk / from the config only | 2,269 / 9 | 2,499 / 248 |
| Resume aliases (`midfn_aliases`) | 20,576 in 2,019 functions | 22,084 in 2,233 functions |

Discovery grows by 469, as the diagnosis measured on PR #5's config (2,259 to 2,728). The new roots are the 239 slots (none of which the finder reached before), 147 case targets (157 distinct targets, 10 of them roots already) and 83 functions reached from the case code, 4 of them Thumb: `0x0801191C`, `0x0801191E`, `0x0816258C` and `0x0816258E`, inside the front end's and the race program's BIOS-call wrappers (Phase 1 §6: `0x08011908`-`0x0801192B` and `0x08162580`-`0x0816259B`). No root of the base is lost.

Two dispatchers were in code the finder had not reached at all: `0x08011D14` and `0x081634DC`, whose default slots (`0x08011D18`, `0x081634E0`) are roots in the new build only. Each is reached through a case of another table: the case target `0x08011D08` of `0x08011B90`, and `0x081634D0` of `0x08163338`, run two instructions into the `cmp` of the nested table, which shares the outer table's default target (`0x08011C28`, `0x081635E8`). `0x08011DDC` and `0x08011DE8`, the two return addresses P2-05 left as misses, are in that newly reached code (diagnosis §2.2).

## 5. Runs

| Run | Build | Exit | `ppu_frames` | Misses | ROM misses | Interpreted instructions |
|---|---|---|---|---|---|---|
| `boot_to_race` replay, 3,290 frames | base | 0 | 3,290 | 13 | 10 | 128,721,463 |
| `boot_to_race` replay, 3,290 frames | new | 0 | 3,290 | 3 | 0 | 128,256,718 |
| no input, 12,000 frames | base | 0 | 12,385 | 10 | 7 | 916,527,971 |
| no input, 12,000 frames | new | 0 | 12,385 | 3 | 0 | 916,102,208 |

The base runs reproduce P2-05's (same counts; the 3,290-frame capture file is byte-identical to P2-05's). The ROM misses gone are the ten P2-05 left: `0x08002DA8`, `0x08002F54`, `0x08003EE4`, `0x08011B98`, `0x08011BB8`, `0x08011BD4`, `0x08012460` and `0x08012480` (case slots), and `0x08011DDC`, `0x08011DE8` (on the 12,000-frame boot, the same without the first three). What remains are the IWRAM misses, as expected until P2-10: `0x03000000` (ARM), `0x030004DC` (Thumb) and `0x03000708` (ARM), with the same counts as before (`x1`, `x5593`, `x7340` on `boot_to_race`). Both 12,000-frame runs stop at 12,385 frames, as in P2-05 (the intro player's bridge never checks the quit).

**Frames and state are unchanged.** `capture.py join BASE NEW --frames 1-3290` on the two `boot_to_race` captures: every compared column (`fb`, `lines`, `DISPCNT`, the ten memory fields, the three RAM regions, both FIFOs, `io_writes`, `halt_writes`) is equal on all 3,290 frames, and so is the `cycles` column, which `join` does not compare. The only column that differs is `bridge_insns`, the instructions interpreted per frame (on 1,877 frames, 464,745 fewer in all). The same holds over the 12,386 records of the 12,000-frame boots (`join` exits 0; `cycles` equal; 425,763 fewer interpreted instructions). So the slots run as generated code with the same results and the same cycle count as when the interpreter bridged them.

**The race.** `boot_to_race` with `--frames 4400` and `GBARECOMP_SELFHEAL_VERBOSE=1` on both builds: both abort at frame 5,127 with `SELF-HEAL bridge for 0x03001CB0 exceeded 200000000 instructions`, as P2-05 found and the plan expects until P2-10, and their captures are equal on every column but `bridge_insns` over all 5,127 records. The base misses 47 PCs (19 IWRAM, the 10 ROM PCs above, 18 Thumb PCs of the race program); the new build misses the same 37 without the 10. The race program's three ARM tables are not dispatched on this build: its main loop runs in a bridge.

## 6. Not done here

- The 4 tables of the race IWRAM image (34 slots, runtime addresses in section 2): for P2-10, which compiles that image. The scanner reports them; it has no option to print them as `[[extra_func]]` entries at their runtime addresses, which P2-10 can add once it knows how that image is compiled.
- The race program's Thumb byte-table switches ([phase2-resume-roots.md](phase2-resume-roots.md) section 8; Phase 1 counted 4): the scanner reads the ARM form only. Their case targets wait for P2-10 and P2-11.
- Upstream candidate U11 (the finder could decode these tables itself) is unchanged; nothing is filed.
- Whether other routes miss anything new is P2-11's strict gate. With the seeds, the slots mGBA executes on `cup`, `options_save` and `multiplayer_lobby` (section 3) have entries already.

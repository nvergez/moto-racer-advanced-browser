# Open-BIOS A/B: the Cult-of-GBA BIOS against the retail BIOS

**Date:** 2026-10-11
**Task:** P2-17 in [phase2-plan.md](../phase2-plan.md): [open-bios.md](open-bios.md) §5.3 steps 1-3 with the Cult-of-GBA image in the mGBA harness, and whether gbarecomp's HALT exit condition ([toolchain.md](../toolchain.md), known issue 5) is the only thing that stops it under gbarecomp.
**Status:** Measured in mGBA 0.10.5 through `tools/analysis/harness`, and in a scratch gbarecomp build. Nothing was run on hardware. This feeds the gates of [ADR 0001](../adr/0001-port-via-static-recompilation.md) decision 4. It is not part of Phase 2's exit.

**Pins.**

| Input | Identity |
|---|---|
| ROM | Moto Racer Advance (Europe) `A9MP`, SHA-1 `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0` |
| Retail BIOS | the owner's dump, SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492` |
| Cult-of-GBA BIOS | `bios.bin` of [Cult-of-GBA/BIOS](https://github.com/Cult-of-GBA/BIOS) at `a30e9a96df083628b650724b7d4d7112b4070b98` (MIT), downloaded as GitHub's archive of that commit; SHA-1 `2e41f9d30ecdf1c4540edf89ac16f49bf327edb7`, MD5 `e2a18f17249a24415ca70d57f40501c8`, 16,384 bytes, the image [open-bios.md](open-bios.md) studied. Not committed |
| mGBA | 0.10.5 (`26b7884`), the harness in `tools/analysis/harness` |
| gbarecomp | `5e89943` plus the scratch changes listed in [section 9](#9-under-gbarecomp-is-the-halt-exit-condition-the-only-blocker) and the [appendix](#appendix-the-gbarecomp-halt-experiment) |

Frame numbers below are **retail-equivalent harness frames**: the frame a retail-BIOS boot would be at, so they line up with `tools/analysis/input/*.txt` (race display from 3303 on `boot_to_race`, and so on). A run that starts elsewhere is shifted by its handoff frame ([section 1](#1-method)).

## Summary

From the cartridge entry, with the same inputs, the Cult-of-GBA BIOS plays the game in mGBA with the same SWI calls and results as the retail BIOS, no lag frame in any race, the same finishing positions on all three tracks and the same race times on two of them. Every difference we found comes from timing: game code whose result depends on where in the frame it runs, never a wrong result. Through its own boot it also runs, but it leaves a different machine state at handoff, and mGBA then never halts the CPU for the rest of the run. Under gbarecomp, the HALT exit condition is the only blocker we found on the routes the current prototype covers.

- **DivArm with a negative divisor and a nonzero remainder: never.** 0 calls out of 1,849-15,643 per route, on all six routes and all four variants (49,417 calls over the six `retail-skip` runs). No divisor is zero or negative (the smallest is 5) and no numerator is negative. Cult-of-GBA's remainder-sign difference ([open-bios.md](open-bios.md) §1) can therefore never change a result in this game on these routes.
- **Lag frames: none in races.** The race main loop starts one iteration in every frame of every race, under both BIOSes (0 lag frames, 0 doubled frames, 16 race runs). The work per iteration differs by at most one scanline while the two runs are still in the same state. In the front end, Cult-of-GBA makes 3 more VBlankIntrWait calls per route, all in 9 frames of the intro animation (net 3 fewer lag frames; it decompresses faster).
- **Race results.** Position 8 on Cross/Kenya, 8 on GP/California and 4 on Traffic/Moscow under every variant. Race times are identical from the cartridge entry on Cross (4'54"36) and GP (3'56"24). On Traffic, lap 3 is 93 frames (1.55 s) slower under Cult-of-GBA (3'43"39 against 3'41"84).
- **The first divergence is timing, and it is explained.** Until the states diverge, both BIOSes receive exactly the same SWI calls with the same arguments; only where in the frame each call happens moves, by a scanline or so. The race's random number generator (IWRAM `0x03000000`, race image) adds VCOUNT to its state, so a one-line shift gives a different random number: on Cross at frame 18293 VCOUNT reads 218 under retail and 219 under Cult-of-GBA, and the runs differ from there on. On Traffic the runs already differ in the front end at frame 3017, where an iteration counter at `0x0203FCCC` (which the race reads at start-up) advances on the other side of a frame boundary.
- **Per-SWI timing in mGBA** (Cult-of-GBA minus retail, same call, same arguments): LZ77UnCompWram about 9,500 cycles faster per call (median; up to 168,787), RLUnCompWram about 45,700 faster, CpuFastSet 17 faster, CpuSet 30 faster, DivArm 16-20 slower. The IRQ path, which runs about 229 times per race frame, takes the same time: the race loop's work per iteration is unchanged.
- **Open bus.** The game's NULL-pointer read (`0x03001458`-`0x03001464`) sees the after-IRQ value `0xE55EC002` under both BIOSes on all but a handful of reads. The after-SWI value differs (retail `0xE3A02004`, Cult-of-GBA `0xEAFFFFFE`) and was seen on 9 and 14 reads of 13,630 in the Cross race, all in its last 300 frames, and on 0 and 1 reads in the GP race. Forcing `0xEAFFFFFE` on every NULL-pointer read leaves the GP race unchanged and the Cross results unchanged; on Cross, RAM differs only from frame 21005 on, 800 frames before the end of the race.
- **Boot through its own intro.** The game boots, reaches the race on the same frame relative to the cartridge entry, and finishes all three races; GP and Traffic give the retail results, Cross is 4.10 s faster (4'50"26, still 8th). The options save is byte-identical to retail from the cartridge entry and differs in one byte (offset `0xCCC`, the same iteration counter) through Cult-of-GBA's own boot. Three things differ at handoff, and they are bugs or gaps in the image, not in the game:
  - Cult-of-GBA never writes POSTFLG, so it is 0 at handoff where retail leaves 1. mGBA 0.10.5 ignores HALTCNT writes while POSTFLG is 0, so in mGBA its 60-frame boot screen runs in 6 frames and **no HALT takes effect for the rest of the run**: every VBlankIntrWait becomes a busy loop. Whether hardware has the same rule is **unverified**.
  - Its RegisterRamReset never clears the highest region it is asked for, so OAM keeps the boot screen's sprites (57 nonzero bytes at handoff); OAM matches retail again from frame 607. Nothing showed on screen.
  - SOUNDCNT_H is `0x000E` instead of `0x0000`, and timer 0's reload is 0 instead of the retail intro's `0xFF89`. IE is 0 under both, which settles the question in [open-bios.md](open-bios.md) §2.5.
- **gbarecomp: HALT is the only blocker found.** With a scratch fix that ends HALT when IE AND IF is nonzero, the Cult-of-GBA BIOS boots through its own boot screen (60 frames), reaches the race and finishes Cross under `GBARECOMP_STRICT_STATIC=1` with `FULLY_STATIC dispatch_misses=0`, as the retail BIOS does in the prototype build without the fix. The fix wakes the CPU 60 times, all during that boot screen. A retail Cross run in a build with the fix never reaches it, and its 18,892-call SWI log is byte-identical to the one from the build without the fix. On GP, Traffic, the options save and the lobby, both BIOSes stop at the same ROM dispatch miss (gaps in the prototype's coverage of the game, not BIOS ones); run without strict mode, the two miss lists are identical, no BIOS address misses, and the options save matches mGBA's byte for byte. The [appendix](#appendix-the-gbarecomp-halt-experiment) has the change, the commands and the frame counts.

**Scope.** P2-17 is done except two items of [open-bios.md](open-bios.md) §5.3, which stay open in [phase2-plan.md](../phase2-plan.md) (P2-17): the full cup (step 1; it needs P2-04's cup route, then `run_ab.sh --routes cup`) and emibios's test suite (step 3, section 7). Also not covered: hardware, mGBA's HLE BIOS as a third variant (not needed with a retail dump), and the CpuSet path under gbarecomp (one call).

## 1. Method

**Variants.** Each route runs four times:

| Variant | BIOS | Start | Handoff (first instruction at `0x08000000`) | Script shift |
|---|---|---|---|---|
| `retail-boot` | retail | full boot | frame 271, VCOUNT 126 | 0 (the reference, as in Phase 1) |
| `cult-boot` | Cult-of-GBA | its own boot | frame 6, VCOUNT 220 | −265 |
| `retail-skip` | retail | cartridge entry (`--skip-bios`) | frame 1, VCOUNT 126 | −270 |
| `cult-skip` | Cult-of-GBA | cartridge entry (`--skip-bios`) | frame 1, VCOUNT 126 | −270 |

`--skip-bios` uses mGBA's `skipBios`: `GBASkipBIOS` jumps to `0x08000000` with VCOUNT 0x7E and POSTFLG 1 whatever BIOS is loaded (`src/gba/gba.c:274-290` at 0.10.5), and the loaded image keeps handling every SWI and IRQ. Both `-skip` variants start from the same machine state: their handoff dumps (I/O, CPU registers, all RAM) are identical. They are the A/B proper, as [open-bios.md](open-bios.md) §5.3 step 2 asks. The `-boot` pair checks the boot path. A retail boot hands off at VCOUNT 126 too (0x7E), so shifting a script by −270 replays the same inputs relative to the cartridge entry.

**Routes.** The Phase 1 scripts in `tools/analysis/input/` (`boot_to_race`, `full_race_cross`, `options_save`, `multiplayer_lobby`), plus `race_gp_finish` and `race_traffic_finish` in `tools/analysis/open-bios-ab/input/`: the GP and Traffic scripts with A held to the finish. All hold accelerate through each race, so a few frames of drift do not change the line the bike takes.

**What each run records** (harness options added for this task, see [tools/analysis/README.md](../../tools/analysis/README.md)):

- every SWI with r0-r3 (`--trace-swi`) and the cycles from the SWI instruction to the caller's next instruction (`--swi-cycles`, IRQs taken in between included);
- every game load from the BIOS region with the value it got (`--log-bios-reads`); in mGBA that value is the open-bus latch of whichever image is loaded;
- per frame, the trace columns plus CRC32s of IWRAM `0x03000000`-`0x03006FFF`, IWRAM `0x03007000`-`0x03007FFF` (stacks and BIOS words) and EWRAM (`--trace-ram`), and the race's lap words at `0x0201A370`-`0x0201A37F`;
- in races, the PCs `0x03001CFC` (the race main loop, right after its VCOUNT ≥ 170 busy-wait, once per iteration) and `0x03001D6C` (the end of the iteration's work, where it branches back to the busy-wait at `0x03001CEC`). Found with `--trace-pc 0x03001CB0-0x03001FFF` on frames 4000-4001 of `boot_to_race`;
- the state at the handoff (`--dump-at-pc 0x08000000`), and the `.sav` of `options_save`.

**Race results.** At the end of a race the game shows the lap times, the race time and the position. The lap times are stored in frames at `0x0201A370`, `0x0201A374` and `0x0201A378` (laps 1-3) and `0x0201A37C` (best lap) while the race program runs: on `full_race_cross` with the retail BIOS they read 5444, 6108 and 6110 at frame 21700, and the overlay shows 1'30"73, 1'41"79 and 1'41"83 (5444 / 60 = 90.73 s); the same words matched the overlay on all 12 race-result screenshots below. The words were found by searching a frame-21700 RAM dump for 5444; no code was read to confirm their meaning, so treat the addresses as **likely**. The position is only on screen, so it is read by hand from a screenshot of the results overlay: for every run whose race display (DISPCNT `0x1741`) ends before the run does, `run_ab.sh` reruns the route up to 60 frames before the last race-display frame and screenshots that frame (below). The end frame depends on the run (section 4), so no fixed frame in the input scripts would do.

**Commands.**

```sh
# Cult-of-GBA bios.bin from https://github.com/Cult-of-GBA/BIOS at a30e9a9, outside the repository
tools/analysis/harness/build.sh
tools/analysis/open-bios-ab/run_ab.sh --cult-bios /path/to/cult-of-gba/bios.bin
tools/analysis/open-bios-ab/run_ab.sh --cult-bios ... --variants retail-skip \
  --routes "full_race_cross race_gp_finish" --tag obEAFFFFFE --harness-args "--openbus 0xEAFFFFFE"
python3 -I tools/analysis/open-bios-ab/ab_report.py analysis-out/open-bios-ab
```

**Results-overlay screenshots** (part of `run_ab.sh` unless `--no-result-shots` is given). For each finished race, F = the last harness frame of the race display − 60, which is race-display end − 60 + shift in retail-equivalent frames. `ab_report.py --result-shot-frame analysis-out/open-bios-ab/VARIANT/ROUTE` prints F, and each `race_result:` line of the report gives the same frame in retail-equivalent numbering as `result_shot_frame`. `run_ab.sh` then runs, with the variant's BIOS and start and any `--harness-args`:

```sh
OUT=$PWD/analysis-out/open-bios-ab   # run_ab.sh's default --out
tools/analysis/harness/run_harness.sh --no-hash-check --bios BIOS [--skip-bios] \
  --out "$OUT/VARIANT/ROUTE/result" --script "$OUT/VARIANT/ROUTE/script.txt" \
  --frames F --shot-at F --trace F-F --trace-ram \
  --trace-mem 0x0201A370:4,0x0201A374:4,0x0201A378:4,0x0201A37C:4
```

The screenshot is `VARIANT/ROUTE/result/shots/fNNNNNN.png` (NNNNNN = F). `run_ab.sh` compares frame F's `trace.tsv` row with the main run's (keys, video registers, CRCs of VRAM, palette, OAM, IWRAM and EWRAM, the lap words) and fails at the end if they differ, so the screenshot shows the traced run.

The 24 runs of the matrix and their 12 results-overlay reruns take 7-10 minutes and about 215 MB under `analysis-out/` (every frame stepped for `--swi-cycles`); the two open-bus variants add about 65 MB. Two complete runs of the matrix gave the same metrics. A third, after the review changes to these tools, gave byte-identical `trace.tsv`, `swi.tsv`, `swicycles.tsv`, `biosreads.tsv`, `pctrace.tsv` and `.sav` files for all 24 runs, and the 12 screenshots show the positions and times of section 4.

## 2. SWI census and DivArm

SWI calls per route, `retail-skip` / `cult-skip`:

| Route | VBlankIntrWait | DivArm | CpuSet | CpuFastSet | LZ77UnCompWram | RLUnCompWram |
|---|---|---|---|---|---|---|
| `boot_to_race` | 1442 / 1445 | 2884 / 2884 | | 968 / 968 | 67 / 67 | 4 / 4 |
| `full_race_cross` | 1452 / 1455 | 14866 / 14866 | | 2420 / 2420 | 71 / 71 | 5 / 5 |
| `race_gp_finish` | 1452 / 1455 | 15642 / 15643 | | 1481 / 1481 | 71 / 71 | 5 / 5 |
| `race_traffic_finish` | 1452 / 1455 | 12154 / 12069 | | 1657 / 1609 | 72 / 72 | 5 / 5 |
| `options_save` | 1412 / 1415 | 1849 / 1849 | | 1048 / 1048 | 61 / 61 | 4 / 4 |
| `multiplayer_lobby` | 1412 / 1415 | 2022 / 2022 | 2446 / 2451 | 815 / 815 | 62 / 62 | 4 / 4 |

These are the six SWIs of the Phase 1 census ([phase1-findings.md](phase1-findings.md) §6); no other SWI ran under either BIOS. The Traffic DivArm and CpuFastSet counts differ because the two races differ (section 5).

**DivArm** (r0 = divisor, r1 = numerator, logged at entry): on every route and every variant, 0 calls with a zero divisor, 0 with a negative divisor, and 0 with a negative numerator and a nonzero remainder. The smallest divisor is 5, the smallest numerator 0. Phase 1 had recorded "DivArm never gets a zero or negative divisor" without an independent check ([phase1-findings.md](phase1-findings.md) §6); this confirms it on these routes. Cult-of-GBA's Div and DivArm differ from retail in the remainder's sign when the divisor is negative (`bios_calls/math/division.s` L48-49) and for a zero divisor or `INT_MIN / -1` (L8). This game made neither kind of call, so Cult-of-GBA returned retail's results for every one.

`retail-skip` and `cult-skip` make the same calls until the game states diverge (section 5): the multisets of (caller, function, r0, r1, r2), VBlankIntrWait aside, are equal up to the end of `boot_to_race` (3,923 calls) and `options_save` (2,962), and up to frame 18292 on Cross (11,809 calls), 6715 on GP, 3603 on Traffic and 2773 in the lobby. What moves is when they happen. The first difference is call 16, a DivArm at frame 294 with the same arguments, made at VCOUNT 9 instead of 8; at frame 1878 a CpuFastSet and an LZ77 call come in the other order.

One register side effect differs: after CpuFastSet, r3 is 0 under the retail BIOS and unchanged under Cult-of-GBA (r3 at the entry of back-to-back CpuFastSet calls; r3 is not an argument). [open-bios.md](open-bios.md) §5.2 anticipated such differences. The game does not depend on it on these routes, since the states stay equal.

## 3. Timing: lag frames and SWI costs

**Race main loop.** Iterations start in every frame of every race under all four variants: 0 lag frames and 0 frames with two starts (16 race runs, 1,093 to 18,482 iterations each). The work per iteration (from the start of the iteration to the end of its work, in scanlines) is 113-203 lines on Cross and GP and up to 274 on Traffic, where 20 (retail) and 27 (`cult-skip`) iterations overrun a frame, as Phase 1 saw, without losing one. Paired by frame on `boot_to_race`, where the race state is identical under both BIOSes, the work differs in 17 of 1,093 iterations, by one line each way (mean +0.014 lines under Cult-of-GBA). After the race states diverge (section 5) paired differences mean nothing: Traffic's reach ±99 lines because different traffic is on screen.

**Front end.** The game waits with VBlankIntrWait, at most once per frame. `cult-skip` makes 3 more calls than `retail-skip` on every route, and the per-frame count differs in exactly 9 frames of the intro animation: in 2162-2164 and 2186-2188 only Cult-of-GBA calls, in 2182-2184 only retail does. Net, Cult-of-GBA has 3 fewer lag frames there.

**Per-SWI cycles in mGBA**, calls with the same caller and arguments matched in order, `cult-skip` minus `retail-skip`, over the six routes:

| SWI | Retail median (`boot_to_race`) | Difference per call, median | Range of the median over routes |
|---|---|---|---|
| CpuFastSet | 216 | −17 | −17 |
| CpuSet (lobby only) | 152 | −30 | −30 |
| DivArm | 172 | +16 | +16 to +20 |
| LZ77UnCompWram | 79,497 | −9,468 | −9,194 to −9,641 |
| RLUnCompWram | 412,806 | −45,841 | −45,625 to −45,841 |

The cycle counts include any IRQ taken during the call, so single calls vary more (for example −228 to +187 for DivArm on `boot_to_race`); the medians are stable. They are mGBA's model of BIOS execution, which has not been compared with hardware.

What this means: decompression is much faster under Cult-of-GBA (up to 168,787 cycles, 0.6 frame, for one LZ77 call), which only shortens loading and the intro. In races the BIOS runs DivArm at most twice per frame (Phase 1) and the IRQ entry and exit about 229 times; Cult-of-GBA's IRQ handler has the same instructions in the same order as retail's ([open-bios.md](open-bios.md) §2.4), and the race loop timing above shows no measurable change.

## 4. Race results

Position and times from the results overlay, read by hand from the screenshots `run_ab.sh` takes 60 frames before the end of each race display (`VARIANT/ROUTE/result/shots/`, [section 1](#1-method)):

| Track | `retail-boot` | `retail-skip` | `cult-skip` | `cult-boot` |
|---|---|---|---|---|
| Cross, Kenya | 8th, 1'30"73, 1'41"79, 1'41"83, race 4'54"36 | same | same | 8th, 1'26"66, 1'41"83, 1'41"76, race 4'50"26 |
| GP, California | 8th, 1'24"68, 1'15"96, 1'15"59, race 3'56"24 ("NEW RECORD") | same | same | same |
| Traffic, Moscow | 4th, 1'10"33, 1'15"98, 1'15"53, race 3'41"84 | same | 4th, 1'10"33, 1'15"98, 1'17"08, race 3'43"39 | same as retail |

In frames (lap words): Cross 5444 + 6108 + 6110 = 17662; `cult-boot` Cross 5200 + 6110 + 6106 = 17416; GP 5081 + 4558 + 4536 = 14175 everywhere; Traffic 4220 + 4559 + 4532 = 13311, `cult-skip` 4220 + 4559 + 4625 = 13404. The race display ends at frame 21788 (Cross), 18307 (GP) and 17468 (Traffic; 17467 under `cult-boot`) for every run with retail times, at 21542 for `cult-boot` Cross and at 17560 for `cult-skip` Traffic, so the screenshots are at 21728, 18247, 17408 (17407), 21482 and 17500 (plus the variant's shift in harness frames). With the A-held-to-the-finish scripts, GP and Traffic end earlier than the 18415 and 17909 that Phase 1 reports for those tracks ([phase1-findings.md](phase1-findings.md) §2). Phase 1's `race_gp.txt` and `race_traffic.txt` end at frame 6000 and what those runs did after it is not recorded, so its end frames do not apply to these scripts. On Traffic, for example, the mode-4 "Try again" screen (DISPCNT `0x1444`) is up from frame 17493.

So from the same start, one of three races changed, by one lap time; through the BIOS's own boot, another one did. Neither is a systematic effect of the BIOS: the Traffic race matches retail when started through Cult-of-GBA's boot, and the Cross race when started from the cartridge entry. Both are the same timing sensitivity, seen from two starting points (section 5). A tolerance for race results, which [open-bios.md](open-bios.md) §5.3 leaves to the ADR, has to allow for it: these open-loop replays drift by one or two seconds on a lap whatever the BIOS.

## 5. First divergence and its cause

`retail-skip` against `cult-skip`, per frame (frames where the trace columns differ):

| Route | Front end | From the race onward |
|---|---|---|
| `boot_to_race` | video in 86 frames, in single frames and runs of up to 4 (the intro animation is decoded every 7 frames and finishes on the other side of VBlank start); EWRAM in 77, in single frames and short runs, the longest 596-606 and 3299-3306; IWRAM below `0x03007000` in 92: 607, 1391 and the continuous stretch 2182-2271, which starts in the intro frames where the VBlankIntrWait counts differ (section 3; what those IWRAM bytes hold was not examined) | identical from frame 3307 to the end (4400): video, EWRAM and IWRAM below `0x03007000` |
| `full_race_cross` | same | identical from 3307 to 18292; from 18293 on EWRAM and IWRAM differ, the screen from 18720 |
| `race_gp_finish` | same | identical from 3350 (after short differences during the race load, the longest EWRAM 3341-3349) to 6734; RAM differs from 6735 on, the screen from 8192 |
| `race_traffic_finish` | same, then IWRAM differs in 3018-3343, EWRAM in 3017-3021 | differ from 3353 (EWRAM) and 3362 (IWRAM) on |
| `options_save` | same kinds of differences (video in 82 frames, EWRAM in 64, IWRAM in the same 92), none after 2482 | (no race); the 32 KiB `.sav` is identical |
| `multiplayer_lobby` | same, then EWRAM differs in the lobby from 2773 on | (no race) |

(`ab_report.py analysis-out/open-bios-ab --range-limit 100`, `divergence:` lines; frames retail-equivalent.)

IWRAM `0x03007000`-`0x03007FFF` differs from the first IRQ on: it holds the stacks, where the IRQ handler saves registers at timing-dependent points (the slot `0x03007F9C` in Phase 1 §6).

**Cross, frame 18293.** At frame 18292 the two machines' RAM and I/O differ only in the stack bytes `0x03007F84` and `0x03007F9C`. In frame 18293, the routine at IWRAM `0x03000000` (race image) runs: it loads VCOUNT, adds the 10-bit state at `0x02000720` plus one, stores it back, and returns a halfword from the table at ROM `0x083F5690` indexed by that state. VCOUNT reads 218 under retail and 219 under Cult-of-GBA, so the state becomes `0x148` and `0x149` (from `0x6D`), and the values the caller computes from the result (stored at `0x020359E0` and `0x0300562C`) are `0x2570` against `0x2070`. (Harness `--watch-write` and `--trace-pc 0x03000000-0x0300007F --trace-pc-regs` on that frame; the routine is called from Thumb code at `0x08161B3F`.) **GP, frame 6735:** the same routine, `0x02000720` becomes `0xA5` against `0xA6`. That is the race's random number generator: any change in when it runs within a frame changes the random numbers. This partly answers [game-facts.md](game-facts.md) question 17 for races.

**Traffic, frame 3017.** At frame 3016 the RAM differs only in stack bytes (above `0x03007E00`). In frame 3017 the front-end code at `0x08007F2C` increments a counter at `0x0203FCCC` (`0x1FA` to `0x1FB`) and `0x08007A84` updates `0x02000C3C`; under retail the same code runs a second time within the frame (counter to `0x1FC`), under Cult-of-GBA it does not. The race reads `0x0203FCCC` at start-up (Phase 1 §3), and Traffic then diverges from its first frames. The byte that differs in the `cult-boot` save is at offset `0xCCC` of the 0xCD0-byte block, which the front end keeps at `0x0203F000` (Phase 1 §3), so it is most likely the same counter: `0x14` against `0x15`.

So the divergence is drift in the sense of [open-bios.md](open-bios.md) §5.2: a different number of cycles in the BIOS moves game code within the frame, and this game feeds that position into its randomness. Two runs under the same BIOS do not diverge (the harness is deterministic), so this is not noise, but it is also not a wrong result. It will appear between gbarecomp and mGBA as well, which is consistent with the race lockstep issue that P2-13 investigates.

## 6. Open bus

Values the game got from the BIOS region (`--log-bios-reads`; every such load is the NULL-pointer bounding-box read at `0x03001458`-`0x03001464`, four byte loads per call):

| Route | Variant | Calls | After-IRQ `0xE55EC002` | After-SWI value |
|---|---|---|---|---|
| `full_race_cross` | `retail-skip` | 13,630 | 13,621 | `0xE3A02004` on 9, all from frame 21500 on (one of them got it in two of its four bytes only: an IRQ came in between) |
| `full_race_cross` | `cult-skip` | 13,628 | 13,614 | `0xEAFFFFFE` on 14, all from frame 21566 on |
| `race_gp_finish` | `retail-skip` | 3,774 | 3,774 | none |
| `race_gp_finish` | `cult-skip` | 3,779 | 3,778 | `0xEAFFFFFE` on 1, at frame 18024 |
| `boot_to_race` | both | 771 | 771 | none |
| `race_traffic_finish`, `options_save`, `multiplayer_lobby` | both | 0 | | |

mGBA's "Bad BIOS Load" messages (GAME_ERROR) count exactly these loads. The only other GAME_ERROR messages come from the BIOS boot itself (I/O, video-register, DMA-source and out-of-bounds ROM-load warnings), all before the handoff: under `retail-boot` 22 `gba.io`, 29 `gba.video`, 8 `gba.dma` and 10 `gba.memory` (for example "Out of bounds ROM Load16: 0x0BFFFFE0"), the last at frame 270; under `cult-boot` 2, 12, 8 and 0, the last at frame 4. The `-skip` variants log none (`stderr.log` of each run, "Bad BIOS" lines excluded).

To separate the value from the timing, the retail BIOS was run with every one of these loads forced (`--openbus`):

| Run | Against `retail-skip` |
|---|---|
| `full_race_cross`, `--openbus 0xE55EC002` | identical except one stack frame: the 9 after-SWI reads under retail change nothing |
| `full_race_cross`, `--openbus 0xEAFFFFFE` | identical until frame 21005; then EWRAM differs in 21005-21793 and the screen in 196 frames between 21597 and 21805 (the race display ends at 21788). Position and all lap times unchanged |
| `race_gp_finish`, either value | identical except stack bytes |

With Phase 1's result (the retail after-SWI value `0xE3A02004`, forced on every read, changes EWRAM from frame 3720), this means Cult-of-GBA's different after-SWI value is the less disruptive of the two, and the game sees it so rarely that it did not change a result. The after-IRQ value, which the game reads on all other calls, is the same in both images. The shim Phase 1 suggested (make the NULL path read `0xE55EC002`) is not needed for Cult-of-GBA on this evidence.

## 7. SWI conformance (open-bios.md §5.3 step 3)

emibios's test suite was **not run**: it needs Zig 0.16 and an emulator core its build fetches (GBAHawk by default), and neither is installed here. In its place, this task measured what step 3 was meant to give, on the game's own calls and against the retail BIOS directly rather than against emibios's pins:

- results: identical for every call (section 2: no input where Cult-of-GBA's DivArm differs; and the runs stay in the same state, call for call, until a timing effect, section 5);
- per-call timing: section 3.

Running the suite stays useful before A′, because it covers SWIs and inputs this game never uses (follow-ups).

## 8. Boot through each BIOS's own intro

**It works in mGBA.** `cult-boot` reaches the cartridge at frame 6 and, with the scripts shifted by −265, follows every route: race display from frame 3303 on `boot_to_race`, all three races finished (section 4), the options save written, the lobby reached.

**Handoff state**, `retail-boot` against `cult-boot` (dumps at the first instruction at `0x08000000`):

| | Retail | Cult-of-GBA | Note |
|---|---|---|---|
| Frame, VCOUNT | 271, 126 | 6, 220 | |
| POSTFLG | 1 | 0 | Cult-of-GBA never writes POSTFLG (no store to `0x04000300` in its source) |
| SOUNDCNT_H | `0x0000` | `0x000E` | Cult-of-GBA writes `0x880E` (`entrypoint.s` L84) |
| TM0CNT_L (reload) | `0xFF89` | `0x0000` | left by the retail intro's sound |
| DISPSTAT | `0x0000` | `0x0001` | VBlank flag: the handoff happens during VBlank |
| OAM | all zero | 57 nonzero bytes | see below |
| IE, IF, IME, DISPCNT, other I/O | equal | equal | IE = 0 under both |
| CPU registers, IWRAM, EWRAM, VRAM, palette | equal | equal | |

- **OAM is not cleared.** Cult-of-GBA's RegisterRamReset shifts the flags right and returns as soon as the remaining flags are zero, before it tests the carry of the bit it just shifted out (`bios_calls/register_ram_reset.s` L54-59: `lsrs r3, #1` then `beq` before `bcc`). The highest region asked for is therefore never cleared: with `0xFF`, OAM (bit 4). OAM matches retail again from frame 607; in the screenshots of frames 305-600 nothing extra shows.
- **mGBA ignores HALT while POSTFLG is 0.** In mGBA 0.10.5 a HALTCNT write halts only if POSTFLG is already nonzero (`src/gba/io.c:587-599`). Cult-of-GBA's boot screen waits for 60 VBlanks with `swi_Halt` and IME off (`boot_screen/boot_screen.s` L252-277); in mGBA none of those halts happens, so the boot takes 6 frames instead of about 63 (section 9). And because POSTFLG stays 0, every HALT the game asks for through VBlankIntrWait is ignored for the whole run: the BIOS's IntrWait loop polls instead of halting. With the different handoff phase and state, this is why the `cult-boot` runs drift differently from `cult-skip` (where `GBASkipBIOS` sets POSTFLG to 1), for example on Cross, which ends 246 frames sooner there. Whether hardware ignores HALT while POSTFLG is 0 is **unverified**; the retail BIOS sets POSTFLG before handoff, so retail runs never meet the case.

Both are cheap to fix in the A′ image ([open-bios.md](open-bios.md) §4): set POSTFLG to 1 at the end of boot, as GBATEK describes the retail BIOS doing, and test the carry before the zero flag in RegisterRamReset.

## 9. Under gbarecomp: is the HALT exit condition the only blocker?

**Setup (scratch, nothing committed; the [appendix](#appendix-the-gbarecomp-halt-experiment) has the change, the builds, the commands and the frame counts).** The Phase 2 diagnosis's iwram-overlays prototype (gbarecomp `5e89943` with patches 0001-0002, the prototype RAM overlay selector, the diagnostic VBlank-start input replay, the race and front-end corpora, healing off), built three ways:

| Build | HALT change | BIOS code linked | Used for |
|---|---|---|---|
| stock (the prototype as the diagnosis left it) | no | retail | every retail run in the results table |
| Cult-of-GBA | yes | Cult-of-GBA | every Cult-of-GBA run, with the change off (`MRA_HALT_EXIT_FIX=0`) or on (`=1`) |
| retail with the change | yes | retail | one strict `full_race_cross` run with the change on, to check that it does nothing for the retail BIOS |

- The Cult-of-GBA image is recompiled with the config in [open-bios.md](open-bios.md)'s appendix: 132 functions, 823 resume aliases, 955 dispatch entries, and the appendix's coverage script reports 0 missing entries, as in open-bios.md §3.
- The change, in `runtime_tick` (`src/runtime/runtime_bus_bridge.cpp`, right after the IRQ branch that starts at L774): when the CPU is halted and IE AND IF is nonzero but the IRQ is not taken (IME off or CPSR.I set), clear HALT after the usual wake latency, without taking an IRQ. This is the hardware rule ([GBATEK, BIOS Halt Functions](https://problemkaputt.de/gbatek-bios-halt-functions.htm)) and what gbarecomp's multiplayer loop already does (`src/runtime/multiplayer_session.cpp:157-160`). It is gated by the environment variable `MRA_HALT_EXIT_FIX`, so one binary gives both sides.
- gbarecomp's own HALTCNT write halts unconditionally (`src/gba/gba_io.cpp:714-719`): unlike mGBA, it has no POSTFLG rule, so the game's halts work under Cult-of-GBA without the change.

Inputs: the same scripts converted to the prototype's replay format; for Cult-of-GBA shifted by −207 frames, because under gbarecomp its boot hands over 207 frames before the retail one (the first SWI of the game, a DivArm with the same arguments, is at cycle 24,136,549 against 82,288,656, a difference of 207.02 frames). Each Cult-of-GBA run is therefore 207 frames shorter than the retail run of the same route (for example 24,793 against 25,000 frames on `full_race_cross`), so both end at the same point of the route.

**Results** (`SDL_AUDIODRIVER=dummy`, `GBARECOMP_SELFHEAL_RECOMPILE=0`, fresh save):

| Run | Retail BIOS, stock build | Cult-of-GBA BIOS, build with the change |
|---|---|---|
| 300 frames | boots (rows below) | change off: `final_pc=0x00000c08` at frame 300, stuck in the boot screen loop: the CPU is halted with IE AND IF nonzero and no IRQ taken on 214,658 ticks (the `mra_halt_exit_fix` count). Known issue 5 reproduced with the game |
| `boot_to_race`, strict | `FULLY_STATIC dispatch_misses=0`, exit 0, in the race loop at the end | change on: the same; the selector ran 3.16 M race dispatches |
| `full_race_cross`, strict | `FULLY_STATIC dispatch_misses=0`, exit 0 | change on: the same; the race finishes and the "Try again" screen shows |
| `race_gp_finish`, `race_traffic_finish`, `options_save`, `multiplayer_lobby`, strict | abort at a ROM dispatch miss (`0x0815A80A`, `0x0815B18C`, `0x08003EE8`, `0x08010598`) | change on: the same miss on each route |
| the same four, not strict | 8, 4, 1 and 1 misses, exit 0 | change on: the same miss PCs, all in ROM; no BIOS address |
| `options_save` `.sav` | SHA-1 `a5149c87…`, the same as mGBA's | the same |

How often the change acted: 60 wake-ups in the Cult-of-GBA `full_race_cross` run, the last at frame 61 (gbarecomp's frame count), all in the boot screen. On that route the game itself never halted with IME off or CPSR.I set. In the third build (retail BIOS, change on), `full_race_cross` under strict mode gives `FULLY_STATIC dispatch_misses=0`, exit 0, the branch never runs, and the race's 18,892-entry cycle-stamped SWI log (`GBARECOMP_SWI_LOG`) is byte-identical to the stock build's.

The first runs of this table used an earlier build of the change, without the counter. Every row was run again with the builds and commands of the appendix (2026-10-11): the same final PCs, cycle counts, coverage lines, abort PCs, miss lists and `.sav` SHA-1 (`a5149c87b90e486f8fb5d0aba6272052f5b8eb70`); on `boot_to_race` and `full_race_cross` the step counts match too (Cult-of-GBA `full_race_cross`: 46,002 steps, 382,840,627 cycles). Only the 300-frame run's step count moved, from 298 to 301, for the same 83,426,112 cycles.

So, on every route the prototype's corpus covers, the HALT exit condition is the only thing that stops the Cult-of-GBA BIOS, and the fix that removes it changes nothing for the retail BIOS. Not covered: routes the prototype does not cover statically (P2-10 and P2-11 add them), CpuSet (the lobby route reached only one CpuSet call under gbarecomp, against about 2,450 in mGBA, with either BIOS), and the browser build.

## 10. What this means for ADR 0001 decision 4

The decision lists four gates before an open BIOS can be the players' target. Where they stand:

1. **mGBA A/B against retail with drift-tolerant metrics: done for the six routes we have, not yet closed.** [open-bios.md](open-bios.md) §5.3 step 1 asks for a full cup, and its acceptance tier is measured over one; that run waits for P2-04's cup route and is an open item of P2-17 in [phase2-plan.md](../phase2-plan.md), as is emibios's suite (step 3). On the six routes: no result difference, no lag, the same positions; race times move by up to 4.1 s (`cult-boot`, Cross) or 1.55 s (`cult-skip`, Traffic) through the game's VCOUNT-seeded randomness. The ADR's tolerance has to be set with that in mind, and against how much the same replay drifts under retail itself (P2-13).
2. **A fix for gbarecomp's HALT exit condition: needed, and sufficient on the covered routes.** It is a small runtime change with no effect on retail runs here; it becomes a patch in its own task.
3. **Strict static coverage of the open BIOS: holds on `boot_to_race` and `full_race_cross`** with the appendix config; the other routes wait for the game's own coverage.
4. **The A′ cleanup: not started.** Add two fixes to its list: POSTFLG = 1 at the end of boot, and the RegisterRamReset carry test. Keep the DivArm remainder fix too, even though this game never needs it.

Nothing found argues against the direction. The main cost is the one [open-bios.md](open-bios.md) §5.2 predicted: timing drift, which in this game reaches race outcomes through its randomness.

## Follow-ups

- The HALT exit fix as a gbarecomp patch (upstream candidate, related to U4 in the diagnosis), with a synthetic repro ROM that halts with IME off. Not filed upstream without the owner. The experiment's version is in the [appendix](#appendix-the-gbarecomp-halt-experiment).
- The full-cup A/B once P2-04's cup route exists: `run_ab.sh --routes cup` (an open item of P2-17 in [phase2-plan.md](../phase2-plan.md)).
- The open-BIOS build under gbarecomp beyond the prototype: CpuSet (lobby), the routes P2-11 covers, and the browser build.
- Run emibios's suite against Cult-of-GBA (Zig 0.16 and an emulator core; an open item of P2-17).
- Whether hardware ignores HALT while POSTFLG is 0 (would need the owner's hardware; see the plan's optional test ROM).
- The race random number generator at `0x03000000` and the counter at `0x0203FCCC`: record them in [game-facts.md](game-facts.md) question 17, and use them in P2-13, since the same VCOUNT dependence will move gbarecomp's races away from mGBA's.
- Confirm the lap-word addresses `0x0201A370`-`0x0201A37C` from the code that writes them before P2-19 relies on them.

## Reproducing

mGBA: the commands in [section 1](#1-method), including the results-overlay screenshots. Everything they write (traces, dumps, screenshots, `.sav` files, savestates) is derived from the ROM and stays under `analysis-out/`. gbarecomp: a scratch build of the diagnosis's prototype; the [appendix](#appendix-the-gbarecomp-halt-experiment) gives the HALT change (33 added lines in `runtime_tick`), the builds, the input conversion, the environment and the frame count of every run.

## Appendix: the gbarecomp HALT experiment

The record of section 9's scratch experiment, so that it can be run again. The change below is **not a patch of this repository** and no script here applies it: the HALT exit fix becomes a patch in `patches/gbarecomp/` in its own task (follow-ups), with a synthetic repro ROM, and may change on the way. The host it was built into is the Phase 2 diagnosis's iwram-overlays prototype, which lives outside the repository ([phase2-plan.md](../phase2-plan.md), "Starting point"; diagnosis §3.2); P2-02, P2-03 and P2-07 port its pieces. Everything the steps below produce is derived from the ROM or the BIOS images and stays out of git.

**Builds.** The prototype host (`MraProto`, with the diagnosis's overlay selector, option C, and the race and front-end corpora compiled in), configured with CMake and Ninja, `-DCMAKE_BUILD_TYPE=Release -DGBARECOMP_ROOT=<gbarecomp copy> -DPROTO_GEN=<race corpus> -DPROTO_FE_GEN=<front-end corpus> -DGBARECOMP_GENERATED_BIOS_DIR=<recompiled BIOS>`, target `MraProto`:

| Build | `GBARECOMP_ROOT` | `GBARECOMP_GENERATED_BIOS_DIR` |
|---|---|---|
| stock | the prototype's gbarecomp copy: `5e89943`, patches 0001-0002, and the prototype's selector and diagnostic patches | the retail BIOS, recompiled by the prototype |
| Cult-of-GBA | the same copy with the change below | the Cult-of-GBA `bios.bin`, recompiled by `gba_recompile` (`5e89943`) with `--bios bios.bin --config cult_bios.toml --out gen/bios-cult`, where `cult_bios.toml` is the config in [open-bios.md](open-bios.md)'s appendix |
| retail with the change | the same copy with the change below | the retail BIOS, as in the stock build |

**The change.** In `src/runtime/runtime_bus_bridge.cpp`, function `runtime_tick`, after the branch that takes a pending IRQ (`if (bus->io().irq_pending() && (g_cpu.cpsr & CPSR_I_BIT) == 0) {`, L774 at `5e89943`). Patches 0001-0002 and the prototype's patches do not touch this file, so the hunk applies to the pin with the same line numbers. 33 added lines: the wake is the last 10, the rest reads `MRA_HALT_EXIT_FIX` once and counts how often the branch runs. The count is printed at exit, only if the branch ran at least once, as `mra_halt_exit_fix enabled=E events=N last_event_frame=F` (F = gbarecomp's cycle counter / 280,896). With `MRA_HALT_EXIT_FIX=1` every event is one wake-up. With 0 the CPU stays halted and the branch runs again on each tick, so N then counts ticks.

```diff
--- a/src/runtime/runtime_bus_bridge.cpp
+++ b/src/runtime/runtime_bus_bridge.cpp
@@ -804,6 +804,39 @@
             recompute_event_budget(bus, ppu);
         }
         runtime_irq(g_cpu.R[15]);
+    } else if (bus->io().halted() &&
+               (bus->io().ie() & bus->io().if_reg()) != 0) {
+        // SCRATCH EXPERIMENT (P2-17, not a patch): HALT ends as soon as
+        // IE AND IF is non-zero, whatever IME and CPSR.I say (GBATEK, BIOS Halt
+        // Functions); no IRQ is taken. Env-gated so one build gives both sides.
+        static const bool halt_exit_fix = [] {
+            const char* e = std::getenv("MRA_HALT_EXIT_FIX");
+            return e && e[0] == '1';
+        }();
+        // Count the wakes this branch performs (it only runs when the stock
+        // condition above would have left the CPU halted).
+        static unsigned long long wakes = 0;
+        static unsigned long long last_wake_cycle = 0;
+        static const bool report_registered = [] {
+            std::atexit([] {
+                std::fprintf(stderr, "mra_halt_exit_fix enabled=%d events=%llu last_event_frame=%llu\n",
+                             halt_exit_fix ? 1 : 0, wakes, last_wake_cycle / 280896ull);
+            });
+            return true;
+        }();
+        (void)report_registered;
+        ++wakes;
+        last_wake_cycle = g_runtime_cycles;
+        if (halt_exit_fix) {
+            bus->io().clear_halt();
+            if (g_pending_cycles) {
+                tick_devices(bus, ppu, static_cast<uint32_t>(g_pending_cycles));
+                g_pending_cycles = 0;
+            }
+            g_runtime_cycles += gba::kIrqWakeDelayCycles;
+            tick_devices(bus, ppu, gba::kIrqWakeDelayCycles);
+            recompute_event_budget(bus, ppu);
+        }
     }
 
 #ifdef GBA_COSIM
```

**Inputs.** Each route's harness script (`tools/analysis/input/`, or `tools/analysis/open-bios-ab/input/` for `race_gp_finish` and `race_traffic_finish`), converted by the prototype's converter, `harness2replay.py` (harness script to `gbarecomp-keyinput-v1`, one event per key change, frame numbers as in the harness; diagnosis §7.3). P2-02's `tools/replay/script2replay.py` replaces that converter with another header and frame convention, so with it these commands change. The Cult-of-GBA side is shifted by −207 frames first:

```sh
python3 -I harness2replay.py tools/analysis/input/ROUTE.txt > traces/ROUTE_retail.csv
python3 -I tools/analysis/open-bios-ab/shift_script.py tools/analysis/input/ROUTE.txt traces/ROUTE_cult.txt --by -207
python3 -I harness2replay.py traces/ROUTE_cult.txt > traces/ROUTE_cult.csv
```

**Runs.** Each from a fresh output directory, with the replay applied at VBlank start by the prototype's diagnostic patch:

```sh
export SDL_AUDIODRIVER=dummy SDL_VIDEODRIVER=dummy GBARECOMP_SELFHEAL_RECOMPILE=0
export MRA_OVERLAY_MODE=select MRA_OVERLAY_STATS=1        # prototype: overlay selector, stats at exit
export GBARECOMP_DIAG_VBLANK_REPLAY=1                      # prototype diagnostic patch: replay at VBlank start
export GBARECOMP_DIAG_SHOT_DIR=$PWD/shots GBARECOMP_DIAG_SHOT_EVERY=1000
export GBARECOMP_INPUT_REPLAY=traces/ROUTE_retail.csv      # or ROUTE_cult.csv
export MRA_HALT_EXIT_FIX=1                                  # 0 or 1; read only by the builds with the change
export GBARECOMP_SWI_LOG=$PWD/swi.csv                       # gbarecomp's SWI log (src/armv4t/runtime_arm.cpp:576)
export GBARECOMP_STRICT_STATIC=1                            # strict runs only
BUILD/MraProto --bios BIOS --rom ROM --frames N --no-window \
  --save-path $PWD/game.sav PROTOTYPE_GAME_CONFIG           # the prototype's v0_base.toml
```

| Route | Retail BIOS, stock build: N | Cult-of-GBA BIOS, build with the change: N | Modes |
|---|---|---|---|
| `boot_to_race` | 4,400 | 4,193 | strict |
| `full_race_cross` | 25,000 | 24,793 | strict; also retail with the change, N = 25,000, `MRA_HALT_EXIT_FIX=1`, strict |
| `race_gp_finish` | 19,500 | 19,293 | strict and not strict |
| `race_traffic_finish` | 19,000 | 18,793 | strict and not strict |
| `options_save` | 3,800 | 3,593 | strict and not strict |
| `multiplayer_lobby` | 3,500 | 3,293 | strict and not strict |
| boot only (`boot_to_race` replay) | | 300, `MRA_HALT_EXIT_FIX=0`, not strict | |

Every Cult-of-GBA run in the table has `MRA_HALT_EXIT_FIX=1` except the last row. What section 9 reads from each run: the end-of-run banner lines (`final_pc`, `self_heal_coverage`, the strict-mode abort message), the `mra_halt_exit_fix` line, the miss list `recomp_master_misses_A9MP.toml.frag` that a non-strict run writes in its directory, `swi.csv`, and the SHA-1 of `game.sav`.

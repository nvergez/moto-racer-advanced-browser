# Phase 2 routes: menus, unlocks and race state

**Date:** 2026-10-11
**Scope:** What the route manifest of [phase2-plan.md](../phase2-plan.md) P2-04 relies on: which Solo modes a fresh save opens, how the cup route reaches the Championship, and which RAM bytes tell the races of a route apart. The manifest is [tools/difftest/routes.toml](../../tools/difftest/routes.toml); the scripts are in [tools/analysis/input/](../../tools/analysis/input/).
**Status:** mGBA harness runs and static reading of the ROM. Nothing was run on gbarecomp for this document, except where a diagnosis prototype run is cited.

## Pins

| | |
|---|---|
| ROM | Moto Racer Advance (Europe) `A9MP`, SHA-1 `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0` |
| BIOS | retail, SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492` |
| Reference | libmgba 0.10.5 through `tools/analysis/harness` (real BIOS boot, fresh empty save unless stated) |
| Static reading | the Ghidra 12.1.4 project of `tools/analysis/ghidra` (`DumpFunction.java`), and byte reads of the ROM with Python |

Frame numbers are harness frames ([tools/analysis/README.md](../../tools/analysis/README.md), "Frame numbering"). "Save offset X" is byte X of the 0xCD0-byte save block ([phase1-findings.md](phase1-findings.md) section 1); the front end keeps it in RAM at `0x0203F000 + X` (section 3). Labels as in [phase2-diagnosis.md](phase2-diagnosis.md): **verified**, **likely**, **unverified**. Screenshots were looked at locally and are not committed.

## Summary

- On a fresh save, Single race and Progression are open; Championship and League are locked. This answers question 16 of [game-facts.md](game-facts.md) for the Solo menu. **Verified.**
- The game has its own unlock code: on the main menu, hold L and press A, UP, B, DOWN. It sets the save's championship and league unlock bits (and two other unlock words) in RAM. The cup route uses it, so the cup starts from a fresh save and no save file is needed. **Verified.**
- The Cross Rookie championship has three races (Kenya, Texas, France). Open-loop inputs that hold A finish every race in 8th place, and the cup completes. **Verified.**
- Race-index and results bytes: the selected track (`0x0203F00A`), the number of races completed in the cup (`0x0203FC50`) and the player's cup points (`0x0203FC52`). The manifest requires them in the cup's checkpoints. **Verified** (track, races, points); the final-standing byte `0x0203FC51` is **likely**.
- No RAM field was found for the finishing position and time of a single race. P2-19 needs one (**unverified**, section 6).

## 1. Solo modes on a fresh save

The Solo menu's enable mask is built at `0x08000E18`-`0x08000E40` from save offset 0x1B (a byte) and save offset 0x2A (a halfword):

```
mask = (save[0x1B] == 0) ? 0x9 : 0x1      ; bit 0 Single race, bit 3 Progression
if (save16[0x2A] != 0)    mask |= 0x2     ; Championship
if (save16[0x2A] & 0x200) mask |= 0x4     ; League
```

The generic menu code passes bit i of the mask to the call that draws item i (`0x08007C88`-`0x08007CA4`; the mask is the word at `+4` of the menu block at `0x0203CEB4`), and the screenshots show the items whose bit is clear hatched.

| Check | Evidence | Status |
|---|---|---|
| The mask is `0x9` on a fresh save | `--watch-write 0x0203CEB4-0x0203CEF7`: `0x08007A2C` writes `0x00000009` to `0x0203CEB8` at frame 2733, when the Solo menu opens | verified |
| Championship and League are drawn hatched and A on them does nothing | screenshots of a scratch route at frames 2846-3176 (DOWN, A on each) | verified |
| Save offset 0x2A is 0 on a fresh save | `--trace-mem 0x0203F02A:2` on `boot_to_race.txt`: 0 on every frame | verified |
| Cross starts with two open tracks, Kenya and Texas; GP and Traffic with one each (California, Moscow) | Cross track-select screenshot at frame 4608 of `abort_race.txt` (two tracks open, four locked); GP and Traffic from the README's script table | verified (Cross); GP and Traffic as recorded in Phase 1 |

So the Championship cannot be reached from a fresh save by menu inputs alone. In play it is presumably opened by results in Progression; that rule was not traced, and open-loop inputs that hold A finish 8th (`full_race_cross.txt`), so reaching it by play in the harness was not attempted (**unverified**).

## 2. The unlock code

The key reader `0x08002370`, which the menus call once per frame, also checks for codes:

- It does so only while the word at `0x0203CE3C` is non-zero. The main-menu function `0x08005658` sets it to 1 on entry (`0x08005664`) and clears it when it returns (`0x08005948`); nothing else was seen writing it. On `boot_to_race.txt` it is 1 on frames 2524-2732.
- While L is held, each new key state other than L alone is recorded (`0x080023C0`-`0x08002408`). After four, the four are compared with ten codes at `0x02000100` (front-end `.data`, loaded from ROM `0x08158C00`), and with R held instead of L, with four codes at `0x02000150`. A match calls `0x080003E8` with the code's index.
- Code 0 is A, UP, B, DOWN (the halfwords `0x0001 0x0040 0x0002 0x0080` at ROM `0x08158C00`). In `0x080003E8`, case 0 ORs `0x0FFF` into save offset 0x2A, and `0x3FFFF` into the save words at offsets 0x30 and 0x34 (`0x0800043C`-`0x08000464`). What 0x30 and 0x34 hold (tracks, bikes?) is **unverified**.
- Code 9 does what code 0 does and also sets byte 1 of all twelve cup records to 0 (section 3). The other twelve codes set bits at save offsets 0x1F, 0x20, 0x24, 0x28, 0x30 and 0x34. The routes use none of them, and their effects in the game were not checked.

**Harness check (verified).** In `cup.txt`, L is held from frame 2715 and A, UP, B, DOWN are tapped with L held: save offset 0x2A (`0x0203F02A`) goes from `0x0000` to `0x0FFF` at frame 2761. The main menu does not act on those keys: its handler compares the whole key state with single keys (`0x08005750`-`0x08005790`), so L+A is not A. The Solo menu then has all four modes enabled, Championship offers Cross, GP and Traffic, and Cross offers Rookie, Pro and Reverse (screenshots at frames 2974-3280 of a scratch run).

The unlock is made in the RAM copy of the save. It reaches SRAM at the next save, which in the cup route is after the first race: the route's final save has `0x0FFF` at offset 0x2A.

**Why this instead of a generated save.** P2-04 offered two ways to start the cup: play to the Championship from a fresh save, or a save generated by a committed script. The code gives a third, simpler one: the cup route starts from a fresh save, the game makes every change itself, and no save file is involved. The trade-off is that everything is unlocked, which a player would not have after one cup. The owner decides (phase2-plan.md, decision 3).

## 3. The save block in RAM

The front end keeps the save block at `0x0203F000`-`0x0203FCCF` (Phase 1: "the front end keeps a block loaded from SRAM at `0x0203F000`"). After `options_save.txt`, the 3,280 bytes of `.sav` written at frame 3415 and the RAM block at frame 2846 differ only at offset 0x02 (an Options cursor), 0x17 (the language), the checksum at 0xCC8 and the word at 0xCCC, which the main-menu loop increments (`0x08005744`-`0x0800574C`); so the RAM block is the save. The manifest's fields:

| RAM | Save offset | Meaning | Evidence | Status |
|---|---|---|---|---|
| `0x0203F00A` | 0x0A | id of the selected track, 6 per discipline: 0 Kenya, 1 Texas, 2 France, 6 California, 12 Moscow | written by the single-race track select at `0x08005F20` (`race_gp.txt`: 6 at frame 3008; `race_traffic.txt`: 12 at 3020; `two_races.txt`: 1 when RIGHT selects Texas, frame 4610) and by the championship from its cup table (`0x08001160`, `0x08000AB8`; 0, 1, 2 in `cup.txt`). The front end reads it at `0x0800212C` just before it hands over to the race program (`race_gp.txt`, frame 3328) | verified |
| `0x0203F017` | 0x17 | language: 0 English, 1 Français | `0x08009B70` writes 1 at frame 3049 of `options_save.txt`; the boot of `boot_with_save.txt` loads 1 at frame 596 and skips the language menu | verified |
| `0x0203F01B` | 0x1B | 1 while the multiplayer screens run | set at `0x08001400` (frame 2773) and cleared at `0x08001758` (frame 3262) in `multiplayer_lobby.txt`; read by the Solo-menu builder (section 1) | verified as an indicator; its exact meaning is **unverified** |
| `0x0203F02A` | 0x2A | championship and league unlock bits: bit 3d opens discipline d (0 Cross, 1 GP, 2 Traffic) in the Championship, bits 3d+1 and 3d+2 its second and third cup, bit 9 the League | discipline menu `0x08000F50`-`0x08000F74`, cup menu `0x0800098C`-`0x080009A4` (cup 0 always open once the discipline is) | verified for the masks; which bit a player earns first is **unverified** |
| `0x0203FC50` | 0xC50 | races completed in the Cross Rookie cup | cup record k is at 0xC50 + 10k; `0x080010A4` and `0x0800094C` compare byte 0 with the cup's race count. In `cup.txt` it goes 0, 1, 2, 3 at frames 24532, 44432, 62032, when A leaves each standings screen | verified |
| `0x0203FC51` | 0xC51 | 8 until the cup is completed, then the player's final standing, 0-based | 8 in all twelve cup records of a fresh save (the options save); 7 at frame 62032, when the final standings show the player 8th of 8 | the write is verified; the 0-based reading is **likely** (one data point) |
| `0x0203FC52` | 0xC52 | the player's points in the cup; 0xC53-0xC59 are CP1-CP7's | written when the front end takes over after each race (22404, 42308, 59864). After race 1, 0xC52-0xC59 are 1, 3, 2, 5, 4, 8, 6, 7, which is the race-complete screen's "+1" for PLR and "+3, +2, +5, +4, +8, +6, +7" for CP1-CP7 | verified |
| `0x0203CE3C` | (not in the save) | 1 while the main menu runs | section 2 | verified |

## 4. The Cross Rookie cup

**Cup table.** `0x02000530` (front-end `.data`, from ROM `0x08159030`) holds 12 cups of 15 bytes: k = 3d + 0, 1, 2 for discipline d's Rookie, Pro and Reverse cups, and k = 9-11 for the leagues. Byte 2 is the number of races and the bytes from 3 on are track ids (read at `0x08001094`-`0x080010A8` and `0x08000954`-`0x08000964`). Cross Rookie (k = 0) is 3 races on tracks 0, 1, 2. The track byte takes those values in `cup.txt` before each race (section 3). **Verified.**

**Points.** 8 points for 1st down to 1 for 8th: the race-complete screen of race 1 lists `+8` to `+1` in finishing order, and the bytes at 0xC52-0xC59 match it (section 3). **Verified** on one race.

**Screens after a race**, each waiting for A (the A held through the race does not count: the screens act on a new press, as `full_race_cross.txt` already showed with its "Try again" screen):

1. race complete k/3 (points of the race);
2. the cup standings; leaving it records the race (save offset 0xC50);
3. after race 3 only: the cup result ("Try again" when the player is last);
4. the track's best laps, then its best race times. On a fresh save these tables hold 2'00"00 per lap and 6'00"00 per race, so the player's times enter both, with "PLR" as the name (laps of 1'11" to 1'42" in the screens seen; each race display lasts 3.9 to 5.3 minutes, countdown included);
5. leaving the best-race table saves to SRAM (3,280 bytes each time, at frames 25132, 45032 and 62932; `--watch-write 0x0E000000-0x0E00FFFF`);
6. races 1 and 2: continue / restart / exit, then bike and gearbox, then the next race. After race 3: back to Rookie / Pro / Reverse.

So between races the route taps A seven times (five after race 3). If an engine's player were slow enough to miss the default records, step 4 might show different screens (**unverified**; the margin is at least 18 s per lap).

**Timeline in mGBA** (`cup.txt`):

| Race | Track | Race display | A held from | Display ends | A released | Recorded |
|---|---|---|---|---|---|---|
| 1 | Kenya (0) | 3593 | 3700 | 22384 | 24200 | 24532 |
| 2 | Texas (1) | 26079 | 26190 | 42288 | 44100 | 44432 |
| 3 | France (2) | 45980 | 46090 | 59844 | 61700 | 62032 |

The route ends at 63542, on the Rookie / Pro / Reverse menu. The player is 8th in every race (+1 point each) and 8th in the final standings with 3 points. Two runs give byte-identical `trace.tsv` and saves.

## 5. Timing choices for open-loop inputs

**Start.** Holding A from the camera fly-in makes the race independent of the exact frame where the start lights go out. With A held from 3600 or from 3700 (race display from 3593, lights out about 300 frames later), race 1 of the cup ends on the same frame, 22384. Held from 3880, 3900, 3905 or 3950 instead, it ends at 22427, 22447, 22452 and 22497. The cup holds A about 110 frames after each race display starts. **Verified** on race 1.

**End.** gbarecomp ends races on other frames than mGBA (diagnosis section 6). In the iwram-overlays prototype's 25,000-frame `full_race_cross` run (gbarecomp, overlay selector, screenshots every 50 frames), the race time is 4'50"26 and the "Try again" screen is up by frame 21600; in mGBA, 4'54"36 and frame 21813. That is about 4 s earlier, measured on the prototype and not re-run here. The cup releases A 1,800 frames (30 s) after each mGBA race display ends, then taps A every 300 frames on screens that wait for input. A run whose race ends any time earlier, or up to 30 s later, lands every tap on the same screen. Whether 30 s is enough is measured in P2-09; the routes.py "slack" column shows the margin of each checkpoint.

## 6. Race-index and results checkpoints

The final review of the Phase 2 plan (PR #7) pointed out that DISPCNT and the resident image look the same for every race, so a run that picked the wrong track would still follow a route checked only on them. The cup's checkpoints therefore require:

- in each race-display event, the track (`track == KENYA`, `TEXAS`, `FRANCE`) and the number of races already completed (`cross_rookie_races == k - 1`);
- after each race, a result: `cross_rookie_points >= k` once the front end is back (every finishing position gives at least 1 point, so this does not depend on the position);
- the race being recorded (`cross_rookie_races == k`).

Values that depend on the race outcome (the points after each race, the final standing) are `expect` entries: compared with mGBA as results (P2-19), not required to follow the route.

`two_races.txt` uses the track byte in the same way (Kenya, then Texas), and the single-race routes check it before the race loads.

**Not found.** The finishing position and the time of a single race (`full_race_cross.txt`) are not in any field above. The race program shows them on its HUD and result overlay, and the best-lap and best-race tables in the save hold the times that enter them. P2-19 has to find a reliable source for per-race results (**unverified**).

## 7. Restart and abort

- **Restart** (pause, DOWN, A) stays in the race program: the word at `0x03000000` stays `0xE3A00640`, DISPCNT is 0 at frame 4286 and `0x1741` again from 4304, and the race starts over with the timer at zero (`restart_race.txt`). **Verified.**
- **Abort from boot.** `abort_race.txt` now starts from boot instead of the mid-race savestate. It gives the same events as before: the race program writes `0xFFFFFFFF` four times to `0x03007B00` at frame 4298 (`--watch-write 0x03007B00-0x03007B0F`, PC `0x0815A03E`), and the front-end image is resident from 4303. **Verified.**

## 8. A harness fix

A script that ends with `end` before the `--frames` count made the harness loop forever: `end` stops `runFrames`, and the loop that runs up to `--frames` never advanced. `end` now stops the run, as the README says. Runs that did not hang are unchanged. The route runner checks that every run ends exactly at the manifest's frame count.

## Reproducing

```sh
tools/analysis/harness/build.sh
tools/difftest/mgba-routes.sh            # every route, twice each, about 3 minutes
tools/difftest/mgba-routes.sh cup        # one route
python3 -I -m unittest discover tools/difftest/tests
```

The section 1-3 checks used the harness options named in each row (`--watch-write`, `--watch-read`, `--trace-mem`) on the committed scripts or short scratch variants of them, and `tools/analysis/ghidra/ghidra_run.sh DumpFunction.java ADDR` for the code.

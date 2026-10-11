# Phase 2 replays: the frame convention, and boot_to_race on the interpreter

**Date:** 2026-10-11
**Scope:** P2-02 of [phase2-plan.md](../phase2-plan.md). How gbarecomp replays the harness's input scripts at VBlank start, how the frame convention was checked, what gbarecomp's interpreter gives on `boot_to_race` against mGBA with it, and the BIOS-interpreting reference of comparison 1. The tools are described in [tools/replay/README.md](../../tools/replay/README.md).

## Pins

| | |
|---|---|
| ROM | Moto Racer Advance (Europe) `A9MP`, SHA-1 `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0` |
| BIOS | retail, SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492` |
| gbarecomp | `5e89943528aee7bc1c399bdbd035364a4b41dd10` with patches 0001-0005 (`main` at `80ad57c`); `file:line` citations are at the pin unless they name a patched line |
| Game config | `game.toml` of `main` at `80ad57c`, unchanged: IWRAM code interpreted |
| mGBA | libmgba 0.10.5 (`26b7884`) through `tools/analysis/harness` at `80ad57c` |
| Machine | Apple M4 Pro, macOS 26.5.2; native runs headless with `SDL_AUDIODRIVER=dummy`, `GBARECOMP_SELFHEAL_RECOMPILE=0` and a fresh save |

"Interpreter" is gbarecomp with `GBARECOMP_FORCE_INTERP=1`; "BIOS reference" is the interpreter with `MRA_INTERP_BIOS=1` as well (section 4). Frame numbers are harness frames. Captures are P2-03's (`GBARECOMP_CAPTURE` and the harness's `--capture`, both with `tools/capture/spec.txt` and the route fields of `routes.py trace-mem`); they were joined with `tools/capture/capture.py join`. Raw frames and capture files stayed in a scratch directory and were deleted after use.

## 1. The convention

**A replay line `N,0xKEYS` means: KEYINPUT reads KEYS during harness frame N**, the frame whose completion moves mGBA's frame counter from N-1 to N. The harness sets the keys of frame N before it emulates it, that is right after the VBlank start that ends frame N-1, and `trace.tsv` shows them in row N (`tools/analysis/README.md`, "Frame numbering"; `gbaharness.c`, `runFrames`: `setKeys` then `runFrame`, then the row of the new frame counter). The file starts with the line `mra-keyinput-v1`; the format is at the top of `tools/replay/script2replay.py`.

**gbarecomp applies it at the same point.** `src/main.cpp` installs `RunOptions::input_frame` when `MRA_REPLAY` is set. gbarecomp calls it from the device tick when VBlank starts, after the framebuffer latch and the VBlank-timed DMA and before `request_irq(IrqVBlank)` (`src/runtime/runtime_bus_bridge.cpp:597-604`, installed at `src/runtime/runtime.cpp:2424-2431`), with `TouchFrameInfo::frame_count`, the PPU's `frame_count()` (`runtime.cpp`, `run_touch_policy`). A VBlank-start capture taken at `frame_count` k is harness frame k+1 (diagnosis §7.3; P2-03's capture numbers its records so), so the callback returns the keys of frame k+2, the frame that starts there. The VBlank-timed DMA runs before the callback in gbarecomp and 3 cycles after the keys are set in mGBA; the game enables no VBlank-timed DMA on the routes scanned ([phase2-capture.md](phase2-capture.md) §1), and a DMA could not read the keys anyway.

**The prototypes.** All three converters simulate the harness's script commands the same way and write the same key changes; they number them differently, for two ways of applying them:

| Prototype | Number written for the keys of harness frame N | Applied |
|---|---|---|
| iwram-overlays (`harness2replay.py`, its diagnostic patch) | N-1 (the frame counter while the harness sets them) | at VBlank start, once `frame_count + 1` reaches the number: the convention above, written one lower |
| runtime-bugs (`harness2replay.py`) | N-1 | stock `GBARECOMP_INPUT_REPLAY`: from the run loop once `frame_count` reaches the number |
| ppu-diffs (`mkreplay.py`, from `trace.tsv`) | N-1 or N-2 | stock replay; N-2 matched best (diagnosis §7.3) |
| web-abort (`replay_boot_to_race.txt`) | N | stock replay |

`tools/replay/script2replay.py` keeps the harness-command simulation of the first two (now also for `--frames`, `end`, `until` in the past and malformed lines) and writes harness frame numbers, so that a replay line, a `trace.tsv` row and a capture record share one number. Its `--check` mode compares a replay with `trace.tsv`'s `keys` column, which is how the convention was checked on the mGBA side.

**Checked on every route** of the manifest. Each route converted with `--route`, run in the harness with `--frames` and `--trace 1-<frames>`, then `script2replay.py --check`:

| Route | Frames checked | Frames with other keys |
|---|---|---|
| `boot_to_race` | 4,400 | 0 |
| `full_race_cross` | 25,000 | 0 |
| `race_gp`, `race_traffic` | 6,000 each | 0 |
| `abort_race` | 5,232 | 0 |
| `restart_race` | 5,500 | 0 |
| `two_races` | 6,828 | 0 |
| `options_save` | 3,644 | 0 |
| `boot_with_save` | 2,906 | 0 |
| `multiplayer_lobby` | 3,392 | 0 |
| `cup` | 63,542 | 0 |

So the converter gives every frame the keys the harness gives it. Whether gbarecomp then applies them on the right frame is what section 3 measures.

**gbarecomp's own replay refuses the format**: `GBARECOMP_INPUT_REPLAY=build/replays/boot_to_race.csv` stops with `[gbarecomp:runtime] invalid input trace line: mra-keyinput-v1`, exit code 1 (`runtime.cpp:3267-3279`).

## 2. The hooks in `src/main.cpp`

- **Off unless set.** A 60-frame boot without `MRA_REPLAY` prints no `touch_policy` line and no line of ours; with `MRA_REPLAY` it prints `mra_replay=../replays/boot_to_race.csv events=19 frames=2451-4021` and gbarecomp's `touch_policy=ENABLED claims=0x0`, and the final line is the same (`final_pc=0x00000348 ... cycles=12406950 ppu_vcount=160 ppu_frames=60`). CI checks both halves without the game, in `scripts/repro-test.sh`, whose executables are our `src/main.cpp` on synthetic ROMs: each run without `MRA_REPLAY` must print no `touch_policy` line and no line of ours, and a 60-frame run with a one-event replay must print `mra_replay=` and `touch_policy=ENABLED claims=0x0`. The smoke test's host never gets that far (it stops at the missing BIOS, before gbarecomp installs `input_frame`), so it checks only that our executable prints no line of ours when no variable is set.
- **Refused values** stop the executable before the game starts, with exit code 2 and a line starting `mra: `: a missing file, an empty file, a first line other than `mra-keyinput-v1` (a `# gbarecomp-keyinput-v1` file included), a malformed event (`10, 0x3FE`), frame 1, keys above `0x03FF`, frames out of order, an unknown embedded route, `MRA_REPLAY` with `GBARECOMP_INPUT_REPLAY` (gbarecomp suspends `input_frame` during its own replay, `runtime.cpp:2357-2358`), `MRA_INTERP_BIOS` set to anything but `0`, `1` or nothing (`false`, for example), and `MRA_INTERP_BIOS=1` without `GBARECOMP_FORCE_INTERP`. `GBARECOMP_FORCE_INTERP` itself is read as gbarecomp reads it (`runtime.cpp:1606-1607`: on when not empty and not starting with `0`). Accepted: CRLF line endings, comments, blank lines, lower-case hex, and a file with no events. Each case was run on the game; the smoke test runs most of them in CI.
- **The browser is not covered yet.** The bundle links gbarecomp's own `packaging/web/main.cpp` until patch 0008 (P2-12), so our `input_frame` does not reach it, and that it works there is **unverified**. Likely, though: `input_frame` is installed through the same `runtime_set_vblank_input_hook` that the iwram-overlays prototype's diagnostic replay used, and that prototype played `full_race_cross` in headless Chromium from an embedded trace to `self_heal_coverage=FULLY_STATIC` and exit 0, with 500 sampled frame CRCs equal to the native run's (its `runs/web/select_full.log`). The touch-policy wrapper around the hook was not in that run.

## 3. `boot_to_race`: gbarecomp's interpreter against mGBA

Runs: the harness with `--script tools/analysis/input/boot_to_race.txt --frames 4400 --capture ...`, and the interpreter for 4,400 frames with `MRA_REPLAY` set to the replay at offset 0 and, to see how a wrong convention shows, at offsets -1 and +1 (`script2replay.py --offset`). All three interpreter runs exit 0 with `FULLY_STATIC dispatch_misses=0` and stop at `ppu_vcount=0 ppu_frames=4400`, in about 19 s each; the offset-0 run ends with `cycles=425568482`, the final cycle count the diagnosis measured with the prototype's VBlank-start replay (§7.1).

**The interpreter reaches the race and follows the route** (`routes.py check boot_to_race`):

| Checkpoint | mGBA | Offset 0 | Offset -1 | Offset +1 |
|---|---|---|---|---|
| `main_menu` | 2524 | 2524 | 2523 | 2525 |
| `race_image` | 3290 | 3291 | 3290 | 3292 |
| `race_display` | 3303 | 3304 | 3303 | 3305 |

At offset 0 the front end follows mGBA frame for frame (the main menu on the same frame), and the race program starts one frame late, as in diagnosis §6. At offset -1 every event moves one frame earlier, the main menu too; the race events land on mGBA's frames only because the two shifts cancel.

**Exact frames (equal `fb`) by offset** (the diagnosis measured 818 and 226 in 2400-4005 with the stock replay at harness frame - 2 and - 1, §7.3):

| Frames | Offset -1 | Offset 0 | Offset +1 |
|---|---|---|---|
| 2400-4005 | 283 | **826** | 321 |
| Front end after the first input, 2451-3289 (839 frames) | 201 | **769** | 265 |
| Race, 3290-4400 (1,111 frames) | 31 | 6 | 5 |
| `ram_ewram` equal, 2451-3289 | 64 | **834** | 119 |

A one-frame error in the convention costs two thirds or more of the front-end matches, so it cannot pass unnoticed. Race frames differ at every offset: races leave lockstep with mGBA (diagnosis §6, P2-13).

**Front-end frames whose CRC differs at offset 0.** Of frames 1-3289, before the race image arrives at 3290, `fb` differs on 427: 421 for causes the diagnosis describes, and 6 (2968-2973) for one it does not. Method: both engines re-run with raw frames and full line records of those frames (`GBARECOMP_CAPTURE_RAW`/`_LINES`, `--capture-raw`/`--capture-lines`; the per-frame files stayed byte-identical to the runs without them), pixels compared at 5-bit precision, line records compared with `capture.py lines`.

| Frames | Count | Line state | Pixels | Cause |
|---|---|---|---|---|
| 16-23, 134-175, 297-324, 568-606, 609, 611-638, 1002-1030, 1032-1059, 1363-1392, 1397-1414, 2167-2187, 2190-2217 | 300 | equal | every differing pixel 1 step off, only on lines whose BLDCNT selects an effect | blend arithmetic, diagnosis §5.2 |
| 220-269 | 50 | equal | 3,622 pixels on every frame, 1 to 31 steps | OBJ ignores BLDCNT bit 4 (BIOS logo, BLDCNT `0x3FBF`), §5.1 |
| 2453-2481, 3258-3289 | 61 | equal | up to 30 steps; 115 to 944 pixels more than one step off per frame on the title fade-out, 770 to 4,442 on the menu fade-out | the same bug on the game's fades: BLDCNT `0x00FF` (darken, OBJ a 1st target), BLDY 1 to 15 |
| 607, 610, 1031, 1393-1395, 2188, 2482-2483, 2498 | 10 | differs: OAM, PAL, VRAM, BLDY or BG0CNT on some lines | | mid-frame writes landing on other lines, §5.4 |
| 2968-2973 | 6 | equal, except PAL on line 25 of 2972 | 28 to 319 pixels, up to 29 steps, all in x 16-43, y 125-137 | see below; cause **unverified** |

- For the 111 frames of the OBJ rows, every pixel off by more than one step is the brightness effect missing: mGBA's value equals the brightened or darkened gbarecomp value (GBATEK's formula with the line's BLDY, ±1 step), 100% of those pixels on every frame. On six sampled fade frames (2460, 2470, 2480, 3260, 3270, 3289) every such pixel lies inside a visible OBJ, all of them normal (not semi-transparent) OBJs, from the harness dumps' OAM. That is §5.1's bug: gbarecomp applies color effects to OBJ pixels only when the OBJ is semi-transparent, and ignores BLDCNT bit 4. The diagnosis measured frames 1-2,717 of a boot without input, so it saw only the BIOS logo; the game's own fades (title to language menu, and the last menu to the race) have it too, and P2-08's patch should take all three away.
- 2482-2483 are the switch from the title to the language menu (DISPCNT `0x1444` to `0x1541` at 2481); 2483 is not in §5.4's list, which has 2482.
- 2968-2973 are in §5.4's list as a menu icon's palette written mid-frame, but here the line state is equal on every line except line 25 of 2972, so the render inputs are the same in both engines. The pixels differ only where OBJ 0 (OAM index 0, priority 2) and OBJ 6 (index 6, priority 0, transparent at those pixels) overlap BG2 (affine, 256 colors, priority 1), from the harness dump at frame 2968. At four sampled pixels of 2968, mGBA's colors are OBJ 0's (from the dump's OBJ VRAM and palette) and gbarecomp's are BG2's (from the dump's BG VRAM and palette and the line records' BG2 registers). That fits mGBA drawing OBJ 0's pixel with OBJ 6's priority, in front of BG2, where gbarecomp uses OBJ 0's own priority, behind it. Which matches hardware is **unverified**. gbarecomp's HLE and LLE renderers (`scripts/build-native.sh --lle`) give identical captures on all 4,400 frames, so it is not specific to one renderer. P2-09 classifies it.

Other columns over frames 1-3289, for P2-09: `DISPCNT`, all memory fields, the FIFO columns and `halt_writes` are equal on every frame; `ram_ewram` differs on 21 frames (294-295, 596-606, 608-609, 2155, 2482, 3286-3289), `ram_iwram` on 607, `io_writes` on 1393-1394, and `ram_iwram_stacks` on 891 frames from 295 on. Up to 2450 these are the frames P2-03 found on a boot without input. `lines` differs without `fb` on 45 frames (1, 294, 296, 1864, 1873, 2149, 2157, 2165, and 37 menu frames from 2490 to 3254).

## 4. The BIOS-interpreting reference

With `GBARECOMP_FORCE_INTERP=1` alone, an interpreted SWI enters the recompiled BIOS (diagnosis §7.1). `MRA_INTERP_BIOS=1` installs `g_runtime_force_interp_hook`, returning 1 for PCs below `0x4000`, which `dispatch_resolve` consults before the BIOS table (`src/armv4t/runtime_arm.cpp:874-880`) and the run loop and IRQ loop before stepping (`runtime.cpp:2165-2171`, `runtime_arm.cpp:1543-1552`). It needs no engine patch. A force-interp hook installed before it (none is, yet; the iwram-overlays prototype had one) keeps deciding for PCs from `0x4000` on: ours calls it there.

- **No generated loop runs.** With `GBARECOMP_ABORT_AFTER_BRANCHES=0`, which aborts at the first loop branch taken in generated code (`arm_codegen.cpp:465-470` in arm-recomp-core `1f13cdf`), a 600-frame boot with the hook runs to the end (exit 0, `NOT_STATIC dispatch_misses=1 interpreted_insns=477`). Without it, the interpreter aborts with `runtime_trace: branch abort at pc=0x000003D0 target=0x000003C8` right after `dispatch pc=0x00000008` with `lr=0x0801191A`, the game's first `swi 0x07` (DivArm), exit code 134: the diagnosis's measurement, reproduced.
- **On `boot_to_race`** (4,400 frames, replay at offset 0) the BIOS reference and the interpreter give equal `fb`, `lines`, `DISPCNT`, memory fields, `ram_ewram`, `ram_iwram`, `io_writes`, `halt_writes` and FIFO columns on all 4,400 frames. Their final lines have the same `final_pc=0x03000894`, `cycles=425568482`, `ppu_vcount=0` and `ppu_frames=4400`, and differ in `steps`: 256,473,566 for the interpreter, 261,623,358 for the BIOS reference. `steps` counts run-loop steps, one interpreted instruction or one dispatch each (`runtime.cpp:2165-2174`). The interpreter runs a SWI's BIOS routine as recompiled code within the step of the `swi` instruction (`runtime_force_interp_step` calls `runtime_swi`, `src/runtime/runtime_arm_default_aborts.cpp:821-830`; diagnosis §7.1), while the reference steps each BIOS instruction in the interpreter, so it takes 5,149,792 more steps. Both runs repeated with the final `src/main.cpp` of this branch give the same two lines. `ram_iwram_stacks` differs on frame 3303 only, and the clock at the record on 28 frames: by 10 cycles at 3303 and by 1 or 2 cycles on 27 race frames, which is where the VBlank-start event falls between instructions (P2-09 classifies RAM-hash differences between backends). Its banner reads `NOT_STATIC dispatch_misses=1 interpreted_insns=5378`, as in the diagnosis: each BIOS entry is a bridge, so no gate may read this banner. `bridge_insns` differs on most frames for the same reason.

## 5. Embedded replays

`scripts/build-native.sh --replays` compiles all 11 routes' replays in (`script2replay.py --embed`, 10,566 bytes of C++ under `build/replays/`). With `MRA_REPLAY=embedded:boot_to_race`, the interpreter's capture of `boot_to_race` is byte-identical to the run with the replay file, and so is its final line. `embedded:nope` is refused with the list of embedded routes. A build without `--replays` refuses `embedded:` (`this build embeds no replays`). `scripts/build-web.sh --no-regen --dev --replays` built a test bundle under `build/` whose `libgbarecomp_game.a` holds `replay_routes.cpp.o` (`emar t`); the smoke test checks the same for `web/game-lib` on the test ROM's code, with and without the table. Our main will find it there once P2-12 links it in the browser.

## 6. Not done here

- Inputs applied during a long interpreter bridge: P2-05, the first build whose race loop is bridged (moved there by the plan).
- The replay in the browser: P2-12.
- The comparator, its allowlists and the classification of the RAM differences and of frames 2968-2973: P2-09.
- Why races leave lockstep: P2-13.

# Analysis tooling

The scripts used for the Phase 1 investigation ([docs/research/phase1-findings.md](../../docs/research/phase1-findings.md)):

- a headless, deterministic GBA harness on libmgba 0.10.5 that boots through the real BIOS and logs state, writes, reads, executed code, SWIs and audio;
- input scripts that drive it through the game;
- a Ghidra 12.1.4 headless pipeline that imports the ROM with the GBA memory map, maps the RAM code images onto their ROM sources and seeds functions from harness coverage;
- small stdlib-only Python helpers.

**Legal hygiene.** Nothing here contains ROM or BIOS bytes. You supply both. Everything the scripts produce (dumps, traces, screenshots, WAVs, savestates, `.sav` files, Ghidra projects, decompiler output) is derived from the ROM. It goes to `analysis-out/` at the repository root, which is gitignored, and must never be committed. The scripts check every ROM-derived output path they are given with one function, `py/outpath.py`: a relative path resolves under `analysis-out/`, and a path inside the work tree that git would track is refused (after resolving `..` and symlinks). That covers `--out`, `--wav` and `--save` in `run_harness.sh`, the Ghidra project and seed directories, `out=FILE` and `GHIDRA_LOG` in `ghidra_run.sh`, and the Python helpers' output files. It does not cover standard output, absolute `savestate` paths inside input scripts, or `gbaharness` and `analyzeHeadless` called directly. Short excerpts (an address, a few instructions, a register value) are fine as evidence in `docs/research/`.

Every address, frame number and file offset in these scripts refers to one ROM: Moto Racer Advance (Europe), game code A9MP, SHA-1 `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0`. The wrappers check that hash, and the BIOS hash (`300c20df6731a33952ded8c436f7f186d25d3492`, the official BIOS), before running.

| Path | What |
|---|---|
| `lib.sh` | Shared settings: repository root, ROM, BIOS and output paths, pinned hashes, the output-path guard |
| `harness/gbaharness.c`, `harness/build.sh`, `harness/run_harness.sh` | The harness, its build script, and the wrapper that checks hashes and resolves output paths |
| `input/*.txt` | Input scripts (button presses and dump commands only) |
| `ghidra/ghidra_import.sh`, `ghidra/make_seed_data.sh` | Build the Ghidra project |
| `ghidra/ghidra_run.sh`, `ghidra/*.java` | Run queries against it |
| `py/*.py` | Screenshot sheets, VRAM rendering, RAM-to-ROM matching, the output-path check |

## Setup

Tested on macOS 26 (arm64) with Apple clang 21, cmake 4.4, ninja, Python 3.11 and JDK 24. Linux is untested.

**Inputs.** By default the scripts read `roms/moto-racer-advance.gba` and `bios/gba_bios.bin` at the repository root (both gitignored). `run_harness.sh` and `ghidra_import.sh` take `--rom FILE` and `--bios FILE`; all scripts also read `MRA_ROM` and `MRA_BIOS`. `MRA_OUT` moves the output root (default `analysis-out/`). A guide to dumping both from hardware you own is in [PR #1](https://github.com/nvergez/moto-racer-advanced-browser/pull/1).

**Harness.** `harness/build.sh` clones mGBA tag 0.10.5, checks that it is commit `26b7884bc25a5933960f3cdcd98bac1ae14d42e2`, builds a static GBA-only libmgba (no frontends, no scripting) and compiles the harness:

```sh
tools/analysis/harness/build.sh          # -> analysis-out/bin/gbaharness
```

Override `MGBA_SRC`, `MGBA_BUILD`, `HARNESS_BIN` or `CC` to reuse an existing checkout or build. The binary links `-framework CoreFoundation` on macOS. mGBA.app 0.10.5 cannot load a Lua script from the command line, so it can't be driven headlessly; that is why the harness exists.

**Ghidra.** Install Ghidra 12.1.4 (`ghidra_12.1.4_PUBLIC_20260921.zip` from the official GitHub release; SHA-256 `ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db`) and a JDK 21 or newer. The release ships no macOS arm64 natives (decompiler, sleigh, demangler); build them once with `support/gradle/gradlew buildNatives` in the Ghidra directory. The scripts look for Ghidra in `~/tools/ghidra/ghidra_12.1.4_PUBLIC`; set `GHIDRA_HOME` otherwise. The community GBA loader (SiD3W4y/GhidraGBA) targets Ghidra 10.1 and only creates memory blocks, so it is not used; `GbaSetup.java` does more.

**Python.** Standard library only. Run the helpers with `python3 -I`. The shell scripts need `python3` too: they check output paths with `py/outpath.py`.

## Quick start

From the repository root:

```sh
H=tools/analysis/harness
$H/build.sh
# Boot to a race and dump state (about 1.5 s, deterministic). Relative --out goes under analysis-out/.
$H/run_harness.sh --out runs/race --script tools/analysis/input/boot_to_race.txt --trace 3290-4400 --trace-swi

# Start from the mid-race savestate (frame 4200) and log one frame per scanline
printf 'hold A\nuntil 4202\n' > analysis-out/hold_a.txt
$H/run_harness.sh --out runs/lines --load-state analysis-out/runs/race/mid_race.state \
  --script analysis-out/hold_a.txt --trace-lines 4201 --watch-write 0x04000000-0x04000056

# Ghidra project (about 1 minute), then queries (about 5 s each, safe to run in parallel)
G=tools/analysis/ghidra
$G/ghidra_import.sh
$G/ghidra_run.sh ListFunctions.java block=IWRAM_IMAGE
$G/ghidra_run.sh DumpFunction.java 0x03001CB0
$G/ghidra_run.sh FindRefs.java 0x04000000 len=2
$G/ghidra_run.sh FindSwi.java
```

## Harness

### What it guarantees

- **Real BIOS boot.** The BIOS is loaded with `useBios=1, skipBios=0`. The run aborts unless mGBA reports a full BIOS and the PC after reset is inside it. `summary.json` records the BIOS checksum (`0xBAAE187F` for the official one) and `pc_after_reset`.
- **No user configuration.** The user's mGBA `config.ini` is not read. `idleOptimization` defaults to `ignore`, so busy-wait loops run as on hardware and dominate instruction counts.
- **Deterministic.** Two full runs of `boot_to_race.txt` gave byte-identical dumps and savestates. Stepping mode (`--coverage`, `--calls`, `--trace-pc`) gave the same dumps as plain runs. Resuming from a savestate gave the same dumps as a full replay. Read and write hooks do not change emulation.
- It inherits mGBA 0.10.5's accuracy. Nothing here has been compared with hardware.

### Frame numbering (read this)

- **Frame N** is the frame whose completion moves mGBA's frame counter from N-1 to N. Completion is the start of VBlank (VCOUNT=160). The counter starts at 0 at reset, and savestates carry it.
- A **dump at frame N** is the state right after frame N was drawn: VCOUNT=160, VBlank DMAs triggered but not yet run, VBlank IRQ pending.
- **Events** (writes, reads, SWIs, executed instructions, scanline rows) are tagged with the frame being emulated (counter+1), so VBlank work that prepares frame N counts as frame N.
- **Keys** for frame N are set before frame N is emulated.
- Registers and OAM change mid-frame. In races the game hides OAM entries at precomputed lines and rewrites OAM at VCOUNT 170-174, so a VBlank-start dump shows every sprite hidden. Use `--dump-vcount L`, `--trace-lines` or `--watch-write` for mid-frame state.
- Write-only registers (BGxHOFS, BG2PA-BG3Y, DMA addresses) are reported as mGBA's latched values.

### Input scripts (`--script FILE`)

One command per line; `#` starts a comment. Keys: `A B SELECT START RIGHT LEFT UP DOWN R L`, joined with `+`.

| Command | Effect |
|---|---|
| `wait N` | run N frames with the currently held keys |
| `until F` | run until frame F |
| `press KEYS [N]` | hold KEYS (plus held keys) for N frames, default 6 |
| `tap KEYS [COUNT]` | COUNT times: hold 6 frames, release 6 frames |
| `taptiming ON OFF` | change tap timing |
| `hold KEYS` / `release [KEYS]` | add or remove persistent keys (`release` alone clears all) |
| `dump LABEL` | full dump now (`dumps/fNNNNNN_LABEL/`) |
| `shot LABEL` | screenshot now (`shots/fNNNNNN_LABEL.png`) |
| `mark LABEL` | append `frame<TAB>label` to `marks.tsv` |
| `savestate FILE` | write an mGBA savestate (relative paths go under `--out`) |
| `end` | stop |

Held keys are not part of a savestate: re-issue `hold A` after `--load-state`.

An input given after `until F`, or after a `wait` that ends at frame F, is used for frame F+1, and `trace.tsv`'s `keys` column shows it there: `until 2714` then `tap A` puts A in the rows of frames 2715-2720.

Every script starts from boot. The scripts and their checkpoints are listed in the route manifest (see [Routes](#routes)).

| Script | Path and expected result (fresh save unless stated, checked on 2026-10-11) |
|---|---|
| `boot_to_race.txt` | Title, English, Solo, Single race, Cross, Kenya, Coolfix 250, Auto. Title 2450, main menu 2714, race image installed 3290, race display from 3303, A held from 3608, lap 1 at 3826. Writes `race_running.state` (3800) and `mid_race.state` (4200). |
| `full_race_cross.txt` | Same path, A held to the end. Finishes 3 laps in 8th place; race display ends at 21788, "Try again" screen from 21813. No SRAM write. |
| `race_gp.txt`, `race_traffic.txt` | GP on California and Traffic on Moscow (the only unlocked tracks), with a pause at 4200. Race display from 3346 (GP) and 3358 (Traffic). |
| `options_save.txt` | Options, Language, Français, then B. Writes the 0xCD0-byte save block at frame 3415. Use with `--save FILE`. |
| `boot_with_save.txt` | Boot from the save `options_save.txt` writes (pass a copy with `--save`: the harness writes the run's save back to it). No language menu: the main menu is up at 2484, in French. Solo and back. No SRAM write. |
| `multiplayer_lobby.txt` | The link lobby with no partner. CpuSet (SWI 0x0B) runs about 5 times per frame there, and nowhere else. No SRAM write. |
| `abort_race.txt` | `boot_to_race.txt`'s path up to 4210, then pause, Abort. The race program hands back to the front end at 4298 (front-end image from 4303); Kenya track select at about 4600, then bike and gearbox. No SRAM write. Until 2026-10-11 it started from `mid_race.state`, which gbarecomp cannot load. |
| `restart_race.txt` | Same path up to 4210, then pause, Restart. The race program restarts the race itself (no image switch): display off at 4286, race again from 4304, A held from 4420. No SRAM write. |
| `two_races.txt` | The Kenya race of `abort_race.txt`, then RIGHT on the track select for Texas: race image 5110, display 5123, aborted back to the front end at 6323. Both image switches happen twice. No SRAM write. |
| `cup.txt` | Championship, Cross, Rookie: Kenya, Texas, France. The game's unlock code on the main menu (hold L, then A UP B DOWN) opens the Championship (unlock bits set at 2761). Race displays 3593-22384, 26079-42288 and 45980-59844, with A held from each fly-in; 8th in every race and 8th overall with 3 points. SRAM written at 25132, 45032 and 62932. Ends on the Rookie / Pro / Reverse menu at 63542. See [phase2-routes.md](../../docs/research/phase2-routes.md). |

The boot timeline of `boot_to_race.txt`:

| Frame | State |
|---|---|
| 60-240 | BIOS logo |
| ~300-600 | license screen |
| ~660-2280 | publisher and developer logos, intro animation |
| ~2400-2760 | title, "Press start" (2450: `title` dump) |
| 2522 / 2714 | language menu / main menu |
| 2846-3254 | Solo, Single race, track, bike, gearbox menus |
| 3286-3302 | race program loads (display off) |
| 3303 | first race frame (DISPCNT 0x1741) |
| ~3440-3609 | countdown; rivals leave about 3590-3598 |
| 3826 | start line crossed, lap 1 |
| 4200 / 4300 | on track with rivals (`mid_race` dumps) |

Without steering the bike leaves the road after about frame 4000, but the race keeps running and still finishes.

### Routes

[`tools/difftest/routes.toml`](../difftest/routes.toml) lists every script as a route: its frame count, its starting save (none, or the save another route writes), whether it writes SRAM and the SHA-1 of its final save, and its checkpoints. A checkpoint is a game-state event that both engines' per-frame captures can show (DISPCNT, the first word of the resident IWRAM image, a few RAM bytes such as the selected track), with the mGBA frame where it happens and the frame of the first later input that relies on it. A run of another engine follows the route when every event happens, in order, before that input. The fields and their evidence are in the manifest and in [phase2-routes.md](../../docs/research/phase2-routes.md).

```sh
tools/difftest/mgba-routes.sh            # every route, twice each (about 3 minutes)
tools/difftest/mgba-routes.sh cup        # one route
python3 -I tools/difftest/routes.py check ROUTE TRACE.tsv     # checkpoints of any per-frame trace
python3 -I -m unittest discover tools/difftest/tests          # no game data needed
```

`mgba-routes.sh` runs each route twice from boot, each time from a fresh copy of its starting save, with `--trace 1-<frames>` and a `--trace-mem` column for every RAM field. It checks that the two `trace.tsv` and the two final saves are byte-identical, that the run stops at the route's frame count, that the checkpoints hold on their recorded frames, and that the final save is as the manifest says. Outputs go to `analysis-out/routes/`. The tools need Python 3.11 or newer (`tomllib`).

### Options

```
run_harness.sh [--rom FILE] [--bios FILE] [--no-hash-check] --out DIR [options]
  --script FILE | --frames N               # at least one; --frames also runs past the script end
  --load-state FILE                        # start from a savestate written by the harness
  --save FILE                              # persistent cartridge save (default: fresh, in memory)
  --save-type TYPE                         # force sram|flash512|flash1m|eeprom|eeprom512|none
  --dump-at LIST [--dump-vcount L]         # LIST: 100,200-210,3000+5 (A+LEN)
  --shot-every N | --shot-at LIST
  --trace LIST                             # per-frame row -> trace.tsv
  --trace-io NAMES  --trace-mem ADDR:SIZE,...   # extra trace.tsv columns
  --trace-lines LIST                       # per-scanline register rows -> lines.tsv
  --watch-write RANGES  --watch-read RANGES  [--watch-frames LIST] [--watch-max N]
  --trace-pc RANGES [--trace-pc-regs] [--pc-max N]    # executed instructions -> pctrace.tsv
  --coverage                               # executed address histogram -> coverage.tsv
  --calls                                  # dynamic call targets -> calls.tsv
  --step-frames LIST                       # limit --coverage/--calls/--trace-pc to these frames
  --trace-swi                              # SWI log -> swi.tsv (counts are always in summary.json)
  --openbus VALUE                          # game loads from 0x0-0x3FFF see VALUE (open-BIOS A/B tests)
  --wav FILE                               # stereo s16, 32768 Hz
  --idle ignore|remove|detect              # mGBA idle-loop optimization (default ignore)
  --log-level MASK                         # mGBA log mask to stderr (default 0x7)
```

RANGES are inclusive, `A-B` or `A+LEN`, at most 32 per option. Mirrors are canonicalized: EWRAM to 0x02xxxxxx, VRAM 0x06018000+ to 0x06010000+, SRAM 0x0E/0x0F to 0x0E000000 + (address & 0xFFFF). Relative `--out`, `--wav` and `--save` paths resolve under `analysis-out/`, and a path git would track is refused.

### Outputs (under `--out DIR`)

| File | Content |
|---|---|
| `summary.json` | start/end frame, wall time, ROM CRC32, BIOS checksum, PC after reset, detected save type, mGBA log counts, SWI counts by function, executed instructions by region (with `--coverage`), forced save type and open-bus override if used |
| `marks.tsv`, `index.tsv` | script marks; every dump, shot and savestate with its frame |
| `dumps/fNNNNNN[_vLLL][_label]/` | `screen.png`, `io.bin` (0x400 raw I/O), `io.json` (named registers; decoded DISPCNT, BG0-3, BG2/3 affine, DMA0-3 with timing and mGBA's internal source/destination, timers, SOUNDCNT_H, IE/IF/IME, VCOUNT, save type), `palette.bin`, `vram.bin`, `oam.bin`, `iwram.bin`, `ewram.bin`, `cpu.json` |
| `trace.tsv` | per frame: keys, DISPCNT/mode/page, DISPSTAT, BG0-3CNT, BG2/BG3 affine, BLDCNT, DMA0-3CNT_H, IE, CRC32 of VRAM regions, palette and OAM, bytes written per VRAM 16 KiB chunk, palette, OAM, EWRAM, IWRAM and I/O (CPU and DMA), plus `--trace-io`/`--trace-mem` columns |
| `lines.tsv` | per scanline: DISPCNT, BGxCNT, scroll, BG2/BG3 affine, windows, blend, mosaic (no OAM) |
| `writes.tsv` / `reads.tsv` | frame, vcount, source (`cpu`, `bios`, `dmaN`), pc, mode, lr, most recent SWI and its call site, address, size, old/new value or value. Includes LDM/STM words and DMA transfers |
| `pctrace.tsv` | frame, vcount, pc, mode, opcode [, r0-r15, cpsr] |
| `coverage.tsv` | every executed address in BIOS, EWRAM, IWRAM and ROM, with mode (A, T or AT) and count |
| `calls.tsv` | call targets: `call` = non-sequential PC change with LR = previous instruction + size (BL, `mov lr,pc; bx`, SWI and IRQ vectors); `bx` = BX to an address never seen as a return address. Count, first caller, first frame |
| `swi.tsv` | frame, vcount, SWI address, mode, BIOS function and name, r0-r3, lr |

Performance: boot to frame 4400 with dumps takes about 1.5 s; with per-instruction stepping on every frame about 2.5 s.

### Changes from the Phase 1 working copy

The code that produced the Phase 1 evidence is this one minus the changes below. With the same options, a `boot_to_race.txt` run gives byte-identical dumps, screenshots, `trace.tsv` and `swi.tsv`, and the Ghidra pipeline gives the same project summary (755 functions, 38,475 instructions).

- `--wav` was silent: the empty config left mGBA's master volume at 0. The harness now sets it to full volume. Only audio changes, including the "rendered samples" field of savestates.
- Range lists longer than 32 entries used to be truncated silently; they are now an error.
- New `--save-type` and `--openbus` options, which reproduce two Phase 1 experiments: a missing or Flash/EEPROM save chip (the game shows "Error while saving"), and replacing the BIOS open-bus value (see the findings, section 6).
- A script `end` before the `--frames` count used to hang the harness (the loop up to `--frames` never advanced once `end` had stopped the run). `end` now ends the run there. Runs that did not hang are unchanged.

### Pitfalls

- mGBA routes DMA to 0x0Dxxxxxx straight to its EEPROM model, so `--watch-write` cannot see EEPROM DMA. Watch the DMA registers (0x040000B0-0x040000DF) instead.
- `writes.tsv` "old" values in 0x0E are always 0: the hook has no view of the save chip.
- `calls.tsv` also lists returns from the BIOS IRQ handler (from 0x0000013C) as calls when the banked LR happens to match. A few of those seed bogus function starts in Ghidra (for example 0x0300074C, 0x03000790, 0x03000798 inside the routine at 0x03000340).
- With `--dump-vcount` the dump directory is `fNNNNNN_vLLL`.

## Ghidra

### What the project contains (`ghidra_import.sh`)

1. Raw import: `-loader BinaryLoader -loader-baseAddr 0x08000000 -processor ARM:LE:32:v4t`.
2. `GbaSetup.java`: uninitialized blocks for BIOS, EWRAM, IWRAM, I/O (volatile), palette, VRAM, OAM, 0x0D000000 and SRAM; typed labels for every I/O register (`REG_DISPCNT`, `REG_BG2PA`...), the BIOS words in IWRAM (`BIOS_IRQ_HANDLER` 0x03007FFC, `BIOS_IRQ_CHECK_FLAGS` 0x03007FF8, `BIOS_SOUND_AREA_PTR` 0x03007FF0) and the cartridge header fields; the ARM entry at 0x08000000. Names follow GBATEK and were typed in by hand.
3. `MapRomCopy.java`: byte-mapped blocks that read through to the ROM, for RAM ranges the harness showed to be verbatim ROM copies:
   - `IWRAM_IMAGE` 0x03000000+0x7D84 from ROM 0x083F6820 (race program IWRAM image);
   - overlay `IWRAM_BOOT` 0x03000000+0x834 from ROM 0x081596FC (front-end IWRAM image; address it as `IWRAM_BOOT::0x0300xxxx`);
   - `EWRAM_DATA` 0x02000000+0xBFC from ROM 0x08158B00 (front-end `.data` initial values).
4. Auto-analysis with the default analyzers.
5. `SeedFromHarness.java`: disassembles and creates functions at the call targets and executed addresses from `make_seed_data.sh` (three harness runs of `boot_to_race.txt`), in the mode the CPU used, per game state: ROM from all frames, `IWRAM_IMAGE` from frames 3290-4400, `IWRAM_BOOT` from frames 300-3289.
6. `AnalysisSummary.java` writes `summary.txt`.

Result for the pinned ROM: 755 functions (584 ARM, 171 Thumb), 38,475 instructions. All 10,962 ROM addresses executed on that route were already disassembled in the right mode.

### Running scripts

```
ghidra_run.sh [--project DIR | --copy DIR] [--write] SCRIPT.java [script args...]
```

- Ghidra locks a project even with `-readOnly` (3 concurrent read-only runs: 1 success, 2 `LockException`). So by default `ghidra_run.sh` clones the project (APFS `cp -c` when available) into `$TMPDIR`, runs read-only on the clone and deletes it. Concurrent runs work.
- Script output goes to stdout; Ghidra's log is kept only on failure.
- To keep changes (renames, new functions): `ghidra_run.sh --copy analysis-out/my-proj --write SCRIPT ...` makes a private copy once; later calls use `--project analysis-out/my-proj [--write]`. `--write` on the shared project is refused.
- To rebuild the project, build into a new `MRA_GHIDRA_PROJECT_DIR` and swap directories, so readers never clone a half-written project.

| Script | Args | Output |
|---|---|---|
| `ListFunctions.java` | `[block=ROM\|IWRAM_IMAGE\|IWRAM_BOOT] [min=BYTES]` | TSV: entry, name, ARM/Thumb, size, instructions, block, callers |
| `DumpFunction.java` | `ADDR\|SYMBOL\|SPACE::ADDR [what=both\|disasm\|decomp] [mode=arm\|thumb] [len=BYTES]` | disassembly with bytes, labels and references (literal-pool values resolved), then decompiler C. `len=` dumps a raw range |
| `FindRefs.java` | `ADDR [len=N] [base=ADDR]` | TSV sections: Ghidra references with type, literal-pool words in range and the instructions that load them, immediate operands in range |
| `FindSwi.java` | | every disassembled SWI with its BIOS function (Thumb imm8, ARM bits 16-23); ARM `swi 0x123456` and Thumb `swi 0xAB` are flagged as semihosting |
| `AnalysisSummary.java` | | functions by mode, instruction bytes per block |
| `GbaSetup.java`, `MapRomCopy.java`, `SeedFromHarness.java` | see their headers | used by `ghidra_import.sh` |

`MraOut.java` is a helper class, not a script. Every script takes `out=FILE`; `ghidra_run.sh` checks it like `--out`, so a relative path resolves under `analysis-out/`, not the current directory, and a tracked path is refused. Ghidra bundles its own `ListFunctions.java`, so `ghidra_run.sh` passes scripts by absolute path; do the same if you call `analyzeHeadless` yourself.

### Known issues in the project

Found during Phase 1 and not fixed yet, so the project still matches the one the findings were written against:

- `IWRAM_IMAGE` maps 0x7D84 bytes, but the race loader copies only 0x49C4. The rest is ROM zero padding, which happens to equal the zero-initialized data.
- `EWRAM_DATA` maps the front-end `.data` only. While the race runs, 0x02000000-0x0200071F holds the race program's `.data` from ROM 0x083F6100.
- Auto-analysis also disassembles the race IWRAM image at its ROM load address (85 functions at 0x083F6820-0x083FB1E3) and the front-end image (0x08159EE8-0x08159F2F). That code never runs there.
- Labels alias between the two overlays: a front-end literal can be shown with a race-image label (for example 0x03001378), and `DumpFunction` "value" annotations for `IWRAM_BOOT` data references can show race-image bytes.
- The race routine at 0x03000340-0x0300098F is one function, but the project splits it into five (see the `calls.tsv` pitfall above). The same holds for 0x03000CEC-0x03000DB7.
- The decompiler does not constant-fold literal pools in the writable mapped blocks; `DumpFunction` prints the values in the disassembly.
- Code that exists only in RAM is not mapped (for example the SRAM routines at EWRAM 0x0203D7D4 and 0x0203D734; their ROM sources are 0x0801192C and 0x08011994). Use harness dumps, or `MapRomCopy.java ... overlay=true`.
- A Thumb `BL` is one 4-byte instruction in Ghidra and two 2-byte steps to the CPU; coverage lists both halves.

## Python helpers (`py/`, run with `python3 -I`)

| Script | Use |
|---|---|
| `contact_sheet.py OUT.png 'GLOB' ... [--frames A-B] [--every N] [--cols N] [--scale S]` | tile screenshots with frame labels |
| `render_vram.py DUMPDIR bitmap\|bg N\|tiles\|palette\|oam ...` | render bitmap pages, a whole text or affine BG map (from the dump's BGxCNT), tile sheets, the palette, or list decoded OAM entries |
| `ram_sources.py ROM DUMP --base 0x03000000 [--coverage coverage.tsv]` | RAM ranges that are verbatim ROM copies, and how many executed addresses each covers |
| `pngutil.py` | PNG reading and writing for the above |
| `outpath.py PATH` | The output-path check used by every script: prints the resolved path, or refuses a path git would track |

The PNGs show game graphics, so their output paths get the same check as the shell scripts: a relative `OUT.png` resolves under `analysis-out/`, not the current directory, and a path git would track is refused. Input paths stay relative to the current directory.

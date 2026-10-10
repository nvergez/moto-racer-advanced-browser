# Phase 1 findings

**Date:** 2026-10-10
**Scope:** The Phase 1 questions in [plan.md](../plan.md) and [initial-findings.md](initial-findings.md) that need the ROM: ROM identity, save type, race rendering, compiler and program layout, code running from RAM, sound engine, and BIOS dependencies. Building gbarecomp and measuring its coverage is in [PR #5](https://github.com/nvergez/moto-racer-advanced-browser/pull/5) and not covered here. Ultimate mode was not reached (it is locked on a fresh save).
**Status:** Measured on one ROM in mGBA 0.10.5 with the official BIOS. Nothing has been checked on hardware.

## ROM

Every address, frame number and file offset below refers to this ROM.

| | |
|---|---|
| Title (No-Intro) | Moto Racer Advance (Europe) (En,Fr,De,Es,It) |
| Header | title `MOTORACERADV`, game code `A9MP`, maker `41`, version byte `0x00`, complement `0x4E` (valid) |
| Size | 4,194,304 bytes (exactly 4 MiB; the last 19,996 bytes are 0x00) |
| CRC32 | `8CB19DA0` |
| MD5 | `d3b2ab65c92e18df21788c4b30128041` |
| SHA-1 | `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0` |
| SHA-256 | `049f899b032d52aa7e3ae5ea1d4a443da1e6bcec776980aa7eab2da8636dd68c` |
| No-Intro | Size, CRC32, MD5 and SHA-1 match the Europe entry in [libretro-database](https://github.com/libretro/libretro-database) `metadat/no-intro/Nintendo - Game Boy Advance.dat` at commit `9a899f5b13ed1c355491e342203be29bc573323b` (DAT version 2026.10.07). The same entry is in two earlier commits. That DAT lists one dump per region and no other revision. The USA release (`A9ME`) has a different SHA-1, `351414650E6969C270B1339ADA7B3565CE80374C`. BizHawk's game database (commit `ab81ea25762a`) marks our SHA-1 as a verified good dump. |
| Build tag | `Ubisoft RC2 18-07-2002`, in a block at ROM `0x0816D400` that no code references |
| BIOS used | official GBA BIOS, SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492` (mGBA checksum `0xBAAE187F`) |

Hashes and header fields were recomputed for this write-up with `shasum`, `md5` and Python. The DAT was fetched independently by two verifiers. The DAT has no dump-status field, so "matches No-Intro" means the hashes match.

## How the evidence was produced

1. **Tools.** A headless harness on libmgba 0.10.5 that boots through the real BIOS and logs dumps, per-frame and per-scanline registers, memory reads and writes, executed instructions, SWIs and audio. A Ghidra 12.1.4 project with the GBA memory map, the RAM code images mapped onto their ROM sources, and functions seeded from harness coverage. Both are in [tools/analysis](../../tools/analysis/README.md), with the input scripts used here. The harness is deterministic: repeated runs give byte-identical dumps.
2. **Investigation.** Each of the six questions below was investigated separately and written up as claims with evidence.
3. **Verification.** Each key claim was then attacked twice, independently: once statically (Ghidra plus raw scans of the ROM bytes) and once dynamically (new harness runs and input scripts). Each attempt either failed to refute the claim, or refuted it and stated a corrected claim.
4. **Synthesis (this document).** Status labels in the evidence tables:
   - **verified**: neither attempt refuted the claim, and at least one confirmed it with its own evidence;
   - **corrected**: an attempt refuted part of the claim; the table states the corrected claim;
   - **disputed**: the attempts disagree;
   - **not independently checked**: no refutation attempt was made; the investigator's own label (verified, likely, unverified) is given.
5. **Spot checks for this write-up.** Some results were re-run with the repository's copy of the tools, mainly where the evidence disagreed with itself: the ROM hashes, a full race to the finish (one write-up said no race had been finished, while a verifier had finished three), the options save and its file layout, the forced missing save chip, the open-bus experiment, the GP, Traffic, abort and multiplayer paths, and a rebuild of the Ghidra project. All reproduced; these results are marked "spot-checked".

Unless stated otherwise, runs use a fresh empty save and the route Title, English, Solo, Single race, Cross, Kenya, Coolfix 250, Auto gearbox (`tools/analysis/input/boot_to_race.txt`). Frame numbers are the harness frame counter on that route. Multiplayer with a partner, championship, league, the locked tracks and Ultimate were not exercised. Statements about gbarecomp come from reading its source at the pinned commit `5e89943528aee7bc1c399bdbd035364a4b41dd10`; it was not built or run for this document.

## Headline results

- **Races are pseudo-3D affine backgrounds, not polygons.** Mode 1, with BG2 as a static 1024x1024 texture. HBlank DMA sets the affine scale and offset on every scanline, with no rotation: an OutRun-style road built from hardware affine rows. Bikes, scenery and cars are affine sprites (likely). Nothing renders the scene into VRAM in software.
- **Races already run at 60 Hz** in all three race types tested, with one main-loop iteration per frame. A frame-rate mod is not needed for single-player races.
- **The ROM holds two separately linked programs**, a front end and a race program. They hand control to each other and each installs its own code image at IWRAM `0x03000000`. During a race about 94% of non-idle instructions run from IWRAM. **This shared address range is the main recompilation risk.**
- **Built with ARM's own toolchain** (armcc/tcc, armlink, the ARM C library; likely), not GCC or agbcc. A byte-matching decompilation is impractical. Static recompilation stays the approach.
- **Save: SRAM**, through an SDK-style library tagged `SRAM_F_V102`. The game uses 3,280 bytes. gbarecomp does not recognize that tag, so `game.toml` must set `[save] type = "sram"`.
- **Sound: a custom software mixer** on Direct Sound A (mono, 8-bit, 18,157 Hz). No M4A, so gbarecomp's M4A features do not apply. Its generic sound hardware path is what this game needs.
- **The BIOS surface is small**: six SWIs, none of them sound, math beyond DivArm, or reset functions. But the race calls the BIOS IRQ path about 229 times per frame, and it **reads BIOS memory through a NULL pointer**, so its state depends on the BIOS open-bus value.

---

## 1. ROM identity and save type

**Answer.** The ROM is the No-Intro Europe release (above). The game saves to SRAM-interface memory through a library tagged `SRAM_F_V102` (ROM `0x0801C6D0`). The cartridge chip is 32 KiB according to the sources collected in [PR #4](https://github.com/nvergez/moto-racer-advanced-browser/pull/4); the game uses only the first 3,280 bytes. Every save is a plain byte copy of one 0xCD0-byte (3,280-byte) block to `0x0E000000`, followed by a byte-by-byte verify, retried up to 3 times. There is no Flash or EEPROM protocol, and no password system was found. gbarecomp at the pinned commit does not recognize the tag, so without configuration it would run with no save chip.

| Claim | Evidence | Method | Status |
|---|---|---|---|
| The ROM is the No-Intro Europe dump `A9MP`, not the USA release | Hashes and header above; the game never reads its own header (139 header reads, all by the BIOS at frame 3) | hashing, DAT lookup, harness `--watch-read` | verified |
| The save library ID is `SRAM_F_V102`; no `SRAM_V`, `EEPROM_V` or `FLASH*_V` string exists | One match at file offset `0x1C6D0`, never referenced. `FUN_080119d0` copies a read routine (ROM `0x0801192C`, 0x34 bytes) and a verify routine (ROM `0x08011994`, 0x3C bytes) to EWRAM and sets the SRAM wait state; the write routine `0x08011960` is a byte loop with no command bytes | byte scan, Ghidra, harness | verified. That this is Nintendo's SDK library is likely (structure only, no comparison with SDK object code). What the "F" stands for is **unverified** |
| All backup traffic is 1-byte CPU accesses to `0x0E000000`-`0x0E000CCF`; there is no Flash or EEPROM protocol | Static: only three instructions build the SRAM base (`0x08001E54`, `0x0800E544`, `0x0800E56C`), all with size `0xCD0`; no Flash command addresses anywhere. Dynamic: 25 runs, 95,135 reads and 65,600 writes, all 1-byte, all in range; no DMA to 0x0D-0x0F. With the save type forced to Flash, EEPROM or none, the game still writes plain bytes, fails the verify 3 times and shows "Error while saving" | Ghidra, raw scans, harness | verified; forced "none" spot-checked (9,840 writes = 3 x 3,280, then the error panel) |
| Save layout: 0xCD0 bytes at offset 0; the word at `0xCC8` is the 32-bit sum of the 818 words before it; language at `+0x17`; the rest of the 32 KiB stays 0xFF. A zero or wrong checksum loads defaults and shows the language menu at boot | Boot load at `0x08001E44`-`0x08001E88`; `FUN_0800352c` is a word sum | Ghidra, `--save` round trip | not independently checked (investigator: verified); spot-checked: an options save gives a 32 KiB file, last non-0xFF byte at `0xCCF`, checksum `0xA5E24F59` equal to the word sum |
| The read and verify routines run only from their EWRAM copies (`0x0203D7D4`, `0x0203D734`), called through pointers at `0x02000BF4`/`0x02000BF8`; the write routine runs from ROM | Coverage: the ROM originals never execute | Ghidra, harness | **corrected**. Claimed: they are reinstalled "after every crt0 re-init" "because the race overwrites the pointers". Both verifiers: the front end calls the installer unconditionally every time it starts, because its own crt0 zeroes the pointers (`.data`) and the code copies (`.bss`). The race program's crt0 never reinstalls them. The race does zero the pointers and reuse them as data, but leaves the code copies alone |
| Saves happen when leaving Options after a change, when leaving after "reset game", and after a race result that the game records. Aborting a race or leaving Options unchanged does not save | Callers of the only writer `FUN_0800e50c`: `0x08001CF8` (Options), `0x0800EFF4` (post-race, `FUN_0800e93c`), `0x0800F5DC` (multiplayer post-race) | Ghidra, harness | not independently checked (investigator: likely). One verifier forced a race finish by patching the lap counter; the record-entry screen ran and the same writer saved. Spot-checked: an 8th-place finish writes nothing. One verifier's "reset game" sequence saw no write while three other runs did; it probably did not leave Options (**unverified**). The multiplayer post-race save was not run |
| gbarecomp detects the save type as Unknown; then save reads return 0 and writes are dropped | `src/gba/gba_rom_header.cpp` scans for `EEPROM_V`, `SRAM_V`, `FLASH1M_V`, `FLASH512_V`, `FLASH_V`; `src/gba/gba_bus.cpp` `Region::Save` returns 0 when no chip is configured | source reading; detector re-run on the ROM; mGBA patched to behave the same | verified. In that simulation every save shows the error panel and defaults load on every boot |
| `[save] type = "sram"` in `game.toml` is required and sufficient for the save type; leave `size` out (32,768 is the default and the only valid SRAM size) | `runtime.cpp` parses `[save]`; `valid_save_size(SRAM)` accepts only 32,768; the web exporter keeps `[save]` type and size | source reading; harness round trip | verified |

**gbarecomp.** Add to `game.toml`:

```toml
[save]
type = "sram"   # the ROM's ID string is SRAM_F_V102; gbarecomp 5e89943 only knows SRAM_V
```

`GBARECOMP_SAVE_TYPE=sram` does the same for native test runs. The read and verify routines execute from EWRAM, so a fully static build also needs `[[code_copy]]` entries for them (`0x0203D7D4` from `0x0801192C`, size `0x34`; `0x0203D734` from `0x08011994`, size `0x3C`) and Thumb `[[extra_func]]` roots. No other code ever runs at those addresses, so these entries are safe; the interpreter fallback would also cope.

**Web build.** Persist a raw 32 KiB `.sav`, the format mGBA writes. The checksum at `0xCC8` makes it cheap to validate an imported save.

**Enhancements.** Anything that writes more than 0xCD0 bytes or moves the block breaks compatibility with cartridge and emulator saves.

**Open BIOS.** The save code calls no SWI.

## 2. Race rendering

**Answer.** Races use video mode 1 (DISPCNT `0x1741`: BG0, BG1, BG2 and OBJ, 1D sprite mapping) on every frame, with no bitmap mode and no page flipping. The ground is affine BG2: a 1024x1024, 256-colour map loaded once per race (map `0x06000000`-`0x06003FFF`, tiles `0x06004000`-`0x06007FFF`). HBlank DMA0 writes PA, PB, PC, PD, X and Y on every visible line from a double-buffered table in EWRAM. PB, PC and PD are always 0, so each line samples one horizontal row of the texture with its own scale and offset: a segment-based pseudo-3D road, not rotating "Mode 7". The same map holds a sky panorama, drawn on the top lines with wrap on. An HBlank IRQ also writes BG2CNT, brightness fade (BLDCNT/BLDY) and the backdrop colour on every line, and hides sprites at precomputed lines (likely occlusion behind hill crests). Bikes, scenery, buildings and cars are affine sprites (likely); BG1 is the HUD. The renderer is ARM code running from IWRAM, and the race updates at the full 60 Hz.

| Claim | Evidence | Method | Status |
|---|---|---|---|
| Every race frame is mode 1, DISPCNT `0x1741`; no bitmap mode in races; the page bit is never set | DISPCNT is `0x1741` with no write at all from the first race frame to the end of a 3-lap race (Cross/Kenya 3303-21788, GP/California 3346-18415, Traffic/Moscow 3358-17909). No code anywhere sets the page bit or modes 3/5. Mode 4 is used only outside races (intro, title, post-race "Try again") | harness traces and write watches; Ghidra and raw scan of all DISPCNT writers | verified; spot-checked for GP, Traffic and the Kenya race end |
| The ground is BG2, set per scanline by HBlank DMA0 (CNT_H `0xA660`, 4 words per line into `0x04000020`) from tables at `0x020029AC` and `0x020037EC` that alternate every frame; PB=PC=PD=0 | 847,680 DMA0 writes per register over frames 3303-8600, exactly 160 per frame; PB/PC/PD nonzero only in setup frames 3305-3307. The texture is written only at race load (`0x0815A1EE`, `0x0815A20A`); re-rendering BG2 from VRAM and the per-line registers reproduces the screen wherever BG2 is visible | harness, Ghidra | **corrected** (details). Each table holds 0xA00 bytes (160 lines x 16); 0xE40 is the spacing. BG2 also draws the sky on the top 0-84 lines (wrap on, PA=0x100, constant X) from an upside-down panorama at the bottom of the map. Where the non-wrapping ground runs off the map, what you see is the per-line backdrop colour |
| Races update at 60 Hz: the main loop `FUN_03001cb0` runs once per frame and re-arms DMA0 on the table it built the frame before | 17,981 iterations over Cross, GP and Traffic with no skipped or doubled frame | harness `--trace-pc` | **corrected** (timing). The loop has no frame pacing of its own: it busy-waits for VCOUNT >= 170 (`0x03001CEC`). Work per iteration is 117-203 lines in Cross and 120-198 in GP. In Traffic, 15 of 5,638 iterations took 232-267 lines, more than a whole frame; the next iteration started late in VBlank and still re-armed DMA0 before line 0, so no frame was lost. Headroom is about 18 lines. While the camera is still (countdown, pause), the table is rewritten with identical contents |
| No software rasterizer: after loading, the race writes only HUD tiles and map (BG1, `0x0600E100`-`0x0600F7FF`) and sprite tiles (`0x06010000`+) | Nothing written below `0x0600C000` during full races on three tracks | harness write watches, Ghidra | **corrected** (numbers). Typical frames write 686 bytes (HUD only); long-run means are 0.95-1.2 KB per frame, with peaks of 3-8 KB when sprite tiles upload. The load (display off) writes about 150 KB |
| The renderer is ARM code in IWRAM copied from ROM `0x083F6820`: `0x03000340`-`0x0300098F` walks the track and fills three per-line tables (affine; BG2CNT/blend at `0x02005784`; backdrop colour at `0x020058C4`) and projects objects; `0x03000DB8` sizes and culls sprites; `0x030001A8` is a reciprocal (2^30/x) table lookup | Byte-identical to the ROM image in every race dump; one entry point and one return | harness `--calls`, `--trace-pc`, Ghidra | **corrected** (details). Ghidra's split of `0x03000340` into five functions is wrong. The perspective divide is in `0x03000340`; `0x03000DB8` only sizes, picks a level of detail, culls and writes the sprite. These routines are 56-70% of executed instructions depending on the window (76-83% without the busy-wait) |
| A per-scanline HBlank IRQ (handler `0x030009A4`, dispatcher `0x03004844` via `0x03007FFC`) writes palette[0], BG2CNT, BLDCNT and BLDY on every line and hides sprites at precomputed lines | Each of those writes happens about 228 times per frame; OAM is rewritten at VCOUNT 170-174 | harness I/O watches, Ghidra | **corrected**. The game writes DISPSTAT `0x0018` (`0x0019` is that value read back during VBlank). The handler runs 226-228 times per frame: DMA3 copies during VBlank delay or drop some IRQs, and in 28 frames a visible line (77-81) is missed because the handler acknowledges the next line's IRQ itself. On VBlank lines it reads past its 160-entry tables, which gives screen row 0 junk register values in almost every race frame: row 0 differs from row 1 in 1,096 of 1,109 frames (3300-4400), and 743 of them show the junk palette[0] value (in mGBA; hardware **unverified**) |
| Sprites are affine OBJs: player 64x64, rivals 32x32; at most 32 affine matrices; sprite hiding is occlusion behind hill crests | OAM dump mid-frame at frame 4201: 40 affine entries | harness, decompiler | not independently checked (investigator: likely) |
| BG roles: BG1 HUD (priority 0), BG2 road and sky (priority 2), BG0 enabled but blank; per-line BLDCNT/BLDY give a distance haze | VRAM and per-line traces | harness | not independently checked (investigator: verified); the BG0/BG1 parts are consistent with the verifiers' VRAM analysis |
| Intro and logos are mode 4 on page 0 only; the intro animation is decoded by a FLIC-style player in front-end IWRAM (`IWRAM_BOOT::0x03000000`) every 7 frames | Chunk types 4, 7, 0xC, 0xD, 0xF, 0x10 | harness, Ghidra | not independently checked (investigator: likely) |
| The title is mode 4 plus sprites; menus are mode 1 with a BG0 frame, an affine BG2 picture and sprite text, plus a VCount IRQ palette split | Frame ranges in `trace.tsv` | harness | not independently checked (investigator: verified) |
| From frame 270 on the game never uses windows, mosaic, alpha blending or BG3 | No game writes to those registers | harness | not independently checked (investigator: verified) |
| Texture rows: Y = 0x1000 x (segment texture id & 0x3F) + phase (64 bands of 16 rows); segment flag 0x40 mirrors the road; X starts at 0x20000 - 0x78 x PA - curve offset | Decompiled tail of `0x03000340` | Ghidra | not independently checked (investigator: likely); one verifier saw the same formula statically |

**gbarecomp.**

- The hottest code, including an IRQ that fires on every scanline, is ARM in IWRAM. It must be declared as a `[[code_copy]]` of ROM `0x083F6820` (section 4), or it runs on the interpreter path.
- The PPU must be scanline-accurate for this game: HBlank DMA into BG2PA-BG2Y with the reference points re-latched on each write, mid-frame writes to BG2CNT, BLDCNT, BLDY, palette[0] and OAM, and a VCOUNT that advances realistically, because the main loop polls it instead of waiting for an interrupt. Whether gbarecomp's runtime does all of this at the pinned commit is not checked yet.
- Phase 2 differential tests should compare per-scanline register logs (`lines.tsv`) as well as frames.

**Enhancements.** There are no polygons to intercept; the plan's "affine backgrounds" path applies. This is the same family as Mario Kart: Super Circuit (case A in the [gbarecomp integration study](https://github.com/nvergez/moto-racer-advanced-browser/pull/2)), with one difference: Moto Racer already swaps its table every frame, so there is no 30 Hz road to fix.

- *Widescreen:* gbarecomp's wide compositor extends affine layers into the margins, so the road should extend by itself (**unverified**). `0x03000DB8` culls sprites at the screen edges (at x = 0xF0 according to the decompiler), so the margins would show road without bikes or scenery until that check is widened. The HUD is on BG1.
- *Higher resolution:* gbarecomp has no internal-resolution path. The road is fully described by the static texture, a 1024-entry backdrop colour table (`0x0200953C`) and the per-line tables, so a GPU renderer can sample it at a higher horizontal resolution directly. More lines need the projection in `0x03000340` reimplemented (constants `0x78` and `0x50` are the screen centre). Sprites come from pre-scaled level-of-detail frames, and the occlusion lines must be reproduced.
- *Frame rate:* nothing to do for single-player races.

**Open BIOS.** During a race the BIOS runs only the IRQ entry and exit (about 229 times per frame) and DivArm. The IRQ path has to be quick enough that the handler's register writes still land inside HBlank. That margin has not been measured.

## 3. Program layout and toolchain

**Answer.** The cartridge holds two separately linked programs. The outer header's reset path enters the race program (`0x08000000` -> `0x080000C0` -> `0x08159F30`). On cold boot it immediately jumps to a front-end program embedded at `0x08000100`-`0x08159F2F`, which has its own GBA header, crt0, scatter loader, libraries and IRQ dispatcher. The programs pass control back and forth with direct jumps and a 4-word parameter block at `0x03007B00`, and each reloads EWRAM and IWRAM on entry. About 135 KB of the ROM (3.2%) is code. ARM is 90% of the code bytes and over 98% of executed instructions, mostly in IWRAM. The toolchain is likely ARM's own (armcc and tcc, armlink, the ARM C library), with Nintendo SDK pieces linked in. No GCC or agbcc idiom appears.

| Claim | Evidence | Method | Status |
|---|---|---|---|
| Two separately linked programs; the race program owns the reset path; the front end is a complete image at `0x08000100` | Second header at `0x08000100` (valid complement `0xF0`, blank title); the word at `0x080000FC` is the front end's size; each program has its own loader: front end `.data` `0x08158B00` (0xBFC bytes), IWRAM `0x081596FC` (0x834); race `.data` `0x083F6100` (0x720), IWRAM `0x083F6820` (0x49C4). Switches: frame 284 race to front end, frame 3286 front end to race with `{0x01168000, 0xA00, 0x1C20, 0}`, abort writes `0xFFFFFFFF` x4 | Ghidra, raw scans, harness | **corrected** (addition). The top of EWRAM (`0x0203D854`-`0x0203FFFF`) is outside both loaders and is a second channel: the front end keeps a block loaded from SRAM at `0x0203F000`, it survives the race, and the race reads `0x0203FCCC` at start-up. The front end boots to the title screen when entered directly (tested on a patched scratch copy, since deleted), but relies on the outer header's `0x080000C4` to start a race |
| About 3.2% of the ROM is code; the rest is front-end data (31.8%), race data (64.3%) and a zero tail | Region bounds from the loaders' literal pools | Ghidra, scans | not independently checked (investigator: verified) |
| Execution is ARM-heavy and mostly in IWRAM | Static: front-end game code 99.7% ARM; race ROM code about 60% ARM / 40% Thumb; ARM 90% of unique instruction bytes | Ghidra, harness coverage | **corrected** (numbers). Executed instructions are 98.1% ARM in the race and 99.7% in menus (counting the BIOS). IWRAM runs 95.6% of race instructions and 77.1% of menu instructions (94.4% and 76.9% without busy-waits). The race image's Thumb is a 12-byte interworking stub that runs every frame, not unreached bytes |
| The toolchain is ARM's: armcc/tcc, armlink scatter loading, ARM C library; not GCC, devkitadv or agbcc | ARM C library routines in both programs (`__rt_udiv` at `0x08011610` takes the divisor in r0; signal-handler messages; semihosting exit). Codegen: 20 `addls pc,pc,rX,lsl #2` switches and 0 `ldrls pc` tables; Thumb returns `pop {r3}; bx r3` and 0 agbcc-style `pop {r0}/{r1}; bx`; shared literal pools; armlink-style veneers | Ghidra, raw idiom counts; all 2,536 division calls traced use the ARM library convention | likely (both attempts: not refuted, attribution rests on known codegen traits without reference binaries) |
| The exact version (ADS 1.x rather than SDT 2.5x) | C++ entries in the library's signal table; 2002 build date | string inspection | **unverified** |
| A byte-matching decompilation is impractical; functional recompilation plus non-matching hand-written C (Phase 5) remains viable | Proprietary, discontinued, unidentified compiler build; the two programs were built with different settings (for example the front end divides by 3,600 with a library call while race IWRAM code uses a reciprocal multiply); hand-written assembly mixed in | synthesis | likely (both attempts). One detail corrected: the race also calls `__rt_udiv10` from IWRAM, so the split is not as clean as first stated |
| Features a recompiler or BIOS replacement must handle | 20 ARM jump tables (6 seen executing), 4 Thumb byte tables, IRQ table dispatch; the front end writes the BIOS IntrCheck flag through the IWRAM mirror `0x03FFFFF8`; Thumb code copied to EWRAM (section 1); semihosting SWIs only on the C library's divide-by-zero path | Ghidra, harness | **corrected**. 115 distinct veneers (122 with inline Thumb entry stubs), not 156, which counted long veneers twice. Function-pointer calls exist beyond the IRQ tables (`0x0815E1D8` with 5 targets in a race, tail jumps at `0x0800485C` and `0x0815FD24`, the SRAM pointers). CpuSet (`0x0B`) does run, about 5 times per frame in the multiplayer lobby |
| Nintendo SDK pieces are linked in: an `intr_main`-style IRQ dispatcher in each program, `libagbsyscall`-style SWI wrappers, the fast-SRAM library; no M4A | Dispatcher shape (`mov r12,#0x4000000` ... `bx r0`), customized differently in each program; no M4A signature anywhere | Ghidra, harness | likely (both attempts; matched against the known SDK shape, not SDK binaries) |
| The ROM has no source paths, asserts or developer names; only the C library's messages and a text table of 715 numbered strings in five languages | String scans | Python | not independently checked (investigator: verified) |

**gbarecomp.** Two programs share the same RAM addresses (section 4). Function discovery should probably be seeded from the Ghidra and harness function lists (about 490 real functions once veneers and duplicates are removed, by the investigator's count), because armcc's shared literal pools, `addls pc` tables and `bx pc` veneers placed right before their targets differ from the agbcc games gbarecomp has been tested on. Whether gbarecomp's finder handles them alone is **unverified**.

**Enhancements.** The race renderer and physics live in the race program, separate from the menus. Hooks should be keyed per program.

**Open BIOS.** Switching programs uses no BIOS call: no SoftReset, no RegisterRamReset.

## 4. Code running from RAM

**Answer.** Exactly four ROM-to-RAM code copies happen, all by plain CPU load/store loops: the race IWRAM image (ROM `0x083F6820`, 0x49C4 bytes, to `0x03000000`), the front-end IWRAM image (ROM `0x081596FC`, 0x834 bytes, to `0x03000000`), and the two small SRAM routines in EWRAM. No DMA, CpuSet, CpuFastSet or decompression call copies code, and no code is modified after it is installed. The two IWRAM images overlap at `0x03000000`-`0x03000833`, so the same address holds different code at different times. During a race the IWRAM image runs about 94% of non-idle instructions, and the HBlank IRQ interrupts it on every scanline.

| Claim | Evidence | Method | Status |
|---|---|---|---|
| Exactly four code copies, all by CPU loops: race image (loader `FUN_08159f94`, frames 279-280, again on every race load, restart and new race), front-end image (`FUN_080001f4`, frame 293, again after an abort), SRAM read and verify routines (`FUN_080119d0`, frame 294) | Images rebuilt from write logs match the ROM byte for byte; CpuFastSet is only used to fill, decompression only targets data buffers that never execute | harness write logs over 11 scenarios, Ghidra, raw scans | verified |
| The race image is the race engine | Frames 3290-4400: IWRAM 131.8M instructions, ROM 3.7M, BIOS 2.4M; 28.9M of the IWRAM count is the VCOUNT busy-wait. IWRAM is 94% of non-idle instructions and about 90% of non-idle cycles (95% and 91% in a GP race) | harness coverage | verified for the instruction counts; likely for the cycle shares (estimates from mGBA 0.10.5 cycle counts); **corrected** for function roles (`0x03000340`-`0x0300098F` is one routine; `0x030004DC`, `0x0300074C`, `0x03000790`, `0x03000798` are Ghidra artifacts inside it; the mixer is entered in Thumb at `0x030044C2`) |
| No self-modifying code; after install, only the IRQ jump tables inside the images are written (race `0x030048E8`-`0x0300491B`, front end `0x030007B0`-`0x030007E3`) | A stepping write/execute check over boot, menus, saves, the multiplayer lobby, attract mode, three race types, pause, restart and abort | harness, Ghidra | **corrected** (details). Both attempts found the IRQ tables larger than first claimed: the race table is 13 words, ending at `0x0300491B` rather than `0x03004917`, and the front end fills its whole table `0x030007B0`-`0x030007E3` on every entry, not only the VCount slot `0x030007BC`. The absence of self-modifying code is verified dynamically and only likely statically, since stores through unresolved pointers cannot be excluded |
| The images collide: the same IWRAM addresses run different code depending on which program is active, and gbarecomp's `[[code_copy]]` cannot tell them apart | Only 148 of the 0x834 overlapping bytes are equal | harness dumps, gbarecomp source | **corrected**. A true collision of (address, instruction set) exists only at `0x03000000`, an ARM entry point in both images (a small race routine, and the front end's intro player). At `0x030004DC` the front end has a Thumb entry while the race image has a mid-function ARM instruction; at `0x03000708` the front end's IRQ dispatcher sits in the middle of a race routine, which collides only if a resume entry is emitted there. On the gbarecomp side: `[[code_copy]]` has no guard field, the first matching range wins, overlapping ranges are not rejected, and dispatch is keyed by PC and instruction set only. Two opt-in hooks (`g_runtime_ram_dispatch_hook`, `g_runtime_force_interp_hook`) let game code guard RAM dispatch |
| The HBlank IRQ interrupts race code at arbitrary instructions, so a static build needs resume entries | IE `0x2003`, about 228 HBlank IRQs per frame | harness, Ghidra | **corrected**. About 5% of IRQs land in ROM code and a few in BIOS code. Over 1,098 race frames, 1,799 distinct IWRAM, 1,419 ROM and 25 BIOS return addresses were seen. `static_resume_all = true` covers all of them; `[[resume_range]]` limited to the IWRAM image would leave the ROM returns as misses |
| The front end writes the BIOS IntrCheck flag through the IWRAM mirror `0x03FFFFF8` | `strhne r0,[r12,#-8]` at `IWRAM_BOOT::0x03000744`, 2,992 times | harness, Ghidra | not independently checked here (investigator: verified); confirmed by both attempts on the related claim in section 3 |
| No other install path exists, so every track and race type gets the same race image | The two loaders take constant arguments | Ghidra | likely; GP and Traffic races were checked dynamically |

**gbarecomp.** Compiling the IWRAM code natively is required, not optional: it is about 94% of race CPU time and contains every renderer routine Phase 4 needs to hook. A first `game.toml` would include:

- `[[code_copy]] runtime_start = 0x03000000, source_start = 0x083F6820, size = 0x49C4` (race image);
- `[[code_copy]]` entries for the two EWRAM SRAM routines (section 1);
- `static_resume_all = true`;
- `[[extra_func]]` roots for IRQ-table and veneer targets, and the Thumb entries `0x030044C0` and `0x0203D7D4`;
- `[[data_range]]` or scan limits so the ROM copies of the images (`0x083F6820`-`0x083FB1E3`, `0x081596FC`-`0x08159F2F`) and the `.data` blocks are not decoded as ROM-resident code, provided that does not stop `[[code_copy]]` from reading them (**unverified**).

That leaves the front-end image at the same base. Options, in order of preference (all **unverified** until the build in PR #5 exists):

1. A game-owned `g_runtime_ram_dispatch_hook` that knows which image is resident and dispatches to the matching compiled body. Images change only at the two program entry points, and code is never patched, so a flag switched there, or a check of a few bytes at `0x03000000`, should be enough.
2. Compile only the race image and leave front-end IWRAM code to the interpreter, with a residency check so the race body never runs while the front end is loaded.
3. Add guarded variants of `[[code_copy]]` (for example, valid only while a hash of the image matches) in a patched copy of gbarecomp. This is the most general fix, but it means carrying a patch on a fast-moving engine.

Without one of these, `GBARECOMP_STRICT_STATIC=1` cannot describe this ROM, and permissive mode risks running the wrong code without any error rather than just falling back to the interpreter. The [integration study](https://github.com/nvergez/moto-racer-advanced-browser/pull/2) (section 3.3) reaches the same conclusion from the gbarecomp side.

**Enhancements.** Hooks must be keyed by RAM address plus resident image, and must target the IWRAM routines, because their ROM copies never execute.

**Open BIOS.** Installing code does not involve the BIOS.

## 5. Sound

**Answer.** The game does not use M4A (MusicPlayer2000). It has a custom, still unidentified driver: a small software mixer in ARM, with a tracker-style music sequencer and a sound-effect API on top, all in C apart from the mixing loop. Output is 8-bit mono PCM on Direct Sound A only: timer 0 (reload `0xFC64`, 18,157 Hz) drives DMA1 into FIFO A, and each frame plays exactly 304 samples. The game never writes the PSG registers, and FIFO B, DMA2 and timer 1 stay unused. gbarecomp emulates the sound hardware generically and runs the game's own driver, so audio should work, but none of its M4A-specific enhancements apply.

| Claim | Evidence | Method | Status |
|---|---|---|---|
| Not M4A; the game calls no BIOS sound function | No `Smsh` ident (`0x68736D53`) and no `0x03007FF0` literal in the ROM; gbarecomp's own detector, re-run on the ROM, finds nothing; SWIs are only 0x05, 0x07, 0x0B, 0x0C, 0x11, 0x14 | scans, harness, gbarecomp source | **corrected** (wording). The game's driver is not M4A, but RAM is not M4A-free for the whole run: the BIOS's own driver plays the boot jingle in frames 6-270 and the BIOS clears its pointer at frame 271, before the game starts |
| Direct Sound A only: mono, 8-bit, 18,157 Hz, DMA1 to FIFO A on timer 0; no PSG; FIFO B, DMA2 and timer 1 unused | Init writes `SOUNDCNT_H = 0x0B00` (steady state `0x0300`), DMA1 to `0x040000A0`, TM0 reload `0xFC64`; 304 samples x 924 cycles = 280,896 cycles, one frame | harness, Ghidra | verified. An unused stereo path (FIFO B on DMA2) exists in the code; every init call selects mono |
| Double buffer locked to VBlank: the VBlank handler restarts DMA1 on the buffer just mixed | Buffers race `0x03004A08`/`0x03004F88`, menus `0x03000878`/`0x03000DF8` | harness, Ghidra | **corrected**. Buffers are 0x580 bytes. In races the swap waits for a flag (`0x0201A38D`) that the main loop sets after mixing; in menus it happens every VBlank. The restart is not tied to the timer phase: a late VBlank IRQ (for example after a large DMA3 copy) plays stale or skips mixed bytes. At race start and during pause DMA1 runs unrestarted for a few frames |
| The mixer is ARM code copied into IWRAM (race `0x030044D0`, front end `0x030004EC`), run from the main loop | Byte-identical in both images apart from literal-pool addresses | harness, Ghidra | **corrected**. In races it runs from the main loop in System mode. During the logos, intro and title it runs inside the VCount interrupt (IRQ mode). Whether the loop is hand-written is **unverified** |
| The mixer: up to 16 voices (stride 0x7C), signed 8-bit ROM samples, 16.16 step with no interpolation, rate passed as a parameter (0x46ED = 18,157) | Voice structures in RAM, init call sites | harness, Ghidra | **corrected**. Volume is not limited to 0-64: menu sound effects use 128. The number of voices scanned follows the music (2-14 in menus, 6 in races, at most 3 active in races) |
| Music is a tracker-style module (order list, BPM, envelopes), possibly XM-like; no music plays in the recorded Kenya race | Sequencer state in IWRAM; race player state stays 0 | harness, Ghidra | not independently checked (investigator: likely) |
| gbarecomp does not replace M4A: it emulates the hardware and runs the game's driver; its optional M4A "shadow" re-render only arms when its detector finds M4A, which it does not here | `gba_m4a.h` ("observability only"), `configure_shadow`, `tick_timers` and FIFO DMA code | gbarecomp source, detector re-run | verified (static); likely (dynamic, gbarecomp not run) |
| The same driver is linked into both programs, compiled slightly differently | Matching routines in both programs | Ghidra | not independently checked (investigator: likely) |
| Probably not the open-source release of Krawall (different rate, buffer count and frame size) | Krawall defaults to 16,384 Hz and 4 buffers | source comparison | not independently checked (investigator: likely) |

**gbarecomp.** The audio path is the generic one gbarecomp models: Direct Sound A, DMA1 in FIFO mode on timer 0, FIFO reset through a byte write to `0x04000083`, DMA restarted on the enable edge. What must be right is the recompiled driver, including the two IWRAM mixer copies (about 6,400 instructions per frame in a race, 18,900 in menus). The design assumes timer 0 and VBlank stay exactly in step. Any drift in gbarecomp's timer, DMA or frame scheduling, or a race loop that overruns a frame, would be audible as a click at frame rate. Phase 2 should diff gbarecomp's audio against mGBA. The harness's `--wav` output was silent during Phase 1; that is fixed in `tools/analysis`.

**Enhancements.** gbarecomp's M4A shadow mixer will not arm, so there is no free high-quality audio. A game-specific equivalent looks feasible: one mixer, a known 0x7C-byte voice structure, signed 8-bit samples, mono. It could re-render voices at a higher rate with interpolation, or replace the music player on the host side.

**Open BIOS.** Sound uses no BIOS sound function. It does need exact DivArm results (the timer reload and samples per frame are computed with it), CpuFastSet fill mode, and the normal IRQ path. Only the BIOS boot jingle is lost with a silent open BIOS.

## 6. BIOS calls and BIOS dependencies

**Answer.** The game uses six BIOS functions: VBlankIntrWait (0x05), DivArm (0x07), CpuSet (0x0B), CpuFastSet (0x0C), LZ77UnCompWram (0x11) and RLUnCompWram (0x14), through 13 small Thumb wrappers (front end `0x08011908`-`0x0801192B`, race `0x08162580`-`0x0816259B`). Two ARM-semihosting SWIs sit in the C library's divide-by-zero path and never run. SWIs are rare per frame. The hot BIOS path in races is the IRQ entry and exit, about 229 times per frame. The game also reads BIOS memory through a NULL pointer, and what it reads changes game state.

| Claim | Evidence | Method | Status |
|---|---|---|---|
| The complete set of BIOS SWIs is 0x05, 0x07, 0x0B, 0x0C, 0x11, 0x14, in 13 Thumb `swi n; bx lr` wrappers; the race set has no VBlankIntrWait | 15 SWI instructions in all code (13 BIOS, 2 semihosting); a raw scan of 4 MiB finds no others in code; runtime SWIs come only from the wrapper addresses | Ghidra, raw scan, harness | **corrected** (details). The original claim said there were no inline SWIs outside the wrappers; the static attempt found two, the ARM-semihosting SWIs at `0x080117C4` and `0x080118FE`. They are reachable only after a division by zero, never ran, and would misbehave on hardware. The six BIOS functions and 13 wrappers were confirmed statically; at runtime every SWI came from 9 of the 13 wrappers |
| GetBiosChecksum is never called; the game enters the BIOS only through the SWI vector, the IRQ vector, and returns from its IRQ handler to `0x00000138` | Coverage of BIOS addresses | harness, Ghidra | verified |
| The race reads BIOS memory through a NULL pointer: `0x03001418` loads a per-object-type bounding-box pointer that is 0 for some types and reads bytes 0-3, getting `0xE55EC002`, the word the BIOS fetched last after an IRQ return | 771 calls in frames 3302-4400 at `0x03001458`-`0x03001464`; the value feeds a rectangle overlap test (`0x030014FC`) that can set bit 0x20 at `[object+0x15]` | harness, Ghidra | **corrected** (details). Two object types on Kenya (12 and 19), two other types on GP (25 and 30), none in Traffic. With the retail value the overlap test never succeeds for these objects in the reference run, so the dependency is latent there |
| The open-bus value changes game state | Overriding only what game code reads from `0x0`-`0x3FFF`: `0xE55EC002` gives byte-identical results; `0xE3A02004` (the retail after-SWI value) changes EWRAM from frame 3720 on, with no visible difference by frame 4400; `0`, `0xE129F000` and `0xEAFFFFFE` change only the IRQ-stack slot `0x03007F9C` and one screen row in 1-2 frames (a timing effect around the missed HBlank lines 77-81, see section 2) | harness override | verified; spot-checked with `--openbus` (`0xE55EC002` identical, `0xE3A02004` EWRAM differs from frame 3720; in screenshots of frames 3309-4400, `0` and `0xE129F000` differ in 9 bytes of row 79 at frame 3845 and row 80 at frame 3851, `0xEAFFFFFE` in 15 bytes of row 81 at frame 3854; in 9 dumps their memory differs only at `0x03007F9C`) |
| SWIs are cold; the IRQ path is the hot BIOS code | Race (frames 3608-4400): DivArm only, at most 2 per frame; the BIOS IRQ path runs 181,414 times in 793 frames (92% of BIOS instructions). Front end: VBlankIntrWait at most once per frame, CpuFastSet at most 2, a burst of 515 DivArm calls in one loading frame | harness | **corrected**. The IRQ path is the hot one only during races. In the front end, LZ77UnCompWram accounts for 82% of BIOS instructions |
| A replacement BIOS must accept SWIs from IRQ mode, keep SP_svc at `0x03007FE0` (the game never sets it), and honour the IntrCheck flag at `0x03007FF8` | 977 SWIs issued by the front end's IRQ handler (VCount callback), 467 of them while a VBlankIntrWait is pending; crt0 sets only SP_irq `0x03007FA0` and SP_sys `0x03007F00` | harness, Ghidra | **corrected**. The retail BIOS runs SWI bodies in System mode, not IRQ mode. Re-entry also happens inside LZ77 and RL decompression, which run with IRQs enabled, not only inside IntrWait. The game sets the flag with a plain halfword store, not an OR |
| SWI arguments are benign: DivArm never gets a zero or negative divisor; decompression always goes from ROM to EWRAM; CpuFastSet is always a fill. 599 fills use a count of 60 words, which the retail BIOS rounds up to 64; the 16 extra bytes are never read | swi.tsv | harness | not independently checked (investigator: verified) |
| CpuSet is used only by the link-cable code (multiplayer lobby, about 5 calls per frame) | 2,446 calls in the lobby, 0 in `boot_to_race` | harness | not independently checked (investigator: verified); spot-checked (2,446 calls) |
| The game sets SOUNDBIAS (`0x0200`) and WAITCNT itself; RCNT keeps the BIOS value `0x8000` except in multiplayer | I/O watches | harness | not independently checked (investigator: verified) |
| DivArm calls and the NULL reads happen in the same game-logic pass; a different timing model could hand the read the after-SWI value instead | Closest observed spacing: one scanline, with an IRQ return in between | harness | not independently checked (investigator: likely) |
| gbarecomp models the same open-bus latch | `src/gba/gba_bus.h` updates the latch on every instruction fetched below `0x4000` | source reading | not independently checked (investigator: likely) |

**gbarecomp.** The wrappers are two-instruction functions reached through veneers, easy to intercept and profile. Each exists twice, once per program. Covering CpuSet needs the multiplayer path.

**Open BIOS.** This sharpens [open-bios.md](open-bios.md), section 5:

- The SWI surface is small and benign. Any reasonable open BIOS, or gbarecomp's opt-in HLE, should give identical SWI results (not tested).
- The value that matters for the NULL read is the one left after an **IRQ** return. Cult-of-GBA leaves `0xE55EC002` there, like retail (measured in open-bios.md, section 2.4); Normmatt's BIOS leaves `0xE129F000`, which caused no state change in our 1,100-frame test. Cult-of-GBA's after-SWI value `0xEAFFFFFE` also caused none; the retail after-SWI value `0xE3A02004` did.
- A cheap, BIOS-independent safeguard: hook `0x03001418` (ROM source `0x083F7C38`) in the recompiled build so the NULL bounding-box path behaves as if it read `0xE55EC002`. Treat it as a compatibility shim until we know what bit 0x20 at `[object+0x15]` does.
- The IRQ entry and exit run about 229 times per race frame, so their instruction sequence and timing matter more than any SWI.
- Requirements beyond the SWIs: reentrant SWIs from IRQ mode (including inside LZ77 and RL), SP_svc at `0x03007FE0`, the IntrCheck contract at `0x03007FF8` and through the mirror `0x03FFFFF8`.
- For Phase 2 A/B runs, add an open-bus probe: watch reads of `0x0`-`0x3FFF` and compare values. The harness's `--openbus` option reproduces the experiment above.

---

## Open questions

Answered by this phase, with the question numbers from [initial-findings.md](initial-findings.md): ROM revision (1), race rendering (2), compiler (3, likely), RAM code (4), sound engine (5), save type (6).

Still open:

1. **gbarecomp on this ROM** (7): does it build on macOS, what does a first run cover, and which overlay strategy (section 4) works? Does its PPU handle HBlank DMA into the affine registers with re-latched reference points, and per-line IRQ writes? Does its timing keep the VCOUNT busy-wait and the audio double buffer in step? (PR #5 builds the toolchain.)
2. **Ultimate mode** (8) and the other locked content: championship, league, the other 15 tracks. None were reached; they may use other code paths, but static analysis found only one race image loader with constant arguments.
3. **Multiplayer with a partner.** The SIO IRQ, the link code and the multiplayer post-race save were never run.
4. **Post-race saves.** An 8th-place finish does not save; a forced finish with a record entry does. What exactly triggers the save (record, unlock, or both)?
5. **Hardware behaviour.** The junk colour on screen row 0 in races, the occasionally missed HBlank line and mid-line register timing were observed in mGBA 0.10.5 only.
6. **Open-bus effect.** Does the divergence under `0xE3A02004` ever become visible (collision, AI, sound)? Which objects have no bounding box, and why?
7. **Toolchain version** (SDT 2.5x or ADS 1.x). It only matters if matching decompilation is reconsidered.
8. **Sound driver origin and music format.** In-house or licensed? Is the module format XM-like? Is the stereo path ever used?
9. **The game under an open BIOS.** Run `boot_to_race` and a race with the Cult-of-GBA image and compare (boot timing will differ). Check SWI reentrancy from IRQ mode and SP_svc.
10. **CPU headroom in heavier scenes.** Traffic already overruns a frame now and then; more traffic, later laps or multiplayer could drop frames.
11. **What `SRAM_F` stands for.** The emulation side does not care: the access pattern is SRAM. [PR #4](https://github.com/nvergez/moto-racer-advanced-browser/pull/4) cites a battery-backed SRAM chip on one documented Europe cartridge.

## What this means for the plan

- **Static recompilation stays the approach.** The toolchain rules out a matching decompilation, and nothing found blocks functional recompilation: all executed RAM code is a verbatim ROM copy, nothing is self-modifying, and the SWI surface is small. Phase 1's exit ADR can say so, once the gbarecomp build (PR #5) has measured coverage.
- **The main recompilation risk is the two programs sharing IWRAM `0x03000000`.** About 95% of race execution runs from the race image, and the front end's image sits at the same base. Plan a game-owned RAM dispatch hook keyed on the resident image, `static_resume_all`, and seeded function lists. This is Phase 2's first technical task, before any coverage push.
- **Phase 2 also needs a scanline-accurate PPU and realistic timing.** HBlank DMA and an HBlank IRQ drive the road, the haze and sprite clipping on every line; the main loop polls VCOUNT; audio relies on VBlank and timer 0 staying in step. Differential tests should compare per-scanline register logs and audio, not just frames.
- **The save is simple:** `[save] type = "sram"`, two small `[[code_copy]]` entries, a 32 KiB `.sav` in the web build.
- **Sound needs no special handling** beyond correct generic hardware emulation. HQ audio, if wanted, means writing our own shadow mixer for this driver.
- **Phase 4 takes the "affine backgrounds" path.** The plan's software-polygon branch does not apply.
  - *Frame rate:* drop the item. Races already run at 60 Hz.
  - *Widescreen:* close to Mario Kart: Super Circuit's approach. The affine road should extend into the margins in gbarecomp's wide compositor (**unverified** for this game). The work is widening the sprite cull and moving HUD elements.
  - *Resolution:* new engine-side work. Re-render BG2 from the static texture and per-line tables at a higher horizontal resolution; more lines means reimplementing the projection routine; sprites are pre-scaled bitmaps.
- **Open BIOS (open-bios.md option A or A′) looks workable for this game**, with three conditions: the IRQ path must match retail closely, the after-IRQ open-bus value must stay `0xE55EC002` (or the shim above is added), and SWIs must be reentrant from IRQ mode. The retail BIOS dump stays the fidelity reference.

## Recommended next steps

1. **Bring up gbarecomp on the ROM** (with PR #5): a first `game.toml` with `[save] type = "sram"`, `[[code_copy]]` for the race image and the two SRAM routines, and `static_resume_all`. Record function coverage and dispatch misses on `boot_to_race`.
2. **Prototype the overlay handling** with a small RAM dispatch hook that switches between the race and front-end images at the program entry points. Check it in strict static mode across boot, a race, an abort back to the menus, and a second race.
3. **Write `docs/adr/0001`** confirming static recompilation, citing this document and the coverage numbers from step 1.
4. **Build the differential test loop:** the harness input scripts in `tools/analysis/input` as replays; compare per-frame state CRCs, per-scanline registers and audio between mGBA and the recompiled build.
5. **Reach more of the game:** closed-loop steering or RAM pokes to finish races with records, unlock championship modes, and reach Ultimate. Then re-check RAM code, rendering and saves there.
6. **Run the game under the Cult-of-GBA BIOS** in the harness (`--no-hash-check --bios ...`) and compare against retail: boot, a race, SWI results, open-bus reads.
7. **Fix the Ghidra project's known issues** (listed in [tools/analysis/README.md](../../tools/analysis/README.md)) and stop counting BIOS IRQ returns as calls in `calls.tsv`. Do it in a separate change, so the numbers here stay reproducible.
8. **Phase 4 groundwork:** map the per-line tables built by `0x03000340` and the sprite cull in `0x03000DB8`, and test widescreen with gbarecomp's wide compositor once a recompiled race runs.

## Reproducing

The tools, input scripts and their expected results are in [tools/analysis/README.md](../../tools/analysis/README.md). Typical commands, from the repository root with the ROM and BIOS in `roms/` and `bios/`:

```sh
tools/analysis/harness/build.sh
tools/analysis/harness/run_harness.sh --out runs/race --script tools/analysis/input/boot_to_race.txt \
  --trace 3290-4400 --trace-swi --coverage --step-frames 3290-4400
tools/analysis/harness/run_harness.sh --out runs/save --script tools/analysis/input/options_save.txt \
  --save runs/save/game.sav --watch-write 0x0E000000-0x0E00FFFF
tools/analysis/harness/run_harness.sh --out runs/openbus --script tools/analysis/input/boot_to_race.txt \
  --openbus 0xE3A02004 --dump-at 3700,3720
tools/analysis/ghidra/ghidra_import.sh
```

Outputs go to `analysis-out/`, which is gitignored. They are derived from the ROM and must not be committed.

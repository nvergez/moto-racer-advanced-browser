# Resume entries, the save routines and the ROM roots behind IWRAM code

**Date:** 2026-10-11
**Scope:** P2-05 of [phase2-plan.md](../phase2-plan.md): `static_resume_all`, the two EWRAM save routines and the ROM roots reached only through the front end's IWRAM code, as reviewed `game.toml` entries; what the build does with them on `boot_to_race` and on a boot without input; the first measurement of comparison 1 (ADR 0001, decision 5); inputs during a long interpreter bridge; and the review of the 47 ROM seeds of the iwram-overlays prototype.
**Status:** Native runs of gbarecomp and of the mGBA harness, and static reading of the ROM. IWRAM code is still interpreted on this build (P2-10 compiles it).

## Pins

| | |
|---|---|
| ROM | Moto Racer Advance (Europe) `A9MP`, SHA-1 `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0` |
| BIOS | retail, SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492` |
| gbarecomp | `5e89943528aee7bc1c399bdbd035364a4b41dd10` with patches 0001-0006 (`main` at `f093eaa`); `file:line` citations are at the pin |
| Game config | this branch's `game.toml`; "the previous config" is `main`'s (no entries, `static_resume_all` off) |
| mGBA | libmgba 0.10.5 through `tools/analysis/harness` |
| Machine | Apple M4 Pro, macOS; native runs headless with `SDL_AUDIODRIVER=dummy`, `GBARECOMP_SELFHEAL_RECOMPILE=0` and a fresh save |

"Reference" is the BIOS-interpreting interpreter of P2-02 (`GBARECOMP_FORCE_INTERP=1 MRA_INTERP_BIOS=1`). Frame numbers are harness frames. Replays are `script2replay.py`'s `boot_to_race` replay (`MRA_REPLAY`), captures are P2-03's with `tools/capture/spec.txt` and the route fields of `routes.py trace-mem`, joined with `tools/capture/capture.py join`. Disassembly is Xcode's `llvm-objdump` (`--triple=armv4t-none-eabi` or `thumbv4t-none-eabi`) on byte ranges of the ROM file. Capture files, logs, dumps and disassembly stayed in a scratch directory.

How the runs were made:

- gbarecomp: the plan's native run from `build/native` ("Commands used below"), with the variables of [tools/replay/README.md](../../tools/replay/README.md) for the replay and the capture, plus `GBARECOMP_FORCE_INTERP=1 MRA_INTERP_BIOS=1` for the reference. The two 3,290-frame runs of section 6, repeated from `build/native` exactly as written there, gave byte-identical capture files. Extra observations: `GBARECOMP_SELFHEAL_VERBOSE=1` (each missed PC once, on standard error), `GBARECOMP_MMIO_DUMP=FILE` with `GBARECOMP_MMIO_CAP_RING=2097152` (I/O writes with cycle and PC, written at exit, `runtime.cpp:4279`) and `GBARECOMP_IRQ_LOG=FILE` (one line per IRQ, written at exit, `runtime.cpp:2121`).
- mGBA: `tools/analysis/harness/run_harness.sh --out DIR --script tools/analysis/input/ROUTE.txt --frames N --calls`, with N the route's frame count in `tools/difftest/routes.toml`; `calls.tsv` lists each dynamic call or `bx` target with its count, first caller and first frame.

## 1. What the config adds

| Entry | Why | Section |
|---|---|---|
| `static_resume_all = true` | A static entry at every instruction boundary inside each emitted function, so a return address dispatched after a SWI unwinds the host stack has an entry (diagnosis §2.1) | 4 |
| `[[code_copy]]` `0x0203D7D4` from `0x0801192C`, size `0x34`, and `0x0203D734` from `0x08011994`, size `0x3C`, with Thumb `[[extra_func]]` roots at both | The save library's read and verify routines run only from these EWRAM copies (Phase 1 §1) | 2 |
| ARM `[[extra_func]]` `0x0800255C`, `0x080025B0` | Handlers in the front end's IRQ table, entered only by the IWRAM dispatcher's `bx r0` | 3 |
| ARM `[[extra_func]]` `0x08004168` | Entered only by a tail jump through a function pointer | 3 |
| ARM `[[extra_func]]` `0x0800596C`, `0x0800814C`, `0x08009CAC` | Menu VCount handlers, also IRQ-table entries; from the prototype's seeds (section 8) | 3 |

Every entry has a `note` with the ROM SHA-1, the addresses and how it was found. The plan also listed `0x08002580`; it gets no seed because the finder reaches it (section 3).

## 2. The save routines in EWRAM

The installer at `0x080119D0` (Thumb) copies two routines of the `SRAM_F_V102` library to EWRAM and stores pointers to them:

- `r0 = 0x0801192D` (literal `0x08011A44`), `r3 = 0x0203D7D4` (`0x08011A48`), end `0x08011961` (`0x08011A4C`): a halfword loop copies `(0x08011961 - 0x0801192D) / 2 = 0x1A` halfwords, 0x34 bytes, from `0x0801192C`, then `str` of `0x0203D7D5` to `0x02000BF4` (literal `0x08011A50`).
- `0x08011995` (`0x08011A54`), `0x0203D734` (`0x08011A58`), end `0x080119D1` (`0x08011A5C`): 0x1E halfwords, 0x3C bytes, from `0x08011994`, then `0x0203D735` to `0x02000BF8`.

Both pointers have bit 0 set, so both routines are Thumb; the source bytes disassemble as Thumb functions (`push {r4, r7}` ... `bx lr`) whose literal pools lie inside the copied range. They are called only through the pointers, which the finder cannot follow:

- read: the boot load at `0x08001E44`-`0x08001E5C` (`ldr r3, [0x02000BF4]`, `mov lr, pc`, `bx r3`, with `r2 = 3280` and `r0 = 0x0E000000`);
- verify: the save writer `0x0800E50C` at `0x0800E564`-`0x0800E574` (`ldr r3, [0x02000BF8]`, `mov lr, pc`, `bx r3`).

mGBA harness `--calls`: `0x0203D7D4` is called once on `boot_to_race`, at frame 596 from `0x08001E5C`, in Thumb; `0x0203D734` once on `options_save`, at frame 3415 from `0x0800E574`, in Thumb. Phase 1 found that no other code runs at these addresses and that the race program leaves the copies alone ([phase1-findings.md](phase1-findings.md) §1).

On this build the read routine runs as generated code. On frame 596 of `boot_to_race`, where the game reads the save, the previous config's bridges ran 26,322 instructions (likely the boot load itself, inside the bridge of the miss at `0x08001E44`, the return address just before the call; not traced), and this config's 22, as on the frames around it; no `0x0203D7xx` PC is a dispatch miss in any run below. The verify routine is not reached on these routes.

## 3. ROM roots behind the front end's IWRAM code

**The IRQ table.** The front end's IRQ handler is IWRAM code (`[0x03007FFC] = 0x03000708`, stored at `0x08002608`; ROM source `0x08159E04`). It reads `IE AND IF`, picks a slot and ends with `ldr r0, [table + slot * 4]; bx r0` at `0x030007AC` (source `0x08159EA8`), with the table at `0x030007B0` (literal at source `0x08159EE4`). It tests the bits in this order: timer 3 or serial (bits 6-7) → slot 0, HBlank → 1, VBlank → 2, VCount → 3, timer 0 → 4, DMA 0 to 3 → 5 to 8, anything else → 9. Apart from the dispatcher's own literal, every word of the ROM that holds `0x030007B0` (a search of the whole file) is loaded by code that stores a handler into the table:

| Slot | Handler | Stored at | Seed |
|---|---|---|---|
| all 13 | `0x080025B0` (`bx lr`) | loop `0x080025E8`-`0x080025F4` in the setup function `0x080025B4` | yes |
| 2 (VBlank) | `0x0800255C` | `0x08002600` | yes |
| 3 (VCount) | `0x08002580` | `0x08000320` | no: six direct `bl` reach it (`0x08005858`, `0x08006378`, `0x08007638`, `0x080080C0`, `0x08009BA0`, `0x0800A298`) |
| 3 | `0x080025B0` again | `0x08001240`, `0x08005934`, `0x0800811C`, `0x08009C64` | (above) |
| 3 | `0x0800596C` | `0x0800568C`, in the main-menu function `0x08005658` | yes |
| 3 | `0x0800814C` | `0x08007E50` | yes |
| 3 | `0x08009CAC` | `0x08009A3C` | yes |
| 0 (serial, timer 3) | `0x0800FB14` | `0x0800FAA4` (Thumb) | no: not reached on the routes run (follow-up) |

No ROM word holds the address of another slot (`0x030007B4`-`0x030007E0`). mGBA harness `--calls` on `boot_to_race` to frame 4,400 shows five targets of the `bx r0` at `0x030007AC`: `0x0800255C` (2,992 times, from frame 295), `0x08002580` (2,693, from 608), `0x08009CAC` (240, from 2484), `0x0800596C` (1,040, from 2525) and `0x0800814C` (1,160, from 2733). `options_save` enters the same five, `multiplayer_lobby` (no partner) four of them, and neither enters another; `0x080025B0` and `0x0800FB14` are never entered.

**The function pointer.** The VBlank handler calls `0x08004854` (`bl` at `0x0800256C`), which loads `[0x03000840 + 0x28]` (base from literal `0x08004A78`) and ends with `bx r0` at `0x0800485C`. `0x08004168` is stored there at `0x08004218` and at `0x080045B0` (both with the base from `0x08004A78`; the value from literal `0x08004A9C`, by `ldreq` at `0x080045AC` in the second case). The `ldrne` beside it, at `0x080045A8`, stores `0x08004518` (literal `0x08004AB8`) instead. The other users of the base were not audited for more values. mGBA enters `0x08004168` 2,992 times from `0x0800485C` on `boot_to_race`, from frame 295, and never `0x08004518` on the three routes above, so only `0x08004168` is seeded; `0x08004518` is a follow-up.

**Why the menu handlers matter on this build.** While the IWRAM dispatcher is interpreted, it reaches a handler inside an IRQ-continuation bridge, which hands control back to generated code at the first static entry (`runtime_arm_default_aborts.cpp:635-643`). Without the menu handlers as roots, the first static entry was a function they call (`0x08011410` or `0x080026B0`), and its return into the handler was a dispatch miss: `0x08005980` and `0x080059BC` (`0x0800596C`), `0x0800817C` (`0x0800814C`), `0x08009CC0` and `0x08009CEC` (`0x08009CAC`), bridged 200 to 1,040 times on `boot_to_race` to frame 3,290. With the roots they are resume aliases and the misses are gone.

## 4. Generation

`scripts/regen.sh` (`build/logs/recompile.log`):

| | Previous config | This config |
|---|---|---|
| Functions emitted | 2,259 (ARM 1,612, Thumb 647) | 2,278 (ARM 1,623, Thumb 655) |
| From the config only (`manual_seeds_only`) | 1 (the entry) | 9 |
| Code copies | 0 | 2 |
| Resume aliases (`midfn_aliases`) | 0 | 20,576 in 2,019 functions |

The diagnosis counted 20,401 aliases in 2,001 functions with `static_resume_all` alone (§2.1); the difference is the functions the new roots add.

## 5. Dispatch misses

Native runs as in the plan ("Commands used below"), each from its own working directory so that the miss fragment is the run's own. ROM misses are listed from the exit report (`bridged 0x... (mode) xN`).

| Run | Config | Exit | `ppu_frames` at exit | Misses | ROM misses | Interpreted instructions |
|---|---|---|---|---|---|---|
| `boot_to_race` replay, 3,290 frames | previous | 0 | 3,290 | 95 | 92 | 128,965,745 |
| `boot_to_race` replay, 3,290 frames | this | 0 | 3,290 | 13 | 10 | 128,721,463 |
| no input, 12,000 frames | previous | 0 | 12,385 | 47 | 44 | 917,097,714 |
| no input, 12,000 frames | this | 0 | 12,385 | 10 | 7 | 916,527,971 |

No run printed `SELF-HEAL bridge ... exceeded`, `did not iret` or a call-return overflow. The 12,000-frame runs stop at 12,385 frames on both configs, because the front end's IWRAM intro player still runs in a bridge that never checks the quit (diagnosis §1.3).

The ROM misses left on this config are all P2-06's:

- `boot_to_race`: `0x08002DA8`, `0x08002F54`, `0x08003EE4`, `0x08011B98`, `0x08011BB8`, `0x08011BD4`, `0x08012460`, `0x08012480`, case slots of armcc switches (`cmp rM, #N; addls pc, pc, rM, lsl #2; b ...`, read at `0x08002D9C`, `0x08002F48`, `0x08003ED8`, `0x08011B90` and `0x08012458`), and `0x08011DDC`, `0x08011DE8`, return addresses in code reached only through the switch at `0x08011B90` (diagnosis §2.2);
- 12,000 frames: the same without the first three.

The IWRAM misses remain, as expected until P2-10: `0x03000000` (ARM, the intro player), `0x030004DC` (Thumb, the mixer) and `0x03000708` (ARM, the IRQ dispatcher).

This config adds no miss to either list. Of the 82 ROM misses of the previous config that are gone on `boot_to_race`, 81 follow a `bl` (5 of them inside the menu handlers, section 3) and one is `0x08001F94` (section 9); on the 12,000-frame boot, 36 of the 37 gone follow a `bl`, and the other is again `0x08001F94`. All are resume aliases on this config. Nearly all interpreted instructions are the front end's IWRAM code, so their number hardly moves.

**The race.** A 4,400-frame `boot_to_race` run on this config reaches the race and does not stop at 4,400: the race main loop `0x03001CB0` runs in a bridge from shortly after the race image arrives (every record from frame 3294 on has interpreted instructions), and the bridge never checks the quit. It ends at frame 5,127 with `SELF-HEAL bridge for 0x03001CB0 exceeded 200000000 instructions without returning to stop_pc=0x0815AF4A`, exit code 134, as the plan expects until P2-10 (diagnosis §3.4: about frame 5,100). It prints no exit report; with `GBARECOMP_SELFHEAL_VERBOSE=1`, which logs each missed PC once, it misses 47 PCs before the abort: 19 in IWRAM (both images, P2-10), the 10 ROM PCs of P2-06 above, and 18 Thumb PCs of the race program in ROM, `0x0815A7B0`-`0x0815BC90`, case targets of Thumb switches (section 8).

## 6. Comparison 1, first measurement

This config's build, recompiled, and the reference, each on `boot_to_race` for 3,290 frames with the replay and the capture; `capture.py join REF BUILD --frames 1-3290`:

| Column | Frames that differ |
|---|---|
| `fb` | 3: 2185, 2188-2189 |
| `lines` | 5: 294, 1864, 1873, 2188-2189 |
| `DISPCNT`, all 10 memory fields, `fifo_a_n`, `fifo_b_n`, `fifo_b` | none |
| `ram_ewram` | 3: 2185-2187 |
| `ram_iwram` | 87: 2185-2271 |
| `ram_iwram_stacks` | 119: 295-296, 1396-1476, 1546, 1623-1625, 1630, 1637, 1840, 1847, 1862, 2165-2189, 2255-2256 |
| `fifo_a` | 71: 2186-2256 |
| `io_writes` | 43: 1396-1416, 2165-2185, 2188 |
| `halt_writes` | 43: 1396-1416, 2165-2185, 2189 |

So 3,287 of the 3,290 frame CRCs are equal. The three that differ come from the cause the plan names: IWRAM code runs in an interpreter bridge, and the bridge does not model HALT (diagnosis §1.5).

**The HALTCNT storm.** On 1396-1415 and 2165-2184 the build writes HALTCNT 4,856 to 10,967 times per frame where the reference writes it twice, and its bridge runs 122,000-135,000 instructions per frame: the intro player at `0x03000000` (bridged once per intro) is calling IntrWait. The frame after each storm, 1416 and 2185, has one HALTCNT write in the build and none in the reference. A `GBARECOMP_MMIO_DUMP` of both runs (ring of 2,097,152 writes, 2,192 frames) shows the difference directly: the FIFO A DMA writes of frame 2184 happen while the reference's CPU is halted at `0x00000348` and while the build's CPU executes the BIOS IntrWait loop at `0x00000344`-`0x00000374`, 2 to 4 cycles later.

**Frame 2185: the halt outlives the bridge.** The interpreter writes HALTCNT without halting, so the bus's `halted` flag stays set after each write. Only an IRQ taken by `runtime_tick` clears it (`runtime_bus_bridge.cpp:775-793`), `runtime_should_yield()` returns it (`:1138`), and the run loop idles while it is set (`runtime.cpp:2149-2155`).

- In both runs the last IntrWait of the intro is woken by the VBlank IRQ of the frame 2184/2185 boundary (cycle 613,393,095 in the reference, 613,393,103 in the build).
- The build's interpreted IntrWait loop writes HALTCNT once more, at cycle 613,393,410 (PC `0x00000344`), after that IRQ. The reference writes none in frame 2185.
- `GBARECOMP_IRQ_LOG` (one record per IRQ: cycle, source, return PC, CPSR, whether it woke the CPU from HALT): the next IRQ, VCount at cycle 613,538,471, finds the build's main thread halted at `0x08001F94` (`from_halt=1`, CPSR `0x4000001F`). The reference's main thread is running there (in the BIOS at `0x00001170`, `from_halt=0`).

`0x08001F94` is two instructions after the intro player's call (`bl 0x08011AB0` at `0x08001F8C`, return address `0x08001F90`). So the bridge had returned and the main thread, now generated code, stopped on the stale flag and stayed halted until the VCount IRQ cleared it: at most 145,061 cycles, the time from the last HALTCNT write to that IRQ, about half a frame. That the generated body yields at its first yield check after the bridge is the reading of `runtime_should_yield()`; the PC and the halt are measured. The reference does no such halt: before frame 2186 its IRQ log has no IRQ that wakes the CPU from HALT outside the BIOS, while the build's has two, this one and one at cycle 397,529,449 (frame 1416, at the end of the first storm, PC `0x03000478` inside the intro player's bridge).

The consequences, from the MMIO dumps:

- The post-intro screen setup (the BG2 scroll and affine registers, BLDCNT `0xFF`, BLDY `0xF`, DISPCNT `0x0404`, BG2CNT 3, written from `0x0800355C`-`0x08003848`) is written in VBlank at cycle 613,394,260 in the reference, and at 613,631,340 in the build, on line 125 of the frame being displayed. Frame 2185 differs.
- The main thread stays behind: the immediate DMA3 of 19,200 halfwords to VRAM (`0x08003374`-`0x08003380`) starts on line 134 of frame 2188 in the reference, where it spans the VBlank start (that frame's record is taken 45,725 cycles after the build's, the effect P2-03 measured on the interpreter against mGBA), and 135,843 cycles later in the build. Frames 2188 and 2189 differ.
- From 2190 the frames are equal again; EWRAM is equal from 2188, the bytes written to FIFO A from 2257 and IWRAM from 2272.

**Without IWRAM bridges the differences are gone.** A scratch build of this config plus the front end's IWRAM image as a `[[code_copy]]` in the main corpus, with its roots (`0x03000000`, `0x030004EC`, `0x03000708` ARM; `0x030004DC`, `0x030004DE` Thumb), as the diagnosis's front-end configuration had them (§2.3), was built for this check only and not committed: it is wrong once the race image is resident, and P2-10 decides how both images are compiled. On the same 3,290 frames it bridges only the switch slots above (no IWRAM miss), has no HALTCNT storm, and joins with the reference with every `fb`, `ram_ewram`, `ram_iwram`, FIFO, `io_writes` and `halt_writes` value equal. What remains is the same on both builds, so not caused by the bridges, and is for P2-09: `lines` on frame 294, `ram_iwram_stacks` on 295-296 and the record's clock on 295. On this build, the line records of frame 294 differ on line 73 only, DISPCNT `0x0404` in the reference and still `0x0000` in the build: a write that lands at least one line later.

**Against the plan's rule.** The plan accepts a difference "on a frame where a bridge was running ... and ran the BIOS IntrWait loop", and fails the task on any other frame. Frame 2185 is such a frame: a bridge ran 28,724 instructions and the interpreted IntrWait wrote HALTCNT once. Frames 2188 and 2189 also have a bridge running (32,133 and 26,233 instructions, the mixer and the IRQ dispatcher) but no IntrWait storm of their own; they differ because of frame 2185's halt, which the run never caught up with before 2190. They are recorded with the same cause. They must be equal on P2-10's static build.

**RAM differences for P2-09.** On this build: `ram_ewram` 2185-2187, `ram_iwram` 2185-2271 and `fifo_a` 2186-2256, all from the halt above; `ram_iwram_stacks` on 119 frames, all but 295-296 on frames where an IWRAM bridge runs (18,000 to 137,000 interpreted instructions) and none of those in the scratch build, which fits IRQs taken at other instructions inside a bridge (the registers they push differ; not traced); and the three residual differences of the scratch build. Over frames 3291-4400 (the 4,400-frame runs of both, joined on those frames) every compared column is equal apart from `ram_iwram_stacks` on frame 3303, which also differs between the interpreter and the reference (P2-02).

## 7. Inputs during a long bridge

On this build the race loop runs in one bridge from the start of the race (section 5). With `MRA_REPLAY`, the 4,400-frame run's records equal the reference's on every compared column of frames 3291-4400 but the IRQ stacks of frame 3303 (section 6), so the race gets its inputs inside the bridge: P2-02's `input_frame` is called from the device tick, which the bridge drives. The frame CRCs at 3830, 4000 and 4400 differ from each other (`046D9868`, `54CB5761`, `692E04B6`) and equal the reference's.

Control: the same build with gbarecomp's own replay (`GBARECOMP_INPUT_REPLAY`, the same events at harness frame - 2, which the diagnosis found best, §7.3) gives the same frame CRCs, line CRCs and RAM hashes as the `MRA_REPLAY` run up to frame 3608, apart from the IRQ stacks of frames 2186-2187, and differs from frame 3609 (`lines`) and 3610 (`fb`) on, on every frame to 4,400. The first input of the race, A held from 3609, is the first one applied after the bridge starts, and gbarecomp applies its own replay only in the run loop. Its CRCs at 3830, 4000 and 4400 differ from each other too (`4E8F0008`, `335FACC0`, `6BE22706`), so on this build the plan's "identical frames" from the diagnosis (§1.4, measured on another build) do not reproduce; the join against the reference is the check that discriminates.

## 8. The 47 ROM seeds of the iwram-overlays prototype

The prototype took 47 ROM `[[extra_func]]` seeds from miss reports of runs with both IWRAM images compiled (its `rom_seeds.inc`). Each was checked against the ROM and against this build's runs:

| Seeds | Kind | Here |
|---|---|---|
| `0x0800255C` | VBlank handler (section 3) | kept |
| `0x08004168` | pointer target (section 3) | kept |
| `0x0800596C`, `0x0800814C`, `0x08009CAC` | menu VCount handlers (section 3) | kept |
| `0x08005980`, `0x080059BC`, `0x0800817C`, `0x08009CC0`, `0x08009CEC` | return addresses after `bl` inside those three handlers | not needed: resume aliases once the handlers are roots; no miss in any run |
| `0x08002DA8`, `0x08002F54`, `0x08003EE4`, `0x08011B98`, `0x08011BB8`, `0x08011BD4`, `0x08012460`, `0x08012480` | ARM switch case slots | P2-06, which seeds whole tables from its scanner |
| `0x08011DDC`, `0x08011DE8` | return addresses in code reached only through the switch at `0x08011B90` | P2-06 |
| `0x0815A7B0`, `0x0815A7BA`, `0x0815A7C4`, `0x0815A7CE`, `0x0815A7D8`, `0x0815A7E2`, `0x0815A7EC`, `0x0815A7F6`, `0x0815A800`, `0x0815A814`, `0x0815A81E` | case targets of a Thumb switch in the race program: `cmp r0, #0xC; bhs; adr r3; ldrb r3, [r3, r0]; lsls r3, #1; add pc, r3` at `0x0815A796`-`0x0815A7A0`, a 12-entry byte table at `0x0815A7A4`. The prototype has 11 of the 12 targets (`0x0815A80A` is missing) | wait |
| `0x0815B7FC` | one case target of the same kind of switch, 12 entries at `0x0815B7C8` | wait |
| `0x0815BC70`, `0x0815BC74`, `0x0815BC78`, `0x0815BC7C`, `0x0815BC88`, `0x0815BC90` | case targets of an 11-entry byte table at `0x0815BC64` (6 of its 9 distinct targets) | wait |
| `0x0815CCAC`, `0x0815CD78`, `0x0815CE80`, `0x0815CFA8`, `0x0815D0A0`, `0x0815D22C`, `0x0815D538`, `0x0815D610`, `0x0815F598` | function pointers of the race program: words in its literal pools and tables (`0x0815D508`-`0x0815D524`, `0x0815D774`-`0x0815D778`, `0x0815E014`, `0x0815FDB0`, `0x08162A28`-`0x08162A90`). mGBA calls six of them on `boot_to_race` by frame 4,400 (`0x0815CFA8`, `0x0815D0A0`, `0x0815D22C`, `0x0815D538`, `0x0815D610` from `0x0815E1D8`; `0x0815F598` by `bx` from `0x0815FD24`) | wait |

Kept: 5; not needed: 5; P2-06: 10; waiting: 27. The 27 belong to the race program. On this build its main loop runs in a bridge that does not dispatch, so none of the nine pointers is ever dispatched and nothing here can test a seed for them; the Thumb case targets are dispatched (section 5), but the prototype's lists are partial tables, which is the reason P2-06 seeds switches from a scan rather than from miss reports. They wait for P2-10 (the race image compiled) and P2-11's miss reports, with the evidence above.

## 9. What reached `0x08001F94`

[phase2-dispatch-misses.md](phase2-dispatch-misses.md) found `0x08001F94` among the misses of the previous config, with no `bl` before it, and left open how a dispatch reaches it. Section 6 answers it: the intro player's bridge returns to `0x08001F90`, the generated code runs one instruction and stops at `0x08001F94` on the stale HALT flag, and the run loop dispatches `0x08001F94` when the next IRQ ends the halt. Its counts there (1, 1, 3 and 7 at 2,700, 3,600, 5,400 and 12,000 frames) follow the intro player's. With `static_resume_all` it is a resume alias of the function at `0x08001F84`, so it needs no seed, and the spurious halt happens all the same until the intro player stops being bridged (P2-10).

## 10. Not done here

- The switch slots (P2-06), the IWRAM images (P2-10), the comparator and the classification of the RAM differences above (P2-09).
- Thumb byte-table switches in the race program (section 8) need their whole tables: P2-06's scanner handles the ARM form only. A scan for the Thumb form is a follow-up.
- `0x0800FB14` (IRQ slot 0, stored by the multiplayer code) and `0x08004518` (the other value of the pointer at `0x03000840 + 0x28`) have static evidence but were not reached on any route run here: for P2-11's routes.
- The stale HALT flag after a bridge (section 6) is a gbarecomp bug, the same one as diagnosis §1.5 (U4 there) with a second effect: it also halts generated code after the bridge returns. It disappears from these routes once no bridge runs.

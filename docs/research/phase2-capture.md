# Phase 2 captures: sample point and first measurements

**Date:** 2026-10-11
**Scope:** P2-03 of [phase2-plan.md](../phase2-plan.md). Where gbarecomp and the mGBA harness take their per-frame records, how that was checked, and what the first captures of both engines show. The capture format is in [tools/capture/README.md](../../tools/capture/README.md).

## Pins

| | |
|---|---|
| ROM | Moto Racer Advance (Europe) `A9MP`, SHA-1 `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0` |
| BIOS | retail, SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492` |
| gbarecomp | `5e89943528aee7bc1c399bdbd035364a4b41dd10` with patches 0001, 0002 and 0005 (this task); `file:line` citations are at the pin |
| Game config | `game.toml` of PR #5 (`a7efc60`), unchanged: no P2-01 fixes, IWRAM code interpreted |
| mGBA | libmgba 0.10.5 (`26b7884`) through `tools/analysis/harness` |
| Machine | Apple M4 Pro, macOS 26.5.2, Apple clang 21; native runs headless with `SDL_AUDIODRIVER=dummy`, `GBARECOMP_SELFHEAL_RECOMPILE=0` and a fresh save |
| Browser | headless Chromium (Playwright 1.64.0), audio muted; Emscripten 6.0.10 |

"Interpreter" is gbarecomp with `GBARECOMP_FORCE_INTERP=1`; "recompiled" is the same executable without it. Frame numbers are harness frames.

**Review round 1** (PR #12) changed patch 0005 (diagnostics on standard error start with `capture: ` instead of the record prefix; region names are at most 16 characters; an empty frame list is refused; I/O writes made during multiplayer session execution are not counted; a ring allocation failure is reported once) and the harness (strict list options, `--capture-mem` accumulates, the same 16-character limit). The capture-off and capture-on runs of §2, the console-sink checks (native and browser) and the cross-check of §5 were repeated with both: same results. The §3 runs were repeated with the same options: the per-frame, line and FIFO files of both engines are byte-identical to the earlier ones.

## 1. Sample point

**Verified.** Both engines take the record of frame N at the VBlank-start event that ends frame N, after the frame is latched and before the VBlank-timed DMA, the VBlank IRQ and the next instruction:

- **gbarecomp.** `tick_devices` handles the event in this order: `mark_framebuffer_latched()`, `run_timed_dma(1)` (VBlank-timed DMA), the VBlank input hook (`input_frame`), then `request_irq(IrqVBlank)` (`src/runtime/runtime_bus_bridge.cpp:597-607`). Patch 0005 calls the capture right after the latch, before the DMA.
- **mGBA.** At VCOUNT 160, `_startHdraw` (`src/gba/video.c`) calls `GBADMARunVblank`, which schedules each VBlank-timed DMA 3 cycles later (`dma->when = now + 3 + cycles`, `src/gba/dma.c`), raises IF and schedules the IRQ 7 cycles later (`GBA_IRQ_DELAY`, `src/gba/gba.c`), increments the frame counter and sets `earlyExit`. `GBAProcessEvents` stops there, `runFrame` returns, and the harness's `afterFrame` writes the record, so no instruction runs between the event and the record. A DMA or the IRQ can come first only when the event itself is handled 3 or 7 cycles late, inside the same `mTimingTick`; neither changes RAM before the record unless it is a VBlank-timed DMA.

The plan put gbarecomp's record after the VBlank-timed DMA and asked where the harness samples. The harness samples before it, so the capture does too: then the two engines read the same point by construction. For this game the difference does not matter:

- **The game never enables a VBlank-timed DMA** on `full_race_cross`, frames 1-25,000 (harness `--watch-write` on the four DMA control registers, every write that sets the enable bit, by timing): DMA0 HBlank (18,483 enables), DMA1 and DMA2 sound FIFO (24,691 and 40), DMA3 immediate (30,500). So `run_timed_dma(1)` does nothing there, and gbarecomp's record is before and after it at once. The cup, options-save and multiplayer routes were not scanned (**unverified** there). The capture does not depend on it: both engines sample before the VBlank-timed DMA.
- **The DMA3 of race frames comes after the record, in both engines.** On `boot_to_race`, the CPU starts DMA3 at VCOUNT 174 (64 halfwords from ROM `0x083AF1D8` to OBJ VRAM `0x06011600`) and at VCOUNT 196 (128 words from EWRAM `0x02033C48` to BG VRAM `0x0600E180`), during the VBlank that follows frame 4000's record:
  - mGBA: `writes.tsv` (`--watch-frames 4001`) shows `030000A8` writing `0x80000040` and `03000090` writing `0x84000080` to `0x040000DC`, with the DMA3 transfers on the same lines, tagged frame 4001 (writes after the VBlank start of frame 4000). The record of frame 4000 equals the harness dump at frame 4000, which the harness takes at the same point: `ram_ewram` `7EDD7718` and `ram_iwram` `941D6A0C` are the CRC-32s of the dump's `ewram.bin` and `iwram.bin` (unmasked spec; DISPCNT `0x1741`, image word `0xE3A00640`).
  - gbarecomp (interpreter, driven into the race with the stock `GBARECOMP_INPUT_REPLAY` at harness frame - 2, diagnosis §7.3): `GBARECOMP_MMIO_DUMP` shows the same two writes to `0x040000DC` from the same PCs at master-clock 1,123,518,095 and 1,123,544,858, that is 17,871 and 44,634 cycles (lines 174 and 196) after frame 4000's record (clock 1,123,500,224) and before frame 4001's (1,123,781,122).

Two more checks that the engines sample the same point: on the first 3,000 frames of a boot without input, every memory field and every FIFO column is equal on every frame (§3), and the master clocks at the records agree to within -7 to +12 cycles on 2,998 frames (frame 1 at 197,143 cycles in both; frame 1000 at 280,812,231 in mGBA and 280,812,224 in gbarecomp). On frame 270, gbarecomp's clock is 47 cycles ahead, and on frame 2188, 45,722. At frame 2188 line 134 the CPU starts an immediate DMA3 of 19,200 halfwords to VRAM (harness `writes.tsv`, PC `08003380`), which spans the VBlank start. gbarecomp copies it at once and charges its stolen cycles to the clock before the devices catch up (`drain_dma_steal`, `runtime_bus_bridge.cpp:669-687`), so the VBlank event is handled with the clock past it (**likely**; not traced). The `cycles` column is therefore information, not a compared field.

## 2. Capture off, capture on

**Verified**, with `scripts/build-native.sh --without 0005` (P2-00's A/B build) as the unpatched build. For N = 240, 300, 320, 600 and 1,000 frames without input, each on the interpreter and on the recompiled build, these four runs end on the same `final_pc=` line (PC, steps, cycles, `ppu_vcount`, `ppu_frames`) and coverage banner, and write byte-identical `--dump-png` files: the unpatched build, the patched build with the capture unset, and twice the patched build with the capture on (spec, route fields, line records of the last 6 frames, FIFO bytes of every frame, the last frame raw). The two capture runs give byte-identical files. The runs cover the BIOS fade (240), the license fade (300, 320) and the intro (600, 1,000); from 300 frames on, the recompiled runs bridge 14 to 37 dispatch misses, so the bridge's new counter runs too.

| N | Final state (both backends) | Recompiled coverage |
|---|---|---|
| 240 | `final_pc=0x00000348`, `ppu_vcount=160 ppu_frames=240` | `FULLY_STATIC` |
| 300 | `0x00000348`, `160`, `300` | `NOT_STATIC dispatch_misses=14 interpreted_insns=1022` |
| 320 | `0x00000348`, `160`, `320` | `NOT_STATIC dispatch_misses=14 interpreted_insns=2142` |
| 600 | `0x00001174`, `160`, `600` | `NOT_STATIC dispatch_misses=17 interpreted_insns=44093` |
| 1000 | `0x00000348`, `ppu_vcount=88 ppu_frames=1000` | `NOT_STATIC dispatch_misses=37 interpreted_insns=6452191` |

(`steps` differs between backends; within a backend it is the same in all four runs.)

**Console sink.** `GBARECOMP_CAPTURE=-` printed the same 1,000 records as the file sink, prefix aside (`capture.py extract`, then `cmp`), recompiled, 1,000 frames. The longest line was 273 characters with `spec.txt` and the route fields. With the largest spec the parsers accept, 64 regions with 16-character names and 32 four-byte memory fields, the header row is the longest line: 1,866 characters with the prefix. Records were at most 939 characters on 1,000 frames with the line state off, and 942 on 60 frames with it on; `capture.py extract` took all of them (exit 0). Region names were limited to 16 characters in review round 1: with the 32 characters allowed before, the header could reach about 2,890 characters, past the 2,000 the page keeps (the 1,034 measured before was the header row with 3-character names). A 17-character name is refused (`capture: GBARECOMP_CAPTURE_SPEC: bad region name ...`, exit 1).

**Diagnostics.** gbarecomp's capture messages on standard error start with `capture: `, never with the record prefix, because the page prints standard error to the same console. With `GBARECOMP_CAPTURE=- GBARECOMP_CAPTURE_LINES=1-3`, which warns that line records need a file sink, `capture.py extract` of standard error followed by standard output gives the file sink's 301 records byte for byte (300 frames, recompiled).

**In the browser.** A `--dev --embed-private-rom` bundle (under `build/`, never published) in headless Chromium, with `?env=GBARECOMP_CAPTURE=-,GBARECOMP_CAPTURE_LINE_STATE=0,...&args=--window --frames 600`, printed 601 records to the console. They equal the native recompiled run of the same code, with the same variables, in every column, the master clock and the bridge count included. After review round 1 the run was repeated with `GBARECOMP_CAPTURE_LINES=1-3` added, so that a `capture: ` warning reaches the same console: `capture.py extract` gave the same 601 records, equal to the native run in every column.

## 3. Both engines, frames 1-3,000 of a boot without input

**Verified.** The harness with `--frames 3000` and gbarecomp's interpreter with `--frames 3000` (it stops at `ppu_vcount=0`) each wrote 3,000 records, frames 1-3000, with `spec.txt` and the route fields of `routes.py trace-mem`. Joined on the frame column (`capture.py join`):

| Columns | Frames that differ |
|---|---|
| `DISPCNT`, all 10 memory fields, `fifo_a_n`, `fifo_a`, `fifo_b_n`, `fifo_b`, `halt_writes` | none |
| `ram_iwram` (`0x03000000`-`0x03007DFF`) | 1: 607 |
| `ram_ewram` | 16: 294-295, 596-606, 608-609, 2155 |
| `ram_iwram_stacks` (`0x03007E00`-`0x03007FFF`, `0x03007F9C` masked) | 796, from frame 295 on |
| `io_writes` | 4: 1393-1394 and 2852-2853, each pair one write moved across the frame boundary |
| `lines` | 18: 1, 294, 296, 607, 610, 1031, 1393-1395, 1864, 1873, 2149, 2157, 2165, 2188, 2850-2852 |
| `fb` | 407, the fades and the BIOS logo (§5.1, §5.2 of the diagnosis) among them |

**Line state, frames 1-330** (`capture.py lines` on both engines' line records): 48 of 52,800 line records differ, in 3 frames, all explained by the diagnosis:

- frame 1, line 0: BG2PA, BG2PD, BG3PA, BG3PD are `0x0100` in mGBA and 0 in gbarecomp before the BIOS sets them (§7.2);
- frame 294, line 73: BG2CNT `0x0003` in mGBA, still 0 in gbarecomp, a mid-frame write landing on another line (§5.4 lists frame 294);
- frame 296, lines 0-45: VRAM_BG differs while a copy into BG VRAM is in progress during the frame (§5.4 lists frame 296).

The masks of `spec.txt` matter: with an empty spec, frames 182-187 also differ, on all 960 lines, BLDALPHA `0x1F11` in mGBA against `0xFF11` in gbarecomp (§7.2).

The other `lines` frames match the timing-shaped frames of diagnosis §5.4 (607, 610, 1031, 1393-1395, 1864, 1873, 2149-2165, 2188). Frames 2850-2852, after the diagnosis's route had left the title screen, differ the same way: VRAM_BG on 13-14 lines spaced like the title's mid-frame VRAM writes.

**For P2-09 (not classified here).** The RAM differences are where §5.4's timing differences are: EWRAM on a long copy that runs a frame apart (596-609, one 16 KiB block per frame, from a run with 16 KiB regions), IWRAM outside the stacks only on frame 607. With 16-byte regions (no masks), the stack area differs at `0x03007F80`-`0x03007F8F` on 791 frames and `0x03007F90`-`0x03007F9F` on 638, and at `0x03007E60`-`0x03007E7F` and `0x03007F70`-`0x03007F7F` on 25 frames together. The BIOS keeps its IRQ stack below `0x03007FA0` and its handler pushes r0-r3, r12 and lr there (GBATEK, "BIOS RAM Usage"), so these words would hold the registers of whatever each interrupt stopped; that this game's IRQ stack is there was not traced (**unverified**). The spec masks only `0x03007F9C` (Phase 1 §6). Whether the rest differs for timing reasons alone is **unverified**, which is why the stacks are a region of their own.

## 4. Size and cost

- `full_race_cross`, 25,000 frames, `spec.txt` plus the route fields, no line records: 3,572,946 bytes from the harness and 3,572,445 bytes from gbarecomp's interpreter (stock replay at harness frame - 2). `routes.py check full_race_cross` reads gbarecomp's file directly: the run follows the route (race image at 3291, race display at 3304, race over at 21549, against 3290, 3303 and 21794 in mGBA, diagnosis §6).
- Line records: 12,618,694 bytes for frames 1-330 (38 KB per frame), the same size from both engines; about 950 MB for a 25,000-frame race, so they are written only for requested frames.
- Wall time, harness, `full_race_cross`: 14.0 s without the capture, 23.1 s with it (0.4 ms per frame).
- Wall time, gbarecomp, two runs each: interpreter, 3,000 frames: 7.9 and 9.4 s off, 9.8 and 9.8 s on, 8.4 and 8.4 s on without line state. Recompiled, 2,400 frames (bridged from frame 1031, §5): 9.4 and 9.4 s off, 10.8 and 10.7 s on, 11.1 and 11.7 s on without line state. Runs vary by more than a second, so this only bounds the cost at about 0.5 ms per frame; the line state (a `memcmp` of VRAM, OAM and palette before each line, and a CRC-32 when they changed) is most of it on the interpreter. The browser bundle above ran with the line state off.

## 5. The HALTCNT storm, frame by frame

The plan's P2-05 needs the frames where an interpreter bridge ran BIOS IntrWait, which writes HALTCNT and IME thousands of times per frame (diagnosis §1.5), and suggested finding them in `GBARECOMP_MMIO_DUMP`. Its ring holds the last 262,144 IO writes (`kMmioCapRingSize`, `gba_io.h:59`). On PR #5's config, recompiled, 2,700 frames without input:

- `halt_writes` is 0-2 per frame up to frame 1030. It is over 100 on 918 frames, 1031-1390, 1396-1415, 2165-2184 and 2189-2706, about 10,000-12,500 per frame, with `io_writes` around 30,000-37,000; and 0 on 1416-2164, where `io_writes` is 81 per frame. The stale bridge of diagnosis §1.1 starts at VBlank 1029, and from frame 1032 to the end `bridge_insns` is 25,000-147,000 on every frame (mean 132,000), storm or not.
- At 30,000 IO writes per frame, the default ring holds about 8 frames of the storm, not the 26 that 10,000 writes per frame would give. Patch 0005 adds `GBARECOMP_MMIO_CAP_RING`: with 2,097,152 entries the dump covered frames 2641-2706 (the run stopped at 2706, diagnosis §1.3). In the browser (wasm32), the largest ring the variable accepts, 2^28 entries (6 GiB), cannot be allocated: a 120-frame run printed `[mmio-cap] cannot allocate the ring (268435456 entries, 6442450944 bytes); no MMIO writes are recorded` once, wrote an empty dump and exited 0.
- Cross-check of the capture's IO tap: on those 66 frames, the dump's IO writes and HALTCNT writes per frame (frame boundaries from the records' clocks; a write at a record's clock comes after the record) equal `io_writes` and `halt_writes` on every frame.

So P2-05 can read the storm from the per-frame records of any length of run (`halt_writes`, and `bridge_insns` for the bridge), and needs the ring only for the individual writes of a short window.

## 6. Not done here

- The comparator, its allowlists and the classification of RAM differences (P2-09).
- Replays at VBlank start and the BIOS-interpreting reference (P2-02). The race checks above used gbarecomp's stock `GBARECOMP_INPUT_REPLAY`.
- A browser driver in the repository (P2-12). The browser check above used a scratch Playwright script.

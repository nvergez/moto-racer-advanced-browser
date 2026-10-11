# Captures

Records of the emulated machine at the start of every VBlank and at every rendered line, taken the same way by gbarecomp (`GBARECOMP_CAPTURE`, [patch 0005](../../patches/gbarecomp/0005-frame-capture.patch)) and by the mGBA harness (`--capture`, [tools/analysis/harness](../analysis/harness/gbaharness.c)). Two engines, or two gbarecomp backends, are compared by joining their files on the frame column ([phase2-plan.md](../../docs/phase2-plan.md), P2-03; [ADR 0001](../../docs/adr/0001-port-via-static-recompilation.md), decision 5). How the sample point was established, and what the first captures showed, is in [phase2-capture.md](../../docs/research/phase2-capture.md).

| File | What |
|---|---|
| `spec.txt` | The mask table both engines apply at capture time: register masks, RAM regions and their masked bytes, the IWRAM image word |
| `capture.py` | `join` two per-frame files, diff two `lines` files, `extract` the records from a browser console log (stdlib, `python3 -I`; usage at its top) |
| `tests/` | Unit tests for `capture.py` on synthetic files: `python3 -I -m unittest discover tools/capture/tests` |

Capture files hold hashes, register values and RAM values of the game. They are derived from the ROM: keep them under `build/` or `analysis-out/` and never commit them.

## Taking a capture

From the repository root, with the route manifest's memory fields (the checkpoint fields of [routes.toml](../difftest/routes.toml)):

```sh
MEM=$(python3 -I tools/difftest/routes.py trace-mem)

# mGBA: writes analysis-out/runs/boot3000/capture.tsv
tools/analysis/harness/run_harness.sh --out runs/boot3000 --frames 3000 \
  --capture --capture-spec tools/capture/spec.txt --capture-mem "$MEM"

# gbarecomp, here its interpreter: writes build/cap/boot3000.tsv
mkdir -p build/cap
(cd build/native && export GBARECOMP_FORCE_INTERP=1 GBARECOMP_CAPTURE=../cap/boot3000.tsv \
   GBARECOMP_CAPTURE_SPEC=@../../tools/capture/spec.txt GBARECOMP_CAPTURE_MEM="$MEM" &&
 mkdir -p ../saves && rm -f ../saves/t.sav &&
 SDL_AUDIODRIVER=dummy GBARECOMP_SELFHEAL_RECOMPILE=0 ./MotoRacerAdvanceRecomp \
   --bios ../../bios/gba_bios.bin --rom ../../roms/moto-racer-advance.gba \
   --frames 3000 --no-window --save-path ../saves/t.sav ../../game.toml)

python3 -I tools/capture/capture.py join analysis-out/runs/boot3000/capture.tsv build/cap/boot3000.tsv
```

`join` exits 1 when a compared column differs on a common frame, and also when the two files do not cover the same frames or do not have the same columns: a run that stopped early, or one started without the spec, fails the join instead of passing on the frames it has. The frames checked are those of `--frames`, or else every frame of either file, except that a file may lack the one frame after its last when the other file ends there (a `--frames N` run can stop at N or N+1). `--allow-missing` reports missing frames and columns without failing. It exits 2 on unreadable input.

A capture of a route, from either engine, is also what `tools/difftest/routes.py check ROUTE FILE` reads to check the route's checkpoints: its `DISPCNT` and `mem_*` columns are those of `trace.tsv`.

| gbarecomp (environment) | Harness option | |
|---|---|---|
| `GBARECOMP_CAPTURE=PATH` or `-` | `--capture` | Per-frame records, to PATH (`capture.tsv` in `--out` for the harness), or to standard output (below) |
| `GBARECOMP_CAPTURE_FRAMES=LIST` | `--capture-frames LIST` | Frames that get a record. Default: every frame |
| `GBARECOMP_CAPTURE_SPEC=@FILE` or the text | `--capture-spec FILE` | The spec ([below](#spec)). Default: empty (no masks, no regions) |
| `GBARECOMP_CAPTURE_MEM=LIST` | `--capture-mem LIST` | More memory fields, `ADDR:SIZE` as for `--trace-mem` |
| `GBARECOMP_CAPTURE_LINES=LIST` | `--capture-lines LIST` | Full line records of these frames, to `STEM.lines.tsv` |
| `GBARECOMP_CAPTURE_FIFO=LIST` | `--capture-fifo LIST` | Bytes written to FIFO A and B in these frames, to `STEM.fifo.tsv` |
| `GBARECOMP_CAPTURE_RAW=LIST` | `--capture-raw LIST` | Frames as raw BGR555, to `STEM.raw/fNNNNNN.bgr555` |
| `GBARECOMP_CAPTURE_LINE_STATE=0` | | No per-line state: the `lines` column is `-` (for the browser) |
| `GBARECOMP_MMIO_CAP_RING=N` | | Size of `GBARECOMP_MMIO_DUMP`'s ring, in writes (default 262,144) |

`STEM` is the per-frame path without its `.tsv` (`capture` for the harness). A list holds frames and ranges (`1-3000;4200`) separated by `;`, `,` or spaces, in decimal or `0x` hexadecimal; the harness also takes `A+LEN`, and at most 32 entries per option. A relative gbarecomp path is relative to the directory the executable runs in. Both engines refuse a malformed variable or option and say why: a bad number, a range whose end is before its start, a list with no entry (gbarecomp treats a variable set to the empty string as unset). gbarecomp exits 1 with a line starting `capture: ` on standard error; the harness exits with a `gbaharness: ` message.

**In the browser**, `GBARECOMP_CAPTURE=-` prints every line of the per-frame file to standard output with the prefix `[capture] `, header included. The page shows standard output and standard error in the same console (`print` and `printErr` in gbarecomp's `packaging/web/bootstrap.js`), whose `line()` keeps 2,000 characters per line. Only records carry the prefix: gbarecomp's capture diagnostics start with `capture: `. With the largest spec the parsers accept (64 regions with 16-character names, 32 memory fields), the header row is the longest line, 1,866 characters with the prefix, and a record about 940; region names are limited to 16 characters for that reason. `capture.py extract LOG` turns a console log back into the per-frame file: it starts at the header row, and leaves out, with exit 1, a line longer than the console keeps or a record whose column count differs from the header's. Pass variables with `?env=`, which only a bundle built with `--dev` and served from localhost honors, and which splits on commas: use `;` inside values and `%20` for spaces, for example `?env=GBARECOMP_CAPTURE=-,GBARECOMP_CAPTURE_LINE_STATE=0,GBARECOMP_CAPTURE_MEM=0x03000000:4;0x0203F00A:1`. Full line records, FIFO bytes and raw frames need a file sink, so they are native only.

## Sample point and frame numbers

A record is taken at the start of VBlank (VCOUNT 160), right after the last visible line was rendered and the frame latched, and before the VBlank-timed DMA, the VBlank IRQ and any further instruction:

- gbarecomp: in `tick_devices` (`src/runtime/runtime_bus_bridge.cpp`), between `mark_framebuffer_latched()` and `run_timed_dma(1)`, so also before the `input_frame` hook and `request_irq(IrqVBlank)` (lines 597-607 at the pin).
- mGBA: in the harness's `afterFrame`, when `runFrame` returns after the VBlank-start event (`_startHdraw` sets `earlyExit`). mGBA schedules VBlank-timed DMA 3 cycles and the IRQ 7 cycles after that event.

Both engines sample before the VBlank-timed DMA, so they see the same memory whether or not the game enables one. On `full_race_cross`, frames 1-25,000, it never does; the other routes were not scanned (**unverified** there). The DMA3 transfers of race frames are started by the CPU at VCOUNT 174 and 196, after the record. Evidence: [phase2-capture.md](../../docs/research/phase2-capture.md).

Frames are numbered as the harness numbers them: the record of frame N is taken when mGBA's frame counter reaches N. In gbarecomp that is PPU `frame_count()` + 1 (diagnosis §7.3). The line records of frame N are the 160 lines rendered before that record, sampled right before each line is rendered: gbarecomp before `render_scanline` at HBlank start, mGBA in its renderer's `drawScanline` (also at HBlank start).

Where `--frames N` stops depends on the backend (diagnosis §7.3), so the last record of a run can be N or N+1. Join on the frame column; never compare by line number.

## Per-frame record (`capture.tsv`)

A TSV file with a header row. Hexadecimal values are upper case without `0x`, zero-padded to their width; CRC-32 is zlib's.

| Column | Compared | Content |
|---|---|---|
| `frame` | key | Harness frame number |
| `fb` | yes | CRC-32 of the 240x160 frame as little-endian 16-bit words `r \| g<<5 \| b<<10`, rows top to bottom, where each channel is the top 5 bits of the engine's 8-bit output (so the two pixel formats compare at 5-bit precision) |
| `lines` | yes | CRC-32 of the frame's line records, as text: each record exactly as `capture.lines.tsv` would hold it, newline included, in rendering order. `-` when the line state is off |
| `DISPCNT` | yes | DISPCNT, 4 digits |
| `mem_AAAAAAAA` | yes | One per memory field, in spec order then `CAPTURE_MEM` order, a repeated address once: the little-endian value of SIZE bytes at the address, 2×SIZE digits. The same column names and format as `trace.tsv`'s `--trace-mem` columns, which is what `routes.py check` reads |
| `ram_NAME` | yes | One per spec region: CRC-32 of the region's bytes, with masked bytes hashed as zero |
| `fifo_a_n`, `fifo_a` | yes | Bytes written to FIFO A (`0x040000A0`-`0x040000A3`) by the CPU and by DMA during frame N (since the previous VBlank start), in decimal, and their CRC-32 (`00000000` for none). Each write adds its bytes in address order |
| `fifo_b_n`, `fifo_b` | yes | The same for FIFO B (`0x040000A4`-`0x040000A7`) |
| `io_writes` | yes | Writes to the I/O registers (`0x04000000`-`0x040003FF`) by the CPU and DMA during frame N (since the previous VBlank start); a 32-bit write counts once |
| `halt_writes` | yes | Of those, the writes that cover HALTCNT (`0x04000301`): the BIOS writes it once per Halt or IntrWait |
| `cycles` | no | The engine's master clock when it handles the VBlank-start event (gbarecomp `g_runtime_cycles`, mGBA `mTimingGlobalTime`). Both clocks follow the video timing, so records are 280,896 cycles apart, give or take the instruction in progress; gbarecomp's clock can also be ahead by the rest of an immediate DMA that spans VBlank start (45,722 cycles on one boot frame) |
| `bridge_insns` | no | gbarecomp: instructions its interpreter bridge ran during frame N (dispatch misses). mGBA: `-` |

The FIFO, `io_writes`, `halt_writes` and `bridge_insns` counts cover frame N alone, even when a frame list skips the frames before it: both engines reset them at every VBlank start. gbarecomp's multiplayer session execution (`runtime_session_execution`) is not captured: no records, no line state, and its I/O writes are not counted.

Values are read from the engines' backing memory (gbarecomp `GbaBus::ewram_ptr()`, `iwram_ptr()`, the I/O page; mGBA the same arrays the harness dumps), never through the bus, which has side effects in gbarecomp (P2-02). Memory fields and regions must lie in EWRAM or IWRAM.

## Line records (`STEM.lines.tsv`)

`frame`, `line`, then the video registers as the I/O page holds them, each ANDed with its spec mask: `DISPCNT BG0CNT BG1CNT BG2CNT BG3CNT BG0HOFS BG0VOFS BG1HOFS BG1VOFS BG2HOFS BG2VOFS BG3HOFS BG3VOFS BG2PA BG2PB BG2PC BG2PD BG2X BG2Y BG3PA BG3PB BG3PC BG3PD BG3X BG3Y WIN0H WIN0V WIN1H WIN1V WININ WINOUT BLDCNT BLDALPHA BLDY MOSAIC` (4 digits, 8 for BG2X/Y and BG3X/Y), then `PAL0` (palette entry 0), and CRC-32s of `OAM` (1 KiB), `PAL` (1 KiB), `VRAM_BG` (`0x06000000`-`0x0600FFFF`) and `VRAM_OBJ` (`0x06010000`-`0x06017FFF`). This is the layer-1 state of comparison 2 (diagnosis §7.2), and the column set of the ppu-diffs prototypes. About 38 KB per frame, so it is written only for requested frames; the `lines` column covers every frame.

## FIFO bytes (`STEM.fifo.tsv`) and raw frames (`STEM.raw/`)

`frame`, `channel` (`A` or `B`), `n`, `bytes` (the bytes in hex, `-` for none): one row per channel for each requested frame, the bytes behind `fifo_a_n`/`fifo_a` and `fifo_b_n`/`fifo_b` (P2-15).

`fNNNNNN.bgr555`: the 76,800 bytes `fb` hashes. These are frames of the game: local only.

## Spec

One entry per line or per `;`; `#` starts a comment that runs to the end of the line. Numbers are decimal or `0x` hexadecimal; ranges are `FIRST-LAST`, inclusive.

| Entry | Meaning |
|---|---|
| `reg NAME MASK` | AND MASK into register NAME (a line-record column name, upper case) in line records |
| `ram NAME FIRST-LAST` | Hash this range as column `ram_NAME`; the range lies in EWRAM or in IWRAM. At most 64 regions; NAME is 1 to 16 letters, digits and `_` |
| `mask NAME FIRST-LAST` | Hash these bytes of region NAME as zero. At most 128 masks |
| `mem ADDR:SIZE` | Memory field `mem_ADDR`, SIZE 1, 2 or 4. At most 32 fields, spec and `CAPTURE_MEM` together |

[`spec.txt`](spec.txt) is the table for this game. Each entry says why it is there. Comparisons add masks only by editing it, with a cause for each (P2-09). Both engines must read the same spec for their files to share columns.

## Sizes and cost

Measured on the M4 Pro (details in [phase2-capture.md](../../docs/research/phase2-capture.md)):

- Per-frame records with `spec.txt` and the route fields: about 143 bytes per frame, 3.6 MB for `full_race_cross`'s 25,000 frames on either engine.
- Line records: about 38 KB per frame (12.6 MB for 330 frames). Raw frames: 76,800 bytes each. FIFO rows: about 1 KB per frame.
- Time: about 0.5 ms per frame at most for gbarecomp natively, mostly the line state (which is why the browser can turn it off); the harness ran `full_race_cross` in 23.1 s with the capture against 14.0 s without.

## Changing the format

The two implementations are `src/runtime/frame_capture.cpp` in patch 0005 and the "capture" section of `gbaharness.c`. Change both, the header comments of both, and this file together, then check that a boot without input still gives equal memory fields and FIFO columns on both engines, as in [phase2-capture.md](../../docs/research/phase2-capture.md).

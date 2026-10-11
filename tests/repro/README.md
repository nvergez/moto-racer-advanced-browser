# Synthetic repro ROMs

Small GBA ROMs that reproduce gbarecomp runtime bugs without the game, run by `scripts/repro-test.sh`: the IRQ call-return leak (`irqleak1`-`irqleak3`, patch 0003) and two code images sharing IWRAM (`overlay1`, patch 0006). They hold no Nintendo code or data, and by default they run on a stand-in BIOS generated here, so they need no BIOS dump either, and CI runs them.

| File | What |
|---|---|
| `make_rom.py` | Writes the repro ROMs: `make_rom.py irqleak1 OUT.gba`, and the same for `irqleak2`, `irqleak3` and `overlay1`. 4 KiB each, header logo left zero |
| `irqleak1.toml`, `irqleak2.toml`, `irqleak3.toml` | Their configs, for `gba_recompile` and the runtime. `[identity].sha1` pins the bytes `make_rom.py` writes |
| `irqleak3_hooks.cpp` | A gbarecomp function-entry hook, linked into `repro_irqleak3` only |
| `overlay1.toml`, `overlay1.ovl.toml` | overlay1's two configs: the main corpus, with image A at `0x03000000`, and image B's corpus, which the script compiles with `gba_recompile --output-prefix ovl_`. Only the first is the runtime's config |
| `overlay1_hooks.cpp` | The RAM overlay selector (patch 0006), linked into `repro_overlay1` only |
| `make_bios.py`, `bios.toml` | A 16 KiB stand-in BIOS and its `gba_recompile --bios` config. `make_bios.py --compare DUMP` compares it with a BIOS dump |
| `CMakeLists.txt` | Links each case's recompiled code, all its corpora included (and `<case>_hooks.cpp`, if there is one), with gbarecomp's runtime and our `src/main.cpp` into `repro_<case>` |

## The IRQ call-return leak (patch 0003)

The three cases reproduce the bug of [phase2-diagnosis.md](../../docs/research/phase2-diagnosis.md), §1.1, which `patches/gbarecomp/0003-irq-call-return-leak.patch` fixes. `irqleak1` and `irqleak2` are the two ROMs of that section, ported from its prototype: same bytes, same SHA-1s (`5ce18c7c345bcf14a1650d2d628e93b7e2159c6a` and `b59d626bc60fefd820bd9d4ae2c283f38383e031`). `irqleak3` was added for the second part of the patch (SHA-1 `cc29307835a67e64bb61af3bbf877a8b50858bb4`).

In all three, a VBlank IRQ handler at `0x08000180` calls (`bl`) a routine that tail-calls, through a pointer in EWRAM, a function `F` (`0x08000200`) that has no static entry, so every call to `F` is bridged by the interpreter, in IRQ-continuation mode.

- **irqleak1**: the interpreter performs `F`'s `bx lr` and stops at the handler's return address `0x08000188`, which has a static entry because of `static_resume_all = true`. The handler then continues natively, and the call-return frame its `bl` pushed is never popped. The main loop is `b .`. Each VBlank leaks one frame until the 1,024-entry call-return stack overflows.
- **irqleak2**: `static_resume_all = false`; the return address `0x08000194` has an entry only because a branch targets it. The main loop calls `VBlankIntrWait`. After each SWI, gbarecomp unwinds the host stack, and the main loop's return address `0x080000FC` has no entry, so it is bridged too, with the top of the call-return stack as the address to stop at: a leaked `0x08000194` that only IRQ code reaches. That is how the game failed (a leaked `0x08004E10` as the stop PC of the bridge for `0x08003E70`). In 600 frames that bridge interprets 84 million instructions (table below); over 2,000 frames the stack overflows as in irqleak1.
- **irqleak3**: irqleak1's code under another header title and game code, and an executable that registers a function-entry hook at `F` (`irqleak3_hooks.cpp`: `gba_mod_register_function_entry_plugin`, with a callback that sets R15 to LR and returns 1). The bridge checks hooks before it interprets each instruction, and when one handles the call it returns at once; in IRQ-continuation mode it does so without popping the caller's frame (`src/runtime/runtime_arm_default_aborts.cpp:534-541` at the pin). That exit does not reach the heal-to-static check that the first part of 0003 fixes, so the frame still leaks with that part alone. The second part, which drops frames left above the IRQ's entry depth when `runtime_irq()` returns, is what stops it. This case is the test of that second part: without it, both parts are in one patch and `--without` cannot separate them. The hook registry is part of gbarecomp's runtime whether or not its mods are built (`CMakeLists.txt:390` at the pin), and mods are off here (`GBARECOMP_ENABLE_MODS`, default `OFF`, `:371-373`). Only the mod runtime resets hooks (`src/runtime/mod_runtime.cpp:2065`, called from `src/runtime/runtime.cpp:1541` when mods are built), so the hook is installed once, before `main()`.

`make_rom.py`'s docstring and comments give the code, instruction by instruction.

## Two code images in IWRAM (patch 0006)

`overlay1` reproduces what `patches/gbarecomp/0006-ram-overlay-selector.patch` is for: two code images that a program copies to the same IWRAM address at different times. Moto Racer Advance does this with its front end's and its race program's images, both at `0x03000000` ([phase2-diagnosis.md](../../docs/research/phase2-diagnosis.md), §3; [ADR 0001](../../docs/adr/0001-port-via-static-recompilation.md), decision 2). It is also the repro the diagnosis asks for with the upstream candidate U5 (§9). SHA-1 `5b0ac75c53f66d5e0ece14cf390a34b8cbec9289`.

Once per frame, the main loop copies image A (4 words, from ROM `0x08000400`) to `0x03000000` one word at a time and calls it there through `bx r12`, then does the same with image B (5 words, from ROM `0x08000500`). A writes `0xA1` and B `0xB2` to the result word `0x02000010`. The main loop clears that word before each call, logs it after A to `0x02000000` and after B to `0x02000004`, counts completed cycles at `0x02000008`, and waits for the next VBlank (`VBlankIntrWait`). The two images differ at every offset, as the game's do. B's fifth word stays at `0x03000010` after A is copied over B, as the longer race image's tail stays behind the front end's image in the game.

gbarecomp compiles one function per address and instruction set in a corpus. `overlay1.toml` declares image A as a `[[code_copy]]` at `0x03000000`. `overlay1.ovl.toml` declares image B there, and the script compiles it into a second corpus with `gba_recompile --output-prefix ovl_ --no-symbol-map` (`generated/overlay1.ovl/`, table `ovl_kDispatchTable`; a symbol map would register itself as the cartridge's only one). Without a selector, the main table answers for `0x03000000` whatever is resident: after B is copied, A's generated body runs, and the log reads `0xA1`, `0xA1`, with no dispatch miss, even under `GBARECOMP_STRICT_STATIC=1`. That is the silent corruption of the diagnosis's control run (§3.1, option N). `overlay1_hooks.cpp` installs a selector through 0006's `g_runtime_ram_overlay_select`. It compares the live IWRAM word at the dispatch target with the word at the same offset of each image's ROM source, and answers 0 for A (the main table), 1 with `ovl_kDispatchTable` for B, and -1 for neither (a dispatch miss). With it, the log reads `0xA1`, `0xB2`.

The script runs overlay1 twice, both times under `GBARECOMP_STRICT_STATIC=1` with gbarecomp's capture (patch 0005, [tools/capture/README.md](../../tools/capture/README.md)) recording the three log words at every VBlank start:

- `overlay1`, with the selector: fully static, `0xA1` then `0xB2` in every record once a cycle has completed, and at least N/2 cycles in N frames;
- `overlay1-noselector`, the control (`MRA_REPRO_OVERLAY_SELECTOR=0` leaves the selector uninstalled): fully static too, and `0xA1` then `0xA1`. It shows that the repro tells the two apart.

With `--without 0006 --expect-failure`, gbarecomp has no selector API (`tests/repro/CMakeLists.txt` looks for `g_runtime_ram_overlay_select` in `runtime_arm.h`), the hooks install nothing, and the one run must log `0xA1`, `0xA1`, fully static, as on the gbarecomp pin.

## The stand-in BIOS

gbarecomp needs a 16 KiB BIOS image twice: recompiled at build time, so that IRQs and SWIs run through generated code, and loaded at run time (its size is checked; a SHA-1 other than the retail one only warns, and `scripts/repro-test.sh` passes `--bios-sha1` so there is no warning). With `[bios] skip_intro = true` the repro ROMs use only three things from it, so `make_bios.py` writes just those: the exception vectors, an IRQ dispatcher that calls the user handler stored at `0x03007FFC` and returns, and `VBlankIntrWait` (SWI `0x05`), which enables IME and halts until the handler flags a VBlank in `0x03007FF8`. Any other SWI returns at once; reset is a branch to itself. It is not a GBA BIOS and is not meant for games.

**Where it comes from.** The behavior comes from GBATEK's descriptions: "BIOS Interrupt handling" (the handler pointer at `0x03007FFC`, called in IRQ mode, and the IntrWait flags at `0x03007FF8`), "BIOS Halt Functions" (`VBlankIntrWait`), "GBA System Control" (`HALTCNT`) and "ARM CPU Exceptions" (vectors, banked registers, SPSR). No code is taken from a BIOS image.

The first version of this file, reviewed in PR #11, was not that clean. Its IRQ dispatcher was the six-instruction listing that GBATEK's "BIOS Interrupt handling" prints, which is the retail BIOS's own code at `0x128`-`0x13F`, and its SWI entry and exit matched the retail BIOS too. A word-by-word comparison with the retail dump (SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492`) found 14 of its 41 words in four runs, in the retail order: `0x20`-`0x37` = retail `0x128`-`0x13F`, `0x40`-`0x47` = `0x140`-`0x147`, `0x50`-`0x57` = `0x150`-`0x157`, `0x9C`-`0xAB` = `0x17C`-`0x18B`. Where the SWI sequences came from is **unverified**. The current version was rewritten so that no sequence matches: other registers, another order, the dispatcher subtracts 4 from `lr` up front and returns with one `ldmfd sp!, {r0-r3, r12, pc}^`, and the SWI handler saves `r0`, `r1` and `lr` and returns with `ldmfd sp!, {r0, r1, pc}^`.

`python3 tests/repro/make_bios.py --compare bios/gba_bios.bin` checks this against a dump. It prints only the stand-in's own offsets and words, and exits 1 if two consecutive words of the stand-in equal two consecutive words of the dump, at any offset. On the retail dump above (2026-10-11): no such run, and 5 of the 39 nonzero words occur somewhere in the dump on their own, all common single instructions:

| Stand-in | Word | Instruction | Occurrences in the dump |
|---|---|---|---|
| `0x18` | `EA000000` | `b 0x20` (the IRQ vector; the same encoding is a branch over one word anywhere) | 2 |
| `0x2C` | `E28FE004` | `add lr, pc, #4` | 1 |
| `0x30` | `E3A0C301` | `mov r12, #0x04000000` | 4 |
| `0x60` | `E3A00001` | `mov r0, #1` | 1 |
| `0x74` | `E3A00000` | `mov r0, #0` | 2 |

A finer check (a scratch script, not committed) found none of the stand-in's 8-byte windows, taken at its 4-byte-aligned offsets, anywhere in the dump at a 2-byte alignment either.

`bios.toml` seeds `0x38`, where the user handler returns: the dispatcher sets `lr` with `add lr, pc, #4` and jumps with `ldr pc, [r12, #-4]`, which ends the function, so discovery cannot find it (the same issue as the Cult-of-GBA BIOS's return point, [open-bios.md](../../docs/research/open-bios.md) §3). `static_resume_all = true` gives the instruction after the Halt an entry; the runtime re-dispatches it once the interrupt has been served. In every passing run below, the only bridged PCs are the ones the repros are built to miss, `F` and, in irqleak2, `0x080000FC`: none in the BIOS.

`--bios PATH` runs the same tests on a BIOS dump instead, recompiled with gbarecomp's `bios/gba_bios.toml` as for the game. Both give the same results.

## Running

```sh
scripts/repro-test.sh                                   # all cases, stand-in BIOS: they must pass
scripts/repro-test.sh --without 0003 --expect-failure   # A/B build: irqleak1-3 must overflow
scripts/repro-test.sh --without 0006 --expect-failure   # A/B build: overlay1 must run image A for B
scripts/repro-test.sh --without 0003 --without 0006 --expect-failure   # both, one A/B build
scripts/repro-test.sh --bios bios/gba_bios.bin          # on a BIOS dump
scripts/repro-test.sh irqleak2 --frames 600             # one case, another length
```

The script generates the BIOS image and the ROMs into `build/repro/roms/` and checks their SHA-1s against the configs, recompiles them with `gba_recompile`, builds `build/repro/native/repro_<case>`, and runs each case headless (`SDL_AUDIODRIVER=dummy`, `GBARECOMP_SELFHEAL_RECOMPILE=0`, `--bios-skip-intro`, 2,000 frames) in `build/repro/run/<run>/`, whose `out.log` is the run's output: one run per irqleak case, two for overlay1 (`overlay1` and `overlay1-noselector`). A case named twice runs once. A case can have more corpora than its main one: each `<case>.<prefix>.toml` is compiled with `--output-prefix <prefix>_` into `generated/<case>.<prefix>/`, and `CMakeLists.txt` links them all.

An irqleak run passes when it exits 0 after at least the requested frames, bridged `F` (`bridged 0x08000200` in the runtime's miss report, so the leak path ran: a run where `F` got a static entry fails), interprets at most 10 instructions per frame, and prints none of: `generated call-return stack overflow`, `SELF-HEAL bridge ... exceeded`, `did not iret`. irqleak1 and irqleak2 must also print no `runtime_irq: dropped` line: the first part of 0003 must leave the second part nothing to drop. irqleak3 must print at least one. overlay1's two runs must end as "Two code images in IWRAM" above says. `--expect-failure` runs only the cases whose fix `--without` leaves out (0003 for the irqleak cases, 0006 for overlay1; a case named on the command line whose patch is in the build is an error), and each run must end the way its bug makes it end: an irqleak run must exit 134 (SIGABRT) with `generated call-return stack overflow at return_pc=` the case's leaked address (`0x08000188` for irqleak1 and irqleak3, `0x08000194` for irqleak2); overlay1 must exit 0, fully static, with image A's result logged for image B. Each run is limited to 300 s and to 256 MiB per file it writes; a run killed by either is reported as such (exit code 142, SIGALRM, or 153, SIGXFSZ). `--without NAME` builds under `build/without-NAME/repro/` (A/B builds, [patches/gbarecomp/README.md](../../patches/gbarecomp/README.md)). From a warm build tree a run of the script takes under 10 s on an M4 Pro (4-5 s for the three irqleak cases on 2026-10-11; about 10 s for all five runs with the build of the runtime, the same day).

## Results

2026-10-11, macOS arm64 (M4 Pro, Apple clang 21), gbarecomp `5e89943`, the stand-in BIOS of this version (SHA-1 `87467856c6608b3851f67893f7d6d5dd2fb949bd`). "Series" is what `scripts/apply-patches.sh` applied; 0001 and 0002 do not touch these paths. Each row was run with the stand-in BIOS and with the retail BIOS dump (SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492`), with the same results except where two numbers are given (stand-in, then retail).

| Case | Series | Exit | Frames | Interpreted instructions | Message |
|---|---|---|---|---|---|
| irqleak1 | 0001-0004 | 0 | 2,000 | 2,000 (`F`, once per IRQ) | none |
| irqleak2 | 0001-0004 | 0 | 2,000 | 4,001 (`F` 2,001 times, `0x080000FC` 2,000 times) | none |
| irqleak3 | 0001-0004 | 0 | 2,000 | 0 (`F` bridged 2,000 times, each time handled by the hook) | `runtime_irq: dropped 1 call-return frame(s) ... (top return_pc=0x08000188, event #N)` for N = 1, 2, 4 ... 1024 |
| irqleak1, irqleak3 | 0001, 0002, 0004 (`--without 0003`) | 134 | | | `generated call-return stack overflow at return_pc=0x08000188` |
| irqleak2 | 0001, 0002, 0004 (`--without 0003`) | 134 | | | `generated call-return stack overflow at return_pc=0x08000194` |
| irqleak1-3 | 0001, 0002 (`--without 0003 --without 0004`) | 134 | | | as above |
| irqleak1-3 | 0001-0003 (`--without 0004`) | 0 | 2,000 | as with 0001-0004 | as with 0001-0004 |
| irqleak2, 600 frames | 0001, 0002 | 0 | 601 | 84,293,566 / 84,290,465, nearly all in the bridge for `0x080000FC`, entered once | `did not iret` once |
| irqleak2, 600 frames | 0001, 0002, 0004 | 134 | | | `generated call-return stack overflow at return_pc=0x08000194` |

The first version of the stand-in BIOS gave the same results, except 84,292,558 interpreted instructions in the 600-frame row. That count depends on the BIOS image; why was not traced.

With 0003, 0004 (the end-of-run watchdog) does not change these runs: no bridge is running when they reach their last frame. Without 0003, the 600-frame irqleak2 run shows both 0004's bug and why 0004 must come with 0003. On the pin, the runaway bridge is still running at frame 600, the next IRQ hits the watchdog, and the run stops at frame 601. With 0004 it overflows instead. The likely mechanism is the one the diagnosis traced in the game (§1.3), not traced here: the abandoned handler is interpreted and reaches the leaked stop PC, which ends the bridge; with 0004 the handler runs natively, so the bridge keeps going and frames keep leaking. The game shows the same pattern (0004's header). The 600-frame runs are not part of the script's checks: in its default mode they fail on purpose.

With 0005 and 0006 added (series 0001-0006), the 2,000-frame irqleak rows are unchanged on both BIOS images, and `--without 0003` gives the same overflows on the stand-in BIOS (2026-10-11).

overlay1, 2,000 frames, under `GBARECOMP_STRICT_STATIC=1` (2026-10-11). The first two rows were run on both BIOS images, the last two on the stand-in BIOS. Every run is `self_heal_coverage=FULLY_STATIC dispatch_misses=0 interpreted_insns=0` and ends after 2,001 cycles (one before the first VBlank, then one per frame); "Log" is what every capture record holds:

| Run | Series | Exit | Selector | Log after A, after B |
|---|---|---|---|---|
| overlay1 | 0001-0006 | 0 | on | `0xA1`, `0xB2` |
| overlay1-noselector | 0001-0006 | 0 | off | `0xA1`, `0xA1` |
| overlay1 | 0001-0005 (`--without 0006`) | 0 | unavailable | `0xA1`, `0xA1` |
| overlay1 | 0001, 0002, 0004, 0005 (`--without 0003 --without 0006`) | 0 | unavailable | `0xA1`, `0xA1` |

Not part of the script: 0006 also keeps PCs the selector claims out of the self-heal tier, because heals are keyed by PC and mode only. A scratch variant of overlay1 checked it with RAM healing on (`GBARECOMP_SELFHEAL_RECOMPILE=1`, `GBARECOMP_RAM_OVERLAY_HEAL=1`, gcc backend, 600 frames), a main corpus without image A and a selector that answers 0 for A and -1 for B. A's first dispatch is an unclaimed miss, and 0x03000000 is healed from A's bytes. With 0006, B's claimed miss is bridged (3,005 interpreted instructions, 5 per cycle) and logs `0xB2`; with the guard in `runtime_dispatch_miss` removed, the heal tier runs A's heal for B, which logs `0xA1` (1,202 native heal calls, 0 interpreted). The variant's config and selector are not committed; 0006's header describes them.

## How the encodings were checked

Every instruction in `make_rom.py` and `make_bios.py` is written as its 32-bit encoding with the assembly in a comment. The generated images were disassembled with Capstone 5.0.9 (`capstone.Cs(CS_ARCH_ARM, CS_MODE_ARM)`, Python), and every instruction matched its comment; the rewritten stand-in BIOS was checked the same way. overlay1 was checked with LLVM's disassembler instead (Apple LLVM 21: the ROM wrapped in an ELF object with `.incbin` and `clang -target armv4t-none-eabi -c`, then `objdump -d --triple=armv4t-none-eabi`), with the same result. Neither tool is needed to run the tests.

## Adding a case

Add a builder to `make_rom.py` (or a new generator), a `<case>.toml` with the ROM's SHA-1 and a `note` on every `[[extra_func]]` and `[[code_copy]]`, optionally more corpora (`<case>.<prefix>.toml`) and a `<case>_hooks.cpp`, and the case, the patch whose bug it reproduces (`case_patch`) and its pass and failure conditions to `scripts/repro-test.sh`. Keep Nintendo data out: no header logo, and no code taken from a BIOS image or from a listing of one; if the stand-in BIOS changes, run `make_bios.py --compare` on a dump and update the table above.

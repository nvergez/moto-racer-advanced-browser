# Synthetic repro ROMs

Small GBA ROMs that reproduce gbarecomp runtime bugs without the game, run by `scripts/repro-test.sh`. They hold no Nintendo code or data, and by default they run on a stand-in BIOS generated here, so they need no BIOS dump either, and CI runs them.

| File | What |
|---|---|
| `make_rom.py` | Writes the repro ROMs: `make_rom.py irqleak1 OUT.gba`, `make_rom.py irqleak2 OUT.gba`. 4 KiB each, header logo left zero |
| `irqleak1.toml`, `irqleak2.toml` | Their configs, for `gba_recompile` and the runtime. `[identity].sha1` pins the bytes `make_rom.py` writes |
| `make_bios.py`, `bios.toml` | A 16 KiB stand-in BIOS and its `gba_recompile --bios` config |
| `CMakeLists.txt` | Links each case's recompiled code with gbarecomp's runtime and our `src/main.cpp` into `repro_<case>` |

## The IRQ call-return leak (patch 0003)

`irqleak1` and `irqleak2` reproduce the bug of [phase2-diagnosis.md](../../docs/research/phase2-diagnosis.md), §1.1, which `patches/gbarecomp/0003-irq-call-return-leak.patch` fixes. They are the two ROMs of that section, ported from its prototype: same bytes, same SHA-1s (`5ce18c7c345bcf14a1650d2d628e93b7e2159c6a` and `b59d626bc60fefd820bd9d4ae2c283f38383e031`).

In both, a VBlank IRQ handler at `0x08000180` calls (`bl`) a routine that tail-calls, through a pointer in EWRAM, a function `F` (`0x08000200`) that has no static entry. The interpreter bridges `F` in IRQ-continuation mode, performs its `bx lr`, and stops at the handler's return address because that address has a static entry. The handler then continues natively, and the call-return frame its `bl` pushed is never popped.

- **irqleak1**: `static_resume_all = true` gives the return address `0x08000188` its entry. The main loop is `b .`. Each VBlank leaks one frame until the 1,024-entry call-return stack overflows.
- **irqleak2**: `static_resume_all = false`; the return address `0x08000194` has an entry only because a branch targets it. The main loop calls `VBlankIntrWait`. After each SWI, gbarecomp unwinds the host stack, and the main loop's return address `0x080000FC` has no entry, so it is bridged too, with the top of the call-return stack as the address to stop at: a leaked `0x08000194` that only IRQ code reaches. That is how the game failed (a leaked `0x08004E10` as the stop PC of the bridge for `0x08003E70`). In 600 frames that bridge interprets 84 million instructions (table below); over 2,000 frames the stack overflows as in irqleak1.

`make_rom.py`'s docstring and comments give the code, instruction by instruction.

## The stand-in BIOS

gbarecomp needs a 16 KiB BIOS image twice: recompiled at build time, so that IRQs and SWIs run through generated code, and loaded at run time (its size is checked; a SHA-1 other than the retail one only warns, and `scripts/repro-test.sh` passes `--bios-sha1` so there is no warning). With `[bios] skip_intro = true` the repro ROMs use only three things from it, so `make_bios.py` writes just those: the exception vectors, the IRQ dispatcher that calls the user handler stored at `0x03007FFC` and returns, and `VBlankIntrWait` (SWI `0x05`), which enables IME and halts until the handler flags a VBlank in `0x03007FF8`. Any other SWI returns at once; reset is a branch to itself. It was written from GBATEK's descriptions ("BIOS Interrupt handling" lists the dispatcher's six instructions; "BIOS Halt Functions"), not from a BIOS image. It is not a GBA BIOS and is not meant for games.

`bios.toml` seeds `0x30`, where the user handler returns: the dispatcher sets `lr` with `add lr, pc, #0` and jumps with `ldr pc, [r0, #-4]`, which ends the function, so discovery cannot find it (the same issue as the Cult-of-GBA BIOS's return point, [open-bios.md](../../docs/research/open-bios.md) §3). `static_resume_all = true` gives the instruction after the Halt an entry; the runtime re-dispatches it once the interrupt has been served. In every passing run below, the only bridged PCs are the ones the repros are built to miss, `F` and, in irqleak2, `0x080000FC`: none in the BIOS.

`--bios PATH` runs the same tests on a BIOS dump instead, recompiled with gbarecomp's `bios/gba_bios.toml` as for the game. Both give the same results.

## Running

```sh
scripts/repro-test.sh                                   # both cases, stand-in BIOS: they must pass
scripts/repro-test.sh --without 0003 --expect-failure   # A/B build: both must overflow
scripts/repro-test.sh --bios bios/gba_bios.bin          # on a BIOS dump
scripts/repro-test.sh irqleak2 --frames 600             # one case, another length
```

The script generates the BIOS image and the ROMs into `build/repro/roms/` and checks their SHA-1s against the configs, recompiles them with `gba_recompile`, builds `build/repro/native/repro_<case>`, and runs each case headless (`SDL_AUDIODRIVER=dummy`, `GBARECOMP_SELFHEAL_RECOMPILE=0`, `--bios-skip-intro`, 2,000 frames, a 300 s limit) in `build/repro/run/<case>/`, whose `out.log` is the run's output. A run passes when it exits 0 after at least the requested frames, interprets at most 10 instructions per frame, and prints none of: `generated call-return stack overflow`, `SELF-HEAL bridge ... exceeded`, `did not iret`, and `runtime_irq: dropped`. The last one is the second half of 0003, which drops frames still left above an IRQ's entry depth when `runtime_irq()` returns; the first half must leave it nothing to drop. With `--expect-failure`, every run must instead exit 134 (SIGABRT) with `generated call-return stack overflow`. `--without NAME` builds under `build/without-NAME/repro/` (A/B builds, [patches/gbarecomp/README.md](../../patches/gbarecomp/README.md)). From a warm build tree a run of the script takes under 10 s on an M4 Pro.

## Results

2026-10-11, macOS arm64 (M4 Pro, Apple clang 21), gbarecomp `5e89943`. "Series" is what `scripts/apply-patches.sh` applied; 0001 and 0002 do not touch these paths. Each row was run with the stand-in BIOS and with the retail BIOS dump (SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492`), with the same results except where two numbers are given (stand-in, then retail).

| Case | Series | Exit | Frames | Interpreted instructions | Message |
|---|---|---|---|---|---|
| irqleak1 | 0001-0004 | 0 | 2,000 | 2,000 (`F`, once per IRQ) | none |
| irqleak2 | 0001-0004 | 0 | 2,000 | 4,001 (`F` 2,001 times, `0x080000FC` 2,000 times) | none |
| irqleak1 | 0001, 0002, 0004 (`--without 0003`) | 134 | | | `generated call-return stack overflow at return_pc=0x08000188` |
| irqleak2 | 0001, 0002, 0004 (`--without 0003`) | 134 | | | `generated call-return stack overflow at return_pc=0x08000194` |
| both | 0001, 0002 (`--without 0003 --without 0004`) | 134 | | | as above |
| both | 0001-0003 (`--without 0004`) | 0 | 2,000 | as with 0001-0004 | none |
| irqleak2, 600 frames | 0001, 0002 | 0 | 601 | 84,292,558 / 84,290,465, nearly all in the bridge for `0x080000FC`, entered once | `did not iret` once |
| irqleak2, 600 frames | 0001, 0002, 0004 | 134 | | | `generated call-return stack overflow at return_pc=0x08000194` |

With 0003, 0004 (the end-of-run watchdog) does not change these runs: no bridge is running when they reach their last frame. Without 0003, the 600-frame irqleak2 run shows both 0004's bug and why 0004 must come with 0003. On the pin, the runaway bridge is still running at frame 600, the next IRQ hits the watchdog, and the run stops at frame 601. With 0004 it overflows instead. The likely mechanism is the one the diagnosis traced in the game (§1.3), not traced here: the abandoned handler is interpreted and reaches the leaked stop PC, which ends the bridge; with 0004 the handler runs natively, so the bridge keeps going and frames keep leaking. The game shows the same pattern (0004's header). The 600-frame runs are not part of the script's checks: in its default mode they fail on purpose.

## How the encodings were checked

Every instruction in `make_rom.py` and `make_bios.py` is written as its 32-bit encoding with the assembly in a comment. The generated images were disassembled with Capstone 5.0.9 (`capstone.Cs(CS_ARCH_ARM, CS_MODE_ARM)`, Python), and every instruction matched its comment. Capstone is not needed to run the tests.

## Adding a case

Add a builder to `make_rom.py` (or a new generator), a `<case>.toml` with the ROM's SHA-1 and a `note` on every `[[extra_func]]`, and the case and its pass and failure conditions to `scripts/repro-test.sh`. Keep Nintendo data out: no header logo, no BIOS code.

# Toolchain

How to build this project on macOS from a fresh clone: prerequisites, setup, the engine build and tests, the smoke test, the native and web builds of the game, and known issues.

**Verified** on 2026-10-10 on an Apple M4 Pro running macOS 26.5.2, with gbarecomp pinned at `5e89943528aee7bc1c399bdbd035364a4b41dd10`, from a clean clone of this branch. Linux (Ubuntu 24.04) is covered by CI only. Windows is not covered. The game-dependent steps were run once with the owner's dump of the Europe ROM (SHA-1 `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0`) and BIOS; see [First real-ROM smoke test](#first-real-rom-smoke-test).

## What needs the ROM and the BIOS

| Step | Script | Needs the ROM and BIOS? |
|---|---|---|
| Fetch gbarecomp, apply our patches | `scripts/setup.sh` | No |
| Build gbarecomp, run its tests | `scripts/test-engine.sh` | No |
| Recompile and run free test ROMs, natively and in WebAssembly | `scripts/smoke-test.sh` | No |
| Recompile the game (BIOS + ROM to C++) | `scripts/regen.sh` | Yes |
| Native executable | `scripts/build-native.sh` | Yes |
| Browser bundle, local server | `scripts/build-web.sh`, `scripts/serve-web.sh` | Yes |

Generating the game's C++ needs only the ROM, but every build of the game also recompiles the BIOS dump and links it, and the runtime loads the dump at start. So the scripts that build the game check for both files up front and stop with one message listing whatever is missing. They read `roms/moto-racer-advance.gba` and `bios/gba_bios.bin` unless you pass `--rom PATH` and `--bios PATH` (see [Inputs](#inputs)).

## Prerequisites

| Tool | Version verified | Needed for | Install on macOS |
|---|---|---|---|
| Xcode Command Line Tools (Apple clang) | clang 21.0.0 (`clang-2100.1.1.101`) | Everything | `xcode-select --install` |
| CMake | 4.4.0 (3.20 or newer) | Everything | `brew install cmake` |
| Ninja | 1.13.2 | Optional; the scripts fall back to Makefiles | `brew install ninja` |
| Python | 3.11.6 (3.9 or newer) | gbarecomp's tools and tests, the web build, the local server | Preinstalled or `brew install python` |
| Git | 2.50.1 | Submodules | With the Command Line Tools |
| curl, shasum | System | Test ROM download, hash checks | Preinstalled |
| SDL2 | 2.32.10 (Homebrew) | Optional; windowed native runs. Without it the native build is headless only | `brew install sdl2` |
| Node.js | 24.14.0 | Optional; gbarecomp's browser unit tests | `brew install node` or nvm |
| Emscripten | 6.0.10, through emsdk | Web builds and the web half of the smoke test | See below |

Nothing else was installed for this work. gbarecomp's configure step downloads toml++ v3.4.0 (pinned commit `30172438`) with CMake's FetchContent, so the first configure needs network access.

### Emscripten

gbarecomp's browser host was validated with Emscripten 6.0.10 (`gbarecomp/packaging/web/README.md`). Install exactly that with emsdk:

```sh
git clone --depth 1 --branch 6.0.10 https://github.com/emscripten-core/emsdk.git ~/emsdk
~/emsdk/emsdk install 6.0.10
~/emsdk/emsdk activate 6.0.10
```

You don't need to source `emsdk_env.sh` yourself: when `emcc` is not on `PATH`, the scripts source `$EMSDK/emsdk_env.sh`, or `~/emsdk/emsdk_env.sh` when `EMSDK` is unset, the same way gbarecomp's `build_web.sh` does. CI installs Emscripten with these three commands.

Homebrew's `emscripten` formula was at 6.0.12 on 2026-10-10 (`brew info emscripten`), not the validated 6.0.10, and it pulls in openjdk and a second Python. It has not been tried here. The scripts warn when `emcc` is not 6.0.10.

## From a fresh clone

```sh
git clone https://github.com/nvergez/moto-racer-advanced-browser.git
cd moto-racer-advanced-browser
scripts/setup.sh
```

Do not clone with `--recurse-submodules`. That would also fetch gbarecomp's netplay submodules and its Android SDL fork, which the build does not use. `scripts/setup.sh`:

1. Checks the prerequisites and prints their versions.
2. Checks out the `gbarecomp` submodule at the pinned commit, then only one of its own submodules, `external/arm-recomp-core`, which the build needs. `--with-netplay` adds `external/recomp-net` and `external/rbengine`, needed only for `GBARECOMP_NETPLAY=ON`.
3. Sets `submodule.platform/android/third_party/SDL.update = none` in gbarecomp's local git config, so a later `git submodule update --init --recursive` skips the Android SDL fork ("Skipping submodule"). It is local config, nothing is committed.
4. Applies `patches/gbarecomp/` to the submodule's working tree (see [Known issues](#known-issues)). `git status` then shows `gbarecomp (modified content)`. That is expected.
5. Reports whether `roms/moto-racer-advance.gba` and `bios/gba_bios.bin` are in place.

## Engine build and tests

```sh
scripts/fetch-test-roms.sh   # optional: adds two tests that run recompiled test ROMs
scripts/test-engine.sh
```

`scripts/test-engine.sh` configures gbarecomp in `build/gbarecomp` (Release, Ninja), builds every target and runs `ctest`. Expected: `100% tests passed out of 52`, or `out of 50` without the test ROMs. Without Node, the ten browser JS tests are not registered. On the M4 Pro: configure about 4 s, build about 7 s (56 s of CPU time), tests about 10 s.

The build prints about 140 compiler warnings from gbarecomp's own sources, mostly `-Wmismatched-tags`, and the macOS linker warns `ignoring duplicate libraries`. Neither is an error.

By hand, without the scripts:

```sh
cmake -S gbarecomp -B build/gbarecomp -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build/gbarecomp
ctest --test-dir build/gbarecomp
```

## Smoke test, without the ROM or the BIOS

```sh
scripts/smoke-test.sh                # both halves
scripts/smoke-test.sh --native-only
scripts/smoke-test.sh --web-only     # needs Emscripten
```

It runs the real pipeline on two freely licensed test ROMs from [jsmolka/gba-tests](https://github.com/jsmolka/gba-tests) (MIT), `arm.gba` and `thumb.gba`, which test the CPU and report the first failing test in register r12.

1. `scripts/fetch-test-roms.sh` downloads them from the repository at pinned commit `a7113b6` into `test-roms/` (gitignored) and checks their SHA-256. They are the binaries committed upstream: they are assembled with FASMARM, an x86 tool, so building them here was not practical.
2. Each ROM is recompiled with `gba_recompile` and its config in `tests/smoke/`, with the same function `recompile_rom` in `scripts/lib/common.sh` that recompiles the game. `arm.gba` gives 350 functions, `thumb.gba` 210.
3. **Native.** Each ROM's generated code is linked into gbarecomp's test ROM runner, which boots the cartridge directly without a BIOS, and run. Both pass. Then our own executable (`CMakeLists.txt`, `src/main.cpp`) is built with the `arm.gba` code in place of the game's, and started without a BIOS. It must stop with `BIOS resolution failed`, which shows that it starts and parses its arguments, `--state-dir` included.
4. **Web.** The same runners are compiled with Emscripten and run under Node, the one emsdk ships. Both pass with the same final state as natively. gbarecomp's browser host (`packaging/web/main.cpp`, the browser backend, the canonical link options from `cmake/web_host_link_options.cmake`) is linked with each ROM's code. `web/game-lib`, the project `scripts/build-web.sh` hands to `build_web.sh`, is built with `emcc`.

Everything goes to `build/smoke/`, logs to `build/smoke/logs/`. On the M4 Pro the whole test takes under a minute from a warm build tree.

## Inputs

Both files are gitignored and must never be committed or downloaded. See the dumping guide (`docs/guides/dumping-rom-and-bios.md`, PR #1).

| File | What | Check |
|---|---|---|
| `roms/moto-racer-advance.gba` | Your dump of the Europe cartridge (`AGB-A9MP`) | 4194304 bytes, SHA-1 `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0` (`[identity].sha1` in `game.toml`) |
| `bios/gba_bios.bin` | Your dump of the GBA BIOS | 16384 bytes, SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492` (the value gbarecomp expects, `gbarecomp/bios/gba_bios.toml`) |

To use files somewhere else, pass `--rom PATH` and `--bios PATH` to `scripts/regen.sh`, `scripts/build-native.sh` or `scripts/build-web.sh` (and to `scripts/setup.sh`, which only reports whether they exist). Relative paths are taken from the current directory. Every path can also be overridden with environment variables, listed at the top of `scripts/lib/common.sh`: `MRA_ROM`, `MRA_BIOS`, `MRA_GAME_CONFIG`, `MRA_BIOS_CONFIG`, `MRA_BUILD_DIR`, `MRA_GENERATED_DIR`.

Before anything is built, the scripts check the ROM's SHA-1 and size and the BIOS's SHA-1 and size against `game.toml`, and stop with one message on any mismatch. The USA cartridge (`A9ME`) is a different binary and is refused.

## The game config

`game.toml` is pinned to one ROM revision, *Moto Racer Advance (Europe) (En,Fr,De,Es,It)*. Every value was read from the owner's dump on 2026-10-10:

```sh
shasum -a 1 roms/moto-racer-advance.gba     # [identity].sha1 and [rom].sha1
md5 -q roms/moto-racer-advance.gba          # [identity].md5
stat -f %z roms/moto-racer-advance.gba      # [program].size: 4194304 = 0x00400000
build/gbarecomp/gba_scan roms/moto-racer-advance.gba
                                            # game_code=A9MP, entry_target=0x080000c0,
                                            # save_type=unknown
```

The SHA-1, MD5, CRC32 (`8CB19DA0`) and size match the No-Intro entry recorded in the game-facts research (PR #4). `build/gbarecomp/gba_scan` exists after `scripts/test-engine.sh` or any build script.

`[save]` is set to `type = "sram"`, `size = 32768`. The ROM carries Nintendo's save library ID string `SRAM_F_V102` (one match, at ROM offset `0x1C6D0`, by byte search), but gbarecomp's detector only knows the `SRAM_V` prefix, so `gba_scan` reports `save_type=unknown` and the game would find no save chip without this section. The runtime confirms the setting at start: `save_config source=game-config type=SRAM size=32768 (detected=unknown ...)`.

Still open, as `TODO(phase1)` comments in `game.toml`: `[[code_copy]]` entries for the two IWRAM code images (they share the base address `0x03000000`), `[[extra_func]]` seeds for the separately linked race program and for what the runtime's miss reports find, and `[[data_range]]` entries if discovery ever decodes data as code.

The ROM SHA-1 is also built into the executable: CMake reads `[identity].sha1` and `[game].name` from `game.toml` into `mra_build_config.h`, so the hash is written in one place only. The scripts still refuse any `"TBD"` value and CMake refuses an `[identity].sha1` that is not a SHA-1, so a config for another revision can be started from placeholders safely.

## Native build

```sh
scripts/build-native.sh            # regenerate, then build build/native/MotoRacerAdvanceRecomp
scripts/build-native.sh --no-regen # reuse generated/
scripts/build-native.sh --lle      # LLE scanline renderer, into build/native-lle
scripts/build-native.sh --rom ~/dumps/mra.gba --bios ~/dumps/gba_bios.bin
```

What it does:

1. `scripts/regen.sh`: checks both inputs against `game.toml` (hashes, sizes, no placeholder left), builds `gba_recompile` and `gba_scan`, recompiles the BIOS into `generated/bios` with `gbarecomp/bios/gba_bios.toml`, and the ROM into `generated/game` with `--max-functions 65536`. It fails if the number of emitted functions reaches that cap, because `gba_recompile` drops seeds past it without a warning. Logs: `build/logs/recompile-bios.log`, `build/logs/recompile.log`.
2. Configures the top-level `CMakeLists.txt` into `build/native` and builds `MotoRacerAdvanceRecomp`. Configuring fails unless the recompiled BIOS is picked up. The executable links through gbarecomp's `target_link_gbarecomp_runtime_stack()`, gets a 16 MiB main-thread stack on macOS, and compiles the generated shards at `-O1 -g0` as MKSC does.

`generated/` is gitignored: it is a translation of copyrighted code. The script prints a headless run command at the end, which runs to the title screen with runtime healing off:

```sh
cd build/native
GBARECOMP_SELFHEAL_RECOMPILE=0 ./MotoRacerAdvanceRecomp \
  --bios ../../bios/gba_bios.bin --rom ../../roms/moto-racer-advance.gba \
  --frames 2700 --no-window --save-path ../saves/smoke.sav \
  --dump-png ../frame-2700.png ../../game.toml
```

Run from `build/native` so the runtime's working-directory files (`recomp_cache/`, `recomp_coverage_A9MP.json`, `recomp_master_misses_A9MP.toml.frag`, `bios.cfg`, `rom.cfg`) stay under `build/`. At exit the runtime prints a coverage banner (`self_heal_coverage=... dispatch_misses=... interpreted_insns=...`); read it after every run. `--dump-png` writes the last frame, which is a picture of the game: keep it under `build/`. Phase 1 discovery runs need more care with saves and coverage files; the integration study's playbook (docs/research/gbarecomp-integration.md, §10, PR #2) covers them.

## Web build

```sh
scripts/build-web.sh               # regenerate, then build build/web-PRIVATE/
scripts/build-web.sh --no-regen --embed-private-rom --dev
scripts/serve-web.sh [port]        # http://127.0.0.1:8080/ by default
```

`scripts/build-web.sh` runs gbarecomp's `packaging/web/build_web.sh` with `web/game-lib` as the project, so the browser compiles the same `generated/game` as the native build. It keeps every build product under `build/` (`build/web/runtime`, `build/web/game`) and writes the bundle to `build/web-PRIVATE/`. `--embed-private-rom` copies the ROM and the BIOS into the bundle so the page needs no file picker; `--dev` lets a page on localhost take `?args=` and `?env=`. `scripts/serve-web.sh` uses gbarecomp's `serve.py`, which listens on 127.0.0.1 only and sends the COOP/COEP headers that pthreads need.

**Do not publish `build/web-PRIVATE/`**, with or without `--embed-private-rom`: `game.wasm` is compiled from the recompiled ROM and the recompiled Nintendo BIOS. Whether anything is ever published is the owner's decision (integration study, §5.6). `web-PRIVATE/` is gitignored wherever it appears.

The stock page links gbarecomp's generic `main()`, so no game-owned code reaches the browser yet. That will need our own link step (Phase 3); `tests/smoke/CMakeLists.txt` already links the browser host that way, with `gbarecomp_web_host_link_options()`.

## How the game-dependent scripts were verified

The scripts that need the ROM and the BIOS were run end to end once, in a scratch directory, with stand-ins passed through the environment variables above: `arm.gba` in place of the game, and the MIT-licensed [Cult-of-GBA BIOS](https://github.com/Cult-of-GBA/BIOS) (`bios.bin` at `a30e9a9`, SHA-1 `2e41f9d30ecdf1c4540edf89ac16f49bf327edb7`) in place of the retail BIOS, with the BIOS config from the appendix of [docs/research/open-bios.md](research/open-bios.md). Nothing from that run is committed.

- `scripts/regen.sh`: recompiled the BIOS (132 functions, 823 resume aliases, as in open-bios.md §3) and the ROM.
- `scripts/build-native.sh`, with and without `--lle`, and with `--no-regen`: configure picked up the recompiled BIOS, the executable linked. Headless, it booted the recompiled BIOS (`bios_boot=LLE (real intro)`) and ran 3000 frames with `self_heal_coverage=FULLY_STATIC dispatch_misses=0`. With `--bios-skip-intro` it ran the test ROM to its final loop, also fully static.
- `scripts/build-web.sh --no-regen --embed-private-rom --dev` built the bundle, `scripts/serve-web.sh` served it with the COOP/COEP headers, and the page ran in the Claude desktop app's browser pane (Chromium): the recompiled BIOS drew its boot screen through WebGL. That run is how the `--state-dir` bug below was found.

That run used neither the retail BIOS nor the game ROM; the next section does, natively. No browser other than that Chromium pane was tried.

## First real-ROM smoke test

A time-boxed session (about 45 minutes) on 2026-10-10, to see how far the scaffold gets with the real inputs. Outcomes only: the generated code, logs, miss reports and screenshots stay out of git, in ignored directories or outside the repository.

- **Inputs**: the owner's dump of the Europe ROM (SHA-1 `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0`, `A9MP`) and the retail BIOS (SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492`), passed with `--rom` and `--bios`. gbarecomp at `5e89943` with `patches/gbarecomp/` applied. M4 Pro, macOS 26.5.2, Apple clang 21.
- **Reference**: libmgba 0.10.5 through a small headless harness (not in this repository), real BIOS boot, no input, screenshots at the same frame numbers. Frames were compared pixel by pixel after reducing both to 5 bits per channel, because the two tools expand GBA colors to 8 bits differently.
- **No input was given.** Everything below is the boot, the intro and the title screen's attract loop.

### Generation and build

`scripts/build-native.sh --rom ... --bios ...` into the default ignored `generated/` and `build/`, with gbarecomp's tools already built by `scripts/test-engine.sh`: regenerate, configure and build took 10 s wall.

- BIOS recompiled with `gbarecomp/bios/gba_bios.toml`; configure picked it up.
- ROM: `gba_recompile` emitted **2,259 functions** (1,612 ARM, 647 Thumb; its discovery summary counts 2,258 found by walking the code and 1 from the config alone), with no `[[extra_func]]` or other config entries. Far below the 65,536 cap. 16 MB of C++ in 16 shards; the recompiled BIOS is 3.8 MB.
- The executable built with about 2,000 warnings from the generated code (unused variables) and no errors.

### Boot, with runtime healing off

This is the command `scripts/build-native.sh` prints (`GBARECOMP_SELFHEAL_RECOMPILE=0`): every dispatch miss is run by the interpreter, nothing is compiled at run time, and the banner reports coverage honestly.

**It boots through the real BIOS intro to the title screen.** The runtime starts with `bios_boot=LLE (real intro)` and `save_config source=game-config type=SRAM size=32768`. Last frame of each run against mGBA at the same frame:

| Frame | Screen | Pixels that differ from mGBA |
|---|---|---|
| 240 | BIOS logo | 3,622 of 38,400: mGBA is mid-fade, gbarecomp shows the logo at full brightness (cause **unverified**) |
| 450 | License screen | 0 |
| 1800 | Intro animation | 0 |
| 2450 | Title, "Press start" | 0 |
| 2700 | Title, "Press start" | 0 |

2,700 frames took 10.5 s wall; headless runs are not paced to 60 Hz.

Coverage at exit (`self_heal_coverage`):

| Frames | Coverage | Distinct dispatch misses | Interpreted instructions |
|---|---|---|---|
| 120, 240 | `FULLY_STATIC` | 0 | 0 |
| 450 | `NOT_STATIC` | 15 | 9,427 |
| 900 | `NOT_STATIC` | 37 (2 in IWRAM, 35 in ROM) | 4,485,773 |
| 2700 | `NOT_STATIC` | 37 | 228,577,755 |

- **IWRAM**: two entry points, `0x030004DC` (Thumb, bridged 4,349 times by frame 2700) and `0x03000708` (ARM, 4,512 times). Both lie in the front end's IWRAM image (`0x03000000`-`0x03000833`, copied from ROM `0x081596FC`). Once the interpreter enters IWRAM it keeps going, and nearly all of the 228 million interpreted instructions come from there (see the healing runs below). That is expected without `[[code_copy]]` entries.
- **ROM**: 35 misses, each 0x4 to 0x1C0 bytes past the start of a function that discovery did find (the runtime names the nearest one: the busiest miss, `0x08012460`, bridged 12,180 times, sits next to the function at `0x0801245C`). The runtime flags 4 groups as jump-table candidates. None was reviewed or added to `game.toml` yet.

Problems seen, all repeatable (the same `--frames` gives the same output every time):

1. **IRQ watchdog.** `runtime_irq: handler at depth 1 did not iret after 4000000 dispatches (R15=0x00000018, cpsr=0x60000092) — abandoning` appears once in the 1800-, 2450- and 2700-frame runs, and 173 times in the 1300-frame run, which also overshot to 1,391 frames.
2. **3600 frames aborts** (SIGABRT, exit code 134): `SELF-HEAL bridge for 0x08003E70 exceeded 200000000 instructions without returning to stop_pc=0x08004E10 (current pc=0x00000364)`. The interpreter, entered at a ROM miss, never reached the PC it was meant to return to (`0x08004E10`, where the shorter runs end) and was in the BIOS when it gave up.
3. **The result depends on `--frames`.** Runs stopped at different frame counts take different paths before the stop (the 1300-frame run hits the watchdog 173 times, the 1800-frame run once), so the frame count is part of a run's input. With `GBARECOMP_PRESENT_IN_PLACE=0` (headless runs default to "present in place, unwind at final frame only") every run from 1300 to 3600 frames aborts the same way, with a bridge for `0x08003D84`. Why is **unverified**.

### Boot, with runtime healing on

By default gbarecomp also compiles each missed function with the host C++ compiler (its banner says `backend=gcc`) into `build/native/recomp_cache/`, and a later run loads them from there at start (`warm_loaded=` in the banner). RAM-resident code is healed only with `GBARECOMP_RAM_OVERLAY_HEAL=1`. `GBARECOMP_HEAL_CACHE` moves the cache, which is how the RAM-healing pair below got a cache of its own.

| Run | Frames reached | Distinct misses | Healed to native | Interpreted instructions | Watchdog | Wall |
|---|---|---|---|---|---|---|
| Healing on, empty cache, 2700 frames | 2706 | 37 | 35 (failed: the 2 in IWRAM) | 228,577,755 | 1 | 11 s |
| Healing on, that cache, 3600 frames | 3605 | 16 | 47 | 218,628,312 | 1 | 11 s |
| Healing and RAM healing on, empty cache, 3600 frames | 3600 | 102 | 102 | 82,501 | 0 | 29 s |
| Healing and RAM healing on, that cache, 3600 frames | 3600 | 55: 52 IWRAM, 2 EWRAM, 1 ROM | 55 | 12 | 0 | 5 s |

Healing ROM misses alone leaves almost all interpretation in place (218 million instructions), which shows that the interpreted instructions come from the IWRAM entries. With RAM healing as well, the second run interpreted 12 instructions, the watchdog stayed quiet, the 3600-frame run finished, and frame 3600 (the title's attract animation) is identical to mGBA's in both RAM-healing runs. One EWRAM entry, `0x0203D7EA`, is where the mGBA harness saw the game read the save area during boot. Coverage still reads `NOT_STATIC`: healed code is not statically recompiled code, so this is a diagnostic result, not a build.

### Not reached

- **The race program and its IWRAM image** (ROM `0x083F6820`), which needs input to reach a race. Whether recompiled dispatch can tell the two IWRAM images apart is still open.
- **Saves**: no SRAM write happened in 3,600 frames, as in mGBA up to frame 4,400, so no save file was written.
- **The game in a browser.** `scripts/build-web.sh --no-regen --rom ... --bios ...` built the bring-your-own-ROM bundle from the same generated code in 19 s (`game.wasm` 4.4 MB, no ROM or BIOS inside), but it was not opened in a browser.

Next steps, for Phase 1: declare the IWRAM images (`[[code_copy]]`), review the ROM misses and jump-table candidates into `[[extra_func]]` / `[[jump_table]]` entries, and find out what the IRQ watchdog and the never-returning bridge are.

## Known issues

1. **The stock browser bundle exits at launch at our pin.** The page always passes `--state-dir` (`gbarecomp/packaging/web/bootstrap.js:62`), and the runtime's argument parser rejects it: `internal: value flag --state-dir is missing from kCliValueFlags`, exit code 1 (`src/runtime/runtime.cpp:791-799`, check at lines 868-871). Seen in the browser and natively. `patches/gbarecomp/0001-cli-accept-state-dir.patch` adds the flag to the table; `scripts/setup.sh` and the build scripts apply it, and the smoke test fails without it. Upstreamable.
2. **The other game repositories do not link on macOS as written.** They pass `-Wl,--start-group`, which Apple's linker rejects. Our `CMakeLists.txt` uses gbarecomp's `target_link_gbarecomp_runtime_stack()` instead.
3. **Stack size on macOS.** A macOS main thread gets 8 MiB; Windows and the web reserve 16 MiB. Our executable links with `-stack_size 0x1000000`. The game thread that `--tcp` creates still gets 512 KiB (integration study, §7.2), so prefer `--tcp-observe` for debugging.
4. **`gba_recompile` caps function discovery at 4096 by default, silently.** `scripts/regen.sh` passes `--max-functions 65536` and checks the emitted count against it.
5. **HALT ends only on an interrupt the CPU takes** (seen with the stand-in BIOS). gbarecomp's single-player loop clears HALT only when IME is set and CPSR.I is clear (`src/runtime/runtime_bus_bridge.cpp:774-793`, `src/gba/gba_io.h:151-153`). On hardware HALT ends as soon as `IE AND IF` is non-zero, whatever IME and CPSR say ([GBATEK, BIOS Halt Functions](https://problemkaputt.de/gbatek-bios-halt-functions.htm)); gbarecomp's own multiplayer loop does that (`src/runtime/multiplayer_session.cpp:157-160`). The Cult-of-GBA boot screen halts with IME off and never reaches the cartridge (PC stays at `0x00000C08`). This matters for an open-BIOS build. Whether the game ever halts with IME off is **unverified**.
6. **`--bios-skip-intro` / `[bios].skip_intro` leaves the BG2 and BG3 affine matrices at zero.** The handoff it synthesizes sets only CPU state (`src/runtime/bios_hle.cpp:518-540`). After a real boot, BG2PA, BG2PD, BG3PA and BG3PD should be 0x100: mGBA initializes them so (`GBAIOInit`, `src/gba/io.c:339-342` at tag 0.10.5), and the Cult-of-GBA BIOS source lists the same values as what the official BIOS leaves, as measured by its authors on emulators. Not checked against the retail BIOS (**unverified**). In the stand-in run, `arm.gba` drew its result text into mode 4 VRAM, but every frame came out one flat color, with BG2PA = BG2PD = 0 over the debug server. A game that uses bitmap or affine modes without writing those registers itself would render wrong with the intro skipped. Keep the intro until this is fixed or ruled out for the game.
7. **Homebrew Emscripten is not the validated version** (6.0.12 against 6.0.10). Use emsdk.
8. **The co-simulation coordinator fails on macOS** (`oracle/gba_cosim.py` passes Windows-only `creationflags`). A one-line patch is described in `patches/gbarecomp/README.md`; it will be added when the co-simulation is first used.
9. **The runtime writes into its working directory**: `recomp_cache/`, `recomp_coverage_*.json`, `recomp_master_misses_*.toml.frag`, `bios.cfg`, `rom.cfg`. Run it from `build/native`. `.gitignore` covers these names in case a run starts at the repository root.
10. **Warnings that are not errors**: about 140 compiler warnings in gbarecomp's sources; about 2,000 more (`-Wunused-variable`, `-Wunused-but-set-variable`) when compiling the recompiled BIOS and game; `ld: warning: ignoring duplicate libraries` on macOS; em++ `-pthread + ALLOW_MEMORY_GROWTH may run non-wasm code slowly`, from gbarecomp's own browser link options.
11. **gbarecomp's `web_bootstrap_tests` is timing-sensitive.** The test waits a fixed 40 event-loop turns after each simulated file pick, but the page hashes the file with `crypto.subtle.digest`, which Node finishes on its thread pool. On the `ubuntu-24.04` CI runner it failed in both runs, at a different check each time; on the M4 Pro it passes. Delaying every digest by 1 ms reproduces the failure on macOS every time. `patches/gbarecomp/0002-web-test-wait-for-pick.patch` makes the test wait for the line each pick logs (10 s deadline); the page itself is unchanged. Upstreamable.
12. **Runtime problems seen with the game ROM**: the IRQ watchdog, a self-heal bridge that never returns, and results that depend on `--frames`. See [First real-ROM smoke test](#first-real-rom-smoke-test).

## CI

`.github/workflows/ci.yml` runs on every pull request and on pushes to `main`, with no ROM and no BIOS:

- `shellcheck -x` over `scripts/`.
- **native** on `macos-15` (Apple silicon, with SDL2) and `ubuntu-24.04` (GNU ld, no SDL2): `setup.sh`, `fetch-test-roms.sh`, `test-engine.sh` (all of gbarecomp's tests, the two test ROM tests included) and `smoke-test.sh --native-only`. On Ubuntu, gbarecomp's `web_bootstrap_tests` needs `patches/gbarecomp/0002` (known issue 11).
- **web smoke** on `ubuntu-24.04`: emsdk 6.0.10, cached by version, then `smoke-test.sh --web-only`.

The full gbarecomp build is small (186 build steps), so CI builds all of it and caches only the emsdk install.

## Directory layout

| Path | Tracked | Contents |
|---|---|---|
| `gbarecomp/` | Submodule | gbarecomp at the pin |
| `CMakeLists.txt`, `src/` | Yes | Native host: `main.cpp` and the build-config template |
| `game.toml` | Yes | Game config for the Europe ROM (`A9MP`); Phase 1 TODOs as comments |
| `web/game-lib/` | Yes | The generated game as a library for `build_web.sh` |
| `tests/smoke/` | Yes | Smoke test project and test ROM configs |
| `patches/gbarecomp/` | Yes | Local fixes to gbarecomp, applied by `scripts/apply-patches.sh` |
| `scripts/` | Yes | Everything above |
| `roms/`, `bios/` | No | Private inputs |
| `generated/` | No | Recompiled BIOS and game |
| `test-roms/` | No | Downloaded test ROMs |
| `build/` | No | All build output, logs, `web-PRIVATE/` bundles |

# Toolchain

How to build this project on macOS from a fresh clone: prerequisites, setup, the engine build and tests, the smoke test, the repro ROMs, the native and web builds of the game, and known issues.

**Verified** on 2026-10-10 on an Apple M4 Pro running macOS 26.5.2, with gbarecomp pinned at `5e89943528aee7bc1c399bdbd035364a4b41dd10`, from a clean clone of this branch. Linux (Ubuntu 24.04) is covered by CI only. Windows is not covered. The game-dependent steps were run once with the owner's dump of the Europe ROM (SHA-1 `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0`) and BIOS; see [First real-ROM smoke test](#first-real-rom-smoke-test).

## What needs the ROM and the BIOS

| Step | Script | Needs the ROM and BIOS? |
|---|---|---|
| Fetch gbarecomp, apply our patches | `scripts/setup.sh` | No |
| Build gbarecomp, run its tests | `scripts/test-engine.sh` | No |
| Recompile and run free test ROMs, natively and in WebAssembly | `scripts/smoke-test.sh` | No |
| Recompile and run the synthetic repro ROMs, natively | `scripts/repro-test.sh` | No (a BIOS dump is optional, `--bios`) |
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
| Perl | 5.34.1 (System) | `scripts/repro-test.sh`: the time limit on each run (`alarm`) | Preinstalled on macOS and on the Ubuntu CI runner |
| SDL2 | 2.32.10 (Homebrew) | Optional; windowed native runs. Without it the native build is headless only | `brew install sdl2` |
| Node.js | 24.14.0 | Optional; gbarecomp's browser unit tests | `brew install node` or nvm |
| Emscripten | 6.0.10, through emsdk | Web builds and the web half of the smoke test | See below |

Nothing else was installed for this work. gbarecomp needs toml++ v3.4.0 (MIT, pinned commit `30172438`); `scripts/setup.sh` downloads its single header once (see step 5 below), so setup needs network access and the build steps after it do not.

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
4. Applies the patch series in `patches/gbarecomp/` to the submodule's working tree (see [Local gbarecomp patches](#local-gbarecomp-patches)). `git status` then shows `gbarecomp (modified content)`. That is expected.
5. Downloads `toml.hpp` from toml++ at the commit gbarecomp pins, checks its SHA-256, and puts it in `gbarecomp/third_party/tomlpp/`, a path gbarecomp ignores and looks in first. Without it, every new build tree clones toml++ from GitHub (known issue 12). If gbarecomp's pin ever moves to another toml++ commit, the script warns and leaves the fetching to gbarecomp.
6. Reports whether the ROM and the BIOS are in place (`roms/moto-racer-advance.gba` and `bios/gba_bios.bin`, or the files given with `--rom` and `--bios`).

## Engine build and tests

```sh
scripts/fetch-test-roms.sh   # optional: adds two tests that run recompiled test ROMs
scripts/test-engine.sh
```

`scripts/test-engine.sh` configures gbarecomp in `build/gbarecomp` (Release, Ninja), builds every target and runs `ctest`. Expected: `100% tests passed out of 52`, or `out of 50` without the test ROMs. Without Node, the ten browser JS tests are not registered. On the M4 Pro: configure about 4 s, build about 7 s (56 s of CPU time), tests about 10 s.

With the test ROMs fetched first, the build prints about 520 compiler warnings (524 in a fresh build tree on the M4 Pro, summing the `N warnings generated` lines): 296 `-Wunused-but-set-variable` and 196 `-Wunused-variable`, nearly all in generated test code. 394 come from the recompiled test ROMs (`build/gbarecomp/test_rom_{arm,thumb}_gen`, built only when the test ROMs are present) and 92 from `codegen_tests_generated`. The other 38 come from gbarecomp's own sources and tests and from toml++. The macOS linker also warns `ignoring duplicate libraries`. None of these is an error.

By hand, without the scripts:

```sh
scripts/apply-patches.sh   # the pin plus the full series, e.g. after an A/B build
cmake -S gbarecomp -B build/gbarecomp -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build/gbarecomp
ctest --test-dir build/gbarecomp
```

These commands take no lock and compile whatever `gbarecomp/` holds, so do not run them while a build script runs in the same checkout (see [Local gbarecomp patches](#local-gbarecomp-patches)).

## Local gbarecomp patches

`patches/gbarecomp/` holds a series of patches to gbarecomp (what each fixes: [its README](../patches/gbarecomp/README.md)). `scripts/apply-patches.sh` applies them in name order, each on top of the pin plus the patches before it, and every build script runs it first, so the submodule is always the pin plus the series when something is built.

```sh
scripts/apply-patches.sh --check    # exit 0 if gbarecomp/ is the pin plus the series
scripts/apply-patches.sh --reverse  # back to the pin
scripts/apply-patches.sh --diff     # anything else in gbarecomp/
```

A hand edit in `gbarecomp/` stops the script, and with it every build script, before anything is written; the message lists the files. `scripts/apply-patches.sh --write-patch patches/gbarecomp/NNNN-name.patch` turns such an edit into the next patch of the series, or refreshes an existing one. The script keeps a stamp, scratch git objects and the build lock in `build/gbarecomp-patches/`; with a matching stamp the check takes about 0.1 s. `--check` also fails when `gbarecomp/` is not at the commit this repository records.

**A/B builds.** `--without NAME` on `scripts/build-native.sh`, `build-web.sh`, `regen.sh`, `test-engine.sh` or `smoke-test.sh` (or `MRA_WITHOUT_PATCHES="NAME ..."`) builds with that patch left out, for example to show that a bug comes back without its fix. Everything goes under `build/without-NAME/`, the generated code included, so the normal build directories are never written from another series. `scripts/serve-web.sh --without NAME` serves the A/B bundle. Example: `scripts/smoke-test.sh --native-only --without 0001` fails on the `--state-dir` bug that 0001 fixes ([Known issues](#known-issues), 1).

The A/B build switches `gbarecomp/` itself, and the tree keeps the variant until the next normal build script or `scripts/apply-patches.sh` run; the build says so at the end. So builds in one checkout run one at a time: the build scripts hold a lock for their whole run, and one started meanwhile waits. To build two series at once, use a second git worktree.

`tests/tooling/apply-patches-test.sh` tests all of this on a toy repository, with no game data; CI runs it.

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

## Repro ROMs, without the game

```sh
scripts/repro-test.sh                                   # must pass
scripts/repro-test.sh --without 0003 --expect-failure   # A/B: irqleak1-3 must fail without 0003
scripts/repro-test.sh --without 0006 --expect-failure   # A/B: overlay1 must fail without 0006
scripts/repro-test.sh --bios bios/gba_bios.bin          # the same on a BIOS dump
```

[`tests/repro/`](../tests/repro/README.md) holds small ROM generators (Python, no Nintendo data, header logo left zero) that reproduce gbarecomp runtime bugs: the IRQ call-return leak that `patches/gbarecomp/0003` fixes, in three forms, and two code images sharing IWRAM, which `patches/gbarecomp/0006`'s RAM overlay selector handles (`overlay1`). `irqleak1` and `irqleak2` take the path the game took, which the first part of 0003 fixes; `irqleak3` adds a function-entry hook (`tests/repro/irqleak3_hooks.cpp`) so that the leak takes a path only the second part covers. The script generates them, recompiles them with `gba_recompile` and their configs, links each with gbarecomp's runtime and our `src/main.cpp`, and runs them headless for 2,000 frames with the intro skipped. A run passes when it reaches its last frame with exit code 0, bridged the function the leak goes through (`0x08000200`), interprets at most 10 instructions per frame, and prints none of the runtime's overflow, runaway-bridge and IRQ-watchdog messages; `irqleak3` must also show the second part of 0003 at work (`runtime_irq: dropped`), and the other two must not. With `--without 0003 --expect-failure`, every irqleak case must instead abort with `generated call-return stack overflow` at its leaked return address (exit code 134), as on the gbarecomp pin. `overlay1` copies two images to IWRAM `0x03000000` in turn and calls each; image B is compiled into a second corpus (`--output-prefix ovl_`), and `tests/repro/overlay1_hooks.cpp` installs a selector. Under `GBARECOMP_STRICT_STATIC=1`, with the selector, it must be fully static and log each image's own result; without it (`MRA_REPRO_OVERLAY_SELECTOR=0`, the control run, or `--without 0006 --expect-failure`), it is fully static too but logs image A's result for image B ([tests/repro/README.md](../tests/repro/README.md), "Two code images in IWRAM"). A run killed by the script's limits is reported as such: 300 s per run (exit code 142, SIGALRM) and 256 MiB per file it writes (exit code 153, SIGXFSZ).

gbarecomp needs a 16 KiB BIOS image to recompile and to load. By default the script uses a stand-in written for these tests, `tests/repro/make_bios.py`: the exception vectors, an IRQ dispatcher and `VBlankIntrWait`, written from GBATEK's descriptions. No code in it is taken from a BIOS image. GBATEK also prints the retail BIOS's IRQ dispatcher, and the first version of the stand-in copied it (six instructions), with an SWI entry and exit that matched the retail ones too; the review of PR #11 found this, and the stand-in was rewritten. `make_bios.py --compare bios/gba_bios.bin` now finds no two consecutive words in common with the retail dump (SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492`) at any offset, and 5 single words, all common instructions ([tests/repro/README.md](../tests/repro/README.md), "The stand-in BIOS"). So the test needs neither the game nor a BIOS dump, and CI runs it. `--bios PATH` uses a dump instead, recompiled with gbarecomp's BIOS config; both give the same results ([tests/repro/README.md](../tests/repro/README.md), "Results"). Output goes to `build/repro/`; each run's log is `build/repro/run/<case>/out.log`. From a warm build tree it takes under 10 s on the M4 Pro.

## Inputs

Both files are gitignored and must never be committed or downloaded. See the dumping guide (`docs/guides/dumping-rom-and-bios.md`, PR #1).

| File | What | Check |
|---|---|---|
| `roms/moto-racer-advance.gba` | Your dump of the Europe cartridge (`AGB-A9MP`) | 4194304 bytes, SHA-1 `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0` (`[identity].sha1` in `game.toml`) |
| `bios/gba_bios.bin` | Your dump of the GBA BIOS | 16384 bytes, SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492` (the value gbarecomp expects, `gbarecomp/bios/gba_bios.toml`) |

To use files somewhere else, pass `--rom PATH` and `--bios PATH` to `scripts/regen.sh`, `scripts/build-native.sh` or `scripts/build-web.sh` (and to `scripts/setup.sh`, which only reports whether they exist). Relative paths are taken from the current directory. Every path can also be overridden with environment variables, listed at the top of `scripts/lib/common.sh`: `MRA_ROM`, `MRA_BIOS`, `MRA_GAME_CONFIG`, `MRA_BIOS_CONFIG`, `MRA_BUILD_DIR`, `MRA_GENERATED_DIR`, and for A/B builds `MRA_WITHOUT_PATCHES`.

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
scripts/build-native.sh --without 0003  # A/B build without patch 0003, into build/without-0003/
scripts/build-native.sh --rom ~/dumps/mra.gba --bios ~/dumps/gba_bios.bin
```

What it does:

1. `scripts/regen.sh`: checks both inputs against `game.toml` (hashes, sizes, no placeholder left), builds `gba_recompile` and `gba_scan`, recompiles the BIOS into `generated/bios` with `gbarecomp/bios/gba_bios.toml`, and the ROM into `generated/game` with `--max-functions 65536`. It fails if the number of emitted functions reaches that cap, because `gba_recompile` drops seeds past it without a warning. Logs: `build/logs/recompile-bios.log`, `build/logs/recompile.log`.
2. Configures the top-level `CMakeLists.txt` into `build/native` and builds `MotoRacerAdvanceRecomp`. Configuring fails unless the recompiled BIOS is picked up. The executable links through gbarecomp's `target_link_gbarecomp_runtime_stack()`, gets a 16 MiB main-thread stack on macOS, and compiles the generated shards at `-O1 -g0` as MKSC does.

`generated/` is gitignored: it is a translation of copyrighted code. The script prints a headless run command at the end, which runs to the title screen with runtime healing off. With the default paths it is this, which the script prints with absolute paths, quoted for the shell:

```sh
rm -f build/saves/smoke.sav   # start from no save
cd build/native
GBARECOMP_SELFHEAL_RECOMPILE=0 ./MotoRacerAdvanceRecomp \
  --bios ../../bios/gba_bios.bin --rom ../../roms/moto-racer-advance.gba \
  --frames 2700 --no-window --save-path ../saves/smoke.sav \
  --dump-png frame-2700.png ../../game.toml
```

Run from `build/native` so the runtime's working-directory files (`recomp_cache/`, `recomp_coverage_A9MP.json`, `recomp_master_misses_A9MP.toml.frag`, `bios.cfg`, `rom.cfg`) stay under `build/`. At exit the runtime prints a coverage banner (`self_heal_coverage=... dispatch_misses=... interpreted_insns=...`); read it after every run. `--dump-png` writes the last frame, which is a picture of the game: keep it under `build/`. Phase 1 discovery runs need more care with saves and coverage files; the integration study's playbook (docs/research/gbarecomp-integration.md, §10, PR #2) covers them.

## Web build

```sh
scripts/build-web.sh               # regenerate, then build build/web-PRIVATE/
scripts/build-web.sh --no-regen --embed-private-rom --dev
scripts/serve-web.sh [port]        # http://127.0.0.1:8080/ by default
scripts/serve-web.sh --without 0001 [port]   # the A/B bundle of build-web.sh --without 0001
```

`scripts/build-web.sh` runs gbarecomp's `packaging/web/build_web.sh` with `web/game-lib` as the project, so the browser compiles the same `generated/game` as the native build. It keeps every build product under `build/` (`build/web/runtime`, `build/web/game`) and writes the bundle to `build/web-PRIVATE/`. `--embed-private-rom` copies the ROM and the BIOS into the bundle so the page needs no file picker; `--dev` lets a page on localhost take `?args=` and `?env=`. `scripts/serve-web.sh` uses gbarecomp's `serve.py`, which listens on 127.0.0.1 only and sends the COOP/COEP headers that pthreads need.

**Do not publish `build/web-PRIVATE/`**, with or without `--embed-private-rom`: `game.wasm` is compiled from the recompiled ROM and the recompiled Nintendo BIOS. Whether anything is ever published is the owner's decision (integration study, §5.6, PR #2). `web-PRIVATE/` is gitignored wherever it appears.

With the game, the page currently stops at the title screen (known issue 13). The stock page links gbarecomp's generic `main()`, so no game-owned code reaches the browser yet. That will need our own link step (Phase 3); `tests/smoke/CMakeLists.txt` already links the browser host that way, with `gbarecomp_web_host_link_options()`.

## How the game-dependent scripts were verified

The scripts that need the ROM and the BIOS were run end to end once, in a scratch directory, with stand-ins passed through the environment variables above: `arm.gba` in place of the game, and the MIT-licensed [Cult-of-GBA BIOS](https://github.com/Cult-of-GBA/BIOS) (`bios.bin` at `a30e9a9`, SHA-1 `2e41f9d30ecdf1c4540edf89ac16f49bf327edb7`) in place of the retail BIOS, with the BIOS config from the appendix of [docs/research/open-bios.md](research/open-bios.md). Nothing from that run is committed.

- `scripts/regen.sh`: recompiled the BIOS (132 functions, 823 resume aliases, as in open-bios.md §3) and the ROM.
- `scripts/build-native.sh`, with and without `--lle`, and with `--no-regen`: configure picked up the recompiled BIOS, the executable linked. Headless, it booted the recompiled BIOS (`bios_boot=LLE (real intro)`) and ran 3000 frames with `self_heal_coverage=FULLY_STATIC dispatch_misses=0`. With `--bios-skip-intro` it ran the test ROM to its final loop, also fully static.
- `scripts/build-web.sh --no-regen --embed-private-rom --dev` built the bundle, `scripts/serve-web.sh` served it with the COOP/COEP headers, and the page ran in the Claude desktop app's browser pane (Chromium): the recompiled BIOS drew its boot screen through WebGL. That run is how the `--state-dir` bug below was found.

That run used neither the retail BIOS nor the game ROM; the next section does, natively. No browser other than that Chromium pane was tried.

## First real-ROM smoke test

A time-boxed session (about 45 minutes) on 2026-10-10, to see how far the scaffold gets with the real inputs. Outcomes only: the generated code, logs, miss reports and screenshots stay out of git, in ignored directories or outside the repository.

The [Phase 2 diagnosis](research/phase2-diagnosis.md) later found the causes of the problems below. Its corrections (its §8) are marked **Correction** where they apply; the record of what was seen is left as it was.

- **Inputs**: the owner's dump of the Europe ROM (SHA-1 `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0`, `A9MP`) and the retail BIOS (SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492`), passed with `--rom` and `--bios`. gbarecomp at `5e89943` with `patches/gbarecomp/` applied. M4 Pro, macOS 26.5.2, Apple clang 21.
- **Reference**: libmgba 0.10.5 through a small headless harness, real BIOS boot, no input, screenshots at the same frame numbers and in windows around them. Frames were compared pixel by pixel after reducing both to 5 bits per channel, because the two tools expand GBA colors to 8 bits differently. **This is a local check: it cannot be repeated from this repository alone.** The harness exists only as a binary on the machine used for this work, and neither it nor the comparison script is committed. Stock mGBA 0.10.5 can capture comparable frames with its Lua scripting (Tools > Scripting...): a `callbacks:add("frame", ...)` handler that calls `emu:screenshot(path)` when `emu:currentFrame()` reaches the wanted frame (all three exist in `src/core/scripting.c`, `src/core/thread.c` and `src/script/stdlib.c` at tag 0.10.5), with the BIOS intro enabled. That route was not tried, and whether its frame numbers line up with the harness's is **unverified**.
- **No input was given.** Everything below is the boot, the intro and the title screen's attract loop.

### Generation and build

`scripts/build-native.sh --rom ... --bios ...` into the default ignored `generated/` and `build/`, with gbarecomp's tools already built by `scripts/test-engine.sh`: regenerate, configure and build took 10 s wall.

- BIOS recompiled with `gbarecomp/bios/gba_bios.toml`; configure picked it up.
- ROM: `gba_recompile` emitted **2,259 functions** (1,612 ARM, 647 Thumb; its discovery summary counts 2,258 found by walking the code and 1 from the config alone), with no `[[extra_func]]` or other config entries. Far below the 65,536 cap. 16 MB of C++ in 16 shards; the recompiled BIOS is 3.8 MB.
- The executable built with about 2,000 warnings from the generated code (unused variables) and no errors.

### Boot, with runtime healing off

This is the command `scripts/build-native.sh` prints (`GBARECOMP_SELFHEAL_RECOMPILE=0`): every dispatch miss is run by the interpreter, nothing is compiled at run time, and the banner reports coverage honestly.

**It boots through the real BIOS intro to the title screen.** The runtime starts with `bios_boot=LLE (real intro)` and `save_config source=game-config type=SRAM size=32768`. Last frame of each run against mGBA at the same frame, and against every mGBA frame captured around it (frames 170-330, 440-460, 1290-1400, 1795-1810, 2445-2455 and 2695-2712). The mGBA windows and gbarecomp's frames 180 to 320 come from two later sessions the same day (the review of this branch and its fixes), each with a fresh build of the branch; the 240- and 1300-frame runs gave byte-identical PNGs in the first and the last session.

| Frame | Screen | Pixels that differ from mGBA's same frame (of 38,400) | mGBA frames it matches exactly |
|---|---|---|---|
| 180 | BIOS logo, appearing | 2,750 | 181 |
| 220, 240, 260 | BIOS logo | 3,622 in each: gbarecomp keeps the logo at full brightness while mGBA fades it | 216-219, the logo before mGBA's fade starts |
| 270 | White, end of the BIOS fade | 0 | 250-279 |
| 280 | Black | 24,240 | 281-296 |
| 300 | License screen, fading in | 2,034, each off by one 5-bit step | none |
| 320 | License screen, fading in | 2,652, off by one or two steps | none |
| 450 | License screen | 0 | 440-460, all captured |
| 1391 (end of the 1300-frame run) | Publisher logo, fading out | 36,305, each off by one step | none |
| 1800 | Intro animation | 0 | 1799-1805 |
| 2450, 2700 | Title, "Press start" | 0 | 2445-2455 and 2695-2712, all captured |

Every frame that matches mGBA is a screen that stays the same for at least 7 mGBA frames, so these matches cannot show a frame offset or a blending difference. **Correction** (diagnosis §7.4): they say nothing about the build either. At frames 2450 and 2700 the run was inside the runaway bridge of problem 2 below, spinning in the BIOS IntrWait loop (about 10,000 writes per frame to IME and HALTCNT from frame 2439 on); the title screen does not change, so the pixels still matched. Two kinds of difference show up elsewhere:

- **Brightness fades** (frames 220-260, 300, 320, 1391). mGBA's register trace (same harness) shows the BIOS brightening the logo to white from frame 220 to 250 (`BLDCNT=0x3FBF`, `BLDY` rising from 1 to 16; 0x0B at frame 240), and the game darkening with `BLDCNT=0x00FF` and `BLDY` 0x0D, 0x03 and 0x0F at frames 300, 320 and 1391. gbarecomp shows none of the BIOS fade, and in the game's fades its pixels are off by one or two 5-bit steps. Whether both come from how gbarecomp applies `BLDY` is **unverified**.
- **A frame of offset** (frames 180 and 280). gbarecomp's frames 180 and 280 equal mGBA's 181 and 281: the two tools number frames differently, or gbarecomp is one frame ahead there (**unverified**).

The `--lle` build (per-pixel scanline renderer) gives the same counts at frames 240 and 300 (3,622 and 2,034, in the review run of this branch). 2,700 frames took 10.5 s wall; headless runs are not paced to 60 Hz.

Coverage at exit (`self_heal_coverage`):

| Frames | Coverage | Distinct dispatch misses | Interpreted instructions |
|---|---|---|---|
| 120, 240 | `FULLY_STATIC` | 0 | 0 |
| 450 | `NOT_STATIC` | 15 | 9,427 |
| 900 | `NOT_STATIC` | 37 (2 in IWRAM, 35 in ROM) | 4,485,773 |
| 2700 | `NOT_STATIC` | 37 | 228,577,755 |

- **IWRAM**: two entry points, `0x030004DC` (Thumb, bridged 4,349 times by frame 2700) and `0x03000708` (ARM, 4,512 times). Both lie in the front end's IWRAM image (`0x03000000`-`0x03000833`, copied from ROM `0x081596FC`: the literal pool at `0x080002C8`-`0x080002D0` holds source, destination and size, and an mGBA write watch shows the loop at `0x08000260`-`0x08000264` copying those 0x834 bytes at frame 293; see the comments in `game.toml`). Once the interpreter enters IWRAM it keeps going, and nearly all of the 228 million interpreted instructions come from there (see the healing runs below). That is expected without `[[code_copy]]` entries. **Correction** (diagnosis §1.1, §8): most of them come from one bridge, not from IWRAM code in general. 198.75 million of the 228.6 million are the bridge for `0x08003E70`, at VBlanks 1029-2706, whose stop PC was a call-return frame leaked by IRQ code (problem 2). With patch 0003 the same 2700-frame run interprets 119,865,640 instructions, three quarters of them in one call of the front end's IWRAM intro player at `0x03000000` (diagnosis §2.3).
- **ROM**: 35 misses, each 0x4 to 0x1C0 bytes past the start of a function that discovery did find (the runtime names the nearest one: the busiest miss, `0x08012460`, bridged 12,180 times, sits next to the function at `0x0801245C`). The runtime flags 4 groups as jump-table candidates. None was reviewed or added to `game.toml` yet. **Correction** (diagnosis §2.1): the candidates at `0x08001E44` and `0x08002630` are runs of consecutive return addresses after `bl` instructions, not jump tables. With patches 0003 and 0004, the same config bridges 46 PCs in 2,700 frames and 47 from 3,600 frames on: the 37 above and ten more, most likely code the game now runs natively instead of inside the stale bridge of problem 2 (not traced). [phase2-dispatch-misses.md](research/phase2-dispatch-misses.md) lists them all.

Problems seen, all repeatable (the same `--frames` gives the same output every time):

1. **IRQ watchdog.** `runtime_irq: handler at depth 1 did not iret after 4000000 dispatches (R15=0x00000018, cpsr=0x60000092) — abandoning` appears once in the 1800-, 2450- and 2700-frame runs, and 173 times in the 1300-frame run, which also overshot to 1,391 frames. **Correction** (diagnosis §1.2): an end-of-run artifact, not a hang during play. It happens only after `--frames` is reached: the end-of-run quit made every generated instruction yield, IRQ handlers included, and each IRQ that arrived while an interpreter bridge still ran spun to the watchdog. `patches/gbarecomp/0004-quit-waits-for-irq-handlers.patch` fixes it: with 0003 applied, runs of 2,700, 3,600, 5,400 and 12,000 frames print it 0 times, against 80 times at 3,600 and 772 at 12,000 frames without 0004.
2. **3600 frames aborts** (SIGABRT, exit code 134): `SELF-HEAL bridge for 0x08003E70 exceeded 200000000 instructions without returning to stop_pc=0x08004E10 (current pc=0x00000364)`. The interpreter, entered at a ROM miss, never reached the PC it was meant to return to (`0x08004E10`, where the shorter runs end) and was in the BIOS when it gave up. **Correction** (diagnosis §1.1): `0x08004E10` is a call-return frame leaked by IRQ code. The VCount IRQ handler calls the front end's IWRAM sound mixer, which the interpreter runs; the interpreter stops at the return address `0x08004E10` without popping its frame, one frame per IRQ. At VBlank 1029 a mainline miss at `0x08003E70` takes the stale frame as its stop PC, but `0x08004E10` only ever runs in IRQ mode, so that bridge runs until the 200 million-instruction cap. Every native run of 2,716 frames or more aborts this way. `patches/gbarecomp/0003-irq-call-return-leak.patch` fixes it, and `scripts/repro-test.sh` reproduces it without the game ([Repro ROMs](#repro-roms-without-the-game)).
3. **The result depends on `--frames`.** Runs stopped at different frame counts take different paths before the stop (the 1300-frame run hits the watchdog 173 times, the 1800-frame run once), so the frame count is part of a run's input. With `GBARECOMP_PRESENT_IN_PLACE=0` (headless runs default to "present in place, unwind at final frame only") every run from 1300 to 3600 frames aborts the same way, with a bridge for `0x08003D84`. Why is **unverified**. **Correction** (diagnosis §1.3): it is deterministic end-of-run behavior, from problems 1 and 2: the stale bridge runs from VBlank 1029 until something interpreted reaches `0x08004E10`, which happens only after the quit, when the abandoned VCount handler is interpreted. With `GBARECOMP_PRESENT_IN_PLACE=0` there is no quit hook at all, and the stale-stop bridge starts earlier, at VBlank 609 on the miss at `0x08003D84`. With 0003 and 0004, a run can still stop past `--frames` while a long bridge is running, because a bridge never checks the quit: 3,600 frames stop at 3,644 and 12,000 at 12,385 (the front end's IWRAM code, the intro player at `0x03000000` included, is still interpreted). Exact stops are expected once no bridge runs (Phase 2 plan, P2-10).

### Boot, with runtime healing on

By default gbarecomp also compiles each missed function with the host C++ compiler (its banner says `backend=gcc`) into `build/native/recomp_cache/`, and a later run loads them from there at start (`warm_loaded=` in the banner). RAM-resident code is healed only with `GBARECOMP_RAM_OVERLAY_HEAL=1`. `GBARECOMP_HEAL_CACHE` moves the cache, which is how the RAM-healing pair below got a cache of its own.

"Loaded from cache", "Native at exit" and "Failed" are the banner's `warm_loaded` (functions loaded from the cache at start), `healed_native` and `failed`. `healed_native` counts the native functions at exit, the ones loaded from the cache included: it is the size of the runtime's healed-function table (`overlay_counters()`, `src/runtime/overlay_loader.cpp:601-603`).

| Run | Frames reached | Distinct misses | Loaded from cache | Native at exit | Failed | Interpreted instructions | Watchdog | Wall |
|---|---|---|---|---|---|---|---|---|
| Healing on, empty cache, 2700 frames | 2706 | 37 | 0 | 35 | 2 (the IWRAM ones) | 228,577,755 | 1 | 11 s |
| Healing on, that cache, 3600 frames | 3605 | 16 | 35 | 47 | 4 | 218,628,312 | 1 | 11 s |
| Healing and RAM healing on, empty cache, 3600 frames | 3600 | 102 | 0 | 102 | 0 | 82,501 | 0 | 29 s |
| Healing and RAM healing on, that cache, 3600 frames | 3600 | 55: 52 IWRAM, 2 EWRAM, 1 ROM | 50 | 105 | 0 | 12 | 0 | 5 s |

Unlike runs with healing off, runs with healing on are not exact to the instruction: the review run of row 2 interpreted 218,628,297 instructions with 46,723 native calls, against 218,628,312 and 46,720 here. Healing compiles on a worker thread, so a function can come into use at a slightly different point in each run (a likely cause, **unverified**).

Healing ROM misses alone leaves almost all interpretation in place (218 million instructions), which shows that the interpreted instructions come from the IWRAM entries. **Correction**: that does not follow. In the healing-off run most came from the mis-stopped bridge of problem 2 (diagnosis §8), whose stop PC the IWRAM mixer's leak supplies; the split in these healing runs was not measured (**unverified**). With RAM healing as well, the second run interpreted 12 instructions, the watchdog stayed quiet, the 3600-frame run finished, and frame 3600 (the title's attract animation) is identical to mGBA's in both RAM-healing runs (it matches mGBA frames 3600-3608 and none of 3590-3599). One EWRAM entry, `0x0203D7EA`, is the Thumb code that reads the save area during boot: an mGBA read watch shows it making 3,280 one-byte reads of `0x0E000000`-`0x0E000CCF` at frame 596. Coverage still reads `NOT_STATIC`: healed code is not statically recompiled code, so this is a diagnostic result, not a build.

### Not reached

- **Race code running from IWRAM**, which needs input to reach a race. The race program's startup does run at boot: in mGBA it enters `0x08159F30` at frame 271 and copies its image (ROM `0x083F6820`, 0x49C4 bytes) to IWRAM at frames 279-280, before the front end copies its own image over the first 0x834 bytes at frame 293 (watches and literal pools in the `game.toml` comments). Whether recompiled dispatch can tell the two IWRAM images apart is still open.
- **Saves**: no SRAM write happened in 3,600 frames, as in mGBA up to frame 4,400, so no save file was written.
- **The game in a browser, past the title screen.** `scripts/build-web.sh --no-regen --rom ... --bios ...` built the bring-your-own-ROM bundle from the same generated code in 19 s (`game.wasm` 4.4 MB, no ROM or BIOS inside). Built again with `--embed-private-rom --dev`, served with `scripts/serve-web.sh` and opened in the Claude desktop app's browser pane (Chromium), it boots through the BIOS intro and the license screen to the title, "Press start", then stops: the page shows `failed: WebAssembly runtime aborted` after 1,332 published frames. The console has the same abort as the native 3600-frame run, `SELF-HEAL bridge for 0x08003E70 exceeded 200000000 instructions without returning to stop_pc=0x08004E10 (current pc=0x00000364)`, then `Aborted()`. Runtime healing does not exist in the browser: the page logs `self_heal_recompile=UNAVAILABLE host=wasm` (`src/runtime/overlay_loader.cpp:427-431`, under `__EMSCRIPTEN__`), so it always runs as a native run with healing off does, and reaches this abort every time. Seen in two runs on 2026-10-10 (the review's and the fix's), both at 1,332 published frames. **Correction** (diagnosis §1.1, §4): this is the leaked call-return frame of problem 2, not a browser problem. The bundle reports only 1,332 frames because a bridge presents none. In the diagnosis, a prototype of patch 0003 (the same code without its log message) let the browser bundle run 6,011 frames (§1.1). No browser run was made with `patches/gbarecomp/0003` itself, so that it fixes the browser abort is **unverified** until P2-12 runs the bundle.

Next steps, for Phase 1: declare the IWRAM images (`[[code_copy]]`), review the ROM misses and jump-table candidates into `[[extra_func]]` / `[[jump_table]]` entries, and find out what the IRQ watchdog and the never-returning bridge are (since found and fixed: problems 1-3 above).

## Known issues

1. **The stock browser bundle exits at launch at our pin.** The page always passes `--state-dir` (`gbarecomp/packaging/web/bootstrap.js:62`), and the runtime's argument parser rejects it: `internal: value flag --state-dir is missing from kCliValueFlags`, exit code 1 (`src/runtime/runtime.cpp:791-799`, check at lines 868-871). Seen in the browser and natively. `patches/gbarecomp/0001-cli-accept-state-dir.patch` adds the flag to the table; `scripts/setup.sh` and the build scripts apply it, and the smoke test fails without it. Upstreamable.
2. **The other game repositories do not link on macOS as written.** They pass `-Wl,--start-group`, which Apple's linker rejects. Our `CMakeLists.txt` uses gbarecomp's `target_link_gbarecomp_runtime_stack()` instead.
3. **Stack size on macOS.** A macOS main thread gets 8 MiB; Windows and the web reserve 16 MiB. Our executable links with `-stack_size 0x1000000`. The game thread that `--tcp` creates still gets 512 KiB (integration study, §7.2, PR #2), so prefer `--tcp-observe` for debugging.
4. **`gba_recompile` caps function discovery at 4096 by default, silently.** `scripts/regen.sh` passes `--max-functions 65536` and checks the emitted count against it.
5. **HALT ends only on an interrupt the CPU takes** (seen with the stand-in BIOS). gbarecomp's single-player loop clears HALT only when IME is set and CPSR.I is clear (`src/runtime/runtime_bus_bridge.cpp:774-793`, `src/gba/gba_io.h:151-153`). On hardware HALT ends as soon as `IE AND IF` is non-zero, whatever IME and CPSR say ([GBATEK, BIOS Halt Functions](https://problemkaputt.de/gbatek-bios-halt-functions.htm)); gbarecomp's own multiplayer loop does that (`src/runtime/multiplayer_session.cpp:157-160`). The Cult-of-GBA boot screen halts with IME off and never reaches the cartridge (PC stays at `0x00000C08`). This matters for an open-BIOS build. Whether the game ever halts with IME off is **unverified**.
6. **`--bios-skip-intro` / `[bios].skip_intro` leaves the BG2 and BG3 affine matrices at zero.** The handoff it synthesizes sets only CPU state (`src/runtime/bios_hle.cpp:518-540`). After a real boot, BG2PA, BG2PD, BG3PA and BG3PD should be 0x100: mGBA initializes them so (`GBAIOInit`, `src/gba/io.c:339-342` at tag 0.10.5), and the Cult-of-GBA BIOS source lists the same values as what the official BIOS leaves, as measured by its authors on emulators. Not checked against the retail BIOS (**unverified**). In the stand-in run, `arm.gba` drew its result text into mode 4 VRAM, but every frame came out one flat color, with BG2PA = BG2PD = 0 over the debug server. A game that uses bitmap or affine modes without writing those registers itself would render wrong with the intro skipped. Keep the intro until this is fixed or ruled out for the game.
7. **Homebrew Emscripten is not the validated version** (6.0.12 against 6.0.10). Use emsdk.
8. **The co-simulation coordinator fails on macOS** (`oracle/gba_cosim.py` passes Windows-only `creationflags`). A one-line patch is described in `patches/gbarecomp/README.md`; it will be added when the co-simulation is first used.
9. **The runtime writes into its working directory**: `recomp_cache/`, `recomp_coverage_*.json`, `recomp_master_misses_*.toml.frag`, `bios.cfg`, `rom.cfg`. Run it from `build/native`. `.gitignore` covers these names in case a run starts at the repository root.
10. **Warnings that are not errors**: about 520 compiler warnings in `scripts/test-engine.sh` with the test ROMs present, nearly all unused-variable warnings in generated test code (see [Engine build and tests](#engine-build-and-tests)); about 2,000 more (`-Wunused-variable`, `-Wunused-but-set-variable`) when compiling the recompiled BIOS and game; `ld: warning: ignoring duplicate libraries` on macOS; em++ `-pthread + ALLOW_MEMORY_GROWTH may run non-wasm code slowly`, from gbarecomp's own browser link options.
11. **gbarecomp's `web_bootstrap_tests` is timing-sensitive.** The test waits a fixed 40 event-loop turns after each simulated file pick, but the page hashes the file with `crypto.subtle.digest`, which Node finishes on its thread pool. On the `ubuntu-24.04` CI runner it failed in both runs, at a different check each time; on the M4 Pro it passes. Delaying every digest by 1 ms reproduces the failure on macOS every time. `patches/gbarecomp/0002-web-test-wait-for-pick.patch` makes the test wait for the line each pick logs (10 s deadline); the page itself is unchanged. Upstreamable.
12. **gbarecomp clones toml++ into every new build tree** unless `gbarecomp/third_party/tomlpp/toml.hpp` exists. Its configure step then runs FetchContent, a full `git clone` from GitHub, in each build directory (`build/gbarecomp`, `build/native`, the smoke test's trees, the web build's). Usually that takes a few seconds, but in the first clean-clone check one configure took 595 s, and later the clone for `build/smoke/native-host` hung for more than 11 minutes, while a manual clone right after took 2 s. So `scripts/setup.sh` now puts the pinned header in place once (step 5 of setup), and a fresh configure takes about 1 s with no network.
13. **Runtime problems seen with the game ROM**: the IRQ watchdog, a self-heal bridge that never returns, and results that depend on `--frames`. The bridge that never returns also stops the stock browser bundle: it boots to the title screen, then aborts at the same bridge for `0x08003E70`, because runtime healing is unavailable in WebAssembly. See [First real-ROM smoke test](#first-real-rom-smoke-test). **Correction** ([Phase 2 diagnosis](research/phase2-diagnosis.md), §1.1, §4): the browser abort is not caused by the missing runtime healing, nor by anything else browser-specific: it is gbarecomp's IRQ call-return leak, the same as the native abort. `patches/gbarecomp/0003` fixes it natively, and `0004` fixes the watchdog (problems 1-3 in [First real-ROM smoke test](#first-real-rom-smoke-test)). For the browser, the evidence is the diagnosis prototype of 0003, with which the bundle ran 6,011 frames; this patch has not been run in a browser yet (**unverified** until P2-12). What remains natively: a run can stop past `--frames` while a long interpreter bridge runs.

## CI

`.github/workflows/ci.yml` runs on every pull request and on pushes to `main`, with no ROM and no BIOS:

- `shellcheck -x` over `scripts/` and `tests/tooling/`.
- **patch tooling** on `ubuntu-24.04`: `tests/tooling/apply-patches-test.sh`, with the full history checked out so that it can also run PR #5's `apply-patches.sh` (`a7efc60`) on the same case.
- **native** on `macos-15` (Apple silicon, with SDL2) and `ubuntu-24.04` (GNU ld, no SDL2): `setup.sh`, `fetch-test-roms.sh`, `test-engine.sh` (all of gbarecomp's tests, the two test ROM tests included), `smoke-test.sh --native-only` and `repro-test.sh` (on the stand-in BIOS). On Ubuntu, gbarecomp's `web_bootstrap_tests` needs `patches/gbarecomp/0002` (known issue 11), and the job also runs `repro-test.sh --without 0003 --without 0006 --expect-failure`, so that each repro keeps failing without the fix it tests (one A/B build for both).
- **web smoke** on `ubuntu-24.04`: emsdk 6.0.10, cached by version, then `smoke-test.sh --web-only`.

The full gbarecomp build is small (186 build steps), so CI builds all of it and caches only the emsdk install.

## Directory layout

| Path | Tracked | Contents |
|---|---|---|
| `gbarecomp/` | Submodule | gbarecomp at the pin; PolyForm Noncommercial 1.0.0 (`gbarecomp/LICENSE`, <https://polyformproject.org/licenses/noncommercial/1.0.0>) |
| `CMakeLists.txt`, `src/` | Yes | Native host: `main.cpp` and the build-config template |
| `game.toml` | Yes | Game config for the Europe ROM (`A9MP`); Phase 1 TODOs as comments |
| `web/game-lib/` | Yes | The generated game as a library for `build_web.sh` |
| `tests/smoke/` | Yes | Smoke test project and test ROM configs |
| `tests/tooling/` | Yes | Tests of the scripts that need no game data |
| `tests/repro/` | Yes | Synthetic repro ROM generators, a stand-in BIOS and their configs, run by `scripts/repro-test.sh` |
| `patches/gbarecomp/` | Yes | Local fixes to gbarecomp, applied as a series by `scripts/apply-patches.sh`. They contain excerpts of gbarecomp's source and are distributed under its license, PolyForm Noncommercial 1.0.0 |
| `scripts/` | Yes | Everything above |
| `roms/`, `bios/` | No | Private inputs |
| `generated/` | No | Recompiled BIOS and game |
| `test-roms/` | No | Downloaded test ROMs |
| `build/` | No | All build output, logs, `web-PRIVATE/` bundles; `gbarecomp-patches/` (the patch stamp and the build lock) and `without-NAME/` (A/B builds) |

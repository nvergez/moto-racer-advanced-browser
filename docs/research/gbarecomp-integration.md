# gbarecomp integration study

**Date:** 2026-10-10
**Scope:** How a game is brought up on gbarecomp, read from the code of the framework and of two game repositories, so we can repeat it for Moto Racer Advance. No Moto Racer Advance ROM was used. Nothing here is verified against that ROM.

Conventions:

- Most of this study comes from reading code and docs. A statement with a citation and no tag says what the cited file says or does. It was read, not observed by running it, unless the text says it was run.
- *(inferred)* marks a conclusion that goes beyond what the cited source states, such as a consequence we drew from code we did not run.
- Recommendations are our judgment. They are worded as recommendations ("we recommend", "Recommendation:", "prefer", "use"), not as facts.
- **unverified** marks a claim we have not checked at all.
- Citations use `repo@sha:path:line`. A bare `path:line` refers to `GR` unless the sentence names another repository. Line numbers are valid at the cited commit only.

## Sources

| Short name | Repository | Commit | Notes |
|---|---|---|---|
| `GR` | [mstan/gbarecomp](https://github.com/mstan/gbarecomp) | `5e89943528aee7bc1c399bdbd035364a4b41dd10` (2026-10-09) | Our pin |
| `ARC` | [mstan/arm-recomp-core](https://github.com/mstan/arm-recomp-core) | `1f13cdfd3b437a7a3919285f381987bd43f5234a` | Submodule of `GR` at `external/arm-recomp-core` |
| `RNET` | [RetroPortingToolKit/recomp-net](https://github.com/RetroPortingToolKit/recomp-net) | `c58f125a3cc3468fc84012cf4eeb50cc0b62c379` | Submodule of `GR` (netplay only) |
| `RBE` | [RetroPortingToolKit/rbengine](https://github.com/RetroPortingToolKit/rbengine) | `2a03e73693acee0fb78076ea058642c931bef12e` | Submodule of `GR` (netplay only) |
| `SDL` | [mstan/SDL](https://github.com/mstan/SDL) | `8e28503b164d4353262ed5abf102c25fa838e4f8` (release-2.32.10 + 1) | Submodule of `GR` at `platform/android/third_party/SDL` |
| `MKSC` | [mstan/MarioKartSuperCircuitRecomp](https://github.com/mstan/MarioKartSuperCircuitRecomp) | `b89fbb4a786c53cb3d450f1931ed5aa7b5b6e922` (v0.1.4) | Closest analogue |
| `MMZ` | [mstan/MegaManZeroRecomp](https://github.com/mstan/MegaManZeroRecomp) | `218adfddf3572a6eaf7ffbec858d95c71bf53935` | Contrasting repo |
| `MC` | [mstan/MinishCapRecomp](https://github.com/mstan/MinishCapRecomp) | `1aa1128e14cbcc40140a518ed426092ac85b26a6` | Skimmed only |
| `UI` | [mstan/recomp-ui](https://github.com/mstan/recomp-ui) | `6374aae201b930c97425718249f5d39b2275ca13` | The commit `MKSC` pins |
| `BOK` | [Shy/BoktaiRecomp](https://github.com/Shy/BoktaiRecomp) | `69ff053841c9e5b0f5eb1ac42cfc1f008a94c010` | Third-party game repo with macOS CI; read through the GitHub API only |
| `MGBA` | [mgba-emu/mgba](https://github.com/mgba-emu/mgba) | `26b7884bc25a5933960f3cdcd98bac1ae14d42e2` (tag `0.10.5`) | The version installed here; one debugger file read |

Machine used for the build check in §7: Apple M4 Pro, macOS 26.5.2, Apple clang 21.0.0 (`clang-2100.1.1.101`), Apple ld `ld-1267`, CMake 4.4.0, Ninja 1.13.2, Python 3.11.6, Node 24.14.0, Homebrew SDL2 2.32.10.

## Summary

1. **gbarecomp builds and passes its tests on our Mac.** At `GR`, configure + build + `ctest` finished in under 30 seconds of wall time, with **50/50 tests passing**, the browser JS unit tests among them (§7).
2. **None of the three game repositories we read can link on macOS as written** *(inferred: we did not build them)*. They pass `-Wl,--start-group` unconditionally, and Apple's linker rejects that flag (checked on this machine). gbarecomp's own `target_link_gbarecomp_runtime_stack()` handles this. Our repo must use it (§7, §9).
3. **The browser target is one day old at our pin.** It first appears on `main` at `4855ba2` (PR #16, merged 2026-10-09). Our pin `5e89943` is two merges later: PR #29 (opt-in DMA batching) and PR #31, which makes the HLE scanline renderer the build default. That default was not part of PR #16's web validation. We recommend keeping the pin plus a second LLE build to compare frames against (§9). Neither `MKSC` nor `MMZ` pins an engine that has the web host, so we would be the first game repo on it. The supported web flow links a generic `main()` and a CLI-exported library. Game-owned hooks such as MKSC's mods are **not** included unless we write our own web link step (§5).
4. **Legal: a "bring your own ROM" web bundle still contains the game's code.** `game.wasm` is compiled from the recompiled ROM and the recompiled BIOS. gbarecomp's docs contradict each other on whether such a bundle can be published, while `MKSC` already publishes native binaries with the same kinds of code. §5.6 compares four options. Our recommendation: local builds only through Phase 3; if the owner later wants a public page, a bundle with an open-source BIOS instead of Nintendo's. The owner decides before Phase 3 hosting.
5. **The BIOS dump is needed twice:** at build time, to recompile it (LLE path, and required by `build_web.sh`), and at runtime, where it is always loaded, even with the opt-in BIOS HLE. Generating the *game's* C++ does not need it (§2.3).
6. **MKSC's enhancements are specific to MKSC. Some framework seams transfer, MKSC's own work does not, and no seam exists for higher resolution.**
   - The 60 FPS mod overrides one Thumb immediate in an affine-background road renderer. The patch came from a researcher who also worked on the MKSC decomp, which we do not have for our game.
   - Adaptive Widescreen is 344 lines of MKSC-specific code (scene detection by tile IDs, HUD rectangles, sprite moves) on top of the engine's PPU providers.
   - In bitmap modes 3/4/5, gbarecomp draws the widescreen margins as plain backdrop.
   - The framework has no internal-resolution upscaling and no CPU overclock. *(inferred)* Higher resolution is new work however the game renders.
   - *(inferred)* Widescreen can only show objects the game still draws. If it culls opponents and trackside objects at its 240-pixel view (**unverified**), filling the margins means reverse engineering game logic.
   - *(inferred)* If Moto Racer Advance draws its races in software (**unverified**; playbook step 2 measures it), resolution and widescreen need a host-side renderer behind a `[[mod_function_hook]]`, which must not change guest timing. A higher frame rate could come from that renderer or from a new engine feature that scales guest cycles, which risks breaking game logic tied to frame timing. Either way it is new work (§6).
7. **`gba_recompile` stops discovering functions at 4096 by default, without saying so.** MKSC passes `--max-functions 65536` and discovers 13,717 to 20,815 functions, depending on whether decomp seeds are used. We must do the same (§3.1).
8. **Several debugging tools in `TCP.md` do not exist in the code at our pin.** These include the per-frame ring, `rdb_*`, and the `*_diff` commands. The coverage report, strict-static mode, input record/replay, save states, `state_hash` and the co-simulation engine do exist. The NanoBoyAdvance oracle binary is not in any public repo (§4).
9. **macOS gives the game the smallest host stack of any platform.** Windows and the web reserve 16 MiB and Android 256 MiB; a macOS main thread has 8 MiB and a `std::thread` 512 KiB (measured). The engine maps guest calls onto the host stack. The playbook links with a 16 MiB main-thread stack. The game thread that `--tcp` creates stays at 512 KiB, so we recommend `--tcp-observe` for debugging (§7.2).
10. **Static coverage cannot see RAM code that changes.** Dispatch looks a function up by PC and instruction set only. If the game copies different routines to one RAM address over time, or patches a copy, the static body runs stale code with no miss, and the run still reports `FULLY_STATIC`. Only game-owned hooks can handle it, and the engine installs none. For a 3D racer that may run its renderer from RAM, this is the main Phase 1 risk *(inferred)*. Playbook steps 2 and 10 measure it as an input to ADR 0001 (§3.3).

---

## 1. Layout of a game repository

### 1.1 How the engine is pinned

| Repo | Engine pin | Other submodules | Notes |
|---|---|---|---|
| `MKSC` | Submodule `gbarecomp/` at `29efc02893f12122d340952ce1093898c6b5ef63` (`MKSC@b89fbb4:.gitmodules`, gitlink) | `recomp-ui/` at `6374aae`; `third_party/mksc` (jellees/mksc decomp, symbols only) | `29efc02` is on gbarecomp branch `fix/delay-checkpoint-arrival`, not `main`. It is 74 commits behind our pin and is not its ancestor (checked with `git merge-base`). |
| `MMZ` | Submodule `gbarecomp/` at `7c9a1eba611b4eef7668937707d5f9abb0d94d9b` | `recomp-ui/` | Mixed conventions: `CMakeLists.txt` uses the submodule, but `tools/regen.ps1` and `game.toml` `[bios].path` assume a sibling `../gbarecomp` (`MMZ@218adfd:tools/regen.ps1:3`, `game.toml` `[bios]`). |
| `MC` | Submodule `gbarecomp/` at `7c9a1eb` | `recomp-ui/`; `third_party/tmc` (zeldaret/tmc decomp) | |
| `BOK` | Submodule `gbarecomp/` (branch `main`) | `recomp-ui/` | CMake falls back to a sibling `../gbarecomp` (`BOK@69ff053:CMakeLists.txt:25-27`) |

Every repo exposes the engine path as a CMake cache variable (`GBARECOMP_ROOT`) and pulls it in with `add_subdirectory("${GBARECOMP_ROOT}" gbarecomp_build EXCLUDE_FROM_ALL)` (`MKSC@b89fbb4:CMakeLists.txt:14-31`). The engine's own nested submodules come in through `--recurse-submodules`. `arm-recomp-core` uses a relative URL (`../arm-recomp-core.git`), which resolved to `https://github.com/mstan/arm-recomp-core.git` when we cloned.

Neither engine commit pinned by a game repo (`29efc02` for MKSC, `7c9a1eb` for MMZ and MC) contains `packaging/web/` (checked with `git cat-file -e`). The web host first appears at `4855ba2`, two merges before our pin (§9, "Engine pin").

### 1.2 Top-level files (MKSC)

| Path | Role |
|---|---|
| `CMakeLists.txt` | Game executable: `src/*.cpp` + `generated/*.cpp`, linked against the engine archives. Optional recomp-ui launcher. Copies the mod catalog after the build. |
| `game.toml` | One file read by **both** `gba_recompile` and the runtime. MMZ's header calls it a "Hybrid configuration" (`MMZ@218adfd:game.toml:2`). |
| `baserom.md` | ROM identity: region, game code, size, SHA-1, MD5, header entry, save signature and offset (`MKSC@b89fbb4:baserom.md`) |
| `src/main.cpp` | Fills `gbarecomp::RunOptions` and calls `gbarecomp::run_game()` (`MKSC@b89fbb4:src/main.cpp`) |
| `src/mksc_*.cpp`, `src/mods/*.cpp` | Game-owned enhancement code and trusted plugins |
| `mods/preloaded/packages/<id>/<ver>/manifest.toml` | Built-in mod manifests (data only) |
| `symbols/` | Imported names: `imported_symbols.tsv`, `imported_data_symbols.tsv`, `<ID>_symbols.toml` overlay, `function_boundaries.tsv` |
| `generated/README.md` | Only tracked file in `generated/` |
| `recomp/launcher/boxart.tga` | Copyrighted box art "solely to identify the game" (`MKSC@b89fbb4:recomp/launcher/README.md`) |
| `tests/*.cpp`, `tests/*.input` | Unit tests for game-owned code; `gbarecomp-keyinput-v1` input traces |
| `tools/regen.ps1` | Checks the ROM SHA-1, then runs `gba_recompile` with base config, symbol overlay and TSVs, `--max-functions 65536` |
| `tools/test-attract-gameplay.ps1` | Strict-static acceptance runs (§3.4) |
| `tools/make_release.ps1`, `tools/linux/*` | Windows zip; Linux AppImage built in Docker (Ubuntu 22.04) |
| `tools/decomp/*.sh` | Builds the decomp in WSL to re-import symbols |
| `docs/NETPLAY.md`, `docs/SAVE_VALIDATION.md` | Player and maintainer docs |

### 1.3 Tracked vs ignored

`MKSC@b89fbb4:.gitignore` ignores:

- `roms/`, `*.gba`
- `generated/*.{c,cpp,h,json}`
- `build/`, `build-*/`, `release-stage/`
- `recomp_cache/`, `saves/`, `*.sav`, `*.srm`
- `*.exe`, `*.dll`, `*.pdb`, `*.log`, `*.bmp`, `*.png`
- `bios.cfg`, `rom.cfg`, `config.ini`, `keybinds.ini`
- `recomp_coverage*.json`, `recomp_master_misses*.toml.frag`, `recomp_seed_proposals.toml`
- the bulky decomp inputs `symbols/mksc_readelf_*.txt` and `symbols/mksc.map`

The small importer outputs in `symbols/` are tracked. `MMZ` ignores `third_party/` and `*.csv` as well, and un-ignores `docs/screenshots/*.png`.

Inside the engine, BIOS-derived output is ignored. `GR@5e89943:src/runtime/generated_bios/.gitignore` says `bios_recompiled.cpp` "embeds Nintendo's BIOS bytes as instruction-by-instruction lowerings", and it ignores `bios_symbol_map.cpp` as BIOS-derived too. `bios_dispatch_table.cpp` and `bios_dispatch_stub.cpp` are tracked.

### 1.4 Release packaging

- **Windows:** `MKSC@b89fbb4:tools/make_release.ps1` requires the regenerated shards and `gbarecomp/src/runtime/generated_bios/bios_recompiled.cpp` (lines 57-58). It builds with MSYS2 MinGW and stages the exe, DLLs, recomp-ui assets, the mod catalog and a bundled TinyCC for self-healing. The script header says the zip contains no ROM, BIOS, saves, generated source or config.
- **Linux:** `MKSC@b89fbb4:tools/linux/build_appimage.sh` builds the engine's pinned SDL fork and the game inside Docker. It collects licenses with `tools/collect_licenses.py` and smoke-tests with a read-only private ROM/BIOS mount.
- **macOS:** no game repo we read ships one. The engine provides `GR@5e89943:packaging/package_macos.sh`, a flat directory plus a tarball. A `.app` bundle does not work there (`packaging/README.md`).
- *(inferred)* A release binary contains compiled code derived from both the ROM and the BIOS. Leaving out *source* files does not change that. See §5.6.

---

## 2. `game.toml`

### 2.1 Two readers, two parsers

- **`gba_recompile`** parses the file with toml++ v3.4.0, fetched at commit `30172438` (`GR@5e89943:CMakeLists.txt:604-628`). It reads `[program]`, `[identity]` and the arrays (`GR@5e89943:tools/gba_recompile/config.cpp:476-508, 732-850`).
- **The runtime** uses its own line-based reader. It accepts only these keys (`GR@5e89943:src/runtime/runtime.cpp:693-785`):
  - `[game] short_name, default_region`
  - `[bios] path, sha1, crc32, hle, hle_keep_intro, skip_intro`
  - `[rom] path, sha1, crc32`
  - `[save] path, type, size`
  - `[video] screen, view_width, resize_view, sharp_filter, affine_filter, widescreen`
  - `[audio] shadow`

  Paths resolve relative to the config file's directory. The value `TBD` counts as empty. MKSC's `[runtime] debug_port/window_title` are **ignored** by both readers. They only document compile-time defines, and those defines do not reach the runtime library either (playbook step 9).
- **The web build** exports the runtime's scalar subset to `runtime.toml` (`GR@5e89943:packaging/web/runtime_config.py`, described in `packaging/web/README.md`).

### 2.2 Recompiler fields (`GR@5e89943:docs/TOML_SCHEMA.md`, `tools/gba_recompile/config.cpp`)

| Key | Required | MKSC value | Meaning |
|---|---|---|---|
| `[program].load_address` | yes | `0x08000000` | Where the image is mapped |
| `[program].size` | yes | `0x00400000` | Must match the file size |
| `[program].entry_pc` | yes | `0x08000000` | Seeded automatically. MKSC and MMZ use the header branch at `0x08000000`. Without a config, `gba_recompile` defaults to `--entry 0x080000C0` (`tools/gba_recompile/main.cpp:95`). |
| `[program].name`, `.id` | no | `"…(USA)"`, `"AMKE"` | Labels |
| `speculative_literal_harvest` | no (default `true`) | `false` | Harvest callback pointers from literal pools. Both MKSC and MMZ turn it off for evidence-only corpora. |
| `aot_scan_start` / `aot_scan_end` | no | whole ROM | Validated callback-table discovery in that range. Keep compressed data outside it. |
| `static_resume_all` | no (default `false`) | `true` | Resume entry at every instruction, because an IRQ can return anywhere. Needed for strict end-to-end AOT. |
| `codegen_shards` | no (auto 2..64) | `64` | Number of C++ translation units |
| `[identity].sha1` | **yes** | ROM SHA-1 | `gba_recompile` aborts on mismatch |
| `[identity].md5` | no | ROM MD5 | Cross-check |

Arrays: `[[extra_func]]` (addr, mode, name, note, `resume`, `source_addr`), `[[resume_range]]`, `[[jump_table]]` (abs32/abs16/pcrel_thumb/pcrel_arm; arm/thumb/auto), `[[code_copy]]` (ROM→RAM code mapping), `[[data_range]]` (hard exclusion), `[[exclude_func]]`, `[[thumb_alu_immediate_override]]`, `[[mod_function_hook]]`.

The code also accepts `[[alu_immediate_override]]` (`config.cpp:223-252, 488-490`), which `TOML_SCHEMA.md` does not document.

`--config` can be repeated. The first file is the base and wins every conflict; the others are overlays. An overlay may not define `[program]`, and its `[identity]` must match the base (`docs/TOML_SCHEMA.md`, "Overlay configs").

### 2.3 Runtime fields

| Key | Meaning | Source |
|---|---|---|
| `[rom].sha1` | One of three sources for the expected ROM SHA-1, which **is required**: `[rom].sha1`, `RunOptions::builtin_rom_sha1` in `main.cpp`, or `--rom-sha1`. With none of them, the runtime refuses to launch ("per-game TOML must set [rom].sha1"). On the web, `main()` passes no `RunOptions`. The page passes `--rom-sha1`. `build_web.sh` takes that value from `[rom].sha1` or from the ROM given at build time, and refuses to build when it has neither. | `runtime.cpp:1315-1316, 902-907, 1411-1416`; `packaging/web/main.cpp:5`; `build_web.sh:138-152`; `packaging/web/bootstrap.js:8, 64` |
| `[bios].path`, `.sha1` | BIOS file and expected hash. Wrong size (≠ 16384) is fatal; a SHA-1 mismatch is only a warning. Without the recomp-ui launcher, macOS and Linux have no file dialog: pass `--bios`/`--rom` or set the paths. | `runtime.cpp:1385-1409`; `asset_picker.cpp:141-173, 203-205, 244-249` |
| `[bios].hle` | Opt-in SWI HLE ported from mGBA (MPL-2.0). The dump is **still required**. | `ENHANCEMENTS.md` §1 "The BIOS dump is still required, even with HLE on" |
| `[bios].skip_intro` | Skips the boot logo without changing SWI behaviour. MMZ ships it on. It shifts IRQ timing, so the strict-static gate has to be re-run. | `PRINCIPLES.md:68-96` |
| `[save].type`, `.size` | `sram` (32768), `eeprom` (512 or 8192), `flash512` (65536), `flash1m` (131072). Default: detected from the SDK signature in the ROM. `GBARECOMP_SAVE_TYPE` overrides. | `src/runtime/save_config.cpp`; `src/gba/gba_rom_header.cpp:67-74` |
| `[video].view_width` etc. | Honoured only up to the game's `RunOptions::max_view_width` | `TOML_SCHEMA.md` "Runtime video settings" |

The ROM SHA-1 also goes in `RunOptions::builtin_rom_sha1` in `main.cpp`. MKSC repeats it in at least six places: `game.toml` `[identity]` and `[rom]`, `main.cpp`, the mod manifests, `tools/regen.ps1` and `tools/make_release.ps1`.

If the recompiled BIOS is not linked, the runtime switches to HLE boot by itself and prints `recompiled BIOS is not linked; using BIOS HLE boot instead` (`runtime.cpp:1567-1583`). *(inferred)* Any real BIOS code that still runs, such as SWIs that HLE does not implement and the IRQ dispatcher, would then go through the interpreter bridge, so the run can never be `FULLY_STATIC`.

### 2.4 What we must know about the ROM before the first build

| Fact | Needed for | How to get it |
|---|---|---|
| SHA-1, MD5, size | `[identity]`, `[rom]`, `[program].size`, `main.cpp` | `shasum -a 1`, `md5 -q`, `stat -f %z` |
| Game code (4 chars), header entry | `[program].id`. The runtime names its miss and coverage files after the code (`runtime.cpp:2099-2108`). | `gba_scan` (`GR@5e89943:tools/gba_scan/main.cpp:50-75`) |
| Save type and size | `[save]`. Optional while signature detection is right. Signatures cannot tell EEPROM 512 B from 8 KiB. | `gba_scan` prints `save_type`, `save_signature`, `save_signature_offset`. Confirm in mGBA. |
| Code copied to RAM | `[[code_copy]]` + `[[extra_func]]` | Not needed up front. It shows up as RAM-address dispatch misses (§3). |
| Function list, jump tables, callbacks | `[[extra_func]]`, `[[jump_table]]` | Not needed up front. Found iteratively (§3). |

MKSC's first `game.toml` (`MKSC@328b915:game.toml`) had only `[game]`, `[program]`, `[identity]`, `[bios]`, `[rom]`, `[save]`, `[runtime]`, `[video]`, `[audio]`. It had no arrays.

---

## 3. Bring-up workflow, from first recompile to playable

### 3.1 Analyzer and function discovery

`gba_recompile --rom` runs `FunctionFinder` from a set of seeds. Seeds come from:

- `entry_pc`
- `[[extra_func]]`
- `[[jump_table]]` entries
- `--symbols` TSV rows
- optional literal-pool harvesting
- optional `aot_scan` callback tables

The finder follows direct branches and BL within the same ARM/Thumb mode. It refuses to enter `[[data_range]]`. It decodes `[[code_copy]]` RAM addresses from their ROM source bytes. Output: `recompiled_NNN.cpp` shards, `recompiled.h`, `dispatch_table.cpp`, `symbol_map.cpp`, and `data_symbol_map.cpp` when `--data-symbols` is given (`GR@5e89943:tools/gba_recompile/main.cpp:104-141`).

- **The function cap is silent.** The default `--max-functions` is 4096 (`tools/gba_recompile/main.cpp:97`; `src/recompile/function_finder.h:227`). Past the cap, non-required seeds are skipped with `continue` and no warning (`src/recompile/function_finder.cpp:1952`). MKSC uses 65536 (`MKSC@b89fbb4:tools/regen.ps1:4, 54`). MKSC discovers 13,717 functions without decomp seeds and 20,815 with them (`GR@5e89943:docs/SYMBOL_OVERLAY.md:6, 141-155`). MMZ's README reports 10,885.
- **Misses are cheap; false positives are not.** Decoding data as code produces junk C. The finder is built to be conservative, and the TOML fills the gaps (`docs/TOML_SCHEMA.md`, "False-positive policy").
- Generated code is evidence, not authority. Never hand-edit it. Fix the config or the recompiler and regenerate (`GR@5e89943:CLAUDE.md`, `PRINCIPLES.md`).

### 3.2 Symbol import

Names change nothing about execution. They make traces, miss reports and the TCP `symbol` query readable (`docs/SYMBOL_OVERLAY.md`).

MKSC and MC import from a byte-matching decomp: `readelf -sW`, `readelf -SW` and the linker map, fed to `tools/symbol_import/import_decomp_symbols.py`. The importer gates on the decomp reproducing the exact ROM SHA-1.

**Moto Racer Advance has no decomp** (`docs/research/initial-findings.md`), so this path is closed to us. The `--symbols` format is plain TSV: `addr<TAB>mode<TAB>name` (`MKSC@b89fbb4:symbols/imported_symbols.tsv:1`). *(inferred)* We can write our own, from Ghidra or mGBA analysis, as names accumulate. MC also ships a Ghidra script generated from decomp symbols (`MC@1aa1128:ghidra/import_symbols.py`).

### 3.3 Runtime dispatch, self-heal and coverage report

These are the rules in `GR@5e89943:PRINCIPLES.md:134-226` ("Honest self-healing", "Coverage honesty is load-bearing"):

1. When a PC has no generated function, the interpreter runs the block (the bridge) and records the miss.
2. **ROM** misses are compiled on the fly in the background into `recomp_cache/<sha1>/<gcc|tcc>/<os-arch>/abi6-ram3/<pc>_<crc>_<a|t>.dll`. They are loaded warm on the next run (`src/runtime/overlay_loader.cpp:117-125`). The `.dll` suffix is used on every OS (`overlay_compile.cpp:327`).
   - On macOS the compiler is `c++` from `PATH`, called with `-O2 -std=gnu++17 -shared`, and loaded with `dlopen` (`overlay_compile.cpp:54-75, 365-386`; fixed for non-Windows hosts in `GR` commit `b75bb63`).
   - The overlay ABI hands every host symbol over as a pointer, so a dylib has no undefined symbols (`src/runtime/overlay_abi.h:1-15`).
3. Healing **RAM-resident** code is opt-in (`GBARECOMP_RAM_OVERLAY_HEAL=1`; `overlay_loader.cpp:90-93, 209-211`). *(inferred)* By default, code running from IWRAM/EWRAM that no `[[code_copy]]` covers stays on the interpreter. That matters if Moto Racer Advance runs its renderer from IWRAM (**unverified**). Three kinds of RAM code need telling apart:
   - **Verbatim copies of ROM bytes, one routine per address.** `[[code_copy]]` maps them to their ROM source, and `[[extra_func]].source_addr` covers position-independent copies (§3.5), so they can become static.
   - **Code generated at runtime.** Its bytes exist nowhere in the ROM. *(inferred)* No static path exists for it at our pin. On native it is interpreted, or healed at runtime with `GBARECOMP_RAM_OVERLAY_HEAL=1`. On the web, which has no healing, it is always interpreted. Either way the miss is reported, and a route that runs it is never `FULLY_STATIC`.
   - **Overlays and patched copies.** An overlay is several ROM routines copied to the same RAM address at different times. A patched copy is a ROM routine changed after it was copied. `[[code_copy]]` cannot describe either. The recompiler maps an address through the first `[[code_copy]]` range that contains it (`src/recompile/function_finder.cpp:105-125`), does not reject overlapping ranges (`tools/gba_recompile/config.cpp:337-369`), and drops an overlay config's `[[code_copy]]` whose `runtime_start` matches the base's as a duplicate, even when its source differs (`config.cpp:941-947`). At runtime, both the static table and the heal tier look a function up by PC and instruction set only, with no check of the bytes in RAM (`src/armv4t/runtime_arm.cpp:860-920`; `overlay_loader.cpp:620-631`). We found no code that drops a healed entry when the guest rewrites its RAM. *(inferred)* Once a RAM address has a static or healed body, any other code later placed there runs that stale body and records no miss. With a static body the run still reports `FULLY_STATIC`. Upstream lists the "Self-modifying / dynamic-RAM code path" as out of scope until the static case is solid (`GBA_ACCURACY_BURNDOWN.md:252-254`).

   Two game-owned hooks can handle the third kind. The engine declares them and resets them when `run_game()` returns (`runtime.cpp:1278-1282`), but never installs either:
   - **`g_runtime_ram_dispatch_hook`** (`src/armv4t/runtime_arm.h:65-70`) runs in `runtime_dispatch` for RAM PCs, before the static table (`runtime_arm.cpp:882-894`). It can compare the live RAM with known ROM sources and dispatch to the compiled body of the one that matches. MKSC does this for SDK flash helpers copied to the stack (`MKSC@b89fbb4:src/main.cpp:27`, `src/mksc_flash_dispatch.h`). It dispatches to the ROM copy's compiled body. MKSC's comment lists why that is valid for these helpers: branches stay inside the copy, and no instruction exposes its code address as data (`src/mksc_flash_dispatch.h:7-11`). *(inferred)* A routine that depends on its RAM address would need another approach, such as the next hook. The engine consults this hook only in `runtime_dispatch`.
   - **`g_runtime_force_interp_hook`** (`runtime_arm.h:72-79`) is a predicate for "executable regions whose bytes can change underneath a static dispatch entry". A non-zero result sends that PC to the interpreter. It is checked in `runtime_dispatch` (`runtime_arm.cpp:875-880`) and in the per-instruction prologue of generated code, so it also catches a generated direct call into the region (`src/runtime/runtime_bus_bridge.cpp:1020-1031`). It records no miss. The `FULLY_STATIC` verdict depends only on misses and heals (`runtime_arm_default_aborts.cpp:259-261`), and in that case the banner prints a literal `interpreted_insns=0` (lines 120-123). *(inferred)* A run that uses this hook can read `FULLY_STATIC` while interpreting, so a game that installs it has to report its own count.

   Playbook steps 2 and 10 measure which kinds Moto Racer Advance uses. The answer is an input to ADR 0001.
4. At exit the runtime prints `self_heal_coverage=FULLY_STATIC …` or `self_heal_coverage=NOT_STATIC dispatch_misses=N interpreted_insns=… healed_native=…` (`src/runtime/runtime_arm_default_aborts.cpp:119-135`). It writes:
   - `recomp_coverage_<CODE>.json`, on every exit (`runtime_arm_default_aborts.cpp:312`)
   - `recomp_master_misses_<CODE>.toml.frag`, only when the run had at least one dispatch miss (`runtime_arm_default_aborts.cpp:179`). It holds proposed `[[extra_func]]` entries, with jump-table candidates flagged where several misses sit next to each other.

   Both go in the working directory, and `GBARECOMP_MISS_FRAG` / `GBARECOMP_COVERAGE_JSON` override the paths (`runtime.cpp:2105-2116`). A run with no misses leaves an existing fragment at that path untouched (`runtime_arm_default_aborts.cpp:179`), so a stale one can survive from an earlier run. A run that was served from the heal cache is still reported `NOT_STATIC`, even with zero misses and so no fragment. The heal tier answers before the miss handler (`runtime_arm.cpp:912, 919`), so a PC already in the cache is not recorded as a miss. That is why every discovery run in the playbook turns healing off.
5. A human reviews the fragment and merges the real entries into `game.toml`. No tool ever writes `game.toml`. Then regenerate and rebuild. (`GR@5e89943:CLAUDE.md` still mentions a `recomp_seed_proposals.toml`. No code at `GR` writes that file. The fragment is the actual output.)

Healing is on by default (`CMakeLists.txt:105`, `GBARECOMP_SELFHEAL_RECOMPILE_DEFAULT`). MKSC forces it on (`CMakeLists.txt:20`). `GBARECOMP_SELFHEAL_RECOMPILE=0` turns it off for one run.

### 3.4 Strict static mode

With `GBARECOMP_STRICT_STATIC=1`, cache loading, background healing and interpreter bridging are all off, and the first miss aborts (`overlay_loader.cpp:420-425`, `runtime_arm_default_aborts.cpp:899-909`). The abort happens before the exit report, so a failed strict run writes no fragment and no coverage JSON. A pass proves that every PC dispatched on that route had a static entry. It does not prove that the entry matched the code in RAM at that moment (overlays and patched copies, §3.3), or that the generated code is correct. Upstream's own checklist calls "fully static" "a per-run tally" and says the correctness of generated code "is bounded by the codegen test set" (`GBA_ACCURACY_BURNDOWN.md:248-249`).

MKSC's acceptance script (`MKSC@b89fbb4:tools/test-attract-gameplay.ps1`):

- runs a 6,000-frame attract soak and an 18,000-frame scripted gameplay route (`GBARECOMP_INPUT_REPLAY=tests/mksc-gameplay-fuzz.input`)
- sets `GBARECOMP_STRICT_STATIC=1` and `GBARECOMP_SELFHEAL_RECOMPILE=0`
- passes `--no-window --frames N --dump-png --save-path`
- requires these strings in the log: `ppu_frames=N`, `unmapped=0 io_unhandled=0`, `self_heal_coverage=FULLY_STATIC dispatch_misses=0 interpreted_insns=0 healed_native=0`, plus a non-empty PNG

Input traces use the `gbarecomp-keyinput-v1` CSV format: `frame,keyinput_active_low`. `GBARECOMP_INPUT_RECORD` writes them and `GBARECOMP_INPUT_REPLAY` reads them (`runtime.cpp:3221-3250`).

### 3.5 How MKSC and MMZ reached full coverage

**MKSC** (history at `MKSC@b89fbb4`):

| Date | Commit | Step |
|---|---|---|
| 2026-07-14 | `328b915` | Scaffold. Minimal `game.toml` with no arrays, `speculative_literal_harvest = false`, `codegen_shards = 16`. |
| 2026-07-30 | `cb2df1c` | "Reach Mario Kart gameplay with strict static coverage". +568 lines in `game.toml`: `aot_scan_*`, `static_resume_all`, IRQ and scene callbacks, 3 `[[code_copy]]` (IRQ handler, sound driver, stack flash helper), jump tables, and callback lists from 10,000-, 12,000- and 18,000-frame input profiles, each reviewed against the ROM. Adds the acceptance script. |
| 2026-07-30 | `34c81c8`, `798400c`, `9d066f4` | Adaptive widescreen, 60 FPS mod, v0.0.1 release. Same day. |
| 2026-08-20 | `61159d7` | Decomp names imported (names only) |
| 2026-09-26, 2026-10-03 | `5a614ae`, `50bc6d3` | Coverage gaps found **after release**: a link-cable serial callback, flash helpers copied to the stack at varying depths, Time Trial results callbacks |

Final base config: 79 `[[extra_func]]`, 5 `[[jump_table]]`, 3 `[[code_copy]]`, 0 `[[data_range]]`, 1 override. The symbol overlay adds 132 `[[data_range]]` (counted with `grep`).

Two special mechanisms appear along the way:

- **Stack-copied SDK flash routines.** MKSC installs `g_runtime_ram_dispatch_hook` (`src/main.cpp:27`, `src/mksc_flash_dispatch.h`). It byte-matches a live stack copy against its ROM source and dispatches to the ROM-compiled body.
- **Position-independent RAM copies.** MMZ uses `[[extra_func]].source_addr` instead (`MMZ@218adfd:README.md`, "Verified bring-up evidence").

**MMZ** (`MMZ@218adfd:README.md`, `tools/`):

- Interactive discovery sessions (`tools/play-discovery.ps1`) record logs, coverage JSON, miss fragments, the input CSV, ROM and build hashes, and initial and final SRAM.
- `tools/review_misses.py` sorts each miss into a new root or an interior resume alias.
- `tools/verify-strict.ps1` replays the session in strict mode. Five named campaigns, of 30,000 to 60,000 frames each, pass.
- Corpus: 10,885 functions, 649 `[[extra_func]]`, 33 jump tables, 4 code copies, 69 resume declarations (counted with `grep`; the README counts 92 resume aliases).
- The README calls each pass "a path-specific static-coverage proof, not a whole-game claim".

*(inferred)* For Moto Racer Advance, the equivalent is one recorded route per mode: menus, one race per track, Ultimate mode. Each gets a strict replay gate. New routes will keep finding gaps after release.

---

## 4. Debugging and verification tools

| Tool | Status at `GR@5e89943` | External requirements | Notes |
|---|---|---|---|
| Exit coverage banner, miss fragment, coverage JSON | **Implemented** | none | §3.3 |
| Strict static mode | **Implemented** | none | §3.4 |
| Input record/replay | **Implemented** | none | `GBARECOMP_INPUT_RECORD` / `_REPLAY`. Not compatible with mGBA movie files *(inferred: no converter in the tree)*. |
| Save states | **Implemented** | none | `GBAS` container, F1–F9 / Shift+F1–F9, `savestate_save/load` over TCP. Refuses a state from a different ROM SHA-1 (`TCP.md`, "Save states"). |
| TCP debug server | **Implemented (subset)** | none | Enable with `--tcp <port>` (command-driven) or `--tcp-observe <port>` / `GBARECOMP_TCP_OBSERVE` (alongside a window) (`runtime.cpp:943-1000, 1649-1652`). With `--tcp`, the game core runs on a separate `std::thread` (`runtime.cpp:2449-2472`), and `GBARECOMP_INPUT_REPLAY` has no effect: that branch returns at line 2615, before the trace is read at 3212-3297. With `--tcp-observe`, the game stays on the main thread of a windowed run, and the server answers reads, including `ppu_state`, but cannot step (`runtime.cpp:2907-2942`). Commands in `src/debug/tcp_debug_server.cpp`: `ping frame registers read_{iwram,ewram,vram,pal,oam,io} ppu_state audio_{state,samples,cap,trace} runtime_trace cyc_anchor irq_cap mmio_cap state_hash counters misses m4a_detect m4a_dump matrix_state symbol screenshot pause continue resume step step_inst step_to_vblank run_frames run_status set_keyinput set_break_pc savestate_save savestate_load fp_save quit`. Games can add commands through `RunOptions::tcp_command`. |
| Per-frame ring and reverse debugger (`history`, `get_frame`, `rdb_*`, `*_diff`) | **Documented, not implemented** | none | `TCP.md` and `DEBUG.md` describe them, but none of these command names occurs anywhere in `src/`, `tools/` or `oracle/`. `src/debug/trace_ring.h` is a stub. `debug.ini` is never read, and `GBARECOMP_DEFAULT_DEBUG_PORT` is defined but unused (`runtime.cpp:104-105`). |
| Opt-in traces | **Implemented** | none | `GBARECOMP_INSN_TRACE` + `GBARECOMP_FP_SAVE`, `GBARECOMP_MMIO_CAP` / `_DUMP`, `GBARECOMP_IRQ_LOG`, `GBARECOMP_SWI_LOG`, `GBARECOMP_RUNTIME_TRACE`, `GBARECOMP_AUDIO_FIFO_TRACE`, `GBARECOMP_WRAM_TRACE` (JSONL), `GBARECOMP_FRAMEDUMP_DIR`, `GBARECOMP_IWRAM_DUMP`, `GBARECOMP_HANG_WATCHDOG` (all found via `getenv` in `src/`) |
| `state_hash` | **Implemented** | none | FNV-1a-64 over IWRAM+EWRAM+VRAM+PAL+OAM and the cycle count (`tcp_debug_server.cpp:582-600`). It does not cover CPU or device state (`COSIM_ORACLE.md`). |
| Co-simulation (first divergence) | **Implemented, opt-in; coordinator fails on macOS as shipped** | Python 3 | **macOS:** the coordinator passes a Windows-only `creationflags` to `subprocess.Popen` (`oracle/gba_cosim.py:82-84`). Python 3.11.6 on this Mac raises `ValueError: creationflags is only supported on Windows platforms` before any process starts (checked). A one-line local patch fixes it (§7.2). Build with `-DGBA_COSIM=ON`. Compares recomp against recomp, or against the in-tree interpreter (`GBARECOMP_FORCE_INTERP`), at cycle-stride checkpoints. Coordinator: `oracle/gba_cosim.py`, configured with `GBA_COSIM_EXE/ROM/BIOS/CONFIG/CWD`. The status line at the top of `COSIM_ORACLE.md` still reads "DESIGN … no engine code yet", but its own log records §1–§6 built on 2026-07-01, and `src/debug/cosim.cpp` has the engine. **Limit:** the interpreter shares `src/gba` with the recomp, so device-model bugs show up identically on both sides (`tools/gbaref/README.md`). |
| mGBA oracle (`gbarecomp_oracle`) | **Implemented, opt-in** | mGBA 0.10.5 built from source with `oracle/setup-mgba.sh`; MPL-2.0; separate process on TCP 19843 | `-DGBARECOMP_BUILD_ORACLE=ON` (`CMakeLists.txt:1106`). Accepts `--bios`, `--rom`, `--port` and serves the `emu_*` / `read_emu_*` commands (`oracle/main.cpp`). Made buildable on macOS arm64 in `GR` commit `f4a065e` ("Verified on macOS arm64 (M4, macOS 26, AppleClang 21)"). 12 Python scripts in `oracle/` still contain `.exe` strings; some route through `recomp_paths.exe_name()`. |
| gbaref (libretro reference) | **Implemented, Windows-oriented** | SDL2 and a libretro mGBA core binary (not in the repo) | `tools/gbaref/`: a human plays both builds to the same scene, then `oracle/ref_diff.py` diffs the WRAM traces. `build.sh` hardcodes MSYS2 and `.exe`. *(inferred)* Porting it to macOS is small. |
| NanoBoyAdvance oracle | **Not available to us** | GPL-3.0 | Python comparators exist (`oracle/*_nba.py`, `nba_common.py`, port 19844). The server lives in a private `_nba_oracle/` directory outside the public repos (`GBA_ACCURACY_BURNDOWN.md:75`; `MMZ@218adfd:tools/run-nba-oracle.ps1:2`, `$OracleRoot = ..\..\_nba_oracle`). `COSIM_ORACLE.md` §8 lists the NBA co-sim peer as unbuilt. |
| `bios_smoke` | **Implemented** | BIOS | Interpreter-only BIOS runner |
| Web browser acceptance tests | **Implemented** | Chrome or Chromium, `websocket-client`, a private embedded-ROM bundle | `tests/web/test_game.py`, `test_save.py` (`packaging/web/README.md`, "Browser acceptance tests") |

For the "replay mGBA inputs" step in `docs/plan.md` Phase 2: gbarecomp's own replay format plus the mGBA oracle's `emu_set_keys` / `emu_step_frames` give a scripted lockstep. *(inferred)* Recording directly in the mGBA app would need a converter we would have to write.

---

## 5. Web

### 5.1 Exact steps (from `GR@5e89943:packaging/web/README.md`, `docs/WEB_ROM_BUILD.md`, `README.md`)

```sh
# native recompiler + recompiled BIOS
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DGBARECOMP_COMPILER_CACHE=OFF
cmake --build build --target gba_recompile -- -j10
build/gba_recompile --bios bios/gba_bios.bin --config bios/gba_bios.toml --out build/generated_bios
# export the game as a library project, then build the bundle
GBARECOMP_CORE="$PWD/build/gba_recompile" python3 tools/cli.py build \
  --rom /path/to/game.gba --output /path/to/game-recomp --config /path/to/game.toml --force
bash packaging/web/build_web.sh /path/to/game-recomp build/generated_bios /path/to/game.gba "" /path/to/game.toml
python3 packaging/web/serve.py /path/to/game-recomp/web 8080
```

Requirements: Bash, Python ≥3.9, CMake, a native C++ toolchain, the Emscripten SDK (README: "validated with 6.0.10"), and `sha1sum`, `shasum` or Python.

### 5.2 What `build_web.sh` does (`GR@5e89943:packaging/web/build_web.sh`)

1. Writes `runtime.toml` from the config and takes the expected ROM SHA-1 from `[rom].sha1` or from the ROM argument, which is only hashed (lines 138-152). The BIOS hash defaults to `300c20df…` (line 155).
2. Configures the engine with `emcmake`, `-DGBARECOMP_WEB_HOST=ON` and `-DGBARECOMP_GENERATED_BIOS_DIR=<dir>` (line 187). It fails if the recompiled BIOS is missing.
3. Builds the exported project's `libgbarecomp_game.a`. It refuses one whose `CMakeLists.txt` lacks `-mtail-call` (line 204).
4. Links `packaging/web/main.cpp` (`return gbarecomp::run_game(argc, argv);`) with the engine archives and the game library (lines 212-222). Link options come from `cmake/web_host_link_options.cmake`:
   - `-pthread -mtail-call -sPROXY_TO_PTHREAD -sPTHREAD_POOL_SIZE=4`
   - `-sALLOW_MEMORY_GROWTH -sINITIAL_MEMORY=134217728`
   - 16 MiB stacks, `-lidbfs.js`, `--profiling-funcs --emit-symbol-map`
5. Builds the AudioWorklet DSP and copies `index.html`, `host_web.js`, `save_store.js`, `asset_store.js`, `bootstrap.js` and `audio_worklet.js`. Writes `build_info.js` and `manifest.json`, which holds SHA-256 hashes of the bundle and of its inputs.
6. Default output: `<project>/web`. Build directories: `GBARECOMP_WEB_BUILD_DIR` (default `<gbarecomp>/build-web-host`, *inside the engine checkout*), `GBARECOMP_WEB_GAME_BUILD_DIR`, `GBARECOMP_WEB_OUT_DIR`.

Consequences for us:

- **`tools/cli.py build` takes only one `--config` and one `--symbols`, and no `--data-symbols`** (`tools/cli.py:258-266`). If `--max-functions` is omitted, the recompiler's 4096 default applies.
- **Game-owned code is not linked.** No `src/*.cpp`, no trusted plugins, no `RunOptions`. The engine refuses recomp-ui on wasm (`CMakeLists.txt:472`), and `build_web.sh` does not enable `GBARECOMP_ENABLE_MODS`.
- *(inferred)* To ship any game hook or enhancement on the web, we will write our own Emscripten link step. Two ways: follow `build_web.sh` with our `main.cpp`, or use `gbarecomp_add_runtime_target()` from `runtime.cmake`, which already applies the web link options when the core is configured with `GBARECOMP_WEB_HOST` (`cmake/runtime.cmake.in:56-148`). Enhancements would be wired directly in `main()` or read from `runtime.toml`, not through the `.gbamod` UI.
- Web has no self-healing. Uncovered code still runs, through the interpreter bridge, with no healing and at lower speed (`self_heal_recompile=UNAVAILABLE host=wasm interpreter_bridge=NOT_STATIC`, `overlay_loader.cpp:428-431`). The script's own comment says a web build "is only honest for a game whose coverage is FULLY STATIC" (`build_web.sh:37-39`). We recommend treating strict-static coverage on native as the quality bar for every route we ship on the web. It is a bar we set, not a hard requirement of the engine.

### 5.3 Hosting

`serve.py` sends `Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Embedder-Policy: require-corp` and `Cache-Control: no-store`, and serves `.wasm` as `application/wasm` (`packaging/web/serve.py:16-25`). The README says any static host works if it sends the two COOP/COEP headers over https, or from localhost. *(inferred, general web-platform knowledge, not from gbarecomp)* Hosts that cannot set custom response headers, such as plain GitHub Pages, would need a workaround. **unverified** for any specific host.

### 5.4 Player experience (`packaging/web/index.html`, `README.md`)

- "Choose ROM…" and "Choose BIOS…" buttons. The ROM is checked against the bundle's SHA-1. A wrong ROM is refused with both hashes, and a 16 KiB file offered as the ROM is recognised as a BIOS.
- Both files stay in that browser's IndexedDB. "Forget ROM/BIOS" removes them. Without IndexedDB (some private windows), they last for the page only.
- Start/Pause/Fullscreen/Enable audio. The audio context needs a real click.
- Volume, filter (Nearest/Linear/Sharp), 9 save-state slots, export/import/restore of battery saves, and a log area. `?autostart=1` starts as soon as stored files are present.
- Rendering uses WebGL from a shared triple buffer. Keyboard bindings follow the native defaults. `navigator.getGamepads()` and an on-screen touch pad are supported (`host_web.js:80-88, 239, 449`). Saves go to IDBFS under `/saves/<ROM SHA-1>/`.
- Missing on web: the in-game settings menu and overlay text (PR #16 description, mstan/gbarecomp#16). The page also reports no gyro or solar sensor (`host_web.js:239`, `gyro:false,solarSensor:false`).
- The page is a developer-style shell. Its title is "gbarecomp web" and it uses a monospace log layout. *(inferred)* We will want our own shell for players.

### 5.5 Maturity

- PR #16 ("WebAssembly browser host and guaranteed tail transfers", by contributor FabioCeleste, merge `4855ba2`, 2026-10-09) is the whole web host. The PR body lists vibration, orientation lock and safe-area insets as "Not tested on real phones/tablets" (unit tests only), and reports that MMZ's web run hit a dispatch miss in IWRAM.
- Two merges followed on the same day, and our pin is the second: PR #29 (`6283943`, opt-in shared-RAM DMA batching and the opt-in HLE scanline renderer) and PR #31 (`5e89943`), which makes that HLE renderer the default (§9, "Engine pin").
- Bring-your-own-ROM followed in `b49bb86` (2026-09-25 on its branch).
- The Node unit tests for the web host (`web_*_tests`) pass on this machine (§7). No browser build was done for this study, because Emscripten was not installed yet.

### 5.6 What the "ROM-free" bundle still contains, and publishing options

`game.wasm` links `libgbarecomp_game.a`, which is compiled from the recompiled ROM. It also links `libgbarecomp_runtime.a`, which includes `bios_recompiled.cpp` (`build_web.sh:212-222`; `CMakeLists.txt:418-449`). gbarecomp's own documents disagree about whether that can be published:

- `GR@5e89943:packaging/web/README.md:12`: a bundle "contains only code and settings and can be published". `docs/WEB_ROM_BUILD.md:6` repeats it: "A normal bundle is therefore safe to publish." So does the main `README.md:318-319`.
- `GR@5e89943:README.md:253-255`: generated C++ "is derived from it and should not be redistributed without permission".
- `GR@5e89943:packaging/README.md:78-80`: "A recompiled binary already embeds translated ROM code, so these scripts are for building **your own** copy from **your own** dump — not for redistribution."
- `GR@5e89943:src/runtime/generated_bios/.gitignore`: the BIOS lowering "embeds Nintendo's BIOS bytes".

**Precedent.** `MKSC`, by gbarecomp's author, publishes native binaries on GitHub Releases: eight releases from v0.0.1 (2026-07-30) to v0.1.4 (2026-10-04), the latest with a Windows zip and a Linux AppImage (`gh release list -R mstan/MarioKartSuperCircuitRecomp`, checked 2026-10-10). Its release script requires the recompiled BIOS (§1.4), so those binaries contain both kinds of code. *(inferred)* This shows what the engine's author does. It says nothing about what the games' rights holders accept, and we found no statement from any rights holder.

Our `CLAUDE.md` bans committing generated code. It does not cover publishing a compiled bundle.

**Options.** *(inferred, not legal advice)* The legal column compares the options with each other. It does not assess risk under any particular law.

| Option | What is distributed | Legal exposure | Technical cost |
|---|---|---|---|
| **(a) Local builds only** | Our source, docs and scripts. Each player builds from their own ROM and BIOS. | Lowest. Nothing derived from the ROM or the BIOS leaves the player's machine. Matches `packaging/README.md:78-80` and `README.md:253-255`. | Each player needs CMake, a C++ toolchain, Emscripten and their own BIOS dump, so in practice the audience is developers. |
| **(b) Published bundle, gbarecomp default** | `game.wasm` with recompiled ROM code and recompiled Nintendo BIOS code | Highest. Distributes compiled translations of both copyrighted works. Goes against `README.md:253-255` for the ROM part. Same shape as `MKSC`'s releases. | None beyond Phase 3. `build_web.sh` builds it as is. |
| **(c) Published bundle without the recompiled BIOS** | `game.wasm` with recompiled ROM code. The runtime boots through BIOS HLE when no recompiled BIOS is linked (`runtime.cpp:1566-1583`). It still loads the player's BIOS dump, and *(inferred)* whatever real BIOS code runs goes through the interpreter (§2.3). | ROM-derived code as in (b). No Nintendo BIOS-derived code. Players still need a BIOS dump. | `build_web.sh` refuses to build without the recompiled BIOS (lines 174-176, 188-189), so this needs our own link step (§5.2). BIOS code that HLE does not cover is interpreted: slower, and never `FULLY_STATIC`. On wasm the interpreter bridge stays on (`overlay_loader.cpp:428-431`). HLE boot without the recompiled BIOS cannot keep the BIOS intro (`runtime.cpp:1575-1582`), which *(inferred)* shifts IRQ timing the way `skip_intro` does (§2.3). Not tried on the web: **unverified**. |
| **(d) Published bundle with an open-source BIOS** | `game.wasm` with recompiled ROM code and a recompiled open BIOS, such as the MIT-licensed Cult-of-GBA BIOS | ROM-derived code as in (b). No Nintendo code. Players need only their ROM. | Studied separately in PR #3 (`docs/research/open-bios.md` on branch `docs/open-bios`, not merged when this was written): our own BIOS config and hash, and fidelity differences from the retail BIOS, **unverified** for this game. A variant combines (c) with an open BIOS file loaded at runtime. |

All options except (a) distribute compiled code derived from the game ROM. *(inferred, not studied)* A bundle with none would be the engine interpreting every instruction. That is an emulator, which removes the reason for recompiling.

**Recommendation for the owner:** (a) through Phases 1–3. Nothing has to be published to make progress, and Phase 2 needs native local builds anyway. Decide before any hosting. If the owner then wants a public page, prefer (d) to (b): no Nintendo code in the bundle, and players need only their ROM. The ROM-derived code remains, and only the owner can accept that risk. Use (c) only if (d) fails, because it keeps the BIOS requirement for players and costs speed and static coverage.

---

## 6. Enhancements: MKSC's 60 FPS and Adaptive Widescreen

### 6.1 60 FPS track rendering

- **Mechanism.** `MKSC@b89fbb4:game.toml:53-60` explains it. The road renderer generates affine parameters every frame but alternates between two IWRAM output buffers. DMA0 always reads the first one, so the visible road updates at 30 FPS. The fix overrides the Thumb `MOVS` immediate at `0x08030C14` with the current selector value, which keeps the selector at buffer zero.
- **Game-owned code.** `src/mods/mksc_track_60fps_plugin.cpp` (49 lines) chains `g_runtime_thumb_alu_imm_override`. When `pc == 0x08030C14` and the original value is 1, it returns `g_cpu.R[1]`. It registers the activation plugin `mario-kart-super-circuit.track-60fps`.
- **Package.** `mods/preloaded/packages/mario-kart-super-circuit.enhancement.track-60fps/1.0.0/manifest.toml` targets the ROM SHA-1 and is `default_enabled = false`.
- **Framework support.**
  - `[[thumb_alu_immediate_override]]` makes codegen emit a runtime check at that one PC only. Every other site stays a compile-time literal at zero cost (`TOML_SCHEMA.md`).
  - The hook type is `RuntimeThumbAluImmediateOverride` (`src/armv4t/runtime_arm.h:50-53, 87-88`).
  - The mod runtime provides `GBA_MOD_CONSTRUCTOR` and `gba_mod_register_activation_plugin` (`src/runtime/mod_runtime.h:45, 105-111`).
- **Origin.** The patch research is antimattur's (`MKSC` README and manifest). The README credits antimattur for both the decompilation work and the patch. *(inferred)* The research probably drew on that decomp. *(inferred from the `game.toml` comment)* The road parameters were already computed every frame; only the buffer DMA0 reads was refreshed at 30 Hz.

### 6.2 Adaptive Widescreen

- **`RunOptions` in `src/main.cpp:41-45`.** `mod_game_id`, `mod_owns_adaptive_view = true`, `max_resize_view_width = 480`, `resize_driven_view = true`, `extended_view_init = &mksc::install_extended_view`.
- **`src/mksc_extended_view.cpp`, 344 lines, game-owned.** It installs four PPU providers declared in `GR@5e89943:src/gba/gba_ppu.h:241-290`:
  - `g_ws_tilemap_provider`: in the margins, keep wrapping BG1–BG3 scenery; BG0 (the HUD) is unavailable; pillarbox non-race scenes.
  - `g_ws_bg_x_provider`: moves the left and right BG0 HUD rectangles to the edges of the wider view and removes the original copies.
  - `g_ws_obj_attr_x_provider`: moves the minimap markers and the speedometer needle sprite.
  - `g_ws_affine_filter_provider`: smooths affine BG2 (the road) during races.
- **Road extension.** The affine road needs no provider. It "is extrapolated directly by the wide compositor".
- **Scene detection.** `DISPCNT` mode ≤ 1, all four BGs and OBJ enabled, `BGxCNT` signatures, and the "LAP"/"TIME" tile IDs in screen block 7. The result is cached per VBlank (`g_runtime_vblank_starts`).
- **Plugin and package.** `src/mods/mksc_adaptive_view_plugin.cpp` calls `gba_mod_set_adaptive_view_enabled(1)`. A manifest sits under `mods/preloaded/…adaptive-view/`. CMake copies `mods/preloaded` next to the executable (`CMakeLists.txt:128-135`). `tests/extended_view_tests.cpp` covers the layout logic.

### 6.3 Game-owned vs framework

| Framework (`GR`) | Game (`MKSC`) |
|---|---|
| Wide PPU surface up to 896 pixels wide, and up to 864 tall with game-authored vertical margins (`gba_ppu.h:120-137`). Live resize policy. Provider seams. | Which scenes are wide, the HUD rectangles, sprite identification |
| `[[thumb_alu_immediate_override]]` codegen and runtime hook | The address, the override value, when to enable |
| Mod loader: `.gbamod` ZIPs hold data and manifests only. Checks ROM SHA-1, feature dependencies and plugin IDs before activation. Mods page in recomp-ui. (`docs/MOD_PACKAGES.md`) | Trusted plugins, statically linked and registered by ID; built-in manifests |
| `[[mod_function_hook]]`: replace a reviewed guest function entry with a native callback that writes the post-call CPU state, including R15 (`docs/MOD_PACKAGES.md`, "Trusted function-entry hooks") | (not used by MKSC) |
| `g_runtime_ram_dispatch_hook` and `g_runtime_force_interp_hook`: declared and reset by the engine, never installed by it (§3.3) | Which RAM ranges change, how to recognise each copy. MKSC installs the RAM dispatch hook for stack-copied flash helpers (`src/main.cpp:27`). |
| `RunOptions::extended_view_frame`, `host_overlay` (2D lines, rects, circles, text; no textures; `src/runtime/host_overlay.h`), `g_ws_obj_margin_provider`, `gba_mod_publish_foreign_background` (240×160 BGR555) | Their use |

### 6.4 Transferability to Moto Racer Advance

How the game draws its races is **unverified**. It is the first Phase 1 measurement (playbook step 2).

**How to tell the cases apart** *(inferred)*. The `DISPCNT` mode number alone can mislead. A game can rasterize 3D in software into tile graphics in mode 0–2, and a bitmap mode can show a mostly static picture. During a race, look at what changes from frame to frame:

- the `DISPCNT` mode and which layers are on
- how much VRAM is rewritten per frame, and by what: CPU stores or DMA from RAM into tile or bitmap memory point to software rendering, while tilemap and scroll updates alone point to case A
- whether the BG2/BG3 affine registers change per scanline, through HBlank DMA or an HBlank interrupt, which is the "Mode 7" road technique MKSC uses

mGBA's I/O register viewer, tile and map viewers, memory viewer and write watchpoints show all three without a recompile. Two cases follow.

**Case A: affine or tiled backgrounds, like MKSC** (`DISPCNT` mode 1 or 2 during races). The framework has seams for widescreen and the frame-rate patch type, but nothing for resolution. MKSC's own work does not transfer *(inferred)*:

- **Widescreen, backgrounds.** The affine road extends into the margins for free.
- **Widescreen, HUD.** HUD layers can be moved with the same providers. But which scenes are races, where the HUD sits, and which sprites to move is game-specific. In MKSC that is 344 lines (`MKSC@b89fbb4:src/mksc_extended_view.cpp`, with scene detection keyed to MKSC's "LAP"/"TIME" tile IDs). We would have to find our equivalents by reverse engineering, without a decomp.
- **Widescreen, world objects.** The OBJ seams only re-place or clip sprites the game has already put in OAM, or draw game-authored pixels in the margins (`GR@5e89943:src/gba/gba_ppu.h:276-305`). MKSC moves only HUD sprites (§6.2). If the game culls opponents and trackside objects at the edge of its 240-pixel view (**unverified**; `docs/plan.md` Phase 4 already expects something like it), the margins show road with no bikes. Two fixes, both reverse engineering of game logic *(inferred)*: patch the culling, or read object positions from game RAM and draw them in the margins through `g_ws_obj_margin_provider`.
- **Resolution.** No internal-resolution path exists in either case. `docs/plan.md` Phase 4 wants affine layers re-rendered at higher resolution. The engine's PPU writes one output pixel per GBA pixel. Margins make the canvas wider (up to 896 columns, `gba_ppu.h:120-137`) but add no pixels inside the original view. The affine filter interpolates texture samples at that same density (`gba_ppu.cpp:1716-1721`). *(inferred)* A higher-resolution affine or tile renderer is new engine-side work, in our fork or a local patch of the submodule.
- **Frame rate.** If the game double-buffers per-scanline affine tables the way MKSC does, a similar one-instruction override might raise the visible frame rate. Finding the instruction and the buffer logic requires our own reverse engineering, for the same reason.

**Case B: software-drawn 3D** (in a bitmap mode, `DISPCNT` mode 4 or 5, or rasterized into tiles). Little transfers, and the framework lacks several pieces:

- **Widescreen.** In bitmap modes the wide renderer draws the margins as backdrop: "A bitmap has a fixed width … the margins fall outside its bounds, staying backdrop" (`GR@5e89943:src/gba/gba_ppu.cpp:1794-1799`). The game's rasterizer only fills a 240-wide (mode 4) or 160×128 (mode 5) page in VRAM, so there is nothing to reveal. A wider view needs the camera to project wider and a renderer that draws into a host-side buffer wider than VRAM.
- **Resolution.** No internal-resolution or upscaling path exists, as in case A. Presentation filters only: sharp, linear, affine filter, colour profiles. `host_overlay` cannot draw textured triangles.
- **Frame rate.**
  - Every guest instruction advances the master clock by its ARM7TDMI cost (`docs/CPU_TIMING.md:3-7`; `COSIM_ORACLE.md`, "shared alignment clock"). *(inferred)* A CPU-bound software renderer therefore keeps the frame rate it has on hardware.
  - There is no overclock or cycle-scaling option. A search for `overclock`, `cycle_scale` and similar terms finds only the host fast-forward ("Turbo") key, which speeds up everything, game logic included.
  - *(inferred)* Two paths could raise the frame rate. One is a native renderer that replaces the original and charges fewer guest cycles than it did (below). The other is a new engine feature that discounts guest cycles, an overclock in effect. Both change guest timing on purpose, so mGBA comparisons stop matching. The overclock changes it for the whole game, and game logic tied to frame counts or timers may break.
- **Likely path for case B** *(inferred)*:
  1. Find the rasterizer entry points with mGBA's debugger and Ghidra.
  2. Declare them as `[[mod_function_hook]]`.
  3. Implement the callback in game-owned C++: read the guest's transformed geometry and draw it natively. A callback that handles the call skips the original body, and with it the body's guest cycles: the generated hook returns before the first instruction charges any (`GR@5e89943:src/recompile/emit_function.cpp:498-519`). Pixel-identical VRAM is then not enough. The game would run ahead of hardware timing, and input replays and mGBA comparisons could desync. Two options *(inferred, neither tried)*:
     - **Observe, do not replace.** Read the geometry, then return 0. The original body runs and charges its own cycles, and guest state and timing stay identical. The native renderer draws only into a host buffer at higher resolution or wider. This serves resolution and widescreen, but not frame rate. `MC` registers read-only entry hooks of this kind (`MC@1aa1128:src/mods/minish_zelda1_foreign_world_plugin.cpp:802, 1265-1280`).
     - **Replace.** Only needed when the original body must not run, as for a frame-rate gain. Draw into VRAM and the host buffer. To keep timing and replays identical, the callback must charge the replaced function's measured cycle cost, for example with `runtime_tick()` (declared in `src/armv4t/runtime_arm.h:404`; never called from a hook in any repo we read). The cost depends on the scene, so it has to be measured per call, and IRQs that would have fired during the function then fire at its end. Charging less is what would raise the frame rate, and it changes timing on purpose (see "Frame rate" above).

     A wider host buffer needs geometry outside the original view, which the game may cull (see case A, world objects).
  4. Write a WebGL presentation path in the web host for the high-resolution buffer. The current host only displays the 240×160 (or wider) RGB frame.

  All of this is new work in our repo. Upstream has no such path. Its roadmap lists "internal-resolution scaling" as out of scope "for now" (`GR@5e89943:docs/ROADMAP.md:521-525`), but the same line lists widescreen, which has since shipped, so the list says little about future plans. MKSC's 49-line plugin is not a model for its size.
- **Watchdog false positive.** Per mstan/gbarecomp PR #2 (bitmap modes), a software rasterizer "legitimately never HALTs", and the hang watchdog can mistake that for a busy-spin. The watchdog is opt-in (`GBARECOMP_HANG_WATCHDOG=1`, `runtime_bus_bridge.cpp:1100-1104`).
- **Bitmap modes are young.** They were added in July 2026 (PR #2, merge `80725f9`). Only mode 4 was exercised then, by Boktai's intro; "Modes 3 and 5 are untested". The later scanline-HLE comparison covered modes 0–5 on synthetic frames (`docs/ENGINE_HLE_DMA.md:10-16`), and that HLE renderer is the default at our pin. That is one more reason to keep an LLE build for comparison while bitmap rendering is investigated (§9, "Engine pin").

---

## 7. Platform support and macOS arm64

### 7.1 Evidence

| Evidence | What it shows |
|---|---|
| Our build, 2026-10-10 | `GR@5e89943` configures with `cmake -S gbarecomp -B build -G Ninja -DCMAKE_BUILD_TYPE=Release`: SDL2 found at `/opt/homebrew`, toml++ fetched, BIOS placeholder used. All 186 build steps succeed (141 lines containing `warning:`, mostly `-Wmismatched-tags`; no errors). `ctest`: **100% tests passed out of 50**, including `codegen_tests`, `heal_gate_tests`, `ppu_smoke_tests` and all 12 `web_*` tests (Node, Python and one C++). Wall time: configure 8 s, build 7 s, test 10 s. |
| `GR` commit `f4a065e` (2026-07-28) | mGBA oracle builds on macOS arm64 ("M4, macOS 26, AppleClang 21") |
| `GR` commit `b75bb63` (2026-07-29) | Self-heal fixed for macOS and Linux: compiler path, linker flags, `dlopen` loader. Measured on Boktai. |
| `GR` commits `7451315`, `1166f7e` (2026-07-30) | Link-group gating by linker type (`APPLE OR msvc` gets a plain list); the BIOS `_start` symbol renamed for ELF. "19/19 engine suites pass on macOS." |
| `GR` commit `4cabc7d` + `packaging/package_macos.sh` | Portable macOS package. The commit message says the macOS path builds Boktai and "boots the real ROM for 30 frames from a freshly extracted tarball". |
| `BOK@69ff053:.github/workflows/ci.yml` | ROM-free CI on `macos-14` and `ubuntu-24.04`: engine build, `ctest -E "oracle\|bios_intro_flawless"`, and a syntax check of game sources. `BOK@69ff053:CMakeLists.txt:170-184` links on Apple without `--start-group`. |
| `GR@5e89943:.github/` | Contains only an image, so the engine has no CI of its own. `MKSC` and `MMZ` have no `.github/`. |
| `MKSC@b89fbb4:tools/linux/` | Linux x86_64 release built in an Ubuntu 22.04 Docker image |
| Windows | Primary platform. MSYS2 MinGW is the supported toolchain, not MSVC (`BOK` CI notes that `bios_hle.cpp` uses `__builtin_clz`). An optional Clang-MinGW toolchain is in `cmake/toolchains/clang-mingw.cmake`. |

### 7.2 What will break on macOS arm64 with Apple clang

| Problem | Evidence | Fix |
|---|---|---|
| `-Wl,--start-group` in game CMake | `MKSC@b89fbb4:CMakeLists.txt:77`, `MMZ@218adfd:CMakeLists.txt:65`, `MC@1aa1128:CMakeLists.txt:120`. Apple `ld-1267` on this machine: `ld: unknown options: --start-group --end-group`. | Use `target_link_gbarecomp_runtime_stack()` (`GR@5e89943:CMakeLists.txt:565-588`) |
| PowerShell tools with Windows paths (`build\gba_recompile.exe`, `-Algorithm SHA1`) | `MKSC` `tools/*.ps1`, `MMZ` `tools/*.ps1` | Write `bash` or Python equivalents |
| `GBARECOMP_STATIC_RELEASE` | Pins MSYS2 `libSDL2.a` and Windows system libraries (`CMakeLists.txt:102-104, 134-170`; `packaging/README.md`) | Do not use it. Package with `package_macos.sh`. |
| Homebrew `sdl2` may become `sdl2-compat`, which loads SDL3 with `dlopen` | `packaging/README.md`. This machine still has SDL2 2.32.10, which links CoreAudio directly per `otool -L`; `brew info` shows the formula is now an alias of `sdl2-compat 2.32.74`. | Fine for development builds. Packaging must bundle `libSDL3.dylib`, which `package_macos.sh` does. |
| `.app` bundle cannot be signed with the launcher assets beside the executable | `packaging/README.md` | Ship a flat directory. Irrelevant for the browser target. |
| `oracle/*.py` with `.exe` strings; `tools/gbaref/build.sh` hardcodes MSYS2 | §4 | Patch locally or upstream when we need them |
| Co-sim coordinator launches its two runtimes with `creationflags=0x00000200` (Windows `CREATE_NEW_PROCESS_GROUP`) | `oracle/gba_cosim.py:82-84`. On this Mac, `subprocess.Popen(..., creationflags=0x200)` under Python 3.11.6 raises `ValueError: creationflags is only supported on Windows platforms` (checked). The `ctypes.windll` priority call that follows is inside `try`/`except` (lines 88-93), so it is harmless. | One-line local patch to line 84: `creationflags=0x00000200 if os.name == "nt" else 0`. With it, the script's `launch()` starts its process on this Mac (checked with a stand-in executable; no full co-sim run). Keep it as a patch file in our repo and apply it to the submodule's working tree; do not commit inside the submodule. |
| NanoBoyAdvance oracle | Private | Use the mGBA oracle and co-sim (with the patch above) instead |
| Netplay (`GBARECOMP_NETPLAY`, off by default in the engine; MKSC turns it on) | `cmake/GbaNetplay.cmake:1`; `MKSC@b89fbb4:CMakeLists.txt:7-12` | Keep it off. Untested on macOS by us. |
| Host stack size (likelihood: plausible) | The engine says "Recompiled guest code maps guest calls (and some tail-call loops) onto the host call stack, so game executables reserve a large stack" (`src/runtime/mobile_platform.h:36-41`). Natively, generated code transfers control with `f(); return`, which the compiler is not required to turn into a tail call; only wasm builds get guaranteed tail calls (`src/armv4t/runtime_arm.h:195-229`). Every other platform reserves a large stack: 16 MiB on Windows through the executable's stack reserve (`CMakeLists.txt:332-366`, applied to `gbarecomp_runtime` users at line 404), which is also the default for new threads *(inferred, general Windows behavior)*; 16 MiB on the web through `-sSTACK_SIZE` and `-sDEFAULT_PTHREAD_STACK_SIZE` (`cmake/web_host_link_options.cmake:12-13`); 256 MiB on Android for the game thread (`src/runtime/mobile_platform.h:42`, `mobile_platform.cpp:34-44`). `MKSC` and `MMZ` set 16 MiB again for Windows only (`MKSC@b89fbb4:CMakeLists.txt:137-141`, `MMZ@218adfd:CMakeLists.txt:126-130`). macOS gets nothing. Measured on this Mac with a test program: main thread 8,372,224 bytes, `std::thread` 536,576 bytes (512 KiB + one page). Linked with `-Wl,-stack_size,0x1000000`, the main thread gets 16,777,216 bytes and `std::thread` still 536,576. With `--tcp`, the game core runs on a plain `std::thread`, with no stack size set (`runtime.cpp:2449-2472`), so by the measurement above it gets 512 KiB on macOS. | Link our executable with `-Wl,-stack_size,0x1000000` on Apple (playbook step 9). That covers headless and windowed runs, including `--tcp-observe`, where the game stays on the main thread. It does not cover `--tcp`. For observation, use `--tcp-observe`. Oracle lockstep needs `--tcp` and its `step` command, and it may need an upstream change that creates the game thread with an explicit stack size. |
| Self-heal compiler | Uses `c++` (Apple clang) through `PATH`. `gcc_toolchain_available()` probes `g++`/`gcc`/`cc`/`clang` (`overlay_loader.cpp:131-165`). | Works per `b75bb63`. Disable it for strict runs. |

---

## 8. Licensing

| Component | License | Source | Applies to us when |
|---|---|---|---|
| gbarecomp | "PolyForm Noncommercial License 1.0.0", Copyright (c) 2026 Matthew Stanley | `GR@5e89943:LICENSE` | Always: native build, web build, any derived code |
| gbarecomp `src/runtime/bios_hle.{h,cpp}` | **MPL-2.0** (derived from mGBA `src/gba/bios.c`) | `GR@5e89943:THIRD_PARTY_ATTRIBUTION.md`, `third_party/MPL-2.0.txt` | Compiled into every runtime. File-scoped copyleft. Changes to those two files stay MPL-2.0. Any distribution in executable form, native binary or web bundle alike, must make the source of those files available and tell recipients how to get it (MPL-2.0 §3.2(a)). *(inferred)* A link to the pinned gbarecomp commit in the bundle's notices is the obvious way. |
| Ported files (`gba_m4a`, `color_lut`, `gba_rtc`, `audio_shadow`, `mp2k_shadow`) | MIT OR Apache-2.0 (from JRickey/gba-recomp) | `THIRD_PARTY_ATTRIBUTION.md` | Always. Keep the attribution headers. |
| arm-recomp-core | MIT, Copyright (c) 2026 Matthew Stanley | `ARC@1f13cdf:LICENSE`, `PROVENANCE.md` | Always |
| recomp-net | MIT | `RNET@c58f125:LICENSE` | Only with `GBARECOMP_NETPLAY=ON` |
| libjuice v1.7.2, fetched by recomp-net | MPL-2.0 per its upstream, **unverified** here | `RNET@c58f125:CMakeLists.txt:144-155` | Only with netplay |
| rbengine | MIT | `RBE@2a03e73:LICENSE` | Only with netplay |
| SDL (mstan fork, 2.32.10) | zlib | `SDL@8e28503:LICENSE.txt` | Native builds and Android. Not used on web. |
| Emscripten runtime (JS glue and its system sources) | MIT or University of Illinois/NCSA, at our choice | `LICENSE` of the Emscripten 6.0.10 SDK installed here (`upstream/emscripten/`) | Web bundle only |
| musl libc, as shipped in Emscripten | MIT | `system/lib/libc/musl/COPYRIGHT` in the same SDK | Web bundle only |
| libc++, libc++abi, libunwind, compiler-rt, as shipped in Emscripten | Apache-2.0 with LLVM exception. The exception waives the notice conditions for portions embedded in compiled object code. | `system/lib/{libcxx,libcxxabi,libunwind,compiler-rt}/LICENSE.TXT` in the same SDK | Web bundle only |
| dlmalloc, as shipped in Emscripten | Public domain (CC0) | `system/lib/dlmalloc.c:53-54` in the same SDK | Web bundle only |
| toml++ v3.4.0 | MIT | `GR@5e89943:third_party/README.md` | Build tool only (`gba_recompile`) |
| mGBA 0.10.5 (oracle only) | MPL-2.0 | `oracle/README.md`, `third_party/README.md` | Only in the separate oracle binary. Never ship it. |
| NanoBoyAdvance | GPL-3.0 | `third_party/README.md` | Not available to us |
| recomp-ui | MIT | `UI@6374aae:LICENSE` | Only if we adopt the native launcher |
| Dear ImGui, stb, tinyfiledialogs (in recomp-ui) | MIT; MIT or public domain; zlib | `UI@6374aae:src/third_party/*` | Same |
| OpenMoji font / Noto Sans Symbols 2, flags (in recomp-ui) | CC BY-SA 4.0 / OFL-1.1 | `UI@6374aae:assets/common/{fonts,img}/NOTICE.md` | Same. The Lato fonts are not listed in `NOTICE.md` (**unverified**). |
| MKSC, MMZ | PolyForm NC 1.0.0 | their `LICENSE` | Only if we copy their code. Copied code stays noncommercial and needs attribution. |
| jellees/mksc decomp | No license file. MKSC uses it "only as a source of facts". | `MKSC@b89fbb4:README.md` | Not applicable |

**gbarecomp's LICENSE file is not the canonical PolyForm text.** We compared it with the canonical file at [polyformproject/polyform-licenses@1.0.0](https://github.com/polyformproject/polyform-licenses/blob/1.0.0/PolyForm-Noncommercial-1.0.0.md):

- It drops four sections: **Distribution License, Notices, Changes and New Works License, Patent License**.
- It rewrites "Copyright License" to cover distribution and changes in one paragraph.
- It adds an "intent" footer and a commercial-contact line.
- **No patent license is granted.** The kept "Patent Defense" section ends "your patent license for the software granted under these terms", but no section grants one. "No Other Rights" adds that the terms "do not imply any other licenses" (`GR@5e89943:LICENSE`). *(inferred, not legal advice)* Whether users of gbarecomp have any patent license is unclear. The owner should know this; we cannot settle it.

Which Emscripten libraries actually end up in `game.wasm` is **unverified** until we link a bundle. The rows above list what the SDK ships with its license file.

*(inferred, not legal advice)* The safe reading for our repo:

- Stay strictly noncommercial.
- Keep gbarecomp's `LICENSE` and `THIRD_PARTY_ATTRIBUTION.md` with any build we distribute.
- Keep the MPL-2.0 files' notices intact, and point recipients of any binary or bundle to the MPL-2.0 source of `bios_hle`.
- Ship the notices of the web toolchain libraries (MIT texts for Emscripten and musl) with any web bundle.
- Do not vendor gbarecomp source into our tree. Pin it as a submodule.
- License our own code separately. If it is a derivative of gbarecomp, it inherits the noncommercial restriction, as `docs/plan.md` already says. **Our repository has no `LICENSE` file yet** (`git ls-tree origin/main` lists only `.gitignore`, `CLAUDE.md`, `README.md` and two docs). See open question 7.

---

## 9. Recommended layout for our repository

Modeled on `MKSC`, with the Apple link fix from `BOK` and the web caveats above.

**Why not the `tools/cli.py` export.** gbarecomp's README documents `tools/cli.py build`, which exports a library project: `generated/`, copied framework headers, and its own `CMakeLists.txt` that builds `gbarecomp_game` (`tools/cli.py:75-199`). It is also the only input `build_web.sh` documents (`build_web.sh:2`). We still prefer the MKSC-style layout:

- `cli.py build` passes one `--config`, one `--symbols`, and no `--data-symbols` to the recompiler (`tools/cli.py:202-248, 258-266`). We will want config overlays and data names as the reverse engineering grows.
- The exported project has no place for game-owned code (`main.cpp` with `RunOptions`, hooks, enhancements), and every phase after Phase 1 needs some.
- The trade-off: we write our own web link step instead of using `build_web.sh` unchanged, and we track upstream changes to the export by hand.

**One generation path.** `tools/regen.sh` writes `generated/game` once, and both the native target and the web build compile that same directory. Running `cli.py` separately for the web would give a second corpus, generated with different flags, that can drift from the one the native strict gates proved. For the web:

- Day one: a small tracked `web/game-lib/CMakeLists.txt` builds `gbarecomp_game` from `generated/game`, and we hand it to `build_web.sh` (playbook, "Local web smoke test").
- Phase 3: our own target, configured with `emcmake`, linking our `main.cpp` with `gbarecomp_web_host_link_options()` (`cmake/web_host_link_options.cmake`) or through `gbarecomp_add_runtime_target()` (`cmake/runtime.cmake.in:56-148`).

```text
moto-racer-advanced-browser/
  gbarecomp/                  submodule: https://github.com/mstan/gbarecomp.git @ 5e89943…
                              init only external/arm-recomp-core (netplay and Android SDL not needed)
  CMakeLists.txt              native target; links with target_link_gbarecomp_runtime_stack();
                              -O1 -g0 on recompiled_*.cpp; GBARECOMP_GENERATED_BIOS_DIR=generated/bios
  game.toml                   reviewed base config; every array entry carries a `note` with its evidence
  baserom.md                  ROM identity (SHA-1, MD5, size, game code, header entry, save signature)
  src/main.cpp                RunOptions: builtin name/SHA-1, max_view_width, hooks
  src/mra_*.cpp               game-owned hooks and enhancements (later)
  symbols/                    our own small TSVs: addr<TAB>mode<TAB>name (no decomp exists)
  tests/*.input               gbarecomp-keyinput-v1 route traces (ROM-free, tracked); a '#' header
                              names the ROM SHA-1 and the initial save (playbook step 11)
  tests/*.cpp                 unit tests for game-owned code
  tools/regen.sh              hash gate + gba_recompile (--max-functions 65536)
  tools/verify-strict.sh      strict-static acceptance runs over tests/*.input
  web/game-lib/CMakeLists.txt game library over generated/game, for build_web.sh (day one)
  web/                        our own player shell and link step, when Phase 3 starts
  docs/
  roms/  bios/  generated/{bios,game}/  build/    ignored
```

- **Engine pin: keep `5e89943`.** It is gbarecomp's `main` HEAD as of 2026-10-10. The web host first appears at `4855ba2` (PR #16). Three first-parent commits carry it: `4855ba2`, `6283943` (PR #29) and `5e89943` (PR #31) (GitHub compare `4855ba2...5e89943`; `packaging/web/build_web.sh` is present at all three). PR #31 (commit `d606672`) changed one line of `CMakeLists.txt`, `set(GBARECOMP_SCANLINE_IMPLEMENTATION "LLE"` to `"HLE"`, so fresh builds now use the HLE scanline renderer. PR #29 had added that renderer as an opt-in. On 2026-10-09 the web host merged at 21:16 UTC, PR #29 at 21:24 and PR #31 at 21:40, so neither later change was part of PR #16's validation. The upstream evidence is byte-identical output on 128 synthetic frames covering modes 0–5 and 120-frame MKSC and MMZ checks, which "do not establish equivalence for every game or display state" (`docs/ENGINE_HLE_DMA.md:3-16`). `build_web.sh` does not set the option, so web builds get HLE too *(inferred from `build_web.sh:183-187`)*. *(inferred)* Configured with LLE, the pin should behave like the two earlier commits, because PR #29's other change, shared-RAM DMA batching, stays opt-in (`GBARECOMP_DMA_RAM_IMPLEMENTATION` defaults to LLE, `docs/ENGINE_HLE_DMA.md:24-26`). Recommendation: keep the pin, and keep a second native build configured with `-DGBARECOMP_SCANLINE_IMPLEMENTATION=LLE`. Compare frames between the two while the game's rendering modes are investigated, and switch to LLE when a bitmap-mode rendering bug needs ruling out. Bump deliberately, one commit at a time, and re-run the strict gates after each bump.
- **Native launcher:** start without recomp-ui. Pass `--bios`/`--rom` or set `[bios].path`/`[rom].path`. Add the launcher only if we ship native builds.
- **No box art.** MKSC's copyrighted `boxart.tga` should not be copied here.
- **CI:** adopt `BOK`'s pattern. A ROM-free job on `macos-14` and Linux builds the engine and runs `ctest -E "oracle|bios_intro_flawless"`. Later it can compile our game-owned sources with `-fsyntax-only`.
- **`.gitignore` safety net.** The playbook runs everything from `build/native/` and keeps the ROM under `roms/`, so its outputs already land in ignored paths. The cache, the coverage and miss files go in the working directory (`runtime.cpp:2034, 2105-2116`), `bios.cfg` and `rom.cfg` next to the executable (`asset_picker.cpp:184-185`), saves at `--save-path` (under `build/saves/` in the playbook) or else next to the ROM, and states next to the ROM. These entries guard against a run started from the repository root:
  - `recomp_cache/`
  - `recomp_coverage*.json`, `recomp_master_misses*.toml.frag`, `dispatch_misses.log`
  - `bios.cfg`, `rom.cfg`, `config.ini`, `keybinds.ini`
  - `saves/`, `diagnostics/`, `web-PRIVATE/`, `build-web-host/`
  - `*.state*` instead of `*.state`. The runtime writes `<rom>.state1` to `.state10`: slots 1–9 from the function keys, and slot 10 from the runtime menu or scripts (`runtime.cpp:3131-3143, 3370-3372`). `--state-dir` names them `state<N>`, with no extension, so keep any state directory under an ignored path.
  - `*.sav.tmp`. The save is written to `<save>.tmp` and then renamed (`runtime.cpp:1978-1989`), so a crash can leave the temporary file, which `*.sav` does not match.

  Saves default to the ROM path with a `.sav` extension (`runtime.cpp:1834-1838`), which lands under `roms/` and is already ignored.

---

## 10. Phase 1 playbook (macOS, day one)

Prerequisite: `roms/moto-racer-advance.gba` and `bios/gba_bios.bin` exist; the paths are already ignored.

Every command, flag and environment variable below exists at `GR@5e89943`, and mGBA's debugger commands at `MGBA@26b7884`. Only steps 3–4 were run for this study, using a scratch clone instead of a submodule. Steps 1–2 and 5–11 need the ROM or the BIOS, so what they produce is **expected from reading the code, not yet observed**. The same applies to the optional items at the end.

**1. Check the inputs.**

```sh
mkdir -p build/logs
shasum -a 1 bios/gba_bios.bin roms/moto-racer-advance.gba | tee build/logs/hashes.txt
md5 -q roms/moto-racer-advance.gba >> build/logs/hashes.txt
stat -f '%z %N' bios/gba_bios.bin roms/moto-racer-advance.gba >> build/logs/hashes.txt
```

Expected: BIOS `300c20df6731a33952ded8c436f7f186d25d3492`, 16384 bytes. Record the ROM SHA-1, MD5 and size in `baserom.md`; every later finding depends on them.

**2. Classify the race renderer in mGBA.** This decides how much work Phase 4 holds (§6.4). It needs no recompile and is already part of `docs/plan.md` Phase 1, so do it first. Start a race, pause, then advance frame by frame:

- **I/O register viewer:** the `DISPCNT` mode and enabled layers; the BG2/BG3 affine registers (`BG2PA`–`BG2PD`, `BG2X`, `BG2Y` and the BG3 set); the DMA control registers, looking for HBlank-timed transfers into those affine registers.
- **Tile, map and memory viewers:** whether tile or bitmap VRAM changes every frame, or only tilemaps and scroll values.
- **Debugger write watchpoints** on VRAM addresses: which code stores to them, and whether that code runs from ROM (`0x08…`) or RAM (`0x02…`/`0x03…`). mGBA 0.10.5's command-line debugger sets one watchpoint per address: `watch/w` fires on every write, `watch/c` only when the value changes (`MGBA@26b7884:src/debugger/cli-debugger.c:113-116, 640-667`). Whether they also fire on DMA writes is **unverified**. If VRAM changes but no CPU store hits, read the source address from the DMA registers.
- **RAM code that changes.** For each routine seen running from RAM, note its address range. After it has run once, put `watch/c` watchpoints on a few of its words, such as the first instruction and the literal pool, and keep playing through menus and several tracks. A hit means a different routine was copied over it (an overlay) or the copy was patched. Static recompilation cannot see either, and the coverage report stays `FULLY_STATIC` (§3.3). The DMA caveat above applies here too; playbook step 10 has a check that does not depend on it.

Record the mode, the per-frame VRAM write pattern, any per-scanline affine updates, and the RAM code ranges with any watchpoint hits in `docs/research/` with the ROM SHA-1. Classify by the pattern, not the mode number alone (§6.4). The writer PCs are also a first look at open question 4 in the findings doc, "how much code runs from RAM". The RAM code results are an input to ADR 0001.

**3. Get the engine at the pin.** Use a submodule, as in §9, or a scratch clone for pure investigation.

```sh
git submodule add https://github.com/mstan/gbarecomp.git gbarecomp
git -C gbarecomp checkout 5e89943528aee7bc1c399bdbd035364a4b41dd10
git -C gbarecomp submodule update --init external/arm-recomp-core
git add .gitmodules gbarecomp   # records the pinned gitlink; commit on a branch
```

Only `external/arm-recomp-core` is needed to build. The netplay submodules and the Android SDL fork can stay uninitialized. We checked this: a fresh clone at the pin with only that submodule configures, builds and passes 50/50 tests.

**4. Build and test the tools.**

```sh
cmake -S gbarecomp -B build/gbarecomp -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build/gbarecomp
ctest --test-dir build/gbarecomp
```

Expected: `100% tests passed out of 50`, as measured in §7. The binaries `build/gbarecomp/gba_recompile`, `gba_scan` and `bios_smoke` exist.

**5. Scan the header.**

```sh
build/gbarecomp/gba_scan roms/moto-racer-advance.gba | tee build/logs/gba_scan.txt
```

Produces `key=value` lines: `game_title`, `game_code`, `entry_target`, `complement_valid`, `logo_present`, `save_type`, `save_signature`, `save_signature_offset`, `ok=1`. This is the first answer to save type, open question 6 in the findings doc. Confirm it in mGBA.

**6. Recompile the BIOS** into our ignored tree.

```sh
build/gbarecomp/gba_recompile --bios bios/gba_bios.bin \
  --config gbarecomp/bios/gba_bios.toml --out generated/bios
```

Produces `generated/bios/bios_recompiled.{cpp,h}`, `bios_dispatch_table.cpp` and `bios_symbol_map.cpp`. The engine's own ignore file lists `bios_recompiled.{cpp,h}` and `bios_symbol_map.cpp` as BIOS-derived (`src/runtime/generated_bios/.gitignore`). It aborts if the BIOS hash differs from `gba_bios.toml`'s `[identity]`.

**7. Write `game.toml`** from steps 1 and 5. Leave `[save]` out until the type is confirmed; the runtime then uses signature detection.

```toml
# Moto Racer Advance (<region>, <game code>, revision <n>). Values from build/logs/.
[game]
name = "Moto Racer Advance"
short_name = "moto_racer_advance"

[program]
name = "Moto Racer Advance (<region>)"
id = "<game code>"
load_address = 0x08000000
size = 0x<ROM size in hex>
entry_pc = 0x08000000
speculative_literal_harvest = false
codegen_shards = 16

[identity]
sha1 = "<ROM SHA-1>"
md5 = "<ROM MD5>"

[bios]
path = "bios/gba_bios.bin"
sha1 = "300c20df6731a33952ded8c436f7f186d25d3492"
hle = false

[rom]
path = "roms/moto-racer-advance.gba"
sha1 = "<ROM SHA-1>"
```

**8. Recompile the ROM.** This is the only generation step. The native build and the web smoke test both compile its output (§9, "One generation path").

```sh
build/gbarecomp/gba_recompile --rom roms/moto-racer-advance.gba --config game.toml \
  --out generated/game --max-functions 65536 2>&1 | tee build/logs/recompile.log
```

Produces `generated/game/recompiled_000.cpp`…, `recompiled.h`, `dispatch_table.cpp` and `symbol_map.cpp`. The log carries the config summary and the `[gba_recompile discovery summary]` block (`TOTAL emitted`). Check that the total is well below 65536, because the cap is silent. Optional A/B: rerun with `speculative_literal_harvest = true` into another directory, to measure how much the heuristics find on their own.

**9. Minimal host.** `CMakeLists.txt`:

```cmake
cmake_minimum_required(VERSION 3.20)
project(MotoRacerAdvanceRecomp C CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(GBARECOMP_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/gbarecomp" CACHE PATH "gbarecomp checkout")
add_subdirectory("${GBARECOMP_ROOT}" gbarecomp_build EXCLUDE_FROM_ALL)
file(GLOB MRA_GENERATED CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/generated/game/*.cpp")
add_executable(MotoRacerAdvanceRecomp src/main.cpp ${MRA_GENERATED})
set(MRA_SHARDS ${MRA_GENERATED})
list(FILTER MRA_SHARDS INCLUDE REGEX "/recompiled_[0-9]+\\.cpp$")
set_source_files_properties(${MRA_SHARDS} PROPERTIES COMPILE_OPTIONS "-O1;-g0")
target_include_directories(MotoRacerAdvanceRecomp PRIVATE
    "${GBARECOMP_ROOT}/src/armv4t" "${GBARECOMP_ROOT}/src/gba"
    "${GBARECOMP_ROOT}/src/runtime" "${GBARECOMP_ROOT}/src/debug")
target_link_gbarecomp_runtime_stack(MotoRacerAdvanceRecomp)   # Apple-safe link
if(APPLE)
    # 16 MiB main-thread stack, like Windows and the web (§7.2).
    # Does not reach the game thread that --tcp creates.
    target_link_options(MotoRacerAdvanceRecomp PRIVATE "-Wl,-stack_size,0x1000000")
endif()
```

This sets no `GBARECOMP_WINDOW_TITLE` or `GBARECOMP_DEFAULT_GAME_CONFIG`. Only `runtime.cpp` reads them (`runtime.cpp:96-101, 141, 828, 2875`), and it is compiled into the `gbarecomp_runtime` library (`CMakeLists.txt:375-379`), so definitions on our executable never reach it. *(inferred)* The same holds for `MKSC`, which sets both on its executable (`MKSC@b89fbb4:CMakeLists.txt:84-87`), and for the engine's own `gbarecomp_add_runtime_target()` (`cmake/runtime.cmake.in:124-131`). The window title comes from `RunOptions::builtin_game_name` (`runtime.cpp:2873-2875`), and the default config name is already `game.toml`.

`src/main.cpp`, modeled on `MKSC@328b915:src/main.cpp`:

```cpp
#include "runtime.h"
int main(int argc, char** argv) {
    gbarecomp::RunOptions opts;
    opts.builtin_game_name = "Moto Racer Advance";
    opts.builtin_rom_sha1 = "<ROM SHA-1>";
    return gbarecomp::run_game(argc, argv, opts);
}
```

Configure and build. The configure output must contain `gbarecomp: BIOS recompiled output present — linking`.

```sh
cmake -S . -B build/native -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DGBARECOMP_GENERATED_BIOS_DIR="$PWD/generated/bios"
cmake --build build/native --target MotoRacerAdvanceRecomp
```

**10. First headless runs, from `build/native/`.** Three runs over the same 1800 frames:

- **10a. Coverage with the interpreter bridge, no healing.** The number to record.
- **10b. Strict.** Aborts at the first miss and prints its PC.
- **10c. Default.** Healing on; `c++` compiles overlays into `build/heal-cache/`.

Each run gets its own `--save-path` and starts with no save file there, so all three start from the same state and none touches `roms/moto-racer-advance.sav`. Each also names its own coverage and miss files. By default every run writes the same two files in the working directory, and the later runs would overwrite the first (`runtime.cpp:2105-2116`). Old fragments are deleted first, because a run with no misses leaves an existing one in place (§3.3). Run 10c points its heal cache at `build/heal-cache/` with `GBARECOMP_HEAL_CACHE` (`overlay_loader.cpp:455-460`). Under the default `recomp_cache/` in `build/native/`, any later run with healing on would load it warm, and the PCs it holds would never show up as misses again (§3.3).

```sh
cd build/native
mkdir -p ../saves
rm -f ../saves/smoke-bridge.sav ../saves/smoke-strict.sav ../saves/smoke-heal.sav
rm -f ../logs/smoke-bridge.toml.frag ../logs/smoke-strict.toml.frag ../logs/smoke-heal.toml.frag
GBARECOMP_SELFHEAL_RECOMPILE=0 \
GBARECOMP_COVERAGE_JSON=../logs/smoke-bridge.json GBARECOMP_MISS_FRAG=../logs/smoke-bridge.toml.frag \
./MotoRacerAdvanceRecomp --bios ../../bios/gba_bios.bin \
  --rom ../../roms/moto-racer-advance.gba --frames 1800 --no-window \
  --save-path ../saves/smoke-bridge.sav --dump-png ../logs/smoke-1800.png ../../game.toml \
  2>&1 | tee ../logs/smoke-bridge.log
GBARECOMP_STRICT_STATIC=1 GBARECOMP_SELFHEAL_RECOMPILE=0 \
GBARECOMP_COVERAGE_JSON=../logs/smoke-strict.json GBARECOMP_MISS_FRAG=../logs/smoke-strict.toml.frag \
./MotoRacerAdvanceRecomp --bios ../../bios/gba_bios.bin \
  --rom ../../roms/moto-racer-advance.gba --frames 1800 --no-window \
  --save-path ../saves/smoke-strict.sav ../../game.toml 2>&1 | tee ../logs/smoke-strict.log
GBARECOMP_HEAL_CACHE=../heal-cache \
GBARECOMP_COVERAGE_JSON=../logs/smoke-heal.json GBARECOMP_MISS_FRAG=../logs/smoke-heal.toml.frag \
./MotoRacerAdvanceRecomp --bios ../../bios/gba_bios.bin \
  --rom ../../roms/moto-racer-advance.gba --frames 1800 --no-window \
  --save-path ../saves/smoke-heal.sav ../../game.toml 2>&1 | tee ../logs/smoke-heal.log
```

Each run should print:

- `bios_loaded sha1=…`
- `rom_loaded sha1=… code=… entry=… save=… signature=…`
- `bios_backend=…`, and `scanline_backend=HLE (tile-span native-color composition)` (`LLE (per-pixel composition)` in an LLE build; `runtime.cpp:1589-1593`)
- `final_pc=… unmapped=… io_unhandled=… ppu_frames=1800 …`, `pal_nonzero=… vram_nonzero=…`
- a `self_heal_coverage=` line

Each run that reaches its last frame writes its coverage JSON, and its miss fragment only if it had at least one dispatch miss (§3.3). A strict run that aborts writes neither (§3.4). Record these in `docs/research/` with the ROM SHA-1:

- the coverage verdict
- the number of misses
- how many misses are in IWRAM (`0x03…`) or EWRAM (`0x02…`); this is open question 4 in the findings doc, "how much code runs from RAM"
- for each RAM miss, which of the three kinds in §3.3 it is. Two checks:
  - **Bytes.** Compare the whole live routine, up to its last instruction and its literal pool, with the ROM, not only the bytes at the PC. A full match at one ROM offset is a verbatim copy that `[[code_copy]]` or `source_addr` can cover. A partial match is a patched copy, and no match means generated code. Neither may get a `[[code_copy]]`, which would make the static body stale (§3.3). `GBARECOMP_MISS_IWRAM_DUMP=<path>` and `GBARECOMP_MISS_EWRAM_DUMP=<path>` save live RAM at the first IWRAM or EWRAM miss of the run (`runtime_arm_default_aborts.cpp:868-897`; `MMZ` sets the IWRAM one in every discovery session, `MMZ@218adfd:tools/play-discovery.ps1:101`). `GBARECOMP_IWRAM_DUMP=<path>` writes IWRAM at exit (`runtime.cpp:2129-2140`), and the TCP `read_ewram` command reads EWRAM. The comparison needs a small script we have not written yet.
  - **Stability.** A match at one moment does not rule out an overlay. Set `GBARECOMP_WRAM_TRACE=<path>` with `GBARECOMP_WRAM_TRACE_LO` and `_HI` around the routine's range. The runtime then writes one JSONL record per changed byte per frame, with the frame number (`runtime.cpp:2262-2323`). Any change after the routine first ran means an overlay or a patch. *(inferred from the code)* The trace compares memory once per frame, so it sees DMA writes too, but not a change that is undone within the same frame.
- `unmapped` and `io_unhandled`

**11. Play and record, then replay until the route is static.**

The trace holds input only. The runtime's comment says strict acceptance replays it "from the same initial SRAM" (`runtime.cpp:3212-3216`). But the runtime loads the save file at boot when it exists and writes it back during play and at exit (`runtime.cpp:1834-1844, 1961-1989`). Without `--save-path`, every run shares `roms/moto-racer-advance.sav`, and a replay would start from whatever earlier runs left there. Both reference repositories pin the initial save:

- `MMZ` snapshots it at the start of each discovery session and restores it before the strict replay (`MMZ@218adfd:tools/play-discovery.ps1:45-54`, `tools/verify-strict.ps1:47-51`, `-InitialSave`).
- `MKSC` deletes the save and passes a fresh `--save-path` on every strict run (`MKSC@b89fbb4:tools/test-attract-gameplay.ps1:39-40, 65`).

We start every route from no save file.

Discovery runs in bridge mode: healing off, so no heal cache can hide a miss, and named coverage and miss files (§3.3). `MMZ` records its discovery sessions the same way (`MMZ@218adfd:tools/play-discovery.ps1:92-100`). Each command deletes its fragment first, because a run with no misses leaves an old one in place.

**11a. Record** the route while playing:

```sh
rm -f ../saves/route-menu-race1.sav ../logs/route-menu-race1.record.toml.frag
GBARECOMP_SELFHEAL_RECOMPILE=0 GBARECOMP_INPUT_RECORD=../logs/route-menu-race1.input \
GBARECOMP_COVERAGE_JSON=../logs/route-menu-race1.record.json \
GBARECOMP_MISS_FRAG=../logs/route-menu-race1.record.toml.frag \
./MotoRacerAdvanceRecomp --window --save-path ../saves/route-menu-race1.sav \
  --bios ../../bios/gba_bios.bin --rom ../../roms/moto-racer-advance.gba ../../game.toml \
  2>&1 | tee ../logs/route-menu-race1.record.log
```

**11b. Fix and replay in bridge mode, until no miss is left.** Review the newest fragment, merge the real entries into `game.toml` with notes, regenerate (step 8) and rebuild (step 9). Then replay the trace with the same bridge settings. One run lists every miss that reaches dispatch on the route, not only the first:

```sh
rm -f ../saves/replay.sav ../logs/route-menu-race1.bridge.toml.frag
GBARECOMP_SELFHEAL_RECOMPILE=0 GBARECOMP_INPUT_REPLAY=../logs/route-menu-race1.input \
GBARECOMP_COVERAGE_JSON=../logs/route-menu-race1.bridge.json \
GBARECOMP_MISS_FRAG=../logs/route-menu-race1.bridge.toml.frag \
./MotoRacerAdvanceRecomp --no-window --frames <ppu_frames from the recording log> \
  --save-path ../saves/replay.sav \
  --bios ../../bios/gba_bios.bin --rom ../../roms/moto-racer-advance.gba ../../game.toml \
  2>&1 | tee ../logs/route-menu-race1.bridge.log
```

Repeat 11b until the replay writes no fragment and prints `self_heal_coverage=FULLY_STATIC`. Expect a few rounds. The bridge interprets a missed function and everything it calls until control returns to its caller (`runtime_arm_default_aborts.cpp:434, 464, 511-625`). A function reached only from inside that call tree never reaches dispatch, so it shows up as a miss once its caller is static. *(inferred)* The recompiler follows direct `BL` calls in the same instruction set (§3.1), so most such callees are found as soon as their caller is seeded. Computed calls and mode switches need another round.

**11c. Strict gate.**

```sh
rm -f ../saves/replay.sav
GBARECOMP_STRICT_STATIC=1 GBARECOMP_SELFHEAL_RECOMPILE=0 \
GBARECOMP_INPUT_REPLAY=../logs/route-menu-race1.input ./MotoRacerAdvanceRecomp --no-window \
  --frames <ppu_frames from the recording log> --save-path ../saves/replay.sav \
  --bios ../../bios/gba_bios.bin --rom ../../roms/moto-racer-advance.gba ../../game.toml \
  2>&1 | tee ../logs/route-menu-race1.strict.log
```

It must end in `self_heal_coverage=FULLY_STATIC dispatch_misses=0 interpreted_insns=0 healed_native=0`. A strict run stops at the first miss and writes no fragment and no coverage JSON (§3.4). If it fails, go back to 11b rather than fixing one PC per rebuild.

Avoid save-state loads while recording; replays do not capture them (`MMZ@218adfd:README.md`). Before copying a finished trace to `tests/`, name its initial save in a header. The replay reader skips lines that start with `#` (`runtime.cpp:3268`):

```text
# route: menu-race1
# rom_sha1: <ROM SHA-1>
# initial_save: none
```

*(inferred)* A route that needs progress, such as unlocked tracks or modes, should start from the final save of another tracked route, named in its header with that save's SHA-1. `tools/verify-strict.sh` would replay that route first to rebuild the save. Do not commit save files: `CLAUDE.md` forbids it, and `*.sav` is ignored. Keeping every initial save reproducible from tracked traces removes the need.

**Optional, once the steps above work:**

- **Rendering mode in the recompiled build**, to cross-check step 2. Run windowed with `--tcp-observe 19881`, play or replay a route into a race (`GBARECOMP_INPUT_REPLAY` also drives windowed runs, `runtime.cpp:3830-3834`), and send `{"cmd":"ppu_state"}`. It returns `dispcnt` and the BG registers (`src/debug/tcp_debug_server.cpp:924-945`). Do not use `--tcp` here: its game thread has only 512 KiB of stack on macOS (§7.2), and it ignores `GBARECOMP_INPUT_REPLAY` (§4). Driving the game to a race there would take hand-written `set_keyinput` or `run_frames` commands with a `keyinput` field.
- **LLE scanline build for comparison** (§9, "Engine pin"). Configure `build/native-lle` with the step 9 command plus `-DGBARECOMP_SCANLINE_IMPLEMENTATION=LLE`, replay the same route with `--dump-png` or `GBARECOMP_FRAMEDUMP_DIR` in both builds, and compare the frames.
- **Co-simulation.** Apply the one-line `creationflags` patch first; without it the script fails on macOS before starting anything (§7.2). Configure a second build directory with `-DGBA_COSIM=ON`, then run `python3 gbarecomp/oracle/gba_cosim.py --a recomp --b recomp …` with `GBA_COSIM_EXE/ROM/BIOS/CONFIG/CWD` set (`oracle/gba_cosim.py:1-40`). The script starts both runtimes with `--rom` and no `--save-path` (`oracle/gba_cosim.py:80-81`). *(inferred)* Both would then read and write the save next to the ROM (`runtime.cpp:1834-1838`), so point `GBA_COSIM_ROM` at a copy of the ROM in a scratch directory under `build/`.
- **Local web smoke test**, once Emscripten is installed. It compiles the same `generated/game` as the native build, through a small game-library project, instead of regenerating with `tools/cli.py` (§9). *(inferred, untested)* It relies only on what `build_web.sh` checks of a project: a `CMakeLists.txt` that contains `-mtail-call`, and a `gbarecomp_game` library in the game build directory (`build_web.sh:202-221`). Generated code includes only `<cstdint>`, `runtime_arm.h` and its own generated header (`tools/gba_recompile/main.cpp:568-569, 829-830`), hence the two include directories below. Never publish the output until the owner has decided (§5.6).

  `web/game-lib/CMakeLists.txt`:

  ```cmake
  cmake_minimum_required(VERSION 3.20)
  project(mra_game_lib CXX)
  set(MRA_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../..")
  file(GLOB MRA_GENERATED CONFIGURE_DEPENDS "${MRA_ROOT}/generated/game/*.cpp")
  add_library(gbarecomp_game STATIC ${MRA_GENERATED})
  set_target_properties(gbarecomp_game PROPERTIES CXX_STANDARD 20 CXX_STANDARD_REQUIRED YES)
  target_include_directories(gbarecomp_game PRIVATE
      "${MRA_ROOT}/generated/game" "${MRA_ROOT}/gbarecomp/src/armv4t")
  target_compile_options(gbarecomp_game PRIVATE -mtail-call)
  ```

  ```sh
  GBARECOMP_WEB_BUILD_DIR="$PWD/build/web-runtime" \
  GBARECOMP_WEB_GAME_BUILD_DIR="$PWD/build/web-game" \
  GBARECOMP_WEB_OUT_DIR="$PWD/build/web-out" \
  bash gbarecomp/packaging/web/build_web.sh web/game-lib generated/bios \
    roms/moto-racer-advance.gba "" game.toml
  python3 gbarecomp/packaging/web/serve.py build/web-out 8080
  ```

  The three directory variables keep every build product under `build/`, out of the submodule and out of `web/` (`build_web.sh:97-103`).

---

## Discrepancies with existing documents

For the orchestrator to reconcile. This PR does not edit those files.

- `docs/research/initial-findings.md`, gbarecomp "Targets":
  - "macOS and Linux are not documented" is outdated. `packaging/package_macos.sh`, `package_linux.sh` and a Flatpak path exist, macOS was verified by a contributor, and we built and tested the engine on our Mac (§7).
  - The claim that RAM-installed code "is compiled into a persistent native cache" holds for ROM PCs by default. RAM PCs need `GBARECOMP_RAM_OVERLAY_HEAL=1` (§3.3).
- Orchestrator brief, "No HLE": an opt-in SWI HLE with boot-skip exists (`[bios].hle`), but the BIOS dump is still required at runtime (§2.3).
- Orchestrator brief, "Generating C++ from a ROM does NOT need the BIOS": true for the game. A working LLE runtime and the web bundle also need the **recompiled BIOS**, which needs the dump at build time (§2.3, §5.2). `MKSC` README's "Generation requires … a retail GBA BIOS" blurs the two.
- Stale statements inside gbarecomp:
  - `docs/ARCHITECTURE.md` says BIOS code stays interpreted and `gba_recompile` is a stub.
  - `TCP.md` and `DEBUG.md` describe the ring, `rdb_*` and `debug.ini` (§4).
  - The `COSIM_ORACLE.md` status header.
  - `CLAUDE.md` names `recomp_seed_proposals.toml`.
  - `docs/WINDOWS_GAME_SETUP.md` says a game "may run without" a BIOS, but the runtime always resolves and loads one (`runtime.cpp:1385-1465`).
  - Its docs contradict each other on redistribution. `packaging/web/README.md:12`, `docs/WEB_ROM_BUILD.md:6` and `README.md:318-319` say a bundle can be published. `README.md:253-255` and `packaging/README.md:78-80` say generated code and binaries are not for redistribution (§5.6).
- `docs/plan.md` Phase 3 lists several items that gbarecomp's web host already provides (§5.4):
  - the ROM picker with SHA-1 check and IndexedDB storage, never uploaded
  - persistent saves in IDBFS
  - keyboard, gamepad and touch input
  - audio started by a user click
  - COOP/COEP serving

  The remaining Phase 3 work is our own link step for game hooks, a player-facing shell, and the hosting decision.
- `docs/plan.md` Phase 2 plans to record inputs in mGBA and replay them in the recompiled build. gbarecomp records and replays its own format, and drives the mGBA oracle over TCP. Replaying mGBA's own recordings needs a converter we do not have (§4).
- `docs/plan.md` Phase 1, "Measure how much code runs from RAM", should also ask whether that code changes after it is copied. Overlays and patched copies run stale static code that coverage reports cannot detect (§3.3).
- `docs/plan.md` Phase 4, "Resolution": gbarecomp has no internal-resolution path for affine backgrounds either, so that item is new engine-side work in both rendering cases (§6.4).

## Open questions

1. **Publishing a web bundle.** Every option except local builds distributes compiled code derived from the ROM, and gbarecomp's default bundle also contains code derived from Nintendo's BIOS. §5.6 compares four options with their legal exposure and technical cost. Recommendation: (a) local builds only through Phase 3. If the owner later wants a public page, (d), a bundle with an open-source BIOS, rather than (b), gbarecomp's default. The owner decides before Phase 3 hosting.
2. **The gbarecomp LICENSE text** differs from canonical PolyForm Noncommercial 1.0.0 and grants no patent license (§8). Does that matter for how we attribute or distribute? A question for the owner, not something to settle in code.
3. **Engine pin.** Recommendation: keep `5e89943`, gbarecomp's `main` HEAD on 2026-10-10. The web host first appears at `4855ba2`; three first-parent commits carry it, and no game repo has shipped on any of them. Waiting for a game repo to qualify one gains little, because our own strict-static gates are the qualification that matters for our ROM. The pin's one behavioral change since the web host, the HLE scanline renderer as the default (PR #31), is covered by a second build with `-DGBARECOMP_SCANLINE_IMPLEMENTATION=LLE` for frame comparison (§9).
4. **`.gitignore` additions** listed in §9. Who adds them, and when? They are a safety net, not a prerequisite: the playbook keeps runtime outputs under the already-ignored `build/` and `roms/`.
5. **Submodule or scratch clone for Phase 1?** The playbook works either way. The submodule commit fixes the pin in the repo history.
6. **Rendering mode** (case A or B in §6.4) decides how much enhancement work Phase 4 holds. It is now playbook step 2, measured in mGBA right after the ROM hash and before any recompile.
7. **License for our own code.** The repository has no `LICENSE` file (§8). *(inferred, general copyright default, not legal advice)* Until it has one, nobody else may reuse its contents. Options:
   - **PolyForm Noncommercial 1.0.0 for the whole repo**, using the canonical text. It matches gbarecomp and the code we may adapt from `MKSC` or `MMZ`, which must stay noncommercial anyway, and one license is simple to explain. Others cannot reuse even our standalone tools commercially.
   - **MIT (or similar) for original code and docs**, with a notice that builds link PolyForm NC code and that any code adapted from gbarecomp, `MKSC` or `MMZ` keeps their license. Our own tools and docs become freely reusable, at the cost of per-file license tracking.

   Recommendation: PolyForm Noncommercial 1.0.0 for everything, while most of our code is glue around gbarecomp. Revisit if we write tools that stand on their own. The owner decides.
8. **RAM code that changes** (§3.3). If the race code runs from RAM regions that receive overlays or patches, static recompilation gives no correctness guarantee there until we write a game-owned dispatch or force-interpreter hook, and the coverage report will not flag it. Playbook steps 2 and 10 measure it. The result belongs in ADR 0001 next to the rendering mode.

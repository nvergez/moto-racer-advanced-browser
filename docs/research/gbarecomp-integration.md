# gbarecomp integration study

**Date:** 2026-10-10
**Scope:** How a game is brought up on gbarecomp, read from the code of the framework and of two game repositories, so we can repeat it for Moto Racer Advance. No Moto Racer Advance ROM was used. Nothing here is verified against that ROM.

Conventions:

- *(inferred)* marks a conclusion drawn from reading code or docs, not observed by running it.
- **unverified** marks a claim we have not checked at all.
- Citations use `repo@sha:path:line`. Line numbers are valid at the cited commit only.

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

Machine used for the build check in §7: Apple M4 Pro, macOS 26.5.2, Apple clang 21.0.0 (`clang-2100.1.1.101`), Apple ld `ld-1267`, CMake 4.4.0, Ninja 1.13.2, Python 3.11.6, Node 24.14.0, Homebrew SDL2 2.32.10.

## Summary

1. **gbarecomp builds and passes its tests on our Mac.** At `GR`, configure + build + `ctest` finished in under 30 seconds of wall time, with **50/50 tests passing**, the browser JS unit tests among them (§7).
2. **None of the three game repositories we read can link on macOS as written** *(inferred: we did not build them)*. They pass `-Wl,--start-group` unconditionally, and Apple's linker rejects that flag (checked on this machine). gbarecomp's own `target_link_gbarecomp_runtime_stack()` handles this. Our repo must use it (§7, §9).
3. **The browser target is one day old at our pin.** It landed on `main` on 2026-10-09 (PR #16, merge `4855ba2`). Neither `MKSC` nor `MMZ` pins an engine that has it, so we would be the first game repo on it. The supported web flow links a generic `main()` and a CLI-exported library. Game-owned hooks such as MKSC's mods are **not** included unless we write our own web link step (§5).
4. **Legal: a "bring your own ROM" web bundle still contains the game's code.** `game.wasm` is compiled from the recompiled ROM and the recompiled BIOS. gbarecomp's docs contradict each other on whether such a bundle can be published. The owner must decide before Phase 3 hosting (§5.6, open questions).
5. **The BIOS dump is needed twice:** at build time, to recompile it (LLE path, and required by `build_web.sh`), and at runtime, where it is always loaded, even with the opt-in BIOS HLE. Generating the *game's* C++ does not need it (§2.3).
6. **MKSC's enhancements do not transfer to a software-rasterized 3D renderer.**
   - The 60 FPS mod overrides one Thumb immediate in an affine-background road renderer.
   - Adaptive Widescreen widens tile and affine background layers and moves HUD elements.
   - In bitmap modes 3/4/5, gbarecomp draws the widescreen margins as plain backdrop.
   - The framework has no internal-resolution upscaling and no CPU overclock.
   - If Moto Racer Advance draws its races in software into a bitmap mode (**unverified**), every enhancement needs a host-side renderer behind a `[[mod_function_hook]]`. That is new work (§6).
7. **`gba_recompile` stops discovering functions at 4096 by default, without saying so.** MKSC passes `--max-functions 65536` and discovers 13,717 to 20,815 functions, depending on whether decomp seeds are used. We must do the same (§3.1).
8. **Several debugging tools in `TCP.md` do not exist in the code at our pin.** These include the per-frame ring, `rdb_*`, and the `*_diff` commands. The coverage report, strict-static mode, input record/replay, save states, `state_hash` and the co-simulation engine do exist. The NanoBoyAdvance oracle binary is not in any public repo (§4).

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

Neither engine commit pinned by a game repo (`29efc02` for MKSC, `7c9a1eb` for MMZ and MC) contains `packaging/web/` (checked with `git cat-file -e`). Of the commits studied, only `GR` has the web host.

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

Inside the engine, BIOS-derived output is ignored. `GR@5e89943:src/runtime/generated_bios/.gitignore` says `bios_recompiled.cpp` "embeds Nintendo's BIOS bytes as instruction-by-instruction lowerings". `bios_dispatch_table.cpp` and `bios_dispatch_stub.cpp` are tracked.

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

  Paths resolve relative to the config file's directory. The value `TBD` counts as empty. MKSC's `[runtime] debug_port/window_title` are **ignored** by both readers. They only document the compile-time defines.
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
| `[rom].sha1` | **Required.** The runtime refuses to launch without it ("per-game TOML must set [rom].sha1"). | `runtime.cpp:1411-1420` |
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

- **The function cap is silent.** The default `--max-functions` is 4096 (`tools/gba_recompile/main.cpp:97`; `src/recompile/function_finder.h:227`). Past the cap, non-required seeds are skipped with `continue` and no warning (`src/recompile/function_finder.cpp:1952`). MKSC uses 65536 (`MKSC@b89fbb4:tools/regen.ps1:3`). MKSC discovers 13,717 functions without decomp seeds and 20,815 with them (`GR@5e89943:docs/SYMBOL_OVERLAY.md:6, 141-155`). MMZ's README reports 10,885.
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
3. Healing **RAM-resident** code is opt-in (`GBARECOMP_RAM_OVERLAY_HEAL=1`; `overlay_loader.cpp:90-93, 209-211`). *(inferred)* By default, code running from IWRAM/EWRAM that no `[[code_copy]]` covers stays on the interpreter. That matters if Moto Racer Advance runs its renderer from IWRAM (**unverified**).
4. At exit the runtime prints `self_heal_coverage=FULLY_STATIC …` or `self_heal_coverage=NOT_STATIC dispatch_misses=N interpreted_insns=… healed_native=…` (`src/runtime/runtime_arm_default_aborts.cpp:119-135`). It writes:
   - `recomp_master_misses_<CODE>.toml.frag`: proposed `[[extra_func]]` entries, with jump-table candidates flagged where several misses sit next to each other
   - `recomp_coverage_<CODE>.json`

   Both go in the working directory, and `GBARECOMP_MISS_FRAG` / `GBARECOMP_COVERAGE_JSON` override the paths (`runtime.cpp:2105-2116`). A run that was served from the heal cache is still reported `NOT_STATIC`.
5. A human reviews the fragment and merges the real entries into `game.toml`. No tool ever writes `game.toml`. Then regenerate and rebuild. (`GR@5e89943:CLAUDE.md` still mentions a `recomp_seed_proposals.toml`. No code at `GR` writes that file. The fragment is the actual output.)

Healing is on by default (`CMakeLists.txt:105`, `GBARECOMP_SELFHEAL_RECOMPILE_DEFAULT`). MKSC forces it on (`CMakeLists.txt:20`). `GBARECOMP_SELFHEAL_RECOMPILE=0` turns it off for one run.

### 3.4 Strict static mode

With `GBARECOMP_STRICT_STATIC=1`, cache loading, background healing and interpreter bridging are all off, and the first miss aborts (`overlay_loader.cpp:420-425`). A pass proves that the linked static corpus covered every PC that ran on that route.

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
| TCP debug server | **Implemented (subset)** | none | Enable with `--tcp <port>` (command-driven) or `--tcp-observe <port>` / `GBARECOMP_TCP_OBSERVE` (alongside a window) (`runtime.cpp:943-1000, 1649-1652`). Commands in `src/debug/tcp_debug_server.cpp`: `ping frame registers read_{iwram,ewram,vram,pal,oam,io} ppu_state audio_{state,samples,cap,trace} runtime_trace cyc_anchor irq_cap mmio_cap state_hash counters misses m4a_detect m4a_dump matrix_state symbol screenshot pause continue resume step step_inst step_to_vblank run_frames run_status set_keyinput set_break_pc savestate_save savestate_load fp_save quit`. Games can add commands through `RunOptions::tcp_command`. |
| Per-frame ring and reverse debugger (`history`, `get_frame`, `rdb_*`, `*_diff`) | **Documented, not implemented** | none | `TCP.md` and `DEBUG.md` describe them, but none of these command names occurs anywhere in `src/`, `tools/` or `oracle/`. `src/debug/trace_ring.h` is a stub. `debug.ini` is never read, and `GBARECOMP_DEFAULT_DEBUG_PORT` is defined but unused (`runtime.cpp:104-105`). |
| Opt-in traces | **Implemented** | none | `GBARECOMP_INSN_TRACE` + `GBARECOMP_FP_SAVE`, `GBARECOMP_MMIO_CAP` / `_DUMP`, `GBARECOMP_IRQ_LOG`, `GBARECOMP_SWI_LOG`, `GBARECOMP_RUNTIME_TRACE`, `GBARECOMP_AUDIO_FIFO_TRACE`, `GBARECOMP_WRAM_TRACE` (JSONL), `GBARECOMP_FRAMEDUMP_DIR`, `GBARECOMP_IWRAM_DUMP`, `GBARECOMP_HANG_WATCHDOG` (all found via `getenv` in `src/`) |
| `state_hash` | **Implemented** | none | FNV-1a-64 over IWRAM+EWRAM+VRAM+PAL+OAM and the cycle count (`tcp_debug_server.cpp:582-600`). It does not cover CPU or device state (`COSIM_ORACLE.md`). |
| Co-simulation (first divergence) | **Implemented, opt-in** | Python 3 | Build with `-DGBA_COSIM=ON`. Compares recomp against recomp, or against the in-tree interpreter (`GBARECOMP_FORCE_INTERP`), at cycle-stride checkpoints. Coordinator: `oracle/gba_cosim.py`, configured with `GBA_COSIM_EXE/ROM/BIOS/CONFIG/CWD`. The status line at the top of `COSIM_ORACLE.md` still reads "DESIGN … no engine code yet", but its own log records §1–§6 built on 2026-07-01, and `src/debug/cosim.cpp` has the engine. **Limit:** the interpreter shares `src/gba` with the recomp, so device-model bugs show up identically on both sides (`tools/gbaref/README.md`). |
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

1. Writes `runtime.toml` from the config and reads the expected ROM SHA-1 from `[rom].sha1`. The ROM argument is only hashed. The BIOS hash defaults to `300c20df…` (line 155).
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
- Web has no self-healing (`self_heal_recompile=UNAVAILABLE host=wasm interpreter_bridge=NOT_STATIC`, `overlay_loader.cpp:428-431`). The script's own comment says a web build "is only honest for a game whose coverage is FULLY STATIC" (`build_web.sh:37-39`). Every route has to pass strict-static on native first.

### 5.3 Hosting

`serve.py` sends `Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Embedder-Policy: require-corp` and `Cache-Control: no-store`, and serves `.wasm` as `application/wasm` (`packaging/web/serve.py:16-25`). The README says any static host works if it sends the two COOP/COEP headers over https, or from localhost. *(inferred, general web-platform knowledge, not from gbarecomp)* Hosts that cannot set custom response headers, such as plain GitHub Pages, would need a workaround. **unverified** for any specific host.

### 5.4 Player experience (`packaging/web/index.html`, `README.md`)

- "Choose ROM…" and "Choose BIOS…" buttons. The ROM is checked against the bundle's SHA-1. A wrong ROM is refused with both hashes, and a 16 KiB file offered as the ROM is recognised as a BIOS.
- Both files stay in that browser's IndexedDB. "Forget ROM/BIOS" removes them. Without IndexedDB (some private windows), they last for the page only.
- Start/Pause/Fullscreen/Enable audio. The audio context needs a real click.
- Volume, filter (Nearest/Linear/Sharp), 9 save-state slots, export/import/restore of battery saves, and a log area. `?autostart=1` starts as soon as stored files are present.
- Rendering uses WebGL from a shared triple buffer. Keyboard bindings follow the native defaults. `navigator.getGamepads()` and an on-screen touch pad are supported (`host_web.js:80-88, 239, 449`). Saves go to IDBFS under `/saves/<ROM SHA-1>/`.
- Missing on web: the in-game settings menu, overlay text, sensors (PR #16 description, mstan/gbarecomp#16).
- The page is a developer-style shell. Its title is "gbarecomp web" and it uses a monospace log layout. *(inferred)* We will want our own shell for players.

### 5.5 Maturity

- PR #16 ("WebAssembly browser host and guaranteed tail transfers", merge `4855ba2`, committed 2026-10-09) is the whole web host. The PR body says: "Not tested on real phones/tablets"; MMZ's web run hit a dispatch miss in IWRAM.
- Bring-your-own-ROM followed in `b49bb86` (2026-09-25 on its branch).
- The Node unit tests for the web host (`web_*_tests`) pass on this machine (§7). No browser build was done for this study, because Emscripten was not installed yet.

### 5.6 What the "ROM-free" bundle still contains

`game.wasm` links `libgbarecomp_game.a`, which is compiled from the recompiled ROM. It also links `libgbarecomp_runtime.a`, which includes `bios_recompiled.cpp` (`build_web.sh:212-222`; `CMakeLists.txt:418-449`). gbarecomp's own documents disagree about whether that can be published:

- `GR@5e89943:packaging/web/README.md:12`: a bundle "contains only code and settings and can be published". `docs/WEB_ROM_BUILD.md:6` repeats it: "A normal bundle is therefore safe to publish."
- `GR@5e89943:packaging/README.md:78-80`: "A recompiled binary already embeds translated ROM code, so these scripts are for building **your own** copy from **your own** dump — not for redistribution."
- `GR@5e89943:src/runtime/generated_bios/.gitignore`: the BIOS lowering "embeds Nintendo's BIOS bytes".

Our `CLAUDE.md` bans committing generated code. It does not cover publishing a compiled bundle. That needs a decision from the owner; see the open questions.

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
- **Origin.** The patch research is antimattur's (`MKSC` README and manifest), which drew on the decomp. *(inferred from the `game.toml` comment)* The road parameters were already computed every frame; only the buffer DMA0 reads was refreshed at 30 Hz.

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
| Wide PPU surface up to 896×160 (`gba_ppu.h:120-137`). Live resize policy. Provider seams. | Which scenes are wide, the HUD rectangles, sprite identification |
| `[[thumb_alu_immediate_override]]` codegen and runtime hook | The address, the override value, when to enable |
| Mod loader: `.gbamod` ZIPs hold data and manifests only. Checks ROM SHA-1, feature dependencies and plugin IDs before activation. Mods page in recomp-ui. (`docs/MOD_PACKAGES.md`) | Trusted plugins, statically linked and registered by ID; built-in manifests |
| `[[mod_function_hook]]`: replace a reviewed guest function entry with a native callback that writes the post-call CPU state, including R15 (`docs/MOD_PACKAGES.md`, "Trusted function-entry hooks") | (not used by MKSC) |
| `RunOptions::extended_view_frame`, `host_overlay` (2D lines, rects, circles, text; no textures; `src/runtime/host_overlay.h`), `g_ws_obj_margin_provider`, `gba_mod_publish_foreign_background` (240×160 BGR555) | Their use |

### 6.4 Transferability to Moto Racer Advance

How the game draws its races is **unverified**. It is the first Phase 1 question. Two cases:

**Case A: affine or tiled backgrounds, like MKSC** (`DISPCNT` mode 1 or 2 during races). Most of MKSC's approach transfers *(inferred)*:

- The affine road extends into the margins for free.
- HUD layers can be moved with the same providers.
- If the game double-buffers per-scanline affine tables the way MKSC does, a similar one-instruction override might raise the visible frame rate. Finding the instruction requires our own reverse engineering, since no decomp exists.

**Case B: software-drawn 3D in a bitmap mode** (`DISPCNT` mode 4 or 5). Little transfers, and the framework lacks several pieces:

- **Widescreen.** In bitmap modes the wide renderer draws the margins as backdrop: "A bitmap has a fixed width … the margins fall outside its bounds, staying backdrop" (`GR@5e89943:src/gba/gba_ppu.cpp:1794-1799`). The game's rasterizer only fills a 240-wide (mode 4) or 160×128 (mode 5) page in VRAM, so there is nothing to reveal. A wider view needs the camera to project wider and a renderer that draws into a host-side buffer wider than VRAM.
- **Resolution.** No internal-resolution or upscaling path exists. Presentation filters only: sharp, linear, affine filter, colour profiles. `host_overlay` cannot draw textured triangles.
- **Frame rate.**
  - Generated code charges guest cycles per instruction (`COSIM_ORACLE.md`, "shared alignment clock"). *(inferred)* A CPU-bound software renderer therefore keeps the frame rate it has on hardware.
  - There is no overclock or cycle-scaling option. A search for `overclock`, `cycle_scale` and similar terms finds only the host fast-forward ("Turbo") key, which speeds up everything, game logic included.
  - Raising the frame rate needs either a new cycle-discount feature, which changes timing and is risky for game logic tied to frame counts, or a native renderer that costs no guest cycles.
- **Likely path for case B** *(inferred)*:
  1. Find the rasterizer entry points with mGBA's debugger and Ghidra.
  2. Declare them as `[[mod_function_hook]]`.
  3. Implement the callback in game-owned C++: read the guest's transformed geometry, draw it natively (into VRAM first, to stay pixel-identical, then into a host buffer at higher resolution or wider), and return through R15.
  4. Write a WebGL presentation path in the web host for the high-resolution buffer. The current host only displays the 240×160 (or wider) RGB frame.

  All of this is new work in our repo, and possibly upstream. MKSC's 49-line plugin is not a model for its size.
- **Watchdog false positive.** Per mstan/gbarecomp PR #2 (bitmap modes), a software rasterizer "legitimately never HALTs", and the hang watchdog can mistake that for a busy-spin. The watchdog is opt-in (`GBARECOMP_HANG_WATCHDOG=1`, `runtime_bus_bridge.cpp:1100-1104`).
- **Bitmap modes are young.** They were added in July 2026 (PR #2, merge `80725f9`). Only mode 4 was exercised then, by Boktai's intro; "Modes 3 and 5 are untested". The later scanline-HLE comparison covered modes 0–5 on synthetic frames (`docs/ENGINE_HLE_DMA.md:10-16`).

---

## 7. Platform support and macOS arm64

### 7.1 Evidence

| Evidence | What it shows |
|---|---|
| Our build, 2026-10-10 | `GR@5e89943` configures with `cmake -S gbarecomp -B build -G Ninja -DCMAKE_BUILD_TYPE=Release`: SDL2 found at `/opt/homebrew`, toml++ fetched, BIOS placeholder used. All 186 build steps succeed (141 lines containing `warning:`, mostly `-Wmismatched-tags`; no errors). `ctest`: **100% tests passed out of 50**, including `codegen_tests`, `heal_gate_tests`, `ppu_smoke_tests` and all 12 `web_*` tests (Node, Python and one C++). Wall time: configure 8 s, build 7 s, test 10 s. |
| `GR` commit `f4a065e` (2026-07-28) | mGBA oracle builds on macOS arm64 ("M4, macOS 26, AppleClang 21") |
| `GR` commit `b75bb63` (2026-07-29) | Self-heal fixed for macOS and Linux: compiler path, linker flags, `dlopen` loader. Measured on Boktai. |
| `GR` commits `7451315`, `1166f7e` (2026-07-30) | Link-group gating by linker type (`APPLE OR msvc` gets a plain list); the BIOS `_start` symbol renamed for ELF. "19/19 engine suites pass on macOS." |
| `GR` commit `4cabc7d` + `packaging/package_macos.sh` | Portable macOS package. "verified booting a real ROM for 30 frames" (Boktai) |
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
| NanoBoyAdvance oracle | Private | Use the mGBA oracle and co-sim instead |
| Netplay (`GBARECOMP_NETPLAY`, off by default in the engine; MKSC turns it on) | `cmake/GbaNetplay.cmake:1`; `MKSC@b89fbb4:CMakeLists.txt:7-12` | Keep it off. Untested on macOS by us. |
| Main-thread stack size | Windows builds reserve 16 MiB (`CMakeLists.txt:332-372`). Nothing does the same for macOS. **unverified** whether deep guest call chains overflow the default 8 MiB main-thread stack. | If it crashes, add `-Wl,-stack_size,0x1000000` |
| Self-heal compiler | Uses `c++` (Apple clang) through `PATH`. `gcc_toolchain_available()` probes `g++`/`gcc`/`cc`/`clang` (`overlay_loader.cpp:131-165`). | Works per `b75bb63`. Disable it for strict runs. |

---

## 8. Licensing

| Component | License | Source | Applies to us when |
|---|---|---|---|
| gbarecomp | "PolyForm Noncommercial License 1.0.0", Copyright (c) 2026 Matthew Stanley | `GR@5e89943:LICENSE` | Always: native build, web build, any derived code |
| gbarecomp `src/runtime/bios_hle.{h,cpp}` | **MPL-2.0** (derived from mGBA `src/gba/bios.c`) | `GR@5e89943:THIRD_PARTY_ATTRIBUTION.md`, `third_party/MPL-2.0.txt` | Compiled into every runtime. File-scoped copyleft: changes to those two files stay MPL-2.0 and must remain available as source. |
| Ported files (`gba_m4a`, `color_lut`, `gba_rtc`, `audio_shadow`, `mp2k_shadow`) | MIT OR Apache-2.0 (from JRickey/gba-recomp) | `THIRD_PARTY_ATTRIBUTION.md` | Always. Keep the attribution headers. |
| arm-recomp-core | MIT, Copyright (c) 2026 Matthew Stanley | `ARC@1f13cdf:LICENSE`, `PROVENANCE.md` | Always |
| recomp-net | MIT | `RNET@c58f125:LICENSE` | Only with `GBARECOMP_NETPLAY=ON` |
| libjuice v1.7.2, fetched by recomp-net | MPL-2.0 per its upstream, **unverified** here | `RNET@c58f125:CMakeLists.txt:144-155` | Only with netplay |
| rbengine | MIT | `RBE@2a03e73:LICENSE` | Only with netplay |
| SDL (mstan fork, 2.32.10) | zlib | `SDL@8e28503:LICENSE.txt` | Native builds and Android. Not used on web. |
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

*(inferred, not legal advice)* The safe reading for our repo:

- Stay strictly noncommercial.
- Keep gbarecomp's `LICENSE` and `THIRD_PARTY_ATTRIBUTION.md` with any build we distribute.
- Keep the MPL-2.0 files' notices intact.
- Do not vendor gbarecomp source into our tree. Pin it as a submodule.
- License our own code separately. If it is a derivative of gbarecomp, it inherits the noncommercial restriction, as `docs/plan.md` already says.

---

## 9. Recommended layout for our repository

Modeled on `MKSC`, with the Apple link fix from `BOK` and the web caveats above.

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
  tests/*.input               gbarecomp-keyinput-v1 route traces (ROM-free, tracked)
  tests/*.cpp                 unit tests for game-owned code
  tools/regen.sh              hash gate + gba_recompile (--max-functions 65536)
  tools/verify-strict.sh      strict-static acceptance runs over tests/*.input
  web/                        our own player shell and link step, when Phase 3 starts
  docs/
  roms/  bios/  generated/{bios,game}/  build/    ignored
```

- **Engine pin:** `5e89943` is the only commit with the web host. Bump deliberately, one commit at a time, and re-run the strict gates after each bump.
- **Native launcher:** start without recomp-ui. Pass `--bios`/`--rom` or set `[bios].path`/`[rom].path`. Add the launcher only if we ship native builds.
- **No box art.** MKSC's copyrighted `boxart.tga` should not be copied here.
- **CI:** adopt `BOK`'s pattern. A ROM-free job on `macos-14` and Linux builds the engine and runs `ctest -E "oracle|bios_intro_flawless"`. Later it can compile our game-owned sources with `-fsyntax-only`.
- **`.gitignore` gaps.** Ours lacks entries the runtime will write:
  - `recomp_cache/`
  - `recomp_coverage*.json`, `recomp_master_misses*.toml.frag`, `dispatch_misses.log`
  - `bios.cfg`, `rom.cfg`, `config.ini`, `keybinds.ini`
  - `saves/`, `diagnostics/`, `web-PRIVATE/`, `build-web-host/`

  Its `*.state` pattern does not match the runtime's `<rom>.state1`–`.state9` files (`runtime.cpp:3137-3143`). That needs `*.state[0-9]`. Saves default to the ROM path with a `.sav` extension (`runtime.cpp:1836`), which lands under `roms/` and is already ignored.

---

## 10. Phase 1 playbook (macOS, day one)

Prerequisite: `roms/moto-racer-advance.gba` and `bios/gba_bios.bin` exist; the paths are already ignored.

Every command and flag below exists at `GR@5e89943`. Only steps 2–3 were run for this study, using a scratch clone instead of a submodule. Step 1 and steps 4–10 need the ROM or the BIOS, so what they produce is **expected from reading the code, not yet observed**. The same applies to the optional items at the end.

**1. Check the inputs.**

```sh
mkdir -p build/logs
shasum -a 1 bios/gba_bios.bin roms/moto-racer-advance.gba | tee build/logs/hashes.txt
md5 -q roms/moto-racer-advance.gba >> build/logs/hashes.txt
stat -f '%z %N' bios/gba_bios.bin roms/moto-racer-advance.gba >> build/logs/hashes.txt
```

Expected: BIOS `300c20df6731a33952ded8c436f7f186d25d3492`, 16384 bytes. Record the ROM SHA-1, MD5 and size in `baserom.md`; every later finding depends on them.

**2. Get the engine at the pin.** Use a submodule, as in §9, or a scratch clone for pure investigation.

```sh
git submodule add https://github.com/mstan/gbarecomp.git gbarecomp
git -C gbarecomp checkout 5e89943528aee7bc1c399bdbd035364a4b41dd10
git -C gbarecomp submodule update --init external/arm-recomp-core
git add .gitmodules gbarecomp   # records the pinned gitlink; commit on a branch
```

Only `external/arm-recomp-core` is needed to build. The netplay submodules and the Android SDL fork can stay uninitialized. We checked this: a fresh clone at the pin with only that submodule configures, builds and passes 50/50 tests.

**3. Build and test the tools.**

```sh
cmake -S gbarecomp -B build/gbarecomp -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build/gbarecomp
ctest --test-dir build/gbarecomp
```

Expected: `100% tests passed out of 50`, as measured in §7. The binaries `build/gbarecomp/gba_recompile`, `gba_scan` and `bios_smoke` exist.

**4. Scan the header.**

```sh
build/gbarecomp/gba_scan roms/moto-racer-advance.gba | tee build/logs/gba_scan.txt
```

Produces `key=value` lines: `game_title`, `game_code`, `entry_target`, `complement_valid`, `logo_present`, `save_type`, `save_signature`, `save_signature_offset`, `ok=1`. This is the first answer to save type, open question 6 in the findings doc. Confirm it in mGBA.

**5. Recompile the BIOS** into our ignored tree.

```sh
build/gbarecomp/gba_recompile --bios bios/gba_bios.bin \
  --config gbarecomp/bios/gba_bios.toml --out generated/bios
```

Produces `generated/bios/bios_recompiled.{cpp,h}` and `bios_dispatch_table.cpp`. It aborts if the BIOS hash differs from `gba_bios.toml`'s `[identity]`.

**6. Write `game.toml`** from steps 1 and 4. Leave `[save]` out until the type is confirmed; the runtime then uses signature detection.

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

**7. Recompile the ROM.**

```sh
build/gbarecomp/gba_recompile --rom roms/moto-racer-advance.gba --config game.toml \
  --out generated/game --max-functions 65536 2>&1 | tee build/logs/recompile.log
```

Produces `generated/game/recompiled_000.cpp`…, `recompiled.h`, `dispatch_table.cpp` and `symbol_map.cpp`. The log carries the config summary and the `[gba_recompile discovery summary]` block (`TOTAL emitted`). Check that the total is well below 65536, because the cap is silent. Optional A/B: rerun with `speculative_literal_harvest = true` into another directory, to measure how much the heuristics find on their own.

**8. Minimal host.** `CMakeLists.txt`:

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
target_compile_definitions(MotoRacerAdvanceRecomp PRIVATE
    GBARECOMP_WINDOW_TITLE="MotoRacerAdvanceRecomp"
    GBARECOMP_DEFAULT_GAME_CONFIG="game.toml")
```

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

**9. First headless runs, from `build/native/`.** Three runs over the same 1800 frames:

- **9a. Coverage with the interpreter bridge, no healing.** The number to record.
- **9b. Strict.** Aborts at the first miss and prints its PC.
- **9c. Default.** Healing on; `c++` compiles overlays into `recomp_cache/`.

```sh
cd build/native
GBARECOMP_SELFHEAL_RECOMPILE=0 ./MotoRacerAdvanceRecomp --bios ../../bios/gba_bios.bin \
  --rom ../../roms/moto-racer-advance.gba --frames 1800 --no-window \
  --save-path ../saves/smoke.sav --dump-png ../logs/smoke-1800.png ../../game.toml \
  2>&1 | tee ../logs/smoke-bridge.log
GBARECOMP_STRICT_STATIC=1 GBARECOMP_SELFHEAL_RECOMPILE=0 ./MotoRacerAdvanceRecomp \
  --bios ../../bios/gba_bios.bin --rom ../../roms/moto-racer-advance.gba --frames 1800 \
  --no-window ../../game.toml 2>&1 | tee ../logs/smoke-strict.log
./MotoRacerAdvanceRecomp --bios ../../bios/gba_bios.bin --rom ../../roms/moto-racer-advance.gba \
  --frames 1800 --no-window ../../game.toml 2>&1 | tee ../logs/smoke-heal.log
```

Each run should print:

- `bios_loaded sha1=…`
- `rom_loaded sha1=… code=… entry=… save=… signature=…`
- `bios_backend=…`, `scanline_backend=HLE …`
- `final_pc=… unmapped=… io_unhandled=… ppu_frames=1800 …`, `pal_nonzero=… vram_nonzero=…`
- a `self_heal_coverage=` line

Each run also writes `recomp_master_misses_<CODE>.toml.frag` and `recomp_coverage_<CODE>.json` in `build/native/`. Record these in `docs/research/` with the ROM SHA-1:

- the coverage verdict
- the number of misses
- how many misses are in IWRAM/EWRAM; this is open question 4 in the findings doc, "how much code runs from RAM"
- `unmapped` and `io_unhandled`

**10. Play and record, then replay strictly.**

```sh
GBARECOMP_INPUT_RECORD=../logs/route-menu-race1.input ./MotoRacerAdvanceRecomp --window \
  --bios ../../bios/gba_bios.bin --rom ../../roms/moto-racer-advance.gba ../../game.toml
# review the .frag, merge real entries into game.toml with notes, regenerate (step 7), rebuild (step 8), then:
GBARECOMP_STRICT_STATIC=1 GBARECOMP_SELFHEAL_RECOMPILE=0 \
GBARECOMP_INPUT_REPLAY=../logs/route-menu-race1.input ./MotoRacerAdvanceRecomp --no-window \
  --frames <frames recorded> --bios ../../bios/gba_bios.bin \
  --rom ../../roms/moto-racer-advance.gba ../../game.toml
```

Repeat until the strict replay ends in `self_heal_coverage=FULLY_STATIC dispatch_misses=0 interpreted_insns=0 healed_native=0`.

Avoid save-state loads while recording; replays do not capture them (`MMZ@218adfd:README.md`). Copy finished traces to `tests/`.

**Not day one, but cheap once the steps above work:**

- **Rendering mode in the recompiled build.** Run with `--tcp 19880`, send `{"cmd":"run_frames","n":3600}` then `{"cmd":"ppu_state"}`, and read `dispcnt`. Cross-check with mGBA's I/O viewer during a race.
- **Co-simulation.** Configure a second build directory with `-DGBA_COSIM=ON`, then run `python3 gbarecomp/oracle/gba_cosim.py --a recomp --b recomp …` with `GBA_COSIM_EXE/ROM/BIOS/CONFIG/CWD` set (`oracle/gba_cosim.py:1-40`).
- **Local web smoke test**, once Emscripten is installed. Pass `--max-functions` explicitly to `cli.py`, and keep the runtime build dir out of the submodule. Never publish the output until the owner has decided (§5.6).

  ```sh
  GBARECOMP_CORE="$PWD/build/gbarecomp/gba_recompile" python3 gbarecomp/tools/cli.py build \
    --rom roms/moto-racer-advance.gba --output build/mra-export --config game.toml \
    --max-functions 65536 --force
  GBARECOMP_WEB_BUILD_DIR="$PWD/build/web-runtime" bash gbarecomp/packaging/web/build_web.sh \
    build/mra-export generated/bios roms/moto-racer-advance.gba "" game.toml
  python3 gbarecomp/packaging/web/serve.py build/mra-export/web 8080
  ```

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
  - The two packaging READMEs contradict each other on redistribution (§5.6).
- `docs/plan.md` Phase 3 lists several items that gbarecomp's web host already provides (§5.4):
  - the ROM picker with SHA-1 check and IndexedDB storage, never uploaded
  - persistent saves in IDBFS
  - keyboard, gamepad and touch input
  - audio started by a user click
  - COOP/COEP serving

  The remaining Phase 3 work is our own link step for game hooks, a player-facing shell, and the hosting decision.
- `docs/plan.md` Phase 2 plans to record inputs in mGBA and replay them in the recompiled build. gbarecomp records and replays its own format, and drives the mGBA oracle over TCP. Replaying mGBA's own recordings needs a converter we do not have (§4).

## Open questions

1. **Publishing a web bundle** means distributing compiled code derived from the ROM and from Nintendo's BIOS (§5.6). Do we publish, or only document how players build it locally? This decides the Phase 3 hosting plan.
2. **The gbarecomp LICENSE text** differs from canonical PolyForm Noncommercial 1.0.0 (§8). Does that matter for how we attribute or distribute? A question for the owner, not something to settle in code.
3. **Engine pin.** `5e89943` is the first commit with the web host, and no game repo has shipped on it yet. Accept being first, or wait for a game repo to qualify a later commit?
4. **`.gitignore` additions** listed in §9. Who adds them, and when? They should land before the first runtime run (playbook step 9).
5. **Submodule or scratch clone for Phase 1?** The playbook works either way. The submodule commit fixes the pin in the repo history.
6. **Rendering mode** (case A or B in §6.4) decides how much enhancement work Phase 4 holds. It should be the first measurement made once the ROM is available.

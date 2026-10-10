# Replacing the Nintendo BIOS with an open-source one

**Date:** 2026-10-10 (revised after two review rounds the same day)
**Question:** Can our build avoid the Nintendo GBA BIOS by shipping an open-source replacement, so a player only needs their ROM? What does it cost in work, licensing and fidelity?
**Status:** Research plus scratch experiments (recompiling an open BIOS with gbarecomp, small scripts over the BIOS images and sources, and a read of a third-party 2022 A/B report). Nothing here has been run against the Moto Racer Advance ROM by us. This is engineering analysis, not legal advice.

Pinned sources (all paths and line numbers below refer to these commits):

| Project | Commit |
|---|---|
| [mstan/gbarecomp](https://github.com/mstan/gbarecomp) | `5e89943528aee7bc1c399bdbd035364a4b41dd10` |
| [Cult-of-GBA/BIOS](https://github.com/Cult-of-GBA/BIOS) | `a30e9a96df083628b650724b7d4d7112b4070b98` |
| [coolbho3k/emibios](https://github.com/coolbho3k/emibios) | `c4d5d7113ccbb56af5bf73839bf1c51f67936362` (2026-10-10). This is newer than release 0.1.6, and every emibios fact in this doc describes this commit, not the release ([§4 Option B](#option-b-notes-emibios)) |
| [Nebuleon/ReGBA](https://github.com/Nebuleon/ReGBA) (hosts Normmatt's BIOS) | `7f379052dc14366e622a96c7cf7fb6b5a7e918a3` |
| [mgba-emu/mgba](https://github.com/mgba-emu/mgba) | `143adf5aa2a60c6036810b0cd72445e13d74b0e6` |

## Verdict

**Feasible with caveats.** We can build with the [Cult-of-GBA BIOS](https://github.com/Cult-of-GBA/BIOS) (MIT), recompiled by gbarecomp like the Nintendo BIOS. Players would then pick only their ROM. Before we publish anything built with it, its retail-derived parts need replacing or an explicit decision.

- **No changes to gbarecomp's source.** The expected BIOS hash is a config value, `gba_recompile` accepts our own BIOS config, and the runtime links whatever generated BIOS directory we point it at. In a scratch build, a short config gave dispatch entries for every SWI entry point, CpuSet's internal table, and the IRQ handler's return point. The first draft of that config missed the return point, so every IRQ would have missed the dispatch table ([§3](#3-experiment-recompiling-the-cult-of-gba-bios)). The runtime library compiled against the result. We won't call the coverage complete until a `GBARECOMP_STRICT_STATIC` run on the ROM shows no BIOS dispatch misses.
- **It doesn't fully solve the legal problem.** gbarecomp's default browser bundle compiles a translation of Nintendo's BIOS into `game.wasm`, even though it asks players for their own BIOS file ([§2.2](#22-how-the-bios-is-recompiled)). Cult-of-GBA isn't Nintendo's image. But its source comments say several of its routines and tables were decompiled or copied from the retail BIOS ([§1](#cult-of-gba-bios)). `gba_recompile` compiles every SWI-table target into `game.wasm` whether or not the game calls it, and option A also ships `bios.bin` itself. Those parts would ship too. Mitigation: a small pinned repository of our own, started without upstream history, that regenerates the tables from formulas and rewrites the derived routines (option A′, [§4](#4-options-for-our-build)). The alternative is an explicit owner decision to accept the risk after review.
- **Main cost: fidelity.** The open BIOS computes the same things differently, with different cycle counts and some different results. One difference hits a SWI on the game's preliminary list: Cult-of-GBA's DivArm gives the remainder (r1) the wrong sign when the divisor is negative. Third-party data from 2022 (mGBA with dummy inputs) recorded the game calling only five SWIs: VBlankIntrWait, DivArm, CpuFastSet, LZ77UnCompWram and RLUnCompWram. The same author's A/B run reached the race start under an older Cult-of-GBA build, with no crash and no visible breakage compared with the retail BIOS ([§1](#cult-of-gba-bios)). Nobody has driven a race with it yet. All of this is **unverified** for our ROM revision ([§5](#5-fidelity-risks-for-moto-racer-advance)).
- **No BIOS dump is needed to build or ship. One is needed to sign off fidelity against retail.** gbarecomp needs a 16 KiB BIOS image twice: once to recompile at build time and once to load at run time. [PR #2](https://github.com/nvergez/moto-racer-advanced-browser/pull/2) says "The BIOS dump is needed twice" because it describes gbarecomp's stock path. With option A, the open image fills both roles. Comparing against retail behavior does need the owner's dump (mGBA A/B, and optionally a private gbarecomp build). Without a dump, the fallback reference is mGBA's HLE, which has known blind spots ([§5.3](#53-how-we-would-detect-divergence)).

[emibios](https://github.com/coolbho3k/emibios) (LGPL-3.0-or-later) may be the stronger candidate on fidelity. Its README says "Many SWIs are tuned to match the retail BIOS in timing for most inputs". But it is one month old, and its LGPL obligations are hard to meet for this bundle. Re-evaluate it once we have the ROM ([§4](#4-options-for-our-build)).

## Why this matters

- Downloading Nintendo's BIOS image from the internet isn't an option for this project, and our docs won't point to one. The legal route is dumping it from a console you own, which needs GBA-family hardware plus a way to run homebrew. See [docs/guides/dumping-rom-and-bios.md](../guides/dumping-rom-and-bios.md) (open in [PR #1](https://github.com/nvergez/moto-racer-advanced-browser/pull/1) at the time of writing).
- Every future player of the browser port would face the same hurdle, because gbarecomp's web page asks for both the ROM and the BIOS ([`packaging/web/README.md` L8–12](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/packaging/web/README.md#L8-L12)).
- gbarecomp's author considered this exact option ("Redistributable replacement BIOS — bundle a freely-licensed reimplementation (e.g. Normmatt's open-source GBA BIOS, or the Cult-of-GBA BIOS)") and deferred it on 2026-07-02 as "not worth building now" ([`ENHANCEMENTS.md` L59–98](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/ENHANCEMENTS.md#L59-L98)). So it's a known trade-off upstream, but we'd be the ones maintaining it.

---

## 1. Open-source GBA BIOS replacements

### Summary

| | Cult-of-GBA BIOS | emibios | Normmatt's BIOS | mGBA HLE BIOS image |
|---|---|---|---|---|
| Source | [Cult-of-GBA/BIOS](https://github.com/Cult-of-GBA/BIOS) | [coolbho3k/emibios](https://github.com/coolbho3k/emibios) | [ReGBA `bios/`](https://github.com/Nebuleon/ReGBA/tree/7f379052dc14366e622a96c7cf7fb6b5a7e918a3/bios) | [mGBA `src/gba/hle-bios.s`](https://github.com/mgba-emu/mgba/blob/143adf5aa2a60c6036810b0cd72445e13d74b0e6/src/gba/hle-bios.s) |
| License (read from the files) | MIT, "Copyright 2020 - 2021 DenSinH and fleroviux" (`LICENSE`). Parts are described by their authors as decompiled or copied from the retail BIOS (see below) | LGPL-3.0-or-later for the BIOS; tests and some tooling MIT (`README.md` L88, SPDX headers) | GPL-2.0-or-later, "Copyright (c) 2013 Normmatt" plus VBA and VBA-M teams, in the header of the C source files (`helper.arm.c`, `logo.c`, `softwareinterrupts.c`). The assembly files and logo data (`core.s`, `divide.s`, `reset.s`, `logo_data.c`, `logo_data.h`) carry no license text | MPL-2.0 (file header) |
| Language / build | ARM assembly, GNU `as` (`make.sh`: devkitARM `arm-none-eabi-as` + `objcopy`) | ARM/Thumb assembly built with Zig 0.16 (`zig build`) | C + ARM assembly, devkitARM `gba_rules` + libtonc (`bios/Makefile`) | ARM assembly, devkitARM (`hle-bios.make`), compiled into mGBA as a byte array |
| Prebuilt binary | `bios.bin` committed in the repo, SHA-1 `2e41f9d30ecdf1c4540edf89ac16f49bf327edb7` at the pinned commit. No GitHub releases | GitHub releases 0.1.0–0.1.6 (`gba_bios.bin`, 16384 bytes). Release 0.1.6 (published 2026-10-03) is tag commit `1dcd0005a72f`, asset SHA-256 `ca56efafc53af12f6ba2eec722302dd2cb725f65dd2ed8afdeb5d27bc14e2d08` (equal to `bios.sha256` at that commit). `bios.sha256` at our pinned commit `c4d5d71` is `2a6c04d3f5d9…` instead (GitHub API, 2026-10-10) | `bios/gba_bios.bin` committed in ReGBA, SHA-1 `598c0b2c6c5d15bbba218773574c9e7856d141f3` | `hle-bios.c` in mGBA's tree |
| Activity (GitHub API, 2026-10-10) | Created 2020-07; last push 2025-04-06; 80 commits; 119 stars; 4 open issues | Created 2026-09-11; last push 2026-10-10; 79 commits (75 by one author); 51 stars | ReGBA archived; last push 2019-05-20; BIOS sources dated 2013 | Maintained as part of mGBA (pushed 2026-10-08) |
| SWIs | All 43 table slots (0x00–0x2A) filled. Sound slots partly `swi_DoNothing`: SoundBias, SoundDriverMode, **SoundDriverMain**, SoundChannelClear, 0x20–0x24, MultiBoot (`entrypoint.s` L185–228) | All 43 slots; sound driver, MusicPlayerFadeOut and MultiBoot implemented; slots 0x20–0x23 no-ops (`src/swi/swi_table.s`) | Math, memory, decompression, Halt/IntrWait implemented; sound driver 0x19–0x1E, 0x20–0x22, MultiBoot, HardReset, VSyncOff/On are no-ops (`core.s` L119–169) | Implements Halt, IntrWait, VBlankIntrWait, CpuSet, CpuFastSet, SoftReset and SoundDriverGetJumpList. The Div, DivArm, Sqrt, ArcTan, ArcTan2 and LZ77 entries fall into `StallCall`, a loop that burns the stall cycles mGBA computed, while mGBA computes the results in C (`hle-bios.s` L302–313, `bios.c` L592–597). The other entries are `bx lr` no-ops because mGBA handles those calls in C (`hle-bios.s` L131–162) |
| Boot | Own boot screen with the authors' names; sets I/O registers "in the same way the official BIOS does", though its own comment lists registers that came out different ([§2.5](#25-other-assumptions-about-the-nintendo-image)); no cartridge header check (`entrypoint.s` L15–87) | Own boot screen with game name/code; checks the header logo against a hash and does not contain the Nintendo logo (`src/boot/boot_screen.s` L9); multiboot receiver | Custom logo, "pauses for a second or two" (`logo.c` L50–53); no header check | No intro; jumps straight to the cartridge |
| GetBiosChecksum | Constant `0xBAAE187F` in r0 (`entrypoint.s` L235–240) | `0xBAAE187F`, r1 = 1, r3 = 0x4000, "same as retail" (`src/swi/system/get_bios_checksum.s`) | Constant `0xBAAE187F` with a TODO (`softwareinterrupts.c` L459–464) | n/a: mGBA returns the value from C |
| Retail open-bus value after an SWI (`0xE3A02004`) | No: `0xEAFFFFFE` (measured, [§2.4](#24-direct-reads-of-bios-memory)) | Yes, pinned on purpose (`src/swi/dispatcher.s` L56–58) | No: `0x00001524` (measured) | Yes, pinned on purpose (`hle-bios.s` L64) |
| Used or mentioned by | Shipped by [SkyEmu](https://github.com/skylersaleh/SkyEmu/blob/c3b0b56aed427b35188db30243ee74e52c1f9456/ACKNOWLEDGMENTS.md) and [FBNeo](https://github.com/finalburnneo/FBNeo/blob/e8f21da9ec5aaef94892716fcd84bca5e7f5563a/src/burn/drv/gba/gbabios.h) (both embed commit `0d9dd3e` from 2024-07, which predates the 2025-04 RegisterRamReset fix), [crab](https://github.com/mattrbeck/crab/blob/2d58e8233ad084afec772142d0148e2a853af57f/README.md); a reference for [NooDS](https://github.com/Hydr8gon/NooDS/blob/4cb1439c330248b26cdf5f8dbcfa4e5ac53dcda0/README.md)'s GBA HLE BIOS; the base of emibios | Developed against GBAHawk, MesenCE, mGBA and NanoBoyAdvance (README credits) | Bundled by ReGBA/TempGBA and [eggvance](https://github.com/jsmolka/eggvance/blob/73dcb0b497e15cf546c3d69f1cceaad6cb570e26/README.md). The [NanoBoyAdvance README](https://github.com/nba-emu/NanoBoyAdvance/blob/55b5cf0ae3d929582ac5bfd486558173502b8354/README.md) (L26) offers it as an unofficial, "(less accurate)" alternative to dumping. A modified copy is integrated in [GBARunner2](https://github.com/Gericom/GBARunner2/blob/6e4ce456597cabaaa45aac83bbd2f4c90580dca8/readme.md) | mGBA, when no BIOS file is loaded |

### Cult-of-GBA BIOS

- The README calls it "Written completely in ARM assembly from scratch" and says "high accuracy is a non-goal. But we aim to make it compatible with most commercial games." Its TODO list covers the remaining BIOS calls ("mainly sound functions"), BIOS-memory read checks in all calls, and more game testing.
- **Provenance: parts are retail-derived by the authors' own account.** Several source comments contradict "from scratch":

  | Part | SWIs | What the source says |
  |---|---|---|
  | MidiKey2Freq routine and its two tables | 0x1F | `bios_calls/audio.s` L1 "decompiled from the official BIOS:". The tables are annotated with retail BIOS addresses (`@ 0x3104`, `@ 0x31b8`, L2 and L23) |
  | SoundDriverInit | 0x1A | Same file. It refers to a retail routine by its decompiler name, `FUN_0000170a` (L186, L256) |
  | BitUnPack | 0x10 | `bios_calls/decompression/bitunpack.s` L1 "I decompiled this from the original BIOS:" |
  | HuffUnComp | 0x13 | `bios_calls/decompression/huffman.s` L1, same wording. Decompiler labels with retail addresses in the comments (`LAB_00001064`, L19 and L26) |
  | Sine table used by BgAffineSet and ObjAffineSet | 0x0E, 0x0F | `bios_calls/math/rotation_scaling.s` L26–28 "this is the LUT the original BIOS uses" |
  | ArcTan polynomial, also run by ArcTan2 (which falls through into it) | 0x09, 0x0A | `bios_calls/math/arctan.s` L89 "this is the algorithm used by the original BIOS" |

  Other comments only describe observed retail behavior. Examples: `rotation_scaling.s` L182 "looking at the original BIOS, the formula for ...", `decompression/running_length.s` L93, and `arctan.s` L144 (r3 = 0x170). They show the authors studied the retail BIOS. Whether that matters is for the legal review.
- **Why this matters even for SWIs the game never calls.** Distribution doesn't depend on what the game calls. `gba_recompile` expands the whole SWI table (43 entries, 34 distinct targets, all with dispatch entries; [§3](#3-experiment-recompiling-the-cult-of-gba-bios)). `build_web.sh` links the result into `game.wasm` (L212–222), and option A also ships `bios.bin` as an asset. Our reading, not legal advice: an MIT grant passes on only the rights its authors hold. It can't license code they took from someone else.
- **The tables can be regenerated from formulas.** We checked with a small script:
  - Every one of the 256 sine-table entries equals `trunc(16384 × sin(2πn/256))`. That is the formula emibios generates its table with (`tools/gen/sine_lut.zig`).
  - All 12 MIDI frequency entries equal `round(2^(n/12) × 2^31)`.
  - The MIDI scale table is a regular pattern (`(14 − octave) << 4 | semitone`).

  Regenerating them changes where the source comes from, not the bytes. The routines (BitUnPack, HuffUnComp, MidiKey2Freq, SoundDriverInit, ArcTan) would have to be rewritten. That's option A′ in [§4](#4-options-for-our-build).
- **Known differences from retail.** These come from source comments plus two checks of our own. This isn't a conformance test:
  - Div "differs from the official BIOS for division by 0 cases or int.MinValue / -1" (`bios_calls/math/division.s` L8).
  - **Div/DivArm remainder sign.** Cult-of-GBA gives the remainder (r1) the sign of the quotient, sign(N) xor sign(D) (`division.s` L48–49). Retail gives it the sign of the numerator, like C's `div()`: mGBA computes it with `div()` (`bios.c` L279), and emibios notes "The remainder takes the sign of Number" (`src/swi/math/div.s` L16–17). The two differ whenever the divisor is negative and the remainder is nonzero. For 1234 / −10, Cult-of-GBA returns r1 = −4 and retail +4. For −7 / −2, Cult-of-GBA returns +1 and retail −1. r0 and r3 match. These numbers come from our instruction-level model of the source, not an emulator run. GBATEK's example (−1234, 10) doesn't tell the two conventions apart ([GBATEK: BIOS Arithmetic Functions](https://problemkaputt.de/gbatek-bios-arithmetic-functions.htm)).
  - **IntrWait with r0 = 0** halts before checking for an already-set flag (`bios_calls/power.s` L27–28). GBATEK specifies r0 = 0 as "Return immediately if an old flag was already set" ([GBATEK: BIOS Halt Functions](https://problemkaputt.de/gbatek-bios-halt-functions.htm)), so Cult-of-GBA can return one interrupt late. VBlankIntrWait passes r0 = 1 and isn't affected.
  - CpuSet, CpuFastSet and LZ77 lack the retail check on the source address ("TODO: check if source address is valid (>= 0x02000000)" at `cpu_set.s` L1 and `decompression/lz77.s` L1).
  - Run emibios's test suite against Cult-of-GBA before rating its fidelity. That needs neither the ROM nor a dump ([§5.3](#53-how-we-would-detect-divergence) step 3).
- **Known game issues** ([issue tracker](https://github.com/Cult-of-GBA/BIOS/issues?q=is%3Aissue)):
  - Open reports: Castlevania: Aria of Sorrow (#18), a Pokémon Emerald ROM hack (#17) and a homebrew test suite (#14).
  - Fixed in the past: Golden Sun not booting (#3), Tony Hawk's Pro Skater 2 graphics via a Sqrt fix (#5, #7), Minish Cap affine distortion (#12), a RegisterRamReset bug (#15, #16).
  - Issue [#9](https://github.com/Cult-of-GBA/BIOS/issues/9) (2022-01-14) links an [mGBA A/B report](https://davidgfnet-cultgba-mgba-testing-1c75d903.netlify.app/): each ROM ran 9000 frames under Cult-of-GBA and under the retail BIOS, with dummy inputs. We loaded the 48 MB page and parsed it with a script.
    - The header reads "Comparing 2 runs (with 1062 roms), resulted in 764 differences". Only the ROMs whose two outputs differ are listed: 764 of 1062, or 72%. The issue's author expected most of these differences: "each BIOS takes a different amount of cycles and causes the game to drift slightly, but those can be ignored".
    - `Motoracer Advance.gba` is one of the 764. Both runs exited with code 0, after 24.49 s and 24.61 s.
    - Both frame-9000 screenshots show the race start screen: timer 0'00", POS 8, 000 km/h, HUD and track drawn. Neither shows visible breakage.
    - 27.0% of pixels differ. The differences are the 3D ground and roadside scenery, the whole top pixel row, and 20 pixels in the HUD's progress bar. The HUD, rider and sky are identical. That fits the two runs being slightly out of step. A difference in DivArm results in the 3D code would also show up in the scenery, though, and we haven't confirmed the cause.
    - The page doesn't say which column is which BIOS. The two screenshots look the same, so that doesn't change the result.
    - **Tested build.** The URL suffix `1c75d903` matches Cult-of-GBA commit `1c75d9034534` (2021-12-31). That was the latest commit when the issue was posted; the next one is dated 2022-10-21. Between that commit and our pinned `a30e9a9`, the source changed only in ObjAffineSet/BgAffineSet, RegisterRamReset and the boot animation (`git diff 1c75d90 a30e9a9`). None of the five SWIs on the game's preliminary list changed ([§5.1](#51-which-swis-the-game-calls)). The handoff state and boot timing did change: RegisterRamReset now writes the BG2/BG3 scaling registers to the right address (`6cc6bf9`), and the boot animation no longer gets skipped (`5ceb424`).
    - What it shows: no crash, and Cult-of-GBA gets through boot, the menus the dummy inputs pass, and the race start. What it doesn't show: actual driving, so DivArm under physics load and race-time frame pacing are still untested. The ROM revision is unknown.
- The two latest source fixes (`3cfa1b1`, `6cc6bf9`) updated `bios.bin` in the same commit (`git log -- bios.bin`). We couldn't check that the source reproduces it byte for byte: Apple clang's assembler rejects the GNU-syntax source (`ldr sp, =#…`, `ldmfa`, `b $`, `strneh`), and neither `arm-none-eabi-as` nor `llvm-mc` is installed here. `make.sh` calls devkitARM's `${DEVKITARM}/bin/arm-none-eabi-as` and `objcopy`. **Unverified.** Option A′ has to settle this first ([§4, A′ notes](#option-a-notes-fresh-repository-and-rewrites)).

### emibios

- README: "a research Game Boy Advance BIOS replacement that aims to be as accurate as possible when running commercial games while being freely redistributable". It is "not intended to contain, or use as reference, any proprietary code directly derived from the retail BIOS", relying on "observing and matching the behavior of the retail BIOS". "Originally based on Cult-of-GBA BIOS" (L9).
- Claims:
  - most SWIs accurate "in both result and register/flag side effects";
  - "Many SWIs are tuned to match the retail BIOS in timing for most inputs" (L20);
  - "Syncs with the retail BIOS in TAS playback in many games";
  - "no known titles currently failing to boot".

  It also warns: "This is a research project and should not be considered production-ready just yet." The README discloses that LLMs proposed and ran experiments and wrote some of the code. We haven't checked any of these claims.
- **Provenance, partly checked:**
  - Its sine table is generated at build time from a formula (`tools/gen/sine_lut.zig`, run from `build.zig` L23–27). Its MIDI table is written out by hand but documented as a formula, at a different scale from Cult-of-GBA's (`round(2^(n/12) × 2^30)`, 13 entries; `src/swi/audio/midi_key2freq.s` L7–8, L88–92). Its MidiKey2Freq routine is structured differently from Cult-of-GBA's.
  - Its ArcTan (`src/swi/math/arc_tan.s`) uses the same eight polynomial coefficients, in the same instruction order, as Cult-of-GBA's ArcTan, which Cult-of-GBA calls the retail algorithm. Matching retail results bit for bit probably requires those coefficients. Whether that's a problem is for the legal review.
  - Whether other emibios routines carry over Cult-of-GBA's retail-derived code is **unverified**.
- **Third-party font:** the README credits "Fonts for GB Studio (Jeremy Oduber)" for the boot screen font (L80). We haven't checked its license.
- It ships a test suite that can run against any BIOS image (`zig build test -Dbios=/path/to/gba_bios.bin`, `tests/README.md`). That gives us a ready-made SWI conformance check for whichever BIOS we pick.
- Very high churn: 32 commits on 2026-10-08 and 2026-10-09 alone. We'd have to pin one version and re-validate on every upgrade.

### Normmatt's BIOS

- Lives in ReGBA's `bios/` folder (ReGBA README: "an open-source BIOS replacement based on VBA-M's high-level BIOS emulation is bundled in the release archive. This BIOS is provided by Normmatt").
- **Not** the repository Normmatt/gba_bios. The [GBARunner2 wiki](https://wiki.ds-homebrew.com/gbarunner2/bios) points there for "Normmatt's Open Source BIOS", but that repo is a "Disassembly of the Game Boy Advance BIOS" that reassembles Nintendo's code and needs the original BIOS as `baserom.bin` to build (its README). It has no license and is unusable for us. The same goes for camthesaxman/gba_bios, the disassembly gbarecomp's own BIOS config is generated from. We name both without links on purpose.
- GBARunner2 integrates "the open source bios of Normmatt … with some small modifications". The GBARunner2 repository has no license (GitHub API: `license: null`), so that variant isn't usable either.

### How emulators cope without a BIOS (context only)

mGBA, when no full BIOS is loaded, runs a small built-in image (`hle-bios.s`, MPL-2.0) and computes most SWIs in C:

- `GBASwi16` checks `gba->memory.fullBios`. Without a full BIOS, it raises a real SWI into the image only for the calls the image implements ([`src/gba/bios.c` L408–445](https://github.com/mgba-emu/mgba/blob/143adf5aa2a60c6036810b0cd72445e13d74b0e6/src/gba/bios.c#L408-L445)).
- For Div, DivArm, Sqrt, ArcTan, ArcTan2 and LZ77, it computes the result in C and then, when the estimated stall is at least 18 cycles, raises the SWI into the image so its `StallCall` loop burns those cycles (`bios.c` L592–597, `hle-bios.s` L302–313).
- Sound driver SWIs are logged as stubs (L579–590).
- The image places the retail open-bus words where they'll be prefetched: `0xE3A02004` after an SWI, `0xE55EC002` after an IRQ, `0xE129F000` after reset (`hle-bios.s` L64, L124, L330). That shows how much mGBA cares about matching those values.

---

## 2. What gbarecomp assumes about the BIOS

The task brief said gbarecomp "does not HLE SWIs and refuses other hashes". Both need correcting: there is an opt-in HLE layer, and most hash checks are warnings with a configurable expected hash. A BIOS image is still always required.

### 2.1 Where the BIOS is required or its hash is checked

All at gbarecomp `5e89943`.

| Component | Where | Behavior with a non-Nintendo BIOS |
|---|---|---|
| Runtime default hash | `src/gba/gba_bios.h` L25–26 (`kExpectedSha1 = "300c20df…"`) | Only a default |
| Runtime config | `src/runtime/runtime.cpp` L144, L724–725 (`[bios].sha1`), L896–900 (`--bios-sha1`) | **Configurable** |
| Runtime BIOS picker | `runtime.cpp` L1383–1409 → `src/runtime/asset_picker.cpp` L152–175 | Size must be 16384 bytes (hard). Hash mismatch is a **warning**: "This is not the recompiled-against image. Behavior is undefined; proceeding anyway." |
| Runtime loader | `runtime.cpp` L1460 | Loads with an empty expected hash, so no check |
| Runtime without a BIOS file | `asset_picker.cpp` L247 (non-Windows: "no path provided") | **Hard fail.** A 16 KiB image is always needed, even in HLE mode |
| Browser page | `packaging/web/asset_store.js` L33–38 | 16384 bytes required; hash mismatch is a warning ("trying it anyway") |
| Browser build | `packaging/web/build_web.sh` L153–165 | Expected hash from `[bios].sha1` in the game config, else the Nintendo hash; a mismatch is a warning |
| Browser config export | `packaging/web/runtime_config.py` L15 | Exports `[bios]` `sha1`, `crc32`, `hle`, `hle_keep_intro`, `skip_intro` |
| BIOS recompiler | `tools/gba_recompile/main.cpp` L1063–1090, `config.cpp` L992–1021 | With `--config`, aborts unless the image matches `[identity].sha1` **of that config**. Without `--config`, no check |
| Desktop launcher | `src/runtime/launcher_seam.h` L66–88 | **Hard check** against the Nintendo hash ("Retail Game Boy Advance BIOS required"). Not used by the browser build |
| Netplay | `runtime.cpp` L1491–1496, `src/runtime/multiplayer_runner.cpp` L49 | **Hard check** ("netplay requires this build's original ROM and retail BIOS"). Only matters if we ever add link-cable play |
| Upstream gates and tests | `PRINCIPLES.md` L21–53 ("BIOS intro must be flawless"), `tests/selfheal/stage2_bios_identical.sh` | Validated against the Nintendo BIOS and mGBA only. Nothing upstream tests another BIOS |

Docs disagree with the code in places. `bios/README.md` L29 says "The runtime refuses to start with a BIOS whose hash isn't recognized", and `docs/ARCHITECTURE.md` L101–124 says the BIOS is interpreted and "there is no HLE path". The code above, and `ENHANCEMENTS.md` L18–58 (HLE "SHIPPED (2026-07-02)"), show otherwise. We trust the code.

### 2.2 How the BIOS is recompiled

- `gba_recompile --bios <image> [--config <toml>] --out <dir>` seeds the reset, SWI and IRQ vectors (0x00, 0x08, 0x18; `main.cpp` L1223–1242), discovers functions, and writes `bios_recompiled.{h,cpp}`, `bios_dispatch_table.cpp` and `bios_symbol_map.cpp`.
- CMake compiles those files **into `gbarecomp_runtime`** when `${GBARECOMP_GENERATED_BIOS_DIR}/bios_recompiled.cpp` exists, and uses an empty stub otherwise (`CMakeLists.txt` L415–449). The directory is a cache variable, so we can point it anywhere without touching the submodule.
- `build_web.sh` requires a generated BIOS directory as its second argument, configures the runtime with it, and links `libgbarecomp_runtime.a` into `game.wasm` (L174–176, L183–189, L212–222).
- **So gbarecomp's browser bundle contains a translation of whichever BIOS was recompiled.**
  - gbarecomp itself treats that output as Nintendo-derived and keeps it out of git: "it embeds Nintendo's BIOS bytes as instruction-by-instruction lowerings" (`src/runtime/generated_bios/.gitignore`).
  - Yet its web docs say the bundle "contains no ROM and no BIOS" and "can be published" (`packaging/web/README.md` L8–12).
  - With the Nintendo BIOS, publishing that bundle would distribute a translation of Nintendo's code. With an open BIOS, it's a translation of the open BIOS instead, which still carries whatever retail-derived parts that BIOS has ([§1](#cult-of-gba-bios)).
- The generated code reads literal pools and data tables from the loaded image at run time (e.g. `ldr r13,[r15,#0xf90]` becomes `bus_read_u32(...)`). **The image loaded at run time must be the same one that was recompiled.** That's why gbarecomp still asks for the `.bin` file, and why one build can't offer "use your own Nintendo BIOS instead".

**What `bios/gba_bios.toml` encodes.** It's specific to the Nintendo image and useless for any other BIOS:

- `[identity]` pins the Nintendo SHA-1 and MD5 (L17–19).
- 108 `[[extra_func]]` entries.
  - Most are function addresses and names imported from camthesaxman's disassembly of Nintendo's BIOS (`tools/import_bios_symbols/import_bios_symbols.py` L1–35), e.g. `swi_vector` at 0x140, `irq_vector` at 0x128, and `after_interrupt` at 0x138, where the game's IRQ handler returns (L97–100).
  - The rest are hand-added resume points observed under specific games (Metroid, Mega Man Zero, Pokémon Emerald) as IRQ returns into BIOS loops.
- Two `[[jump_table]]` entries: Nintendo's SWI table at 0x1C8 (43 entries) and the boot intro's command table at 0x3738 (L508–524).
- 8 `[[resume_range]]` entries, from the same game observations (L664–710).
- `static_resume_all = true`: every instruction of every emitted BIOS function becomes a valid resume point (`docs/TOML_SCHEMA.md` L122).

`docs/ENGINE_HLE_DMA.md` L307–316 records why the config matters: regenerating the Nintendo BIOS without it missed an entry point and resume coverage, and a strict build rejected it. With the config, the Nintendo BIOS yields 770 functions and 4,373 interior resume aliases.

### 2.3 SWI and IRQ paths

- A guest SWI calls `runtime_swi(imm)`, which enters SVC mode and dispatches to 0x08 in the recompiled BIOS (`src/armv4t/runtime_arm.cpp` L1327–1404).
- IRQs dispatch to 0x18 (L1496). `runtime_irq` then keeps re-dispatching R15 until the handler's exception return (L1512–1567). Every BIOS address the IRQ path passes through, including where the game's handler returns into the BIOS, needs a dispatch entry.
- Lookups for PCs below 0x4000 go to `kBiosDispatchTable` (L897–905). Nothing in the runtime names a Nintendo BIOS function: it dispatches purely by address. A grep of `src/` for Nintendo BIOS addresses outside comments found none.
- A dispatch miss is bridged by the interpreter and logged, unless `GBARECOMP_STRICT_STATIC` is set, which aborts (`src/runtime/runtime_arm_default_aborts.cpp` L899–916). There is no on-the-fly recompiler in the browser, so a browser build is "only honest for a game whose coverage is FULLY STATIC" (`build_web.sh` L37–39). The open BIOS must be fully covered by its config, like the Nintendo one.
- **Opt-in HLE** (`[bios].hle = true`): `src/runtime/bios_hle.cpp` (MPL-2.0, ported from mGBA) answers some SWIs before the BIOS runs (L467–509):
  - Handled in C: Div, DivArm, Sqrt, ArcTan, ArcTan2, CpuSet, CpuFastSet, GetBiosChecksum, Bg/ObjAffineSet, BitUnPack, the decompressors, SoundBias and MidiKey2Freq.
  - Left to the BIOS image: Halt, IntrWait, VBlankIntrWait, SoftReset, RegisterRamReset, the sound driver, MultiBoot, and the IRQ vector.
  - The cycle costs are approximate, and the affine SWIs and MidiKey2Freq use host floats (L17–26).
  - Without a recompiled BIOS linked, the runtime forces HLE and skips the intro (`runtime.cpp` L1566–1583).
  - gbarecomp's own summary: the dump "stays load-bearing three ways" (LLE fallback, BIOS-region reads, hash gate; `ENHANCEMENTS.md` L47–58).
- `[bios].skip_intro = true` synthesizes the documented post-boot state and jumps to the cartridge without running the intro, independent of HLE (`PRINCIPLES.md` L68–87, `src/runtime/bios_hle.cpp` L518–540). Upstream warns that this shifts IRQ timing and needs its own coverage work.

### 2.4 Direct reads of BIOS memory

Games can't read the BIOS from outside it. GBATEK: "If the program counter is not in the BIOS area, reading will return the most recent successfully fetched BIOS opcode", e.g. "the opcode at [0188h+8] after SWI execution" ([GBATEK, GBA Unpredictable Things](https://problemkaputt.de/gbatek-gba-unpredictable-things.htm)).

gbarecomp models this:

- Every instruction executed inside the BIOS latches the word at PC+8 **from the loaded image** (`src/runtime/runtime_bus_bridge.cpp` L1008–1018).
- Protected reads return that latch, without logging (`src/gba/gba_bus.h` L98–119, `gba_bus.cpp` L180–226).
- gbarecomp has hit at least one game depending on this ("MC-HP-002", `gba_bus.h` L100–104).

With a different BIOS image, those values change. For the two open images we have as binaries, we read the word at PC+8 of the IRQ-handler call and of each exception-return instruction with a small script:

| Moment | Retail value | Cult-of-GBA (`a30e9a9`) | Normmatt (ReGBA) | emibios |
|---|---|---|---|---|
| During an IRQ handler | `0xE25EF004` | `0xE25EF004` (match) | `0xE25EF004` (match) | not measured |
| After an IRQ returns | `0xE55EC002` | `0xE55EC002` (match) | `0xE129F000` (differs) | not measured |
| After an SWI returns | `0xE3A02004` | `0xEAFFFFFE` (differs) | `0x00001524` (differs) | pinned to `0xE3A02004` (`src/swi/dispatcher.s` L56–58) |
| After boot / SoftReset | `0xE129F000` | differs (that word appears nowhere in the image) | not measured | pinned to `0xE129F000` (`src/boot/hard_reset.s` L91–94) |

Where the retail values come from:

- After an SWI: gbarecomp `gba_bus.h` L108–109 ("for the GBA SWI return at BIOS 0x188 that is mem[0x190]=0xE3A02004").
- After an IRQ and after boot: the words mGBA's image places to imitate retail (`hle-bios.s` L124, L330).
- During an IRQ: derived. It's the `subs pc, lr, #4` that follows the handler call in both mGBA's and Nintendo's layout (GBATEK's "[0134h+8]").

Cult-of-GBA's IRQ values match because its IRQ and SWI handlers use the same instructions in the same order as retail.

A game that reads BIOS memory after an SWI would see a different value under Cult-of-GBA. Such reads are usually accidental, e.g. a null-pointer dereference. Whether Moto Racer Advance does this is **unverified**. mGBA logs these reads ([§5.3](#53-how-we-would-detect-divergence)). gbarecomp doesn't.

### 2.5 Other assumptions about the Nintendo image

- **Boot.** The Nintendo intro checks the cartridge's logo and plays the logo and chime. The open BIOSes show their own screens and leave their own post-boot state.
  - Cult-of-GBA writes the non-zero I/O values its authors measured on emulators (`entrypoint.s` comment L35–44, table L77–87). But its comment says "our BIOS still comes out with" four other values, including `0200 - 0001`, i.e. IE = 1 (L45–49).
  - The cleanup that follows clears DISPSTAT, BG0CNT, WINOUT and **IME** (0x208; L62–66, `definition.s` L53), not IE (0x200).
  - RegisterRamReset(0xFF), which runs after the boot screen, does clear IE (`bios_calls/register_ram_reset.s` L111–126), so the comment may predate a fix.
  - Whether IE, or anything else, differs from retail at handoff is **unverified**. RAM contents and timing at handoff differ for sure.
  - `skip_intro` makes the intro irrelevant, but the handoff state still needs checking, IE included.
- **Coverage discovered under the Nintendo BIOS.** Game-side resume points found while IRQs land at Nintendo-BIOS timing may shift with another BIOS. A game config with `static_resume_all = true` avoids depending on this (`docs/TOML_SCHEMA.md` L122).
- **Upstream support.** gbarecomp's principles call the real BIOS "the oracle" and forbid "stubbing SWIs, or making a game work by skipping BIOS code it actually depends on" (`PRINCIPLES.md` L55–133). Running an open BIOS doesn't break that rule: it's a real BIOS image, recompiled the normal way. But upstream won't test it, and one of its debugging rules no longer holds for us: "If something looks wrong 'around an SWI,' the divergence is in the codegen / runtime ABI / bus / IRQ scheduler — not in the BIOS" (L126–127). With an open BIOS, the BIOS is a suspect too.

---

## 3. Experiment: recompiling the Cult-of-GBA BIOS

Done on macOS (Apple clang 21, CMake 4.4, Ninja) in a scratch directory, not in this repo. Nothing was committed.

1. **Built `gba_recompile` natively** from gbarecomp `5e89943`: `cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DGBARECOMP_COMPILER_CACHE=OFF`, then `--target gba_recompile`. It built cleanly (CMake fetched toml++ v3.4.0). This is also a first data point for the plan's open question about building on macOS, for this one target only.
2. **No config:** `gba_recompile --bios cult-bios/bios.bin --out gen`.
   - The tool found 125 ARM functions from the 3 vector seeds.
   - All 43 SWI table targets got dispatch entries: the finder detects the table at 0x17C by itself, as the config run's summary below confirms ("auto_jt 0x0000017C count=43").
   - It **missed CpuSet's internal 4-entry function table** (`ldr pc, [r4, r2, lsl #2]` at 0x250), so SWI 0x0B would hit a dispatch miss at run time.
   - With no config there's also no `static_resume_all`, so IRQ returns into BIOS loops would miss too.
3. **First config** (identity hash, `static_resume_all`, the CpuSet table): 131 functions, 822 interior resume aliases, 953 dispatch entries. All 43 SWI table targets (34 distinct addresses) and all 4 CpuSet targets have entries.
   - But this config **missed the IRQ handler's return point**. `exception_irq` sets `add lr, pc, #0` then `ldr pc, [r0, #-4]` (`entrypoint.s` L129–130), so the game's handler returns to 0x120 (`ldmfd sp!, {r0-r3, r12, lr}`, then `subs pc, lr, #4` at 0x124).
   - The generated `afunc_00000110` ends with `GBARECOMP_TAIL_DISPATCH(0x00000120u)`, and the table had no entry for 0x120 or 0x124.
   - Every IRQ, VBlank included, would have bridged through the interpreter, or aborted under `GBARECOMP_STRICT_STATIC`. This is inferred from the generated code and the runtime source; we didn't run it.
   - gbarecomp's Nintendo config covers the same point with `after_interrupt` at 0x138 (`bios/gba_bios.toml` L97–100).
4. **Config in the [appendix](#appendix-scratch-config-for-the-cult-of-gba-bios)** (adds `[[extra_func]]` at 0x120): **132 functions, 823 aliases, 955 dispatch entries**, with 0x120 and 0x124 covered.
   - A script ([appendix](#coverage-script)) decodes the image and checks for a dispatch entry at:
     - every SWI and CpuSet table target;
     - every `b`/`bl` target;
     - every return address an emitted instruction sets up (`bl`, `mov lr, pc`, `add`/`sub lr, pc, #imm` including `adr lr`, and `ldr lr, =label`).
   - With the first config, 0x120 was the only miss. With the appendix config, there are none. We re-ran both configs with the appendix version of the script during the second review round, with the same result.
   - Exception returns go back either to the game (SWI) or to the interrupted BIOS instruction (IRQ during Halt/IntrWait), which `static_resume_all` covers inside emitted functions.
   - The remaining uncovered ranges below the end of code (0x2A26) are data or unreachable:
     - tables, literal pools and the boot screen's `.incbin` graphics, spot-checked rather than classified word by word;
     - the undefined, abort and FIQ vectors with their `b $` handlers, which a normal game never reaches.
   - For scale, the Nintendo BIOS needs 770 functions and 4,373 aliases ([§2.2](#22-how-the-bios-is-recompiled)). Cult-of-GBA is pure ARM, with no Thumb code.
5. **Linked it into the runtime** (first config): configured with `-DGBARECOMP_GENERATED_BIOS_DIR=<generated dir>` ("BIOS recompiled output present — linking") and built `gbarecomp_runtime`. It compiled with no errors. The appendix config only adds one function, but we haven't rebuilt the runtime with it.

This is a static check only. Full coverage is proven only by running the ROM with `GBARECOMP_STRICT_STATIC=1` and seeing no BIOS dispatch misses (Phase 2).

Not done, because each needs the ROM or tools we don't have yet: running a game with this BIOS, the browser build (no Emscripten installed), and a byte-for-byte rebuild of `bios.bin` from source.

---

## 4. Options for our build

None of these edits the gbarecomp submodule.

| Option | Player provides | gbarecomp changes | Our work (rough guesses) | License fit | Fidelity |
|---|---|---|---|---|---|
| **A. Cult-of-GBA, recompiled** | ROM only | None (config only) | 1–2 days of wiring. Validation: 2–3 days for the Phase 1 census and mGBA A/B, then BIOS triage time-boxed to one week before falling back (to A′ fixes, B or a retail dump) | MIT, but parts are retail-derived by the authors' account (§1). Needs A′ or an explicit owner decision after review before publishing | Untested on this game. Known differences: DivArm remainder sign, IntrWait r0 = 0, div-by-zero, timing, open bus (§1, §5.2) |
| **A′. Cult-of-GBA cleaned copy, retail-derived parts replaced, new history (recommended)** | ROM only | None | A + 4–6 days. Set up an ARM GNU assembler and check that the `a30e9a9` source rebuilds `bios.bin` SHA-1 `2e41f9d3…` byte for byte, before changing anything. Start a new repository from the cleaned tree with no upstream history. Generate the sine and MIDI tables from their formulas. Rewrite BitUnPack, HuffUnComp, MidiKey2Freq, SoundDriverInit and ArcTan from specs, or make the ones the census shows unused trap loudly. Settle the ArcTan question. Fix the DivArm remainder sign while there. Re-derive the recompile config and re-run the [coverage script](#coverage-script) after every rebuild. Check with emibios's tests. Details in the [A′ notes](#option-a-notes-fresh-repository-and-rewrites) | MIT for the kept parts; our new routines MIT too. Still needs the review to agree the replaced list is complete | As A, minus the DivArm difference, plus the risk of new bugs in the rewritten routines. ArcTan/ArcTan2 results differ from retail unless the retail coefficients are kept after legal review. Neither is on the preliminary SWI list (§5.1) |
| A″. Minimal purpose-built image | ROM only | None | Unknown, likely more than A′: vectors, IRQ handler, and only the SWIs the census finds | Our own code | Only as good as the census |
| B. emibios, recompiled | ROM only | None | A + ~1 day (Thumb handlers and a halfword SWI table need explicit seeds) + legal review | LGPL-3.0+: obligations we may not be able to meet for this bundle (see notes); ArcTan shared with Cult-of-GBA; font license unchecked | Probably best on paper; young and fast-moving |
| C. A/A′ or B plus gbarecomp HLE (`[bios].hle = true`) | ROM only | None | Hours on top of A/B | Adds no new license: `bios_hle.cpp` (MPL-2.0) is compiled into `gbarecomp_runtime` anyway (`CMakeLists.txt` L381) | Math results from mGBA-derived C; approximate timing |
| D. mGBA's HLE image plus gbarecomp HLE | ROM only | Patch needed: RegisterRamReset, Stop and sound would be no-ops otherwise | Several days | MPL-2.0: fine | Weakest: depends on two HLE layers designed for different hosts |
| E. Status quo: player supplies the Nintendo BIOS | ROM + BIOS dump | None | None | Publishing `game.wasm` would distribute a translation of Nintendo's BIOS ([§2.2](#22-how-the-bios-is-recompiled)) | Best |
| F. Player's Nintendo BIOS, interpreted, nothing recompiled into the bundle | ROM + BIOS dump | None (forced HLE when no BIOS is linked) | Measuring only | Avoids the distribution problem | IRQs and machine-state SWIs go through the interpreter on every call; upstream calls such browser builds not "honest"; speed unmeasured |

Ruled out:

- Normmatt's BIOS. Its C files are GPL-2.0-or-later, and its recompiled form would be linked into one `game.wasm` with PolyForm Noncommercial code. The GPL would require the combined work to be under GPL terms, which can't carry PolyForm's noncommercial restriction. Its assembly files have no license at all, which doesn't help.
- GBARunner2's copy (no license).
- Every disassembly of Nintendo's BIOS.

### Option A in detail (A′ is the same, pinned to our own repository instead)

Paths follow the layout proposed in [PR #2](https://github.com/nvergez/moto-racer-advanced-browser/pull/2) (§9: a `gbarecomp/` submodule at the root, `game.toml`, `tools/regen.sh`, ignored `roms/ bios/ generated/{bios,game}/ build/`). The scaffold PR should settle the open points below.

1. **Vendor the BIOS** as a git submodule next to `gbarecomp/`, e.g. `cult-of-gba-bios/`, pinned to `a30e9a9`. For A′, pin our A′ repository instead. It must not be a GitHub fork or any clone that carries upstream history ([A′ notes](#option-a-notes-fresh-repository-and-rewrites)). A submodule keeps its `bios.bin` out of our tree. Our `.gitignore` ignores `bios/` and `*bios*.bin`, so a copied file would be silently ignored, and a negation rule could let a Nintendo dump slip into a commit. Don't name the submodule directory `bios`: that's where PR #2 expects the owner's dump.
2. **Verify before use:** `tools/regen.sh` refuses anything but SHA-1 `2e41f9d30ecdf1c4540edf89ac16f49bf327edb7` (or the A′ build's hash).
3. **Our recompile config**, e.g. `cult-of-gba-bios.toml` next to `game.toml`, starting from the [appendix](#appendix-scratch-config-for-the-cult-of-gba-bios). Its addresses are valid for image `2e41f9d3…` only. Re-derive them and re-run the [coverage script](#coverage-script) whenever the image or gbarecomp changes.
4. **Build:** `gba_recompile --bios cult-of-gba-bios/bios.bin --config cult-of-gba-bios.toml --out generated/bios`. That's the directory PR #2 already passes as `GBARECOMP_GENERATED_BIOS_DIR` and to `build_web.sh`, so nothing downstream changes. *Open point for the scaffold PR:* the private retail variant (step 8) then needs its own directory, e.g. `generated/bios-retail`.
5. **Game config:** `[bios] sha1 = "2e41f9d30ecdf1c4540edf89ac16f49bf327edb7"`, so the runtime and the web build expect the open BIOS. Decide later whether to set `skip_intro = true`.
6. **Web shell:** bundle the 16 KiB image as a normal asset and write it to `/data/gba_bios.bin` in `preRun`, where gbarecomp's `bootstrap.js` L66 writes the player's BIOS today. Remove the BIOS picker. `build_web.sh` copies gbarecomp's `bootstrap.js` and `index.html` into the output (L231–232). So either replace them in our own Phase 3 web shell (planned anyway) or keep a small patch applied to a copy. The ROM SHA-1 gate stays.
7. **Third-party notices** for everything in the bundle, in a notices file linked from the page and in the repo docs:
   - gbarecomp: PolyForm Noncommercial 1.0.0. gbarecomp's `LICENSE` is a shortened text without the canonical "Notices" section, but it names the canonical URL (L3). The canonical Notices section asks that recipients get "a copy of these terms or the URL for them" ([PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0)). Ship the full terms or that URL.
   - `src/runtime/bios_hle.{h,cpp}`: MPL-2.0, ported from mGBA, compiled in unconditionally (`CMakeLists.txt` L381). Include the MPL notice and a pointer to the source files (`THIRD_PARTY_ATTRIBUTION.md`).
   - The JRickey/gba-recomp ports (MIT OR Apache-2.0), which are in `libgbarecomp_gba.a` and `libgbarecomp_runtime.a` (`CMakeLists.txt` L293–301, L394; `THIRD_PARTY_ATTRIBUTION.md`). Which objects the static link actually pulls into `game.wasm` is **unverified**; list them all to be safe.
   - Cult-of-GBA's MIT `LICENSE` text, which MIT requires "in all copies or substantial portions".
8. **Developer-only reference:** if the owner dumps the Nintendo BIOS, they can build a **private, unpublished** native variant with it for the comparisons in [§5.3](#53-how-we-would-detect-divergence).

What players see: "Choose your ROM", nothing else. The boot shows the Cult-of-GBA screen (with its authors' names) unless `skip_intro` is set.

### Option A′ notes: fresh repository and rewrites

**A new repository, without upstream history.**

- The code A′ exists to remove has been in Cult-of-GBA's history since July 2020 (`a685b5a` added BitUnPack and `627702b` HuffUnComp, both with the "decompiled" comment). Every `bios.bin` committed since January 2021 contains builds of it (11 commits touch `bios.bin` up to `a30e9a9`). At `a30e9a9`:
  - `bios_calls/audio.s` L1: "decompiled from the official BIOS:";
  - `bios_calls/decompression/bitunpack.s` L1 and `huffman.s` L1: "I decompiled this from the original BIOS:";
  - `bios_calls/math/arctan.s` L89: "this is the algorithm used by the original BIOS".
- A GitHub fork, or any clone pushed with its history, would republish all of that from the owner's account. As a submodule of our repository, it would also be fetched by every recursive clone of ours.
- So: create a new repository (not with GitHub's Fork button) whose first commit is the cleaned tree.
  - Keep Cult-of-GBA's MIT `LICENSE` with its copyright line.
  - Credit upstream in the README with the repository URL and the base commit `a30e9a9`.
  - License our new routines MIT as well, so the image stays under one license.
- Alternative: keep the cleaned source in a directory of our own repository and build it as part of our pipeline. That saves a repository, but every developer machine and CI job then needs the ARM assembler. Our `.gitignore` already ignores `*bios*.bin`, so the built image wouldn't be committed by accident.

**Write the replacements from specifications.**

- Sources: GBATEK, emibios's tests run as black-box checks (the tests are MIT), and our own measurements. Not the removed files, not any disassembly of the retail BIOS, and not emibios's BIOS code, which is LGPL-3.0-or-later.
- Ideally the person writing them hasn't studied the removed files. For the record: the authors of this research have read parts of them, including Cult-of-GBA's ArcTan routine.
- Record who wrote each routine and from which sources. The legal review needs that.

**Toolchain and reproducibility come first.**

- `make.sh` assembles `entrypoint.s` with devkitARM's `arm-none-eabi-as -mcpu=arm7tdmi` and extracts the image with `arm-none-eabi-objcopy -O binary`. Neither is installed here, and Apple clang's assembler rejects the source (§1).
- Before changing anything, install an ARM GNU assembler, rebuild `a30e9a9` unchanged, and compare the SHA-1 with `2e41f9d30ecdf1c4540edf89ac16f49bf327edb7`. devkitARM is what `make.sh` expects (the README has no build instructions). Whether another GNU binutils build for `arm-none-eabi` gives identical bytes is **unverified**. If the rebuild differs, find out why first. Otherwise every later difference is ambiguous.
- Commit the A′ build's `bios.bin` with its SHA-1, plus a check (script or CI job) that the source still rebuilds it.

**ArcTan and ArcTan2 can't be both clean-room and retail-exact.**

- GBATEK's ArcTan entry gives only the input and output ranges and warns "there is a problem in accuracy" outside ±π/4. It gives no algorithm ([GBATEK: BIOS Arithmetic Functions](https://problemkaputt.de/gbatek-bios-arithmetic-functions.htm)). A routine written from GBATEK alone will return different values from retail.
- Retail-exact results need the eight polynomial coefficients. Cult-of-GBA calls them the retail algorithm. The same eight coefficients appear in emibios (`src/swi/math/arc_tan.s` L10) and in mGBA's `_ArcTan` (`src/gba/bios.c` L291–317, MPL-2.0). Appearing in three open projects doesn't settle where they came from.
- Decide after the census (§5.3 step 1). ArcTan (0x09) and ArcTan2 (0x0A) aren't on the preliminary list (§5.1).
  - If the census confirms neither is called, replace both with a loud trap or any reasonable approximation. They need replacing even unused, because every SWI-table target is compiled into the bundle (§1).
  - If either is called, choose one: keep the coefficients once the legal review clears them, or use a different approximation and measure its effect in the A/B (§5.3 step 2).

**Re-derive the recompile config after every rebuild.**

- The appendix config is valid for image `2e41f9d3…` only. Its identity hash changes with any edit.
- In `entrypoint.s`, the vectors, IRQ handler, SWI dispatcher and `cpu_set.s` come before the decompression, math and audio files (L242–247). So the IRQ return point (0x120) and the CpuSet table (0x254) probably keep their addresses when only those later routines change. Everything after the first changed routine moves, and so do the SWI table's targets.
- After each rebuild: read the addresses from the assembler listing or a disassembly, update `[identity]`, `[[extra_func]]` and `[[jump_table]]`, regenerate, and run the [coverage script](#coverage-script) until it reports no misses. Then do the strict-static run (§5.3 step 4).

### Option B notes (emibios)

- Same mechanics as A. Its SWI table is 16-bit offsets with bit 0 marking Thumb handlers (`src/swi/swi_table.s`), and `gba_recompile` rejects `abs16` tables with `entries_mode = "auto"` (`tools/gba_recompile/config.cpp` L425–432). Each handler needs its own `[[extra_func]]` with the right mode.
- **LGPL-3.0 questions for the legal review** (our reading, not legal advice):
  - The recompiled emibios in `game.wasm` is a translation of the Library, so a modified version of it, not only something linked against it.
  - Section 4(d)(0) asks for the "Corresponding Application Code" in a form that lets users relink with a modified BIOS (emibios `LICENSE` L99–107). Here that code includes `libgbarecomp_game.a`, the recompiled ROM, which `build_web.sh` links into the same `game.wasm` (L212–222) and which we can't publish. This is the same problem as the [game-code issue](#related-issue-outside-this-docs-scope) below.
  - Regenerating the translation from a modified BIOS needs gbarecomp's recompiler, which is PolyForm Noncommercial.
  - The boot screen font from "Fonts for GB Studio" (§1) has a license we haven't checked.
- **Pinning:** pin exactly one version and say which:
  - either release 0.1.6 (tag commit `1dcd0005a72fc5b9232a2b05a821b5e1d7850bb3`, `gba_bios.bin` SHA-256 `ca56efaf…`, equal to `bios.sha256` at that commit);
  - or a commit, built with Zig 0.16 and checked against `bios.sha256` at that same commit.

  The §1 facts describe `c4d5d71` and need re-checking at whatever we pin.

### Risks common to A–C

- **gbarecomp upgrades** may add a hard Nintendo-only check, change the BIOS config schema, or change how the generated BIOS is selected. Pinning the submodule contains this. Re-run the [coverage script](#coverage-script) on each upgrade.
- **The open BIOS is less maintained:** Cult-of-GBA's last change was April 2025. We may end up fixing BIOS bugs ourselves, either in our own repository (which A′ creates anyway) or by switching to emibios.
- **Debugging changes.** Upstream assumes the BIOS is ground truth ([§2.5](#25-other-assumptions-about-the-nintendo-image)). For us, a bug near an SWI first needs BIOS triage: same BIOS in mGBA, then mGBA HLE or the retail BIOS, then `[bios].hle = true` (§5.3 step 6). Budget for that in Phase 2.
- **Netplay would need a patch** because of the hard retail-BIOS check (§2.1). It's not planned.

---

## 5. Fidelity risks for Moto Racer Advance

Everything game-specific here is **unverified** until the ROM has been analyzed (no ROM revision pinned yet).

### 5.1 Which SWIs the game calls

- **Preliminary, third-party:** a 2022 per-game SWI list recorded by running mGBA with the retail BIOS and "some dummy inputs to get past most start screens" ([issue #9](https://github.com/Cult-of-GBA/BIOS/issues/9#issuecomment-1034127061), [CSV linked in a later comment](https://github.com/Cult-of-GBA/BIOS/issues/9#issuecomment-1036609624)). Each field holds the decimal SWI number.
  - The row `Motoracer Advance.gba` lists **5, 7, 12, 17, 20**: VBlankIntrWait (0x05), DivArm (0x07), CpuFastSet (0x0C), LZ77UnCompWram (0x11), RLUnCompWram (0x14).
  - How far that run got: the same author's A/B report used the same kind of dummy inputs for 9000 frames, and both of its Moto Racer runs reached the race start ([§1](#cult-of-gba-bios)). The SWI-list comments don't give a frame count. If that run was as long, the list covers boot, menus and the race start screen, with the bike stationary. That is likely but **unverified**.
  - Caveats: unknown ROM revision; reached the race start but no driving, so driving physics and most race-time code probably weren't exercised; only SWIs that actually executed were counted.
- **Across many games**, from the same data ([histogram comment](https://github.com/Cult-of-GBA/BIOS/issues/9#issuecomment-1037086478)): CpuSet (778 games), VBlankIntrWait (551), CpuFastSet (524), Div (409), LZ77 WRAM (394) and VRAM (361), RegisterRamReset (235), Halt (162), ObjAffineSet (128), Sqrt (114), ArcTan2 (106). Sound driver SWIs (0x1A–0x1E) appear in 7 games each, which suggests most games bring their own sound code.
- **What a 2002 3D racer might add** (general expectation, **unverified** for this game): Sqrt and ArcTan2 for vectors and steering, Div/DivArm for perspective projection, BgAffineSet/ObjAffineSet for Mode 7-style layers and scaled sprites. Many GBA 3D engines avoid SWIs in hot loops and use their own routines in IWRAM instead, because of the call overhead. Which applies here is a Phase 1 question.

### 5.2 How a different implementation can diverge

| Kind | Example | Visible effect | Moto Racer exposure (preliminary SWI set) |
|---|---|---|---|
| Results | Cult-of-GBA Div/DivArm remainder takes the quotient's sign instead of the numerator's (§1); Div by zero and `INT_MIN / -1` differ from retail; HLE affine uses floats | Wrong physics or graphics, possibly a hang | **Medium until measured.** DivArm is on the list. r1 differs whenever the divisor is negative and the remainder nonzero. The 2022 A/B (§1) shows no visible breakage at the race start under Cult-of-GBA. Its pixel differences are in the 3D scenery, where both drift and a DivArm difference would show, so it doesn't rule this out. Whether the game reads r1 after DivArm and divides by negative numbers is **unverified**. Divide-by-zero handling is **unverified** too |
| Register side effects | Retail leaves specific values in r1/r3 (e.g. Div puts the absolute quotient in r3; mGBA's CpuSet sets r3 to 0x170 to "Match official BIOS's clobbered r3", `hle-bios.s` L249) | Only if compiled code relies on them (rare) | Low |
| Wait behavior | Cult-of-GBA's IntrWait with r0 = 0 waits for one more interrupt when a flag is already set (§1) | Extra frame of latency, shifted game loop | None in the list: VBlankIntrWait uses r0 = 1 |
| Timing | Every SWI's cycle count differs (emibios tunes them; Cult-of-GBA doesn't) | Frame-time budget changes, so possible extra or fewer lag frames, shifted IRQ arrival, different behavior in races against VBlank | **Main risk.** The 2022 A/B reached the race start under Cult-of-GBA with only drift-like differences (§1), but the bike wasn't moving. DivArm called many times per frame while driving could still change frame pacing. Two rough indications that the gap may be small, both **unverified**: Cult-of-GBA's CpuFastSet copies in the same 8-register `ldmia`/`stmia` bursts that GBATEK describes for retail (`cpu_set.s` L65–84; [GBATEK: BIOS Memory Copy](https://problemkaputt.de/gbatek-bios-memory-copy.htm)), and its Div loops (`division.s` L26–43) cost the same order of cycles per quotient bit as mGBA's retail model, 11 + 13 × loops (`bios.c` L288), by our rough count. Measure it with lag frames (§5.3) |
| BIOS open bus | `0xEAFFFFFE` instead of `0xE3A02004` after an SWI (§2.4) | Only if the game reads BIOS memory, usually by a bug | Unknown |
| Boot state | Different intro; different RAM and timing at handoff; possibly IE (§2.5) | Different RNG seed, if the game derives one from early timing or uninitialized RAM | Unknown |
| Missing functionality | Cult-of-GBA's SoundDriverMain is a no-op | No music in games using the BIOS sound driver | None in the preliminary list |

One consequence for the plan: Phase 2's exit test ("a full cup plays identically to mGBA under the input replays") must run **the same BIOS on both sides** (mGBA + Cult-of-GBA vs. gbarecomp + Cult-of-GBA). Comparing an open BIOS against the retail one will drift through timing alone, as the issue #9 author noted: "each BIOS takes a different amount of cycles and causes the game to drift slightly". The cross-BIOS comparisons in §5.3 therefore use metrics that survive drift.

### 5.3 How we would detect divergence

**Phase 1 (no recompiler involved).** Steps 1–2 need the ROM; the retail dump is needed only for the retail variant of step 2. Step 3 needs neither and can run now.

1. **SWI census in mGBA.** mGBA logs every SWI with r0–r3 at entry ("SWI: %02X r0: …", `GBA_BIOS` category, DEBUG level), whichever BIOS is loaded: the log comes before the `fullBios` check (`src/gba/bios.c` L410, L422).
   - Play menus, one race and a full cup.
   - For DivArm (r0 = divisor, r1 = numerator), count the calls with a negative divisor and a nonzero remainder (computed offline from the two logged inputs). Those are the calls where Cult-of-GBA's r1 differs from retail.
   - Add a static scan of the ROM for SWI opcodes (Thumb `0xDFxx`, ARM `0xEFxxxxxx`) to catch rare paths. Hits in data are false positives to sort by hand.
2. **mGBA A/B, no recompiler involved.** mGBA can load any BIOS file, or none for HLE. The variants: the retail BIOS (if dumped), Cult-of-GBA (or our A′ build), emibios and mGBA HLE. Script the runs with mGBA's Lua scripting (since 0.10.0, ["preliminary support for Lua scripting"](https://mgba.io/2022/10/11/mgba-0.10.0/)).
   - **Start every variant at the cartridge entry.** The intros differ (Nintendo logo, the Cult-of-GBA and emibios boot screens, nothing under mGBA HLE), so the same inputs replayed from power-on are out of sync from frame 0.
     - In mGBA, set the `skipBios` option (`src/core/config.c` L464). On reset, mGBA then calls `GBASkipBIOS`, which jumps to the cartridge and sets VCOUNT and POSTFLG the same way whatever BIOS is loaded (`src/gba/core.c` L844–855, `src/gba/gba.c` L308–325).
     - gbarecomp's equivalent is `[bios].skip_intro` (§2.3, used in step 5).
     - Drift still builds up from the first SWI or interrupt, because each BIOS spends a different number of cycles.
   - **Check the boot path separately.** Skipping the intro hides boot-state differences. Do one run per BIOS with the intro to check that the game starts, and compare the handoff state (§2.5). emibios's `tests/system/handoff_test.zig` takes a "register/latch snapshot" at handoff (`tools/test_manifest.zig`) and may be reusable for that.
   - **Use metrics that survive drift:**
     - *Lag frames, the timing metric.* Over a fixed number of frames, count the VBlankIntrWait calls in the `GBA_BIOS` SWI log (step 1). More frames per call under one BIOS means the game misses VBlanks more often there. This assumes the main loop waits with VBlankIntrWait, the only wait SWI on the preliminary list (§5.1). **Unverified.**
     - *Race results:* finishing position and time per race. Write replays that hold inputs over long stretches (hold accelerate, steer in long segments), so that a few frames of drift don't change the bike's line. Expect small differences even then. The tolerance goes in the ADR.
     - *Screenshots and key RAM:* compare them exactly only up to the first divergence. Record that frame and the SWIs logged just before it. After it, look for visible or audible problems, not pixel equality.
   - Enable the `GBA_MEM` GAME_ERROR log: "Bad BIOS Load32/16/8" is logged for every read of BIOS memory from outside it (`src/gba/memory.c` L388, L547, L662). That's our open-bus detector. gbarecomp has no equivalent log (§2.4).
3. **SWI conformance, runnable now without the ROM or a dump.** Run emibios's test suite against the candidate image: `zig build test -Dbios=<path to Cult-of-GBA bios.bin>` (emibios `tests/README.md`).
   - **Setup:** Zig 0.16 (`build.zig.zon`, `minimum_zig_version`). The build also fetches an emulator core to run the tests on: GBAHawk by default, or MesenCE or mGBA with `-Demu=` (`build.zig.zon`, `build.zig` L110–112). None of these is installed here, and whether they build on macOS is **unverified**.
   - **Results:** the DivArm sweep checks r0, r1 and r3 against truncated division for 209 operand pairs, including negative divisors (`tests/math/swi_div_arm_test.zig` L23–47, remainder at L37–38). Cult-of-GBA's remainder sign should fail it.
   - **Timing:** cycle counts are pinned for a few inputs per SWI. Examples: DivArm(0x12345, 7) = 273 cycles (`swi_div_arm_test.zig` L16–21); CpuFastSet copy and fill of 128 words (`tests/memory/swi_cpu_fast_set_test.zig` L58–71); LZ77 and RL, one 256-byte fixture each into WRAM and VRAM (`tests/decompression/swi_lz77_test.zig` L50–52, `swi_rl_test.zig` L47–49). A timing failure gives the per-call cycle gap for those inputs.
   - **Limits:**
     - The pins aren't stated to be retail measurements. The RAM-permutation goldens say "Measured on OUR BIOS under forced blank, to be re-verified on real hardware" (`tests/memory/ram_perm.zig` L91–92). The per-SWI test files don't say where their numbers come from. The README claims "Many SWIs are tuned to match the retail BIOS in timing for most inputs" (L20). So a timing failure measures the distance from emibios, which is only claimed to be close to retail.
     - The cycle counts come from an emulator core, so they're only as accurate as its timing.
     - The LZ77 and RL timing fixtures are one byte value repeated, unlike game assets.
     - VBlankIntrWait, IntrWait and Halt have no tests at all (`tools/test_manifest.zig`). Their timing shows up only as lag frames in step 2.

**Phase 2 (gbarecomp, once the build gets that far):**

4. **Recompiler correctness, same BIOS on both sides:** gbarecomp + Cult-of-GBA vs. mGBA + Cult-of-GBA, using `GBARECOMP_INPUT_RECORD` / `GBARECOMP_INPUT_REPLAY` (`runtime.cpp` L3211–3293) and the TCP `state_hash` command (FNV-1a over IWRAM, EWRAM, VRAM, palette, OAM and the cycle count, with per-region hashes; `TCP.md` L176–179).
   - Run with `GBARECOMP_STRICT_STATIC=1` to prove the BIOS coverage from §3.
   - `GBARECOMP_SWI_LOG=<file>` records each SWI with its caller and r0–r2 (`runtime_arm.h` L396–401, `runtime_arm.cpp` L561–603, `runtime.cpp` L2125–2128). It's a fixed ring buffer of 131072 entries (`kSwiLogSize = 1u << 17`, L563) whose write index wraps silently (L587). Log one scenario per run, and treat a file with exactly 131072 records as wrapped.
5. **BIOS fidelity (needs the dump; private build only):** the same replays on gbarecomp + Nintendo BIOS vs. gbarecomp + Cult-of-GBA, both with `[bios].skip_intro = true` so they start at the cartridge entry (`bios_hle.cpp` L518–540). Expect timing drift anyway. Use the step 2 metrics: lag frames from `GBARECOMP_SWI_LOG` (mind the ring buffer, step 4), race results, and the first divergence in `state_hash`. Then check whether anything a player can perceive changes: physics, graphics, audio.
6. **Per-SWI isolation:** `[bios].hle = true` routes the math, memory and decompression SWIs to the same C code under both BIOS images. If divergence vanishes with HLE on, the cause is one of those SWIs. If it persists, look at the IRQ path, Halt/IntrWait or the boot state.

**Acceptance (proposal), in two tiers:**

- **With a retail dump (full sign-off).** Runs start at the cartridge entry (step 2). Exact frame-by-frame equality with retail isn't expected and isn't a criterion.
  - Lag frames over a full cup: no systematic increase over the retail BIOS, in mGBA (step 2) and, if built, in the private gbarecomp build (step 5). The threshold goes in the ADR, once the first retail run gives a baseline.
  - Race results over a full cup within the ADR's tolerance of retail, with the drift-tolerant replays from step 2.
  - The first divergence is located (frame, preceding SWI or interrupt) and explained. After it, no visible or audible problem in a full cup.
  - The game boots and plays from the open BIOS's own intro too (step 2, boot path).
  - Every census SWI either matches retail results or has a documented, harmless difference.
  - No "Bad BIOS Load" logs in the mGBA runs, or they're shown to be harmless.
  - No BIOS dispatch misses under `GBARECOMP_STRICT_STATIC`.
- **Without a dump (fallback):** the same checks, with mGBA HLE standing in for retail and emibios's suite (step 3) as a second reference for results and per-SWI timing. Record in the ADR what this can't detect:
  - Timing against retail. mGBA's HLE charges its own approximate stall model (`bios.c` `useStall`), so lag frames under it aren't a retail reference. emibios's timing pins help only as far as they match retail, which is **unverified** (step 3).
  - Retail edge cases mGBA itself gets wrong.
  - Boot-state differences, because mGBA HLE has no intro.
  - mGBA's results aren't independent of gbarecomp's HLE either, since gbarecomp's HLE is ported from mGBA.

  mGBA HLE does pin retail open-bus values (§1), so open-bus dependence still shows up.

---

## 6. Recommendation

1. **Build with option A; publish A′, or A only after an explicit risk decision.**
   - Use the Cult-of-GBA BIOS, recompiled, for development and the Phase 1/2 work.
   - Before any build is published, replace the parts its authors describe as decompiled or copied from the retail BIOS (§1) in a small, pinned repository of our own (A′). Start it from a fresh commit of the cleaned tree, without upstream history, keeping the MIT `LICENSE` and credit. Write the replacements from specs, not from the removed files ([A′ notes](#option-a-notes-fresh-repository-and-rewrites)). Alternatively, the owner records an explicit decision to accept that risk after review.
   - Either way, an open BIOS removes the wholesale translation of Nintendo's BIOS from `game.wasm`. It doesn't make the bundle publishable on its own (see the game-code issue below).
2. **No BIOS dump is needed to build or ship. One is needed to sign off fidelity against retail.**
   - If the owner can dump their console's BIOS, do it: it's the only retail reference for the §5.3 comparisons.
   - If not, use the no-dump acceptance tier and record its blind spots in the ADR.
3. **Now, before the ROM:** run emibios's suite against Cult-of-GBA's `bios.bin` (§5.3 step 3). It needs no ROM and no dump, and it gives the first per-SWI timing numbers and a check of the DivArm remainder sign. If A′ goes ahead, also set up the ARM assembler and check that the source rebuilds `bios.bin` byte for byte ([A′ notes](#option-a-notes-fresh-repository-and-rewrites)).
4. **In Phase 1, with the ROM:** run the mGBA SWI census and the A/B, starting every variant at the cartridge entry and using the drift-tolerant metrics, the "Bad BIOS Load" log and the DivArm sign check (§5.3 steps 1–2). Record the result in an ADR. If Cult-of-GBA shows a perceptible problem the census can explain, fix it in the A′ repository or try emibios (option B). B needs its LGPL questions answered first.
5. **Before Phase 3:** write the vendoring, hash check, config and web-shell changes from §4, plus the full third-party notices (step 7).

### Related issue outside this doc's scope

The same mechanism that puts the recompiled BIOS into `game.wasm` also puts the recompiled **game** there: `build_web.sh` links `libgbarecomp_game.a`, built from the C++ generated from the ROM (L202–222). Publishing the bundle therefore distributes a translation of Moto Racer Advance's code, whatever BIOS we use. Our `CLAUDE.md` forbids committing such code, but the Phase 3 plan hosts the bundle publicly. That needs its own decision (ADR) before Phase 3. An open BIOS doesn't solve it. It also blocks option B: the LGPL's relinking requirement would cover that same game code (§4, Option B notes).

---

## Appendix: scratch config for the Cult-of-GBA BIOS

Used for the second run in §3. Not yet tested with a game.

**Valid for `bios.bin` SHA-1 `2e41f9d30ecdf1c4540edf89ac16f49bf327edb7` only** (Cult-of-GBA `a30e9a9`). The hash, the IRQ return point (0x120) and the CpuSet table (0x254) all come from that image. For any other build, A′ included, re-derive them ([A′ notes](#option-a-notes-fresh-repository-and-rewrites)) and re-run the [coverage script](#coverage-script).

```toml
[program]
name         = "Cult-of-GBA BIOS"
id           = "cult_of_gba_bios"
load_address = 0x00000000
size         = 0x00004000
entry_pc     = 0x00000000
static_resume_all = true

[identity]
sha1 = "2e41f9d30ecdf1c4540edf89ac16f49bf327edb7"   # bios.bin at Cult-of-GBA/BIOS a30e9a9
md5  = "e2a18f17249a24415ca70d57f40501c8"

# The IRQ handler sets lr with 'add lr, pc, #0' at 0x118 and jumps to the
# game's handler, which returns here (ldmfd at 0x120, subs pc,lr,#4 at 0x124).
# Same role as after_interrupt (0x138) in gbarecomp's Nintendo config.
[[extra_func]]
addr = 0x00000120
mode = "arm"
name = "irq_after_handler"

# CpuSet dispatches through a 4-entry table right after
# 'ldr pc, [r4, r2, lsl #2]' at 0x250; the finder does not detect it.
[[jump_table]]
addr         = 0x00000254
stride       = 4
count        = 4
format       = "abs32"
entries_mode = "arm"
name         = "cpuset_fn_table"
```

### Coverage script

The static check from §3, step 4. It reads the BIOS image and the `bios_dispatch_table.cpp` that `gba_recompile` writes, and lists every required address that has no dispatch entry. It decodes ARM code only, so it fits Cult-of-GBA and A′ but not emibios, which has Thumb handlers. Python 3 standard library, no dependencies. Move it into `tools/` when the scaffold lands (§4 step 3).

Checked during the second review round, with gbarecomp `5e89943`'s `gba_recompile` and Cult-of-GBA `a30e9a9`:

- With the config above: 955 entries, `missing: 0`, exit status 0.
- With the same config minus the `[[extra_func]]` at 0x120: 953 entries, one miss (`0x00000120  add lr,pc at 0x118`), exit status 1.
- Command: `python3 -I bios_coverage.py bios.bin generated/bios/bios_dispatch_table.cpp --table 0x17C:43 --table 0x254:4 --end 0x2A28`.

```python
"""Static dispatch-coverage check for a recompiled ARM-only BIOS image (gbarecomp gba_recompile output).

usage: python3 -I bios_coverage.py <bios.bin> <bios_dispatch_table.cpp>
                                   --table ADDR:COUNT [--table ADDR:COUNT ...] --end ADDR

--table  a table of 32-bit code pointers the BIOS jumps through (SWI table, CpuSet table, ...)
--end    first address past the BIOS code, for the list of uncovered ranges
For Cult-of-GBA bios.bin SHA-1 2e41f9d3...: --table 0x17C:43 --table 0x254:4 --end 0x2A28.
Those addresses are valid for that image only; read them again from the source or a disassembly
for any other build.

Exit status 1 if any required address lacks a dispatch entry. Required addresses:
  - every table target
  - every b/bl target, and the return address of every bl
  - every return address an instruction sets up in lr:
    mov lr,pc / add lr,pc,#imm / sub lr,pc,#imm (adr lr) / ldr lr,[pc,#imm] (ldr lr,=label)
Only instructions at dispatch entries are decoded. With static_resume_all = true that is every
emitted instruction. Thumb code is not decoded: the script refuses a table with Thumb entries.
"""
import argparse
import re
import struct
import sys

ap = argparse.ArgumentParser()
ap.add_argument('bios')
ap.add_argument('dispatch_cpp')
ap.add_argument('--table', action='append', default=[], help='ADDR:COUNT')
ap.add_argument('--end', required=True)
args = ap.parse_args()

bios = open(args.bios, 'rb').read()
rows = re.findall(r'\{0x([0-9A-Fa-f]{8})u, ([01])u, [01]u,', open(args.dispatch_cpp).read())
if any(t == '1' for _, t in rows):
    sys.exit('Thumb entries present: this script only decodes ARM code')
entries = {int(a, 16) for a, _ in rows}
print('dispatch entries:', len(entries))


def word(a):
    return struct.unpack_from('<I', bios, a)[0]


def ror(v, r):
    return ((v >> r) | (v << (32 - r))) & 0xFFFFFFFF if r else v


def branch_target(a, w):
    off = w & 0xFFFFFF
    if off & 0x800000:
        off -= 1 << 24
    return (a + 8 + off * 4) & 0xFFFFFFFF


missing = []


def need(addr, why):
    if addr not in entries:
        missing.append((addr, why))


for spec in args.table:
    base, count = (int(x, 0) for x in spec.split(':'))
    for i in range(count):
        need(word(base + 4 * i) & ~1, f'table 0x{base:X} entry {i}')

for a in sorted(entries):
    w = word(a)
    if w >> 28 == 0xF:                        # unconditional space: not used by this BIOS
        continue
    if w & 0x0F000000 == 0x0B000000:          # bl
        need(a + 4, f'return of bl at 0x{a:X}')
        need(branch_target(a, w), f'bl target from 0x{a:X}')
    elif w & 0x0F000000 == 0x0A000000:        # b
        need(branch_target(a, w), f'b target from 0x{a:X}')
    elif w & 0x0FFFFFFF == 0x01A0E00F:        # mov lr, pc
        need(a + 8, f'mov lr,pc at 0x{a:X}')
    elif w & 0x0FEFF000 == 0x028FE000:        # add lr, pc, #imm
        need(a + 8 + ror(w & 0xFF, 2 * ((w >> 8) & 0xF)), f'add lr,pc at 0x{a:X}')
    elif w & 0x0FEFF000 == 0x024FE000:        # sub lr, pc, #imm
        need(a + 8 - ror(w & 0xFF, 2 * ((w >> 8) & 0xF)), f'sub lr,pc at 0x{a:X}')
    elif w & 0x0F7FF000 == 0x051FE000:        # ldr lr, [pc, #+-imm]
        lit = a + 8 + ((w & 0xFFF) if w & 0x00800000 else -(w & 0xFFF))
        need(word(lit) & ~1, f'ldr lr,=label at 0x{a:X}')

print('missing:', len(missing))
for addr, why in missing:
    print(f'  0x{addr:08X}  {why}')

end = int(args.end, 0)
holes, start = [], None
for a in range(0, end, 4):
    if a not in entries:
        start = a if start is None else start
    elif start is not None:
        holes.append((start, a))
        start = None
if start is not None:
    holes.append((start, end))
print(f'uncovered ranges below 0x{end:X} (check by hand: data, literal pools or missed code): {len(holes)}')
for s, e in holes:
    print(f'  0x{s:04X}-0x{e - 4:04X} ({(e - s) // 4} words) first word 0x{word(s):08X}')
sys.exit(1 if missing else 0)
```

## Sources

- gbarecomp at `5e89943528aee7bc1c399bdbd035364a4b41dd10`: `LICENSE`, `bios/README.md`, `bios/gba_bios.toml`, `PRINCIPLES.md`, `ENHANCEMENTS.md`, `docs/ARCHITECTURE.md`, `docs/TOML_SCHEMA.md`, `docs/ENGINE_HLE_DMA.md`, `TCP.md`, `CMakeLists.txt`, `src/gba/gba_bios.{h,cpp}`, `src/gba/gba_bus.{h,cpp}`, `src/runtime/{runtime.cpp,asset_picker.cpp,bios_hle.{h,cpp},runtime_bus_bridge.cpp,runtime_arm_default_aborts.cpp,launcher_seam.h,multiplayer_runner.cpp}`, `src/runtime/generated_bios/.gitignore`, `src/armv4t/runtime_arm.{h,cpp}`, `tools/gba_recompile/{main.cpp,config.cpp}`, `tools/import_bios_symbols/import_bios_symbols.py`, `packaging/web/{README.md,build_web.sh,bootstrap.js,asset_store.js,runtime_config.py}`, `THIRD_PARTY_ATTRIBUTION.md`
- Cult-of-GBA/BIOS at `a30e9a96df083628b650724b7d4d7112b4070b98`: `README.md`, `LICENSE`, `entrypoint.s`, `definition.s`, `bios_calls/` (`audio.s`, `cpu_set.s`, `power.s`, `register_ram_reset.s`, `math/{division,arctan,rotation_scaling}.s`, `decompression/{bitunpack,huffman,lz77,running_length}.s`), `boot_screen/boot_screen.s`, `make.sh`, `bios.bin`; the commit log and the diff from `1c75d9034534d2c5f508bd82822084b52ccc8d1d` to `a30e9a9`; [issues](https://github.com/Cult-of-GBA/BIOS/issues), especially [#9](https://github.com/Cult-of-GBA/BIOS/issues/9) with its comments, the [SWI CSV](https://pastebin.com/86Bw3Zjb) linked there, and the [mGBA A/B report](https://davidgfnet-cultgba-mgba-testing-1c75d903.netlify.app/) (fetched 2026-10-10, 49,919,395 bytes; we extracted the `Motoracer Advance.gba` row and its two frame-9000 screenshots with a script and compared them pixel by pixel)
- coolbho3k/emibios at `c4d5d7113ccbb56af5bf73839bf1c51f67936362`: `README.md`, `LICENSE`, `bios.sha256`, `build.zig`, `build.zig.zon`, `tools/gen/sine_lut.zig`, `tools/test_manifest.zig`, `src/` (`swi/math/{div,arc_tan}.s`, `swi/audio/midi_key2freq.s`), `tests/` (`README.md`, `math/swi_div_arm_test.zig`, `memory/{swi_cpu_fast_set_test,ram_perm}.zig`, `decompression/{swi_lz77_test,swi_rl_test,test_helpers}.zig`); [releases](https://github.com/coolbho3k/emibios/releases) and tag `0.1.6` (`1dcd0005a72fc5b9232a2b05a821b5e1d7850bb3`, release asset digest), via the GitHub API on 2026-10-10
- Nebuleon/ReGBA at `7f379052dc14366e622a96c7cf7fb6b5a7e918a3`: `README.md`, `bios/` (`Makefile`, `source/*`)
- Normmatt/gba_bios at `388c2f98ba7236de92bd9b5bca02a47f824abee3` (named without a link on purpose): `README.md`, `asm/bios.s` (a disassembly of Nintendo's BIOS, not a replacement)
- mGBA at `143adf5aa2a60c6036810b0cd72445e13d74b0e6`: `src/gba/hle-bios.s`, `src/gba/hle-bios.make`, `src/gba/bios.c`, `src/gba/memory.c`, `src/gba/core.c`, `src/gba/gba.c`, `src/core/config.c`; [mGBA 0.10.0 release notes](https://mgba.io/2022/10/11/mgba-0.10.0/)
- [GBATEK: GBA Unpredictable Things](https://problemkaputt.de/gbatek-gba-unpredictable-things.htm) (BIOS read protection), [GBATEK: BIOS Misc Functions](https://problemkaputt.de/gbatek-bios-misc-functions.htm) (GetBiosChecksum `BAAE187Fh`), [GBATEK: BIOS Arithmetic Functions](https://problemkaputt.de/gbatek-bios-arithmetic-functions.htm) (Div, ArcTan), [GBATEK: BIOS Memory Copy](https://problemkaputt.de/gbatek-bios-memory-copy.htm) (CpuFastSet), [GBATEK: BIOS Halt Functions](https://problemkaputt.de/gbatek-bios-halt-functions.htm) (IntrWait)
- [PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0) (canonical text, Notices section)
- [GBARunner2 wiki: GBA BIOS Info](https://wiki.ds-homebrew.com/gbarunner2/bios); GBARunner2 `readme.md` at `6e4ce456597cabaaa45aac83bbd2f4c90580dca8`
- Users of the replacement BIOSes: SkyEmu `ACKNOWLEDGMENTS.md` and `src/gba_bios.h` at `c3b0b56aed427b35188db30243ee74e52c1f9456`; FBNeo `src/burn/drv/gba/gbabios.h` at `e8f21da9ec5aaef94892716fcd84bca5e7f5563a`; crab `README.md` at `2d58e8233ad084afec772142d0148e2a853af57f`; NooDS `README.md` at `4cb1439c330248b26cdf5f8dbcfa4e5ac53dcda0`; eggvance `README.md` at `73dcb0b497e15cf546c3d69f1cceaad6cb570e26`; NanoBoyAdvance `README.md` at `55b5cf0ae3d929582ac5bfd486558173502b8354`
- This repository: [PR #2](https://github.com/nvergez/moto-racer-advanced-browser/pull/2) `docs/research/gbarecomp-integration.md` (Summary item 5, §9 layout), at its head on 2026-10-10
- Repository metadata (stars, dates, licenses, issue lists, tags, release assets): GitHub REST API, queried 2026-10-10

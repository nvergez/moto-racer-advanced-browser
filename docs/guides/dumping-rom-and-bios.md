# Dumping the ROM and the GBA BIOS from your own hardware

**Researched:** 2026-10-10. Nobody on the project has dumped this cartridge yet, so none of these procedures has been tested with it. Prices are what vendor pages listed on that date, except where a different date is given.

The project needs two files, and both must come from hardware you own:

| File | Where it goes | Comes from |
|---|---|---|
| Moto Racer Advance ROM | `roms/moto-racer-advance.gba` | Your cartridge, read with a cartridge reader |
| GBA BIOS (16384 bytes) | `bios/gba_bios.bin` | Your Game Boy Advance console, read by a small homebrew program running on it |

The BIOS is built into the console, not the cartridge. A cartridge reader alone can't produce it.

## Short version: what to order

| You already own | Order |
|---|---|
| Only the cartridge | 1. GBxCart RW (cartridge reader, ROM dump)<br>2. A writable GBA flash cart whose save memory keeps data with the power off: **FRAM, or battery-backed SRAM with a working battery** (runs the BIOS dumper)<br>3. A used GBA, GBA SP or GBA Micro (runs the BIOS dumper) |
| Cartridge + a GBA, GBA SP, GBA Micro or Game Boy Player | Items 1 and 2 |
| Cartridge + DS, DS Lite or 3DS only | Items 1, 2 and 3. A DS-family console produces a different BIOS file (see [Part 2](#which-console-the-bios-must-come-from)) |
| Cartridge + GBA + a Wii, or a GameCube with an SD Gecko, that runs homebrew + a GameCube–GBA link cable | Nothing: [gba-link-cable-dumper](#alternative-gamecube-or-wii-over-the-link-cable) dumps both files. Its own estimate for this 4 MiB ROM is about 6 minutes |

Recommended items, with what the vendor pages said on 2026-10-10:

1. **[GBxCart RW](https://www.gbxcart.com/)** by insideGadgets: "Just $33 plus shipping (when purchasing direct)". The page also lists resellers (Retro Game Repair Shop, ZedLabz, RetroModding, ModInFrance), which may ship faster to you. It reads GB, GBC and GBA cartridges and is driven on macOS by [FlashGBX](https://github.com/Lesserkuma/FlashGBX). The vendor says it's "Supported on Windows, Mac and Linux" and adds: "We highly recommend Windows for the best out of box experience." On a Mac, the FlashGBX app needs macOS Sequoia 15 or newer ([FlashGBX README L327](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/README.md?plain=1#L327)). On older macOS, run FlashGBX from Python instead ([CLI section below](#recommended-procedure-gbxcart-rw--flashgbx-on-macos)); we haven't tested that route on older macOS (**unverified**).
2. **A flash cart for the BIOS dumper.** Its save memory must survive a power-off: **FRAM, or battery-backed SRAM with a working battery**. Avoid reproduction carts that have SRAM but no battery, which FlashGBX's README says exist ([L386](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/README.md?plain=1#L386)). bios-dump passes its SRAM test on such a cart and prints "Done dumping!", but the BIOS is lost when you power off to read it back ([details](#how-the-dumpers-work)). One of:
   - **insideGadgets "GBA 32MB, 256Kbit FRAM Save, Flash Cart"**, the **No Rumble** variant ([shop page](https://shop.insidegadgets.com/product/gba-32mb-256kbit-fram-save-flash-cart/)). This is the cheapest known-compatible option, because the GBxCart RW you're already buying writes to it ([FlashGBX README L150](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/README.md?plain=1#L150) lists "insideGadgets 32 MiB, 256K FRAM with Rumble option"). The live shop blocks automated requests (HTTP 403), so we read the Internet Archive's Wayback Machine snapshot of the same URL dated 2026-05-08 (timestamp `20260508182251`). It lists "No Rumble (Green PCB)" at $37 and "Rumble enabled (Green PCB)" at $42, both "Out of stock", and says "Restocks every 1-2 weeks." and "Includes a generic clear reproduction GBA cart shell (separately)". It also says "Need to flash a game on this cart? Make sure to grab our GBxCart Flasher." Rumble isn't needed here. Today's price and stock are **unverified**. If it's out of stock, the EverDrive below is the fallback.
   - **An SD-card flash cart** such as the [EverDrive GBA Mini](https://krikzz.com/our-products/cartridges/everdrive-gba-mini.html) ($99, "1Mbit SRAM (128KByte) save memory", "Supported with GameCube player"). It costs more, needs no writing step, and is useful later for running test programs on real hardware. Some SD carts copy the save to the SD card only at the next boot, which needs the save memory to survive the power-off in between ([details](#alternative-an-sd-flash-cart)). The EverDrive page doesn't say whether it has a battery (**unverified**).
3. **A GBA-family console**: GBA (AGB-001), GBA SP (AGS-001/AGS-101), GBA Micro (OXY-001) or the GameCube Game Boy Player (DOL-017). **Not** a DS, DS Lite, 3DS or 2DS, and not a DSi, which has no GBA slot at all.
4. Isopropyl alcohol (99%+) and cotton swabs for cleaning cartridge contacts ([FlashGBX README, Troubleshooting](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/README.md?plain=1#L370)).

## Ground rules

- **Dump from hardware you own. Downloading a ROM or BIOS image is not an acceptable substitute for this project**, even if you own the cartridge. Don't ask for, link to, or accept such files. This doc names no download sites, and nothing in the repo may.
- **Never commit, upload or share the dumps**, including saves and anything derived from them. The paths below are gitignored, but `git add -f` overrides that. Keep a private backup outside the repo.
- Keep the dumps unmodified: no trimming, header fixing or patching. gbarecomp's web page rejects a ROM whose SHA-1 differs from the one the build expects ("Wrong ROM: its SHA-1 is …", [`packaging/web/asset_store.js` L30](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/packaging/web/asset_store.js#L30) at gbarecomp `5e89943`).

## Before you start

Run this guide's commands from the root of your clone of this repo, and create the two output directories first. They are gitignored, so a fresh clone doesn't have them. Without them, `head … > bios/gba_bios.bin` fails with "no such file or directory", and FlashGBX's CLI backups stop with a misleading "Couldn't find file" (it opens the target with `open(path, "ab+")` and never creates directories, `FlashGBX/FlashGBX_CLI.py` L984–L991 and L1380–L1390 at FlashGBX `2d9682c`).

```sh
cd /path/to/moto-racer-advanced-browser   # your clone of this repo
mkdir -p roms bios
```

Keep third-party code outside the repo: the bios-dump clone (Part 2) and any FlashGBX Python virtual environment (Part 1). Neither a `bios-dump/` nor a `FlashGBX/` directory is gitignored.

---

## Part 1: The cartridge ROM

### Options compared

| Option | Hardware and price (2026-10-10) | macOS | Dump verification | Can write flash carts (needed for the BIOS route) | Verdict |
|---|---|---|---|---|---|
| **GBxCart RW + FlashGBX** | [GBxCart RW](https://www.gbxcart.com/), $33 + shipping | FlashGBX ships `FlashGBX-5.1_macOS-arm64.dmg` (release 5.1, 2026-08-29). README requires "Sequoia 15 or newer" ([README](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/README.md?plain=1#L327)). The vendor recommends Windows (see above) | Built-in database (partly based on No-Intro) checks the ROM's CRC32 and supplies ROM size and save type | Yes | **Recommended** |
| **Joey Jr + FlashGBX** | [BennVenn Joey Jr](https://bennvenn.myshopify.com/collections/game-cart-to-pc-interface/products/usb-gb-c-cart-dumper-the-joey-jr), $42. "USB-C cable is required and not included." Shop banner: orders resume shipping on 16 October 2026 | Shop page: "Mac users please use FlashGBX software with the Joey Jr". FlashGBX README: on macOS, run the [Joey Jr Firmware Updater](https://github.com/Lesserkuma/JoeyJr_FWUpdater) first or FlashGBX won't find the device | Same as above | Yes (FlashGBX) | Good alternative |
| **GBFlash + FlashGBX** | [GBFlash](https://github.com/simonkwng/GBFlash) ("a rapid burner for GB/GBA flash cards"). README doesn't say where to buy it | Through FlashGBX | Same as above | Yes | Fine if you can find one |
| **Epilogue GB Operator + Playback** | [GB Operator](https://www.epilogue.co/product/gb-operator), $49.99 incl. VAT, USB-C. Product page: "Ships on October 30th" | Playback for "macOS 12.0 or later", "Intel Core i5 or Apple M1" ([downloads](https://www.epilogue.co/downloads)) | "Counterfeit cartridge detection" ([What is Playback?](https://www.epilogue.co/support/getting-started/what-is-playback)). We found no documented check against a dump database | Yes, per Epilogue: Playback's Data mode has "Upload Homebrew: Write games to flashcarts" ([What is Playback?](https://www.epilogue.co/support/getting-started/what-is-playback)). Its [Flashcart Support](https://www.epilogue.co/support/hardware/flashcart-support) page names no supported GBA models, and says SD game loaders such as EverDrive and EZ-Flash Omega are not supported. Not supported by FlashGBX | Fine for the ROM. For the BIOS route, writing bios-dump to the insideGadgets FRAM cart and backing up its save is **unverified** |
| **DS or DS Lite + Slot-1 flash cart + [GodMode9i](https://github.com/DS-Homebrew/GodMode9i)** | Only if you already own them | Not needed; the dump lands on the flash cart's SD card | None built in; check the hash yourself | No | Only if you already own the hardware |
| **GBA + Wii, or GameCube with SD Gecko, + link cable + [gba-link-cable-dumper](https://github.com/FIX94/gba-link-cable-dumper)** | Only if you already own them | Not needed; files land on the Wii/GameCube SD card | None built in | No | About 6 minutes for this ROM, and dumps the BIOS too |

FlashGBX also supports [Game Bub](https://gamebub.net/) (added in FlashGBX 5.0).

### Recommended procedure: GBxCart RW + FlashGBX on macOS

Sources: [FlashGBX README](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/README.md) and the FlashGBX source at commit `2d9682c` (button labels in `FlashGBX/FlashGBX_GUI.py`, CLI flags in `FlashGBX/FlashGBX.py`).

1. **Install FlashGBX.** Download `FlashGBX-5.1_macOS-arm64.dmg` from [FlashGBX Releases](https://github.com/Lesserkuma/FlashGBX/releases) and copy the app to Applications. The app isn't signed with an Apple Developer certificate. If macOS refuses to open it, the README's fix is to remove the quarantine flag:
   ```sh
   xattr -d com.apple.quarantine /Applications/FlashGBX.app
   ```
   The README lists no driver install for macOS.
2. **Clean the cartridge contacts** with 99%+ isopropyl alcohol on a cotton swab and let them dry. The README calls an unstable connection "the most common reason for read or write errors".
3. **Insert the cartridge** into the GBxCart RW's GBA slot. To be safe, do this while the device is unplugged, then connect it over USB.
4. In FlashGBX, click **Connect**, select **Game Boy Advance**, then click **Refresh** to read the header. The platform buttons stay disabled until you connect (`FlashGBX/FlashGBX_GUI.py` L340–L341 and L1416–L1424). Check:
   - Boot logo and header checksum show as valid.
   - The game code is **A9ME** (USA) or **A9MP** (Europe). These are the two Moto Racer Advance entries in FlashGBX's database ([`db_AGB.json` L2619–L2640](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/FlashGBX/config/db_AGB.json#L2619-L2640)).
   - ROM size shows **4 MiB** and save type **256K SRAM/FRAM**. Both entries list `"rs": 4194304` and save type 3, which `FlashGBX/CartridgeTypes.py` maps to "256K SRAM/FRAM" (32 KiB). The save type is **unverified** against the cartridge itself; Phase 1 confirms it in [`docs/research/game-facts.md`](../research/game-facts.md).
5. **Back up the save first** with **Backup Save Data**. It's your progress, and if the board has a battery, a cartridge this old may have a weak one. Store it as `roms/moto-racer-advance.sav` (ignored by git).
6. Click **Backup ROM** and save to `roms/moto-racer-advance.gba` in the repo.
7. Wait for "The ROM backup is complete and the checksum was verified successfully!". For a GBA cartridge, this means the dump's CRC32 matches FlashGBX's database entry (`FlashGBX/FlashGBX_GUI.py` L1754–L1758). The other outcomes:
   - "…the checksum doesn't match the known database entry": clean and reseat the cartridge, dump again, and compare the two SHA-1s. Two identical dumps that still don't match the database point to an unknown revision or a non-genuine cartridge (see [Part 5](#part-5-buying-a-used-cartridge)).
   - "A data loop was detected…": usually an overdump (wrong ROM size) or a bad read.
8. Optionally, turn on ROM dump reports: **Options → Settings → Always generate ROM dump reports** (`FlashGBX_GUI.py` L667 and L674; CLI `--generate-dump-report`). Without that setting, the message box after a backup has a **Generate Dump Report** button. The report records the dump's details for `docs/research/`. Its "Save Type" line includes the save library string read from the ROM, such as `SRAM_V…` or `SRAM_F_V…` (`FlashGBX/DumpReport.py` L231 and L241), which [Part 5](#part-5-buying-a-used-cartridge) uses.

If you prefer the CLI, install FlashGBX in a Python virtual environment as the README describes ([Run via Python](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/README.md?plain=1#L336-L349)), but create it outside the repo. The README's `python3 -m venv FlashGBX` would create a `FlashGBX/` directory in the current directory, which git doesn't ignore.

```sh
python3 -m venv ~/.venvs/flashgbx
source ~/.venvs/flashgbx/bin/activate
python3 -m pip install "FlashGBX[qt6]"      # the README also has a get-pip.py step if pip is missing

cd /path/to/moto-racer-advanced-browser     # back to the repo root, where roms/ exists
python3 -m FlashGBX --cli --mode agb --action info
python3 -m FlashGBX --cli --mode agb --action backup-save --agb-savetype sram256k roms/moto-racer-advance.sav
python3 -m FlashGBX --cli --mode agb --action backup-rom --generate-dump-report roms/moto-racer-advance.gba
```

Add `--agb-romsize 4mb` only if FlashGBX fails to match the cartridge in its database. Without a match it falls back to a detected size or 32 MiB (`FlashGBX/FlashGBX_CLI.py`), and an overdump has the wrong hash.

### ROM gotchas

- **ROM size.** The GBA cartridge header has no ROM-size field ([GBATEK, "GBA Cartridge Header"](https://problemkaputt.de/gbatek.htm#gbacartridgeheader)), so dumpers take it from a database (FlashGBX) or probe for the end of the ROM (GodMode9i reads past the end looking for the open-bus pattern, up to 32 MiB: `arm9/source/dumpOperations.cpp` at [`57c6ed9`](https://github.com/DS-Homebrew/GodMode9i/blob/57c6ed9a973376778eef06ea0a4a7a9edf5627a5/arm9/source/dumpOperations.cpp)). A good dump of either known release is 4,194,304 bytes, per FlashGBX's database.
- **Save type.** It only matters for the save backup, not the ROM. If FlashGBX shows anything other than 256K SRAM/FRAM, or "No database entry", be suspicious of the cartridge.
- **Contacts.** Clean them before suspecting anything else. Reseat the cartridge, and try another cable or USB port (FlashGBX README).
- **Hot-plugging.** Don't insert or remove the cartridge while the reader is powered.
- **Dump twice.** Matching SHA-1s across two dumps rule out a flaky read.

### Alternatives in brief

- **Joey Jr**: same FlashGBX workflow after the firmware update. The shop page warns against its drag-and-drop firmware on macOS, which "will write dozens of hidden files, confusing and potentially corrupting save files on your cart".
- **GB Operator**: in Playback, open **Data** and use **Backup Game** and **Backup Save** ([What is Playback?](https://www.epilogue.co/support/getting-started/what-is-playback); [Seth Larson, 2024-05-06](https://sethmlarson.dev/backup-game-boy-roms-and-saves-on-ubuntu) shows the same workflow). Epilogue says the backups "are compatible with popular emulators" but doesn't say the file is an untrimmed, unmodified dump, so check the SHA-1 yourself afterwards.
- **DS or DS Lite with GodMode9i**: the README says it can "Dump Game Boy Advance cartridges on the original Nintendo DS and Nintendo DS Lite consoles". You run it from a DS-mode Slot-1 flash cart, with Moto Racer Advance in Slot-2. Output is `gm9i/out/<TITLE>_<GAMECODE><MAKER>_<REV>.gba` on the SD card: the header title, then 6 header bytes from `0xAC` (the 4-character game code and the 2-character maker code), then the revision (`dumpOperations.cpp` L1180–L1181 and L1204). The save is dumped too. This is a good ROM route, but a DS can't give you the right BIOS.
- **GameCube or Wii link cable**: see [below](#alternative-gamecube-or-wii-over-the-link-cable). It dumps the ROM, save and BIOS. The tool estimates 1.5 minutes per MiB (`gbasize/1024/1024*3/2` with the size in bytes, [`source/main.c` L352](https://github.com/FIX94/gba-link-cable-dumper/blob/d8c06b3dea345b80920b7609b5be7baa54c2fb63/source/main.c#L352)), so the README's "32mb takes about 48 minutes" means 32 MiB. For this 4 MiB ROM, that's about 6 minutes.

---

## Part 2: The GBA BIOS

### Which console the BIOS must come from

The GBA family and the DS family carry two different 16 KiB GBA BIOS images. [mgba-emu/bios-dump README](https://github.com/mgba-emu/bios-dump/blob/7cffabaf7da18f18efc9c2712657eeef10abfdad/README) (commit `7cffaba`) lists:

| Consoles | BIOS checksum (internal) | SHA-256 |
|---|---|---|
| GBA (AGB-001), GBA SP (AGS-001, AGS-101), GBA Micro (OXY-001), Game Boy Player (DOL-017) | `BAAE187F` | `fd2547724b505f487e6dcb29ec2ecff3af35a841a77ab2e85fd87350abd36570` |
| DS (NTR-001), DS Lite (USG-001), 3DS (CTR-001), 3DS XL (SPR-001), 2DS (FTR-001), New 3DS (KTR-001), New 3DS XL (RED-001), New 2DS XL (JAN-001) | `BAAE1880` | `782eb3894237ec6aa411b78ffee19078bacf10413856d33cda10b44fd9c2856b` |

mGBA recognizes both, as "Official GBA BIOS" and "Official GBA (DS) BIOS" (`GBA_BIOS_CHECKSUM` and `GBA_DS_BIOS_CHECKSUM` in [`include/mgba/internal/gba/bios.h` L15–L16](https://github.com/mgba-emu/mgba/blob/143adf5aa2a60c6036810b0cd72445e13d74b0e6/include/mgba/internal/gba/bios.h#L15-L16)). The internal checksum is the sum of the image's 32-bit little-endian words (`GBAChecksum` in [`src/gba/bios.c` L619–L626](https://github.com/mgba-emu/mgba/blob/143adf5aa2a60c6036810b0cd72445e13d74b0e6/src/gba/bios.c#L619-L626)), so you can check it on your own file ([Part 3](#part-3-verify)).

gbarecomp expects SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492`, MD5 `a860e8c0b6d573d191e4ec7db1b1e4f6`, 16384 bytes ([`bios/README.md`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/bios/README.md) and [`src/gba/gba_bios.h` L25–L26](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/gba/gba_bios.h#L25-L26) at `5e89943`). libretro-database lists the same size, MD5 and SHA-1 for `gba_bios.bin` ([`dat/System.dat` L265](https://github.com/libretro/libretro-database/blob/bf825e3ec48d43557ad024da6a7b93e512043525/dat/System.dat#L265)). No source we found lists that SHA-1 next to one of the SHA-256s above, so **we infer** that it is the GBA-family image: gbarecomp's BIOS HLE reports the GBA-family checksum (`GBA_BIOS_CHECKSUM = 0xBAAE187Fu`, [`src/runtime/bios_hle.cpp` L87](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/runtime/bios_hle.cpp#L87)). Your own dump settles it: if it passes the SHA-1 check and its internal checksum is `BAAE187F` (Part 3), they are the same image.

How gbarecomp uses the BIOS at `5e89943`:

- **By default, the BIOS is recompiled when the port is built.** `gba_recompile --bios <path>` translates the BIOS into C++ (`bios_recompiled.cpp` and `bios_dispatch_table.cpp`, written to `src/runtime/generated_bios` unless `--out` says otherwise; [`tools/gba_recompile/main.cpp` L162–L221](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/tools/gba_recompile/main.cpp#L162-L221)). The runtime links that output when it exists ([`CMakeLists.txt` L415–L449](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/CMakeLists.txt#L415-L449)), and the browser build stops without it ("missing generated BIOS", [`packaging/web/build_web.sh` L174–L175](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/packaging/web/build_web.sh#L174-L175)). So whoever builds the port needs a BIOS dump at build time, and the BIOS code a player runs is the code translated then.
- **An opt-in high-level emulation (HLE) of BIOS calls exists.** `[bios].hle = true` in the game config, `--bios-hle`, or the `GBARECOMP_BIOS_HLE` environment variable turn it on. Calls it doesn't implement fall through to the recompiled BIOS ([`src/runtime/bios_hle.h` L6–L21](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/runtime/bios_hle.h#L6-L21); `src/runtime/runtime.cpp` L1104–L1113). When no recompiled BIOS is linked, the runtime switches to "BIOS HLE boot" on its own (`runtime.cpp` L1566–L1572). gbarecomp's `CLAUDE.md` ("not stubbed, not HLE'd") and `bios/README.md` ("We do **not** HLE SWIs") predate this code.
- **A BIOS file is still required when the game runs, HLE or not.** The native runtime takes its path from the command line, then a cached `bios.cfg`, then a Windows file dialog (`runtime.cpp` L1383–L1409). A wrong size is an error, and a wrong hash is only a warning (`src/runtime/asset_picker.cpp` L141–L173). It then loads the file (`runtime.cpp` L1460) and maps it into the emulated bus (`bus.set_bios`, L1551). The web page requires exactly 16384 bytes and also only warns on a hash mismatch ("…is not the expected …; trying it anyway", `packaging/web/asset_store.js` L35–L37).
- `src/runtime/launcher_seam.h` L78 and netplay (`runtime.cpp` L1493–L1496: "netplay requires this build's original ROM and retail BIOS") require the exact hash.
- `bios/README.md` L29 says "The runtime refuses to start with a BIOS whose hash isn't recognized", which contradicts the warning-only code above.

A DS-family dump might run with a warning, but nobody has validated it, and gbarecomp's BIOS symbol map was built against the canonical image (`tools/import_bios_symbols/import_bios_symbols.py`). Whether it behaves correctly, as the file loaded at run time or as the input to `gba_recompile --bios`, is **unverified**. **Dump from a GBA-family console.**

### How the dumpers work

The BIOS can only be read while the CPU is executing inside it. Otherwise a read "will return the most recent successfully fetched BIOS opcode" ([GBATEK, "GBA Unpredictable Things"](https://problemkaputt.de/gbatek.htm#gbaunpredictablethings)). [mgba-emu/bios-dump](https://github.com/mgba-emu/bios-dump) (MIT) "dumps the GBA BIOS by jumping directly into the CpuFastSet routine in the BIOS, bypassing the region check, and then copying the BIOS into a flashcart's SRAM". In [`src/bios-dump.c`](https://github.com/mgba-emu/bios-dump/blob/7cffabaf7da18f18efc9c2712657eeef10abfdad/src/bios-dump.c), the program:

- embeds the string `SRAM_V123`, so flash carts and save tools treat it as an SRAM game;
- writes `0x55` to SRAM and reads it back (L122–L126), and stops with "Fatal SRAM error!" if the cartridge has no writable SRAM (an EEPROM- or flash-save cart won't work). The test runs while the cart is powered, so it can't tell whether the save survives a power-off;
- prints the BIOS's own checksum with "CPU AGB" or "CPU NTR";
- copies the 16 KiB image byte by byte to the start of SRAM (`0x0E000000`, libgba's `SRAM` in `gba_base.h`, L156–L160), prints "Done dumping!", then prints the SHA-256 with "CPU AGB", "CPU NTR" or "CPU ???". The SHA-256 is computed from the copy in work RAM (the `out` buffer, L13 and L102), not from SRAM. **A correct SHA-256 on screen doesn't prove the save holds the BIOS.**

So the BIOS is **the first 16384 bytes of the save file**, provided the save survives until you read it back. The community `Bios_Shrinker.py` (GlaZedBelmont/Random-Stuff release 0.0.6) does the same thing: it reads the first `0x4000` bytes. On macOS, from the repo root:

```sh
head -c 16384 bios/bios-dump.sav > bios/gba_bios.bin
```

### Methods compared

| Method | Hardware | BIOS you get | Source | Status |
|---|---|---|---|---|
| **bios-dump on a writable flash cart with FRAM or battery-backed SRAM, written and read back with GBxCart RW** | GBA-family console + GBxCart RW + e.g. insideGadgets 256Kbit FRAM flash cart | GBA (correct) | bios-dump README and source; FlashGBX README (cart support) | **Recommended.** This exact combination is untested by us |
| **bios-dump on an SD flash cart** | GBA-family console + SD flash cart with SRAM saves (EverDrive GBA, EZ-Flash Omega, etc.). If the cart copies the save to SD only at the next boot, its save memory must survive the power-off | GBA (correct) | bios-dump README; [DS-Homebrew wiki, "GBA BIOS Dumping"](https://wiki.ds-homebrew.com/gbarunner2/bios-dump), method 2 | Documented |
| **gba-link-cable-dumper (FIX94)** | GBA-family console + GameCube (with SD Gecko) or Wii with GameCube ports, running homebrew + GameCube controller + GameCube–GBA link cable | GBA (correct) | [README](https://github.com/FIX94/gba-link-cable-dumper/blob/d8c06b3dea345b80920b7609b5be7baa54c2fb63/README.md) ("GBA BIOS Dumper by Dark Fader"); `source/main.c` writes `/dumps/gba_bios.bin` (`0x4000` bytes) | Documented. Release v1.6 is from 2016 |
| **DS or DS Lite in GBA mode, Slot-2 flash cart** | DS / DS Lite + Slot-2 flash cart | **DS variant (wrong hash)** | bios-dump README (NTR-001, USG-001); DS-Homebrew wiki, method 2 | Works, wrong file for us |
| **3DS with custom firmware + open_agb_firm** | 3DS family with Luma3DS | **DS variant (wrong hash)** | bios-dump README (CTR, KTR, …); DS-Homebrew wiki, method 1; [open_agb_firm](https://github.com/profi200/open_agb_firm) | Works, wrong file for us |
| **Multiboot from a Mac over the link port** | GBA-family console + DIY RP2040 cable ([loopj/gba-multiboot-pico](https://github.com/loopj/gba-multiboot-pico), needs a sacrificial link cable and a multimeter) + a cartridge with writable SRAM in the slot | GBA (correct) | bios-dump would need a multiboot build (`TARGET` ending in `_mb`, per its Makefile comment). Using the Moto Racer cart's own SRAM would overwrite your save | **Unverified.** We found no end-to-end write-up. Not worth the time |
| **Any cartridge reader alone** (GBxCart RW, GB Operator, Joey Jr) | – | – | The BIOS is in the console. FlashGBX's README has no BIOS feature | Not possible |
| **DSi / DSi XL** | – | – | No GBA slot. bios-dump's table doesn't list them, and GodMode9i's GBA dumping is DS/DS Lite only | Not possible |

A prebuilt `Bios_Dumper.gba` (GlaZedBelmont/Random-Stuff release 0.0.5, February 2020) is what the DS-Homebrew wiki links to. That release has no source code and no notes, so what the binary contains is **unverified**. Build mgba-emu/bios-dump from source instead (below). Once the Docker image is pulled, the build takes seconds.

### Recommended procedure: bios-dump via a FRAM flash cart and GBxCart RW

You need a GBA-family console, the GBxCart RW, a FlashGBX-supported GBA flash cart with **FRAM or battery-backed SRAM** (e.g. the insideGadgets 256Kbit FRAM cart), and Docker. Do [Before you start](#before-you-start) first.

1. **Build `bios-dump.gba` outside the repo**, for example in `~/src`. We verified this on 2026-10-10 on an Apple M4 Pro with Docker 29.6.2. The `devkitpro/devkitarm` image has an arm64 build, and this produced a 131072-byte `bios-dump.gba` containing `SRAM_V123`:
   ```sh
   mkdir -p ~/src && cd ~/src
   git clone https://github.com/mgba-emu/bios-dump.git
   cd bios-dump
   git checkout 7cffabaf7da18f18efc9c2712657eeef10abfdad
   docker run --rm -v "$PWD":/src -w /src devkitpro/devkitarm:20260610 make
   ```
   The result is `~/src/bios-dump/bios-dump.gba`. devkitPro also distributes a native macOS toolchain, which we didn't try (**unverified** on Apple Silicon).
2. **Write it to the flash cart.** Put the flash cart in the GBxCart RW. In FlashGBX, click **Connect**, select **Game Boy Advance**, then click **Write ROM** and pick `~/src/bios-dump/bios-dump.gba`. FlashGBX auto-detects many flash carts, and the insideGadgets FRAM cart is on its supported list.
3. **Run it on the GBA-family console.** Power on with the flash cart inserted. Expected screen output: `BIOS Checksum: BAAE187F`, `CPU AGB`, `Done dumping!`, then `SHA256: fd2547724b50…` and `CPU AGB`.
   - `CPU NTR`: you're on a DS-family console. Use a GBA, SP, Micro or Game Boy Player.
   - `Fatal SRAM error!`: the cart has no writable SRAM. Use an FRAM or battery-backed SRAM cart.
4. **Read the save back.** Power off and move the flash cart to the GBxCart RW. For flash and reproduction carts, the FlashGBX README says to run "Analyze Flash Cart" before backing up save data. Then use **Backup Save Data**. If the save type isn't detected, pick **256K SRAM/FRAM** (CLI: `--agb-savetype sram256k`). Save it as `bios/bios-dump.sav` in the repo, which git ignores through `bios/`. You get a 32 KiB file.
5. **Extract and verify**, from the repo root:
   ```sh
   head -c 16384 bios/bios-dump.sav > bios/gba_bios.bin
   echo "300c20df6731a33952ded8c436f7f186d25d3492  bios/gba_bios.bin" | shasum -a 1 -c
   ```
   `bios/bios-dump.sav` can stay where it is (ignored) or be deleted.

**If the console showed `CPU AGB` and the right SHA-256, but the SHA-1 check fails:** the cart probably didn't keep its save through the power-off (no battery, a dead battery, or SRAM that isn't battery-backed), or the save was read back with the wrong save type. The on-screen SHA-256 comes from work RAM, not from the save. Re-read the save as 256K SRAM/FRAM. If it still fails, use an FRAM cart.

### Alternative: an SD flash cart

1. Build `bios-dump.gba` as above and copy it to the flash cart's SD card.
2. Boot the cart on a GBA-family console, launch `bios-dump.gba`, and wait for `Done dumping!` and `CPU AGB`.
3. Get the save written to the SD card. When this happens depends on the cart: some copy the save to SD right away, others at the next boot into the menu. To be safe, power off, boot back into the cart's menu, and wait a few seconds before removing the SD card. A cart that copies at the next boot needs its save memory to survive the power-off, which normally means a working battery. This is **unverified** per cart; check your cart's manual.
4. Copy the `.sav` to `bios/bios-dump.sav` in the repo and run the `head -c 16384` step above. The troubleshooting note above applies here too.

### Alternative: GameCube or Wii over the link cable

From the [gba-link-cable-dumper README](https://github.com/FIX94/gba-link-cable-dumper/blob/d8c06b3dea345b80920b7609b5be7baa54c2fb63/README.md): start the matching `.dol` on a GameCube (SD Gecko) or Wii, with a GameCube controller in port 1 and the GameCube–GBA link cable in port 2. Boot the GBA **without a cartridge** and the dumper loads over the cable. Choose the BIOS backup ("Press Y to backup the GBA BIOS", `source/main.c`). The file is written as `dumps/gba_bios.bin` on the console's SD card or USB drive. The same tool also dumps the ROM (about 6 minutes for this game, by its own estimate) and the save once you insert the cartridge. If the GBA resets at that step, the README says to boot with the cartridge in while holding Start+Select. You need homebrew running on the Wii or GameCube already; setting that up is outside this guide.

---

## Part 3: Verify

Use the stock macOS tools (checked on macOS 26.5), from the repo root:

```sh
# BIOS: must be exactly 16384 bytes with this SHA-1 (gbarecomp bios/README.md, libretro System.dat)
stat -f %z bios/gba_bios.bin
echo "300c20df6731a33952ded8c436f7f186d25d3492  bios/gba_bios.bin" | shasum -a 1 -c

# Optional cross-checks
md5 bios/gba_bios.bin             # a860e8c0b6d573d191e4ec7db1b1e4f6 (gbarecomp bios/README.md, libretro System.dat)
shasum -a 256 bios/gba_bios.bin   # GBA family: fd2547724b505f487e6dcb29ec2ecff3af35a841a77ab2e85fd87350abd36570 (bios-dump README)
python3 -c 'import struct,sys; d=open(sys.argv[1],"rb").read(); print("%08X" % (sum(struct.unpack("<4096I", d)) & 0xFFFFFFFF))' bios/gba_bios.bin
                                  # internal checksum. GBA family: BAAE187F (bios-dump README, mGBA)

# ROM
stat -f %z roms/moto-racer-advance.gba     # 4194304 for both known releases (FlashGBX database)
crc32 roms/moto-racer-advance.gba          # 2fdbe7a8 (USA, A9ME) or 8cb19da0 (Europe, A9MP), FlashGBX database
shasum -a 1 roms/moto-racer-advance.gba
```

- **BIOS.** `shasum -c` prints `OK` or `FAILED`. A SHA-256 of `782eb389…856b` or an internal checksum of `BAAE1880` means a DS-family BIOS: redo the dump on a GBA-family console. Any other value means a bad dump or a non-retail BIOS: rerun the dumper, and see the troubleshooting note in Part 2. The SHA-256 and internal-checksum lines compare your file against the bios-dump README's GBA-family row. If the SHA-1 passes but either of them doesn't match, report it: it would break the inference in [Part 2](#which-console-the-bios-must-come-from).
- **ROM.** Compare the SHA-1 with the per-region hashes in [`docs/research/game-facts.md`](../research/game-facts.md). This guide doesn't repeat them, so that file stays the single source. A check that doesn't depend on that file is the CRC32: FlashGBX's "checksum was verified successfully" message (Part 1, step 7) and the `crc32` line above both compare against FlashGBX's database (`"rc": 802940840` = `0x2FDBE7A8` for USA and `"rc": 2360450464` = `0x8CB19DA0` for Europe, [`db_AGB.json` L2623 and L2634](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/FlashGBX/config/db_AGB.json#L2619-L2640)). CRC32 catches bad reads but isn't a cryptographic hash, so the SHA-1 comparison is still needed. A dump that matches no known hash is either a bad read (dump again) or a non-genuine or unknown cartridge. Report it either way; don't use it.
- Once both files match, record the ROM's SHA-1 and region in `docs/research/` as `CLAUDE.md` requires. Record only hashes, never file contents.

## Part 4: Where to put the files

```
roms/moto-racer-advance.gba   # the cartridge ROM
roms/moto-racer-advance.sav   # optional: your cartridge save backup
bios/gba_bios.bin             # the GBA BIOS
bios/bios-dump.sav            # optional: the bios-dump save it came from
```

You created both directories in [Before you start](#before-you-start). Both are gitignored, as checked on 2026-10-10:

```console
$ git check-ignore -v roms/moto-racer-advance.gba roms/moto-racer-advance.sav bios/gba_bios.bin bios/bios-dump.sav
.gitignore:6:roms/	roms/moto-racer-advance.gba
.gitignore:6:roms/	roms/moto-racer-advance.sav
.gitignore:8:bios/	bios/gba_bios.bin
.gitignore:8:bios/	bios/bios-dump.sav
```

- **Never commit them.** Don't use `git add -f`, and check `git status` before every commit.
- `git clean -x` or `git clean -X` deletes ignored files, including these dumps. Keep a backup outside the repo.
- Pass gbarecomp's tools the path explicitly: `--bios <path to this repo's bios/gba_bios.bin>`. Its `bios/README.md` says `bios_smoke`, the runtime and `gba_recompile` "all look here by default", but the code at `5e89943` doesn't match. `bios_smoke` uses `bios/gba_bios.bin` relative to the current directory ([`tools/bios_smoke/main.cpp` L51](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/tools/bios_smoke/main.cpp#L51)), `gba_recompile` has no default ("--bios needs a path argument", `tools/gba_recompile/main.cpp` L214–L215), and the runtime goes from the command line to a cached `bios.cfg` to a Windows file dialog (`src/runtime/runtime.cpp` L1383–L1409).

---

## Part 5: Buying a used cartridge

A bootleg or reproduction cartridge holds a copied, sometimes patched, ROM, so its dump may not match the known-good hashes, and it can't be used. FlashGBX says so directly: "Database checks will only work for genuine, unmodified game cartridges" ([README L374](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/README.md?plain=1#L374)).

What to check, mostly from [Epilogue's "Spotting fakes"](https://www.epilogue.co/support/cartridges/spotting-fakes) and [Nintendo Life's guide](https://www.nintendolife.com/guides/how-to-spot-fake-nintendo-video-games). No single check is proof:

- **Label.** Crisp print, correct colors, no spelling errors, and a small stamped two-digit number (Nintendo quality control) that shows in raking light. The label should carry the product code. For this game the header game code is A9ME (USA) or A9MP (Europe), so expect something like `AGB-A9ME-USA`; that exact label text is **unverified**.
- **Back of the shell.** Nintendo branding and/or "Made in Japan" (Epilogue), and a **tri-wing** screw (GB and GBC carts use a different screw). A Phillips screw or missing text is a red flag.
- **Inside** (tri-wing screwdriver):
  - "Nintendo" spelled correctly on the PCB.
  - A properly marked mask ROM chip. A black epoxy blob ("glob-top") is a strong sign of a fake.
  - No stacked boards, no stickers inside the shell, and no oddly cut PCB.
  - Nintendo Life adds that a numbered sticker with "E4" inked on the back of the board isn't found on official GBA boards.
  - Genuine GBA boards carry a board code, commonly in the form `AGB-Exx-xx` (**unverified** as a rule).
- **Save chip and battery.** FlashGBX's database lists Moto Racer Advance as **256K SRAM/FRAM** (`"st": 3` in [`db_AGB.json` L2625 and L2636](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/FlashGBX/config/db_AGB.json#L2619-L2640), which `CartridgeTypes.py` L101 maps to "256K SRAM/FRAM"). That doesn't say which chip the board carries. Battery-backed SRAM needs a coin cell to keep saves. FRAM doesn't, and Nintendo Life notes that a battery is used on some GBA games, "but not every GBA game uses one".
  - FlashGBX's dump report shows the ROM's save library string (Part 1, step 8). FlashGBX labels `SRAM_F_…` strings "256K SRAM/FRAM" and plain `SRAM_…` strings "256K SRAM" (`CartridgeTypes.py` L189–L195), so even FlashGBX treats `SRAM_F_` as either chip. `docs/research/game-facts.md` reports `SRAM_F_V102` for this game, from one source.
  - So a board without a battery is not, on its own, a sign of a fake. Look at the save chip: an SRAM chip with no battery points to a bootleg, since FlashGBX's README says such carts need patched ROMs, which would change the hash. Which chip genuine boards carry, and whether they have a battery, is **unverified** until someone records a real board in `docs/research/game-facts.md`.
  - A FlashGBX save type other than 256K SRAM/FRAM is a red flag. A dead battery only loses saves; the ROM still dumps fine.
- **Software check after purchase.** FlashGBX's header and database check (Part 1, step 4), or Playback's counterfeit detection. Epilogue says software checks "catch most fakes but not all".
- **When buying.** Ask for clear photos of the front label, the back, and ideally the PCB. A loose cartridge is all you need.

---

## Sources

Pinned commits were checked on 2026-10-10.

- gbarecomp `5e89943528aee7bc1c399bdbd035364a4b41dd10`: [`bios/README.md`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/bios/README.md), [`src/gba/gba_bios.h`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/gba/gba_bios.h), [`src/runtime/runtime.cpp`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/runtime/runtime.cpp), [`src/runtime/asset_picker.cpp`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/runtime/asset_picker.cpp), [`src/runtime/bios_hle.h`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/runtime/bios_hle.h), [`src/runtime/bios_hle.cpp`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/runtime/bios_hle.cpp), [`src/runtime/launcher_seam.h`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/runtime/launcher_seam.h), [`CMakeLists.txt`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/CMakeLists.txt), [`tools/gba_recompile/main.cpp`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/tools/gba_recompile/main.cpp), [`tools/bios_smoke/main.cpp`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/tools/bios_smoke/main.cpp), [`packaging/web/build_web.sh`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/packaging/web/build_web.sh), [`packaging/web/asset_store.js`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/packaging/web/asset_store.js), [`RELEASE_NOTES.md`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/RELEASE_NOTES.md), [`CLAUDE.md`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/CLAUDE.md)
- mgba-emu/bios-dump `7cffabaf7da18f18efc9c2712657eeef10abfdad`: [README](https://github.com/mgba-emu/bios-dump/blob/7cffabaf7da18f18efc9c2712657eeef10abfdad/README), [`src/bios-dump.c`](https://github.com/mgba-emu/bios-dump/blob/7cffabaf7da18f18efc9c2712657eeef10abfdad/src/bios-dump.c)
- mGBA `143adf5aa2a60c6036810b0cd72445e13d74b0e6`: [`include/mgba/internal/gba/bios.h`](https://github.com/mgba-emu/mgba/blob/143adf5aa2a60c6036810b0cd72445e13d74b0e6/include/mgba/internal/gba/bios.h), [`src/gba/bios.c`](https://github.com/mgba-emu/mgba/blob/143adf5aa2a60c6036810b0cd72445e13d74b0e6/src/gba/bios.c), [`src/gba/gba.c`](https://github.com/mgba-emu/mgba/blob/143adf5aa2a60c6036810b0cd72445e13d74b0e6/src/gba/gba.c)
- libretro-database `bf825e3ec48d43557ad024da6a7b93e512043525`: [`dat/System.dat`](https://github.com/libretro/libretro-database/blob/bf825e3ec48d43557ad024da6a7b93e512043525/dat/System.dat)
- FlashGBX `2d9682c0d1abbb556c27d7ba1715453c9776b563` (v5.1): [README](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/README.md), [`FlashGBX/config/db_AGB.json`](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/FlashGBX/config/db_AGB.json), [`FlashGBX/CartridgeTypes.py`](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/FlashGBX/CartridgeTypes.py), [`FlashGBX/DumpReport.py`](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/FlashGBX/DumpReport.py), [`FlashGBX/FlashGBX_GUI.py`](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/FlashGBX/FlashGBX_GUI.py), [`FlashGBX/FlashGBX_CLI.py`](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/FlashGBX/FlashGBX_CLI.py), [Releases](https://github.com/Lesserkuma/FlashGBX/releases)
- GodMode9i `57c6ed9a973376778eef06ea0a4a7a9edf5627a5`: [README](https://github.com/DS-Homebrew/GodMode9i/blob/57c6ed9a973376778eef06ea0a4a7a9edf5627a5/README.md), [`arm9/source/dumpOperations.cpp`](https://github.com/DS-Homebrew/GodMode9i/blob/57c6ed9a973376778eef06ea0a4a7a9edf5627a5/arm9/source/dumpOperations.cpp)
- gba-link-cable-dumper `d8c06b3dea345b80920b7609b5be7baa54c2fb63`: [README](https://github.com/FIX94/gba-link-cable-dumper/blob/d8c06b3dea345b80920b7609b5be7baa54c2fb63/README.md), [`source/main.c`](https://github.com/FIX94/gba-link-cable-dumper/blob/d8c06b3dea345b80920b7609b5be7baa54c2fb63/source/main.c)
- [DS-Homebrew wiki: GBA BIOS Dumping](https://wiki.ds-homebrew.com/gbarunner2/bios-dump)
- [loopj/gba-multiboot-pico](https://github.com/loopj/gba-multiboot-pico)
- [devkitpro/devkitarm on Docker Hub](https://hub.docker.com/r/devkitpro/devkitarm) (tag `20260610`, amd64 and arm64)
- Vendors: [GBxCart RW](https://www.gbxcart.com/), [insideGadgets FRAM flash cart](https://shop.insidegadgets.com/product/gba-32mb-256kbit-fram-save-flash-cart/) (the live page returns HTTP 403 to automated requests; prices and stock come from the Wayback Machine snapshot `20260508182251` of that URL, read on 2026-10-10), [Joey Jr](https://bennvenn.myshopify.com/collections/game-cart-to-pc-interface/products/usb-gb-c-cart-dumper-the-joey-jr), [GBFlash](https://github.com/simonkwng/GBFlash), [Game Bub](https://gamebub.net/), [GB Operator](https://www.epilogue.co/product/gb-operator), [Playback downloads](https://www.epilogue.co/downloads), [What is Playback?](https://www.epilogue.co/support/getting-started/what-is-playback), [Epilogue: Flashcart Support](https://www.epilogue.co/support/hardware/flashcart-support), [EverDrive GBA Mini](https://krikzz.com/our-products/cartridges/everdrive-gba-mini.html)
- Authenticity: [Epilogue: Spotting fakes](https://www.epilogue.co/support/cartridges/spotting-fakes), [Nintendo Life: How to spot fake Nintendo video games](https://www.nintendolife.com/guides/how-to-spot-fake-nintendo-video-games)
- [Seth Larson: Backup Game Boy ROMs and saves on Ubuntu (2024-05-06)](https://sethmlarson.dev/backup-game-boy-roms-and-saves-on-ubuntu)

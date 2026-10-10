# Dumping the ROM and the GBA BIOS from your own hardware

**Researched:** 2026-10-10. Nobody on the project has dumped this cartridge yet, so none of these procedures has been tested with it. Prices are what vendor pages listed on that date.

The project needs two files, and both must come from hardware you own:

| File | Where it goes | Comes from |
|---|---|---|
| Moto Racer Advance ROM | `roms/moto-racer-advance.gba` | Your cartridge, read with a cartridge reader |
| GBA BIOS (16384 bytes) | `bios/gba_bios.bin` | Your Game Boy Advance console, read by a small homebrew program running on it |

The BIOS is built into the console, not the cartridge. A cartridge reader alone can't produce it.

## Short version: what to order

| You already own | Order |
|---|---|
| Only the cartridge | 1. GBxCart RW (cartridge reader, ROM dump)<br>2. A writable GBA flash cart with SRAM or FRAM save memory (runs the BIOS dumper)<br>3. A used GBA, GBA SP or GBA Micro (runs the BIOS dumper) |
| Cartridge + a GBA, GBA SP, GBA Micro or Game Boy Player | Items 1 and 2 |
| Cartridge + DS, DS Lite or 3DS only | Items 1, 2 and 3. A DS-family console produces a different BIOS file (see [Part 2](#which-console-the-bios-must-come-from)) |
| Cartridge + GBA + a Wii or GameCube that runs homebrew + a GameCube–GBA link cable | Nothing, if you accept a slow dump: [gba-link-cable-dumper](#alternative-gamecube-or-wii-over-the-link-cable) dumps both files |

Recommended items, with what the vendor pages said on 2026-10-10:

1. **[GBxCart RW](https://www.gbxcart.com/)** by insideGadgets: "Just $33 plus shipping (when purchasing direct)". The page also lists resellers (Retro Game Repair Shop, ZedLabz, RetroModding, ModInFrance), which may ship faster to you. It reads GB, GBC and GBA cartridges and is driven on macOS by [FlashGBX](https://github.com/Lesserkuma/FlashGBX).
2. **A flash cart for the BIOS dumper**, one of:
   - **insideGadgets "GBA 32MB, 256Kbit FRAM Save, Flash Cart"** ([shop page](https://shop.insidegadgets.com/product/gba-32mb-256kbit-fram-save-flash-cart/)). The cheapest known-compatible option, because the GBxCart RW you're already buying writes to it ([FlashGBX README](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/README.md?plain=1#L150) lists "insideGadgets 32 MiB, 256K FRAM with Rumble option"). Price and stock are **unverified**: the shop blocks automated requests (HTTP 403), and a search-engine snippet showed $37–42.
   - **An SD-card flash cart** such as the [EverDrive GBA Mini](https://krikzz.com/our-products/cartridges/everdrive-gba-mini.html) ($99, "1Mbit SRAM (128KByte) save memory", "Supported with GameCube player"). It costs more, needs no writing step, and is useful later for running test programs on real hardware.
3. **A GBA-family console**: GBA (AGB-001), GBA SP (AGS-001/AGS-101), GBA Micro (OXY-001) or the GameCube Game Boy Player (DOL-017). **Not** a DS, DS Lite, 3DS or 2DS, and not a DSi, which has no GBA slot at all.
4. Isopropyl alcohol (99%+) and cotton swabs for cleaning cartridge contacts ([FlashGBX README, Troubleshooting](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/README.md?plain=1#L370)).

## Ground rules

- **Dump from hardware you own. Downloading a ROM or BIOS image is not an acceptable substitute for this project**, even if you own the cartridge. Don't ask for, link to, or accept such files. This doc names no download sites, and nothing in the repo may.
- **Never commit, upload or share the dumps**, including saves and anything derived from them. The paths below are gitignored, but `git add -f` overrides that. Keep a private backup outside the repo.
- Keep the dumps unmodified: no trimming, header fixing or patching. gbarecomp's web page rejects a ROM whose SHA-1 differs from the one the build expects ("Wrong ROM: its SHA-1 is …", [`packaging/web/asset_store.js` L30](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/packaging/web/asset_store.js#L30) at gbarecomp `5e89943`).

---

## Part 1: The cartridge ROM

### Options compared

| Option | Hardware and price (2026-10-10) | macOS | Dump verification | Can write flash carts (needed for the BIOS route) | Verdict |
|---|---|---|---|---|---|
| **GBxCart RW + FlashGBX** | [GBxCart RW](https://www.gbxcart.com/), $33 + shipping | FlashGBX ships `FlashGBX-5.1_macOS-arm64.dmg` (release 5.1, 2026-08-29). README requires "Sequoia 15 or newer" ([README](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/README.md?plain=1#L327)) | Built-in database (partly based on No-Intro) checks the ROM's CRC32 and supplies ROM size and save type | Yes | **Recommended** |
| **Joey Jr + FlashGBX** | [BennVenn Joey Jr](https://bennvenn.myshopify.com/collections/game-cart-to-pc-interface/products/usb-gb-c-cart-dumper-the-joey-jr), $42. "USB-C cable is required and not included." Shop banner: orders resume shipping on 16 October 2026 | Shop page: "Mac users please use FlashGBX software with the Joey Jr". FlashGBX README: on macOS, run the [Joey Jr Firmware Updater](https://github.com/Lesserkuma/JoeyJr_FWUpdater) first or FlashGBX won't find the device | Same as above | Yes (FlashGBX) | Good alternative |
| **GBFlash + FlashGBX** | [GBFlash](https://github.com/simonkwng/GBFlash) ("a rapid burner for GB/GBA flash cards"). README doesn't say where to buy it | Through FlashGBX | Same as above | Yes | Fine if you can find one |
| **Epilogue GB Operator + Playback** | [GB Operator](https://www.epilogue.co/product/gb-operator), $49.99 incl. VAT, USB-C | Playback for "macOS 12.0 or later", "Intel Core i5 or Apple M1" ([downloads](https://www.epilogue.co/downloads)) | "Counterfeit cartridge detection" ([What is Playback?](https://www.epilogue.co/support/getting-started/what-is-playback)). We found no documented check against a dump database | Not supported by FlashGBX. We found no documentation of flash-cart writing | Fine for the ROM only. Doesn't help with the BIOS |
| **DS or DS Lite + Slot-1 flash cart + [GodMode9i](https://github.com/DS-Homebrew/GodMode9i)** | Only if you already own them | Not needed; the dump lands on the flash cart's SD card | None built in; check the hash yourself | No | Only if you already own the hardware |
| **GBA + Wii or GameCube + link cable + [gba-link-cable-dumper](https://github.com/FIX94/gba-link-cable-dumper)** | Only if you already own them | Not needed; files land on the Wii/GameCube SD card | None built in | No | Slow, but dumps the BIOS too |

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
4. In FlashGBX, select **Game Boy Advance**, click **Connect**, then **Refresh** to read the header. Check:
   - Boot logo and header checksum show as valid.
   - The game code is **A9ME** (USA) or **A9MP** (Europe). These are the two Moto Racer Advance entries in FlashGBX's database ([`db_AGB.json` L2619–L2640](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/FlashGBX/config/db_AGB.json#L2619-L2640)).
   - ROM size shows **4 MiB** and save type **256K SRAM/FRAM**. Both entries list `"rs": 4194304` and save type 3, which `FlashGBX/CartridgeTypes.py` maps to "256K SRAM/FRAM" (32 KiB). The save type is **unverified** against the cartridge itself; Phase 1 confirms it in `docs/research/game-facts.md`.
5. **Back up the save first** with **Backup Save Data**. It's your progress, and a cartridge this old may have a weak battery. Store it as `roms/moto-racer-advance.sav` (ignored by git).
6. Click **Backup ROM** and save to `roms/moto-racer-advance.gba` in the repo.
7. Wait for "The ROM backup is complete and the checksum was verified successfully!". The other outcomes:
   - "…the checksum doesn't match the known database entry": clean and reseat the cartridge, dump again, and compare the two SHA-1s. Two identical dumps that still don't match the database point to an unknown revision or a non-genuine cartridge (see [Part 5](#part-5-buying-a-used-cartridge)).
   - "A data loop was detected…": usually an overdump (wrong ROM size) or a bad read.
8. Optionally, turn on FlashGBX's ROM dump report (CLI `--generate-dump-report`). It records the dump's details for `docs/research/`.

If you prefer the CLI, install FlashGBX in a Python venv as the README describes (`python3 -m pip install "FlashGBX[qt6]"`), then:

```sh
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
- **GB Operator**: in Playback, open **Data** and use **Backup Game** and **Backup Save** ([Seth Larson, 2024-05-06](https://sethmlarson.dev/backup-game-boy-roms-and-saves-on-ubuntu); Epilogue's own docs don't describe the export format, so it is **unverified**). Check the SHA-1 yourself afterwards.
- **DS or DS Lite with GodMode9i**: the README says it can "Dump Game Boy Advance cartridges on the original Nintendo DS and Nintendo DS Lite consoles". You run it from a DS-mode Slot-1 flash cart, with Moto Racer Advance in Slot-2. Output is `gm9i/out/<TITLE>_<GAMECODE>_<REV>.gba` on the SD card, and the save is dumped too (`dumpOperations.cpp`). This is a good ROM route, but a DS can't give you the right BIOS.
- **GameCube or Wii link cable**: see [below](#alternative-gamecube-or-wii-over-the-link-cable). It dumps the ROM, save and BIOS. The README estimates "32mb takes about 48 minutes", and Moto Racer Advance is 4 MiB (32 Mbit).

---

## Part 2: The GBA BIOS

### Which console the BIOS must come from

The GBA family and the DS family carry two different 16 KiB GBA BIOS images. [mgba-emu/bios-dump README](https://github.com/mgba-emu/bios-dump/blob/7cffabaf7da18f18efc9c2712657eeef10abfdad/README) (commit `7cffaba`) lists:

| Consoles | BIOS checksum (internal) | SHA-256 |
|---|---|---|
| GBA (AGB-001), GBA SP (AGS-001, AGS-101), GBA Micro (OXY-001), Game Boy Player (DOL-017) | `BAAE187F` | `fd2547724b505f487e6dcb29ec2ecff3af35a841a77ab2e85fd87350abd36570` |
| DS (NTR-001), DS Lite (USG-001), 3DS (CTR-001), 3DS XL (SPR-001), 2DS (FTR-001), New 3DS (KTR-001), New 3DS XL (RED-001), New 2DS XL (JAN-001) | `BAAE1880` | `782eb3894237ec6aa411b78ffee19078bacf10413856d33cda10b44fd9c2856b` |

mGBA recognizes both, as "Official GBA BIOS" and "Official GBA (DS) BIOS" (`GBA_BIOS_CHECKSUM` and `GBA_DS_BIOS_CHECKSUM` in [`include/mgba/internal/gba/bios.h` L15–L16](https://github.com/mgba-emu/mgba/blob/143adf5aa2a60c6036810b0cd72445e13d74b0e6/include/mgba/internal/gba/bios.h#L15-L16)).

gbarecomp expects the GBA-family image: SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492`, MD5 `a860e8c0b6d573d191e4ec7db1b1e4f6`, 16384 bytes ([`bios/README.md`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/bios/README.md) and `src/gba/gba_bios.h` at `5e89943`). gbarecomp has no high-level BIOS replacement. It runs the real BIOS code from your dump ("recompiled and executed via the dispatch table, not stubbed, not HLE'd", gbarecomp `CLAUDE.md`). What happens with a DS-family dump depends on the code path at `5e89943`:

- The main runtime loads the BIOS with no expected hash and only warns on a mismatch (`src/runtime/runtime.cpp` L1456–L1460; `RELEASE_NOTES.md`). So does the web page ("…is not the expected …; trying it anyway", `packaging/web/asset_store.js` L37).
- `src/runtime/launcher_seam.h` L78 and netplay (`runtime.cpp` L1493–L1496: "netplay requires this build's original ROM and retail BIOS") require the exact hash.
- `bios/README.md` L29 says "The runtime refuses to start with a BIOS whose hash isn't recognized", which contradicts the warning-only code above.

A DS-family dump might run with a warning, but nobody has validated it, and gbarecomp's BIOS symbol map was built against the canonical image (`tools/import_bios_symbols/import_bios_symbols.py`). Whether it behaves correctly is **unverified**. **Dump from a GBA-family console.**

### How the dumpers work

The BIOS can only be read while the CPU is executing inside it. Otherwise a read "will return the most recent successfully fetched BIOS opcode" ([GBATEK, "GBA Unpredictable Things"](https://problemkaputt.de/gbatek.htm#gbaunpredictablethings)). [mgba-emu/bios-dump](https://github.com/mgba-emu/bios-dump) (MIT) "dumps the GBA BIOS by jumping directly into the CpuFastSet routine in the BIOS, bypassing the region check, and then copying the BIOS into a flashcart's SRAM". In [`src/bios-dump.c`](https://github.com/mgba-emu/bios-dump/blob/7cffabaf7da18f18efc9c2712657eeef10abfdad/src/bios-dump.c), the program:

- embeds the string `SRAM_V123`, so flash carts and save tools treat it as an SRAM game;
- writes `0x55` to SRAM and reads it back, and stops with "Fatal SRAM error!" if the cartridge has no writable SRAM (an EEPROM- or flash-save cart won't work);
- prints the BIOS's own checksum with "CPU AGB" or "CPU NTR";
- copies the 16 KiB image byte by byte to the start of SRAM (`0x0E000000`, libgba's `SRAM` in `gba_base.h`), prints "Done dumping!", then prints the SHA-256 with "CPU AGB", "CPU NTR" or "CPU ???".

So the BIOS is **the first 16384 bytes of the save file**. The community `Bios_Shrinker.py` (GlaZedBelmont/Random-Stuff release 0.0.6) does the same thing: it reads the first `0x4000` bytes. On macOS:

```sh
head -c 16384 bios-dump.sav > bios/gba_bios.bin
```

### Methods compared

| Method | Hardware | BIOS you get | Source | Status |
|---|---|---|---|---|
| **bios-dump on a writable FRAM/SRAM flash cart, written and read back with GBxCart RW** | GBA-family console + GBxCart RW + e.g. insideGadgets 256Kbit FRAM flash cart | GBA (correct) | bios-dump README and source; FlashGBX README (cart support) | **Recommended.** This exact combination is untested by us |
| **bios-dump on an SD flash cart** | GBA-family console + SD flash cart with SRAM saves (EverDrive GBA, EZ-Flash Omega, etc.) | GBA (correct) | bios-dump README; [DS-Homebrew wiki, "GBA BIOS Dumping"](https://wiki.ds-homebrew.com/gbarunner2/bios-dump), method 2 | Documented |
| **gba-link-cable-dumper (FIX94)** | GBA-family console + GameCube (with SD Gecko) or Wii with GameCube ports, running homebrew + GameCube controller + GameCube–GBA link cable | GBA (correct) | [README](https://github.com/FIX94/gba-link-cable-dumper/blob/d8c06b3dea345b80920b7609b5be7baa54c2fb63/README.md) ("GBA BIOS Dumper by Dark Fader"); `source/main.c` writes `/dumps/gba_bios.bin` (`0x4000` bytes) | Documented. Release v1.6 is from 2016 |
| **DS or DS Lite in GBA mode, Slot-2 flash cart** | DS / DS Lite + Slot-2 flash cart | **DS variant (wrong hash)** | bios-dump README (NTR-001, USG-001); DS-Homebrew wiki, method 2 | Works, wrong file for us |
| **3DS with custom firmware + open_agb_firm** | 3DS family with Luma3DS | **DS variant (wrong hash)** | bios-dump README (CTR, KTR, …); DS-Homebrew wiki, method 1; [open_agb_firm](https://github.com/profi200/open_agb_firm) | Works, wrong file for us |
| **Multiboot from a Mac over the link port** | GBA-family console + DIY RP2040 cable ([loopj/gba-multiboot-pico](https://github.com/loopj/gba-multiboot-pico), needs a sacrificial link cable and a multimeter) + a cartridge with writable SRAM in the slot | GBA (correct) | bios-dump would need a multiboot build (`TARGET` ending in `_mb`, per its Makefile comment). Using the Moto Racer cart's own SRAM would overwrite your save | **Unverified.** We found no end-to-end write-up. Not worth the time |
| **Any cartridge reader alone** (GBxCart RW, GB Operator, Joey Jr) | – | – | The BIOS is in the console. FlashGBX's README has no BIOS feature | Not possible |
| **DSi / DSi XL** | – | – | No GBA slot. bios-dump's table doesn't list them, and GodMode9i's GBA dumping is DS/DS Lite only | Not possible |

A prebuilt `Bios_Dumper.gba` (GlaZedBelmont/Random-Stuff release 0.0.5, February 2020) is what the DS-Homebrew wiki links to. That release has no source code and no notes, so what the binary contains is **unverified**. Build mgba-emu/bios-dump from source instead (below). Once the Docker image is pulled, the build takes seconds.

### Recommended procedure: bios-dump via a FRAM flash cart and GBxCart RW

You need a GBA-family console, the GBxCart RW, a FlashGBX-supported GBA flash cart with SRAM or FRAM save memory (e.g. the insideGadgets 256Kbit FRAM cart), and Docker.

1. **Build `bios-dump.gba`** outside the repo. We verified this on 2026-10-10 on an Apple M4 Pro with Docker 29.6.2. The `devkitpro/devkitarm` image has an arm64 build, and this produced a 131072-byte `bios-dump.gba` containing `SRAM_V123`:
   ```sh
   git clone https://github.com/mgba-emu/bios-dump.git
   cd bios-dump
   git checkout 7cffabaf7da18f18efc9c2712657eeef10abfdad
   docker run --rm -v "$PWD":/src -w /src devkitpro/devkitarm:20260610 make
   ```
   devkitPro also distributes a native macOS toolchain, which we didn't try (**unverified** on Apple Silicon).
2. **Write it to the flash cart.** Put the flash cart in the GBxCart RW. In FlashGBX, choose Game Boy Advance, Connect, then **Write ROM** and pick `bios-dump.gba`. FlashGBX auto-detects many flash carts, and the insideGadgets FRAM cart is on its supported list.
3. **Run it on the GBA-family console.** Power on with the flash cart inserted. Expected screen output: `BIOS Checksum: BAAE187F`, `CPU AGB`, `Done dumping!`, then `SHA256: fd2547724b50…` and `CPU AGB`.
   - `CPU NTR`: you're on a DS-family console. Use a GBA, SP, Micro or Game Boy Player.
   - `Fatal SRAM error!`: the cart has no writable SRAM. Use an SRAM or FRAM cart.
4. **Read the save back.** Power off and move the flash cart to the GBxCart RW. For flash and reproduction carts, the FlashGBX README says to run "Analyze Flash Cart" before backing up save data. Then use **Backup Save Data**. If the save type isn't detected, pick **256K SRAM/FRAM** (CLI: `--agb-savetype sram256k`). You get a 32 KiB `.sav`.
5. **Extract and verify:**
   ```sh
   head -c 16384 bios-dump.sav > bios/gba_bios.bin
   echo "300c20df6731a33952ded8c436f7f186d25d3492  bios/gba_bios.bin" | shasum -a 1 -c
   ```
   Then delete the intermediate `.sav` or keep it outside the repo.

### Alternative: an SD flash cart

1. Build `bios-dump.gba` as above and copy it to the flash cart's SD card.
2. Boot the cart on a GBA-family console, launch `bios-dump.gba`, and wait for `Done dumping!` and `CPU AGB`.
3. Get the save written to the SD card. When this happens depends on the cart: some copy the save to SD right away, others at the next boot into the menu. To be safe, power off, boot back into the cart's menu, and wait a few seconds before removing the SD card. This is **unverified** per cart; check your cart's manual.
4. Copy the `.sav` (for example `bios-dump.sav`) to the Mac and run the `head -c 16384` step above.

### Alternative: GameCube or Wii over the link cable

From the [gba-link-cable-dumper README](https://github.com/FIX94/gba-link-cable-dumper/blob/d8c06b3dea345b80920b7609b5be7baa54c2fb63/README.md): start the matching `.dol` on a GameCube (SD Gecko) or Wii, with a GameCube controller in port 1 and the GameCube–GBA link cable in port 2. Boot the GBA **without a cartridge** and the dumper loads over the cable. Choose the BIOS backup ("Press Y to backup the GBA BIOS", `source/main.c`). The file is written as `dumps/gba_bios.bin` on the console's SD card or USB drive. The same tool also dumps the ROM and save once you insert the cartridge. If the GBA resets at that step, the README says to boot with the cartridge in while holding Start+Select. You need homebrew running on the Wii or GameCube already; setting that up is outside this guide.

---

## Part 3: Verify

Use the stock macOS tools:

```sh
# BIOS: must be exactly 16384 bytes with this SHA-1 (gbarecomp bios/README.md)
stat -f %z bios/gba_bios.bin
echo "300c20df6731a33952ded8c436f7f186d25d3492  bios/gba_bios.bin" | shasum -a 1 -c

# Optional cross-checks of the same file
shasum -a 256 bios/gba_bios.bin   # fd2547724b505f487e6dcb29ec2ecff3af35a841a77ab2e85fd87350abd36570 (bios-dump README, GBA family)
md5 bios/gba_bios.bin             # a860e8c0b6d573d191e4ec7db1b1e4f6 (gbarecomp bios/README.md)

# ROM
stat -f %z roms/moto-racer-advance.gba     # 4194304 for both known releases (FlashGBX database)
shasum -a 1 roms/moto-racer-advance.gba
```

- **BIOS.** `shasum -c` prints `OK` or `FAILED`. A SHA-256 of `782eb389…856b` means a DS-family BIOS: redo the dump on a GBA-family console. Any other value means a bad dump or a non-retail BIOS: rerun the dumper.
- **ROM.** Compare the SHA-1 with the per-region and per-revision hashes in [`docs/research/game-facts.md`](../research/game-facts.md). This guide deliberately doesn't repeat them. A dump that matches no known hash is either a bad read (dump again) or a non-genuine or unknown cartridge. Report it either way; don't use it.
- Once both files match, record the ROM's SHA-1 and region in `docs/research/` as `CLAUDE.md` requires. Record only hashes, never file contents.

## Part 4: Where to put the files

```
roms/moto-racer-advance.gba   # the cartridge ROM
roms/moto-racer-advance.sav   # optional: your cartridge save backup
bios/gba_bios.bin             # the GBA BIOS
```

Create both directories at the repo root (`mkdir -p roms bios`). Both are gitignored, as checked on 2026-10-10:

```console
$ git check-ignore -v roms/moto-racer-advance.gba bios/gba_bios.bin
.gitignore:6:roms/	roms/moto-racer-advance.gba
.gitignore:8:bios/	bios/gba_bios.bin
```

- **Never commit them.** Don't use `git add -f`, and check `git status` before every commit.
- `git clean -x` or `git clean -X` deletes ignored files, including these dumps. Keep a backup outside the repo.
- gbarecomp's own tools look for `bios/gba_bios.bin` inside *its* checkout by default and accept `--bios <path>` ([gbarecomp `bios/README.md`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/bios/README.md)). Point them at this repo's file instead of copying it around.

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
- **Save chip and battery.** FlashGBX's database lists Moto Racer Advance as 256K SRAM. SRAM needs a battery to keep its contents, so a genuine board should have an SRAM chip and a coin cell. A board without a battery, or a FlashGBX save type other than 256K SRAM/FRAM, suggests a reproduction. FlashGBX's README notes that bootlegs with "an SRAM memory chip but no battery" need patched ROMs, which would change the hash. A dead battery only loses saves; the ROM still dumps fine.
- **Software check after purchase.** FlashGBX's header and database check (Part 1, step 4), or Playback's counterfeit detection. Epilogue says software checks "catch most fakes but not all".
- **When buying.** Ask for clear photos of the front label, the back, and ideally the PCB. A loose cartridge is all you need.

---

## Sources

Pinned commits were checked on 2026-10-10.

- gbarecomp `5e89943528aee7bc1c399bdbd035364a4b41dd10`: [`bios/README.md`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/bios/README.md), [`src/gba/gba_bios.h`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/gba/gba_bios.h), [`src/runtime/runtime.cpp`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/runtime/runtime.cpp), [`src/runtime/launcher_seam.h`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/runtime/launcher_seam.h), [`packaging/web/asset_store.js`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/packaging/web/asset_store.js), [`RELEASE_NOTES.md`](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/RELEASE_NOTES.md)
- mgba-emu/bios-dump `7cffabaf7da18f18efc9c2712657eeef10abfdad`: [README](https://github.com/mgba-emu/bios-dump/blob/7cffabaf7da18f18efc9c2712657eeef10abfdad/README), [`src/bios-dump.c`](https://github.com/mgba-emu/bios-dump/blob/7cffabaf7da18f18efc9c2712657eeef10abfdad/src/bios-dump.c)
- mGBA `143adf5aa2a60c6036810b0cd72445e13d74b0e6`: [`include/mgba/internal/gba/bios.h`](https://github.com/mgba-emu/mgba/blob/143adf5aa2a60c6036810b0cd72445e13d74b0e6/include/mgba/internal/gba/bios.h), [`src/gba/gba.c`](https://github.com/mgba-emu/mgba/blob/143adf5aa2a60c6036810b0cd72445e13d74b0e6/src/gba/gba.c)
- FlashGBX `2d9682c0d1abbb556c27d7ba1715453c9776b563` (v5.1): [README](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/README.md), [`FlashGBX/config/db_AGB.json`](https://github.com/Lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/FlashGBX/config/db_AGB.json), [Releases](https://github.com/Lesserkuma/FlashGBX/releases)
- GodMode9i `57c6ed9a973376778eef06ea0a4a7a9edf5627a5`: [README](https://github.com/DS-Homebrew/GodMode9i/blob/57c6ed9a973376778eef06ea0a4a7a9edf5627a5/README.md), [`arm9/source/dumpOperations.cpp`](https://github.com/DS-Homebrew/GodMode9i/blob/57c6ed9a973376778eef06ea0a4a7a9edf5627a5/arm9/source/dumpOperations.cpp)
- gba-link-cable-dumper `d8c06b3dea345b80920b7609b5be7baa54c2fb63`: [README](https://github.com/FIX94/gba-link-cable-dumper/blob/d8c06b3dea345b80920b7609b5be7baa54c2fb63/README.md), [`source/main.c`](https://github.com/FIX94/gba-link-cable-dumper/blob/d8c06b3dea345b80920b7609b5be7baa54c2fb63/source/main.c)
- [DS-Homebrew wiki: GBA BIOS Dumping](https://wiki.ds-homebrew.com/gbarunner2/bios-dump)
- [loopj/gba-multiboot-pico](https://github.com/loopj/gba-multiboot-pico)
- [devkitpro/devkitarm on Docker Hub](https://hub.docker.com/r/devkitpro/devkitarm) (tag `20260610`, amd64 and arm64)
- Vendors: [GBxCart RW](https://www.gbxcart.com/), [insideGadgets FRAM flash cart](https://shop.insidegadgets.com/product/gba-32mb-256kbit-fram-save-flash-cart/) (not fetchable automatically), [Joey Jr](https://bennvenn.myshopify.com/collections/game-cart-to-pc-interface/products/usb-gb-c-cart-dumper-the-joey-jr), [GBFlash](https://github.com/simonkwng/GBFlash), [Game Bub](https://gamebub.net/), [GB Operator](https://www.epilogue.co/product/gb-operator), [Playback downloads](https://www.epilogue.co/downloads), [What is Playback?](https://www.epilogue.co/support/getting-started/what-is-playback), [EverDrive GBA Mini](https://krikzz.com/our-products/cartridges/everdrive-gba-mini.html)
- Authenticity: [Epilogue: Spotting fakes](https://www.epilogue.co/support/cartridges/spotting-fakes), [Nintendo Life: How to spot fake Nintendo video games](https://www.nintendolife.com/guides/how-to-spot-fake-nintendo-video-games)
- [Seth Larson: Backup Game Boy ROMs and saves on Ubuntu (2024-05-06)](https://sethmlarson.dev/backup-game-boy-roms-and-saves-on-ubuntu)

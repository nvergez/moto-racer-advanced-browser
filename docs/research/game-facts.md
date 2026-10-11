# Game facts

**Date:** 2026-10-10
**Scope:** Public facts about *Moto Racer Advance* that matter for the port, collected before we had a ROM. Apart from the update below, nothing here has been checked against a ROM.

**Update after the dump (2026-10-10).** The owner's cartridge has since been dumped. We checked three things on that dump; nothing else in this doc has been re-checked against it:

- It is the Europe release. Its SHA-1 is `B91BAD8EE04652D71E0610F8D1A5DEAEBD4C1FD0` and its size 4194304 bytes, matching the No-Intro Europe entry in §2 (`shasum -a 1`). Its header gives internal title `MOTORACERADV`, game code `A9MP`, maker code `41`, and version byte 0 (read with a Python script at offsets `0xA0`, `0xAC`, `0xB0`, `0xBC`). This answers question 1 in §7.
- A byte search of the whole file finds `SRAM_F_V102` once, at file offset `0x1C6D0` (address `0x0801C6D0`, 4-byte aligned), and none of the ID strings gbarecomp scans for (`EEPROM_V`, `SRAM_V`, `FLASH_V`, `FLASH512_V`, `FLASH1M_V`). So the save porting note in §3 applies to this dump.
- Its CodeBreaker checksum is `0x2981` (`tools/cheats/decrypt_gba_cheats.py cbcrc`), not the USA master code's `0x6A2F`. The cheat codes and RAM addresses in §6 are for the USA ROM and have not been checked on this dump.

## Confidence labels

- **verified**: stated by a primary source (the developer, a dump database, a database built from cartridge dumps), or by two or more independent sources, and checked by us against that source.
- **likely**: one secondary source, or our own derivation (decoded cheat codes, readings from video thumbnails) that passed a consistency check.
- **unverified**: not checked, sources disagree, or inferred.

"Verified" means the source says it. It does not mean we confirmed it on a ROM.

Under the project rules ([CLAUDE.md](../../CLAUDE.md)), every claim about the game's internals (rendering, memory layout, addresses, save format, ROM strings) is **unverified** until it has been checked on a ROM pinned by hash, whatever label it carries here. The labels only rank how much the public evidence supports each claim.

## Key facts for the port

| Fact | Confidence |
|---|---|
| Two dumps exist: USA (`A9ME`, SHA-1 `351414650E6969C270B1339ADA7B3565CE80374C`) and Europe (`A9MP`, SHA-1 `B91BAD8EE04652D71E0610F8D1A5DEAEBD4C1FD0`), both 4 MiB, both five-language. No revisions are listed. | verified |
| Save hardware is 32 KiB SRAM (256 Kbit SRAM/FRAM). MAME documents a battery-backed SRAM chip on a Europe cart. No RTC, rumble, or other cartridge hardware. | verified (SRAM); likely (no other hardware) |
| The save library ID string is reported as `SRAM_F_V102`. gbarecomp at the pinned commit does not recognize `SRAM_F_V`. Without `[save] type = "sram"` in the game config, the game would find no save chip: reads of the save region return `0x00` and writes are dropped. | verified on the Europe dump (string; see the update above); verified (gbarecomp code) |
| The developer says the target from day one was 60 fps. IGN's E3 report, preview, and review also say 60 fps. | verified (statements) |
| The renderer uses no polygons. Reviews describe sprites, backgrounds, scaling, and a "line-scrolling technique". Per-scanline backgrounds (affine, as in "Mode 7", or text-mode) plus scaled sprites fit this; which one is used is open. | likely (**unverified** on a ROM) |
| 18 tracks (6 Cross, 6 GP, 6 Traffic), plus the unlockable "Ultimate" course. 8 riders per race. | verified |
| Link play for up to 4 players, one cartridge per player (no single-pak mode). | verified |
| "Ultimate" exists and is a futuristic, space-themed course. The "hover taxis" detail is still open. | likely |
| Cheat codes point at EWRAM addresses for race position, speed, nitro, and an 18-byte unlock block at `0x0203F024`. USA ROM only. | likely (**unverified** on a ROM) |

## 1. Releases

| Region | Publisher | Release date | Product ID | Barcode | Confidence |
|---|---|---|---|---|---|
| Europe (PAL) | Ubisoft | 2002-10-04 | AGB-A9MP-EUR | 3307210116123 | Date: verified [W][GF][AD]. Product ID: verified [GF][MAME] (libretro lists only `AGB-A9MP` [LS]). Barcode: likely [GF] |
| USA | Ubi Soft (MobyGames: "Ubi Soft Entertainment, Inc.") | 2002-12-03, 2002-12-04, or 2002-12-05 | AGB-A9ME-USA | 008888140313 | Product ID: verified [GF][LS][GH][MAME]. Date: **unverified**, sources disagree: Dec 3 [GZ], Dec 4 [W][IGN-R][GS], Dec 5 [GF][YT]. Barcode: likely [GF] |

- Developer: Adeline Software International; producer: Delphine Software International [W]. Adeline's own site gives the release as "October 2002" [AD].
- Languages on both carts: English, French, German, Spanish, Italian (No-Intro names) [NI]. verified.
- ESRB: E [IGN-R][GF][LE]. verified. US launch price $24.99 [IGN-R]. likely.
- No Japanese release appears in the No-Intro mirror [NI]. likely (an absence, not proof).
- No revisions: No-Intro lists one dump per region [NI], and gbhwdb lists the ROM IDs as `AGB-A9ME-0` and `AGB-A9MP-0` (revision 0) [HW]. likely.
- Naming: the title screen and several databases spell it "Motoracer Advance" [YT][LM][GH]. Current No-Intro uses "Moto Racer Advance" [NI].

## 2. Dump database entries

Source: the No-Intro GBA DAT as mirrored in libretro-database, commit [`bf825e3`](https://github.com/libretro/libretro-database/blob/bf825e3ec48d43557ad024da6a7b93e512043525/metadat/no-intro/Nintendo%20-%20Game%20Boy%20Advance.dat#L12136-L12147) (2026-10-08), DAT header version `2026.10.07`, lines 12136–12147. Values below are copied from that file.

| | USA | Europe |
|---|---|---|
| No-Intro name | Moto Racer Advance (USA) (En,Fr,De,Es,It) | Moto Racer Advance (Europe) (En,Fr,De,Es,It) |
| Serial (game code) | A9ME | A9MP |
| Size (bytes) | 4194304 | 4194304 |
| CRC32 | `2FDBE7A8` | `8CB19DA0` |
| MD5 | `77FDFC944C31CCB0270C73E801CC20B0` | `D3B2AB65C92E18DF21788C4B30128041` |
| SHA-1 | `351414650E6969C270B1339ADA7B3565CE80374C` | `B91BAD8EE04652D71E0610F8D1A5DEAEBD4C1FD0` |
| Save type | not listed in the DAT | not listed in the DAT |
| FlashGBX header key (SHA-1 of ROM bytes `0x000`–`0x17F`) | `062b103bad19ab6aeccbbe95db9de3dbc94f9aca` | `f34f0868970fa0ac43ea2a672ff48a564959a25f` |

Cross-checks:

- Both CRC32s also appear in the FlashGBX database [FG] (as decimal `802940840` = `0x2FDBE7A8` and `2360450464` = `0x8CB19DA0`) and in a GBA dumper's game list [GD]. GameHacking.org lists only the USA CRC32 [GH]. Size 4194304 matches FlashGBX.
- MAME's GBA software list [MAME] gives the same size, CRC32, and SHA-1 for both regions. Its Europe entry names the ROM after the cartridge's mask ROM (`agb-a9mp-0.u1`) and documents the board, which suggests MAME's own dump. Its USA entry uses a No-Intro-style file name, so it may have been copied from No-Intro (**unverified**).
- RetroAchievements' list of MD5s for MAME's GBA software list [RAH] gives the same MD5s: `d3b2ab65c92e18df21788c4b30128041` for `agb-a9mp-0.u1` and `77fdfc944c31ccb0270c73e801cc20b0` for the USA file.
- BizHawk's game database [BH] lists both SHA-1s. Its names follow No-Intro's conventions, so it is probably derived from an older No-Intro DAT rather than separate dumps (**unverified**).
- **Verified** for CRC32, size, MD5, and SHA-1. The Europe dump has the strongest support (No-Intro plus MAME's documented cart). For the USA dump, the full-file MD5 and SHA-1 we found may all trace back to No-Intro.
- We did not query DAT-o-MATIC (datomatic.no-intro.org) directly: its search is a POST form, and we did not submit forms. The libretro file is a mirror of No-Intro.
- The FlashGBX key is how FlashGBX looks up its database: SHA-1 of the first `0x180` bytes ([RomFileAGB.py L227–230](https://github.com/lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/FlashGBX/RomFileAGB.py#L227-L230)). It gives a quick header check on a fresh dump.
- No entry in libretro's TOSEC GBA DAT or its Lost Level Archive GBA DAT (109 games) at the same commit.

## 3. Cartridge hardware

| Item | Value | Confidence | Sources |
|---|---|---|---|
| ROM size | 4 MiB (32 Mbit) | verified | [NI][FG] |
| Save type | 32 KiB SRAM. FlashGBX: save type 3 = "256K SRAM/FRAM", size 32768. Hades: `BACKUP_SRAM`. MAME: slot `gba_sram` for both regions. | verified | [FG][HD][MAME] |
| Save ID string in ROM | `SRAM_F_V102` | verified on the Europe dump (offset `0x1C6D0`, see the update at the top); USA ROM not checked | [GD]; our dump |
| Save slots | One ("Cartridge save (one slot)") | likely | [IGN-R] |
| RTC, rumble, solar, tilt, other GPIO | None. Hades marks the game `GPIO_NONE`. No entry in mGBA's or VBA-M's override tables, which is where such hardware is flagged. | likely | [HD][MO][VO] |
| Physical save chip, PCB type (Europe) | MAME documents one Europe cart: PCB `AGB-E06-10`, U2 "256K SRAM [HY62WT081ED70C]", battery CR1616. So battery-backed SRAM, not FRAM, on that cart. Other production runs may differ. | verified (one cart) | [MAME] |
| Physical save chip, PCB type (USA) | Unknown. MAME's USA entry has no board details, and gbhwdb has no hardware submissions for either region. | **unverified** | [MAME][HW] |

About `SRAM_F_V`: emulators treat it as 32 KiB SRAM, the same as `SRAM_V` (ares [AR], bsnes-mercury labels it `FRAM` [BM]). GBATEK's backup ID list only names `SRAM_Vnnn` [GT-B].

**Porting note.** Verified in gbarecomp's source at the pinned commit `5e89943`; the effect on this ROM is **unverified**.

- **Detection.** gbarecomp detects saves by scanning the ROM, at 4-byte alignment, for `EEPROM_V`, `SRAM_V`, `FLASH1M_V`, `FLASH512_V`, and `FLASH_V` ([gba_rom_header.cpp L66–75](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/gba/gba_rom_header.cpp#L66-L75)). `SRAM_F_V102` matches none of them, so the detected type is `unknown`, which has a save size of 0 ([save_config.cpp L49–58](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/runtime/save_config.cpp#L49-L58)).
- **What the game would see.** With no save type, no SRAM is configured. The bus checks `sram_enabled()` before it touches the save object: reads of the save region (`0x0E000000`–`0x0FFFFFFF`) return `0x00` and are counted as unmapped accesses, which are printed only with `GBARECOMP_LOG_UNMAPPED` set; writes are dropped ([gba_bus.cpp L252–258, L310–320, L378–388](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/gba/gba_bus.cpp#L252-L258) for 8/16/32-bit reads; L470–480, L527–539, L607–619 for writes; L637–648 for the logging). The `0xFF` default inside `GbaSave::sram_read` ([gba_save.cpp L26–29](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/gba/gba_save.cpp#L26-L29)) is not reached on this path. At best the game runs without saves. If it checks its SRAM at boot (for example by writing and reading back a test value), it may show an error or behave differently (**unverified**).
- **mGBA differs.** mGBA, our planned reference, has no override for `A9M` [MO], so its save type starts as "autodetect". The first access to the save region then picks the type: a read always selects SRAM, and so does a write anywhere except `0x0E005555`, where a first write selects Flash instead ([memory.c L717–723 and L1064–1071 @ 143adf5](https://github.com/mgba-emu/mgba/blob/143adf5aa2a60c6036810b0cd72445e13d74b0e6/src/gba/memory.c#L717-L723); 16- and 32-bit accesses go through the same byte paths). An SRAM save library is not expected to write to `0x0E005555` first, so mGBA should end up with SRAM (**unverified** on this ROM). gbarecomp has no such fallback. Without the config below, the two would diverge in Phase 2's replay comparisons as soon as the game touches SRAM.
- **Fix.** Set `[save] type = "sram"` in the game's `game.toml` ([runtime.cpp L734–751](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/runtime/runtime.cpp#L734-L751)). A type set in the game config overrides the ROM signature, and the `GBARECOMP_SAVE_TYPE` environment variable overrides both ([save_config.cpp L85–133](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/runtime/save_config.cpp#L85-L133); call site and `configure_sram` in [runtime.cpp L1806–1832](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/runtime/runtime.cpp#L1806-L1832)).
- **Browser target.** `[save] type` is the route that works in a released browser bundle. `packaging/web/runtime_config.py` exports `[save]` `type` and `size` from `game.toml` into the bundle's `runtime.toml` ([L12–20](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/packaging/web/runtime_config.py#L12-L20)), which the page passes to the runtime with `--config` ([bootstrap.js L64](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/packaging/web/bootstrap.js#L64)). The environment variable works natively, but in the browser only through the `?env=` URL parameter, which the page honors only for a bundle built with `--dev` and served from a loopback address ([bootstrap.js L10–15, L60](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/packaging/web/bootstrap.js#L10-L15)).
- **Inconsistency upstream.** gbarecomp's own browser save test already maps `SRAM_F` to a 32 KiB chip ([tests/web/test_save.py L99–100](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/tests/web/test_save.py#L99-L100)), while the runtime's detector does not recognize it.

## 4. Content

### Menus and modes

- Main menu: Solo, Multiplayer, Options, Top 5. Solo: Single Race, Championship, League, Progression. likely [YT] (read from video thumbnails); consistent with [W][MG].
- Three disciplines: Cross (off-road), GP (paved circuits), Traffic (roads with traffic, either bike class). verified [IGN-R][GS][MG][W].
- Progression is the main mode: a tree of races per discipline that unlocks bikes, tracks, and "combos". verified [IGN-R][MG][W].
- Which Solo modes start locked: **verified** on the Europe dump (ROM SHA-1 `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0`, mGBA harness with the retail BIOS, 2026-10-11). On a fresh save, Single Race and Progression are open, Championship and League are locked, and Cross starts with two open tracks (Kenya, Texas); see [phase2-routes.md](phase2-routes.md) section 1. Which championship disciplines a player opens first, and how, is still **unverified** (question 16 in §7). Before that check the sources conflicted. Wikipedia says "The single race mode must be earned through playing the progression mode" and cites IGN's review for the paragraph [W], but the IGN review says only that the three disciplines "can be accessed in single race or championship" and says nothing about earning Single Race [IGN-R]. The longplay's thumbnail at about 0:00:50, on what looks like a fresh save, shows Single Race as a solid box with white text, Championship and League hatched with grey text, and Progression selected [YT]; the check agrees with it. Two reviews describe content, rather than menu entries, locked at the start: jeuxvideo.com says that in the championship only Cross can be played at first, and GP and Traffic unlock later [JV] (**unverified**); GameZone says Cross offers just two tracks ("terrains") to begin with, and more unlock as you place third or better [GZ] (the two tracks are verified, the unlock rule is **unverified**).

### Progression structure

The longplay's chapter list [YT], in order: Cross, GP, and Traffic start sections; Super League; Mega League; Reverse GP; Reverse Cross; Reverse Traffic; GP, Cross, and Traffic Reverse Leagues; Extra League; Ultimate; Ultimate Reverse; credits. likely.

From the video's thumbnails, each discipline has "Rookie" and "Pro" groups. The Extra League has 12 races ("race complete 6/12"), and a Mirror unlock ("mirror", an "M" icon) appears after Ultimate Reverse. likely [YT].

### Tracks

Adeline's 2002 site lists the tracks by discipline (in French; translated below) [AD]. The in-game English names match, as read from the longplay's thumbnails [YT]. A GameFAQs reader review also counts eighteen tracks [GF-RR]. verified (list and count).

| Discipline | Tracks |
|---|---|
| Cross | Kenya, Texas, France, Mauritania, New Zealand, Italy |
| GP | California, England, Belgium, Brazil, Sweden, Germany |
| Traffic | Moscow, San Francisco, Montreal, Cairo, Tokyo, Paris |
| Ultimate | One course, plus "Ultimate Reverse" |

- We did not see the in-game "Texas" name card; the name comes from Adeline's list. The track is the desert-canyon Cross course seen in the longplay, and GameZone's review mentions racing in Texas [GZ]. likely.
- Each discipline has reversed versions of its tracks [YT]. likely.
- Races have 8 riders (the player plus 7 CPU riders) [IGN-P][JV], shown as "POS 8" on the grid in [YT]. Races are 3 laps in the races we sampled [YT]. verified (8 riders), likely (3 laps).

### Bikes

- Each bike has four stats: max speed, acceleration, brake, grip. verified [MG][YT].
- Adeline's site groups the bikes as Cross, GP, and Pocket [AD]. verified.
- Bikes seen in the longplay [YT] (likely, not a complete list): Cross: Blood 250, Fullmax 250, Fullmax 500. GP: GP 250, Powermax 250, Powermax 500. Pocket: Pocket Machine (a pocket bike usable in all three disciplines).
- Unlocking GP bikes takes Cross wins, and vice versa [IGN-R]. likely.
- Automatic or manual gearbox is chosen on the bike screen [YT][JV]. likely.

### Unlockables

- Bikes, tracks, leagues, and "combos" (button sequences for special moves) [IGN-R][GS][JV][MG]. verified.
- Combo names seen in the longplay [YT]: Quick Fall, Quick Start, Anti-collision, Mega Grip. likely. Quick Fall is the first one earned, so it is probably the "get up faster after a fall" combo that jeuxvideo.com describes [JV] (**unverified**). The game displays each combo's input, but we did not transcribe them from low-resolution thumbnails.
- Riders: jeuxvideo.com says clearing the modes available at the start wins new riders, 36 in total (our translation) [JV]. It is unclear whether 36 counts every rider or only the unlockable ones. **unverified**.
- Locked items are shown greyed out [IGN-R]. likely.
- Mirror mode after Ultimate Reverse [YT]. likely.

### Controls

The sources agree that R triggers a wheelie that boosts speed, limited by a gauge that refills. jeuxvideo.com says R makes the bike wheelie, and a screenshot caption says to wheelie to boost your speed [JV]. Gaming Nexus says pressing R makes the rider wheelie, then boost [GN], and GameZone says the right button makes the bike surge for a speed boost [GZ]. IGN says the boost comes from holding "the shoulder button" and is limited by a power bar that must refill after each use [IGN-R]. MobyGames says the nitro does a wheelie, can be depleted, and regenerates over time [MG]. Only jeuxvideo.com mentions L, which it says shifts gears [JV]; that fits the manual gearbox option (§4, Bikes). **unverified**: check in the manual and in-game (question 13 in §7).

### Multiplayer

- Up to 4 players over the link cable, one cartridge per player. IGN's feature list says "multiple cartridge" [IGN-R]. Gaming Nexus regrets that there is no single-cartridge mode [GN]. MobyGames: 1–4 players, free-for-all, multi-link cable [MG-T]. libretro: `users 4` [LX]. verified.

### The "Ultimate" claim

The earlier recap's claim, as recorded in [initial-findings.md](initial-findings.md): an "Ultimate" mode contains a sci-fi race with hover taxis and spaceships.

| Part | Verdict | Evidence |
|---|---|---|
| Ultimate exists and is unlocked late | verified | MobyGames: "A fourth style called Ultimate is unlocked later on in the game" [MG]. Longplay chapters 4:26:30 "Ultimate" and 4:29:48 "Ultimate Reverse", after the Extra League [YT] |
| It is a race | likely | The chapters are about 3 minutes each, the length of one race [YT]. The thumbnails show a lap race with "POS" and lap counters |
| Futuristic setting | likely | Thumbnails show a star field, planets (one ringed), neon and wireframe city blocks, and striped glowing roads [YT] |
| "Spaceships" | likely | Flying-saucer craft with green aliens appear beside and above the track, and the Ultimate menu art shows an alien in a saucer [YT] |
| "Hover taxis" | **unverified** | Yellow car-shaped vehicles appear on and above the track [YT]. At 270×180 we cannot tell whether they are taxis or whether they hover |
| How it unlocks | **unverified** | In the longplay it follows the Extra League. No source states the rule |

The Ultimate menu also shows a locked "?" slot, which suggests more content (**unverified**). Ultimate Reverse appears to be raced as a green alien rider (**unverified**). The credits are a checkerboard course on an asteroid-strewn planet, ridden by an alien on a yellow saucer, with credit names painted on the track [YT].

How the thumbnails were read: YouTube publishes preview thumbnails ("storyboards") for each video. For the longplay these are 270×180 frames every 10 seconds. We viewed them transiently to read track names, menus, and the Ultimate course. No video was downloaded and no image is committed.

## 5. Technical

### What the developer said

- "From the start of the project the watchword was: 60 fps" (our translation from French) [AD]. verified as a statement.
- Adeline's "Making of" page declines to name its programming tools and compiler-debugger [AD-T]. verified. So the compiler question stays open.
- Tools described on the same page [AD-T], all verified as statements:
  - **Bankedit** groups isolated decor elements (trees, houses) and sprite animations into per-level banks, with sound, collision, and effect parameters. Vehicles are handled the same way.
  - **MRedit** builds the terrain base: "material strips 1024 pixels long made from 8×8-pixel squares" of grass, dirt, road, and so on.
  - **Trackedit** lays those strips end to end "like sections of an electric racing set" and places decor (trees, rocks, houses, animals) on top.
  - One graphics-tool image on the page is named `outil_ProMotion_128.jpg`, which suggests the Pro Motion pixel-art editor. likely.
- Team, per Adeline's site [AD-M] and MobyGames credits [MG-C]: one software engineer (Pascal Dubois), Didier Chanfray (game design; "General Manager" in the credits), Hugues Tardif (development director), Arnaud Lhomme (art director), artists Gaël Marlier and Romain Chavanne, Philippe Vachey (music and SFX). verified.
- Wikipedia's Adeline article says no original Adeline staff worked on this game [WA]. MobyGames links several of these credited people to Adeline's earlier games (Time Commando, Little Big Adventure 2) [MG-C]. **Unverified**; sources conflict, and it is low relevance.

### What reviewers said about rendering

- IGN at E3 2002: "a line-scrolling technique that features an incredibly smooth framerate (60 frames per second), and a super far draw distance" [IGN-E3].
- IGN preview: "The game runs at a silky smooth 60 frames per second" [IGN-P].
- IGN review: "doesn't feature any trendy texture-mapped 3D models; the developers worked with the GBA's strength of manipulating sprites and backgrounds"; graphics rating text: "smooth and fast scaling with detailed artwork flowing at 60 frames per second". Turning around is impossible, which IGN attributes to the lack of polygons [IGN-R].
- GameFAQs reader review: "entirely presented without polygons" [GF-RR].
- jeuxvideo.com (in French) says Cross races are "in 3D" and GP races use "Mode 7" [JV]. "In 3D" contradicts the no-polygon reviews and reads as a reviewer's impression. "Mode 7" (an affine background rewritten per scanline) does not contradict IGN's "line-scrolling technique". **unverified**.
- Reviewers note a long draw distance, steep hills, and no slowdown with many riders on screen [GS][IGN-R][JV][GF-RR].

### Implications (all unverified until Phase 1)

- **Frame rate.** The developer and three IGN pieces say 60 fps, so the plan's Phase 4 frame-rate item may be moot. Confirm in mGBA.
- **Renderer.** Everything points to a raster "road" engine with no polygons: per-scanline background effects plus scaled sprites for riders and decor. The per-scanline part could be an affine background (the "Mode 7" technique, which jeuxvideo.com names for GP) or text-mode backgrounds with per-line scroll; the evidence does not rule out either. Both would mean HBlank DMA or HBlank IRQ writes to background registers. gbarecomp at `5e89943` already handles the DMA case: it renders each visible line at the start of its HBlank from the I/O registers as they stand, then runs HBlank DMA ([runtime_bus_bridge.cpp L573–596](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/runtime/runtime_bus_bridge.cpp#L573-L596)), and its PPU tracks the affine reference registers that Mario Kart: Super Circuit reloads by HBlank DMA on every road scanline ([gba_ppu.cpp L2434–2440](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/gba/gba_ppu.cpp#L2434-L2440)). So the affine-plus-HBlank-DMA option is exercised upstream by a supported racer. The open risk is narrower: per-line writes made by an HBlank IRQ handler (the IRQ is raised at the same point, [L609–611](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/runtime/runtime_bus_bridge.cpp#L609-L611)) only land on the right line if the recompiled handler runs before the next line is rendered, so IRQ timing matters (**unverified**). The resolution enhancement means re-rendering the per-line road and scaled sprites at higher resolution, not intercepting triangles. The 1024-pixel terrain strips match the largest affine background (1024×1024 pixels), which fits the affine option. Bitmap-mode software rendering is a third candidate. Phase 1 must read `DISPCNT`, the BG registers, and the DMA setup during a race in mGBA.
- **Widescreen.** Decor placement and culling are probably tied to the 240-pixel screen width. Not investigated (question 14 in §7).

### Sound (reviews)

- IGN: "standard background music during menus, digitized voice samples and cycle engine noises during the action" [IGN-R].
- jeuxvideo.com praises digitized voices heard throughout the game, which give it an arcade feel (our translation) [JV].
- GameZone calls the voices "fair" and the bike and effect sounds very poor [GZ].
- Music and sound effects are credited to Philippe Vachey [AD-M][MG-C].

All verified as statements. They describe sampled voices and engine sounds during races and music in the menus, but say nothing about which sound driver plays them. Whether it is Nintendo's M4A (MP2K) driver or a custom mixer is question 6 in §7 ([initial-findings.md](initial-findings.md) question 5).

What that choice changes, per gbarecomp's own comments at `5e89943`: the recompiled game's driver runs unchanged either way. gbarecomp's M4A-specific code is a driver detector and debug dump that does not alter execution ([gba_m4a.h L1–8](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/gba/gba_m4a.h#L1-L8)), plus a "shadow" mixer that re-renders M4A voices in float at 65536 Hz and substitutes its output only after checking it against the driver's own mix ([mp2k_shadow.h L1–9](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/src/gba/mp2k_shadow.h#L1-L9)). The verifier is written to be engine-agnostic, but M4A is the only engine with a shadow mixer at this commit (the tree's other shadow source, `src/gba/audio_shadow.*`, is the verifier). So a custom driver should still play through the emulated sound hardware, but would not get that audio enhancement (**unverified**).

### BIOS calls (third-party data)

In 2022, a contributor to the Cult-of-GBA BIOS issue tracker posted a per-game list of the SWIs each commercial ROM executed, recorded with the retail BIOS and "some dummy inputs to get past most start screens" ([issue #9, comment of 2022-02-09](https://github.com/Cult-of-GBA/BIOS/issues/9#issuecomment-1034127061); the CSV is linked from [a later comment](https://github.com/Cult-of-GBA/BIOS/issues/9#issuecomment-1036609624)). Those comments give no frame count and do not name the emulator. The row `Motoracer Advance.gba` lists SWIs 5, 7, 12, 17, and 20: VBlankIntrWait, DivArm, CpuFastSet, LZ77UnCompWram (LZ77UnCompReadNormalWrite8bit), and RLUnCompWram (RLUnCompReadNormalWrite8bit). We re-read that row from the CSV.

How far that run got is not stated. The 9000 frames in the issue belong to a different run: the same author's mGBA A/B comparison of the retail and Cult-of-GBA BIOSes, described in the issue's opening post. Both of its Moto Racer runs reached the race start screen with the bike stationary ([open-bios.md §1](open-bios.md#cult-of-gba-bios)). If the SWI run went as far, the list covers boot, menus, and the race start, but nobody drove, so race-time calls are probably missing. **unverified** for our ROM, whose region and revision the data does not identify. [open-bios.md §5.1](open-bios.md#51-which-swis-the-game-calls) uses the same data to assess open BIOS replacements. See question 15 in §7.

## 6. Cheat codes

**Source:** GameHacking.org game 5425, "Motoracer Advance (USA) (En,Fr,De,Es,It)", CRC32 `2FDBE7A8`, serial `AGB-A9ME-USA`. Read from the [Wayback Machine snapshot of 2026-06-17](https://web.archive.org/web/20260617202426/https://gamehacking.org/game/5425/), because the live site blocks automated requests. **All codes are for the USA ROM**, No-Intro SHA-1 `351414650E6969C270B1339ADA7B3565CE80374C` (§2), not the owner's Europe dump (see the update at the top). GameHacking matches by CRC32 only, so the SHA-1 link is through the No-Intro DAT. Europe addresses may differ.

Other places checked:

- GameHacking's GBA "M" game list has only the USA entry, so there are no Europe codes there ([2016-09-09](https://web.archive.org/web/20160909000702/http://gamehacking.org/system/gba/m/6) and [2026-06-17](https://web.archive.org/web/20260617132337/https://gamehacking.org/system/gba/m/6) snapshots).
- GameFAQs' cheats page was empty in its last archived copy (2019-12-12) [GF-C].
- libretro-database has no `.cht` file for this game.
- No GameShark codes turned up elsewhere.

### Codes as listed

Codes are copied verbatim, in GameHacking's "Original" format.

| Name (as listed) | Author | Device (as labeled) | Code |
|---|---|---|---|
| [M] Must Be On | MadCatz | Codebreaker/GameShark SP/Xploder | `911216685608` `CF8CF1754BB4` `6EEBE336DF10` |
| Always 1st | MadCatz | Codebreaker/GameShark SP/Xploder | `B3142C244498` `0584FAF949B2` |
| Always in First Place | Dualscreenman | Codebreaker/GameShark SP/Xploder | `3201A58E 0001` |
| Always in First Place | Dualscreenman | GameShark Advance/Action Replay | `1378A3AB 53645017` |
| Bike Speed Boost | Dualscreenman | GameShark Advance/Action Replay | `2F98C0ED A2CFC904` `CC9DC202 9922F449` |
| Bike Speed Modifer [sic] | Dualscreenman | Codebreaker/GameShark SP/Xploder | `74000130 03FE` `320340E5 00??` |
| Drive Thru Objects | MadCatz | Codebreaker/GameShark SP/Xploder | `8C6F7C2E545F` |
| End Race [Press Select+L] | MadCatz | Codebreaker/GameShark SP/Xploder | `20805E0826E7` `16F8EA3DCF12` |
| Infinite Nitro | MadCatz | Codebreaker/GameShark SP/Xploder | `CD1C515A318E` |
| Unlock Everything | MadCatz | Codebreaker/GameShark SP/Xploder | `32A38E88B2FE` `A1E4B8FD4BD7` |

### Formats and decoding

- **Dualscreenman's CodeBreaker codes are plaintext.** They can be read directly using GBATEK's CodeBreaker table [GT-CB]: `3aaaaaaa 00yy` writes a byte, `7aaaaaaa yyyy` means "if the halfword equals yyyy, run the next code", and `4aaaaaaa yyyy` + `iiiicccc ssss` is a fill ("slide") code.
- **MadCatz's CodeBreaker codes are encrypted.** The first line of the master code (`91121668 5608`, type 9) seeds the encryption. Every MadCatz line after it is encrypted and cannot be read as an address.
- **We decrypted them** with a Python port of mGBA's CodeBreaker routine (`src/gba/cheats/codebreaker.c`, mGBA commit [`143adf5`](https://github.com/mgba-emu/mgba/blob/143adf5aa2a60c6036810b0cd72445e13d74b0e6/src/gba/cheats/codebreaker.c)), now committed as [`tools/cheats/decrypt_gba_cheats.py`](../../tools/cheats/decrypt_gba_cheats.py) (MPL-2.0, like the code it ports). `python3 tools/cheats/decrypt_gba_cheats.py check` decrypts every encrypted line in this section (CodeBreaker and Action Replay), compares the output with expected values kept in the script, checks that each of those codes and decoded values still appears in this file, and exits with status 1 on any mismatch. As a second check, mGBA's own C routines at `143adf5` (`_cbLoadByteswap` through `_cbReseed`, codebreaker.c L12–187, and `GBACheatDecryptGameShark`, gameshark.c L65–73, with the seeds from gameshark.c L13 and parv3.c L12), copied unchanged into a small C harness and compiled with Apple clang, give identical output for every line. Three checks make the result likely:
  1. The master code decrypts to `00006A2F 000A` and `1015BC76 0007`, a valid game-ID line and a valid hook line. GBATEK says the flag byte is "usually 0Ah" and the handler slot "usually 7" [GT-CB].
  2. "End Race [Press Select+L]" decrypts to a test of `KEYINPUT` (`0x04000130`) against `0x01FB`. That value means exactly Select and L are held.
  3. Two of MadCatz's decoded addresses sit next to Dualscreenman's plaintext ones: `0x0201A55B` next to `0x0201A58E`, and `0x020340F4` next to `0x020340E5`. MadCatz's two `0x02032C..` addresses (`0x02032CBA`, `0x02032C8D`) are consistent only with each other; no independent code supports them.
- **Dualscreenman's "GameShark Advance/Action Replay" codes are mislabeled or stored oddly.** With the GSA v1/v2 seeds they decrypt to nonsense (`73D5936C 7EA50D88`). With the Pro Action Replay v3 seeds (GBATEK [GT-PAR3]; mGBA [`parv3.c` L12](https://github.com/mgba-emu/mgba/blob/143adf5aa2a60c6036810b0cd72445e13d74b0e6/src/gba/cheats/parv3.c#L12)) they decrypt to `0201A58E 00000001`, then `04000130 000003FE` and `020340E5 000000C8`. These read as plain address/value pairs, the same addresses as the plaintext CodeBreaker codes. Read as real PAR v3 codes they would not address EWRAM: mGBA's PAR v3 parser takes address bits 24–27 from bits 20–23 of the first word ([`_parAddr`, parv3.c L51–53](https://github.com/mgba-emu/mgba/blob/143adf5aa2a60c6036810b0cd72445e13d74b0e6/src/gba/cheats/parv3.c#L51-L53)), so `020340E5` would map to `0x000340E5`. They add one fact: "Bike Speed Boost" writes a concrete value, `0xC8` (200), to `0x020340E5`, where the CodeBreaker "Bike Speed Modifer" leaves the value as `??`. That is the code author's example value, not a known game constant.

### Decoded meaning

| Code | Decoded | Reading |
|---|---|---|
| [M] Must Be On | `91121668 5608` / `00006A2F 000A` / `1015BC76 0007` | Encryption seed; game ID, where `6A2F` is CodeBreaker's checksum of the first 64 KiB of the ROM (the flag byte `0x0A` has bit 3, "CRC Exists", and bit 1, "Disable IRQs", set [GT-CB]); hook at ROM offset `0x15BC76` (address `0x0815BC76`) |
| Always 1st | `42032CBA 0000` / `00000007 0048` | Write halfword `0x0000` to `0x02032CBA + n×0x48`, n = 0..6 |
| Always in First Place | `3201A58E 0001` | Write byte `0x01` to `0x0201A58E` |
| Bike Speed Modifer | `74000130 03FE` / `320340E5 00??` | If `KEYINPUT == 0x03FE` (only A held), write byte `??` to `0x020340E5` |
| Drive Thru Objects | `32032C8D 0000` | Write byte `0x00` to `0x02032C8D` |
| End Race [Press Select+L] | `74000130 01FB` / `3201A55B 0007` | If `KEYINPUT == 0x01FB` (Select+L held), write byte `0x07` to `0x0201A55B` |
| Infinite Nitro | `320340F4 00F0` | Write byte `0xF0` to `0x020340F4` |
| Unlock Everything | `4203F024 FFFF` / `00000009 0002` | Write halfword `0xFFFF` to `0x0203F024 + n×2`, n = 0..8 (18 bytes, `0x0203F024`–`0x0203F035`) |

### RAM map leads (USA ROM, SHA-1 `351414650E6969C270B1339ADA7B3565CE80374C`; meanings **unverified**)

| Address | Width | From | Hypothesis |
|---|---|---|---|
| `0x0201A58E` | byte | Always in First Place (CodeBreaker and Action Replay versions) | Player's race position, 1-based |
| `0x0201A55B` | byte | End Race | Race state; 7 = finished? |
| `0x02032CBA` + n×`0x48`, n = 0..6 | halfword | Always 1st | One field in 7 per-rider records of 72 bytes, probably the CPU riders |
| `0x02032C8D` | byte | Drive Thru Objects | Collision flag, possibly in the player's record |
| `0x020340E5` | byte | Bike Speed Modifier/Boost | Player speed or speed cap. Example value `0xC8` (from the Action Replay version) |
| `0x020340F4` | byte | Infinite Nitro | Nitro gauge |
| `0x0203F024`–`0x0203F035` | 18 bytes | Unlock Everything | Unlock bitfield, probably the RAM copy of save data |
| ROM `0x0815BC76` | — | CodeBreaker hook | Code that runs often (frame loop or interrupt path); a candidate entry point for reverse engineering |

All the RAM addresses are in EWRAM (`0x02000000`–`0x0203FFFF`). Phase 1 should confirm them in mGBA's memory viewer on the USA ROM.

## 7. Open questions for when we have the cartridge

Most need the ROM. A few can be answered from the manual or by playing.

1. Which region is the owner's cart, and does its dump match the No-Intro SHA-1 exactly? Header fields: internal title, maker code, version byte (expected 0). Answered in the update at the top: Europe, exact match, version 0.
2. Does the ROM contain `SRAM_F_V102` and no other save ID string? At what offset? (Europe dump: yes, once, at `0x1C6D0`; see the update at the top.) Does gbarecomp report the save type as unknown? gbarecomp's `gba_scan` tool prints `save_type`, `save_signature`, and `save_signature_offset` ([tools/gba_scan/main.cpp L69–71](https://github.com/mstan/gbarecomp/blob/5e89943528aee7bc1c399bdbd035364a4b41dd10/tools/gba_scan/main.cpp#L69-L71)), but only for a signature it recognizes; for `SRAM_F_V` we expect `save_type=unknown` and an empty signature, so the string's offset needs a plain byte search. Without `[save] type = "sram"`, does the game check SRAM at boot and complain? Do mGBA (which autodetects SRAM on first access) and gbarecomp behave the same once the config is set? See the porting note in §3.
3. How are races drawn? Video mode in `DISPCNT`, which layers draw the road, sky, and decor, whether decor is affine OBJ sprites, and whether HBlank DMA or HBlank IRQs rewrite BG registers per scanline.
4. Does the game render a new frame every VBlank in all modes, including 4-player link races?
5. How much code is copied to IWRAM or EWRAM and run from there? Is any of it generated or self-modifying?
6. Sound engine: M4A or custom? Reviews mention menu music, digitized voices, and engine noise (§5, Sound). gbarecomp's shadow-mixer audio enhancement only covers M4A at the pinned commit.
7. Which compiler built it? Adeline would not say.
8. Do the cheat-derived addresses behave as described? Is the CodeBreaker checksum over the first 64 KiB really `0x6A2F`? `python3 tools/cheats/decrypt_gba_cheats.py cbcrc ROM` computes it from a dump. A Europe dump should not match except by chance: its header, which lies inside those 64 KiB, differs from the USA one (the FlashGBX keys in §2 differ). The owner's Europe dump gives `0x2981`. And what is at `0x0815BC76`?
9. What differs between the USA and Europe ROMs (units, text, code)? This decides which one we target.
10. What does the link protocol look like (SIO multiplayer mode, data per frame)? Can gbarecomp's multiplayer runner drive it? We know of that runner only from its file names (`src/runtime/multiplayer_runner.cpp`, `tools/link_session/`).
11. What is in Ultimate: are the yellow vehicles hover taxis, and what is the locked "?" slot? Is there unused content?
12. Save layout: does the 18-byte unlock block map to SRAM, and does the save carry a checksum?
13. Controls: does L shift gears, as only jeuxvideo.com says? How do R's wheelie and boost gauge work, and how are combos entered? Reviews agree on R but only one mentions L (§4). Phase 3's input mapping needs the answer. The owner's manual is the cheapest source; confirm in-game.
14. Is anything tied to the 240-pixel screen width: decor and rider culling, sprite placement, the road projection, HUD layout? This decides how much work widescreen takes (§5).
15. Which BIOS SWIs does the game call during races, and how often per frame? The third-party list (§5, BIOS calls) comes from a run with dummy inputs, no stated frame count, and an unknown ROM revision. A separate 9000-frame run by the same author reached only the race start, so nobody drove. Trace it in mGBA during a race.
16. On a fresh save, which Solo modes are locked (Single Race, Championship, League)? Sources conflict (§4). Also check which disciplines and tracks start locked: one review says only Cross is open in the championship at first, another that Cross starts with two tracks (§4, both **unverified**). (Solo modes and Cross tracks answered for the Europe dump, ROM SHA-1 `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0`, in [phase2-routes.md](phase2-routes.md) section 1; which championship disciplines a player opens first is still open.)
17. How does the game seed and advance its random number generator: from timers, `VCOUNT`, a frame counter, uninitialized RAM, or input timing? Given the same inputs from cartridge entry, does a race play out identically? Phase 2's exit test (a full cup plays identically to mGBA under input replays, [plan.md](../plan.md)) and cross-BIOS comparisons ([open-bios.md §5.2](open-bios.md#52-how-a-different-implementation-can-diverge), boot state) depend on it.

## Sources

| Key | Source |
|---|---|
| NI | No-Intro GBA DAT via libretro-database [`metadat/no-intro/Nintendo - Game Boy Advance.dat` L12136–12147 @ bf825e3](https://github.com/libretro/libretro-database/blob/bf825e3ec48d43557ad024da6a7b93e512043525/metadat/no-intro/Nintendo%20-%20Game%20Boy%20Advance.dat#L12136-L12147) |
| LS | libretro-database [`metadat/serial/Nintendo - Game Boy Advance.dat` L11918–11932 @ bf825e3](https://github.com/libretro/libretro-database/blob/bf825e3ec48d43557ad024da6a7b93e512043525/metadat/serial/Nintendo%20-%20Game%20Boy%20Advance.dat#L11918-L11932) |
| LX | libretro-database [`metadat/maxusers/…` L11208–11218 @ bf825e3](https://github.com/libretro/libretro-database/blob/bf825e3ec48d43557ad024da6a7b93e512043525/metadat/maxusers/Nintendo%20-%20Game%20Boy%20Advance.dat#L11208-L11218) |
| LE | libretro-database [`metadat/esrb/…` L6348–6358 @ bf825e3](https://github.com/libretro/libretro-database/blob/bf825e3ec48d43557ad024da6a7b93e512043525/metadat/esrb/Nintendo%20-%20Game%20Boy%20Advance.dat#L6348-L6358) |
| LM | libretro-database [`metadat/developer/…` L11088–11098 @ bf825e3](https://github.com/libretro/libretro-database/blob/bf825e3ec48d43557ad024da6a7b93e512043525/metadat/developer/Nintendo%20-%20Game%20Boy%20Advance.dat#L11088-L11098) (uses the "Motoracer" spelling) |
| FG | FlashGBX [`config/db_AGB.json` L2619–2640 @ 2d9682c](https://github.com/lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/FlashGBX/config/db_AGB.json#L2619-L2640); save type table [`CartridgeTypes.py` L96–108](https://github.com/lesserkuma/FlashGBX/blob/2d9682c0d1abbb556c27d7ba1715453c9776b563/FlashGBX/CartridgeTypes.py#L96-L108) |
| MAME | MAME software list [`hash/gba.xml` L23653–23683 @ 954def4](https://github.com/mamedev/mame/blob/954def46685cd0276671138fbd032036b1a771fb/hash/gba.xml#L23653-L23683) (entries `motoracr`, Europe, and `motoracru`, USA) |
| RAH | RetroAchievements/RAHashes [`Mamesl/Nintendo - Game Boy Advance - mamesl - 2024-12-02.txt` L181, L2064 @ cf8a9b4](https://github.com/RetroAchievements/RAHashes/blob/cf8a9b461382b2ff96cc020ba2eff38d84cec452/Mamesl/Nintendo%20-%20Game%20Boy%20Advance%20-%20mamesl%20-%202024-12-02.txt#L181) (MD5s of MAME's GBA software list) |
| BH | BizHawk [`Assets/gamedb/gamedb_gba.txt` L1772–1773 @ 7c1b40d](https://github.com/TASEmulators/BizHawk/blob/7c1b40df1f48a07fc01d63fbfdf410c7980c4aba/Assets/gamedb/gamedb_gba.txt#L1772-L1773) (the file's last change) |
| GD | blimjoe/gbdumper-apm32 [`host/gba.txt` L5905–5909 @ 76683a2](https://github.com/blimjoe/gbdumper-apm32/blob/76683a2b0a62efff30a39e856abbd421ff2a22dd/host/gba.txt#L5905-L5909) |
| HD | Hades emulator [`source/gba/db.c` L1037 @ e12e42d](https://github.com/hades-emu/Hades/blob/e12e42d7c563db9c12092406b06ca015ba938f9f/source/gba/db.c#L1037) |
| AR | ares [`mia/medium/game-boy-advance.cpp` L126–177 @ 9408cb4](https://github.com/ares-emulator/ares/blob/9408cb43d4948fc3ea6e152a307a34348df3fe04/mia/medium/game-boy-advance.cpp#L126-L177) |
| BM | libretro/bsnes-mercury [`ananke/heuristics/game-boy-advance.hpp` L53 @ 79d7f9d](https://github.com/libretro/bsnes-mercury/blob/79d7f9de218b6ffa65a80bbdc5828532bc239232/ananke/heuristics/game-boy-advance.hpp#L53) |
| MO | mGBA [`src/gba/overrides.c` @ 143adf5](https://github.com/mgba-emu/mgba/blob/143adf5aa2a60c6036810b0cd72445e13d74b0e6/src/gba/overrides.c) (no `A9M` entry) |
| VO | VBA-M [`src/vba-over.ini`](https://github.com/visualboyadvance-m/visualboyadvance-m/blob/b29c3dc058fb80f90d043f669119fcfb9cf8f702/src/vba-over.ini) and [`src/libretro/gba-over.inc`](https://github.com/visualboyadvance-m/visualboyadvance-m/blob/b29c3dc058fb80f90d043f669119fcfb9cf8f702/src/libretro/gba-over.inc) @ b29c3dc (no `A9M` entry) |
| HW | [gbhwdb GBA cartridge list](https://gbhwdb.gekkio.fi/cartridges/gba.html) (checked 2026-10-10) |
| GT-B | GBATEK, [GBA Cart Backup IDs](https://problemkaputt.de/gbatek-gba-cart-backup-ids.htm) |
| GT-CB | GBATEK, [GBA Cheat Codes - Codebreaker/Xploder](https://problemkaputt.de/gbatek-gba-cheat-codes-codebreaker-xploder.htm) |
| GT-PAR3 | GBATEK, [GBA Cheat Codes - Pro Action Replay V3](https://problemkaputt.de/gbatek-gba-cheat-codes-pro-action-replay-v3.htm) |
| GH | GameHacking.org game 5425, [archived 2026-06-17](https://web.archive.org/web/20260617202426/https://gamehacking.org/game/5425/) |
| W | Wikipedia, [Moto Racer Advance, revision 1347273925](https://en.wikipedia.org/w/index.php?title=Moto_Racer_Advance&oldid=1347273925) |
| WA | Wikipedia, [Adeline Software International, revision 1359459413](https://en.wikipedia.org/w/index.php?title=Adeline_Software_International&oldid=1359459413) |
| AD | Adeline Software International, [MotoRacer Advance page, archived 2002-12-09](https://web.archive.org/web/20021209071424/http://www.adelinesoft.com:80/mra.html) |
| AD-T | Adeline Software International, ["Making of" (tools) page, archived 2002-12-09](https://web.archive.org/web/20021209151245/http://www.adelinesoft.com:80/tools.html) |
| AD-M | Adeline Software International, [team page, archived 2002-12-09](https://web.archive.org/web/20021209071912/http://www.adelinesoft.com:80/team.html) |
| IGN-E3 | IGN, "E3 2002: Moto Racer Advance", 2002-05-24, [archived](https://web.archive.org/web/20140506170015/http://www.ign.com/articles/2002/05/24/e3-2002-moto-racer-advance) |
| IGN-P | IGN, Craig Harris, preview, 2002-07-01, [archived](https://web.archive.org/web/20140506173840/http://www.ign.com/articles/2002/07/01/moto-racer-advance) |
| IGN-R | IGN, Craig Harris, review, 2003-01-13, [archived](https://web.archive.org/web/20140506040857/http://www.ign.com/articles/2003/01/13/moto-racer-advance-2) |
| GS | GameSpy, Steve Steinberg, review, [archived](https://web.archive.org/web/20051120195920/http://gba.gamespy.com/gameboy-advance/moto-racer-advance/5504p1.html) |
| GZ | GameZone, review, 2003-01-13 (the page's "Review Date"; Wikipedia gives 2003-01-12), [archived](https://web.archive.org/web/20090120190209/http://gameboy.gamezone.com/gzreviews/r20549.htm) |
| GN | Gaming Nexus, [review](https://www.gamingnexus.com/Article/155/Moto-Racer-Advance) |
| JV | jeuxvideo.com, review (French), 2002-10-15, [archived](https://web.archive.org/web/20201126102306/https://www.jeuxvideo.com/articles/0000/00002502_test.htm) |
| GF | GameFAQs, release data, [archived 2018-12-31](https://web.archive.org/web/20181231061445/https://gamefaqs.gamespot.com/gba/582307-moto-racer-advance/data) |
| GF-C | GameFAQs, cheats page, [archived 2019-12-12](https://web.archive.org/web/20191212061407/https://gamefaqs.gamespot.com/gba/582307-moto-racer-advance/cheats) (no cheats listed) |
| GF-RR | GameFAQs, reader review 52443, [archived](https://web.archive.org/web/20181231062822/https://gamefaqs.gamespot.com/gba/582307-moto-racer-advance/reviews/52443) |
| MG | MobyGames, game page, [archived 2022-10-04](https://web.archive.org/web/20221004131332/https://www.mobygames.com/game/gameboy-advance/moto-racer-advance) |
| MG-T | MobyGames, tech info, [archived 2017-09-15](https://web.archive.org/web/20170915040224/http://www.mobygames.com:80/game/gameboy-advance/moto-racer-advance/techinfo) |
| MG-C | MobyGames, credits, [archived 2018-03-28](https://web.archive.org/web/20180328085923/http://www.mobygames.com/game/gameboy-advance/moto-racer-advance/credits) |
| YT | "Longplay of Moto Racer Advance", LongplayArchive, 2024-10-29, USA version, [YouTube](https://www.youtube.com/watch?v=uNqLLiutars): chapter list from the description, plus YouTube's preview thumbnails |

## What we could not check

- **The Cutting Room Floor:** no Moto Racer Advance page found by web search. tcrf.net blocks automated requests, and the Wayback Machine has no snapshot of `tcrf.net/Moto_Racer_Advance`. Absence **unverified**.
- **GameFAQs guides:** none in the Wayback Machine's index of the game's GameFAQs URLs (no `/faqs` path). The live site blocks automated requests.
- **GameSpot and Nintendo World Report reviews:** not found or not reachable.
- **RetroAchievements** has a game page, ID 8210 ([archived 2022-03-09](https://web.archive.org/web/20220309175108/https://retroachievements.org/game/8210), titled "Moto Racer Advance (Game Boy Advance)"). That copy shows 0 achievements and no leaderboards, so code notes with RAM addresses are unlikely. The live site blocks automated requests, so a set added since 2022 is not ruled out.
- **Data Crystal:** the Wayback Machine has no capture of a `Moto_Racer_Advance` or `Motoracer_Advance` page on `datacrystal.romhacking.net` or `datacrystal.tcrf.net`. Absence **unverified** (live site not checked).
- **Live MobyGames:** blocks automated requests. Archived copies of the older URL scheme were used instead.

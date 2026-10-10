# Initial findings

**Date:** 2026-10-10
**Scope:** Feasibility of a native browser port, done before any ROM analysis. Nothing here has been checked against the ROM yet.

This replaces an earlier French-language project recap. Its claims are listed below with their verification status.

## The game

| | |
|---|---|
| Title | Moto Racer Advance |
| Platform | Game Boy Advance |
| Release | 2002 |
| Developer | Adeline Software International (its last game) |
| Producer | Delphine Software International |
| Publisher | Ubisoft |

Source: [Wikipedia](https://en.wikipedia.org/wiki/Moto_Racer_Advance).

## Claims from the earlier recap

| Claim | Status | Notes |
|---|---|---|
| Release details above | Verified | Wikipedia |
| It is already playable in browsers through GBA emulators | Plausible | True of GBA emulation generally; not checked for this title specifically |
| No decompilation project exists | Consistent with search | Nothing found on 2026-10-10 |
| An "Ultimate" mode contains a sci-fi race with hover taxis and spaceships | **Unverified** | Check in-game during Phase 1 |
| The renderer is "Mode 7-like" | **Unverified** | No technical write-up found. Software-rendered polygons vs. affine backgrounds changes the enhancement path entirely; determine in Phase 1 |
| [malespiaut/motoracer_reverse](https://github.com/malespiaut/motoracer_reverse) is relevant | Exists, low relevance | File-format reverse engineering of the 1997 **PC** game, a different codebase. Unlicense |
| Effort: 3–10 days | **Disputed** | See below |
| Technical complexity: low to medium | **Disputed** | Well-documented GBA hardware helps emulator authors, not someone trying to understand the game's own code |
| A native port would be clearly better than emulation | Only with enhancements | A port that renders 240×160 like the original is pixel-identical to an emulator |
| Legal risk: medium | Agreed, with conditions | Acceptable only with a bring-your-own-ROM model and no game code or assets in the repo |

## How other browser ports were made

Every real port we found started from the game's C/C++ source code. The compile-to-browser step (Emscripten, WebGL/WebGPU) is mature, and AI speeds it up a lot. Getting source code is the hard part.

| Game | What it is | Starting point |
|---|---|---|
| GTA V (Oct 2026) | Local WebAssembly + WebGPU port, ~6,600 shaders converted to WGSL. Taken down within hours | Reportedly the source code leaked in 2023 |
| GTA Vice City (dos.zone) | WebAssembly port; players prove ownership with original game files. DMCA'd, later returned | reVC, a community decompilation built over years |
| Half-Life 2 | WebAssembly + WebGL 2 port, ~3 months of work | Not disclosed |
| Doom 3 | WebAssembly port | Official GPL source release |
| Rocket League "clones" | Remakes, not ports: new code and assets. Feasible because the physics is publicly documented (Psyonix GDC 2018 talk, the RocketSim reimplementation) | None |
| Rocket League / Call of Duty "in browser" | Cloud streaming, fan remakes, or spam pages | None |

**Implication:** Moto Racer Advance has no released, leaked, or decompiled source. Our real work is producing source-equivalent code, which is why the 3–10 day estimate doesn't hold.

## Approaches considered

| Approach | Rough effort | Result |
|---|---|---|
| Wrap an existing emulator (mGBA core in WebAssembly) | Days | Same as existing sites. Shaders and save states, nothing new |
| **Static recompilation** (ROM → C++ → WebAssembly) | Weeks, high variance | Native code with function-level hook points to replace subsystems one at a time |
| Full decompilation, then port | Many months | Full control |
| Remake from scratch | Weeks to months | A new game that feels like the original. Rejected: the goal is this game, not one like it |

**Chosen: static recompilation**, with readable C written later only for the subsystems we modify. To be confirmed by Phase 1.

A byte-matching decompilation (like the pret projects) is probably impractical. Those rely on agbcc, the GCC fork from Nintendo's SDK; a third-party studio in 2002 may have used ARM's commercial compiler instead (**unverified**). For reference, the matching decompilation of *Klonoa: Empire of Dreams* (GBA, 2001) took a year of study and tool-building before decompiling started, and was at about 51% in August 2026 despite heavy Claude Code use.

## Tooling

### gbarecomp

[mstan/gbarecomp](https://github.com/mstan/gbarecomp), checked 2026-10-10:

- Public. Created May 2026; last push 2026-10-09.
- **License: PolyForm Noncommercial 1.0.0.** Hobby and research use is fine; commercial use is not.
- Translates ARM and Thumb code to sharded C++, with a shared runtime modeling the PPU, audio, DMA, timers, interrupts, cartridge saves, and input.
- Code installed in RAM at runtime (common in GBA 3D engines for speed) falls back to an interpreter and is compiled into a persistent native cache. A strict mode fails on the first unresolved address instead.
- Targets: Windows (documented), WebAssembly via Emscripten with pthreads (`build_web.sh`), experimental Android. macOS and Linux are not documented.
- Supported games include Mario Kart: Super Circuit, Minish Cap, and the Pokémon Gen 3 games. All are labeled "experimental previews".
- Per-game setup: `gbarecomp build --rom … --output … --config game.toml`. Reaching a playable port needs "verified function coverage, a host application, cartridge configuration, and game-specific validation".

Browser builds with Emscripten and pthreads need cross-origin isolation (COOP/COEP headers) for `SharedArrayBuffer`. That affects hosting.

### Reference emulator

mGBA on desktop: debugger, I/O register viewer, memory viewer. It's the ground truth for differential testing (same inputs, compare frames and RAM).

[gbajs3](https://github.com/thenick775/gbajs3) runs an mGBA core compiled to WebAssembly, if we ever need an in-browser reference.

## Open questions for Phase 1

1. Which ROM revision do we target? Pin it by SHA-1.
2. What does the game render with during races: bitmap mode with software-drawn polygons, or tile/affine backgrounds?
3. Which compiler built it? (This decides whether matching decompilation is ever viable.)
4. How much code is copied into RAM and run from there?
5. Sound engine: Nintendo's standard M4A, or custom? (gbarecomp models M4A.)
6. Save type: EEPROM, SRAM, or flash?
7. Does gbarecomp build on macOS, and what function coverage does it reach on this ROM out of the box?
8. What does Ultimate mode actually contain?

## Sources

- [Wikipedia: Moto Racer Advance](https://en.wikipedia.org/wiki/Moto_Racer_Advance)
- [Longplay of Moto Racer Advance (YouTube)](https://www.youtube.com/watch?v=uNqLLiutars)
- [MobyGames entry](https://www.mobygames.com/game/65460/moto-racer-advance/) (link not verified; the site blocks automated requests)
- [mstan/gbarecomp](https://github.com/mstan/gbarecomp)
- [Starting a decompilation project from zero: Claude Code and 51% of a 2001 GBA game](https://gambiconf.substack.com/p/starting-a-decompilation-project)
- [Tom's Hardware: GTA V browser port taken down](https://www.tomshardware.com/video-games/pc-gaming/gta-v-playable-in-browser-immediately-nuked-unofficial-webassembly-port-built-with-ai-gets-taken-down-within-hours-of-going-live)
- [Ubergizmo: GTA V ported to run locally in browser](https://www.ubergizmo.com/2026/10/gta-v-ported-browser/)
- [Gizmodo: AI and illegal game ports](https://gizmodo.com/browser-based-grand-theft-auto-v-shows-how-ai-is-making-it-easy-to-illegally-port-games-to-new-platforms-2000822395)
- [Dexerto: GTA Vice City back in the browser after takedown](https://www.dexerto.com/gta/gta-vice-city-is-playable-in-your-browser-again-after-take-two-takedown-3406096/)
- [SAYS: Half-Life 2 in the browser](https://says.com/my/gaming/half-life-2-browser)
- [Rocket League at GDC 2018](https://www.rocketleague.com/news/rocket-league-at-gdc-2018)

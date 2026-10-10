# Moto Racer Advance – Browser Port

An unofficial, noncommercial attempt to port *Moto Racer Advance* (Game Boy Advance, 2002) to run natively in the browser, instead of through a generic emulator.

**Status:** Phase 0, project setup. Nothing playable yet. See [docs/plan.md](docs/plan.md).

## Approach

Statically recompile the game's ARM/Thumb machine code to C++ with [gbarecomp](https://github.com/mstan/gbarecomp), compile it to WebAssembly, and then replace parts of it (starting with the renderer) to go beyond what the GBA could do: higher resolution, widescreen, a higher frame rate.

Why this route, and what else was considered: [docs/research/initial-findings.md](docs/research/initial-findings.md).

## Bring your own ROM

This repository contains no game code, data, or assets, and never will. To play, you supply your own dump of the game; it is processed locally in your browser and never uploaded.

## Docs

- [Plan](docs/plan.md): phases, deliverables, exit criteria, risks
- [Initial findings](docs/research/initial-findings.md): feasibility research, prior art, open questions

## Legal

*Moto Racer* is a trademark of its respective owners. This project is not affiliated with or endorsed by Ubisoft, Delphine Software International, or Adeline Software International.

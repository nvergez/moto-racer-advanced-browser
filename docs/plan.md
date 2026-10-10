# Plan

Port *Moto Racer Advance* to the browser by static recompilation, then improve on the original. Background and alternatives: [research/initial-findings.md](research/initial-findings.md).

Each phase ends with something that runs, so the project has value even if a later phase stalls. Effort figures are rough guesses until Phase 1 is done.

## Phase 0: Project setup ✅

- README, CLAUDE.md (English-only and legal-hygiene rules), `.gitignore` for ROMs, BIOS, saves, extracted assets, and generated code.
- English rewrite of the earlier French recap: `docs/research/initial-findings.md`.

## Phase 1: Investigation (~2–4 days, needs the ROM)

Answer the open questions in the findings doc before committing further.

- Pin the ROM revision by SHA-1.
- In mGBA, find out how races are rendered (video mode in `DISPCNT`, what's in VRAM), the save type, and the sound engine.
- Fingerprint the compiler from code patterns.
- Measure how much code runs from RAM.
- Build gbarecomp on macOS (undocumented, so this may need fixes or a Linux container). Run it on the ROM and record function coverage and interpreter fallbacks.
- Play through Ultimate mode and document its content.

**Exit:** `docs/adr/0001-*.md` confirming static recompilation, or switching approach, with evidence.

## Phase 2: Native recompiled build (weeks, high variance)

Debugging is far easier native than in WebAssembly, so get it working on desktop first.

- Recompile to C++ and build a native binary with gbarecomp's runtime.
- Milestones: boots, title screen, menus, one race, a full cup, saves work.
- Differential testing: record input sequences in mGBA, replay them in the recompiled build, and compare frames and key RAM per frame. Any divergence is a bug to fix.
- Push function coverage until no interpreter fallbacks remain on normal play paths.

**Exit:** a full cup plays identically to mGBA under the input replays.

## Phase 3: Browser build (~1–2 weeks)

- Compile with gbarecomp's Emscripten target.
- Web shell:
  - ROM file picker that checks the SHA-1 and stores the ROM in IndexedDB, never uploading it
  - Keyboard, gamepad, and touch input
  - Persistent saves
  - Audio unlocked on first user interaction
- Hosting with COOP/COEP headers (required for pthreads/`SharedArrayBuffer`).
- Performance check on a mid-range laptop and a recent phone.

**Exit:** playable at full speed in desktop Chrome, Firefox, and Safari.

## Phase 4: Enhancements (weeks to months)

The payoff over emulation. The order depends on Phase 1's rendering findings.

- **Resolution:** find the rendering entry point and replace it with a WebGL/WebGPU path that draws the same scene at screen resolution.
  - Software polygons: intercept the transformed triangles.
  - Affine backgrounds: re-render the layers at higher resolution.
- **Widescreen:** widen the camera's field of view and fix whatever stops objects outside the original frame from being drawn.
- **Frame rate:** if the game runs below 60 fps (**unverified**), look at interpolating between frames or decoupling rendering from the simulation.

## Phase 5: Readable source for touched subsystems (optional, ongoing)

Hand-written C for the renderer, camera, and physics as Phase 4 needs them. Verify against the recompiled originals with the Phase 2 replay harness.

Open decision: generated code stays out of the repo. Whether hand-decompiled code can be committed (the pret projects do this) needs a decision before this phase.

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| gbarecomp can't handle this ROM (heavy use of RAM-installed code, unusual compiler output) | Phase 2 stalls | Measured in Phase 1. Fallback: contribute fixes upstream, or ship an emulator-based build and pursue enhancements via emulator hooks |
| gbarecomp is young (since May 2026) and changes fast | Breakage on upgrades | Pin a commit; upgrade deliberately |
| PolyForm Noncommercial license | No commercial use, ever | Accepted for a hobby project. Revisit if goals change |
| Publisher takedown (both GTA browser ports were taken down) | Hosting removed | Bring-your-own-ROM, no game code or assets in the repo, noncommercial |
| Browser memory, threading, and audio limits | Crashes or stutter, especially on mobile | GBA scale is tiny compared to GTA V; measure in Phase 3 |
| Renderer replacement harder than expected | Phase 4 slips | Phases 2–3 are still a working port without it |

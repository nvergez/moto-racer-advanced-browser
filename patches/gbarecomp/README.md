# Local patches to gbarecomp

Fixes we need in gbarecomp before upstream has them. They form a series: `scripts/apply-patches.sh` applies every `*.patch` here in name order, each on top of the pinned commit plus the patches before it, to the submodule's working tree. `scripts/setup.sh` runs it, and so does every build script before it builds anything. We never commit inside the submodule: the repository records only the pinned gbarecomp commit. After setup, `git status` shows `gbarecomp (modified content)`; that is the applied series.

**License.** gbarecomp is Copyright (c) 2026 Matthew Stanley and licensed under the [PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0) (`gbarecomp/LICENSE`). These patches change gbarecomp and contain excerpts of its source, so they are distributed under the same terms, for noncommercial purposes only.

The native build and gbarecomp's own tests pass on macOS arm64 without any patch at the pin (`5e89943528aee7bc1c399bdbd035364a4b41dd10`). `0001` is for running the browser bundle; `0002` makes one of gbarecomp's browser unit tests reliable on a busy Linux CI runner; `0003` and `0004` fix the runtime's IRQ call-return leak and its end-of-run IRQ watchdog ([Phase 2 diagnosis](../../docs/research/phase2-diagnosis.md), §1.1 and §1.2), without which the game aborts after about 2,700 frames; `0005` adds the capture that compares gbarecomp with mGBA.

## Current patches

| Patch | What it fixes | Why we need it | Upstreamable |
|---|---|---|---|
| `0001-cli-accept-state-dir.patch` | Adds `--state-dir` to `kCliValueFlags` in `src/runtime/runtime.cpp` | `parse_cli()` refuses any value flag missing from that table, and the browser page always passes `--state-dir` (`packaging/web/bootstrap.js:62`). Without the fix every web launch exits with code 1 before booting: `internal: value flag --state-dir is missing from kCliValueFlags`. Seen in the desktop app's Chromium pane and in a native run. `scripts/smoke-test.sh` checks it without a BIOS. | Yes: one line, no behavior change for other flags |
| `0002-web-test-wait-for-pick.patch` | `tests/web/bootstrap_test.js` waits for each simulated file pick to log its outcome (10 s deadline) instead of a fixed 40 event-loop turns | The page hashes picked files with `crypto.subtle.digest`, which Node finishes on its thread pool. On the `ubuntu-24.04` CI runner the hash arrived after the 40 turns in both runs, so `web_bootstrap_tests` failed at a different check each time. Delaying each digest by 1 ms reproduces it on macOS every time; with the patch the test passes with delays of 0 to 200 ms. Test-only: the page is unchanged | Yes: test-only |
| `0003-irq-call-return-leak.patch` | When an IRQ-continuation bridge heals at a static entry, pops the call-return frame whose return the interpreter just performed (`runtime_call_should_return`, `src/runtime/runtime_arm_default_aborts.cpp`); at the end of `runtime_irq()`, drops any frame left above the handler's entry depth, as the resumable path already does (`src/armv4t/runtime_arm.cpp`) | An IRQ handler's call into code with no static entry (the front end's IWRAM sound mixer, through a ROM veneer) leaks one frame per IRQ, and a leaked `0x08004E10` later becomes the stop PC of a mainline bridge that never reaches it: `SELF-HEAL bridge for 0x08003E70 exceeded 200000000 instructions`, exit 134, in every native run of 2,716 frames or more (diagnosis §1.3) and in the browser right after the title. `scripts/repro-test.sh` reproduces it with three synthetic ROMs (`tests/repro/`): all overflow the call-return stack without the patch (`--without 0003 --expect-failure`) and pass with it. The third leaks through a function-entry hook, a bridge exit that only the second part covers, so it tests that part on its own | Yes (diagnosis §9, U1): the header has the mechanism and a repro without Nintendo data |
| `0004-quit-waits-for-irq-handlers.patch` | The present-in-place quit check in `runtime_should_yield()` (`src/runtime/runtime_bus_bridge.cpp`) gets the IRQ-depth guard the VBlank yield below it already has | After `--frames` is reached, every generated instruction yielded, IRQ handlers included, so each IRQ that arrived while a bridge still ran spun `runtime_irq()` to `handler at depth 1 did not iret after 4000000 dispatches`: 772 times in a 12,000-frame run of the game, none with the patch. Apply it with 0003: on its own it makes the 2,700-frame run abort (its header says why) | Yes (diagnosis §9, U2): one line |
| `0005-frame-capture.patch` | Adds `GBARECOMP_CAPTURE` (`src/runtime/frame_capture.{h,cpp}`): at every VBlank start, one record of the frame's CRC, its per-line video state, DISPCNT, memory fields, RAM region hashes, FIFO A/B bytes, I/O and HALTCNT writes, the clock and bridged instructions; full line records, FIFO bytes and raw frames for chosen frames; a file sink or a `[capture] ` console sink (diagnostics on stderr start with `capture: `). Also `GBARECOMP_MMIO_CAP_RING` to size the MMIO dump's ring (a ring that cannot be allocated is reported once), an I/O-write tap on its commit path (the capture's callback skips writes made during multiplayer session execution, through `runtime_session_executing()`), and a live bridged-instruction count. Off unless set | Comparisons of gbarecomp with mGBA and between its backends (ADR 0001, decision 5; P2-03) need the same observations from both engines at one sample point. gbarecomp has no headless per-frame record and no render-time line state, and its MMIO ring holds 262,144 writes, about 8 frames while a bridge spins in IntrWait. The format is in `tools/capture/README.md`; the harness writes the same with `--capture` | Yes, as an option (diagnosis U15, U16): observation only, off by default |

## Known candidate

`oracle/gba_cosim.py` passes the Windows-only `creationflags=0x00000200` to `subprocess.Popen`, which raises `ValueError` on macOS and Linux before the co-simulation starts. The one-line fix is `creationflags=0x00000200 if os.name == "nt" else 0` (gbarecomp integration study, `docs/research/gbarecomp-integration.md`, §7.2, PR #2). Nothing runs the co-simulation before Phase 2, so it is not added yet. Add it as the next patch when the co-simulation is first used. It looks upstreamable.

## How the series is applied

```sh
scripts/apply-patches.sh            # make gbarecomp/ the pin plus the series
scripts/apply-patches.sh --check    # exit 0 if it is, 1 if not; changes nothing in gbarecomp/
scripts/apply-patches.sh --reverse  # restore the pin
scripts/apply-patches.sh --diff     # what gbarecomp/ has on top of the pin plus the series
```

The script applies the series in order to a scratch index on top of the pin, never to the working tree directly, and then writes only the files whose content differs from what is there. So a patch may change lines that an earlier patch changed, or lines next to them. (PR #5's version judged each patch on its own against the fully patched tree. With two patches whose hunks overlap each other's context, the earlier one neither applied nor reverted there, so every build after the first stopped. `tests/tooling/apply-patches-test.sh` shows that case.)

Before it writes anything, the script checks that the current tree is a state it can explain:

- the pin;
- the pin plus a leading part of the series (several new patches pulled at once);
- the pin plus the series with one patch left out (an A/B build, below);
- what it last wrote, according to its stamp, `build/gbarecomp-patches/stamp`, including a run that stopped halfway;
- the series of one of the last 100 commits reachable from `HEAD` that changed `patches/gbarecomp/`. A series that only another branch has is not found this way.

From any of these it switches straight to the pin plus the current series (or the A/B variant asked for), removing files that an earlier series added and that the current one does not. Anything else is a hand edit, or a nested submodule (`external/arm-recomp-core`) that is not at its pinned commit: the script stops before writing anything, lists the files that differ from the closest known state, and says how to keep or discard them. The build scripts stop the same way, since they all run it first.

The pin is the commit checked out in `gbarecomp/`. When the repository records another one (`git ls-files -s gbarecomp`, for example after a pull that moved the pin without `git submodule update`), `--check` fails and the other modes warn.

The stamp records the pin, a hash of the series and the resulting tree. When it matches, the build scripts' check takes about 0.1 s and changes nothing. `build/gbarecomp-patches/` also holds the scratch git objects the script creates, so that it adds nothing to the submodule's repository, and the build lock (below). Deleting the directory loses nothing, with one exception: the script recognizes the tree from the other states listed above, but not the tree of an A/B build that left two or more patches out. Every build then stops as for a hand edit, until `scripts/apply-patches.sh` is run with the same `--without` options; the message says so. Do not save that tree with `--write-patch`: the patch would undo the patches left out. The script writes files only in the submodule's working tree, and only to switch between known states.

## A/B builds: leaving patches out

To build without some patches, for example to show that a bug comes back without its fix, pass `--without` to any build script:

```sh
scripts/build-native.sh --without 0003           # into build/without-0003/native
scripts/test-engine.sh --without 0003 -R some_test
scripts/smoke-test.sh --native-only --without 0001
MRA_WITHOUT_PATCHES="0003 0007" scripts/regen.sh  # the same through the environment
```

`NAME` is a patch's number or file name, and `--without` can be repeated. The script applies the series without those patches, and every output of the build goes under `build/without-NAME/` (for several, `build/without-0003-0007/`): the gbarecomp tools, the generated code, the native and web builds, logs and saves. Apart from `build/gbarecomp-patches/`, an A/B build never writes the normal `build/` or `generated/`. The next normal build switches the submodule back to the full series; only the files that differ are written, so the normal build recompiles only what depends on them. `scripts/apply-patches.sh --without NAME` switches the tree without building, and `scripts/serve-web.sh --without NAME` serves the bundle that `scripts/build-web.sh --without NAME` built.

A patch that stacks on one left out does not apply without it. The script then stops before writing anything and names both, for example `0009-....patch does not apply without 0007, which it stacks on`: leave it out too (`--without 0007 --without 0009`).

**One build at a time per checkout.** An A/B build switches `gbarecomp/` itself, the tree the normal build compiles too. So the build scripts, and `apply-patches.sh` in every mode but `--check` and `--diff`, hold a lock, `build/gbarecomp-patches/lock`, for their whole run. One started meanwhile waits, and says what it is waiting for. A lock left by a script killed with `SIGKILL` is removed by the next run, with a warning. After an A/B build, `gbarecomp/` keeps the variant until the next normal build script or `apply-patches.sh` run, as the build says at the end. A build by hand (`cmake --build`, `docs/toolchain.md`) takes no lock and compiles whatever is in place: run `scripts/apply-patches.sh` first, and not while a script runs. To build two series at the same time, use a second git worktree.

Example: `scripts/smoke-test.sh --native-only --without 0001` fails with `internal: value flag --state-dir is missing from kCliValueFlags`, the bug 0001 fixes, and the next `scripts/smoke-test.sh` restores 0001 and passes.

## Adding a patch

1. Make the change in `gbarecomp/`.
2. Save it as the next patch: `scripts/apply-patches.sh --write-patch patches/gbarecomp/NNNN-short-name.patch`, numbered after the last one. It writes the difference between `gbarecomp/` and the pin plus the existing series. The build scripts refuse to build while `gbarecomp/` has an edit that no patch holds, so save before each build. After further edits, run the same command again: it rewrites the file and keeps its header, the blank lines under it included.
3. Build and test the change.
4. Above the first `diff --git` line, which `git apply` ignores, write the header: what the patch fixes, why, and how it was tested, ready for upstream.
5. Add a row to the table above.
6. `scripts/apply-patches.sh --check` reports the series as applied.

## Changing a patch in the middle of the series

`--write-patch FILE` writes FILE against the patches that come before it in the series, so that it applies at its place: for `0007-x.patch`, the pin plus 0001 to 0006. The patches after it are first taken back out of the tree (reverse-applied in a scratch index), so that their changes stay out of FILE and they still apply on top of it. The script then checks that the series gives the current tree. With nothing changed, it leaves a patch it wrote byte for byte as it was.

When the edit overlaps a later patch (it changes that patch's lines or the three lines around them, as happens when the later patch stacks on FILE), the script cannot tell which of the two the edit belongs to. It stops, names both patches and writes nothing. Take the later patch out first. For example, with 0009 stacked on 0007:

1. `scripts/apply-patches.sh --without 0009`, then make the edit in `gbarecomp/`. If it is already made on the full series, save it with `scripts/apply-patches.sh --diff > build/edit.diff` and undo it with `git -C gbarecomp apply -R ../build/edit.diff` first, then make it again after the switch.
2. `scripts/apply-patches.sh --write-patch patches/gbarecomp/0007-x.patch --without 0009`.
3. `scripts/apply-patches.sh`. If 0009 still applies, that is all. Otherwise it stops at 0009, and nothing is written: `git -C gbarecomp apply --reject ../patches/gbarecomp/0009-y.patch` applies the hunks that still fit and leaves the others in `.rej` files. Make those changes by hand, delete the `.rej` files, and run `scripts/apply-patches.sh --write-patch patches/gbarecomp/0009-y.patch`.

`tests/tooling/apply-patches-test.sh` runs these steps on its toy series.

## Moving the pin

1. `scripts/apply-patches.sh --reverse`
2. Move the submodule and record it: `git -C gbarecomp checkout NEW`, `git -C gbarecomp submodule update -- external/arm-recomp-core` (in case NEW moves it), then `git add gbarecomp`. Until the new commit is recorded, the script warns that `gbarecomp/` is not at the commit the repository records, and `--check` fails.
3. Run `scripts/apply-patches.sh`. It stops at the first patch that no longer applies on the new pin, before writing anything: refresh it, or drop it if upstream fixed the problem.

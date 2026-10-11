# Local patches to gbarecomp

Fixes we need in gbarecomp before upstream has them. They form a series: `scripts/apply-patches.sh` applies every `*.patch` here in name order, each on top of the pinned commit plus the patches before it, to the submodule's working tree. `scripts/setup.sh` runs it, and so does every build script before it builds anything. We never commit inside the submodule: the repository records only the pinned gbarecomp commit. After setup, `git status` shows `gbarecomp (modified content)`; that is the applied series.

**License.** gbarecomp is Copyright (c) 2026 Matthew Stanley and licensed under the [PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0) (`gbarecomp/LICENSE`). These patches change gbarecomp and contain excerpts of its source, so they are distributed under the same terms, for noncommercial purposes only.

The native build and gbarecomp's own tests pass on macOS arm64 without any patch at the pin (`5e89943528aee7bc1c399bdbd035364a4b41dd10`). `0001` is for running the browser bundle; `0002` makes one of gbarecomp's browser unit tests reliable on a busy Linux CI runner.

## Current patches

| Patch | What it fixes | Why we need it | Upstreamable |
|---|---|---|---|
| `0001-cli-accept-state-dir.patch` | Adds `--state-dir` to `kCliValueFlags` in `src/runtime/runtime.cpp` | `parse_cli()` refuses any value flag missing from that table, and the browser page always passes `--state-dir` (`packaging/web/bootstrap.js:62`). Without the fix every web launch exits with code 1 before booting: `internal: value flag --state-dir is missing from kCliValueFlags`. Seen in the desktop app's Chromium pane and in a native run. `scripts/smoke-test.sh` checks it without a BIOS. | Yes: one line, no behavior change for other flags |
| `0002-web-test-wait-for-pick.patch` | `tests/web/bootstrap_test.js` waits for each simulated file pick to log its outcome (10 s deadline) instead of a fixed 40 event-loop turns | The page hashes picked files with `crypto.subtle.digest`, which Node finishes on its thread pool. On the `ubuntu-24.04` CI runner the hash arrived after the 40 turns in both runs, so `web_bootstrap_tests` failed at a different check each time. Delaying each digest by 1 ms reproduces it on macOS every time; with the patch the test passes with delays of 0 to 200 ms. Test-only: the page is unchanged | Yes: test-only |

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
- the series of any earlier commit of this repository that changed `patches/gbarecomp/`.

From any of these it switches straight to the pin plus the current series (or the A/B variant asked for), removing files that an earlier series added and that the current one does not. Anything else is a hand edit, or a nested submodule (`external/arm-recomp-core`) that is not at its pinned commit: the script stops before writing anything, lists the files that differ from the closest known state, and says how to keep or discard them. The build scripts stop the same way, since they all run it first.

The stamp records the pin, a hash of the series and the resulting tree. When it matches, the build scripts' check takes about 0.1 s and changes nothing. `build/gbarecomp-patches/` also holds the scratch git objects the script creates, so that it adds nothing to the submodule's repository. Deleting the directory loses nothing: the script then recognizes the tree from the other states listed above, or stops as for a hand edit. It writes files only in the submodule's working tree, and only to switch between known states.

## A/B builds: leaving patches out

To build without some patches, for example to show that a bug comes back without its fix, pass `--without` to any build script:

```sh
scripts/build-native.sh --without 0003           # into build/without-0003/native
scripts/test-engine.sh --without 0003 -R some_test
scripts/smoke-test.sh --native-only --without 0001
MRA_WITHOUT_PATCHES="0003 0007" scripts/regen.sh  # the same through the environment
```

`NAME` is a patch's number or file name, and `--without` can be repeated. The script applies the series without those patches, and every output of the build goes under `build/without-NAME/` (for several, `build/without-0003-0007/`): the gbarecomp tools, the generated code, the native and web builds, logs and saves. Apart from the stamp, an A/B build never writes the normal `build/` or `generated/`, so they never hold anything built from a different series. The next normal build switches the submodule back to the full series; only the files that differ are written, so the normal build recompiles only what depends on them. `scripts/apply-patches.sh --without NAME` switches the tree without building.

Example: `scripts/smoke-test.sh --native-only --without 0001` fails with `internal: value flag --state-dir is missing from kCliValueFlags`, the bug 0001 fixes, and the next `scripts/smoke-test.sh` restores 0001 and passes.

## Adding a patch

1. Make the change in `gbarecomp/`.
2. Save it as the next patch: `scripts/apply-patches.sh --write-patch patches/gbarecomp/NNNN-short-name.patch`, numbered after the last one. It writes the difference between `gbarecomp/` and the pin plus the existing series. The build scripts refuse to build while `gbarecomp/` has an edit that no patch holds, so save before each build. After further edits, run the same command again: a file that is already part of the series is left out of the base, and its header is kept.
3. Build and test the change.
4. Above the first `diff --git` line, which `git apply` ignores, write the header: what the patch fixes, why, and how it was tested, ready for upstream.
5. Add a row to the table above.
6. `scripts/apply-patches.sh --check` reports the series as applied.

`--write-patch` on a patch in the middle of the series diffs against a tree that includes the later patches. If their hunks are close, the script warns that the series no longer gives the current tree; refresh the later patches too.

## Moving the pin

1. `scripts/apply-patches.sh --reverse`
2. Move the submodule, then run `scripts/apply-patches.sh`. It stops at the first patch that no longer applies on the new pin, before writing anything: refresh it, or drop it if upstream fixed the problem.

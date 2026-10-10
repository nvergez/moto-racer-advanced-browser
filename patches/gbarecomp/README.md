# Local patches to gbarecomp

Fixes we need in gbarecomp before upstream has them. `scripts/apply-patches.sh` applies every `*.patch` here, in name order, to the submodule's working tree, and `scripts/setup.sh` runs it. We never commit inside the submodule: the repository records only the pinned gbarecomp commit. After setup, `git status` shows `gbarecomp (modified content)`; that is the applied patches.

The native build and gbarecomp's own tests pass on macOS arm64 without any patch at the pin (`5e89943528aee7bc1c399bdbd035364a4b41dd10`). `0001` is for running the browser bundle; `0002` makes one of gbarecomp's browser unit tests reliable on a busy Linux CI runner.

## Current patches

| Patch | What it fixes | Why we need it | Upstreamable |
|---|---|---|---|
| `0001-cli-accept-state-dir.patch` | Adds `--state-dir` to `kCliValueFlags` in `src/runtime/runtime.cpp` | `parse_cli()` refuses any value flag missing from that table, and the browser page always passes `--state-dir` (`packaging/web/bootstrap.js:62`). Without the fix every web launch exits with code 1 before booting: `internal: value flag --state-dir is missing from kCliValueFlags`. Seen in the desktop app's Chromium pane and in a native run. `scripts/smoke-test.sh` checks it without a BIOS. | Yes: one line, no behavior change for other flags |
| `0002-web-test-wait-for-pick.patch` | `tests/web/bootstrap_test.js` waits for each simulated file pick to log its outcome (10 s deadline) instead of a fixed 40 event-loop turns | The page hashes picked files with `crypto.subtle.digest`, which Node finishes on its thread pool. On the `ubuntu-24.04` CI runner the hash arrived after the 40 turns in both runs, so `web_bootstrap_tests` failed at a different check each time. Delaying each digest by 1 ms reproduces it on macOS every time; with the patch the test passes with delays of 0 to 200 ms. Test-only: the page is unchanged | Yes: test-only |

## Known candidate

`oracle/gba_cosim.py` passes the Windows-only `creationflags=0x00000200` to `subprocess.Popen`, which raises `ValueError` on macOS and Linux before the co-simulation starts. The one-line fix is `creationflags=0x00000200 if os.name == "nt" else 0` (gbarecomp integration study, §7.2). Nothing runs the co-simulation before Phase 2, so it is not added yet. Add it as the next patch when the co-simulation is first used. It looks upstreamable.

## Adding a patch

1. Make the change in `gbarecomp/` and test it.
2. `git -C gbarecomp diff > patches/gbarecomp/NNNN-short-name.patch`, numbered after the last one. Text above the first `diff --git` line is ignored by `git apply`: use it to say what the patch fixes and why.
3. Add a row to the table above.
4. Check that `scripts/apply-patches.sh --check` reports it as applied.

## Moving the pin

1. `scripts/apply-patches.sh --reverse`
2. Move the submodule, then run `scripts/apply-patches.sh`. It stops on a patch that no longer applies: refresh it, or drop it if upstream fixed the problem.

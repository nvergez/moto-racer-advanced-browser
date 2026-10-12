# Differential testing

Routes, and the comparison of gbarecomp with its interpreter and with mGBA on them ([ADR 0001](../../docs/adr/0001-port-via-static-recompilation.md), decision 5; [phase2-plan.md](../../docs/phase2-plan.md), P2-04 and P2-09). The results behind the allowlists and the comparison-1 measurement are in [phase2-comparator.md](../../docs/research/phase2-comparator.md).

| File | What |
|---|---|
| `routes.toml`, `routes.py` | The route manifest (input script, frame count, starting save, checkpoints) and its tool: `check ROUTE CAPTURE` says whether a run follows a route ([tools/analysis/README.md](../analysis/README.md), "Routes") |
| `mgba-routes.sh` | Every route twice in the mGBA harness: determinism, checkpoints on their recorded frames, final saves |
| `compare.py` | The comparator: comparison 1 or 2 on two VBlank-start captures (below) |
| `comparison1.toml` | RAM regions comparison 1 leaves out, each with its cause (none so far) |
| `allowlists/ROUTE.toml` | Per-route allowlists of comparison 2 |
| `detail_lists.py` | The capture lists of the runner's detail pass, bounded (below, "Detail") |
| `fpdiff.py` | Where two gbarecomp runs part, instruction by instruction, from the tails of gbarecomp's fingerprint ring |
| `timeline.py` | Aligns mGBA's and gbarecomp's instruction timelines with their clocks (P2-13) |
| `tests/` | Unit tests on synthetic data, run in CI: `python3 -I -m unittest discover tools/difftest/tests` |

All the Python tools are stdlib only, run with `python3 -I`, and need Python 3.11 or newer (`tomllib`). Captures, line records, raw frames and fingerprint tails are derived from the ROM: they stay under `build/` or `analysis-out/` and are never committed.

## Running a comparison

`scripts/replay-test.sh ROUTE --against interp|mgba` does everything: the replay of the route's input script ([tools/replay](../replay/README.md)), both runs with the per-frame capture ([tools/capture](../capture/README.md)), the route's checkpoints on the gbarecomp run, the comparison, and a second pass for the frames that need detail. It needs the ROM, the BIOS, `build/native` (`scripts/build-native.sh`) and, against mGBA, the harness (`tools/analysis/harness/build.sh`, or `HARNESS_BIN`).

```sh
scripts/replay-test.sh boot_to_race --against mgba            # comparison 2, gbarecomp's interpreter until P2-10
scripts/replay-test.sh boot_to_race --against interp          # comparison 1, the recompiled build
scripts/replay-test.sh boot_to_race --against interp --frames 1-3290 --fp-ring 295
scripts/replay-test.sh cup --against none --test reference     # checkpoints only, no comparison
```

| Option | |
|---|---|
| `--against interp` | Comparison 1: the recompiled build against gbarecomp's interpreter with the BIOS interpreted too (`GBARECOMP_FORCE_INTERP=1 MRA_INTERP_BIOS=1`). `--reference plain` uses the interpreter alone, whose SWIs run the recompiled BIOS: a difference with the BIOS reference that the plain interpreter does not show is in the BIOS translation |
| `--against mgba` | Comparison 2: gbarecomp against the mGBA harness, with `allowlists/ROUTE.toml`. `--test interp` (the default until P2-10, which compiles the IWRAM code: before that the recompiled build cannot run a race, diagnosis §3.4), `reference` or `recompiled` picks the gbarecomp side |
| `--against none` | Only the gbarecomp side, and its checkpoints |
| `--frames [A-]B` | Compare frames A-B (1 <= A <= B) and stop the runs at B. Checkpoints after B are reported as not reached (`routes.py check --partial`), and the summary says how many were checked |
| `--frame-map SPEC` | Pair frames across a known offset (below) |
| `--script FILE` | Another input script on both sides; the checkpoints stay the route's |
| `--replay-offset K` | The gbarecomp side's inputs K frames late (early if negative): a wrong convention must fail |
| `--max-detail N` | Frames re-run with line records and raw frames (default 1200, at most 5000; about 116 KB per frame and side). See [Detail](#detail) for the bound |
| `--fp-ring FRAME`, `--fp-records N` | Comparison 1: run both sides to FRAME, from the route's starting save, with gbarecomp's fingerprint ring armed and diff their last N instructions (1 to 2,000,000, default 500,000) with `fpdiff.py` |
| `--timeout SECONDS` | Stop an engine run that takes longer: default 600 s plus 1 s per 20 frames the run plays; 0 for no limit |
| `--out DIR`, `--keep` | Where the outputs go (default `build/replay-test/ROUTE-AGAINST/`, below); keep the detail captures and fingerprint tails, which are deleted otherwise |

`--test` is refused with `--against interp` and `--reference` without it. A route that starts from another route's save runs that route first, on each side. Both sides run in parallel, headless and muted (`SDL_AUDIODRIVER=dummy`), with `GBARECOMP_SELFHEAL_RECOMPILE=0` and a fresh save. The harness plays a copy of the input script without its `dump`, `shot` and `savestate` commands, which write game screens, memory and savestates and do not change emulation (the per-frame captures of `boot_to_race` are byte-identical with and without them). The exit status is 0 only when both runs exit 0, the gbarecomp run follows the route and the comparison passes; 1 when one of those fails; 2 on a usage or setup error (a bad option, a missing input, an `--out` the runner does not own, not enough free disk, a tool that cannot read its input).

The runner owns its output directory. `--out` must be new, empty, or a directory the runner made, which holds a `.replay-test-out` file; inside the repository it must be under `build/`, since everything in it is derived from the ROM. Each run first deletes, by name, the files and directories the runner writes there, so the outputs of an earlier run (a starting save among them) never leak into the next one, and a file the runner did not write is never touched. In `--out`: `ref.tsv` and `test.tsv` (per-frame captures), `route-test.txt`, `compare.txt` (the report), `compare.json` (the summary), `frames.tsv` (one row per frame and check that differs, with its detail and how it was accounted for), and the logs. Before the detail pass and the fingerprint runs, the runner checks that what they write leaves at least `MRA_MIN_FREE_GB` (default 15) free on that disk. `tests/tooling/replay-test-args-test.sh` checks the option checks and the output-directory rules without game data, in CI.

## What is compared

Both comparisons read VBlank-start captures only, never `--dump-png` (diagnosis §7.3). Frames are harness frames.

**Comparison 1** (`--against interp`), recompilation correctness: `fb` (the frame CRC) and every `ram_*` region hash, exact on every frame, except the regions [`comparison1.toml`](comparison1.toml) lists, each with its cause. It takes no allowlist. Both sides share gbarecomp's device model, so a difference is a recompiler, dispatch, overlay or BIOS-translation problem until shown otherwise. The other columns (`lines`, `DISPCNT`, memory fields, FIFO, `io_writes`, `halt_writes`) are reported, not gated; so is `cycles`, as the range of TEST - REF. It runs and reports now; it gates from P2-10 on.

**Comparison 2** (`--against mgba`), emulation fidelity, in two layers plus RAM ([phase2-plan.md](../../docs/phase2-plan.md), P2-09; diagnosis §7.2):

- **Layer 1**, the per-line state: the `lines` CRC of each frame, exact. In detail, the line records give the lines and columns that differ.
- **Layer 2**, the pixels at 5-bit precision, for each frame whose `fb` CRC differs: from raw frames, exact on lines with no color effect and at most one step per channel on lines with one. A line has an effect, in either engine's line records, when BLDCNT selects brightness (mode 2 or 3) with a nonzero BLDY, alpha (mode 1) with a nonzero BLDALPHA, or when OBJs are on (DISPCNT bit 12) with a 2nd target in BLDCNT and a nonzero BLDALPHA, since a semi-transparent OBJ may blend and the records hold no OAM. Windows are not looked at. So the tolerance can apply on more lines than the effect really touches, never on fewer. Without line records no line has an effect (`frames.tsv` says `effect_lines=unknown(no_line_records)`). A frame whose `fb` differs and has no raw frames is undetermined for layer 2 and fails unless allowlisted.
- **RAM**: each `ram_*` region, reported with its first differing frame.

Each difference fails unless an entry of the route's allowlist covers that check on that frame. The other columns are reported only (P2-15 adds the FIFO bytes).

The report gives, per check, the frames that differ, those an entry allows and those that fail; the frames that pass layer 2 in detail; the first divergence (frame, check, and line, column and values when the detail has them), allowlisted or not, and the first failing one; and, per allowlist entry and check, the compared frames it hit out of those it covers (where it is the first entry to cover the check), with `UNUSED` for an entry nothing hit and `PARTLY USED`, followed by the frames it did not need, for one that covers more than differs.

Raw frames are checked against the captures: the CRC-32 of each one must equal the `fb` column of its frame, or `compare.py` stops with exit 2, since they would not be the frames that were compared. In comparison 1 an `fb` difference always fails; the raw frames only locate the first pixel.

## Allowlists

`allowlists/ROUTE.toml`, one per route of comparison 2:

```toml
schema = 1
route = "boot_to_race"
against = "mgba"

[[allow]]
id = "obj-1st-target"                # letters, digits, '_', '.', '-'
frames = "222-269, 2453-2481"        # harness frames: ranges and single frames
checks = ["layer2"]                  # layer1, layer2, ram:REGION or ram:*
cause = "what differs and why"
ref = "where the evidence is"
fixed_by = "P2-08"                   # optional: the task expected to remove it
```

Every entry carries its cause and a reference to the measurement. When two entries cover the same check on the same frame, the first one counts the hit. An entry names exact frames, and one check when its checks differ on different frames (split it into one entry per check): a range wider than the frames that differ hides what a later change breaks there, and the report marks such an entry `PARTLY USED`. The one exception is an entry for frames that are out of lockstep as a whole, where nearly everything differs and no frame is really compared (`race-starts-one-frame-late` until P2-21); it says so in its cause. `compare.py` refuses an entry with an unknown key or check, a region the captures do not hash, an empty cause or reference, or an id used twice, and, with `--route` (which `replay-test.sh` passes), the allowlist of another route. CI parses every committed allowlist and checks its regions against `tools/capture/spec.txt`.

## Detail

The per-frame pass streams both files and keeps the frames that differ. Frames whose CRCs differ need detail: line records for a `lines` difference, raw frames and line records for an `fb` difference. `compare.py --detail-out` lists them, frames no allowlist entry covers first, at most `--max-detail`; `replay-test.sh` re-runs both engines up to the last of them with `GBARECOMP_CAPTURE_LINES`/`--capture-lines` and `GBARECOMP_CAPTURE_RAW`/`--capture-raw`, checks that the per-frame records of the second runs equal the first runs' (the runs are deterministic, diagnosis §7.6), and calls `compare.py` again with the line records and raw frames.

A capture list holds at most 32 ranges, so the runner merges the closest ranges (`detail_lists.py`), but only while a side captures at most twice `--max-detail` frames; if more than 32 ranges remain, the frames after the 32nd get no detail (it warns), and those whose `fb` differs are undetermined. So one side writes at most 2 × 5,000 frames, about 1.2 GB, and its line records stay under 512 MB. The runner checks free disk space before the pass (`MRA_MIN_FREE_GB`). On a long route the default of 1,200 frames may not cover every frame that differs: on `boot_to_race`, 1,582 frames need detail and 382 race frames (4019-4400) stay undetermined, allowed today by the race's entry. Once that entry goes (P2-21), raise `--max-detail` to cover them, or they fail.

## Frame maps

For runs known not to be in lockstep, `--frame-map` pairs REF frame f with another TEST frame: `A-B:+K` with f+K (K may be negative), `A-B:~N` with the TEST frame in f-N to f+N that has the most equal gated per-frame columns (ties: the smallest offset, then the earlier frame), and the report prints the offsets the search chose, which can be passed back as fixed offsets. Frames outside every entry pair with themselves. Until P2-21 lands, gbarecomp's races start one frame late ([phase2-race-lockstep.md](../../docs/research/phase2-race-lockstep.md)), so race-frame studies such as P2-14's use a map; the exit gates use none unless the owner accepts one. `replay-test.sh` runs the TEST side as far as the map reaches.

## Fingerprint ring

`replay-test.sh --against interp --fp-ring FRAME` runs both gbarecomp sides to FRAME with `GBARECOMP_INSN_TRACE=1`, which arms gbarecomp's per-instruction fingerprint ring (`runtime_arm.cpp`, about 8M records of 80 bytes, 640 MB of memory per run), and `MRA_FP_TAIL`, with which our executable writes the last `MRA_FP_TAIL_RECORDS` records (500,000 by default, about 110 MB of CSV) when the run ends ([src/main.cpp](../../src/main.cpp)). gbarecomp's own `GBARECOMP_FP_SAVE` writes the whole ring, 640 MB once a run has executed 8M instructions (about 135 frames of this game). Then `fpdiff.py` aligns the two tails and reports the first instruction whose cost differs (a timing divergence, with the clock still the same state) and the first record whose state differs. FRAME should be the first frame whose capture differs: the ring keeps the last few frames before it.

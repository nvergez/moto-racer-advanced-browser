# Replays

Input replays for gbarecomp, made from the mGBA harness's input scripts, so that both engines play a route with the same inputs on the same frames ([phase2-plan.md](../../docs/phase2-plan.md), P2-02). The measurements behind the convention are in [phase2-replay.md](../../docs/research/phase2-replay.md).

| File | What |
|---|---|
| `script2replay.py` | Harness input script to replay, the routes table for test builds, and a check of a replay against a harness `trace.tsv` (stdlib, `python3 -I`; usage and the format at its top) |
| `tests/` | Unit tests on synthetic scripts and on the committed scripts, which hold inputs only: `python3 -I -m unittest discover tools/replay/tests` |

A replay holds key presses and frame numbers, nothing from the ROM. Keep generated replays and the routes table under `build/` anyway, with the rest of the build output.

## Making and checking a replay

```sh
mkdir -p build/replays
python3 -I tools/replay/script2replay.py tools/analysis/input/boot_to_race.txt > build/replays/boot_to_race.csv
python3 -I tools/replay/script2replay.py --route full_race_cross -o build/replays/full_race_cross.csv
```

`--route NAME` takes the script and the frame count from the [route manifest](../difftest/routes.toml), as `tools/difftest/mgba-routes.sh` runs it; a script on its own is converted as the harness runs it without `--frames` (`--frames N` for the same as the harness's option).

To check that a replay gives every frame the keys the harness gave it, run the harness with `--trace` over the frames and compare with its `keys` column:

```sh
tools/analysis/harness/run_harness.sh --out runs/b2r --script tools/analysis/input/boot_to_race.txt --trace 1-4400
python3 -I tools/replay/script2replay.py --check build/replays/boot_to_race.csv analysis-out/runs/b2r/trace.tsv
```

## The format and the frame convention

`mra-keyinput-v1`: the first line is exactly `mra-keyinput-v1`, then one `FRAME,0xKEYS` event per line (comments start with `#`). From harness frame `FRAME` on, KEYINPUT reads `KEYS` (active low, `0x03FF` is no key). `FRAME` is the harness's frame number ([tools/analysis/README.md](../analysis/README.md), "Frame numbering"): the keys of frame N are set right after the VBlank start that ends frame N-1, and `trace.tsv` shows them in its row N. Frames start at 2, because frame 1 runs from reset to the first VBlank start.

gbarecomp applies a replay at the same point: our `src/main.cpp` installs `RunOptions::input_frame`, which gbarecomp calls at each VBlank start, before the VBlank IRQ, with its PPU `frame_count` k. That VBlank start ends harness frame k+1, so the callback returns the keys of frame k+2.

gbarecomp's own `GBARECOMP_INPUT_REPLAY` reads the same `FRAME,0xKEYS` lines in files headed `# gbarecomp-keyinput-v1`, but numbers frames by its `frame_count` and applies them from its run loop, not at VBlank start, and not while an interpreter bridge holds the loop. Its loader skips only `#` lines, so it refuses a file in our format (`invalid input trace line: mra-keyinput-v1`) instead of replaying it on other frames.

## Running gbarecomp with a replay

The game executable takes two test variables, both off unless set ([`src/main.cpp`](../../src/main.cpp)):

| Variable | Effect |
|---|---|
| `MRA_REPLAY=FILE` | Replay FILE at VBlank start. Prints `mra_replay=FILE events=N frames=FIRST-LAST` before the game starts |
| `MRA_REPLAY=embedded:ROUTE` | The same with the route's replay compiled into a test build (below) |
| `MRA_INTERP_BIOS=1` | With `GBARECOMP_FORCE_INTERP=1`: the interpreter runs the BIOS too, the reference of comparison 1 (ADR 0001, decision 5). Its coverage banner reads `NOT_STATIC dispatch_misses=1`, because each BIOS entry is a bridge; no gate reads it. `0` or an empty value leaves it off |

From `build/native` (the native run of [phase2-plan.md](../../docs/phase2-plan.md), "Commands used below"):

```sh
(cd build/native && export GBARECOMP_FORCE_INTERP=1 MRA_INTERP_BIOS=1 MRA_REPLAY=../replays/boot_to_race.csv \
   GBARECOMP_CAPTURE=../cap/b2r.tsv GBARECOMP_CAPTURE_SPEC=@../../tools/capture/spec.txt \
   GBARECOMP_CAPTURE_MEM="$(python3 -I ../../tools/difftest/routes.py trace-mem)" &&
 mkdir -p ../saves ../cap && rm -f ../saves/t.sav &&
 SDL_AUDIODRIVER=dummy GBARECOMP_SELFHEAL_RECOMPILE=0 ./MotoRacerAdvanceRecomp \
   --bios ../../bios/gba_bios.bin --rom ../../roms/moto-racer-advance.gba \
   --frames 4400 --no-window --save-path ../saves/t.sav ../../game.toml)
```

A bad value stops the executable with exit code 2 and a line starting `mra: `: a replay that does not parse, an unknown embedded route, `MRA_REPLAY` together with `GBARECOMP_INPUT_REPLAY` (gbarecomp suspends `input_frame` during its own replay), `MRA_INTERP_BIOS` set to anything but `0` or `1`, or `MRA_INTERP_BIOS=1` without `GBARECOMP_FORCE_INTERP` (which is on, as gbarecomp reads it, when it is not empty and does not start with `0`). A non-null `input_frame` also switches gbarecomp to its touch-policy mode (`touch_policy=ENABLED` in the log, and the touch overlay in windowed and browser builds), which is why it is installed only when `MRA_REPLAY` is set.

## Embedded replays (test builds)

The browser bundle cannot read a replay file of ours: its page writes only the ROM, the BIOS and the config into the wasm file system. A test build therefore compiles every route's replay in, and `MRA_REPLAY=embedded:ROUTE` (through `?env=` in a `--dev` bundle on localhost) selects one:

```sh
scripts/build-native.sh --replays              # native test build; the next build without it removes them
scripts/build-web.sh --dev --embed-private-rom --replays   # test bundle, under build/ only, never published
```

Both run `script2replay.py --embed build/replays/replay_routes.cpp`, which needs Python 3.11 or newer to read the manifest. Natively the table is the root `CMakeLists.txt`'s `MRA_REPLAY_ROUTES` (empty by default); `build_web.sh` passes no `-D` options to `web/game-lib`, so `scripts/build-web.sh` hands it over in the `MRA_REPLAY_ROUTES` environment variable. Builds without replays link [`src/replay_routes_none.cpp`](../../src/replay_routes_none.cpp), an empty table. The browser bundle still links gbarecomp's own `main()`, so nothing in it uses the table until our main is linked in the browser (P2-12); that the replay works there is **unverified** until then.

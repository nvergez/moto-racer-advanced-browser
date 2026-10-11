# Seeds

Tools that find function entries gbarecomp's finder cannot reach on its own, and print them as `[[extra_func]]` candidates for a human to review before they go into [game.toml](../../game.toml). No tool writes `game.toml` ([phase2-plan.md](../../docs/phase2-plan.md), "Ground rules for every task").

| File | What |
|---|---|
| `find_switch_tables.py` | armcc switch tables in ARM code (`cmp rM, #N; addls pc, pc, rM, lsl #2; b default; b case_0; ...`): sizes each from its `cmp`, checks that every slot is a `b`, and prints the case slots as candidates, or checks `game.toml` against them (stdlib, `python3 -I`; usage and the checks at its top) |
| `tests/` | Unit tests on hand-encoded ARM words, no game data: `python3 -I -m unittest discover tools/seeds/tests` |

The output names ROM addresses and decoded `b` targets, nothing more; keep any longer output (disassembly, coverage) under `build/` or `analysis-out/` anyway.

## Switch tables

```sh
python3 -I tools/seeds/find_switch_tables.py roms/moto-racer-advance.gba          # report
python3 -I tools/seeds/find_switch_tables.py roms/moto-racer-advance.gba --toml   # candidates
python3 -I tools/seeds/find_switch_tables.py roms/moto-racer-advance.gba --check-config game.toml
```

The report has one line per dispatcher (`add pc, pc, rM, lsl #2` at a 4-byte boundary): where it is (ROM code, or a copy with its runtime address), the bounding `cmp` and how many instructions before the dispatcher it is, the number of cases, the slot range and the default target, or why the table was rejected. Lines marked `REVIEW` need a look before the table is used. Tables inside a copied range (a `[[code_copy]]`, or one of the IWRAM images not declared yet) are reported with their runtime addresses and never printed as ROM candidates; for the pinned ROM the four code copies of [phase1-findings.md](../../docs/research/phase1-findings.md) section 4 are built in, `--copy NAME=SOURCE,SIZE,RUNTIME` adds others.

`--check-config` exits 1 when `game.toml` lacks an ARM `[[extra_func]]` at a candidate slot, or holds an entry whose note calls it a case slot (the `--toml` wording) at an address that is not one. Run it after editing the switch-slot section of `game.toml`. What was found on the pinned ROM, and how the entries were reviewed: [phase2-switch-slots.md](../../docs/research/phase2-switch-slots.md).

The scanner handles the ARM form only. The race program also has Thumb byte-table switches (`cmp r0, #N; bhs; adr; ldrb; lsls; add pc`), whose case targets are left for P2-10 and P2-11 ([phase2-resume-roots.md](../../docs/research/phase2-resume-roots.md) section 8).

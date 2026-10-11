# Dispatch misses once the IRQ call-return leak is fixed

**Date:** 2026-10-11
**Scope:** Which PCs the interpreter bridges in the native game after patches 0003 and 0004 (P2-01, PR #11), on PR #5's config, and how they differ from the unpatched build. P2-05, P2-06 and P2-10 start from this list.
**Status:** Native gbarecomp runs, and static reading of the ROM with Capstone. No new `game.toml` entry comes from this document.

## Pins

| | |
|---|---|
| ROM | Moto Racer Advance (Europe) `A9MP`, SHA-1 `b91bad8ee04652d71e0610f8d1a5deaebd4c1fd0` |
| BIOS | retail, SHA-1 `300c20df6731a33952ded8c436f7f186d25d3492` |
| gbarecomp | `5e89943528aee7bc1c399bdbd035364a4b41dd10`, plus `patches/gbarecomp/` 0001-0004 as in PR #11 ("the series"), or 0001-0002 only ("the pin plus 0001-0002": neither touches these paths) |
| Config | `game.toml` as on `main` (PR #5's config: no `[[code_copy]]`, `static_resume_all` off) |
| Machine | M4 Pro, macOS, Apple clang 21 |

## How the lists were taken

The runs were made for PR #11 at `e315df4`. The review round that followed changed only comments and the header of `0003`; the series runs at 2,700, 3,600, 5,400 and 12,000 frames were repeated with it and gave the same stop frames, interpreted-instruction counts and `bridged` lines (PC, mode and count).

`scripts/build-native.sh` (with `--without 0003 --without 0004` for the pin plus 0001-0002), then the plan's native run from `build/native` ([phase2-plan.md](../phase2-plan.md), "Commands used below"): `SDL_AUDIODRIVER=dummy GBARECOMP_SELFHEAL_RECOMPILE=0`, a fresh save, `--no-window`, `--frames N`. At exit the runtime prints one line per bridged PC, `bridged 0x08001F94 (arm) x1 near gf_afunc_08001F84` (`src/runtime/runtime_arm_default_aborts.cpp:171` at the pin), and the miss count on the coverage line (`dispatch_misses=46`). The lists below are those lines. The instruction before each ROM miss was read from the ROM with Capstone 5.0.9 (ARM mode).

## Counts

| Build | `--frames` | Stopped at | Dispatch misses |
|---|---|---|---|
| pin plus 0001-0002 | 2,700 | 2,706 | 37 (2 IWRAM, 35 ROM) |
| series | 2,700 | 2,700 | 46 (3 IWRAM, 43 ROM) |
| series | 3,600 | 3,644 | 47 (3 IWRAM, 44 ROM) |
| series | 5,400 | 5,400 | 47 |
| series | 12,000 | 12,385 | 47 |
| series without 0004 | 3,600 and 12,000 | 3,644 and 12,385 | 47, the same PCs |

No PC of the unpatched list goes away. The pin plus 0001-0002 cannot be compared at 3,600 frames or more: from 2,716 frames on it aborts in the stale bridge of [phase2-diagnosis.md](phase2-diagnosis.md) §1.1. Its 2,700-frame run spent VBlank 1029 onward inside that bridge, where the interpreter runs the main program without dispatching, so the PCs that code would have dispatched were never counted as misses. With the fix the game runs that code natively and dispatches them, which is where the new misses come from (an inference from the diagnosis's trace, not traced again here).

## The ten new misses

New with the series, against the pin plus 0001-0002 at 2,700 frames: nine at 2,700 frames, and `0x08001FBC` from 3,600 frames on.

| PC | Mode | Instruction before it | Kind | Bridged at 2,700 / 3,600 / 5,400 / 12,000 frames |
|---|---|---|---|---|
| `0x03000000` | ARM | (IWRAM) | The front end's IWRAM intro player ([phase2-diagnosis.md](phase2-diagnosis.md) §2.3), reached through the ROM veneer `0x08011AB0` (`ldr pc, [pc, #-4]`, literal `0x03000000`) | 1 / 2 / 3 / 8 |
| `0x08001F54` | ARM | `bl 0x08003D68` | Return address | 1 / 1 / 1 / 1 |
| `0x08001F58` | ARM | `bl 0x080048C8` | Return address | 1 / 1 / 1 / 1 |
| `0x08001F7C` | ARM | `bl 0x08004ADC` | Return address | 1 / 1 / 1 / 1 |
| `0x08001F94` | ARM | `mov r2, #0` | **Not a return address**; see below | 1 / 1 / 3 / 7 |
| `0x08001FA0` | ARM | `bl 0x08004E78` | Return address | 1 / 1 / 3 / 7 |
| `0x08001FBC` | ARM | `bl 0x08003D68` | Return address | - / 1 / 2 / 7 |
| `0x0800387C` | ARM | `bl 0x08011AD0` | Return address | 1 / 1 / 3 / 7 |
| `0x08003DAC` | ARM | `bl 0x08002D34` | Return address | 1 / 1 / 3 / 7 |
| `0x08004EEC` | ARM | `bl 0x08011AF4` | Return address (`0x08011AF4` is the DivArm veneer, diagnosis §2.1) | 1 / 1 / 3 / 7 |

"Return address" means only that the word before the PC is a `bl`, the pattern of the diagnosis's 30 return-address misses (§2.1): after a SWI unwinds the host stack, the guest's return dispatches a mid-function address that has no entry while `static_resume_all` is off.

**`0x08001F94` is not a return address.** The word before it is `mov r2, #0` at `0x08001F90`, and the word before that is `bl 0x08011AB0` at `0x08001F8C`, the call to the intro player through its veneer. So the return address of that call is `0x08001F90`, one instruction earlier, and the word right before `0x08001F94` is not a `bl`, a `bx` or a `mov lr, pc`. A scan of the whole ROM finds no ARM `b`/`bl` whose target is `0x08001F90` or `0x08001F94`, and no aligned word equal to either address (or to either plus 1). How control gets to `0x08001F94` by a dispatch is **unverified**. One possibility, not checked: the long interpreter bridge of the intro player ends somewhere other than at its return address, and a later resume lands there. Do not seed it as a return site without that check (P2-05).

**Update (P2-05).** The stale HALT flag that the intro player's bridge leaves behind halts the generated code at `0x08001F94`, and the run loop dispatches that PC when the next IRQ ends the halt. Measured with `GBARECOMP_IRQ_LOG` on `boot_to_race`, on P2-05's config and on `main`'s config before it (no resume entries): both logs have a VCount IRQ at cycle 613,538,471 that wakes the main thread from HALT at `0x08001F94` (`from_halt=1`). On `main`'s config the verbose self-heal log then shows the dispatch miss at `0x08001F94`, entered with `LR=0x08001F90`. That the bridge stops exactly at its return address `0x08001F90` and that the generated code then yields at `0x08001F94` is read from the runtime's code, not traced (**unverified**). Details in [phase2-resume-roots.md](phase2-resume-roots.md) §6 and §9. With `static_resume_all` it is a resume alias and needs no seed.

## All 47 misses with the series

Counts are "bridged xN" at 2,700 / 3,600 / 5,400 / 12,000 frames with the series, and at 2,700 frames on the pin plus 0001-0002. "Switch slot" is a case slot of an armcc switch table (diagnosis §2.2); the others in ROM have a `bl` right before them.

| PC | Mode | Pin, 2,700 | Series, 2,700 / 3,600 / 5,400 / 12,000 | Kind | Instruction before it |
|---|---|---|---|---|---|
| `0x03000000` | ARM | - | 1 / 2 / 3 / 8 | IWRAM (new) | |
| `0x030004DC` | Thumb | 4,349 | 4,338 / 6,543 / 10,645 / 26,964 | IWRAM | |
| `0x03000708` | ARM | 4,512 | 4,501 / 6,390 / 9,901 / 23,872 | IWRAM | |
| `0x08001E44` | ARM | 1 | 1 / 1 / 1 / 1 | after `bl` | `bl 0x08003D68` |
| `0x08001EBC` | ARM | 1 | 1 / 1 / 1 / 1 | after `bl` | `bl 0x08002860` |
| `0x08001EC0` | ARM | 1 | 1 / 1 / 1 / 1 | after `bl` | `bl 0x08002370` |
| `0x08001F38` | ARM | 1 | 1 / 1 / 1 / 1 | after `bl` | `bl 0x08004ADC` |
| `0x08001F54` | ARM | - | 1 / 1 / 1 / 1 | after `bl` (new) | `bl 0x08003D68` |
| `0x08001F58` | ARM | - | 1 / 1 / 1 / 1 | after `bl` (new) | `bl 0x080048C8` |
| `0x08001F7C` | ARM | - | 1 / 1 / 1 / 1 | after `bl` (new) | `bl 0x08004ADC` |
| `0x08001F94` | ARM | - | 1 / 1 / 3 / 7 | **not after `bl`** (new) | `mov r2, #0` |
| `0x08001FA0` | ARM | - | 1 / 1 / 3 / 7 | after `bl` (new) | `bl 0x08004E78` |
| `0x08001FBC` | ARM | - | - / 1 / 2 / 7 | after `bl` (new from 3,600) | `bl 0x08003D68` |
| `0x08002598` | ARM | 1,736 | 1,731 / 2,675 / 4,431 / 11,416 | after `bl` | `bl 0x08004D38` |
| `0x08002630` | ARM | 1 | 1 / 1 / 1 / 1 | after `bl` | `bl 0x08004678` |
| `0x08002638` | ARM | 1 | 1 / 1 / 1 / 1 | after `bl` | `bl 0x08004860` |
| `0x08002644` | ARM | 1 | 1 / 1 / 1 / 1 | after `bl` | `bl 0x08004E38` |
| `0x08002650` | ARM | 1 | 1 / 1 / 1 / 1 | after `bl` | `bl 0x08011AC4` |
| `0x080028CC` | ARM | 1 | 1 / 1 / 1 / 1 | after `bl` | `bl 0x08011AD0` |
| `0x0800387C` | ARM | - | 1 / 1 / 3 / 7 | after `bl` (new) | `bl 0x08011AD0` |
| `0x08003D84` | ARM | 2 | 4 / 4 / 6 / 10 | after `bl` | `bl 0x0800381C` |
| `0x08003D8C` | ARM | 2 | 4 / 4 / 6 / 10 | after `bl` | `bl 0x08003388` |
| `0x08003DAC` | ARM | - | 1 / 1 / 3 / 7 | after `bl` (new) | `bl 0x08002D34` |
| `0x08003E70` | ARM | 2 | 3 / 4 / 5 / 10 | after `bl` | `bl 0x080033E8` |
| `0x08004278` | ARM | 2 | 3 / 3 / 3 / 3 | after `bl` | `bl 0x08011AF4` |
| `0x080042C8` | ARM | 511 | 1,023 / 1,023 / 1,023 / 1,023 | after `bl` | `bl 0x08011AF4` |
| `0x08004468` | ARM | 1 | 1 / 1 / 1 / 1 | after `bl` | `bl 0x08011AF4` |
| `0x080046D8` | ARM | 1 | 1 / 1 / 1 / 1 | after `bl` | `bl 0x0800444C` |
| `0x080046E0` | ARM | 1 | 1 / 1 / 1 / 1 | after `bl` | `bl 0x0800435C` |
| `0x08004728` | ARM | 1 | 1 / 1 / 1 / 1 | after `bl` | `bl 0x08011AE8` |
| `0x0800473C` | ARM | 1 | 1 / 1 / 1 / 1 | after `bl` | `bl 0x08011AE8` |
| `0x0800479C` | ARM | 1 | 1 / 1 / 1 / 1 | after `bl` | `bl 0x08011AF4` |
| `0x0800497C` | ARM | 1 | 2 / 2 / 2 / 2 | after `bl` | `bl 0x08011AF4` |
| `0x08004988` | ARM | 1 | 2 / 2 / 2 / 2 | after `bl` | `bl 0x08011AF4` |
| `0x08004A38` | ARM | 1 | 2 / 2 / 2 / 2 | after `bl` | `bl 0x0800435C` |
| `0x08004DC0` | ARM | 1,133 | 1,130 / 1,764 / 2,945 / 7,643 | after `bl` | `bl 0x080126C0` |
| `0x08004EEC` | ARM | - | 1 / 1 / 3 / 7 | after `bl` (new) | `bl 0x08011AF4` |
| `0x08011B98` | ARM | 4,256 | 4,244 / 7,717 / 13,858 / 37,219 | switch slot | `b 0x08011C28` |
| `0x08011BB8` | ARM | 402 | 402 / 805 / 1,408 / 3,667 | switch slot | `b 0x08011C28` |
| `0x08011BD4` | ARM | 2 | 2 / 2 / 2 / 2 | switch slot | `b 0x08011D08` |
| `0x08011DDC` | ARM | 1 | 1 / 1 / 1 / 1 | after `bl` (behind a switch, diagnosis §2.2) | `bl 0x08011AF4` |
| `0x08011DE8` | ARM | 1 | 1 / 1 / 1 / 1 | after `bl` (behind a switch, diagnosis §2.2) | `bl 0x08011AF4` |
| `0x080120C0` | ARM | 403 | 403 / 806 / 1,409 / 3,668 | after `bl` | `bl 0x08011AF4` |
| `0x08012460` | ARM | 12,180 | 12,144 / 19,361 / 32,930 / 87,047 | switch slot | `b 0x08012644` |
| `0x08012480` | ARM | 402 | 402 / 805 / 1,408 / 3,667 | switch slot | `b 0x080125CC` |
| `0x0801289C` | ARM | 4,660 | 4,648 / 8,524 / 15,268 / 40,888 | after `bl` | `bl 0x08011B80` |
| `0x080128EC` | ARM | 737 | 735 / 1,046 / 1,665 / 4,228 | after `bl` | `bl 0x08011AE8` |

On the pin plus 0001-0002 this gives the diagnosis's split (§2): 30 ROM misses after a `bl`, 5 switch slots and 2 IWRAM entries. With the series: 38 after a `bl`, 1 not, 5 switch slots and 3 IWRAM entries.

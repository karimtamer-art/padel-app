# Ranking engine study

An isolated simulation harness for evaluating changes to the rating engine.
**Nothing here runs in the app or touches the database.** No production file was
modified to build it.

```
dart run tools/ranking_simulation/experiments.dart all   # ~6 min → results/results.json
dart run tools/ranking_simulation/report.dart            # → results/report.html
```

Run a single experiment with `… experiments.dart e1` (e1…e14).

## Layout

| File | What's in it |
|---|---|
| `sim.dart` | Seeded RNG, player populations, the "worlds" (ground-truth match models), padel scoreline generation, social matchmaking |
| `engines.dart` | All engines behind one `RankingEngine` interface |
| `metrics.dart` | MAE / median / RMSE, bias + centred MAE, Spearman, pairwise accuracy, calibration, convergence, spread recovery, stability |
| `runner.dart` | Match-stream construction, replay, engine-driven matchmaking, scripted partner scenarios |
| `experiments.dart` | E1–E14 and the JSON writer |
| `charts.dart`, `report.dart` | SVG charts and the HTML report |

## Engines

- **A · Current** — a read-only mirror of the live `_settle_rating` / `RatingEngine`
  maths, including the 2.0 prior for a NULL rating. **Do not change this class**;
  it is the baseline the whole study is measured against.
- **B · Aggressive Placement** — placement phase only; identical to A once established.
- **C · Tuned Hybrid** — the recommended configuration (`kTunedConfig`).
- **D · TrueSkill**, **D2 · TrueSkill per-set**, **E · Glicko-2** — external comparisons,
  run natively on the 0–7 scale so the numbers are directly comparable.

B and C are the same class with different `HybridConfig` values, so the difference
between any two variants is exactly the config — a new variant is a config literal,
not a new class.

## Things to know before trusting a number

- **Every engine consumes an identical match stream.** Streams are generated from
  ground truth, never from an engine's own ratings. The one exception is E5
  (matchmaking), where the stream *is* the variable; it is reported separately.
- **Parameters are chosen on `tuneSeeds` and reported on `evalSeeds`.** Keep it that
  way — if you sweep a parameter, sweep it on the tuning seeds.
- **Absolute error is partly a statement about the prior.** Elo-family maths only
  learns differences; where a population sits on the 0–7 scale comes from the prior
  and from anchors. Read `maeCentered`, `spearman` and `spreadRecovery` to judge the
  estimator, and raw `mae` to judge what a user actually sees.
- **The simulator does not know real padel.** The biggest unknown is how decisive a
  one-level gap really is. `worldDFlat` / `worldD` / `worldDSteep` bracket it
  (≈78% / 87% / 96% for a one-level gap) precisely so conclusions can be checked for
  robustness rather than tuned to one guess.
- **Better engines look worse on `stability`** — a rating that never moves is
  perfectly stable and perfectly useless. Compare stability only at matched accuracy.

## The interactive lab

`ui/` is a clickable bench built on these same files — create players with a known
true skill, play matches by hand, and watch each engine react. See `ui/README.md`.

```
dart run tools/ranking_simulation/ui/build.dart   # → results/ranking_lab.html
```

It compiles `engines.dart` / `sim.dart` to JavaScript rather than re-implementing
them, so the lab and the study cannot disagree. **This is why `Rng` is 32-bit**:
dart2js has no 64-bit integers, so a 64-bit generator would produce a different
stream in the browser than on the VM and a seed would stop naming one run. The
build refuses to emit the page if VM and JS output diverge.

## Replaying real matches

The most valuable next run is not another simulation. Once there is production match
history, feed it in as a `MatchStream` (players, teams, scorelines, winners in order)
and replay each engine over it. That removes the need to guess padel's true curve,
which is the study's main limitation.

The lab already accepts this: Settings → **Replay real match history**, or the
`replay.run` op in `ui/lab_kernel.dart`. Real data has no ground truth, so it
reports out-of-sample prediction accuracy rather than error against a true skill.

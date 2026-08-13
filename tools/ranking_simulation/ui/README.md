# Ranking Lab

An interactive bench for the rating engine. Create players with a known true
skill, play matches, and watch what each engine believes about them.

**Nothing here touches production.** No Supabase client, no `lib/` import, no
network, no database. Every player, rating and match is invented in memory and
disappears when the tab closes.

```
dart run tools/ranking_simulation/ui/build.dart
```

→ `tools/ranking_simulation/results/ranking_lab.html` — one self-contained file.
Double-click it. No server, no internet.

## Why it can be trusted

The lab does not re-implement the rating maths. `engines.dart` and `sim.dart` —
the same files the batch study and the golden tests use — are compiled to
JavaScript by dart2js and run directly in the page. There is one copy of the
maths, so the lab cannot drift from the study.

Three gates protect that:

| Gate | Where | What it proves |
|---|---|---|
| Golden vectors | `test/ranking_lab_test.dart` | The lab's **V2 reproduces production's `RatingEngine`** — the mirror of the SQL `_settle_rating` — across a 244-case grid. If this fails, fix the simulator, never the assertion. |
| Trace neutrality | same file | Turning on the step-by-step explanation changes no number. Observing an engine must not perturb it. |
| VM ↔ JS parity | `build.dart`, every build | The browser build agrees with the Dart VM. The build **refuses to write the page** if it does not. |

Parity is deliberately two-tier. The RNG (`nextRaw` / `nextDouble` / `nextInt`)
must be **bit-identical** — it decides who plays whom and who wins, so one
differing bit sends the whole run elsewhere; that is why `Rng` is a 32-bit
generator (dart2js has no 64-bit integers). Ordinary doubles are allowed a
relative 1e-9, because `sqrt`, `exp` and `log` are not bit-identical between the
Dart VM and V8, and TrueSkill and Glicko lean on all three.

## The four concepts, kept apart

The lab never mixes these, and neither should any conversation about it:

- **True skill** — synthetic hidden ground truth. The engines never see it. It
  exists so *you* can mark the answer.
- **Estimated rating** — what the engine currently believes. What the metrics
  score.
- **Displayed rating** — what a player would actually be shown: quarter-rounded,
  gated behind the placement/uncertainty rules, or "Finding your level".
- **Sigma** — how unsure the engine is. Drives K and the display gate.

Season points and leaderboard activity are **not** part of this simulation.

## Tabs

- **Story** — one player, one match at a time, with the full arithmetic behind
  every move (K, W, S, E, what the margin did). Force a win, force a loss, or
  type an exact scoreline. Shows the developer's view and the player's view
  side by side.
- **Compare engines** — one scenario, every engine, identical matches; averaged
  over as many seeds as you like. Smurf and overrated-beginner presets.
- **Population** — a whole league, with the KPI panel, the true-vs-estimate
  scatter, the distribution histogram, a timeline slider, and a per-player
  inspector.
- **Doubles & boosting** — team-strength models against real win rates, the
  carry test, and the partner-independence test.
- **Knob sweeps** — sweep one parameter and hold everything else; scoreline
  comparison; onboarding self-declaration.
- **Career events** — genuine skill change, and coming back after time away.
- **Settings** — every knob, live, applying to all tabs. V2 is locked.

## Replaying real matches

The study's main limitation is that it guesses how decisive a level gap really
is in padel. Real history removes the guess. Settings → **Replay real match
history** takes:

```json
{"matches": [
  {"a": ["p1", "p2"], "b": ["p3", "p4"], "score": "6-4,3-6,7-5"}
]}
```

in chronological order; ids can be anything (uuids, names) and are never
interpreted. There is no ground truth in real data, so error against a "true"
skill is not reported — **prediction accuracy** is: before each match the engine
is asked who wins and scored against what happened, always before it has seen
that match. Lowest Brier score wins.

Anonymise before exporting. The lab needs nothing but ids and scorelines.

## Status of V3

`kV3Config` in `engines.dart` is a **candidate, not an approved change**. It is
the study's four primary fixes turned into something concrete enough to argue
with: prior 3.3, staged placement K (0.80 / 0.50 / 0.30), no opponent-reliability
discount during placement, 85/15 score signal with the margin capped at ±0.15,
sigma-only inactivity, and no public rating for the first 10 matches.

It deliberately leaves out parts of the study's fully-tuned engine (steeper
curve, adaptive and diversity sigma, widened internal range) — those were either
not individually justified or interact with the primary fixes in ways the lab
exists to expose. Engine **C · Tuned Hybrid** is available for comparison.

λ (team imbalance) is **off by default** in V3. It fits better in every world
that is not an average by construction, but it should be fitted against real
match data before it goes anywhere near production.

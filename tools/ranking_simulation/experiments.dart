// ignore_for_file: avoid_print
/// The experiment suite. Run with:
///   dart run tools/ranking_simulation/experiments.dart [all|e1|e2|...]
///
/// Writes tools/ranking_simulation/results/results.json, which
/// `report.dart` turns into the HTML report.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'engines.dart';
import 'metrics.dart';
import 'runner.dart';
import 'sim.dart';

// Seeds are split so nothing is tuned and reported on the same simulations.
final tuneSeeds = List<int>.generate(20, (i) => i + 1);
final evalSeeds = List<int>.generate(50, (i) => i + 1000);
final evalSeedsShort = List<int>.generate(20, (i) => i + 1000);

double? jd(double v) => v.isFinite ? v : null;

Map<String, RankingEngine Function()> get engineFactories => {
      'A · Current (production)': () => CurrentEngine(),
      'B · Aggressive Placement': () => aggressiveEngine(),
      'C · Tuned Hybrid': () => tunedEngine(),
      'D · TrueSkill': () => TrueSkillEngine(),
      'D2 · TrueSkill (per-set)': () =>
          TrueSkillEngine(name: 'D2 · TrueSkill (per-set)', perSet: true),
      'E · Glicko-2': () => Glicko2Engine(),
    };

// ─────────────────────────────────────────────────────────────────────────────
// Aggregation helpers
// ─────────────────────────────────────────────────────────────────────────────

Map<String, dynamic> aggregate(List<RunOutput> runs) {
  final snapKeys = runs.first.snapshots.keys.toList()..sort();
  final snaps = <String, dynamic>{};
  for (final k in snapKeys) {
    List<double> pick(double Function(Snapshot) f) =>
        [for (final r in runs) f(r.snapshots[k]!)];
    final bandMae = <String, double>{};
    final bandMean = <String, double>{};
    for (final (label, _, _) in skillBands) {
      final v = [
        for (final r in runs)
          if (r.snapshots[k]!.maeByBand.containsKey(label)) r.snapshots[k]!.maeByBand[label]!
      ];
      final m = [
        for (final r in runs)
          if (r.snapshots[k]!.meanEstByBand.containsKey(label))
            r.snapshots[k]!.meanEstByBand[label]!
      ];
      if (v.isNotEmpty) bandMae[label] = mean(v);
      if (m.isNotEmpty) bandMean[label] = mean(m);
    }
    snaps['$k'] = {
      'mae': mean(pick((s) => s.mae)),
      'maeP10': percentile(pick((s) => s.mae), 0.1),
      'maeP90': percentile(pick((s) => s.mae), 0.9),
      'medAE': mean(pick((s) => s.medAE)),
      'rmse': mean(pick((s) => s.rmse)),
      'bias': mean(pick((s) => s.bias)),
      'maeCentered': mean(pick((s) => s.maeCentered)),
      'spearman': mean(pick((s) => s.spearman)),
      'pairwise': mean(pick((s) => s.pairwise)),
      'spreadRecovery': mean(pick((s) => s.spreadRecovery)),
      'estSd': mean(pick((s) => s.estSd)),
      'trueSd': mean(pick((s) => s.trueSd)),
      'pctStrongStuckLow': mean(pick((s) => s.pctStrongStuckLow)),
      'pctWeakStuckHigh': mean(pick((s) => s.pctWeakStuckHigh)),
      'maeByBand': bandMae,
      'meanEstByBand': bandMean,
    };
  }

  final cal = Calibration();
  for (final r in runs) {
    cal.merge(r.calib);
  }

  return {
    'engine': runs.first.engine,
    'seeds': runs.length,
    'snapshots': snaps,
    'accuracy': cal.accuracy,
    'ece': cal.ece,
    'logLoss': cal.meanLogLoss,
    'brier': cal.meanBrier,
    'calibCurve': [
      for (final (p, o, c) in cal.curve) {'pred': p, 'obs': o, 'n': c}
    ],
    'conv025': mean([for (final r in runs) r.conv025.avg].where((x) => x.isFinite).toList()),
    'conv025Median': mean([for (final r in runs) r.conv025.p50].where((x) => x.isFinite).toList()),
    'conv050': mean([for (final r in runs) r.conv050.avg].where((x) => x.isFinite).toList()),
    'conv050Median': mean([for (final r in runs) r.conv050.p50].where((x) => x.isFinite).toList()),
    'neverConverged025': mean([for (final r in runs) r.neverConverged025]),
    'stability': mean([for (final r in runs) r.stability]),
    'displayReadyRound': jd(mean(
        [for (final r in runs) r.displayReadyRound].where((x) => x.isFinite).toList())),
    'displayReadyMae':
        jd(mean([for (final r in runs) r.displayReadyMae].where((x) => x.isFinite).toList())),
  };
}

List<RunOutput> runAcrossSeeds(
  RankingEngine Function() make,
  List<int> seeds,
  StreamSpec spec, {
  bool keepFirstTrajectories = false,
}) {
  final out = <RunOutput>[];
  for (var i = 0; i < seeds.length; i++) {
    final stream = buildStream(seeds[i], spec);
    out.add(replay(make(), stream, keepTrajectories: keepFirstTrajectories && i == 0));
  }
  return out;
}

// ═════════════════════════════════════════════════════════════════════════════
// E1 — Cold start: 1,000 brand-new players, 10 placement + 40 ranked matches.
// ═════════════════════════════════════════════════════════════════════════════
Map<String, dynamic> e1ColdStart() {
  print('  E1 cold start…');
  final worlds = <String, World>{
    'D (primary, mixed doubles)': worldD,
    'A (pure Elo-average)': worldA,
    'C (weak-link)': worldC,
    'E (form noise)': worldE,
  };
  final out = <String, dynamic>{};
  for (final entry in worlds.entries) {
    final seeds = entry.key.startsWith('D (') ? evalSeeds : evalSeedsShort;
    final spec = StreamSpec(nPlayers: 1000, rounds: 50, world: entry.value);
    final byEngine = <String, dynamic>{};
    for (final e in engineFactories.entries) {
      final runs = runAcrossSeeds(e.value, seeds, spec);
      byEngine[e.key] = aggregate(runs);
      print('    ${entry.key} / ${e.key}: '
          'MAE@10=${(byEngine[e.key]['snapshots']['10']['mae'] as double).toStringAsFixed(3)} '
          'MAE@50=${(byEngine[e.key]['snapshots']['50']['mae'] as double).toStringAsFixed(3)} '
          'spread@10=${(byEngine[e.key]['snapshots']['10']['spreadRecovery'] as double).toStringAsFixed(2)}');
    }
    out[entry.key] = byEngine;
  }

  // scatter + histogram + trajectory data from one representative seed
  final stream = buildStream(evalSeeds.first, const StreamSpec(nPlayers: 1000, rounds: 50));
  final truth = stream.truthByRound.last;
  int nearest(double target) {
    var best = 0;
    var bd = double.infinity;
    for (var i = 0; i < truth.length; i++) {
      final d = (truth[i] - target).abs();
      if (d < bd) {
        bd = d;
        best = i;
      }
    }
    return best;
  }

  final picks = {
    'weak (~1.8)': nearest(1.8),
    'average (~3.4)': nearest(3.4),
    'strong (~5.4)': nearest(5.4),
  };
  final detail = <String, dynamic>{};
  final trajOut = <String, dynamic>{};
  final idx = List<int>.generate(1000, (i) => i);
  for (final e in engineFactories.entries) {
    final r = replay(e.value(), stream, keepTrajectories: true);
    detail[e.key] = {
      'scatter': {
        for (final k in [3, 5, 10, 20, 50])
          '$k': [
            for (final i in idx.take(400))
              [stream.truthByRound[k - 1][i], r.trajectories[i][k - 1]]
          ]
      },
      'hist10': [for (final i in idx) r.trajectories[i][9]],
      'hist50': [for (final i in idx) r.trajectories[i][49]],
      'trueHist': stream.truthByRound[49],
    };
    trajOut[e.key] = {for (final p in picks.entries) p.key: r.trajectories[p.value]};
  }

  return {
    'worlds': out,
    'detail': detail,
    'trajectories': trajOut,
    'picksTrue': {for (final p in picks.entries) p.key: truth[p.value]},
  };
}

// ═════════════════════════════════════════════════════════════════════════════
// E2 — Starting prior (2.0 / 3.0 / 3.5) + onboarding self-declaration.
// ═════════════════════════════════════════════════════════════════════════════
Map<String, dynamic> e2Prior() {
  print('  E2 starting prior…');
  final out = <String, dynamic>{};
  const spec = StreamSpec(nPlayers: 800, rounds: 50);
  const base = HybridConfig(
    prior: 3.3,
    sigma0: 0.95,
    stageEnds: [3, 7, 10],
    stageK: [0.70, 0.45, 0.28],
    placementRelFloor: 0.85,
    placementSigmaDecay: 0.88,
  );

  for (final p in [2.0, 2.5, 3.0, 3.3, 3.5, 4.0]) {
    final runs = runAcrossSeeds(
        () => HybridEngine('B prior=$p', base.copyWith(prior: p)), tuneSeeds, spec);
    out['aggressive prior $p'] = aggregate(runs);
  }
  // The production engine unchanged, and the production engine with ONLY the
  // prior moved — this pair isolates "prior" from "placement K".
  for (final p in [2.0, 2.5, 3.0, 3.3, 3.5]) {
    out['current maths, prior $p'] =
        aggregate(runAcrossSeeds(() => CurrentEngine(startPrior: p), tuneSeeds, spec));
  }

  // onboarding priors
  final onboarding = <String, StreamSpec>{
    'honest 70%': const StreamSpec(nPlayers: 800, rounds: 50, askOnboarding: true, honesty: 0.7),
    'honest 100%': const StreamSpec(nPlayers: 800, rounds: 50, askOnboarding: true, honesty: 1.0),
    '20% sandbag': const StreamSpec(
        nPlayers: 800, rounds: 50, askOnboarding: true, honesty: 0.7, sandbagRate: 0.2),
    '20% inflate': const StreamSpec(
        nPlayers: 800, rounds: 50, askOnboarding: true, honesty: 0.7, inflateRate: 0.2),
  };
  final ob = <String, dynamic>{};
  for (final o in onboarding.entries) {
    ob['${o.key} · declared prior'] = aggregate(runAcrossSeeds(
        () => HybridEngine('B declared',
            base.copyWith(useDeclaredPrior: true, declaredPriors: kDeclaredPriors)),
        tuneSeeds,
        o.value));
    ob['${o.key} · flat 3.3 prior'] =
        aggregate(runAcrossSeeds(() => HybridEngine('B flat', base), tuneSeeds, o.value));
  }
  out['onboarding'] = ob;
  return out;
}

// ═════════════════════════════════════════════════════════════════════════════
// E3 — Opponent-reliability weighting during cold start.
// ═════════════════════════════════════════════════════════════════════════════
Map<String, dynamic> e3Reliability() {
  print('  E3 opponent reliability…');
  const spec = StreamSpec(nPlayers: 800, rounds: 50);
  const base = HybridConfig(prior: 3.3, sigma0: 0.95, stageEnds: [3, 7, 10], stageK: [0.70, 0.45, 0.28]);
  final variants = <String, double>{
    '1 · current formula (floor 0.50)': 0.5,
    '3 · placement floor 0.75': 0.75,
    '4 · placement floor 0.85': 0.85,
    '2 · no discount in placement (1.00)': 1.0,
  };
  final out = <String, dynamic>{};
  for (final v in variants.entries) {
    out[v.key] = aggregate(runAcrossSeeds(
        () => HybridEngine('rel${v.value}', base.copyWith(placementRelFloor: v.value)),
        tuneSeeds,
        spec));
  }
  // 5 · full weight for the first 3 matches, then ramp back to the formula
  out['5 · full weight matches 1–3, then ramp'] = aggregate(runAcrossSeeds(
      () => HybridEngine('rel-ramp', base.copyWith(relRampMatches: 3)),
      tuneSeeds,
      spec));

  // and the same question asked of the untouched production engine: what does
  // its W actually evaluate to when the whole population is new?
  final stream = buildStream(tuneSeeds.first, spec);
  final probe = CurrentEngine();
  for (final p in stream.players) {
    probe.register(p.id);
  }
  final wTrace = <double>[];
  for (var r = 0; r < 12; r++) {
    var acc = 0.0;
    var n = 0;
    for (final m in stream.rounds[r]) {
      final sg = (probe.sigmaOf(m.b1) + probe.sigmaOf(m.b2)) / 2;
      acc += 0.5 + 0.5 * (1 - sg);
      n++;
      probe.update(m);
    }
    wTrace.add(acc / n);
  }
  out['_wTraceCurrentEngine'] = wTrace;
  return out;
}

// ═════════════════════════════════════════════════════════════════════════════
// E4 — Placement K grid.
// ═════════════════════════════════════════════════════════════════════════════
Map<String, dynamic> e4PlacementK() {
  print('  E4 placement K…');
  const spec = StreamSpec(nPlayers: 800, rounds: 50);
  const base = HybridConfig(prior: 3.3, sigma0: 0.95, placementRelFloor: 0.85);
  final out = <String, dynamic>{};
  for (final k1 in [0.35, 0.4, 0.5, 0.6, 0.7, 0.8, 1.0]) {
    final cfg = base.copyWith(
      stageEnds: [3, 7, 10],
      stageK: [k1, k1 * 0.64, k1 * 0.40],
    );
    out['stage1 K=$k1'] = aggregate(
        runAcrossSeeds(() => HybridEngine('K$k1', cfg), tuneSeeds, spec));
  }
  // flat (non-staged) placement K for comparison
  for (final k in [0.45, 0.6]) {
    out['flat K=$k (no stages)'] = aggregate(runAcrossSeeds(
        () => HybridEngine('flat$k', base.copyWith(stageEnds: [10], stageK: [k])),
        tuneSeeds,
        spec));
  }
  return out;
}

// ═════════════════════════════════════════════════════════════════════════════
// E5 — Placement matchmaking: near-rating band vs adaptive probing.
// ═════════════════════════════════════════════════════════════════════════════
Map<String, dynamic> e5Matchmaking() {
  print('  E5 placement matchmaking…');
  const spec = StreamSpec(nPlayers: 800, rounds: 50);
  final out = <String, dynamic>{};
  final engines = <String, RankingEngine Function()>{
    'A · Current': () => CurrentEngine(),
    'B · Aggressive Placement': () => aggressiveEngine(),
    'C · Tuned Hybrid': () => tunedEngine(),
    'D · TrueSkill': () => TrueSkillEngine(),
  };
  for (final e in engines.entries) {
    for (final mode in MatchmakingMode.values) {
      final runs = <RunOutput>[];
      for (final s in evalSeedsShort) {
        runs.add(engineDrivenRun(e.value(), s, spec, mode));
      }
      out['${e.key} · ${mode.name}'] = aggregate(runs);
    }
  }
  return out;
}

// ═════════════════════════════════════════════════════════════════════════════
// E6 — Expected-win curve scale, across worlds of different decisiveness.
// ═════════════════════════════════════════════════════════════════════════════
Map<String, dynamic> e6Curve() {
  print('  E6 expected-win curve…');
  final worlds = <String, World>{
    'flat world (gameScale 4.0)': worldDFlat,
    'primary world (gameScale 2.6)': worldD,
    'steep world (gameScale 1.8)': worldDSteep,
  };
  final out = <String, dynamic>{};
  final decisiveness = <String, dynamic>{};
  for (final w in worlds.entries) {
    decisiveness[w.key] = {
      'p@0.5level': w.value.trueMatchProb(3.5, 3.0),
      'p@1.0level': w.value.trueMatchProb(4.0, 3.0),
      'p@1.5level': w.value.trueMatchProb(4.5, 3.0),
      'p@2.0level': w.value.trueMatchProb(5.0, 3.0),
    };
    final byScale = <String, dynamic>{};
    for (final s in [1.0, 1.25, 1.5, 1.75, 2.0, 2.5]) {
      // Swept ON TOP of the other fixes. Sweeping it against the unfixed engine
      // would only measure how much a flatter curve compensates for compression
      // — which is a different question, and the wrong one.
      final cfg = kTunedConfig.copyWith(curveScale: s);
      byScale['scale $s'] = aggregate(runAcrossSeeds(() => HybridEngine('s$s', cfg),
          tuneSeeds, StreamSpec(nPlayers: 800, rounds: 50, world: w.value)));
    }
    out[w.key] = byScale;
  }
  out['_worldDecisiveness'] = decisiveness;
  return out;
}

// ═════════════════════════════════════════════════════════════════════════════
// E7 — Result vs margin weighting.
// ═════════════════════════════════════════════════════════════════════════════
Map<String, dynamic> e7Margin() {
  print('  E7 margin weighting…');
  const spec = StreamSpec(nPlayers: 800, rounds: 50);
  const base = HybridConfig(
      prior: 3.3,
      sigma0: 0.95,
      stageEnds: [3, 7, 10],
      stageK: [0.70, 0.45, 0.28],
      placementRelFloor: 0.85,
      curveScale: 1.5);
  final out = <String, dynamic>{};
  for (final rw in [1.0, 0.9, 0.85, 0.8, 0.7, 0.6]) {
    out['${(rw * 100).round()}/${(100 - rw * 100).round()} linear'] = aggregate(runAcrossSeeds(
        () => HybridEngine('rw$rw', base.copyWith(resultWeight: rw, marginCap: 0.5)),
        tuneSeeds,
        spec));
  }
  // ── Why the margin term compresses ratings, analytically ────────────────
  // The update is K·W·(S − E). E is a probability of WINNING; S mixes the win
  // with the games ratio, and a games ratio is far less extreme than a win
  // probability. So for any favourite E[S] < E even when their rating is exactly
  // right: a permanent downward pull on stronger players and an upward pull on
  // weaker ones — a restoring force toward the mean. It does not depend on the
  // curve being miscalibrated; it survives a perfectly calibrated curve too.
  final drift = <String, dynamic>{};
  for (final gap in [0.0, 0.25, 0.5, 1.0, 1.5, 2.0]) {
    final pWin = worldD.trueMatchProb(3.0 + gap, 3.0);
    final pGame = worldD.perGameProb(3.0 + gap, 3.0); // = E[games ratio]
    final eEngine = 1 / (1 + math.pow(10.0, -gap / 1.0));
    drift['gap $gap'] = {
      'trueWinProb': pWin,
      'expectedGamesRatio': pGame,
      'expectedS_70_30': 0.7 * pWin + 0.3 * pGame,
      'engineE_s1': eEngine,
      'driftVsEngineE': 0.7 * pWin + 0.3 * pGame - eEngine,
      'driftVsPerfectCurve': 0.7 * pWin + 0.3 * pGame - pWin,
    };
  }
  out['_marginBias'] = drift;

  for (final cap in [0.15, 0.22, 0.30]) {
    out['85/15 capped ±$cap'] = aggregate(runAcrossSeeds(
        () => HybridEngine('cap$cap', base.copyWith(resultWeight: 0.85, marginCap: cap)),
        tuneSeeds,
        spec));
    out['70/30 capped ±$cap'] = aggregate(runAcrossSeeds(
        () => HybridEngine('cap70$cap', base.copyWith(resultWeight: 0.7, marginCap: cap)),
        tuneSeeds,
        spec));
  }
  return out;
}

// ═════════════════════════════════════════════════════════════════════════════
// E8 — Doubles team-strength models. Fitted on tuning pairs, scored on held-out
// pairs, in each world. Answers "is a plain average good enough?".
// ═════════════════════════════════════════════════════════════════════════════
Map<String, dynamic> e8TeamModel() {
  print('  E8 team-strength models…');

  double modelStrength(String model, double a, double b, double lambda) {
    final avg = (a + b) / 2;
    final gap = (a - b).abs();
    final strong = math.max(a, b), weak = math.min(a, b);
    switch (model) {
      case 'average':
        return avg;
      case 'avg−λ·gap':
        return avg - lambda * gap;
      case 'weak-link':
        return lambda * weak + (1 - lambda) * avg;
      case 'carry':
        return lambda * strong + (1 - lambda) * avg;
      case 'combo':
        return avg + lambda * gap - 0.5 * lambda * gap * gap;
      default:
        return avg;
    }
  }

  final worlds = <String, World>{
    'A · pure average': worldA,
    'B · carry': worldB,
    'C · weak-link': worldC,
    'D · mixed (primary)': worldD,
  };

  final out = <String, dynamic>{};
  for (final w in worlds.entries) {
    // build tuning + eval sets of real matches with a WIDE range of pair shapes
    List<List<double>> sample(int seed, int n) {
      final rng = Rng(seed);
      final rows = <List<double>>[];
      for (var i = 0; i < n; i++) {
        final a1 = 0.5 + rng.nextDouble() * 6.0;
        final a2 = 0.5 + rng.nextDouble() * 6.0;
        final b1 = 0.5 + rng.nextDouble() * 6.0;
        final b2 = 0.5 + rng.nextDouble() * 6.0;
        final eff = List<double>.filled(4, 0);
        eff[0] = a1;
        eff[1] = a2;
        eff[2] = b1;
        eff[3] = b2;
        final m = w.value.play(rng, 0, 1, 2, 3, eff);
        rows.add([a1, a2, b1, b2, m.aWon ? 1 : 0]);
      }
      return rows;
    }

    final train = sample(seed4(w.key, 1), 40000);
    final test = sample(seed4(w.key, 2), 40000);

    double logLoss(List<List<double>> rows, String model, double lambda, double scale) {
      var s = 0.0;
      for (final r in rows) {
        final sa = modelStrength(model, r[0], r[1], lambda);
        final sb = modelStrength(model, r[2], r[3], lambda);
        var p = 1 / (1 + math.pow(10.0, (sb - sa) / scale));
        p = clampD(p.toDouble(), 1e-6, 1 - 1e-6);
        s += r[4] == 1 ? -math.log(p) : -math.log(1 - p);
      }
      return s / rows.length;
    }

    final byModel = <String, dynamic>{};
    for (final model in ['average', 'avg−λ·gap', 'weak-link', 'carry', 'combo']) {
      var bestLl = double.infinity, bestL = 0.0, bestS = 1.0;
      final lambdas = model == 'average'
          ? [0.0]
          : [0.0, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5];
      for (final l in lambdas) {
        for (final s in [0.8, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]) {
          final ll = logLoss(train, model, l, s);
          if (ll < bestLl) {
            bestLl = ll;
            bestL = l;
            bestS = s;
          }
        }
      }
      // held-out score + accuracy
      var correct = 0;
      for (final r in test) {
        final sa = modelStrength(model, r[0], r[1], bestL);
        final sb = modelStrength(model, r[2], r[3], bestL);
        final p = 1 / (1 + math.pow(10.0, (sb - sa) / bestS));
        if ((p >= 0.5) == (r[4] == 1)) correct++;
      }
      byModel[model] = {
        'lambda': bestL,
        'scale': bestS,
        'testLogLoss': logLoss(test, model, bestL, bestS),
        'testAccuracy': correct / test.length,
      };
    }
    out[w.key] = byModel;
  }

  // the specific pair matchups the brief asked about
  final pairScenarios = <String, dynamic>{};
  final pairs = <String, List<double>>{
    'balanced 3.5+3.5': [3.5, 3.5],
    'slight 4.0+3.0': [4.0, 3.0],
    'carry 5.0+2.0': [5.0, 2.0],
    'extreme 6.0+1.0': [6.0, 1.0],
  };
  for (final w in worlds.entries) {
    final rows = <String, dynamic>{};
    for (final p in pairs.entries) {
      for (final q in pairs.entries) {
        if (p.key == q.key) continue;
        final rng = Rng(4242);
        var wins = 0;
        const n = 20000;
        for (var i = 0; i < n; i++) {
          final eff = [p.value[0], p.value[1], q.value[0], q.value[1]];
          if (w.value.play(rng, 0, 1, 2, 3, eff).aWon) wins++;
        }
        rows['${p.key} vs ${q.key}'] = wins / n;
      }
    }
    pairScenarios[w.key] = rows;
  }
  out['_pairScenarios'] = pairScenarios;
  return out;
}

int seed4(String s, int salt) {
  var h = 17;
  for (final c in s.codeUnits) {
    h = (h * 31 + c) & 0x3FFFFFFF;
  }
  return h + salt * 7919;
}

// ═════════════════════════════════════════════════════════════════════════════
// E9 — Boosting, carrying, partner independence, gap limits.
// ═════════════════════════════════════════════════════════════════════════════
Map<String, dynamic> e9Boosting() {
  print('  E9 boosting / partner independence…');
  final out = <String, dynamic>{};
  final engines = engineFactories;

  // ── 14. Partner independence error ──────────────────────────────────────
  // true skill 3.5 probes: 20 rounds with a 5.0 partner, 20 with a 2.0 partner,
  // 20 with random partners.
  final probeSkills = [
    for (var i = 0; i < 30; i++) 3.5,
    for (var i = 0; i < 15; i++) 2.5,
    for (var i = 0; i < 15; i++) 4.5,
  ];
  final pi = <String, dynamic>{};
  for (final e in engines.entries) {
    final byPhase = <String, List<double>>{};
    final estByPhase = <String, List<double>>{};
    for (final seed in [1, 2, 3, 4, 5]) {
      final r = scriptedPartnerRun(
        e.value(),
        seed,
        phases: const [
          ('with 5.0 partner', 20, 5.0),
          ('then 2.0 partner', 20, 2.0),
          ('then random partners', 20, null),
        ],
        probeSkills: probeSkills,
      );
      for (final k in r.errorByPhase.keys) {
        (byPhase[k] ??= []).addAll(r.errorByPhase[k]!);
        (estByPhase[k] ??= []).addAll(r.estByPhase[k]!);
      }
    }
    pi[e.key] = <String, dynamic>{
      for (final k in byPhase.keys)
        k: {'mae': mean(byPhase[k]!), 'meanEst': mean(estByPhase[k]!)},
      'probeTrueMean': mean(probeSkills),
    };
  }
  out['partnerIndependence'] = pi;

  // ── 15. Boosting inflation ──────────────────────────────────────────────
  // a true-2.5 player permanently attached to a much stronger partner.
  final boost = <String, dynamic>{};
  for (final e in engines.entries) {
    final rows = <String, dynamic>{};
    for (final partnerSkill in [3.5, 4.5, 5.0, 6.0]) {
      final ests = <double>[];
      final sigmas = <double>[];
      for (final seed in [11, 12, 13]) {
        final r = scriptedPartnerRun(
          e.value(),
          seed,
          phases: [('boost', 50, partnerSkill)],
          probeSkills: List<double>.filled(30, 2.5),
        );
        ests.addAll(r.estByPhase['boost']!);
        sigmas.addAll(r.sigmaByPhase['boost']!);
      }
      rows['partner $partnerSkill'] = {
        'meanEst': mean(ests),
        'inflation': mean(ests) - 2.5,
        'meanSigma': mean(sigmas),
      };
    }
    // control: same players, random partners
    final ctrl = <double>[];
    for (final seed in [11, 12, 13]) {
      final r = scriptedPartnerRun(e.value(), seed,
          phases: const [('control', 50, null)], probeSkills: List<double>.filled(30, 2.5));
      ctrl.addAll(r.estByPhase['control']!);
    }
    rows['control (random partners)'] = {
      'meanEst': mean(ctrl),
      'inflation': mean(ctrl) - 2.5,
      'meanSigma': 0.0,
    };
    boost[e.key] = rows;
  }
  out['boostingInflation'] = boost;

  // ── 17/18. Partner + opponent diversity vs sigma ─────────────────────────
  final div = <String, dynamic>{};
  for (final e in engines.entries) {
    final fixed = scriptedPartnerRun(e.value(), 21,
        phases: const [('fixed partner', 40, 3.5)], probeSkills: List<double>.filled(30, 3.5));
    final random = scriptedPartnerRun(e.value(), 21,
        phases: const [('random partners', 40, null)], probeSkills: List<double>.filled(30, 3.5));
    div[e.key] = {
      'fixedPartner': {
        'mae': mean(fixed.errorByPhase['fixed partner']!),
        'sigma': mean(fixed.sigmaByPhase['fixed partner']!),
      },
      'randomPartners': {
        'mae': mean(random.errorByPhase['random partners']!),
        'sigma': mean(random.sigmaByPhase['random partners']!),
      },
    };
  }
  out['diversity'] = div;

  // ── 15b. Gap limits: how much boosting is stopped, how much play is blocked
  // Measured on the TUNED engine, not the current one: a rating-gap rule is
  // vacuous when every rating is squashed into a one-level band, so testing it
  // on Engine A would only re-measure the compression.
  final gapOut = <String, dynamic>{};
  for (final limit in [0.75, 1.0, 1.25, 1.5, 2.0, 99.0]) {
    final ests = <double>[];
    final ctrl = <double>[];
    for (final seed in [11, 12, 13]) {
      final r = scriptedPartnerRun(
        tunedEngine(),
        seed,
        phases: const [('boost', 50, 6.0)],
        probeSkills: List<double>.filled(30, 2.5),
        forcedPartnerGapLimit: limit >= 99 ? null : limit,
      );
      ests.addAll(r.estByPhase['boost']!);
      final c = scriptedPartnerRun(tunedEngine(), seed,
          phases: const [('boost', 50, null)], probeSkills: List<double>.filled(30, 2.5));
      ctrl.addAll(c.estByPhase['boost']!);
    }
    gapOut[limit >= 99 ? 'no limit' : 'limit $limit'] = {
      'meanEst': mean(ests),
      'inflation': mean(ests) - mean(ctrl),
    };
  }
  // legitimate-play cost: what share of naturally-formed pairs would be blocked
  final blocked = <String, dynamic>{};
  {
    const spec = StreamSpec(nPlayers: 800, rounds: 50);
    for (final limit in [0.75, 1.0, 1.25, 1.5, 2.0]) {
      var tot = 0, blk = 0, provTot = 0, provBlk = 0;
      for (final seed in [1000, 1001, 1002]) {
        final stream = buildStream(seed, spec);
        final e = tunedEngine();
        for (final p in stream.players) {
          e.register(p.id);
        }
        for (var r = 0; r < stream.roundCount; r++) {
          for (final m in stream.rounds[r]) {
            for (final t in [m.teamA, m.teamB]) {
              final gap = (e.estimate(t[0]) - e.estimate(t[1])).abs();
              final prov = !e.displayReady(t[0]) || !e.displayReady(t[1]);
              tot++;
              if (gap > limit) blk++;
              if (prov) {
                provTot++;
                if (gap > limit) provBlk++;
              }
            }
            e.update(m);
          }
        }
      }
      blocked['limit $limit'] = {
        'blockedPctAll': 100 * blk / tot,
        'blockedPctProvisional': provTot == 0 ? 0.0 : 100 * provBlk / provTot,
      };
    }
  }
  out['gapLimits'] = {'boostingWithLimit': gapOut, 'blockedShare': blocked};

  return out;
}

// ═════════════════════════════════════════════════════════════════════════════
// E10 — Sigma models: adaptive (surprise-aware) and diversity-aware.
// ═════════════════════════════════════════════════════════════════════════════
Map<String, dynamic> e10Sigma() {
  print('  E10 sigma models…');
  const spec = StreamSpec(nPlayers: 800, rounds: 50);
  const base = HybridConfig(
      prior: 3.3,
      sigma0: 0.95,
      stageEnds: [3, 7, 10],
      stageK: [0.70, 0.45, 0.28],
      placementRelFloor: 0.85,
      curveScale: 1.5,
      resultWeight: 0.85,
      marginCap: 0.22,
      relFloor: 0.65);
  final out = <String, dynamic>{};
  // CONTROLS FIRST. Any sigma rule that keeps sigma high also keeps K high, so
  // part of an "adaptive sigma" win is really just extra gain. The fixed-decay
  // ladder below is the control that separates the two: if a plain slower decay
  // matches the adaptive rule, the adaptive rule is not earning its complexity.
  final variants = <String, HybridConfig>{
    'fixed ×0.92 (current)': base,
    'fixed ×0.95': base.copyWith(sigmaDecay: 0.95),
    'fixed ×0.97': base.copyWith(sigmaDecay: 0.97),
    'fixed ×0.99': base.copyWith(sigmaDecay: 0.99),
    'diversity-aware': base.copyWith(diversitySigma: true),
    'adaptive · ref 0.45': base.copyWith(adaptiveSigma: true, surpriseRef: 0.45),
    'adaptive · ref 0.70': base.copyWith(adaptiveSigma: true, surpriseRef: 0.70),
    'adaptive · ref 1.00': base.copyWith(adaptiveSigma: true, surpriseRef: 1.00),
    'adaptive ref 0.70 + diversity':
        base.copyWith(adaptiveSigma: true, surpriseRef: 0.70, diversitySigma: true),
  };
  for (final v in variants.entries) {
    out[v.key] = aggregate(
        runAcrossSeeds(() => HybridEngine(v.key, v.value), tuneSeeds, spec));
  }

  // Structural test: a player whose true skill silently drops 5.0 → 3.0.
  // Does sigma re-open, and how fast does the rating follow?
  final recovery = <String, dynamic>{};
  for (final e in engineFactories.entries) {
    final ests = <List<double>>[];
    for (final seed in [31, 32, 33]) {
      final rng = Rng(seed * 31 + 5);
      final pool = makePopulation(rng, 400, SkillDist.bell);
      final probes = [for (var i = 0; i < 20; i++) SimPlayer(400 + i, 5.0)];
      final all = [...pool, ...probes];
      final eng = e.value();
      for (final p in all) {
        eng.register(p.id);
      }
      const mm = SocialMatchmaker(cluster: 0.55);
      for (var r = 0; r < 40; r++) {
        final eff = effectiveSkills(rng, all, worldD);
        for (final m in mm.round(rng, all, worldD, eff)) {
          eng.update(m);
        }
      }
      // silent collapse
      for (final p in probes) {
        p.trueSkill = 3.0;
      }
      final trace = <double>[];
      final sigTrace = <double>[];
      for (var r = 0; r < 30; r++) {
        final eff = effectiveSkills(rng, all, worldD);
        for (final m in mm.round(rng, all, worldD, eff)) {
          eng.update(m);
        }
        trace.add(mean([for (final p in probes) eng.estimate(p.id)]));
        sigTrace.add(mean([for (final p in probes) eng.sigmaOf(p.id)]));
      }
      ests.add([...trace, ...sigTrace]);
    }
    final half = ests.first.length ~/ 2;
    recovery[e.key] = {
      'rating': [for (var i = 0; i < half; i++) mean([for (final t in ests) t[i]])],
      'sigma': [for (var i = half; i < ests.first.length; i++) mean([for (final t in ests) t[i]])],
    };
  }
  out['_skillCollapseRecovery'] = recovery;
  return out;
}

// ═════════════════════════════════════════════════════════════════════════════
// E11 — Inactivity: rating decay vs uncertainty-only.
// ═════════════════════════════════════════════════════════════════════════════
Map<String, dynamic> e11Inactivity() {
  print('  E11 inactivity…');
  final out = <String, dynamic>{};
  final skillDeltas = {'unchanged': 0.0, '−0.2': -0.2, '−0.5': -0.5, '+0.3': 0.3};

  // Hold the ENGINE fixed and vary only the inactivity rule — otherwise the
  // comparison just re-measures each engine's baseline error.
  const inactBase = HybridConfig(
    prior: 3.3,
    sigma0: 0.95,
    stageEnds: [3, 7, 10],
    stageK: [0.70, 0.45, 0.28],
    placementRelFloor: 0.85,
    curveScale: 1.5,
    resultWeight: 0.85,
    marginCap: 0.22,
    relFloor: 0.65,
  );
  final variants = <String, RankingEngine Function()>{
    'A · rating decay + σ (production rule)': () => HybridEngine(
        'decay',
        inactBase.copyWith(
            ratingInactivityDecay: true, idleRatingPerWeek: 0.04, idleSigmaPerWeek: 0.01)),
    'B · σ only, no rating decay': () => HybridEngine('sigma-only',
        inactBase.copyWith(ratingInactivityDecay: false, idleSigmaPerWeek: 0.02, idleSigmaCap: 0.75)),
    'C · mild decay + stronger σ growth': () => HybridEngine(
        'mild',
        inactBase.copyWith(
            ratingInactivityDecay: true,
            idleRatingPerWeek: 0.015,
            idleSigmaPerWeek: 0.03,
            idleSigmaCap: 0.80)),
    'D · TrueSkill (τ only, for reference)': () => TrueSkillEngine(),
  };

  for (final v in variants.entries) {
    final rows = <String, dynamic>{};
    for (final d in skillDeltas.entries) {
      final atReturn = <double>[], after5 = <double>[], after15 = <double>[];
      for (final seed in [41, 42, 43]) {
        final rng = Rng(seed * 977 + 3);
        final pool = makePopulation(rng, 400, SkillDist.bell);
        final probes = [for (var i = 0; i < 25; i++) SimPlayer(400 + i, 4.5)];
        final all = [...pool, ...probes];
        final eng = v.value();
        for (final p in all) {
          eng.register(p.id);
        }
        const mm = SocialMatchmaker(cluster: 0.55);
        for (var r = 0; r < 40; r++) {
          final eff = effectiveSkills(rng, all, worldD);
          for (final m in mm.round(rng, all, worldD, eff)) {
            eng.update(m);
          }
        }
        // 13 weeks away; skill changes by d
        for (final p in probes) {
          eng.idle(p.id, 13);
          p.trueSkill = clampD(p.trueSkill + d.value, 0.2, 7.0);
        }
        atReturn.addAll([for (final p in probes) (eng.estimate(p.id) - p.trueSkill).abs()]);
        for (var r = 0; r < 15; r++) {
          final eff = effectiveSkills(rng, all, worldD);
          for (final m in mm.round(rng, all, worldD, eff)) {
            eng.update(m);
          }
          if (r == 4) {
            after5.addAll([for (final p in probes) (eng.estimate(p.id) - p.trueSkill).abs()]);
          }
        }
        after15.addAll([for (final p in probes) (eng.estimate(p.id) - p.trueSkill).abs()]);
      }
      rows[d.key] = {
        'errorAtReturn': mean(atReturn),
        'errorAfter5': mean(after5),
        'errorAfter15': mean(after15),
      };
    }
    out[v.key] = rows;
  }
  return out;
}

// ═════════════════════════════════════════════════════════════════════════════
// E12 — Anchors.
// ═════════════════════════════════════════════════════════════════════════════
Map<String, dynamic> e12Anchors() {
  print('  E12 anchors…');
  const spec = StreamSpec(nPlayers: 800, rounds: 50);
  final out = <String, dynamic>{};

  // scenario applies anchors right after registration
  RunOutput runWithAnchors(
      RankingEngine Function() make, int seed, String scenario, int anchorCount) {
    final stream = buildStream(seed, spec);
    final e = make();
    for (final p in stream.players) {
      e.register(p.id);
    }
    if (scenario != 'none') {
      final rng = Rng(seed * 13 + 77);
      final ids = List<int>.generate(stream.n, (i) => i);
      rng.shuffle(ids);
      final anchors = ids.take(anchorCount).toList();
      for (final id in anchors) {
        final truth = stream.players[id].trueSkill;
        switch (scenario) {
          case 'correct':
            e.markAnchor(id, truth, 0.30);
            break;
          case 'miscalibrated':
            e.markAnchor(id, clampD(truth + (rng.chance(0.5) ? 1.2 : -1.2), 0, 7), 0.30);
            break;
          case 'lowSigmaOnly':
            // correct rating + low sigma, but NO movement cap
            e.seed(id, truth, 0.30);
            break;
        }
      }
    }
    // replay by hand (register already done)
    final traj = List<List<double>>.generate(stream.n, (_) => <double>[]);
    final calib = Calibration();
    for (var r = 0; r < stream.roundCount; r++) {
      for (final m in stream.rounds[r]) {
        if (r >= 20) calib.add(e.predictA(m), m.aWon);
        e.update(m);
      }
      for (var i = 0; i < stream.n; i++) {
        traj[i].add(e.estimate(i));
      }
    }
    final rng = Rng(999);
    final snaps = <int, Snapshot>{};
    for (final k in defaultSnapAt) {
      final est = [for (var i = 0; i < stream.n; i++) traj[i][k - 1]];
      snaps[k] = snapshot(k, est, stream.truthByRound[k - 1], rng);
    }
    return RunOutput(
      engine: e.name,
      snapshots: snaps,
      calib: calib,
      conv025: const Agg(0, 0, 0, 0),
      conv050: const Agg(0, 0, 0, 0),
      neverConverged025: 0,
      stability: 0,
      finalEst: [for (var i = 0; i < stream.n; i++) traj[i].last],
      finalTruth: stream.truthByRound.last,
      finalSigma: const [],
      trajectories: const [],
      displayReadyRound: double.nan,
      displayReadyMae: double.nan,
    );
  }

  // Anchor DENSITY matters more than the anchor rule — 20 verified players in
  // 800 is a rounding error against a population-wide prior offset.
  for (final n in [0, 20, 80, 240]) {
    for (final scen in n == 0 ? ['none'] : ['correct', 'miscalibrated', 'lowSigmaOnly']) {
      for (final e in {
        'A · Current': () => CurrentEngine(),
        'C · Tuned Hybrid': () => tunedEngine(),
      }.entries) {
        final runs = [
          for (final s in evalSeedsShort) runWithAnchors(e.value, s, scen, n)
        ];
        out['${n == 0 ? 'no anchors' : '$n $scen'} · ${e.key}'] = aggregate(runs);
      }
    }
  }
  return out;
}

// ═════════════════════════════════════════════════════════════════════════════
// E13 — Smurf, overrated beginner, improving / declining players.
// ═════════════════════════════════════════════════════════════════════════════
Map<String, dynamic> e13Scenarios() {
  print('  E13 smurf / overrated / drift…');
  final out = <String, dynamic>{};

  // Smurf: true 5.5, everyone starts at the engine's prior.
  // Overrated: true 1.5 who declared "competitive" (prior 5.3).
  for (final scenario in ['smurf (true 5.5)', 'overrated (true 1.5, declared competitive)']) {
    final rows = <String, dynamic>{};
    for (final e in engineFactories.entries) {
      final traces = <List<double>>[];
      for (final seed in [51, 52, 53]) {
        final rng = Rng(seed * 71 + 3);
        final pool = makePopulation(rng, 400, SkillDist.bell);
        final isSmurf = scenario.startsWith('smurf');
        final probes = [
          for (var i = 0; i < 25; i++) SimPlayer(400 + i, isSmurf ? 5.5 : 1.5)
        ];
        final all = [...pool, ...probes];
        final eng = e.value();
        for (final p in pool) {
          eng.register(p.id);
        }
        // Force the same starting point in every engine so the scenario — not
        // the engine's default prior — is what differs: the smurf is dumped at
        // 1.5, the overrated beginner is handed 5.3.
        for (final p in probes) {
          eng.register(p.id,
              declared: isSmurf ? SelfDeclared.beginner : SelfDeclared.competitive);
          eng.seed(p.id, isSmurf ? 1.5 : 5.3, eng.sigmaOf(p.id));
        }
        const mm = SocialMatchmaker(cluster: 0.55);
        final trace = <double>[];
        for (var r = 0; r < 30; r++) {
          final eff = effectiveSkills(rng, all, worldD);
          for (final m in mm.round(rng, all, worldD, eff)) {
            eng.update(m);
          }
          trace.add(mean([for (final p in probes) eng.estimate(p.id)]));
        }
        traces.add(trace);
      }
      rows[e.key] = [
        for (var i = 0; i < traces.first.length; i++) mean([for (final t in traces) t[i]])
      ];
    }
    out[scenario] = rows;
  }

  // Improving / declining populations: recovery of the estimate.
  final drift = <String, dynamic>{};
  for (final e in engineFactories.entries) {
    final spec = const StreamSpec(
        nPlayers: 800, rounds: 60, improverRate: 0.2, declinerRate: 0.2, driftPerRound: 0.02);
    final runs = runAcrossSeeds(e.value, [1000, 1001, 1002, 1003, 1004], spec);
    drift[e.key] = aggregate(runs);
  }
  out['driftingPopulation'] = drift;
  return out;
}

// ═════════════════════════════════════════════════════════════════════════════
// E14 — When is a rating trustworthy enough to display?
// ═════════════════════════════════════════════════════════════════════════════
Map<String, dynamic> e14DisplayGate() {
  print('  E14 display gate…');
  const spec = StreamSpec(nPlayers: 1000, rounds: 50);
  final out = <String, dynamic>{};
  for (final e in {
    'A · Current': () => CurrentEngine(),
    'B · Aggressive Placement': () => aggressiveEngine(),
    'C · Tuned Hybrid': () => tunedEngine(),
  }.entries) {
    // MAE conditional on (matches played, sigma) at the moment each condition
    // first becomes true.
    final byMatches = <int, List<double>>{};
    final bySigma = <String, List<double>>{};
    final byPartners = <int, List<double>>{};
    for (final seed in evalSeedsShort.take(8)) {
      final stream = buildStream(seed, spec);
      final eng = e.value();
      for (final p in stream.players) {
        eng.register(p.id);
      }
      final partnersSeen = List<Set<int>>.generate(stream.n, (_) => <int>{});
      for (var r = 0; r < stream.roundCount; r++) {
        for (final m in stream.rounds[r]) {
          partnersSeen[m.a1].add(m.a2);
          partnersSeen[m.a2].add(m.a1);
          partnersSeen[m.b1].add(m.b2);
          partnersSeen[m.b2].add(m.b1);
          eng.update(m);
        }
        final k = r + 1;
        if ([3, 5, 8, 10, 15, 20, 30, 50].contains(k)) {
          for (var i = 0; i < stream.n; i++) {
            final err = (eng.estimate(i) - stream.truthByRound[r][i]).abs();
            (byMatches[k] ??= []).add(err);
            if (k == 10) {
              final sg = eng.sigmaOf(i);
              final bucket = sg < 0.30
                  ? '<0.30'
                  : sg < 0.40
                      ? '0.30–0.40'
                      : sg < 0.50
                          ? '0.40–0.50'
                          : '≥0.50';
              (bySigma[bucket] ??= []).add(err);
              final pc = partnersSeen[i].length;
              final pb = pc <= 3
                  ? 3
                  : pc <= 6
                      ? 6
                      : pc <= 9
                          ? 9
                          : 10;
              (byPartners[pb] ??= []).add(err);
            }
          }
        }
      }
    }
    out[e.key] = {
      'maeByMatches': {for (final k in byMatches.keys) '$k': mean(byMatches[k]!)},
      'maeBySigmaAt10': {for (final k in bySigma.keys) k: mean(bySigma[k]!)},
      'maeByPartnersAt10': {for (final k in byPartners.keys) '$k': mean(byPartners[k]!)},
    };
  }
  return out;
}

// ═════════════════════════════════════════════════════════════════════════════
void main(List<String> args) {
  final which = args.isEmpty ? 'all' : args.first;
  final sw = Stopwatch()..start();
  final res = <String, dynamic>{};

  void run(String key, Map<String, dynamic> Function() f) {
    if (which == 'all' || which == key) res[key] = f();
  }

  print('Ranking-engine study — running "$which"');
  run('e1', e1ColdStart);
  run('e2', e2Prior);
  run('e3', e3Reliability);
  run('e4', e4PlacementK);
  run('e5', e5Matchmaking);
  run('e6', e6Curve);
  run('e7', e7Margin);
  run('e8', e8TeamModel);
  run('e9', e9Boosting);
  run('e10', e10Sigma);
  run('e11', e11Inactivity);
  run('e12', e12Anchors);
  run('e13', e13Scenarios);
  run('e14', e14DisplayGate);

  final dir = Directory('tools/ranking_simulation/results');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final file = File('${dir.path}/results${which == 'all' ? '' : '_$which'}.json');
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(res));
  print('\nDone in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s → ${file.path}');
}

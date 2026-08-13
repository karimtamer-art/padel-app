/// Guards the Ranking Lab against showing numbers production would not produce.
///
/// The lab exists to decide whether to change the rating engine, so its
/// baseline has to BE the baseline. Three things are pinned here:
///
///  1. the simulator's V2 engine reproduces `RatingEngine` (the production
///     mirror of the SQL `_settle_rating`) exactly, over a grid of states;
///  2. turning on the lab's explanation traces does not change any number —
///     observing an engine must not perturb it;
///  3. the V3 candidate is deterministic, so a seed names one run for good.
///
/// If (1) fails, fix the SIMULATOR, never the assertion — a lab whose baseline
/// has drifted from production is worse than no lab, because it produces
/// confident comparisons against a straw man.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:padel_clay/backend/models/rating_engine.dart';

import '../tools/ranking_simulation/engines.dart';
import '../tools/ranking_simulation/sim.dart';
import '../tools/ranking_simulation/ui/lab_kernel.dart';

double round2(double v) => (v * 100).round() / 100;
double round4(double v) => (v * 10000).round() / 10000;

/// One deterministic doubles match fed to both implementations.
class _Case {
  final List<double> ratings; // a1, a2, b1, b2
  final List<double> sigmas;
  final List<int> played;
  final int gamesA, gamesB;
  final bool aWon;
  const _Case(this.ratings, this.sigmas, this.played, this.gamesA, this.gamesB, this.aWon);

  @override
  String toString() => 'r=$ratings σ=$sigmas n=$played $gamesA-$gamesB aWon=$aWon';
}

List<_Case> _grid() {
  final out = <_Case>[];
  final rng = Rng(20260812);
  // a spread of realistic states: fresh players, established players, mixed
  // sigma, blowouts and squeakers, both winners
  for (var i = 0; i < 240; i++) {
    final ratings = [
      for (var p = 0; p < 4; p++) round2(clampD(0.4 + rng.nextDouble() * 6.2, 0, 7)),
    ];
    final sigmas = [
      for (var p = 0; p < 4; p++) round4(0.12 + rng.nextDouble() * 0.85),
    ];
    final played = [for (var p = 0; p < 4; p++) rng.nextInt(14)];
    final ga = 6 + rng.nextInt(14);
    final gb = rng.nextInt(14);
    out.add(_Case(ratings, sigmas, played, ga, gb, rng.chance(0.5)));
  }
  // explicit edge cases
  out.add(const _Case([2.0, 2.0, 2.0, 2.0], [0.85, 0.85, 0.85, 0.85], [0, 0, 0, 0], 12, 5, true));
  out.add(const _Case([7.0, 7.0, 0.0, 0.0], [0.12, 0.12, 1.0, 1.0], [50, 50, 0, 0], 12, 0, true));
  out.add(const _Case([0.0, 0.0, 7.0, 7.0], [1.0, 1.0, 0.12, 0.12], [0, 0, 50, 50], 0, 12, false));
  out.add(const _Case([3.3, 3.3, 3.3, 3.3], [0.5, 0.5, 0.5, 0.5], [5, 5, 5, 5], 0, 0, true));
  return out;
}

/// Production's answer for the same case, as (rating, sigma) per player.
List<List<double>> _production(_Case c) {
  RatedPlayer p(int i) => RatedPlayer(
        id: '$i',
        rating: c.ratings[i],
        sigma: c.sigmas[i],
        competitiveMatches: c.played[i],
      );
  final changes = RatingEngine.settleMatch(
    team1: [p(0), p(1)],
    team2: [p(2), p(3)],
    team1Games: c.gamesA,
    team2Games: c.gamesB,
    outcome: c.aWon ? MatchOutcome.team1Win : MatchOutcome.team2Win,
  );
  return [
    for (final ch in changes) [ch.ratingAfter, ch.sigmaAfter],
  ];
}

/// The simulator's answer, driven through the same public interface the lab
/// uses (so the test covers the lab's path, not a private shortcut).
List<List<double>> _simulator(_Case c, {List<MoveTrace>? trace}) {
  final e = CurrentEngine();
  for (var i = 0; i < 4; i++) {
    e.register(i);
    e.seed(i, c.ratings[i], c.sigmas[i]);
  }
  // Reach the requested match counts without moving anything: `matches` only
  // gates the ×1.5 placement boost, so replaying real matches would change the
  // ratings we are trying to hold fixed.
  for (var i = 0; i < 4; i++) {
    e.primeMatches(i, c.played[i]);
  }
  e.trace = trace;
  e.update(MatchObs(
    a1: 0,
    a2: 1,
    b1: 2,
    b2: 3,
    gamesA: c.gamesA,
    gamesB: c.gamesB,
    sets: const [],
    aWon: c.aWon,
  ));
  e.trace = null;
  return [
    for (var i = 0; i < 4; i++) [e.estimate(i), e.sigmaOf(i)],
  ];
}

/// Same as [_simulator] but with the lab's scaled thresholds, for proving the
/// scaling touches only what it claims to.
List<List<double>> _simulatorWith(_Case c, {required bool scaled}) {
  final e = scaled
      ? CurrentEngine(boostWindow: 3, provisionalAt: 5)
      : CurrentEngine();
  for (var i = 0; i < 4; i++) {
    e.register(i);
    e.seed(i, c.ratings[i], c.sigmas[i]);
    e.primeMatches(i, c.played[i]);
  }
  e.update(MatchObs(
    a1: 0,
    a2: 1,
    b1: 2,
    b2: 3,
    gamesA: c.gamesA,
    gamesB: c.gamesB,
    sets: const [],
    aWon: c.aWon,
  ));
  return [
    for (var i = 0; i < 4; i++) [e.estimate(i), e.sigmaOf(i)],
  ];
}

void main() {
  group('simulator V2 == production RatingEngine', () {
    test('reproduces settleMatch over a 244-case grid', () {
      for (final c in _grid()) {
        final prod = _production(c);
        final sim = _simulator(c);
        for (var i = 0; i < 4; i++) {
          // The simulator rounds to the precision the DB column stores
          // (numeric(3,2) rating, 4dp sigma); production returns full doubles.
          expect(sim[i][0], closeTo(round2(prod[i][0]), 1e-9),
              reason: 'rating p$i for $c');
          expect(sim[i][1], closeTo(round4(prod[i][1]), 1e-9),
              reason: 'sigma p$i for $c');
        }
      }
    });

    test('the 2.0 prior and 0.85 starting sigma match production defaults', () {
      final e = CurrentEngine();
      e.register(0);
      expect(e.estimate(0), 2.0);
      expect(e.sigmaOf(0), 0.85);
      expect(CurrentEngine.prior, 2.0);
      expect(CurrentEngine.sigma0, RatingEngine.sigmaMax * 0.85);
    });

    test('K, W and S agree with the production formulas', () {
      expect(RatingEngine.kFactor(0.85, 0), closeTo((0.04 + 0.31 * 0.85) * 1.5, 1e-12));
      expect(RatingEngine.wOpp([0.85, 0.85]), closeTo(0.5 + 0.5 * (1 - 0.85), 1e-12));
      expect(RatingEngine.scoreSignal(1, 12, 6), closeTo(0.7 + 0.3 * (12 / 18), 1e-12));
    });
  });

  group('tracing is observation only', () {
    test('identical results with the trace buffer attached', () {
      for (final c in _grid()) {
        final without = _simulator(c);
        final buf = <MoveTrace>[];
        final with_ = _simulator(c, trace: buf);
        expect(with_, equals(without), reason: 'trace perturbed the result for $c');
        expect(buf.length, 4);
      }
    });

    test('the trace arithmetic reconstructs the delta it reports', () {
      for (final c in _grid().take(60)) {
        final buf = <MoveTrace>[];
        _simulator(c, trace: buf);
        for (final t in buf) {
          // delta is the CLAMPED, ROUNDED move, so rebuild the raw one and
          // check it agrees before those two steps.
          final raw = t.k! * t.w! * (t.signal! - t.expected);
          final expected = round2(clampD(t.before + raw, 0, 7)) - t.before;
          expect(t.delta, closeTo(expected, 1e-9), reason: '$c');
          expect(t.resultPart! + t.marginPart!, closeTo(t.signal!, 1e-12));
        }
      }
    });
  });

  group('V3 candidate', () {
    test('is deterministic — one seed names one run', () {
      String run() => handleRequest('{"op":"solo.run","seed":4242,"trueSkill":5.5,'
          '"matches":12,"engines":[{"id":"v3"}]}');
      expect(run(), equals(run()));
    });

    test('golden vector: a true 5.5 through 10 placement matches', () {
      final out = handleRequest('{"op":"solo.run","seed":482901,"trueSkill":5.5,'
          '"matches":10,"engines":[{"id":"v2"},{"id":"v3"}]}');
      // Pinned so an accidental change to the engine, the RNG or the lineup
      // picker fails loudly here instead of silently moving every conclusion.
      expect(out, contains('"trueSkill":5.5'));
      expect(out, contains('"matches":10'));
      final v2 = _finalOf(out, 0), v3 = _finalOf(out, 1);
      expect(v2, closeTo(3.40, 0.005));
      expect(v3, closeTo(4.89, 0.005));
      // The whole point of V3: the same player, same matches, far less squashed.
      expect((v3 - 5.5).abs(), lessThan((v2 - 5.5).abs()));
    });

    test('starts at the centre of the population, not the floor', () {
      final e = v3Engine();
      e.register(0);
      expect(e.estimate(0), 3.3);
      expect(kV3Config.placementRelFloor, 1.0);
      expect(kV3Config.marginCap, 0.15);
      expect(kV3Config.stageK, [0.80, 0.50, 0.30]);
      expect(kV3Config.ratingInactivityDecay, isFalse);
    });
  });

  group('the lab describes each engine honestly', () {
    List<RankingEngine> allEngines() => [
          CurrentEngine(),
          v3Engine(),
          tunedEngine(),
          aggressiveEngine(),
          TrueSkillEngine(),
          TrueSkillEngine(perSet: true),
          Glicko2Engine(),
        ];

    test('displayGate agrees with displayReady at every state', () {
      // The lab TELLS the user the gate rule. If the stated rule and the real
      // one drift apart, the page confidently explains something untrue.
      for (final e in allEngines()) {
        final (needMatches, maxSigma, needPartners) = e.displayGate;
        e.register(0);
        for (final matches in const [0, 1, 5, 6, 9, 10, 11, 30]) {
          for (final sigma in const [0.1, 0.3, 0.39, 0.40, 0.41, 0.5, 0.55, 0.6, 0.9]) {
            e.seed(0, 3.3, sigma);
            e.primeMatches(0, matches);
            final stated = matches >= needMatches &&
                e.sigmaOf(0) <= maxSigma &&
                needPartners == 0; // no partners recorded in this fixture
            expect(e.displayReady(0), stated,
                reason: '${e.name}: gate says ($needMatches, $maxSigma) but '
                    'displayReady disagreed at matches=$matches sigma=$sigma');
          }
        }
      }
    });

    test('only the configurable hybrid claims a placement phase', () {
      // Production has a K boost and a display gate; neither is a phase. Saying
      // otherwise in the UI is what made "V2 has a 10-match placement" look
      // true when it is not.
      expect(CurrentEngine().placementLength, 0,
          reason: 'production has no placement phase to report');
      expect(TrueSkillEngine().placementLength, 0);
      expect(Glicko2Engine().placementLength, 0);
      expect(v3Engine().placementLength, kV3Config.placementMatches);
      expect(tunedEngine().placementLength, kTunedConfig.placementMatches);
    });

    test('V2 with default thresholds IS production, and says so', () {
      final e = CurrentEngine();
      expect(e.isProductionExact, isTrue);
      expect(e.name, contains('production'));
      expect(e.boostWindow, 5);
      expect(e.provisionalAt, 10);
    });

    test('scaling V2 changes the two counts and nothing else', () {
      // The comparison is only fair if both engines commit at the same match
      // count — but a scaled V2 must never be passed off as production.
      final scaled = CurrentEngine(boostWindow: 3, provisionalAt: 5);
      expect(scaled.isProductionExact, isFalse);
      expect(scaled.name, contains('adapted'));
      expect(scaled.displayGate, (5, 0.40, 0));
      expect(scaled.placementLength, 0, reason: 'still no placement phase');

      // Past the boost window both agree exactly: the maths is untouched.
      for (final c in _grid().take(80)) {
        if (c.played.every((n) => n >= 5)) {
          expect(_simulator(c), equals(_simulatorWith(c, scaled: true)),
              reason: 'scaling changed a rating outside the boost window');
        }
      }

      // Inside it, the boost window is the only thing that can differ.
      final inBoost = _Case(const [3.0, 3.0, 3.0, 3.0], const [0.85, 0.85, 0.85, 0.85],
          const [4, 4, 4, 4], 12, 6, true);
      expect(_simulator(inBoost)[0][0],
          isNot(equals(_simulatorWith(inBoost, scaled: true)[0][0])),
          reason: 'a player 4 matches in should feel a boost window of 3 vs 5');
    });

    test('V2 mirrors the is_provisional column, not the other two thresholds', () {
      // The live schema disagrees with itself: the generated column uses < 10,
      // while admin_season_player and a view fallback use < 5. The stored
      // column is the one that decides, so it is the one mirrored here.
      final (matches, sigma, _) = CurrentEngine().displayGate;
      expect(matches, 10);
      expect(sigma, 0.40);
    });
  });

  group('V3 placement variants', () {
    Map<String, dynamic> op(String body) =>
        (jsonDecode(handleRequest(body)) as Map).cast<String, dynamic>();

    test('V3-A IS the candidate — the baseline cannot drift', () {
      // Every variant is read against A. If A stopped being V3 the whole
      // experiment would be comparing five unlabelled things.
      final presets = (op('{"op":"meta"}')['presets'] as Map).cast<String, dynamic>();
      expect(presets['v3a'], equals(presets['v3']));
    });

    test('only placement K and placement sigma differ between variants', () {
      final presets = (op('{"op":"meta"}')['presets'] as Map).cast<String, dynamic>();
      final base = (presets['v3a'] as Map).cast<String, dynamic>();
      for (final id in const ['v3b', 'v3c', 'v3d', 'v3e']) {
        final v = (presets[id] as Map).cast<String, dynamic>();
        expect(v.keys.toSet(), base.keys.toSet(), reason: id);
        for (final k in base.keys) {
          if (k == 'stageK' || k == 'placementSigmaDecay') continue;
          expect(v[k], base[k],
              reason: '$id changed "$k" — variants must isolate the two knobs');
        }
      }
      // F is deliberately NOT in that family: it is the only variant allowed to
      // touch something outside placement, and the test says which knob.
      final fv = (presets['v3f'] as Map).cast<String, dynamic>();
      final ev = (presets['v3e'] as Map).cast<String, dynamic>();
      for (final k in base.keys) {
        if (k == 'sigmaDecay') continue;
        expect(fv[k], ev[k], reason: 'V3-F changed "$k" — it may only move sigmaDecay');
      }
      expect(fv['sigmaDecay'], isNot(ev['sigmaDecay']));

      // …and each one actually changes what it claims to.
      expect((presets['v3b'] as Map)['stageK'], isNot(base['stageK']));
      expect((presets['v3c'] as Map)['stageK'], isNot(base['stageK']));
      expect((presets['v3d'] as Map)['placementSigmaDecay'],
          isNot(base['placementSigmaDecay']));
      expect((presets['v3d'] as Map)['stageK'], base['stageK']);
      expect((presets['v3e'] as Map)['stageK'], (presets['v3b'] as Map)['stageK']);
      expect((presets['v3e'] as Map)['placementSigmaDecay'],
          (presets['v3d'] as Map)['placementSigmaDecay']);
    });

    test('every variant sees the identical match stream', () {
      // The comparison is only valid if no engine gets its own matchmaking.
      // Running each engine ALONE must reproduce what it did in the group.
      const args = '"seed":4242,"reps":3,"skills":[1.5],"horizons":[10],'
          '"pool":"established"';
      final together = op('{"op":"v3.sweep",$args,"engines":'
          '[{"id":"v3a"},{"id":"v3b"},{"id":"v3c"},{"id":"v3d"},{"id":"v3e"}]}');
      for (final id in const ['v3a', 'v3b', 'v3c', 'v3d', 'v3e']) {
        final alone = op('{"op":"v3.sweep",$args,"engines":[{"id":"$id"}]}');
        final a = ((alone['rows'] as List).first as Map)['at'] as List;
        final g = (together['rows'] as List)
            .cast<Map>()
            .firstWhere((r) => r['id'] == id)['at'] as List;
        expect((a.first as Map)['mean'], closeTo((g.first as Map)['mean'] as double, 1e-12),
            reason: '$id moved when other engines were present');
      }
    });

    test('the lean play path simulates exactly what the Story tab does', () {
      // The sweep skips traces and logging for speed. If that ever changed the
      // SIMULATION, every sweep number would describe a different app.
      final story = op('{"op":"solo.run","seed":777,"trueSkill":2.0,"matches":10,'
          '"engines":[{"id":"v3a"}]}');
      final sweep = op('{"op":"v3.sweep","seed":777,"reps":1,"skills":[2.0],'
          '"horizons":[10],"pool":"established","engines":[{"id":"v3a"}]}');
      final storyFinal = ((story['series'] as List).first as Map)['final'] as double;
      final sweepFinal =
          (((sweep['rows'] as List).first as Map)['at'] as List).first as Map;
      expect(sweepFinal['mean'], closeTo(storyFinal, 1e-12));
    });

    test('recovery is signed, so moving the wrong way cannot look like progress', () {
      final r = op('{"op":"v3.sweep","seed":9,"reps":4,"skills":[0.5,6.5],'
          '"horizons":[10],"pool":"established","engines":[{"id":"v3a"}]}');
      for (final row in (r['rows'] as List).cast<Map>()) {
        final a = (row['at'] as List).first as Map;
        final moved = (a['movement'] as num).toDouble();
        final need = (a['required'] as num).toDouble();
        expect((a['recovered'] as num).toDouble(), closeTo(moved / need, 1e-12));
        // both far from the 3.3 prior, so both must have something to recover
        expect(need.abs(), greaterThan(1.0));
      }
    });

    test('a skill sitting on the prior reports no recovery rather than a fake one', () {
      final r = op('{"op":"v3.sweep","seed":9,"reps":2,"skills":[3.3],'
          '"horizons":[10],"pool":"established","engines":[{"id":"v3a"}]}');
      final a = (((r['rows'] as List).first as Map)['at'] as List).first as Map;
      expect(a['recovered'], isNull);
    });

    test('directional recovery is distance-weighted, not a mean of percentages', () {
      // A plain mean lets a row needing 0.3 count as much as one needing 2.8.
      final r = op('{"op":"v3.sweep","seed":31,"reps":6,'
          '"skills":[0.5,1.5,2.5,4.0,5.0,6.0],"horizons":[10],'
          '"pool":"established","engines":[{"id":"v3a"}]}');
      final rows = (r['rows'] as List).cast<Map>();
      final start = (rows.first['start'] as num).toDouble();
      var dm = 0.0, dn = 0.0, um = 0.0, un = 0.0;
      for (final row in rows) {
        final a = (row['at'] as List).first as Map;
        if (a['recovered'] == null) continue;
        final below = (row['trueSkill'] as num) < start;
        if (below) {
          dm += a['movement'] as double;
          dn += a['required'] as double;
        } else {
          um += a['movement'] as double;
          un += a['required'] as double;
        }
      }
      final s = ((r['summary'] as List).first as Map)['at'] as List;
      expect((s.first as Map)['downRecovery'], closeTo(dm / dn, 1e-12));
      expect((s.first as Map)['upRecovery'], closeTo(um / un, 1e-12));
    });

    test('matched pairs compare comparable distances', () {
      final r = op('{"op":"v3.sweep","seed":5,"reps":3,'
          '"skills":[0.5,1.5,2.5,4.0,5.0,6.0],"horizons":[10],'
          '"pool":"established","engines":[{"id":"v3a"}]}');
      final pairs = (((r['summary'] as List).first as Map)['at'] as List)
          .first as Map;
      final list = (pairs['pairs'] as List).cast<Map>();
      expect(list, isNotEmpty);
      for (final p in list) {
        final d = (p['distance'] as num).toDouble();
        final u = (p['upDistance'] as num).toDouble();
        expect((d - u).abs(), lessThanOrEqualTo(0.35),
            reason: 'paired ${p['downSkill']} with ${p['upSkill']} across $d vs $u');
        expect(p['downSkill'] as num, lessThan(3.3));
        expect(p['upSkill'] as num, greaterThan(3.3));
      }
    });

    test('V3-F5 reveals on match count alone, at match 5', () {
      // The whole point of the 5-match design: the player is ranked while the
      // engine is still openly unsure. A sigma gate here would either block the
      // reveal or force the engine to claim a confidence it does not have.
      final e = HybridEngine('t', kV3F5);
      final (matches, maxSigma, partners) = e.displayGate;
      expect(matches, 5);
      expect(maxSigma, greaterThanOrEqualTo(1.0));
      expect(partners, 0);
      expect(kV3F5.placementMatches, 5);
      expect(kV3F5.stageEnds, [2, 4, 5]);
    });

    test('post-placement confidence approaches the established rate from above', () {
      // Never dip below the established decay and come back up: that would
      // make a 7-match player MORE certain per match than a 40-match one.
      for (final d in kV3F5.postStageDecay) {
        expect(d, greaterThanOrEqualTo(kV3F5.sigmaDecay),
            reason: 'a post-placement band decays faster than established');
      }
      final desc = [...kV3F5.postStageDecay, kV3F5.sigmaDecay];
      for (var i = 1; i < desc.length; i++) {
        expect(desc[i], lessThanOrEqualTo(desc[i - 1]),
            reason: 'confidence must tighten monotonically, not oscillate');
      }
      // …and sigma really does keep falling all the way to established.
      final e = HybridEngine('t', kV3F5);
      for (var i = 0; i < 4; i++) {
        e.register(i);
      }
      e.seed(0, 3.3, 0.95);
      var prev = e.sigmaOf(0);
      for (var n = 1; n <= 40; n++) {
        e.primeMatches(0, n - 1);
        e.update(const MatchObs(
            a1: 0, a2: 1, b1: 2, b2: 3, gamesA: 12, gamesB: 6, sets: [], aWon: true));
        final now = e.sigmaOf(0);
        expect(now, lessThanOrEqualTo(prev + 1e-12), reason: 'sigma rose at match $n');
        prev = now;
      }
      expect(prev, lessThan(0.35), reason: 'never actually settles');
    });

    test('a sweep is deterministic', () {
      const body = '{"op":"v3.sweep","seed":11,"reps":5,"skills":[1.0,5.0],'
          '"horizons":[10,20],"pool":"fresh","engines":[{"id":"v3e"}]}';
      expect(handleRequest(body), equals(handleRequest(body)));
    });
  });

  group('score parsing matches production', () {
    test('a match tie-break counts as one game', () {
      final parsed = parseScore('6-4,3-6,10-8');
      final prod = parseSetGames('6-4,3-6,10-8');
      expect(parsed['gamesA'], prod.team1);
      expect(parsed['gamesB'], prod.team2);
      expect(parsed['aWon'], isTrue);
    });

    test('ordinary scorelines agree with production', () {
      for (final s in const ['6-4,6-3', '7-6,6-7,7-6', '6-0,6-0', '3-6,6-4,7-5']) {
        final parsed = parseScore(s);
        final prod = parseSetGames(s);
        expect(parsed['gamesA'], prod.team1, reason: s);
        expect(parsed['gamesB'], prod.team2, reason: s);
      }
    });

    test('rejects what production would treat as unfinished', () {
      expect(parseScore('6-4')['aWon'], isTrue); // single set is allowed
      expect(parseScore('6-4,4-6')['error'], isNotNull); // level sets
      expect(parseScore('')['error'], isNotNull);
      expect(parseScore('6-6')['error'], isNotNull);
      expect(parseScore('banana')['error'], isNotNull);
    });
  });
}

double _finalOf(String json, int index) {
  final marks = '"final":'.allMatches(json).toList();
  final at = marks[index].end;
  final rest = json.substring(at);
  final end = rest.indexOf(RegExp(r'[,}]'));
  return double.parse(rest.substring(0, end));
}

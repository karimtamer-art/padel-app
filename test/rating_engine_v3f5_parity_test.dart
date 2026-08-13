/// Three-way parity for V3-F5: **Ranking Lab ↔ Dart reference ↔ SQL**.
///
/// The lab implementation is the mathematical source of truth. Production is a
/// port of it, so "production is correct" means exactly one thing: given
/// identical pre-match state, production and the lab produce the same numbers.
/// This file is that claim, made runnable.
///
/// Three separate guards, because they fail for different reasons:
///
///  1. **Lab ↔ Dart, per intermediate term.** Not just the final rating — team
///     strength, E, S, W, K, delta and sigma individually. A delta that agrees
///     because two errors cancel is not parity, and would drift apart the
///     moment a scoreline changed.
///  2. **The config is really V3-F5.** `kV3F5` is built by four chained
///     `copyWith` calls, so a change to `kV3Config`, `kV3E` or `kV3F` silently
///     changes V3-F5 too. Every resolved field is pinned here.
///  3. **SQL ↔ Dart constants.** The SQL cannot be executed from a Flutter
///     test, so instead the constant block of `_settle_rating_v3f5` is parsed
///     out of the migration and compared field by field. That catches the
///     realistic failure — someone tunes one side and forgets the other —
///     which no amount of Dart-only testing would.
///
/// What this file does NOT prove: that Postgres `numeric` arithmetic agrees
/// with Dart `double` to the last bit. It does not, and cannot — they are
/// different number systems. The reconciliation is the rounding policy
/// (`storedRating`, 6dp), whose accumulated error is bounded by a test in
/// `rating_engine_v3f5_test.dart`.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:padel_clay/backend/models/rating_engine_v3f5.dart';

import '../tools/ranking_simulation/engines.dart';
import '../tools/ranking_simulation/sim.dart';

/// Doubles are compared this tightly: the two implementations run the same
/// operations in the same order, so anything looser would hide a real bug.
const tol = 1e-12;

/// One deterministic doubles match, fully specifying both implementations'
/// starting state — §29's "enough state to fully reproduce a match".
class Fixture {
  final List<double> ratings; // a1, a2, b1, b2
  final List<double> sigmas;
  final List<int> played;
  final List<bool> anchors;
  final int gamesA, gamesB;
  final bool aWon;
  final String label;

  const Fixture(this.label, this.ratings, this.sigmas, this.played,
      this.anchors, this.gamesA, this.gamesB, this.aWon);

  @override
  String toString() =>
      '$label r=$ratings s=$sigmas n=$played anchor=$anchors '
      '$gamesA-$gamesB aWon=$aWon';
}

/// Runs a fixture through the LAB engine and returns each player's trace.
List<MoveTrace> lab(Fixture f) {
  final e = HybridEngine('v3f5', kV3F5);
  e.trace = <MoveTrace>[];
  for (var i = 0; i < 4; i++) {
    e.register(i);
    if (f.anchors[i]) {
      // markAnchor also forces the match counter to at least placementMatches,
      // so it is applied BEFORE primeMatches to keep the fixture's count.
      e.markAnchor(i, f.ratings[i], f.sigmas[i]);
    } else {
      e.seed(i, f.ratings[i], f.sigmas[i]);
    }
    e.primeMatches(i, f.played[i]);
  }
  e.update(MatchObs(
      a1: 0, a2: 1, b1: 2, b2: 3,
      gamesA: f.gamesA, gamesB: f.gamesB, sets: const [], aWon: f.aWon));
  return e.trace!;
}

/// Runs the same fixture through the PRODUCTION reference.
Map<int, RatingMove> production(Fixture f) {
  RatedPlayer at(int i) => RatedPlayer(
        id: '$i',
        rating: f.ratings[i],
        sigma: f.sigmas[i],
        competitiveMatches: f.played[i],
        isAnchor: f.anchors[i],
      );
  final moves = RatingEngineV3F5.settleMatch(
    team1: [at(0), at(1)],
    team2: [at(2), at(3)],
    team1Games: f.gamesA,
    team2Games: f.gamesB,
    outcome: f.aWon ? MatchOutcome.team1Win : MatchOutcome.team2Win,
  );
  return {for (final m in moves) int.parse(m.id): m};
}

/// A broad, deterministic grid plus the edge cases that matter.
List<Fixture> fixtures() {
  final out = <Fixture>[];
  final rng = Rng(20260813);

  double r2(double v) => (v * 100).round() / 100;
  double r4(double v) => (v * 10000).round() / 10000;

  for (var i = 0; i < 400; i++) {
    final ratings = [
      for (var k = 0; k < 4; k++) r2(clampD(rng.nextDouble() * 7.0, 0, 7)),
    ];
    final sigmas = [
      for (var k = 0; k < 4; k++) r4(0.12 + rng.nextDouble() * 0.88),
    ];
    // spans placement, both post-placement sigma bands and established play
    final played = [for (var k = 0; k < 4; k++) rng.nextInt(30)];
    final anchors = [for (var k = 0; k < 4; k++) rng.chance(0.10)];
    final ga = rng.nextInt(20);
    final gb = rng.nextInt(20);
    out.add(Fixture('grid$i', ratings, sigmas, played, anchors, ga, gb,
        rng.chance(0.5)));
  }

  const noAnchor = [false, false, false, false];
  const fresh = [0.95, 0.95, 0.95, 0.95];

  // Every band boundary, on both sides.
  for (final n in [0, 1, 2, 3, 4, 5, 6, 9, 10, 11, 19, 20, 21, 50]) {
    out.add(Fixture('boundary n=$n', const [3.3, 3.3, 3.3, 3.3],
        [RatingEngineV3F5.sigmaAfter(n), 0.95, 0.95, 0.95], [n, 0, 0, 0],
        noAnchor, 12, 7, true));
  }

  // Scorelines, including the championship tie-break the lab's generated
  // worlds never produced.
  for (final g in [
    [12, 0], [12, 4], [12, 8], [14, 12], [10, 10], [0, 0], [1, 12], [19, 0],
  ]) {
    out.add(Fixture('score ${g[0]}-${g[1]}', const [3.5, 3.5, 3.5, 3.5],
        const [0.5, 0.5, 0.5, 0.5], const [30, 30, 30, 30], noAnchor,
        g[0], g[1], g[0] > g[1]));
  }

  return [
    ...out,
    const Fixture('all fresh', [3.3, 3.3, 3.3, 3.3], fresh,
        [0, 0, 0, 0], noAnchor, 12, 7, true),
    const Fixture('rating floor', [0.0, 0.0, 6.9, 6.9], fresh,
        [0, 0, 0, 0], noAnchor, 0, 12, false),
    const Fixture('rating ceiling', [7.0, 7.0, 0.1, 0.1], fresh,
        [0, 0, 0, 0], noAnchor, 12, 0, true),
    const Fixture('sigma floor', [3.5, 3.5, 3.5, 3.5],
        [0.12, 0.12, 0.12, 0.12], [80, 80, 80, 80], noAnchor,
        12, 9, true),
    const Fixture('anchor clamped', [3.0, 3.0, 6.5, 6.5], fresh,
        [0, 0, 0, 0], [true, false, false, false], 12, 2, true),
    const Fixture('anchor unclamped', [3.0, 3.0, 3.05, 3.05],
        [0.3, 0.3, 0.3, 0.3], [30, 30, 30, 30],
        [true, false, false, false], 12, 11, true),
    const Fixture('huge favourite narrow win', [6.5, 6.5, 1.0, 1.0],
        [0.3, 0.3, 0.3, 0.3], [40, 40, 40, 40], noAnchor,
        12, 8, true),
    const Fixture('uneven doubles', [5.0, 2.0, 3.5, 3.5],
        [0.3, 0.3, 0.3, 0.3], [30, 30, 30, 30], noAnchor,
        12, 8, true),
    const Fixture('new vs established', [3.3, 3.3, 4.0, 4.0],
        [0.95, 0.95, 0.25, 0.25], [0, 0, 50, 50], noAnchor,
        12, 6, true),
  ];
}

// ── SQL constant extraction ────────────────────────────────────────────────

/// Pulls `name constant type := value;` pairs out of the V3-F5 constant block
/// in the migration, so the SQL engine's constants can be compared with Dart's.
Map<String, String> sqlConstants() {
  final file = File('supabase/migration_player_app.sql');
  if (!file.existsSync()) {
    throw StateError('run tests from the project root — migration not found');
  }
  final sql = file.readAsStringSync();

  final start = sql.indexOf('create or replace function public._settle_rating_v3f5');
  if (start < 0) throw StateError('_settle_rating_v3f5 not in migration');
  final end = sql.indexOf('begin', start);
  final decl = sql.substring(start, end);

  final out = <String, String>{};
  final re = RegExp(
      r'^\s*(c_\w+)\s+constant\s+[\w\[\]]+\s*:=\s*(.+?);', multiLine: true);
  for (final m in re.allMatches(decl)) {
    out[m.group(1)!] = m.group(2)!.trim();
  }
  return out;
}

double sqlNum(Map<String, String> c, String key) {
  final raw = c[key];
  if (raw == null) throw StateError('SQL constant $key missing');
  return double.parse(raw);
}

List<double> sqlArray(Map<String, String> c, String key) {
  final raw = c[key];
  if (raw == null) throw StateError('SQL constant $key missing');
  final inner = RegExp(r'array\[(.+)\]').firstMatch(raw)!.group(1)!;
  return inner.split(',').map((s) => double.parse(s.trim())).toList();
}

/// The dollar-quoted body of the function definition starting at [start].
///
/// Not `indexOf('end $$;')` — `language sql` functions close with a bare `$$;`
/// and that scan runs straight past them into the next function, attributing
/// its statements to the wrong name.
String bodyAt(String sql, int start) {
  final open = sql.indexOf(r'$$', start);
  if (open < 0) return '';
  final close = sql.indexOf(r'$$', open + 2);
  return sql.substring(open, close < 0 ? sql.length : close);
}

void main() {
  // ═══════════════════════════════════════════════════════════════════════
  // 1. The lab config really is V3-F5
  // ═══════════════════════════════════════════════════════════════════════
  group('kV3F5 resolves to the audited configuration', () {
    // kV3F5 = kV3F.copyWith(...) = kV3E.copyWith(...) = kV3Config.copyWith(...)
    // Anything inherited rather than overridden is pinned here too, because a
    // change to an ancestor config would otherwise change V3-F5 unnoticed.
    test('prior and starting sigma', () {
      expect(kV3F5.prior, 3.3);
      expect(kV3F5.sigma0, 0.95);
      expect(kV3F5.useDeclaredPrior, isFalse);
    });
    test('placement schedule', () {
      expect(kV3F5.placementMatches, 5);
      expect(kV3F5.stageEnds, [2, 4, 5]);
      expect(kV3F5.stageK, [1.15, 0.90, 0.70]);
      expect(kV3F5.placementSigmaDecay, 0.97);
      expect(kV3F5.relRampMatches, 0);
    });
    test('reliability floors', () {
      expect(kV3F5.placementRelFloor, 1.0);
      expect(kV3F5.relFloor, 0.65);
    });
    test('post-placement K and sigma bands', () {
      expect(kV3F5.kMin, 0.04);
      expect(kV3F5.kMax, 0.35);
      expect(kV3F5.postStageEnds, [10, 20]);
      expect(kV3F5.postStageDecay, [0.980, 0.975]);
      expect(kV3F5.sigmaDecay, 0.97);
    });
    test('model shape', () {
      expect(kV3F5.curveScale, 1.0);
      expect(kV3F5.resultWeight, 0.85);
      expect(kV3F5.marginCap, 0.15);
    });
    test('the experimental knobs are OFF', () {
      expect(kV3F5.lambdaImbalance, 0.0, reason: 'doubles lambda must stay 0');
      expect(kV3F5.adaptiveSigma, isFalse, reason: 'adaptive sigma must stay off');
      expect(kV3F5.diversitySigma, isFalse);
      expect(kV3F5.ratingInactivityDecay, isFalse);
    });
    test('internal range is the public range', () {
      expect(kV3F5.internalMin, 0.0);
      expect(kV3F5.internalMax, 7.0);
    });
    test('reveal is a match-count gate only', () {
      expect(kV3F5.displayMinMatches, 5);
      expect(kV3F5.displayMaxSigma, 1.0);
      expect(kV3F5.displayMinPartners, 0);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  // 2. Dart reference == lab config, constant by constant
  // ═══════════════════════════════════════════════════════════════════════
  group('Dart reference mirrors the lab config', () {
    test('every ported constant matches kV3F5', () {
      expect(RatingEngineV3F5.prior, kV3F5.prior);
      expect(RatingEngineV3F5.sigma0, kV3F5.sigma0);
      expect(RatingEngineV3F5.placementMatches, kV3F5.placementMatches);
      expect(RatingEngineV3F5.stageEnds, kV3F5.stageEnds);
      expect(RatingEngineV3F5.stageK, kV3F5.stageK);
      expect(RatingEngineV3F5.placementSigmaDecay, kV3F5.placementSigmaDecay);
      expect(RatingEngineV3F5.postStageEnds, kV3F5.postStageEnds);
      expect(RatingEngineV3F5.postStageDecay, kV3F5.postStageDecay);
      expect(RatingEngineV3F5.sigmaDecay, kV3F5.sigmaDecay);
      expect(RatingEngineV3F5.kMin, kV3F5.kMin);
      expect(RatingEngineV3F5.kMax, kV3F5.kMax);
      expect(RatingEngineV3F5.placementRelFloor, kV3F5.placementRelFloor);
      expect(RatingEngineV3F5.relFloor, kV3F5.relFloor);
      expect(RatingEngineV3F5.curveScale, kV3F5.curveScale);
      expect(RatingEngineV3F5.resultWeight, kV3F5.resultWeight);
      expect(RatingEngineV3F5.marginCap, kV3F5.marginCap);
      expect(RatingEngineV3F5.ratingMin, kV3F5.internalMin);
      expect(RatingEngineV3F5.ratingMax, kV3F5.internalMax);
      expect(RatingEngineV3F5.sigmaMin, 0.12);
      expect(RatingEngineV3F5.sigmaMax, 1.0);
    });

    test('the reveal gate matches the lab display gate', () {
      final engine = HybridEngine('v3f5', kV3F5);
      for (final n in [0, 4, 5, 6, 20]) {
        engine.register(100);
        engine.seed(100, 3.3, RatingEngineV3F5.sigmaAfter(n));
        engine.primeMatches(100, n);
        expect(engine.displayReady(100), RatingEngineV3F5.isRevealed(n),
            reason: 'n=$n');
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  // 3. Lab == production, on every intermediate term (§29)
  // ═══════════════════════════════════════════════════════════════════════
  group('lab ↔ production settlement parity', () {
    final all = fixtures();

    test('${fixtures().length} fixtures agree on rating, sigma, K, W, E and S',
        () {
      var checked = 0;
      for (final f in all) {
        final traces = lab(f);
        final prod = production(f);
        expect(traces.length, 4, reason: '$f');

        for (final t in traces) {
          final m = prod[t.id]!;
          final why = '$f · player ${t.id}';

          // team strengths — proves the doubles model agrees
          expect(m.teamStrength, closeTo(t.teamRating, tol), reason: 'T $why');
          expect(m.oppStrength, closeTo(t.oppRating, tol), reason: 'O $why');
          // expected score
          expect(m.expected, closeTo(t.expected, tol), reason: 'E $why');
          // score signal
          expect(m.signal, closeTo(t.signal!, tol), reason: 'S $why');
          // opponent reliability and K
          expect(m.w, closeTo(t.w!, tol), reason: 'W $why');
          expect(m.k, closeTo(t.k!, tol), reason: 'K $why');
          // the applied delta and both pieces of state it produces
          expect(m.delta, closeTo(t.delta, tol), reason: 'delta $why');
          expect(m.ratingAfter, closeTo(t.after, tol), reason: 'rating $why');
          expect(m.sigmaAfter, closeTo(t.sigmaAfter, tol), reason: 'sigma $why');
          // stage / match count bookkeeping
          expect(m.matchesBefore, t.matchesBefore, reason: 'n $why');
          expect(m.inPlacement, t.inPlacement, reason: 'placement $why');
          checked++;
        }
      }
      expect(checked, all.length * 4);
    });

    test('a full 60-match career tracks the lab step for step', () {
      // Per-match parity can hide a divergence that only compounds. This
      // replays one player's whole career through both implementations,
      // feeding each match's output back in as the next match's input.
      final engine = HybridEngine('v3f5', kV3F5);
      for (var i = 0; i < 4; i++) {
        engine.register(i);
        engine.seed(i, i == 0 ? 3.3 : 3.6, 0.95);
      }
      var rating = 3.3, sigma = 0.95, n = 0;
      final rng = Rng(99);

      for (var match = 0; match < 60; match++) {
        final ga = rng.nextInt(16), gb = rng.nextInt(16);
        final aWon = ga > gb || (ga == gb && rng.chance(0.5));

        // production, from its own carried-forward state
        final oppSigma = engine.sigmaOf(2);
        final move = RatingEngineV3F5.settleMatch(
          team1: [
            RatedPlayer(id: '0', rating: rating, sigma: sigma, competitiveMatches: n),
            RatedPlayer(id: '1', rating: engine.estimate(1), sigma: engine.sigmaOf(1),
                competitiveMatches: engine.matchesOf(1)),
          ],
          team2: [
            RatedPlayer(id: '2', rating: engine.estimate(2), sigma: oppSigma,
                competitiveMatches: engine.matchesOf(2)),
            RatedPlayer(id: '3', rating: engine.estimate(3), sigma: engine.sigmaOf(3),
                competitiveMatches: engine.matchesOf(3)),
          ],
          team1Games: ga,
          team2Games: gb,
          outcome: aWon ? MatchOutcome.team1Win : MatchOutcome.team2Win,
        ).first;

        engine.update(MatchObs(
            a1: 0, a2: 1, b1: 2, b2: 3,
            gamesA: ga, gamesB: gb, sets: const [], aWon: aWon));

        rating = move.ratingAfter;
        sigma = move.sigmaAfter;
        n++;

        expect(rating, closeTo(engine.estimate(0), tol),
            reason: 'rating diverged at match ${match + 1}');
        expect(sigma, closeTo(engine.sigmaOf(0), tol),
            reason: 'sigma diverged at match ${match + 1}');
        expect(n, engine.matchesOf(0));
      }
    });

    test('the public (quarter-rounded) rating agrees too', () {
      for (final f in fixtures().take(200)) {
        final traces = lab(f);
        final prod = production(f);
        for (final t in traces) {
          final labPublic = (clampD(t.after, 0, 7) * 4).round() / 4;
          final prodPublic =
              (RatingEngineV3F5.clampD(prod[t.id]!.ratingAfter, 0, 7) * 4)
                      .round() /
                  4;
          expect(prodPublic, labPublic, reason: '$f player ${t.id}');
        }
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  // 4. SQL == Dart, constant by constant (§30)
  // ═══════════════════════════════════════════════════════════════════════
  group('SQL ↔ Dart constant parity', () {
    final c = sqlConstants();

    test('the constant block was found and parsed', () {
      expect(c, isNotEmpty);
      expect(c.keys, contains('c_prior'));
    });

    test('scalars match', () {
      expect(sqlNum(c, 'c_prior'), RatingEngineV3F5.prior);
      expect(sqlNum(c, 'c_sigma0'), RatingEngineV3F5.sigma0);
      expect(sqlNum(c, 'c_placement'), RatingEngineV3F5.placementMatches);
      expect(sqlNum(c, 'c_stage_lo'), RatingEngineV3F5.stageSigmaFloor);
      expect(sqlNum(c, 'c_k_min'), RatingEngineV3F5.kMin);
      expect(sqlNum(c, 'c_k_max'), RatingEngineV3F5.kMax);
      expect(sqlNum(c, 'c_curve'), RatingEngineV3F5.curveScale);
      expect(sqlNum(c, 'c_result_w'), RatingEngineV3F5.resultWeight);
      expect(sqlNum(c, 'c_pl_relfl'), RatingEngineV3F5.placementRelFloor);
      expect(sqlNum(c, 'c_relfl'), RatingEngineV3F5.relFloor);
      expect(sqlNum(c, 'c_pl_decay'), RatingEngineV3F5.placementSigmaDecay);
      expect(sqlNum(c, 'c_decay'), RatingEngineV3F5.sigmaDecay);
      expect(sqlNum(c, 'c_sig_min'), RatingEngineV3F5.sigmaMin);
      expect(sqlNum(c, 'c_sig_max'), RatingEngineV3F5.sigmaMax);
      expect(sqlNum(c, 'c_r_min'), RatingEngineV3F5.ratingMin);
      expect(sqlNum(c, 'c_r_max'), RatingEngineV3F5.ratingMax);
      expect(sqlNum(c, 'c_anchor'), RatingEngineV3F5.anchorMaxAbsDelta);
      expect(sqlNum(c, 'c_dp'), RatingEngineV3F5.storedDecimals);
    });

    test('arrays match', () {
      expect(sqlArray(c, 'c_stage_end'),
          RatingEngineV3F5.stageEnds.map((e) => e.toDouble()).toList());
      expect(sqlArray(c, 'c_stage_k'), RatingEngineV3F5.stageK);
      expect(sqlArray(c, 'c_post_end'),
          RatingEngineV3F5.postStageEnds.map((e) => e.toDouble()).toList());
      expect(sqlArray(c, 'c_post_decay'), RatingEngineV3F5.postStageDecay);
    });

    test('the engine version string matches', () {
      expect(c['c_version'], "'$kRatingEngineVersion'");
    });

    test('the margin helper implements the same saturating formula', () {
      final sql = File('supabase/migration_player_app.sql').readAsStringSync();
      final fn = sql.substring(sql.indexOf('function public._v3f5_margin'));
      final body = fn.substring(0, fn.indexOf(r'$$', fn.indexOf(r'$$') + 2));
      // the two constants the formula turns on
      expect(body, contains('0.15'));
      expect(body, contains('0.5'));
      expect(RatingEngineV3F5.marginCap, 0.15);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  // 5. Guards on things this migration must NOT have changed
  // ═══════════════════════════════════════════════════════════════════════
  group('migration guardrails', () {
    final sql = File('supabase/migration_player_app.sql').readAsStringSync();

    test('the v2 engine is still present as the rollback path', () {
      expect(sql, contains('_settle_rating_v2'));
      expect(sql, contains('rating_engine_version()'));
    });

    test('_settle_rating dispatches rather than computing', () {
      final i = sql.lastIndexOf('create or replace function public._settle_rating(p_match_id uuid)');
      expect(i, greaterThan(-1));
      final body = sql.substring(i, i + 1400);
      expect(body, contains('_settle_rating_v3f5'));
      expect(body, contains('_settle_rating_v2'));
      // casual matches must never reach an engine
      expect(body, contains("<> 'ranked'"));
    });

    test('settlement stays idempotent', () {
      final i = sql.indexOf('create or replace function public._settle_rating_v3f5');
      final body = sql.substring(i, sql.indexOf('end \$\$;', i));
      expect(body, contains('if v_applied then return; end if;'));
      expect(body, contains('rating_applied = true'));
    });

    test('the lab inactivity helper was NOT ported', () {
      // The lab's idle() lowers sigma for a high-uncertainty player. Production
      // must never contain that shape: sigma may rise on inactivity, not fall.
      final i = sql.lastIndexOf('function public.apply_rating_decay');
      final body = sql.substring(i, sql.indexOf('end \$\$;', i));
      expect(body, contains('greatest(p.sigma'),
          reason: 'inactivity must be monotone in sigma');
      expect(body.contains('set sigma = least(0.60, sigma + 0.01)'), isFalse,
          reason: 'the sigma-lowering form must be gone');
    });

    test('inactivity NEVER moves a rating — V3-F5 has decay off', () {
      // V3-F5 was selected with ratingInactivityDecay = false. If the sweep
      // subtracts from a rating, production is running V3-F5 during matches
      // and something else between them, which is not V3-F5.
      expect(kV3F5.ratingInactivityDecay, isFalse);

      final i = sql.lastIndexOf('function public.apply_rating_decay');
      final body = sql.substring(i, sql.indexOf('end \$\$;', i));
      // the job may only touch sigma
      expect(body.contains('set rating'), isFalse,
          reason: 'the inactivity sweep must not write a rating');
      expect(body.contains('tier_from_level'), isFalse,
          reason: 'writing a tier implies it moved a rating');
      expect(body.contains('ranking_history'), isFalse,
          reason: 'the sweep has no rating movement to record');
      expect(body.contains('0.04'), isFalse,
          reason: 'the -0.04/week rating decay must be gone');
      expect(body, contains('set sigma'));
    });

    test('only match settlement and explicit admin action move a rating', () {
      // Every function that writes profiles.rating, enumerated.
      //
      // The migration re-defines several functions as it goes (the file is
      // re-run whole, so a later create-or-replace wins), so only the LAST
      // definition of each name is what actually exists in the database —
      // that is what gets scanned. Earlier bodies are dead by construction.
      final lastDef = <String, int>{};
      for (final m in RegExp(r'create or replace function (public\.\w+)')
          .allMatches(sql)) {
        lastDef[m.group(1)!] = m.start;
      }

      final writers = <String>{};
      lastDef.forEach((name, start) {
        if (RegExp(r'update (?:public\.)?profiles\s+set[\s\S]{0,240}?rating\s*=')
            .hasMatch(bodyAt(sql, start))) {
          writers.add(name);
        }
      });

      expect(
          writers,
          {
            'public._settle_rating_v2', // rollback path, deliberately kept
            'public._settle_rating_v3f5', // the engine
            'public.admin_set_player_rating', // explicit admin action
            'public.admin_set_rating', // explicit admin action
          },
          reason: 'unexpected writer of profiles.rating: $writers');
    });

    test('no definition of the inactivity sweep decays a rating, live or dead', () {
      // Stricter than the test above: a superseded copy of the old decaying
      // body left in the file is dead only until someone reorders the file.
      for (final m in RegExp(r'create or replace function public\.apply_rating_decay')
          .allMatches(sql)) {
        final body = bodyAt(sql, m.start);
        expect(body.contains('0.04'), isFalse,
            reason: 'a rating decay survives at offset ${m.start}');
        expect(body.contains('set rating'), isFalse,
            reason: 'a rating write survives at offset ${m.start}');
      }
    });

    test('rating history records the engine that produced each row', () {
      expect(sql, contains('engine_version'));
      expect(sql, contains("c_version, r.cm + 1"));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  // 6. Convergence — the engine still works, at the level the lab reported
  // ═══════════════════════════════════════════════════════════════════════
  test('50-seed convergence: V3-F5 places players near their true skill', () {
    // Deliberately modest: this is a regression guard on the production port,
    // not a re-run of the study. Skill sweep across the ladder, established
    // opponents, MAE measured at 5 / 10 / 20 matches over 50 seeds.
    const skills = [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 5.5, 6.0, 6.5];
    const seeds = 50;
    final errAt = <int, List<double>>{5: [], 10: [], 20: []};

    for (final trueSkill in skills) {
      for (var seed = 0; seed < seeds; seed++) {
        final rng = Rng(1000 + seed);
        var rating = RatingEngineV3F5.prior;
        var sigma = RatingEngineV3F5.sigma0;

        for (var n = 0; n < 20; n++) {
          // an established, correctly-rated opponent pair near the player
          final oppSkill =
              RatingEngineV3F5.clampD(trueSkill + (rng.nextDouble() - 0.5) * 2.0, 0, 7);
          final partnerSkill =
              RatingEngineV3F5.clampD(trueSkill + (rng.nextDouble() - 0.5) * 2.0, 0, 7);

          // 19 games, each an independent Bernoulli on TRUE skill, so result
          // and margin come from the same source
          final q = RatingEngineV3F5.expected(
              (trueSkill + partnerSkill) / 2, oppSkill);
          var ga = 0;
          for (var g = 0; g < 19; g++) {
            if (rng.nextDouble() < q) ga++;
          }
          final gb = 19 - ga;

          final move = RatingEngineV3F5.settleMatch(
            team1: [
              RatedPlayer(id: 'me', rating: rating, sigma: sigma, competitiveMatches: n),
              RatedPlayer(id: 'partner', rating: partnerSkill, sigma: 0.25,
                  competitiveMatches: 50),
            ],
            team2: [
              RatedPlayer(id: 'o1', rating: oppSkill, sigma: 0.25, competitiveMatches: 50),
              RatedPlayer(id: 'o2', rating: oppSkill, sigma: 0.25, competitiveMatches: 50),
            ],
            team1Games: ga,
            team2Games: gb,
            outcome: ga >= 10 ? MatchOutcome.team1Win : MatchOutcome.team2Win,
          ).first;
          rating = move.ratingAfter;
          sigma = move.sigmaAfter;

          if (errAt.containsKey(n + 1)) {
            errAt[n + 1]!.add((rating - trueSkill).abs());
          }
        }
      }
    }

    double mae(List<double> xs) => xs.reduce((a, b) => a + b) / xs.length;
    double within(List<double> xs, double t) =>
        xs.where((e) => e <= t).length / xs.length;

    for (final n in [5, 10, 20]) {
      final e = errAt[n]!;
      // ignore: avoid_print
      print('[v3f5] after $n matches — MAE ${mae(e).toStringAsFixed(3)}  '
          '±0.5 ${(within(e, 0.5) * 100).toStringAsFixed(0)}%  '
          '±1.0 ${(within(e, 1.0) * 100).toStringAsFixed(0)}%  '
          '(n=${e.length})');
    }

    // Placement gets the player into the right region; 20 matches sharpens it.
    expect(mae(errAt[5]!), lessThan(1.2));
    expect(mae(errAt[20]!), lessThan(mae(errAt[5]!)),
        reason: 'the engine must keep improving after the reveal');
    expect(within(errAt[20]!, 1.0), greaterThan(0.60));
    // ...and it must not be silently diverging at the extremes.
    expect(errAt[20]!.reduce(math.max), lessThan(4.0));
  });
}

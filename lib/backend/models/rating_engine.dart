/// Playtomic-style rating math — pure, deterministic, NO I/O.
///
/// This is the **reference / test mirror**. The authoritative runtime copy of
/// this exact algorithm lives in the Postgres `_settle_rating` function
/// (rating writes only happen server-side, per the anti-cheat boundary). The
/// two MUST be kept identical — same discipline as `level_from_elo` ↔
/// `RankingScale.levelFromElo`. `test/rating_engine_test.dart` pins golden
/// vectors both implementations must satisfy.
///
/// Rating scale is 0.00–7.00. Core = Elo, with a Glicko-style uncertainty
/// (`sigma`) driving the K-factor and an opponent-reliability discount, plus
/// margin-of-victory weighting and doubles team averaging.
library;

import 'dart:math' as math;

/// A player's rating state going into a match.
class RatedPlayer {
  final String id;
  final double rating; // 0..7
  final double sigma; // 0.12..1.0 (uncertainty)
  final int competitiveMatches; // completed competitive matches
  final bool isAnchor; // hand-calibrated seed player

  const RatedPlayer({
    required this.id,
    required this.rating,
    required this.sigma,
    this.competitiveMatches = 0,
    this.isAnchor = false,
  });
}

/// The result of a match from team 1's perspective.
enum MatchOutcome { team1Win, team2Win, draw }

/// One player's rating movement after a settled match.
class RatingChange {
  final String id;
  final double ratingBefore;
  final double ratingAfter;
  final double sigmaBefore;
  final double sigmaAfter;

  const RatingChange({
    required this.id,
    required this.ratingBefore,
    required this.ratingAfter,
    required this.sigmaBefore,
    required this.sigmaAfter,
  });

  /// Net applied level change (post clamp) — what `rating_history.delta` stores.
  double get delta => ratingAfter - ratingBefore;
}

/// Pure rating math. Every method is a deterministic function of its inputs.
class RatingEngine {
  RatingEngine._();

  // ── Constants (spec) ─────────────────────────────────────────────
  static const double s = 1.0; // logistic scale on the 0..7 rating
  static const double kMax = 0.35;
  static const double kMin = 0.04;
  static const double sigmaMax = 1.0;
  static const double sigmaMin = 0.12;
  static const double sigmaDecayPerMatch = 0.92;
  static const double sigmaGrowthPerIdleWeek = 0.01;
  static const double sigmaIdleCap = 0.60;
  static const double placementBoost = 1.5;
  static const int placementMatches = 5; // boost applies to a player's first 5
  static const double ratingMin = 0.0;
  static const double ratingMax = 7.0;
  static const double anchorMaxAbsDelta = 0.05;

  static double clampD(double v, double lo, double hi) =>
      v < lo ? lo : (v > hi ? hi : v);

  /// Expected score for a team rated [rTeam] against an opponent rated [rOpp].
  ///   E = 1 / (1 + 10^((R_opp − R_team) / s))
  static double expected(double rTeam, double rOpp) =>
      1.0 / (1.0 + math.pow(10.0, (rOpp - rTeam) / s));

  /// Combined score signal: 70% result, 30% games ratio (margin of victory).
  ///   S = 0.7*result + 0.3*(gamesWon / (gamesWon + gamesLost))
  /// [result] is 1 win / 0.5 draw / 0 loss for this team.
  static double scoreSignal(double result, int gamesWon, int gamesLost) {
    final total = gamesWon + gamesLost;
    final ratio = total == 0 ? 0.5 : gamesWon / total;
    return 0.7 * result + 0.3 * ratio;
  }

  /// Per-player K-factor: scales with the player's own uncertainty, boosted
  /// 1.5× during their first [placementMatches] competitive matches.
  static double kFactor(double sigma, int competitiveMatches) {
    var k = kMin + (kMax - kMin) * (sigma / sigmaMax);
    if (competitiveMatches < placementMatches) k *= placementBoost;
    return k;
  }

  /// Opponent-reliability weight in [0.5, 1.0]: discounts matches against
  /// unreliable (high-sigma) opponents.
  ///   W_opp = 0.5 + 0.5 * mean(1 − sigma_opp / sigma_max)
  static double wOpp(List<double> opponentSigmas) {
    if (opponentSigmas.isEmpty) return 1.0;
    final mean = opponentSigmas
            .map((sg) => 1.0 - sg / sigmaMax)
            .reduce((a, b) => a + b) /
        opponentSigmas.length;
    return 0.5 + 0.5 * mean;
  }

  /// Uncertainty shrinks each match played.
  static double decaySigma(double sigma) =>
      math.max(sigmaMin, sigma * sigmaDecayPerMatch);

  /// Uncertainty grows with inactivity (weekly job), capped at 0.60.
  static double growSigmaIdle(double sigma, int idleWeeks) {
    if (idleWeeks <= 0) return sigma;
    return math.min(sigmaIdleCap, sigma + sigmaGrowthPerIdleWeek * idleWeeks);
  }

  /// Backfill sigma for an existing player from their competitive match count:
  ///   sigma = max(0.12, 1.0 * 0.92^n)
  static double backfillSigma(int competitiveMatches) => math.max(
      sigmaMin, sigmaMax * math.pow(sigmaDecayPerMatch, competitiveMatches));

  /// Settle one competitive match. Each team has 1–2 players (doubles);
  /// [team1Games]/[team2Games] are total games won across all sets.
  ///
  /// Returns a [RatingChange] per player (order: team1 then team2). This is the
  /// canonical algorithm the SQL `_settle_rating` mirrors exactly.
  static List<RatingChange> settleMatch({
    required List<RatedPlayer> team1,
    required List<RatedPlayer> team2,
    required int team1Games,
    required int team2Games,
    required MatchOutcome outcome,
  }) {
    assert(team1.isNotEmpty && team2.isNotEmpty);

    final r1 = _mean(team1.map((p) => p.rating));
    final r2 = _mean(team2.map((p) => p.rating));
    final e1 = expected(r1, r2);
    final e2 = expected(r2, r1); // == 1 - e1

    final result1 = switch (outcome) {
      MatchOutcome.team1Win => 1.0,
      MatchOutcome.team2Win => 0.0,
      MatchOutcome.draw => 0.5,
    };
    final result2 = 1.0 - result1;

    final s1 = scoreSignal(result1, team1Games, team2Games);
    final s2 = scoreSignal(result2, team2Games, team1Games);

    return [
      ..._applyTeam(team: team1, opponents: team2, sTeam: s1, eTeam: e1),
      ..._applyTeam(team: team2, opponents: team1, sTeam: s2, eTeam: e2),
    ];
  }

  static List<RatingChange> _applyTeam({
    required List<RatedPlayer> team,
    required List<RatedPlayer> opponents,
    required double sTeam,
    required double eTeam,
  }) {
    final w = wOpp(opponents.map((p) => p.sigma).toList());
    return [
      for (final p in team) _applyPlayer(p, sTeam, eTeam, w),
    ];
  }

  static RatingChange _applyPlayer(
      RatedPlayer p, double sTeam, double eTeam, double w) {
    final k = kFactor(p.sigma, p.competitiveMatches);
    var delta = k * w * (sTeam - eTeam);
    if (p.isAnchor) delta = clampD(delta, -anchorMaxAbsDelta, anchorMaxAbsDelta);
    final after = clampD(p.rating + delta, ratingMin, ratingMax);
    return RatingChange(
      id: p.id,
      ratingBefore: p.rating,
      ratingAfter: after,
      sigmaBefore: p.sigma,
      sigmaAfter: decaySigma(p.sigma),
    );
  }

  static double _mean(Iterable<double> xs) {
    var sum = 0.0;
    var n = 0;
    for (final x in xs) {
      sum += x;
      n++;
    }
    return n == 0 ? 0.0 : sum / n;
  }
}

/// Parses a team-A-perspective set-score string like `'6-4,3-6,7-6'` into
/// total games won by each team. A championship / super tie-break set (any
/// side ≥ 10, e.g. `'10-8'`) counts as a single game to its winner rather than
/// ten games, so a match tie-break doesn't dwarf the games ratio.
///
/// Mirrors the SQL parser used by `_settle_rating`.
({int team1, int team2}) parseSetGames(String? scoreTeamA) {
  if (scoreTeamA == null || scoreTeamA.trim().isEmpty) {
    return (team1: 0, team2: 0);
  }
  var t1 = 0, t2 = 0;
  for (final rawSet in scoreTeamA.split(',')) {
    final parts = rawSet.trim().split('-');
    if (parts.length != 2) continue;
    final a = int.tryParse(parts[0].trim());
    final b = int.tryParse(parts[1].trim());
    if (a == null || b == null) continue;
    if (a >= 10 || b >= 10) {
      // Match tie-break set → 1 game to the winner.
      if (a > b) {
        t1 += 1;
      } else if (b > a) {
        t2 += 1;
      }
    } else {
      t1 += a;
      t2 += b;
    }
  }
  return (team1: t1, team2: t2);
}

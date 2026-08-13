/// **V3-F5 Hybrid** — the production rating engine (2026-08-13).
///
/// This is the **reference / test mirror**. The authoritative runtime copy is
/// the Postgres `_settle_rating_v3f5` function; rating writes only ever happen
/// server-side (the anti-cheat boundary). The two MUST stay identical —
/// `test/rating_engine_v3f5_test.dart` pins golden vectors both must satisfy,
/// and `test/rating_engine_v3f5_parity_test.dart` pins this file against the
/// Ranking Lab implementation it was ported from.
///
/// **Provenance.** Every constant below was read out of the executable Ranking
/// Lab config, not written from a description: `tools/ranking_simulation/`
/// `engines.dart`, `final kV3F5 = kV3F.copyWith(...)`, resolved through the
/// `kV3Config → kV3E → kV3F → kV3F5` `copyWith` chain and executed by
/// `HybridEngine.update`. There is no V3-F5 class in the lab — it is data fed
/// to a shared engine, which is why this port is a transcription of
/// `HybridEngine.update` **with that config bound**, and nothing else. The
/// dormant lab features that config leaves off (adaptive sigma, diversity
/// sigma, the imbalance lambda, the declared-level prior, the reliability ramp,
/// rating inactivity decay) are deliberately **not ported at all** rather than
/// ported and disabled, so there is nothing here to switch on by accident.
///
/// **This is the only rating engine.** Rating engine v2 was removed on
/// 2026-08-13, along with its SQL rollback path and its Dart reference — there
/// is no second engine to fall back to, and `_settle_rating` no longer
/// dispatches. `ranking_history` rows with `engine_version IS NULL` were
/// settled by v2 and are kept; the maths that produced them is frozen in
/// `test/ranking_lab_test.dart`, where it still pins the Ranking Lab's
/// baseline.
///
/// ## What the engine does, per player, per match
///
/// ```text
/// T      = (R₁ + R₂) / 2                        pure average, λ = 0
/// E_T    = 1 / (1 + 10^((T_O − T_T) / 1.0))     E_O = 1 − E_T
/// ρ      = gamesFor / (gamesFor + gamesAgainst) 0.5 when no games recorded
/// ρ'     = 0.5 + clamp(ρ − 0.5, ±0.15) / 0.15 × 0.5
/// S      = 0.85·result + 0.15·ρ'
/// W      = max(0.5 + 0.5·(1 − σ̄_opp), floor)   floor 1.00 if n < 5 else 0.65
/// K      = stageK[j] × clamp(σ / 0.95, 0.35, 1.0)   if n < 5
///        = 0.04 + 0.31·σ                            if n ≥ 5
/// Δ      = K · W · (S − E_T)                    clamped ±0.05 for anchors only
/// R'     = clamp(R + Δ, 0.0, 7.0)               no rounding in the math
/// σ'     = clamp(σ · d, 0.12, 1.0)
/// n'     = n + 1
/// ```
///
/// `n` is the player's **completed** competitive matches, read *before* this
/// match is counted. Every band below is therefore a band on matches already
/// played, which is what makes the 5/6 and 10/11 and 20/21 boundaries land
/// where the lab puts them.
///
/// ## Known V3-F5 behaviours — deliberate, tested, and NOT to be "fixed" here
///
/// * **A winner can lose a little rating.** At E ≈ 0.99 a 6-4 6-4 win gives
///   S < E and hence Δ < 0. This falls out of the margin term and is pinned by
///   a regression test. Do not add `if (won) delta = max(delta, 0)`.
/// * **Sigma ignores evidence.** Decay is a pure function of match count, so a
///   player who keeps being wrong still gets more confident, and K shrinks with
///   σ. This is the "confidently wrong" weakness; V3-F5 delays it, never fixes
///   it. The lab's surprise-aware sigma exists and is off.
/// * **6-2 6-2 == 6-0 6-0.** The margin saturates at a 0.65 games ratio, which
///   is what removes the incentive to run up a scoreline.
/// * **The K cliff at match 5 → 6** (0.62 → 0.29) is characteristic, not a bug.
/// * **Not zero-sum**, and **5.0 + 2.0 == 3.5 + 3.5** as team strengths.
///
/// Each of those is a candidate for a future V3-F5.1 studied in the lab first.
/// None of them is a licence to change this file.
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
///
/// Padel has no draws — `winner_team` is always 'a' or 'b' — but [draw] is
/// kept because the engine handles a 0.5 result coherently and refusing it
/// would be an invented restriction. It is outside the lab's tested domain.
enum MatchOutcome { team1Win, team2Win, draw }

/// Parses a team-A-perspective set-score string like `'6-4,3-6,7-6'` into
/// total games won by each team. A championship / super tie-break set (any
/// side ≥ 10, e.g. `'10-8'`) counts as a single game to its winner rather than
/// ten games, so a match tie-break doesn't dwarf the games ratio.
///
/// Mirrors the SQL `_parse_set_games` used by `_settle_rating`, and agrees
/// with the Ranking Lab's `parseScore` on the games count. (The lab's parser
/// additionally rejects malformed input; this one skips it. That is an
/// input-validation difference, not a scoring one.)
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

/// The identifier production stamps on everything this engine settles.
///
/// Written to `ranking_history.engine_version` by `_settle_rating_v3f5`. Legacy
/// rows settled by rating engine v2 carry NULL, which is how the two eras stay
/// distinguishable. V3-F is a *different* engine — this is `v3_f5`.
const String kRatingEngineVersion = 'v3_f5';

/// One player's movement, with the arithmetic that produced it.
///
/// The intermediate terms are carried because the SQL ↔ Dart ↔ simulator parity
/// fixtures compare them individually — a delta that agrees for the wrong
/// reason is not parity.
class RatingMove {
  final String id;

  final double ratingBefore, ratingAfter;
  final double sigmaBefore, sigmaAfter;

  /// Completed competitive matches before this one; `matchNumber` is this
  /// match's 1-based ordinal for the player (what rating history records).
  final int matchesBefore;

  /// Pre-match team strengths that produced [expected].
  final double teamStrength, oppStrength;

  final double expected, signal, w, k;

  /// Δ before the 0–7 clamp — [ratingAfter] − [ratingBefore] can be smaller.
  final double rawDelta;

  final bool inPlacement, anchorClamped;

  const RatingMove({
    required this.id,
    required this.ratingBefore,
    required this.ratingAfter,
    required this.sigmaBefore,
    required this.sigmaAfter,
    required this.matchesBefore,
    required this.teamStrength,
    required this.oppStrength,
    required this.expected,
    required this.signal,
    required this.w,
    required this.k,
    required this.rawDelta,
    required this.inPlacement,
    required this.anchorClamped,
  });

  /// Net applied change after the clamp — what `ranking_history.delta` stores.
  double get delta => ratingAfter - ratingBefore;

  int get matchNumber => matchesBefore + 1;

  /// Whether this settlement is the one that reveals the player's rating.
  bool get revealsRating =>
      inPlacement && matchNumber >= RatingEngineV3F5.placementMatches;
}

/// Pure V3-F5 math. Every method is a deterministic function of its inputs and
/// does no I/O — the server is what actually writes a rating.
class RatingEngineV3F5 {
  RatingEngineV3F5._();

  // ── Prior ────────────────────────────────────────────────────────────
  /// Hidden starting estimate for a player with no competitive matches.
  ///
  /// **Hidden** is the operative word: it seeds the math from the first match,
  /// but nothing may show it as the player's rating until placement completes.
  /// A brand-new profile stores `rating = NULL`; this value is what settlement
  /// coalesces that NULL to.
  static const double prior = 3.30;

  /// Starting uncertainty. The onboarding self-declaration deliberately does
  /// NOT move either of these (`useDeclaredPrior = false` in the lab config).
  static const double sigma0 = 0.95;

  // ── Placement ────────────────────────────────────────────────────────
  /// Competitive matches of public placement. After the 5th settles the rating
  /// becomes public. This is the ONE authoritative placement count.
  static const int placementMatches = 5;

  /// Exclusive upper bounds, in matches already played, of the three placement
  /// K stages: exploration (1-2), calibration (3-4), validation (5).
  ///
  /// "Validation" is a stage name, not a statistical test — nothing is verified
  /// at match 5. K is 0.70 and then the rating goes public.
  static const List<int> stageEnds = [2, 4, 5];
  static const List<double> stageK = [1.15, 0.90, 0.70];

  /// Placement K is scaled inside its stage by remaining uncertainty, so the
  /// stage value is a ceiling rather than a fixed step.
  static const double stageSigmaFloor = 0.35;
  static const double stageSigmaCeil = 1.0;

  // ── Post-placement K ─────────────────────────────────────────────────
  /// From match 6 on, K is the plain sigma-driven formula `0.04 + 0.31·σ`.
  /// There is deliberately **no** elevated early-career K stage — the drop from
  /// 0.62 at match 5 to 0.29 at match 6 is what V3-F5 was measured with.
  static const double kMin = 0.04;
  static const double kMax = 0.35;

  // ── Opponent reliability ─────────────────────────────────────────────
  /// While a player is in placement no opponent is discounted at all: W is
  /// pinned to exactly 1.00. Discounting opponents at launch, when nobody is
  /// established, inverts — it suppresses precisely the evidence placement
  /// needs.
  static const double placementRelFloor = 1.00;

  /// Once established, W floors at 0.65 (raised from v2's 0.50).
  static const double relFloor = 0.65;

  // ── Sigma ────────────────────────────────────────────────────────────
  static const double sigmaMin = 0.12;
  static const double sigmaMax = 1.0;

  /// Deterministic decay bands, keyed on matches already played:
  /// `n < 5` placement · `5 ≤ n < 10` · `10 ≤ n < 20` · `n ≥ 20` established.
  ///
  /// The bands approach the established rate from **above** and never dip below
  /// it, which is what keeps correction power alive after the rating goes
  /// public (K is sigma-driven, so holding σ up holds K up).
  static const double placementSigmaDecay = 0.970;
  static const List<int> postStageEnds = [10, 20];
  static const List<double> postStageDecay = [0.980, 0.975];
  static const double sigmaDecay = 0.970;

  // ── Range / anchors ──────────────────────────────────────────────────
  static const double ratingMin = 0.0;
  static const double ratingMax = 7.0;

  /// Anchors are a SOFT pin — a hand-calibrated player still moves, by at most
  /// this much per match, and their sigma still decays normally.
  static const double anchorMaxAbsDelta = 0.05;

  // ── Score signal ─────────────────────────────────────────────────────
  /// The result carries 0.85 of the signal; the games margin carries 0.15, and
  /// saturates beyond a ±0.15 deviation from an even games split.
  static const double resultWeight = 0.85;
  static const double marginCap = 0.15;

  /// Logistic scale on the 0–7 rating.
  static const double curveScale = 1.0;

  /// Decimal places production persists a rating at.
  ///
  /// The engine itself does **no** rounding — this is the storage grain, chosen
  /// so quantisation (5e-7 per match) stays far below anything observable, and
  /// far below the 0.25 display step. Display rounding never re-enters the
  /// math: [storedRating] is what the database keeps, `RankingScale.fmtQuarter`
  /// is what a player sees, and the two are not the same number.
  static const int storedDecimals = 6;
  static const int storedSigmaDecimals = 6;

  static double clampD(double v, double lo, double hi) =>
      v < lo ? lo : (v > hi ? hi : v);

  static double _round(double v, int decimals) {
    final f = math.pow(10, decimals).toDouble();
    return (v * f).round() / f;
  }

  /// Quantises a rating to what `profiles.rating numeric(9,6)` will hold.
  static double storedRating(double v) => _round(v, storedDecimals);

  /// Quantises a sigma to what settlement writes.
  static double storedSigma(double v) => _round(v, storedSigmaDecimals);

  // ── Model ────────────────────────────────────────────────────────────

  /// Doubles team strength: the **pure arithmetic average**.
  ///
  /// The imbalance lambda is 0 and stays 0 until it can be fitted on real
  /// anonymised match history. A consequence, known and accepted: 5.0 + 2.0 and
  /// 3.5 + 3.5 are the same team to this engine. Do not substitute a
  /// teammate-gap limit for a fitted lambda — the lab showed gap limits do not
  /// stop boosting, because the gap closes as the carried player rises.
  static double teamStrength(Iterable<double> ratings) {
    var sum = 0.0;
    var n = 0;
    for (final r in ratings) {
      sum += r;
      n++;
    }
    return n == 0 ? prior : sum / n;
  }

  /// Expected score for a team of strength [rTeam] against [rOpp].
  ///   `E = 1 / (1 + 10^((R_opp − R_team) / s))`, s = 1.0.
  /// Symmetric by construction: `E(a,b) + E(b,a) == 1`.
  static double expected(double rTeam, double rOpp) =>
      1.0 / (1.0 + math.pow(10.0, (rOpp - rTeam) / curveScale));

  /// The games ratio after saturation — the margin's whole contribution.
  ///
  /// Beyond a ±[marginCap] deviation from an even split every scoreline counts
  /// the same, so 6-2 6-2 and 6-0 6-0 are worth an identical amount.
  static double marginRatio(int gamesWon, int gamesLost) {
    final total = gamesWon + gamesLost;
    final ratio = total == 0 ? 0.5 : gamesWon / total;
    final dev = clampD(ratio - 0.5, -marginCap, marginCap);
    return 0.5 + (dev / marginCap) * 0.5;
  }

  /// `S = 0.85·result + 0.15·ρ'`. [result] is 1 win / 0.5 draw / 0 loss.
  ///
  /// Note this replaces v2's raw `0.7·result + 0.3·gamesRatio` entirely; the
  /// uncapped ratio is gone, not merely reweighted.
  static double scoreSignal(double result, int gamesWon, int gamesLost) =>
      resultWeight * result +
      (1 - resultWeight) * marginRatio(gamesWon, gamesLost);

  /// Whether a player with [competitiveMatches] completed is still in
  /// placement — i.e. whether THIS match is one of their first five.
  static bool inPlacement(int competitiveMatches) =>
      competitiveMatches < placementMatches;

  /// Whether a player's rating is public. Match count alone, by design: the
  /// player becomes ranked while sigma is still ~0.82, so the rating is public
  /// AND openly low-confidence. Gating on sigma too would mean either never
  /// revealing at 5, or misstating certainty.
  static bool isRevealed(int competitiveMatches) =>
      competitiveMatches >= placementMatches;

  // ── Confidence gate (NOT the placement gate) ─────────────────────────
  //
  // "Placement is complete" and "the engine is confident" are different
  // claims, and V3-F5 pulls them further apart than v2 did — the reveal now
  // happens at match 5 with sigma still ~0.82. `is_provisional` is the
  // confidence flag and must not be read as evidence the rating is settled;
  // [isRevealed] is the placement flag.
  //
  // Both constants below are *derived from the decay curve above*, not chosen.
  // v2 paired `sigma > 0.40` with `matches < 10` because 0.85·0.92ⁿ crosses
  // 0.40 at exactly n = 10, so the two clauses agreed. The same construction on
  // the V3-F5 curve lands on the end of the last post-placement sigma band:
  // sigma is 0.5871 after 19 matches and 0.5725 after 20, so a 0.58 threshold
  // flips at precisely the point `postStageEnds` calls established.

  /// Matches after which V3-F5 itself stops treating a player as still
  /// calibrating — the end of the last post-placement sigma band.
  static const int establishedMatches = 20;

  /// Sigma above which a rating is flagged provisional. Sits between
  /// `sigmaAfter(19)` and `sigmaAfter(20)` so it agrees with
  /// [establishedMatches] for anyone whose sigma came from match play, while
  /// still letting a hand-set low sigma (an anchor, a leveling session) mean
  /// what it says.
  static const double provisionalMaxSigma = 0.58;

  /// Mirrors the `profiles.is_provisional` generated column.
  static bool isProvisional(double sigma, int competitiveMatches) =>
      sigma > provisionalMaxSigma || competitiveMatches < establishedMatches;

  /// Opponent-reliability weight for a player, given the opposing team's mean
  /// sigma. The floor depends on the **player's own** match count, not the
  /// opponents' — a player in placement gets W = 1.00 against anybody.
  static double wOpp(double oppMeanSigma, int competitiveMatches) {
    final raw = 0.5 + 0.5 * (1 - oppMeanSigma);
    final floor =
        inPlacement(competitiveMatches) ? placementRelFloor : relFloor;
    return math.max(raw, floor);
  }

  /// Index of the placement stage a player with [competitiveMatches] is in.
  /// Returns the last stage if called outside placement, which cannot happen
  /// via [kFactor] but keeps the function total.
  static int stageIndex(int competitiveMatches) {
    for (var i = 0; i < stageEnds.length; i++) {
      if (competitiveMatches < stageEnds[i]) return i;
    }
    return stageEnds.length - 1;
  }

  /// Per-player K.
  ///
  /// In placement: the stage ceiling scaled by remaining uncertainty. After it:
  /// `0.04 + 0.31·σ` — the same formula an established player has always used.
  /// There is no intermediate schedule for matches 6-10.
  static double kFactor(double sigma, int competitiveMatches) {
    if (inPlacement(competitiveMatches)) {
      final ceiling = stageK[stageIndex(competitiveMatches)];
      return ceiling *
          clampD(sigma / sigma0, stageSigmaFloor, stageSigmaCeil);
    }
    return kMin + (kMax - kMin) * sigma;
  }

  /// The deterministic decay multiplier for a player's next match.
  ///
  /// A pure function of match count — no result, no surprise, no diversity
  /// term. That is the tested behaviour and the known weakness both.
  static double sigmaDecayFor(int competitiveMatches) {
    if (inPlacement(competitiveMatches)) return placementSigmaDecay;
    for (var i = 0; i < postStageEnds.length; i++) {
      if (competitiveMatches < postStageEnds[i]) return postStageDecay[i];
    }
    return sigmaDecay;
  }

  static double decaySigma(double sigma, int competitiveMatches) => clampD(
      sigma * sigmaDecayFor(competitiveMatches), sigmaMin, sigmaMax);

  /// Sigma a player would hold after [competitiveMatches] matches starting from
  /// [sigma0]. Only used to explain/verify the curve — settlement always decays
  /// the stored value rather than recomputing it.
  static double sigmaAfter(int competitiveMatches) {
    var s = sigma0;
    for (var n = 0; n < competitiveMatches; n++) {
      s = decaySigma(s, n);
    }
    return s;
  }

  // ── Settlement ───────────────────────────────────────────────────────

  /// Settles one competitive match. Each team has 1-2 players;
  /// [team1Games]/[team2Games] are total games across all sets, already parsed
  /// (see `parseSetGames`, which counts a championship tie-break as one game).
  ///
  /// Returns one [RatingMove] per player, team 1 first. Values are returned
  /// **unrounded**; [storedRating] / [storedSigma] describe what persistence
  /// quantises them to. Casual matches must never be passed here.
  static List<RatingMove> settleMatch({
    required List<RatedPlayer> team1,
    required List<RatedPlayer> team2,
    required int team1Games,
    required int team2Games,
    required MatchOutcome outcome,
  }) {
    assert(team1.isNotEmpty && team2.isNotEmpty);

    final r1 = teamStrength(team1.map((p) => p.rating));
    final r2 = teamStrength(team2.map((p) => p.rating));

    // E_opponent is 1 − E_team, not an independently evaluated logistic. They
    // agree analytically; taking the complement is what the lab does and keeps
    // the pair summing to exactly 1 in floating point.
    final e1 = expected(r1, r2);
    final e2 = 1.0 - e1;

    final sig1 = _mean(team1.map((p) => p.sigma));
    final sig2 = _mean(team2.map((p) => p.sigma));

    final result1 = switch (outcome) {
      MatchOutcome.team1Win => 1.0,
      MatchOutcome.team2Win => 0.0,
      MatchOutcome.draw => 0.5,
    };
    final result2 = 1.0 - result1;

    final s1 = scoreSignal(result1, team1Games, team2Games);
    final s2 = scoreSignal(result2, team2Games, team1Games);

    return [
      for (final p in team1) _apply(p, s1, e1, sig2, r1, r2),
      for (final p in team2) _apply(p, s2, e2, sig1, r2, r1),
    ];
  }

  static RatingMove _apply(RatedPlayer p, double s, double e,
      double oppMeanSigma, double teamR, double oppR) {
    final placement = inPlacement(p.competitiveMatches);
    final w = wOpp(oppMeanSigma, p.competitiveMatches);
    final k = kFactor(p.sigma, p.competitiveMatches);

    final raw = k * w * (s - e);
    final clamped =
        p.isAnchor ? clampD(raw, -anchorMaxAbsDelta, anchorMaxAbsDelta) : raw;

    return RatingMove(
      id: p.id,
      ratingBefore: p.rating,
      ratingAfter: clampD(p.rating + clamped, ratingMin, ratingMax),
      sigmaBefore: p.sigma,
      sigmaAfter: decaySigma(p.sigma, p.competitiveMatches),
      matchesBefore: p.competitiveMatches,
      teamStrength: teamR,
      oppStrength: oppR,
      expected: e,
      signal: s,
      w: w,
      k: k,
      rawDelta: clamped,
      inPlacement: placement,
      anchorClamped: p.isAnchor && raw != clamped,
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

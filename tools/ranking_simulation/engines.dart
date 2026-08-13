// ignore_for_file: avoid_print
/// Rating engines under test. All isolated from production — ENGINE A is a
/// read-only mirror of the live `_settle_rating` / `RatingEngine` maths and is
/// never modified; the others are experimental variants.
library;

import 'dart:math' as math;

import 'sim.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Common interface — every engine consumes the identical match stream.
// ─────────────────────────────────────────────────────────────────────────────
abstract class RankingEngine {
  String get name;

  /// Set to an empty list to make [update] record why each rating moved. Purely
  /// observational — an engine computes the identical numbers whether or not
  /// anyone is watching, which the golden-vector tests assert. Left null in the
  /// batch experiments so a 50,000-match run allocates nothing.
  List<MoveTrace>? trace;

  void register(int id, {SelfDeclared declared = SelfDeclared.unknown});

  /// Internal point estimate on the 0–7 skill scale (what metrics score).
  double estimate(int id);

  /// What a user would actually see (clamped 0–7, quarter-rounded).
  double publicRating(int id) => (clampD(estimate(id), 0, 7) * 4).round() / 4;

  double sigmaOf(int id);
  int matchesOf(int id);

  /// Whether the rating is confident enough to show instead of "UNRANKED".
  bool displayReady(int id);

  /// Length of a real placement phase, or **0 for engines that have none**.
  ///
  /// Production has no placement phase. It has a K boost over a player's first
  /// five matches and a separate display gate — two different mechanisms that
  /// are easy to mistake for one. Only the configurable hybrid has a phase in
  /// the sense of "a stretch with its own rules that ends".
  int get placementLength => 0;

  /// What [displayReady] requires, as (matches, maxSigma, minPartners), so the
  /// lab can state the rule instead of implying one. `ranking_lab_test.dart`
  /// asserts this agrees with [displayReady] — they must never drift apart.
  (int, double, int) get displayGate;

  /// P(team A wins) under this engine's own model — for calibration scoring.
  double predictA(MatchObs m);

  void update(MatchObs m);

  /// Inactivity handling for the decay experiment.
  void idle(int id, int weeks) {}

  /// Force a starting estimate WITHOUT marking the player as an anchor — used
  /// by the smurf / overrated-beginner scenarios so every engine starts those
  /// players from the same place.
  void seed(int id, double rating, double sigma);

  /// Sets the match counter alone, leaving rating and sigma untouched. Lets the
  /// lab build "a player 40 matches in" without inventing 40 matches whose
  /// results would move them somewhere else. The counter is what gates the
  /// placement phase, so this is the difference between provisional and
  /// established.
  void primeMatches(int id, int n) {}

  /// Hand-calibrated reference player (rating pinned AND movement capped).
  void markAnchor(int id, double rating, double sigma) {}
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared per-player state (rating/sigma engines).
// ─────────────────────────────────────────────────────────────────────────────
/// One player's move in one match, with the arithmetic that produced it — this
/// is what the lab's step-by-step explanation renders. Fields an engine has no
/// analogue for (a TrueSkill update has no K or W) stay null rather than being
/// filled with a plausible-looking number.
class MoveTrace {
  final int id;
  final double before, after, delta;
  final double sigmaBefore, sigmaAfter;
  final int matchesBefore;
  final bool inPlacement, won;

  /// What the engine thought the two pairs were worth, and hence P(win).
  final double teamRating, oppRating, expected;

  /// The score signal S actually fed to the update, split into the part that
  /// came from winning and the part that came from the games margin.
  final double? signal, resultPart, marginPart;

  /// Δ = k·w·(S − E). [marginEffect] is how much of [delta] the margin term is
  /// responsible for: delta − (what delta would have been on the result alone).
  final double? k, w, marginEffect;

  final String? note;

  const MoveTrace({
    required this.id,
    required this.before,
    required this.after,
    required this.delta,
    required this.sigmaBefore,
    required this.sigmaAfter,
    required this.matchesBefore,
    required this.inPlacement,
    required this.won,
    required this.teamRating,
    required this.oppRating,
    required this.expected,
    this.signal,
    this.resultPart,
    this.marginPart,
    this.k,
    this.w,
    this.marginEffect,
    this.note,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'before': before,
        'after': after,
        'delta': delta,
        'sigmaBefore': sigmaBefore,
        'sigmaAfter': sigmaAfter,
        'matchesBefore': matchesBefore,
        'inPlacement': inPlacement,
        'won': won,
        'teamRating': teamRating,
        'oppRating': oppRating,
        'expected': expected,
        if (signal != null) 'signal': signal,
        if (resultPart != null) 'resultPart': resultPart,
        if (marginPart != null) 'marginPart': marginPart,
        if (k != null) 'k': k,
        if (w != null) 'w': w,
        if (marginEffect != null) 'marginEffect': marginEffect,
        if (note != null) 'note': note,
      };
}

class PState {
  double rating;
  double sigma;
  int matches = 0;
  bool anchor = false;

  /// Diversity bookkeeping for the information-based sigma experiment.
  final Set<int> partners = <int>{};
  final Set<int> opponents = <int>{};

  /// EMA of |S − E| — "how often is this player surprising us".
  double surpriseEma = 0.0;

  PState(this.rating, this.sigma);
}

double _logistic(double diff, double scale) =>
    1.0 / (1.0 + math.pow(10.0, -diff / scale));

/// 70/30-style score signal with an optional saturating margin term.
double _signal(double result, int gamesFor, int gamesAgainst,
    {required double resultWeight, double marginCap = 0.5}) {
  final total = gamesFor + gamesAgainst;
  var ratio = total == 0 ? 0.5 : gamesFor / total;
  if (marginCap < 0.5) {
    // Saturate: anything beyond ±cap around 0.5 counts the same, so a 6-0 6-0
    // and a 6-1 6-1 carry equal weight and there is no incentive to run it up.
    final dev = clampD(ratio - 0.5, -marginCap, marginCap);
    ratio = 0.5 + (dev / marginCap) * 0.5;
  }
  return resultWeight * result + (1 - resultWeight) * ratio;
}

// ═════════════════════════════════════════════════════════════════════════════
// ENGINE A — CURRENT PRODUCTION (baseline, unmodified)
//
// Exact mirror of supabase `_settle_rating` + lib/backend/models/rating_engine.
//   K   = 0.04 + 0.31·σ, ×1.5 while competitive_matches < 5
//   W   = 0.5 + 0.5·(1 − σ̄_opponents)
//   S   = 0.7·result + 0.3·gamesRatio
//   E   = 1/(1+10^((R_opp − R_team)/1.0))          (team = plain average)
//   Δ   = K·W·(S − E),  rating clamped 0–7, rounded 2dp
//   σ  ← max(0.12, σ·0.92)
// ═════════════════════════════════════════════════════════════════════════════
class CurrentEngine implements RankingEngine {
  @override
  String get name => isProductionExact
      ? 'A · Current (production)'
      : 'A · Current (adapted: prior $startPrior, boost $boostWindow, '
          'provisional at $provisionalAt)';

  @override
  List<MoveTrace>? trace;

  final Map<int, PState> _p = {};

  /// Production coalesces a NULL rating to 2.0 and defaults sigma to 0.85.
  static const double prior = 2.0;
  static const double sigma0 = 0.85;

  /// `RatingEngine.placementMatches` — K is boosted ×1.5 over a player's first
  /// five matches.
  static const int boostWindowDefault = 5;

  /// `profiles.is_provisional` — a rating stays provisional below ten matches.
  static const int provisionalAtDefault = 10;

  /// All three are overridable ONLY so an experiment can isolate one variable,
  /// and so the lab can hold "matches before the engine commits" equal across
  /// engines that are otherwise not comparable. **The defaults are production's
  /// and the golden vectors pin them**; leave them alone and this class is a
  /// byte-for-byte mirror of the live engine.
  final double startPrior;
  final int boostWindow;
  final int provisionalAt;

  CurrentEngine({
    this.startPrior = prior,
    this.boostWindow = boostWindowDefault,
    this.provisionalAt = provisionalAtDefault,
  });

  /// True when nothing has been overridden — i.e. this really is production.
  bool get isProductionExact =>
      startPrior == prior &&
      boostWindow == boostWindowDefault &&
      provisionalAt == provisionalAtDefault;

  @override
  void register(int id, {SelfDeclared declared = SelfDeclared.unknown}) =>
      _p[id] = PState(startPrior, sigma0);

  @override
  void seed(int id, double rating, double sigma) {
    final st = _p[id]!;
    st.rating = rating;
    st.sigma = sigma;
  }

  @override
  void primeMatches(int id, int n) => _p[id]!.matches = n;

  @override
  double estimate(int id) => _p[id]!.rating;

  @override
  double publicRating(int id) => (clampD(estimate(id), 0, 7) * 4).round() / 4;

  @override
  double sigmaOf(int id) => _p[id]!.sigma;

  @override
  int matchesOf(int id) => _p[id]!.matches;

  /// Production's `profiles.is_provisional` generated column:
  /// `sigma > 0.40 OR competitive_matches < 10`.
  ///
  /// Note this is NOT a placement phase — production has none. It is the point
  /// at which a rating stops being flagged provisional. (The live schema is
  /// inconsistent here: `admin_season_player` and one view fallback use `< 5`
  /// against this column's `< 10`. The generated column is the stored truth, so
  /// it is what is mirrored.)
  @override
  bool displayReady(int id) {
    final s = _p[id]!;
    return s.sigma <= 0.40 && s.matches >= provisionalAt;
  }

  @override
  (int, double, int) get displayGate => (provisionalAt, 0.40, 0);

  /// Production boosts K over the first five matches, but nothing about those
  /// five matches forms a phase with its own rules that ends.
  @override
  int get placementLength => 0;

  double _teamAvg(List<int> t) =>
      t.map((i) => _p[i]!.rating).reduce((a, b) => a + b) / t.length;

  double _sigAvg(List<int> t) =>
      t.map((i) => _p[i]!.sigma).reduce((a, b) => a + b) / t.length;

  @override
  double predictA(MatchObs m) =>
      _logistic(_teamAvg(m.teamA) - _teamAvg(m.teamB), 1.0);

  @override
  void update(MatchObs m) {
    final rA = _teamAvg(m.teamA), rB = _teamAvg(m.teamB);
    final sgA = _sigAvg(m.teamA), sgB = _sigAvg(m.teamB);
    final eA = _logistic(rA - rB, 1.0);
    final eB = 1 - eA;
    final sA = _signal(m.aWon ? 1 : 0, m.gamesA, m.gamesB, resultWeight: 0.7);
    final sB = _signal(m.aWon ? 0 : 1, m.gamesB, m.gamesA, resultWeight: 0.7);
    final wA = 0.5 + 0.5 * (1 - sgB);
    final wB = 0.5 + 0.5 * (1 - sgA);

    void apply(List<int> team, double s, double e, double w, double result,
        double teamR, double oppR) {
      for (final id in team) {
        final st = _p[id]!;
        final before = st.rating, sigBefore = st.sigma, playedBefore = st.matches;
        var k = 0.04 + (0.35 - 0.04) * st.sigma;
        if (st.matches < boostWindow) k *= 1.5;
        var delta = k * w * (s - e);
        if (st.anchor) delta = clampD(delta, -0.05, 0.05);
        st.rating = (clampD(st.rating + delta, 0.0, 7.0) * 100).round() / 100;
        st.sigma = math.max(0.12, (st.sigma * 0.92 * 10000).round() / 10000);
        st.matches++;

        trace?.add(MoveTrace(
          id: id,
          before: before,
          after: st.rating,
          delta: st.rating - before,
          sigmaBefore: sigBefore,
          sigmaAfter: st.sigma,
          matchesBefore: playedBefore,
          inPlacement: playedBefore < boostWindow, // K-boost window, not a phase
          won: result == 1,
          teamRating: teamR,
          oppRating: oppR,
          expected: e,
          signal: s,
          resultPart: 0.7 * result,
          marginPart: s - 0.7 * result,
          k: k,
          w: w,
          marginEffect: k * w * (s - result),
        ));
      }
    }

    apply(m.teamA, sA, eA, wA, m.aWon ? 1 : 0, rA, rB);
    apply(m.teamB, sB, eB, wB, m.aWon ? 0 : 1, rB, rA);
  }

  /// apply_rating_decay(): σ +0.01/week after 14 days idle (cap 0.60);
  /// rating −0.04/week after 60 days idle, floored at the division floor.
  @override
  void idle(int id, int weeks) {
    final st = _p[id]!;
    if (weeks >= 2 && st.sigma < 0.60) {
      st.sigma = math.min(0.60, st.sigma + 0.01 * (weeks - 1));
    }
    if (weeks > 8 && st.matches >= 5 && st.rating > 1.0) {
      final decayWeeks = weeks - 8;
      final floor = st.rating >= 5.0
          ? 5.0
          : st.rating >= 3.5
              ? 3.5
              : st.rating >= 2.0
                  ? 2.0
                  : 0.0;
      st.rating = math.max(1.0, math.max(floor, st.rating - 0.04 * decayWeeks));
    }
  }

  @override
  void markAnchor(int id, double rating, double sigma) {
    final st = _p[id]!;
    st.rating = rating;
    st.sigma = sigma;
    st.anchor = true;
    st.matches = math.max(st.matches, 10);
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// ENGINE B / C — configurable hybrid.
//
// B (Aggressive Placement) changes ONLY the placement phase; once a player is
// established it is byte-for-byte the current engine. C (Tuned Hybrid) also
// changes the established-phase knobs. One class, two configs, so the delta
// between them is exactly the config.
// ═════════════════════════════════════════════════════════════════════════════
class HybridConfig {
  // ── prior ──
  final double prior;
  final double sigma0;
  final bool useDeclaredPrior;
  final Map<SelfDeclared, double> declaredPriors;

  // ── placement ──
  final int placementMatches;

  /// Stage boundaries (exclusive upper bound of matches played) and the maximum
  /// effective K inside each stage.
  final List<int> stageEnds;
  final List<double> stageK;

  /// Opponent-reliability floor while in placement (1.0 = ignore it entirely).
  final double placementRelFloor;
  final double placementSigmaDecay;

  /// Variant 5: full weight (W = 1.0) for the first [relRampMatches] matches,
  /// then ramp linearly back to the production formula by the end of placement.
  /// 0 disables the ramp and [placementRelFloor] applies flat.
  final int relRampMatches;

  // ── established ──
  final double kMin, kMax;
  final double sigmaDecay;
  final double relFloor;

  /// Staged confidence AFTER placement. Exclusive upper bounds on matches
  /// played, with the decay to use inside each band; anything past the last
  /// bound falls back to [sigmaDecay].
  ///
  /// Exists because "placement is over" and "we are confident" are different
  /// claims. Without this the only choices are to keep a player provisional
  /// long after their rating is usable, or to drop them to established decay
  /// the moment the counter ticks over — which collapses sigma, and with it K,
  /// while the rating is still travelling. Empty = the old single-decay model.
  final List<int> postStageEnds;
  final List<double> postStageDecay;

  // ── model shape ──
  final double curveScale;
  final double resultWeight;
  final double marginCap;

  /// Team strength = avg − λ·|gap| (λ<0 models carry).
  final double lambdaImbalance;

  // ── sigma models ──
  final bool adaptiveSigma;
  final double surpriseRef;
  final double surpriseGrowThreshold;
  final double surpriseGrow;
  final bool diversitySigma;
  final double decayHighInfo, decayMedInfo, decayLowInfo;

  // ── range + inactivity ──
  final double internalMin, internalMax;
  final bool ratingInactivityDecay;
  final double idleSigmaPerWeek;
  final double idleSigmaCap;
  final double idleRatingPerWeek;

  // ── display gate ──
  final int displayMinMatches;
  final double displayMaxSigma;
  final int displayMinPartners;

  const HybridConfig({
    this.prior = 3.0,
    this.sigma0 = 0.95,
    this.useDeclaredPrior = false,
    this.declaredPriors = const {},
    this.placementMatches = 10,
    this.stageEnds = const [3, 7, 10],
    this.stageK = const [0.70, 0.45, 0.28],
    this.placementRelFloor = 0.85,
    this.placementSigmaDecay = 0.88,
    this.relRampMatches = 0,
    this.kMin = 0.04,
    this.kMax = 0.35,
    this.sigmaDecay = 0.92,
    this.relFloor = 0.5,
    this.postStageEnds = const [],
    this.postStageDecay = const [],
    this.curveScale = 1.0,
    this.resultWeight = 0.7,
    this.marginCap = 0.5,
    this.lambdaImbalance = 0.0,
    this.adaptiveSigma = false,
    this.surpriseRef = 0.45,
    this.surpriseGrowThreshold = 0.42,
    this.surpriseGrow = 0.03,
    this.diversitySigma = false,
    this.decayHighInfo = 0.90,
    this.decayMedInfo = 0.95,
    this.decayLowInfo = 0.98,
    this.internalMin = 0.0,
    this.internalMax = 7.0,
    this.ratingInactivityDecay = true,
    this.idleSigmaPerWeek = 0.01,
    this.idleSigmaCap = 0.60,
    this.idleRatingPerWeek = 0.04,
    this.displayMinMatches = 10,
    this.displayMaxSigma = 0.40,
    this.displayMinPartners = 0,
  });

  HybridConfig copyWith({
    double? prior,
    double? sigma0,
    bool? useDeclaredPrior,
    Map<SelfDeclared, double>? declaredPriors,
    int? placementMatches,
    List<int>? stageEnds,
    List<double>? stageK,
    double? placementRelFloor,
    double? placementSigmaDecay,
    int? relRampMatches,
    double? kMin,
    double? kMax,
    double? sigmaDecay,
    double? relFloor,
    List<int>? postStageEnds,
    List<double>? postStageDecay,
    double? curveScale,
    double? resultWeight,
    double? marginCap,
    double? lambdaImbalance,
    bool? adaptiveSigma,
    double? surpriseRef,
    double? surpriseGrowThreshold,
    double? surpriseGrow,
    bool? diversitySigma,
    double? decayHighInfo,
    double? decayMedInfo,
    double? decayLowInfo,
    double? internalMin,
    double? internalMax,
    bool? ratingInactivityDecay,
    double? idleSigmaPerWeek,
    double? idleSigmaCap,
    double? idleRatingPerWeek,
    int? displayMinMatches,
    double? displayMaxSigma,
    int? displayMinPartners,
  }) =>
      HybridConfig(
        prior: prior ?? this.prior,
        sigma0: sigma0 ?? this.sigma0,
        useDeclaredPrior: useDeclaredPrior ?? this.useDeclaredPrior,
        declaredPriors: declaredPriors ?? this.declaredPriors,
        placementMatches: placementMatches ?? this.placementMatches,
        stageEnds: stageEnds ?? this.stageEnds,
        stageK: stageK ?? this.stageK,
        placementRelFloor: placementRelFloor ?? this.placementRelFloor,
        placementSigmaDecay: placementSigmaDecay ?? this.placementSigmaDecay,
        relRampMatches: relRampMatches ?? this.relRampMatches,
        kMin: kMin ?? this.kMin,
        kMax: kMax ?? this.kMax,
        sigmaDecay: sigmaDecay ?? this.sigmaDecay,
        relFloor: relFloor ?? this.relFloor,
        postStageEnds: postStageEnds ?? this.postStageEnds,
        postStageDecay: postStageDecay ?? this.postStageDecay,
        curveScale: curveScale ?? this.curveScale,
        resultWeight: resultWeight ?? this.resultWeight,
        marginCap: marginCap ?? this.marginCap,
        lambdaImbalance: lambdaImbalance ?? this.lambdaImbalance,
        adaptiveSigma: adaptiveSigma ?? this.adaptiveSigma,
        surpriseRef: surpriseRef ?? this.surpriseRef,
        surpriseGrowThreshold: surpriseGrowThreshold ?? this.surpriseGrowThreshold,
        surpriseGrow: surpriseGrow ?? this.surpriseGrow,
        diversitySigma: diversitySigma ?? this.diversitySigma,
        decayHighInfo: decayHighInfo ?? this.decayHighInfo,
        decayMedInfo: decayMedInfo ?? this.decayMedInfo,
        decayLowInfo: decayLowInfo ?? this.decayLowInfo,
        internalMin: internalMin ?? this.internalMin,
        internalMax: internalMax ?? this.internalMax,
        ratingInactivityDecay: ratingInactivityDecay ?? this.ratingInactivityDecay,
        idleSigmaPerWeek: idleSigmaPerWeek ?? this.idleSigmaPerWeek,
        idleSigmaCap: idleSigmaCap ?? this.idleSigmaCap,
        idleRatingPerWeek: idleRatingPerWeek ?? this.idleRatingPerWeek,
        displayMinMatches: displayMinMatches ?? this.displayMinMatches,
        displayMaxSigma: displayMaxSigma ?? this.displayMaxSigma,
        displayMinPartners: displayMinPartners ?? this.displayMinPartners,
      );
}

/// Default priors when onboarding asks "what's your level?".
const kDeclaredPriors = <SelfDeclared, double>{
  SelfDeclared.unknown: 3.3,
  SelfDeclared.beginner: 1.6,
  SelfDeclared.intermediate: 2.9,
  SelfDeclared.advanced: 4.2,
  SelfDeclared.competitive: 5.3,
};

class HybridEngine implements RankingEngine {
  @override
  final String name;
  final HybridConfig cfg;

  @override
  List<MoveTrace>? trace;

  final Map<int, PState> _p = {};

  HybridEngine(this.name, this.cfg);

  @override
  void register(int id, {SelfDeclared declared = SelfDeclared.unknown}) {
    final prior = cfg.useDeclaredPrior
        ? (cfg.declaredPriors[declared] ?? kDeclaredPriors[declared] ?? cfg.prior)
        : cfg.prior;
    _p[id] = PState(prior, cfg.sigma0);
  }

  @override
  double estimate(int id) => _p[id]!.rating;

  @override
  double publicRating(int id) => (clampD(estimate(id), 0, 7) * 4).round() / 4;

  @override
  double sigmaOf(int id) => _p[id]!.sigma;

  @override
  int matchesOf(int id) => _p[id]!.matches;

  @override
  void seed(int id, double rating, double sigma) {
    final st = _p[id]!;
    st.rating = rating;
    st.sigma = sigma;
  }

  @override
  void primeMatches(int id, int n) => _p[id]!.matches = n;

  @override
  bool displayReady(int id) {
    final s = _p[id]!;
    return s.matches >= cfg.displayMinMatches &&
        s.sigma <= cfg.displayMaxSigma &&
        s.partners.length >= cfg.displayMinPartners;
  }

  @override
  (int, double, int) get displayGate =>
      (cfg.displayMinMatches, cfg.displayMaxSigma, cfg.displayMinPartners);

  @override
  int get placementLength => cfg.placementMatches;

  double _teamRating(List<int> t) {
    final a = _p[t[0]]!.rating, b = _p[t.length > 1 ? t[1] : t[0]]!.rating;
    return (a + b) / 2 - cfg.lambdaImbalance * (a - b).abs();
  }

  double _sigAvg(List<int> t) =>
      t.map((i) => _p[i]!.sigma).reduce((a, b) => a + b) / t.length;

  @override
  double predictA(MatchObs m) =>
      _logistic(_teamRating(m.teamA) - _teamRating(m.teamB), cfg.curveScale);

  int _stageIndex(int matches) {
    for (var i = 0; i < cfg.stageEnds.length; i++) {
      if (matches < cfg.stageEnds[i]) return i;
    }
    return -1;
  }

  @override
  void update(MatchObs m) {
    final rA = _teamRating(m.teamA), rB = _teamRating(m.teamB);
    final sgA = _sigAvg(m.teamA), sgB = _sigAvg(m.teamB);
    final eA = _logistic(rA - rB, cfg.curveScale);
    final eB = 1 - eA;
    final sA = _signal(m.aWon ? 1 : 0, m.gamesA, m.gamesB,
        resultWeight: cfg.resultWeight, marginCap: cfg.marginCap);
    final sB = _signal(m.aWon ? 0 : 1, m.gamesB, m.gamesA,
        resultWeight: cfg.resultWeight, marginCap: cfg.marginCap);

    void apply(List<int> team, List<int> opp, double s, double e, double oppSigma,
        double result, double teamR, double oppR) {
      for (var idx = 0; idx < team.length; idx++) {
        final id = team[idx];
        final st = _p[id]!;
        final before = st.rating, sigBefore = st.sigma, playedBefore = st.matches;
        final inPlacement = st.matches < cfg.placementMatches;

        // ── opponent reliability, floored differently in placement ──
        final rawW = 0.5 + 0.5 * (1 - oppSigma);
        double floor;
        if (!inPlacement) {
          floor = cfg.relFloor;
        } else if (cfg.relRampMatches > 0) {
          // full weight for the first N, then ramp back down to the formula
          final span = math.max(1, cfg.placementMatches - cfg.relRampMatches);
          final t = clampD((st.matches - cfg.relRampMatches) / span, 0, 1);
          floor = 1.0 + (cfg.relFloor - 1.0) * t;
        } else {
          floor = cfg.placementRelFloor;
        }
        final w = math.max(rawW, floor);

        // ── K ──
        double k;
        if (inPlacement) {
          final stage = _stageIndex(st.matches);
          final stageK = cfg.stageK[stage < 0 ? cfg.stageK.length - 1 : stage];
          // scale within the stage by remaining uncertainty so a player who has
          // already been pinned down doesn't keep swinging at full amplitude
          k = stageK * clampD(st.sigma / cfg.sigma0, 0.35, 1.0);
        } else {
          k = cfg.kMin + (cfg.kMax - cfg.kMin) * st.sigma;
        }

        final z = s - e;
        var delta = k * w * z;
        if (st.anchor) delta = clampD(delta, -0.05, 0.05);
        st.rating = clampD(st.rating + delta, cfg.internalMin, cfg.internalMax);

        // ── sigma ──
        final partner = team.length > 1 ? team[1 - idx] : id;
        final newPartner = !st.partners.contains(partner);
        final newOpp = opp.any((o) => !st.opponents.contains(o));
        double dec;
        if (inPlacement) {
          dec = cfg.placementSigmaDecay;
        } else if (cfg.postStageEnds.isNotEmpty) {
          // Staged confidence: placement is over and the rating is public, but
          // the engine is not pretending to be sure yet.
          dec = cfg.sigmaDecay;
          for (var b = 0; b < cfg.postStageEnds.length; b++) {
            if (st.matches < cfg.postStageEnds[b]) {
              dec = cfg.postStageDecay[b < cfg.postStageDecay.length
                  ? b
                  : cfg.postStageDecay.length - 1];
              break;
            }
          }
        } else if (cfg.diversitySigma) {
          dec = newPartner && newOpp
              ? cfg.decayHighInfo
              : (newPartner || newOpp ? cfg.decayMedInfo : cfg.decayLowInfo);
        } else {
          dec = cfg.sigmaDecay;
        }
        if (cfg.adaptiveSigma) {
          final surprise = z.abs();
          st.surpriseEma = 0.7 * st.surpriseEma + 0.3 * surprise;
          // a surprising result should shrink confidence more slowly…
          dec = dec + (1 - dec) * clampD(surprise / cfg.surpriseRef, 0, 1);
          // …and a run of them should actively re-open the estimate
          if (st.surpriseEma > cfg.surpriseGrowThreshold && st.matches >= cfg.placementMatches) {
            dec = math.min(1.0 + cfg.surpriseGrow, dec + cfg.surpriseGrow);
          }
        }
        st.sigma = clampD(st.sigma * dec, 0.12, 1.0);

        st.partners.add(partner);
        st.opponents.addAll(opp);
        st.matches++;

        trace?.add(MoveTrace(
          id: id,
          before: before,
          after: st.rating,
          delta: st.rating - before,
          sigmaBefore: sigBefore,
          sigmaAfter: st.sigma,
          matchesBefore: playedBefore,
          inPlacement: inPlacement,
          won: result == 1,
          teamRating: teamR,
          oppRating: oppR,
          expected: e,
          signal: s,
          resultPart: cfg.resultWeight * result,
          marginPart: s - cfg.resultWeight * result,
          k: k,
          w: w,
          marginEffect: k * w * (s - result),
        ));
      }
    }

    apply(m.teamA, m.teamB, sA, eA, sgB, m.aWon ? 1 : 0, rA, rB);
    apply(m.teamB, m.teamA, sB, eB, sgA, m.aWon ? 0 : 1, rB, rA);
  }

  @override
  void idle(int id, int weeks) {
    final st = _p[id]!;
    if (weeks >= 2) {
      st.sigma =
          math.min(cfg.idleSigmaCap, st.sigma + cfg.idleSigmaPerWeek * (weeks - 1));
    }
    if (cfg.ratingInactivityDecay && weeks > 8 && st.matches >= 5 && st.rating > 1.0) {
      final floor = st.rating >= 5.0
          ? 5.0
          : st.rating >= 3.5
              ? 3.5
              : st.rating >= 2.0
                  ? 2.0
                  : 0.0;
      st.rating =
          math.max(1.0, math.max(floor, st.rating - cfg.idleRatingPerWeek * (weeks - 8)));
    }
  }

  @override
  void markAnchor(int id, double rating, double sigma) {
    final st = _p[id]!;
    st.rating = rating;
    st.sigma = sigma;
    st.anchor = true;
    st.matches = math.max(st.matches, cfg.placementMatches);
  }
}

/// ENGINE B — aggressive placement only; established behaviour identical to A.
HybridEngine aggressiveEngine({HybridConfig? cfg}) => HybridEngine(
      'B · Aggressive Placement',
      cfg ??
          const HybridConfig(
            prior: 3.3,
            sigma0: 0.95,
            placementMatches: 10,
            stageEnds: [3, 7, 10],
            stageK: [0.70, 0.45, 0.28],
            placementRelFloor: 0.85,
            placementSigmaDecay: 0.88,
            // everything below is exactly ENGINE A
            curveScale: 1.0,
            resultWeight: 0.7,
            marginCap: 0.5,
            sigmaDecay: 0.92,
            relFloor: 0.5,
            internalMin: 0.0,
            internalMax: 7.0,
            ratingInactivityDecay: true,
          ),
    );

/// ENGINE C — tuned hybrid. Every constant below was chosen on the TUNING
/// seeds (E2/E3/E4/E6/E7/E10) and is reported on held-out evaluation seeds.
const kTunedConfig = HybridConfig(
  // E2: start at the population's centre, not the bottom of the scale
  prior: 3.3,
  sigma0: 0.95,
  placementMatches: 10,
  // E4: bigger early placement steps were monotonically better up to K = 1.0
  stageEnds: [3, 7, 10],
  stageK: [0.80, 0.50, 0.30],
  // E3: the opponent-reliability discount inverts at launch — drop it while
  // provisional, keep it once established
  placementRelFloor: 1.0,
  placementSigmaDecay: 0.88,
  relFloor: 0.65,
  // E6: chosen in the context of the fixes below, not in isolation
  curveScale: 1.25,
  // E7: capping the games ratio removes the systematic anti-favourite drift AND
  // the incentive to run up a scoreline
  resultWeight: 0.85,
  marginCap: 0.15,
  // E10: surprise-aware sigma, at the reference that keeps volatility sane
  adaptiveSigma: true,
  surpriseRef: 0.70,
  diversitySigma: true,
  decayHighInfo: 0.90,
  decayMedInfo: 0.95,
  decayLowInfo: 0.98,
  // let the internal estimate breathe outside the public scale
  internalMin: -1.0,
  internalMax: 8.0,
  // E11: absence is lost information, not lost skill
  ratingInactivityDecay: false,
  idleSigmaPerWeek: 0.02,
  idleSigmaCap: 0.75,
  // E14: gate the reveal on evidence, not on a match counter alone
  displayMinMatches: 10,
  displayMaxSigma: 0.60,
  displayMinPartners: 5,
);

HybridEngine tunedEngine({HybridConfig? cfg}) =>
    HybridEngine('C · Tuned Hybrid', cfg ?? kTunedConfig);

/// ENGINE V3 — the candidate the lab exists to interrogate.
///
/// NOT production-final and not yet approved for production: these are the
/// study's recommendations turned into a concrete starting point so they can be
/// played with, argued against and changed. Differences from [kTunedConfig] are
/// deliberate simplifications — the study earned each of the four primary fixes
/// separately, while the extras below (curve steepening, adaptive sigma,
/// diversity sigma, the internal range) either were not individually justified
/// or interact with the fixes in ways the lab is meant to expose.
const kV3Config = HybridConfig(
  // ── fix 1: start at the centre of the population, not the floor ──
  prior: 3.3,
  sigma0: 0.95,
  // onboarding answer moves the STARTING POINT only; sigma stays at maximum, so
  // a dishonest answer is worth a couple of matches, not a rank
  useDeclaredPrior: false,
  declaredPriors: kDeclaredPriors,

  // ── fix 2: placement is allowed to move ──
  placementMatches: 10,
  stageEnds: [3, 7, 10],
  stageK: [0.80, 0.50, 0.30],

  // ── fix 3: don't discount opponents while nobody is established ──
  placementRelFloor: 1.0,
  placementSigmaDecay: 0.88,
  relFloor: 0.65,

  // ── fix 4: the margin informs, it does not drive ──
  resultWeight: 0.85,
  marginCap: 0.15,

  // left at today's value on purpose — the study found flattening or steepening
  // the curve mostly acts as a gain control and costs calibration
  curveScale: 1.0,

  // established behaviour: unchanged from production
  kMin: 0.04,
  kMax: 0.35,
  sigmaDecay: 0.92,

  // experimental, off by default — turn it on in the Doubles tab
  lambdaImbalance: 0.0,

  // ── absence is lost information, not lost skill ──
  ratingInactivityDecay: false,
  idleSigmaPerWeek: 0.02,
  idleSigmaCap: 0.75,

  // ── nothing public until the estimate has earned it ──
  displayMinMatches: 10,
  displayMaxSigma: 0.60,
  displayMinPartners: 0,
);

HybridEngine v3Engine({HybridConfig? cfg}) =>
    HybridEngine('V3 · Candidate', cfg ?? kV3Config);

// ─────────────────────────────────────────────────────────────────────────────
// V3 PLACEMENT VARIANTS — the tuning experiment, not proposals.
//
// All five share [kV3Config]'s prior (3.3), margin cap, reliability floor and
// established behaviour. ONLY the placement K schedule and the placement sigma
// decay differ, so any difference between them is attributable to those two
// knobs and nothing else.
//
// Why sigma decay is a K knob as well as a confidence knob: placement K is
//
//     k = stageK[stage] × clamp(sigma / sigma0, 0.35, 1.0)
//
// so the stage number is only a CEILING. With the candidate's 0.88 decay the
// multiplier has fallen to 0.35 (its floor) by match 9, meaning the late stage
// delivers 0.30 × 0.35 = 0.105, not 0.30. Slowing the decay raises correction
// power everywhere at once — which is exactly why D and E must be measured
// rather than assumed.
// ─────────────────────────────────────────────────────────────────────────────

/// V3-A — the current candidate, unchanged. The baseline every variant is read
/// against; a test pins it equal to [kV3Config].
final kV3A = kV3Config;

/// V3-B — sustained correction: the late stages keep more of their power.
final kV3B = kV3Config.copyWith(stageK: const [0.80, 0.60, 0.40]);

/// V3-C — balanced: less of the total correction budget spent in the first
/// three matches, more of it left for the rest of placement.
final kV3C = kV3Config.copyWith(stageK: const [0.70, 0.60, 0.45]);

/// V3-D — candidate K, slower placement sigma decay. Tests the hypothesis that
/// the engine becomes confident before it has finished correcting.
final kV3D = kV3Config.copyWith(placementSigmaDecay: 0.95);

/// V3-E — B's schedule and D's decay together. Not assumed to be the best:
/// both knobs raise K, so this is the variant most at risk of overshooting.
final kV3E = kV3Config.copyWith(
  stageK: const [0.80, 0.60, 0.40],
  placementSigmaDecay: 0.95,
);

/// V3-F — E, plus the ESTABLISHED sigma decay slowed from 0.92 to 0.97.
///
/// The other five all keep production's hard handover at match 10: placement
/// ends and sigma starts falling three times faster, so a player who is still
/// being corrected loses the uncertainty that was funding the correction. This
/// is the only variant that touches a knob outside placement, which is why it
/// is kept separate from the A–E family rather than folded into it.
final kV3F = kV3E.copyWith(sigmaDecay: 0.97);

/// V3-F5 — V3-F with a **5-match visible placement**, retuned rather than
/// compressed. Dividing the 10-match schedule by two was tested and is the
/// worst option in the family (see the "compressed" control in the notes):
/// it halves the evidence without raising the correction power, so it places
/// worse than the 10-match version it replaces.
///
/// Three stages, matching the intent rather than the old boundaries:
///   1–2 exploration   K 1.15 — is this player below, at, or above the prior?
///   3–4 calibration   K 0.90 — still strong enough to undo a misleading start
///   5   validation    K 0.70 — enough evidence for a first usable estimate
///
/// The reveal at match 5 is a **match-count gate only** (`displayMaxSigma` off).
/// That is the point: the player becomes ranked while sigma is still ~0.82, so
/// the rating is public AND openly low-confidence. Gating the reveal on sigma
/// as well would mean either never revealing at 5, or lying about certainty.
///
/// Post-placement confidence is staged so the engine keeps meaningful
/// correction power after the rating goes public — K is sigma-driven, so
/// holding sigma up holds K up. At match 6 K is roughly 3× what a settled
/// player gets. The bands approach the established rate from ABOVE and never
/// dip below it:
///
///   6–10   decay 0.980   early calibration, slowest of all
///   11–20  decay 0.975   stabilising
///   20+    decay 0.970   established (V3-F's own rate)
///
/// Ordering matters and was measured: bands that fall *below* the established
/// rate first and come back up score slightly worse at 20 matches (MAE 0.39 vs
/// 0.38, ±0.5 69% vs 71%) and misstate confidence while doing it.
final kV3F5 = kV3F.copyWith(
  placementMatches: 5,
  stageEnds: const [2, 4, 5],
  stageK: const [1.15, 0.90, 0.70],
  placementSigmaDecay: 0.97,
  postStageEnds: const [10, 20],
  postStageDecay: const [0.980, 0.975],
  displayMinMatches: 5,
  displayMaxSigma: 1.0,
);

// ═════════════════════════════════════════════════════════════════════════════
// ENGINE D — TrueSkill (2v2, Gaussian factor-graph update)
//
// Run natively on the 0–7 scale: per-player μ is a padel level, team skill is
// the SUM of its two players (TrueSkill's own convention), β is the per-player
// performance noise in levels.
// ═════════════════════════════════════════════════════════════════════════════
class TrueSkillEngine implements RankingEngine {
  @override
  final String name;

  final double mu0, sig0, beta, tau;

  /// Update once per SET rather than once per match — a cheap way to feed
  /// margin-of-victory information into an otherwise result-only model.
  final bool perSet;

  @override
  List<MoveTrace>? trace;

  final Map<int, _TS> _p = {};

  TrueSkillEngine({
    this.name = 'D · TrueSkill',
    this.mu0 = 3.3,
    this.sig0 = 1.2,
    this.beta = 0.9,
    this.tau = 0.015,
    this.perSet = false,
  });

  @override
  void register(int id, {SelfDeclared declared = SelfDeclared.unknown}) =>
      _p[id] = _TS(mu0, sig0);

  @override
  double estimate(int id) => _p[id]!.mu;

  @override
  double publicRating(int id) => (clampD(estimate(id), 0, 7) * 4).round() / 4;

  /// TrueSkill's conservative display value is μ − 3σ; we report σ so the
  /// harness can apply whatever display gate it likes.
  @override
  double sigmaOf(int id) => _p[id]!.sigma;

  @override
  int matchesOf(int id) => _p[id]!.matches;

  @override
  void seed(int id, double rating, double sigma) {
    _p[id]!
      ..mu = rating
      ..sigma = sigma;
  }

  @override
  void primeMatches(int id, int n) => _p[id]!.matches = n;

  @override
  bool displayReady(int id) => _p[id]!.sigma <= 0.55 && _p[id]!.matches >= 6;

  @override
  (int, double, int) get displayGate => (6, 0.55, 0);

  /// TrueSkill has no placement phase either — uncertainty simply falls.
  @override
  int get placementLength => 0;

  double _teamMu(List<int> t) => t.map((i) => _p[i]!.mu).reduce((a, b) => a + b);

  double _c(List<int> all) {
    var v = 0.0;
    for (final i in all) {
      final s = _p[i]!.sigma;
      v += s * s + beta * beta;
    }
    return math.sqrt(v);
  }

  @override
  double predictA(MatchObs m) {
    final c = _c(m.all);
    return normCdf((_teamMu(m.teamA) - _teamMu(m.teamB)) / c);
  }

  @override
  void update(MatchObs m) {
    final t = trace;
    final pre = t == null ? null : _snapshotOf(m);
    final expA = t == null ? 0.0 : predictA(m);

    if (perSet) {
      for (final s in m.sets) {
        _apply(m, s[0] > s[1]);
      }
      for (final i in m.all) {
        _p[i]!.matches++;
      }
    } else {
      _apply(m, m.aWon);
      for (final i in m.all) {
        _p[i]!.matches++;
      }
    }

    if (t != null) t.addAll(_traces(m, pre!, expA, perSet ? 'per-set update' : null));
  }

  Map<int, List<double>> _snapshotOf(MatchObs m) =>
      {for (final i in m.all) i: [_p[i]!.mu, _p[i]!.sigma, _p[i]!.matches.toDouble()]};

  List<MoveTrace> _traces(
      MatchObs m, Map<int, List<double>> pre, double expA, String? note) {
    double avg(List<int> t) => t.map((i) => pre[i]![0]).reduce((a, b) => a + b) / t.length;
    final rA = avg(m.teamA), rB = avg(m.teamB);
    return [
      for (final i in m.all)
        () {
          final onA = m.teamA.contains(i);
          final st = _p[i]!;
          return MoveTrace(
            id: i,
            before: pre[i]![0],
            after: st.mu,
            delta: st.mu - pre[i]![0],
            sigmaBefore: pre[i]![1],
            sigmaAfter: st.sigma,
            matchesBefore: pre[i]![2].toInt(),
            inPlacement: !displayReady(i),
            won: onA == m.aWon,
            teamRating: onA ? rA : rB,
            oppRating: onA ? rB : rA,
            expected: onA ? expA : 1 - expA,
            note: note,
          );
        }(),
    ];
  }

  void _apply(MatchObs m, bool aWon) {
    for (final i in m.all) {
      final st = _p[i]!;
      st.sigma = math.sqrt(st.sigma * st.sigma + tau * tau);
    }
    final winners = aWon ? m.teamA : m.teamB;
    final losers = aWon ? m.teamB : m.teamA;
    final c = _c(m.all);
    final t = (_teamMu(winners) - _teamMu(losers)) / c;
    final v = _vWin(t);
    final w = v * (v + t);

    for (final i in winners) {
      final st = _p[i]!;
      final s2 = st.sigma * st.sigma;
      st.mu += (s2 / c) * v;
      st.sigma = math.sqrt(math.max(1e-6, s2 * (1 - (s2 / (c * c)) * w)));
      st.sigma = math.max(st.sigma, 0.06);
    }
    for (final i in losers) {
      final st = _p[i]!;
      final s2 = st.sigma * st.sigma;
      st.mu -= (s2 / c) * v;
      st.sigma = math.sqrt(math.max(1e-6, s2 * (1 - (s2 / (c * c)) * w)));
      st.sigma = math.max(st.sigma, 0.06);
    }
  }

  /// v(t) = φ(t)/Φ(t), with an asymptotic guard in the far tail.
  static double _vWin(double t) {
    if (t < -6.0) return -t + 1.0 / (-t); // avoids 0/0
    final den = normCdf(t);
    if (den < 1e-12) return -t;
    return normPdf(t) / den;
  }

  @override
  void idle(int id, int weeks) {
    // Uncertainty-only: exactly what TrueSkill's τ is for.
    final st = _p[id]!;
    final extra = 0.02 * weeks;
    st.sigma = math.min(1.0, math.sqrt(st.sigma * st.sigma + extra * extra));
  }

  @override
  void markAnchor(int id, double rating, double sigma) {
    _p[id]!
      ..mu = rating
      ..sigma = sigma
      ..matches = math.max(_p[id]!.matches, 10);
  }
}

class _TS {
  double mu;
  double sigma;
  int matches = 0;
  _TS(this.mu, this.sigma);
}

double normPdf(double x) => math.exp(-0.5 * x * x) / math.sqrt(2 * math.pi);

/// Φ(x) via a Numerical-Recipes erfc (≈1.2e-7 absolute accuracy).
double normCdf(double x) => 0.5 * _erfc(-x / math.sqrt2);

double _erfc(double x) {
  final z = x.abs();
  final t = 2.0 / (2.0 + z);
  final ty = 4.0 * t - 2.0;
  const cof = [
    -1.3026537197817094, 6.4196979235649026e-1, 1.9476473204185836e-2,
    -9.561514786808631e-3, -9.46595344482036e-4, 3.66839497852761e-4,
    4.2523324806907e-5, -2.0278578112534e-5, -1.624290004647e-6,
    1.303655835580e-6, 1.5626441722e-8, -8.5238095915e-8,
    6.529054439e-9, 5.059343495e-9, -9.91364156e-10,
    -2.27365122e-10, 9.6467911e-11, 2.394038e-12,
    -6.886027e-12, 8.94487e-13, 3.13092e-13,
    -1.12708e-13, 3.81e-16, 7.106e-15,
  ];
  var d = 0.0, dd = 0.0;
  for (var j = cof.length - 1; j > 0; j--) {
    final tmp = d;
    d = ty * d - dd + cof[j];
    dd = tmp;
  }
  final ans = t * math.exp(-z * z + 0.5 * (cof[0] + ty * d) - dd);
  return x >= 0 ? ans : 2.0 - ans;
}

// ═════════════════════════════════════════════════════════════════════════════
// ENGINE E — Glicko-2, doubles adaptation.
//
// Each player is updated against ONE virtual opponent constructed so that the
// expectation equals the team-vs-team expectation:
//     R_virtual = oppTeamAvg + (myRating − myTeamAvg)
// with RD_virtual = sqrt(mean(RD_opp²) + ½·RD_partner²) so partner uncertainty
// correctly slows the update down. One match = one rating period.
// ═════════════════════════════════════════════════════════════════════════════
class Glicko2Engine implements RankingEngine {
  @override
  final String name;

  /// Glicko points per 1.0 padel level. 400 reproduces the current 10:1-per-
  /// level steepness; 200 is a considerably flatter curve.
  final double pointsPerLevel;
  final double startLevel;
  final double startRd; // in points
  final double startVol;
  final double sysTau; // volatility constraint

  @override
  List<MoveTrace>? trace;

  final Map<int, _GL> _p = {};

  Glicko2Engine({
    this.name = 'E · Glicko-2',
    this.pointsPerLevel = 250,
    this.startLevel = 3.3,
    this.startRd = 350,
    this.startVol = 0.06,
    this.sysTau = 0.5,
  });

  static const double _q = 173.7178;

  @override
  void register(int id, {SelfDeclared declared = SelfDeclared.unknown}) =>
      _p[id] = _GL(1500, startRd, startVol);

  double _lvl(double points) => startLevel + (points - 1500) / pointsPerLevel;
  double _pts(double level) => 1500 + (level - startLevel) * pointsPerLevel;

  @override
  double estimate(int id) => _lvl(_p[id]!.r);

  @override
  double publicRating(int id) => (clampD(estimate(id), 0, 7) * 4).round() / 4;

  /// Reported on the 0–7 scale so it is comparable with the other engines.
  @override
  double sigmaOf(int id) => _p[id]!.rd / pointsPerLevel;

  @override
  int matchesOf(int id) => _p[id]!.matches;

  @override
  void seed(int id, double rating, double sigma) {
    _p[id]!
      ..r = _pts(rating)
      ..rd = sigma * pointsPerLevel;
  }

  @override
  void primeMatches(int id, int n) => _p[id]!.matches = n;

  @override
  bool displayReady(int id) => sigmaOf(id) <= 0.45 && _p[id]!.matches >= 6;

  @override
  (int, double, int) get displayGate => (6, 0.45, 0);

  @override
  int get placementLength => 0;

  double _teamAvgPts(List<int> t) =>
      t.map((i) => _p[i]!.r).reduce((a, b) => a + b) / t.length;

  @override
  double predictA(MatchObs m) {
    final a = _teamAvgPts(m.teamA), b = _teamAvgPts(m.teamB);
    final rdA = math.sqrt(m.teamA.map((i) => _p[i]!.rd * _p[i]!.rd).reduce((x, y) => x + y) / 2);
    final rdB = math.sqrt(m.teamB.map((i) => _p[i]!.rd * _p[i]!.rd).reduce((x, y) => x + y) / 2);
    final phi = math.sqrt(rdA * rdA + rdB * rdB) / _q;
    final g = 1 / math.sqrt(1 + 3 * phi * phi / (math.pi * math.pi));
    return 1 / (1 + math.exp(-g * (a - b) / _q));
  }

  @override
  void update(MatchObs m) {
    final avgA = _teamAvgPts(m.teamA), avgB = _teamAvgPts(m.teamB);
    final snapshot = {for (final i in m.all) i: _p[i]!.copy()};
    final tr = trace;
    final expA = tr == null ? 0.0 : predictA(m);

    void side(List<int> team, List<int> opp, double myAvg, double oppAvg, double score) {
      for (var idx = 0; idx < team.length; idx++) {
        final id = team[idx];
        final me = snapshot[id]!;
        final partner = snapshot[team[1 - idx]]!;
        final oppRd2 = opp.map((o) => snapshot[o]!.rd * snapshot[o]!.rd).reduce((a, b) => a + b) / 2;
        final vRd = math.sqrt(oppRd2 + 0.5 * partner.rd * partner.rd);
        final vR = oppAvg + (me.r - myAvg);
        _glicko(id, me, vR, vRd, score);
      }
    }

    side(m.teamA, m.teamB, avgA, avgB, m.aWon ? 1 : 0);
    side(m.teamB, m.teamA, avgB, avgA, m.aWon ? 0 : 1);
    for (final i in m.all) {
      _p[i]!.matches++;
    }

    if (tr != null) {
      for (final i in m.all) {
        final onA = m.teamA.contains(i);
        final was = snapshot[i]!;
        tr.add(MoveTrace(
          id: i,
          before: _lvl(was.r),
          after: estimate(i),
          delta: estimate(i) - _lvl(was.r),
          sigmaBefore: was.rd / pointsPerLevel,
          sigmaAfter: sigmaOf(i),
          matchesBefore: was.matches,
          inPlacement: !displayReady(i),
          won: onA == m.aWon,
          teamRating: _lvl(onA ? avgA : avgB),
          oppRating: _lvl(onA ? avgB : avgA),
          expected: onA ? expA : 1 - expA,
        ));
      }
    }
  }

  void _glicko(int id, _GL me, double oppR, double oppRd, double score) {
    final mu = (me.r - 1500) / _q;
    final phi = me.rd / _q;
    final muJ = (oppR - 1500) / _q;
    final phiJ = oppRd / _q;

    final g = 1 / math.sqrt(1 + 3 * phiJ * phiJ / (math.pi * math.pi));
    var e = 1 / (1 + math.exp(-g * (mu - muJ)));
    e = clampD(e, 1e-9, 1 - 1e-9);

    final v = 1 / (g * g * e * (1 - e));
    final delta = v * g * (score - e);

    // volatility (Illinois algorithm, Glicko-2 step 5)
    final a0 = math.log(me.vol * me.vol);
    double f(double x) {
      final ex = math.exp(x);
      final d2 = delta * delta;
      final num = ex * (d2 - phi * phi - v - ex);
      final den = 2 * math.pow(phi * phi + v + ex, 2);
      return num / den - (x - a0) / (sysTau * sysTau);
    }

    var aa = a0;
    double bb;
    if (delta * delta > phi * phi + v) {
      bb = math.log(delta * delta - phi * phi - v);
    } else {
      var k = 1;
      while (f(a0 - k * sysTau) < 0 && k < 100) {
        k++;
      }
      bb = a0 - k * sysTau;
    }
    var fa = f(aa), fb = f(bb);
    var iter = 0;
    while ((bb - aa).abs() > 1e-6 && iter++ < 60) {
      final cc = aa + (aa - bb) * fa / (fb - fa);
      final fc = f(cc);
      if (fc * fb <= 0) {
        aa = bb;
        fa = fb;
      } else {
        fa = fa / 2;
      }
      bb = cc;
      fb = fc;
    }
    final newVol = math.exp(aa / 2);

    final phiStar = math.sqrt(phi * phi + newVol * newVol);
    final phiNew = 1 / math.sqrt(1 / (phiStar * phiStar) + 1 / v);
    final muNew = mu + phiNew * phiNew * g * (score - e);

    final st = _p[id]!;
    st.r = muNew * _q + 1500;
    st.rd = clampD(phiNew * _q, pointsPerLevel * 0.04, startRd);
    st.vol = newVol;
  }

  @override
  void idle(int id, int weeks) {
    final st = _p[id]!;
    final phi = st.rd / _q;
    final grown = math.sqrt(phi * phi + weeks * st.vol * st.vol);
    st.rd = math.min(startRd, grown * _q);
  }

  @override
  void markAnchor(int id, double rating, double sigma) {
    final st = _p[id]!;
    st.r = _pts(rating);
    st.rd = sigma * pointsPerLevel;
    st.matches = math.max(st.matches, 10);
  }
}

class _GL {
  double r, rd, vol;
  int matches = 0;
  _GL(this.r, this.rd, this.vol);
  _GL copy() => _GL(r, rd, vol)..matches = matches;
}

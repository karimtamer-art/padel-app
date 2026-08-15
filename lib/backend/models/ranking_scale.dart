/// Ranking model + scale — the dynamic data layer behind the Division card,
/// stats strip, ELO history, streak and achievements.
///
/// A [PlayerProfile] is either **in placement** (a brand-new account, unranked)
/// or **placed** (a level 0.0–7.0 that maps to a division + tier).
library;

import 'mock_data.dart';
import 'rating_engine_v3f5.dart';

/// One rung of the four-tier ladder.
class Division {
  final String key; // 'D' … 'A'
  final String name; // 'Division B'
  final String metal; // 'bronze' | 'silver' | 'gold' | 'elite'
  final String metalName; // 'Gold'
  final String league; // 'Advanced League'
  final double min, max; // inclusive level band
  const Division(this.key, this.name, this.metal, this.metalName, this.league,
      this.min, this.max);
}

/// Pure ranking math. No widgets — safe to unit-test.
///
/// ```
/// 0.0–1.9  Division D · Bronze · Beginner League
/// 2.0–3.4  Division C · Silver · Intermediate League
/// 3.5–4.9  Division B · Gold   · Advanced League
/// 5.0–7.0  Division A · Elite  · Expert League
/// ```
class RankingScale {
  RankingScale._();

  static const List<Division> divisions = [
    Division('D', 'Division D', 'bronze', 'Bronze', 'Beginner League', 0.0, 1.9),
    Division('C', 'Division C', 'silver', 'Silver', 'Intermediate League', 2.0, 3.4),
    Division('B', 'Division B', 'gold', 'Gold', 'Advanced League', 3.5, 4.9),
    Division('A', 'Division A', 'elite', 'Elite', 'Expert League', 5.0, 7.0),
  ];

  /// Competitive matches before a rating goes public. THE authoritative
  /// placement count for every player-facing surface — sourced from the engine
  /// so a screen can never disagree with settlement about it.
  static const int placementTotal = RatingEngineV3F5.placementMatches;
  static const double maxLevel = 7.0;

  static double _clamp(double v, double a, double b) =>
      v < a ? a : (v > b ? b : v);

  static int divisionIndex(double lv) {
    for (var i = 0; i < divisions.length; i++) {
      if (lv <= divisions[i].max) return i;
    }
    return divisions.length - 1;
  }

  static Division divisionFor(double lv) => divisions[divisionIndex(lv)];

  /// 0..1 progress through the player's current division band.
  static double progressInDivision(double lv) {
    final d = divisionFor(lv);
    return _clamp((lv - d.min) / (d.max - d.min), 0, 1);
  }

  /// 'Low' | 'Mid' | 'High' within the current division.
  static String tierFor(double lv) {
    final f = progressInDivision(lv);
    return f < 1 / 3 ? 'Low' : (f < 2 / 3 ? 'Mid' : 'High');
  }

  static Division? nextDivision(double lv) {
    final i = divisionIndex(lv);
    return i < divisions.length - 1 ? divisions[i + 1] : null;
  }

  /// 0..1 fill across the whole D→A ladder (for the progress rail).
  static double ladderFill(double lv) {
    final i = divisionIndex(lv);
    return _clamp((i + progressInDivision(lv)) / (divisions.length - 1), 0, 1);
  }

  /// Next 0.5 level milestone (capped at [maxLevel]).
  static double nextLevelMilestone(double lv) {
    final next = ((lv / 0.5).floor() + 1) * 0.5;
    return next < maxLevel ? next : maxLevel;
  }

  static double levelMilestoneProgress(double lv) {
    final next = nextLevelMilestone(lv);
    final prev = next - 0.5;
    return _clamp((lv - prev) / 0.5, 0, 1);
  }

  static String fmtLevel(double n) => n.toStringAsFixed(1);

  /// Rating v2 stores 2 decimals but the spec displays levels rounded to the
  /// nearest 0.25 step. Use this for the headline level chip.
  static double toQuarter(double lv) => (lv * 4).round() / 4;

  /// Level shown to 0.25 precision, trimmed: 4 · 4.25 · 4.5 · 4.75.
  static String fmtQuarter(double n) {
    var s = toQuarter(n).toStringAsFixed(2);
    if (s.endsWith('0')) s = s.substring(0, s.length - 1); // 4.50 -> 4.5
    if (s.endsWith('.0')) s = s.substring(0, s.length - 2); // 4.0 -> 4
    return s;
  }

  /// Compact display tag, e.g. "Lv 4.3 · Division B".
  static String levelTag(double lv) =>
      'Lv ${fmtLevel(lv)} · ${divisionFor(lv).name}';

  static String fmtSigned(double n) {
    final sign = n > 0 ? '+' : (n < 0 ? '−' : '');
    return '$sign${n.abs().toStringAsFixed(2)}';
  }
}


/// Folds an embedded `player_ratings` row up into its parent map.
///
/// The ranking columns moved off `profiles` into `player_ratings` on
/// 2026-08-15, so PostgREST returns them nested:
/// `{id, name, player_ratings: {rating, level, tier, …}}`. Every screen and
/// service reads them flat (`row['rating']`), and rewriting ~60 read sites to
/// reach through a sub-map would be churn for no gain — so the nesting is
/// undone once, here, at the service boundary.
///
/// A null or missing embed is left alone: an unranked player still has a row
/// (the table is backfilled and trigger-maintained), but a select that did not
/// ask for the embed should not silently gain empty keys.
Map<String, dynamic> flattenRatings(Map<String, dynamic> row) {
  final r = row['player_ratings'];
  if (r is Map) {
    row = Map<String, dynamic>.from(row)..remove('player_ratings');
    r.forEach((k, v) => row[k as String] = v);
  } else if (r is List && r.isNotEmpty && r.first is Map) {
    row = Map<String, dynamic>.from(row)..remove('player_ratings');
    (r.first as Map).forEach((k, v) => row[k as String] = v);
  }
  return row;
}

/// How a player's level changed this period — drives the card's status banner.
enum RankMovement { promoted, dropped, steady }

/// Last rated result, shown on the placed card — the "why did my level move"
/// breakdown (opponent average level, games margin, level delta).
class LastRankedMatch {
  final bool won;
  final double vsLevel; // opponent team average level
  final double delta; // signed level change
  final int gamesFor; // games this player's team won
  final int gamesAgainst; // games conceded
  const LastRankedMatch({
    required this.won,
    required this.vsLevel,
    required this.delta,
    this.gamesFor = 0,
    this.gamesAgainst = 0,
  });

  bool get hasScore => gamesFor > 0 || gamesAgainst > 0;
}

/// A player's ranking state. Construct one of the two named constructors:
/// [Ranking.placement] (unranked, mid-placement) or [Ranking.placed].
class Ranking {
  final bool placed;
  final int placement; // completed placement matches (when !placed)
  final double level; // 0..7 (when placed)
  final RankMovement movement;
  final String movedFrom;
  final double weeklyDelta;
  final LastRankedMatch? lastMatch;
  final double reliability; // 0..100 — rating confidence (1 - sigma)
  final bool provisional; // still finding their level (high sigma / few matches)
  final int competitiveMatches; // completed ranked matches (drives "confirm" count)

  const Ranking.placement(this.placement)
      : placed = false,
        level = 0,
        movement = RankMovement.steady,
        movedFrom = '',
        weeklyDelta = 0,
        lastMatch = null,
        reliability = 0,
        provisional = true,
        competitiveMatches = 0;

  const Ranking.placed({
    required this.level,
    this.movement = RankMovement.steady,
    this.movedFrom = '',
    this.weeklyDelta = 0,
    this.lastMatch,
    this.reliability = 100,
    this.provisional = false,
    this.competitiveMatches = 0,
  })  : placed = true,
        placement = RankingScale.placementTotal;

  int get remaining =>
      (RankingScale.placementTotal - placement).clamp(0, RankingScale.placementTotal);

  /// Ranked matches still needed to shed **provisional** status.
  ///
  /// Not the placement count — placement ended at
  /// [RankingScale.placementTotal] and the rating is already public. This is
  /// the separate confidence gate, which under V3-F5 clears at
  /// [RatingEngineV3F5.establishedMatches] (the engine's own end-of-calibration
  /// boundary), not at v2's 10.
  int get matchesToConfirm {
    final n = RatingEngineV3F5.establishedMatches - competitiveMatches;
    return n < 0 ? 0 : n;
  }
}

/// Everything the Profile screen needs for a single account. Switch the whole
/// screen between a brand-new player and an established one by swapping this.
class PlayerProfile {
  final bool isNew;
  final Ranking ranking;

  // Career stats
  final int played, wins, losses, streak;
  final String winRate; // pre-formatted ('60%' / '—')

  // Leaderboard (null until placed)
  final int? rank;
  final String? nextTier;
  final double progress; // 0..1 toward the next division

  /// The player's own rating after each of their last rated matches, on the
  /// real 0.00-7.00 scale. Was `eloHistory`, a fake `800 + rating*200` series.
  final List<double> ratingHistory;
  final List<RecentMatch> recent;

  /// Whether the one-time "placement complete" reveal has already been shown.
  /// Only meaningful once [ranking] is placed. Display-only.
  final bool placementRevealed;

  const PlayerProfile({
    required this.isNew,
    required this.ranking,
    required this.played,
    required this.wins,
    required this.losses,
    required this.streak,
    required this.winRate,
    this.rank,
    this.nextTier,
    this.progress = 0,
    this.ratingHistory = const [],
    this.recent = const [],
    this.placementRevealed = false,
  });

  bool get hasMatches => played > 0;

  /// Brand-new account: unranked, 0 of 5 placement matches done, no history.
  static const fresh = PlayerProfile(
    isNew: true,
    ranking: Ranking.placement(0),
    played: 0,
    wins: 0,
    losses: 0,
    winRate: '—',
    streak: 0,
    progress: 0,
    ratingHistory: [],
    recent: [],
  );
}

/// Ranking model + scale — the dynamic data layer behind the Division card,
/// stats strip, ELO history, streak and achievements.
///
/// A [PlayerProfile] is either **in placement** (a brand-new account, unranked)
/// or **placed** (a level 0.0–7.0 that maps to a division + tier).
library;

import 'mock_data.dart';

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

  static const int placementTotal = 5;
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

  /// Compact display tag, e.g. "Lv 4.3 · Division B".
  static String levelTag(double lv) =>
      'Lv ${fmtLevel(lv)} · ${divisionFor(lv).name}';

  /// Level derived from raw ELO — mirrors `level_from_elo` in Postgres.
  static double levelFromElo(int elo) =>
      _clamp(((elo - 800) / 200.0), 0, maxLevel);

  static String fmtSigned(double n) {
    final sign = n > 0 ? '+' : (n < 0 ? '−' : '');
    return '$sign${n.abs().toStringAsFixed(2)}';
  }
}

/// How a player's level changed this period — drives the card's status banner.
enum RankMovement { promoted, dropped, steady }

/// Last rated result, shown on the placed card.
class LastRankedMatch {
  final bool won;
  final double vsLevel;
  final double delta; // signed level change
  const LastRankedMatch(
      {required this.won, required this.vsLevel, required this.delta});
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

  const Ranking.placement(this.placement)
      : placed = false,
        level = 0,
        movement = RankMovement.steady,
        movedFrom = '',
        weeklyDelta = 0,
        lastMatch = null;

  const Ranking.placed({
    required this.level,
    this.movement = RankMovement.steady,
    this.movedFrom = '',
    this.weeklyDelta = 0,
    this.lastMatch,
  })  : placed = true,
        placement = RankingScale.placementTotal;

  int get remaining =>
      (RankingScale.placementTotal - placement).clamp(0, RankingScale.placementTotal);
}

/// Everything the Profile screen needs for a single account. Switch the whole
/// screen between a brand-new player and an established one by swapping this.
class PlayerProfile {
  final bool isNew;
  final Ranking ranking;

  // Career stats
  final int played, wins, losses, streak;
  final String winRate; // pre-formatted ('60%' / '—')

  // Leaderboard / ELO (null until placed)
  final int? rank, elo, toNext;
  final String? nextTier, eloDelta; // eloDelta pre-formatted ('+153')
  final double progress; // 0..1 toward next ELO tier

  // History
  final List<int> eloHistory;
  final List<RecentMatch> recent;
  final List<FormMatch> formHistory;
  final int achievementsUnlocked;

  const PlayerProfile({
    required this.isNew,
    required this.ranking,
    required this.played,
    required this.wins,
    required this.losses,
    required this.streak,
    required this.winRate,
    this.rank,
    this.elo,
    this.toNext,
    this.nextTier,
    this.eloDelta,
    this.progress = 0,
    this.eloHistory = const [],
    this.recent = const [],
    this.formHistory = const [],
    this.achievementsUnlocked = 0,
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
    eloHistory: [],
    recent: [],
    formHistory: [],
    achievementsUnlocked: 0,
  );
}

import 'package:flutter/material.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// Playtomic-style ranking model for the Profile Division Card.
///
/// Level scale (NOT raw Elo):
///   0.0 – 1.9   Division D · Bronze · Beginner
///   2.0 – 3.4   Division C · Silver · Intermediate
///   3.5 – 4.9   Division B · Gold   · Advanced
///   5.0 – 7.0   Division A · Elite  · Expert
///
/// Ranking lifecycle:
///   • A new user is *Unranked* until they complete [RankingScale.placementTotal]
///     placement matches. During placement we only know how many are done.
///   • Once placed, the user has a `level`, which maps to a Division, an in-division
///     Tier (Low / Mid / High), and progress toward the next division.
///   • Only **confirmed competitive** matches change `level`. Casual matches and
///     unconfirmed (submitted-but-not-yet-confirmed) scores must NOT mutate it —
///     recompute and rebuild this model only after an opponent confirms.
/// ─────────────────────────────────────────────────────────────────────────

/// Direction of a user's recent ranking movement (this week / since last match).
enum RankMovement { promoted, dropped, steady }

/// One rung of the division ladder.
@immutable
class Division {
  final String key; // 'D' | 'C' | 'B' | 'A'
  final String name; // 'Division B'
  final String metal; // 'Bronze' | 'Silver' | 'Gold' | 'Elite'
  final String league; // 'Advanced League'
  final double min; // inclusive level floor
  final double max; // inclusive level ceiling
  final Color color; // accent for the rung's dot / metal
  final List<Color> grad; // gradient fill for the dot when active/done

  const Division(this.key, this.name, this.metal, this.league, this.min,
      this.max, this.color, this.grad);
}

/// Pure functions that turn a `level` into divisions / tiers / progress.
/// Mirrors the JS `RankingScale` in `Division Card.html` 1:1.
class RankingScale {
  RankingScale._();

  static const int placementTotal = 5;

  /// Bright "card gold" used on the dark hero card (not the muted AppColors.gold).
  static const Color _gold = Color(0xFFE0BB63);
  static const Color _silver = Color(0xFFB9B4AC);
  static const Color _bronze = Color(0xFFB5793F);
  static const Color _elite = Color(0xFF7FB4D0);

  static const List<Division> divisions = <Division>[
    Division('D', 'Division D', 'Bronze', 'Beginner League', 0.0, 1.9, _bronze,
        [Color(0xFFC98B4E), Color(0xFF9A622F)]),
    Division('C', 'Division C', 'Silver', 'Intermediate League', 2.0, 3.4,
        _silver, [Color(0xFFD7D2CA), Color(0xFFA6A199)]),
    Division('B', 'Division B', 'Gold', 'Advanced League', 3.5, 4.9, _gold,
        [Color(0xFFF3DE9E), Color(0xFFC99B33)]),
    Division('A', 'Division A', 'Elite', 'Expert League', 5.0, 7.0, _elite,
        [Color(0xFFA9D2E6), Color(0xFF6CA3C2)]),
  ];

  static double _clamp(double v, double a, double b) =>
      v < a ? a : (v > b ? b : v);

  /// Index (0..3) of the division a level belongs to.
  static int divisionIndex(double level) {
    for (var i = 0; i < divisions.length; i++) {
      if (level <= divisions[i].max) return i;
    }
    return divisions.length - 1;
  }

  static Division divisionFor(double level) => divisions[divisionIndex(level)];

  /// Fraction (0..1) of the way through the current division.
  static double progressInDivision(double level) {
    final d = divisionFor(level);
    return _clamp((level - d.min) / (d.max - d.min), 0, 1);
  }

  /// Whole-number percent through the current division (for "70% to Division A").
  static int progressPercent(double level) =>
      (progressInDivision(level) * 100).round();

  /// In-division tier label.
  static String tierFor(double level) {
    final f = progressInDivision(level);
    if (f < 1 / 3) return 'Low';
    if (f < 2 / 3) return 'Mid';
    return 'High';
  }

  /// The division above the current one, or null if already at the top.
  static Division? nextDivision(double level) {
    final i = divisionIndex(level);
    return i < divisions.length - 1 ? divisions[i + 1] : null;
  }

  /// Fraction (0..1) the ladder fill should span across the 4 rungs.
  static double ladderFill(double level) {
    final i = divisionIndex(level);
    return _clamp((i + progressInDivision(level)) / (divisions.length - 1), 0, 1);
  }

  /// "Level 4.3"
  static String levelLabel(double level) => 'Level ${level.toStringAsFixed(1)}';

  /// "+0.12" / "−0.15" (two-decimal, signed; uses a true minus glyph).
  static String signed(double n) {
    final s = n > 0 ? '+' : (n < 0 ? '\u2212' : '');
    return '$s${n.abs().toStringAsFixed(2)}';
  }

  /// Next 0.5 level milestone above [level] (Playtomic half-steps), capped at 7.0.
  static double nextLevelMilestone(double level) {
    final m = ((level / 0.5).floor() + 1) * 0.5;
    return m > 7.0 ? 7.0 : m;
  }

  /// 0..1 progress from the previous half-step toward [nextLevelMilestone].
  static double levelMilestoneProgress(double level) {
    final next = nextLevelMilestone(level);
    return _clamp((level - (next - 0.5)) / 0.5, 0, 1);
  }
}

/// The user's most recent confirmed match, surfaced on the ranked card.
@immutable
class LastMatch {
  final bool win;
  final double vsLevel; // average level of the opponents faced
  final double delta; // level change from this match (e.g. +0.12 / -0.10)
  const LastMatch({required this.win, required this.vsLevel, required this.delta});
}

/// A user's complete ranking snapshot. Rebuild this after every *confirmed*
/// competitive match; pass it straight into [RankingCard].
@immutable
class UserRanking {
  /// True once placement is complete and the user has a real level.
  final bool placed;

  /// Placement matches completed so far (0..placementTotal). Only meaningful
  /// while [placed] is false.
  final int placementPlayed;

  /// Current level on the 0.0–7.0 scale. Only meaningful while [placed] is true.
  final double level;

  /// Recent movement, surfaced in the status strip.
  final RankMovement movement;

  /// Division the user was promoted *from* (when [movement] == promoted).
  final String movedFrom;

  /// Net level change over the lookback window (e.g. +0.2 / -0.3).
  final double weeklyDelta;

  /// The user's most recent confirmed match, if any.
  final LastMatch? lastMatch;

  const UserRanking._({
    required this.placed,
    this.placementPlayed = 0,
    this.level = 0,
    this.movement = RankMovement.steady,
    this.movedFrom = '',
    this.weeklyDelta = 0,
    this.lastMatch,
  });

  /// New / unranked user, mid-placement.
  const UserRanking.unranked({int placementPlayed = 0})
      : this._(placed: false, placementPlayed: placementPlayed);

  /// Ranked user with a confirmed level.
  const UserRanking.ranked({
    required double level,
    RankMovement movement = RankMovement.steady,
    String movedFrom = '',
    double weeklyDelta = 0,
    LastMatch? lastMatch,
  }) : this._(
          placed: true,
          level: level,
          movement: movement,
          movedFrom: movedFrom,
          weeklyDelta: weeklyDelta,
          lastMatch: lastMatch,
        );

  // ── Derived getters (delegate to RankingScale) ──────────────────────────
  Division get division => RankingScale.divisionFor(level);
  Division? get next => RankingScale.nextDivision(level);
  String get tier => RankingScale.tierFor(level);
  int get progressPercent => RankingScale.progressPercent(level);
  double get ladderFill => RankingScale.ladderFill(level);
  int get divisionIndex => RankingScale.divisionIndex(level);

  /// Immediate next 0.5 level milestone and progress toward it.
  double get nextLevel => RankingScale.nextLevelMilestone(level);
  int get nextLevelPercent =>
      (RankingScale.levelMilestoneProgress(level) * 100).round();
  bool get atMaxLevel => level >= 7.0;

  /// Remaining placement matches (>= 0).
  int get placementRemaining =>
      (RankingScale.placementTotal - placementPlayed).clamp(0, RankingScale.placementTotal);

  /// 0..1 placement completion.
  double get placementProgress =>
      placementPlayed / RankingScale.placementTotal;

  // ── JSON deserialisation ─────────────────────────────────────────────────

  factory UserRanking.fromJson(Map<String, dynamic> json) {
    final level   = (json['level']            as num?)?.toDouble() ?? 0.0;
    final played  = (json['placement_played'] as num?)?.toInt()    ?? 0;
    final weekly  = (json['weekly_delta']     as num?)?.toDouble() ?? 0.0;
    final lastDelta  = (json['last_delta']    as num?)?.toDouble();
    final lastWin = json['last_win']          as bool?;
    final vsLevel = (json['last_vs_level']   as num?)?.toDouble();

    if (played < RankingScale.placementTotal) {
      return UserRanking.unranked(placementPlayed: played);
    }
    return UserRanking.ranked(
      level:       level,
      weeklyDelta: weekly,
      lastMatch:   lastDelta != null
          ? LastMatch(
              win:     lastWin ?? lastDelta >= 0,
              vsLevel: vsLevel ?? level,
              delta:   lastDelta,
            )
          : null,
    );
  }
}

/// Mock rankings for previews / development. Swap for real API-derived models.
class MockRanking {
  MockRanking._();

  /// Brand-new user, two placement matches in.
  static const UserRanking newUser = UserRanking.unranked(placementPlayed: 2);

  /// Account that hasn't played any placement matches.
  static const UserRanking fresh = UserRanking.unranked(placementPlayed: 0);

  /// Typical ranked user — Division B, mid tier, holding steady.
  static const UserRanking ranked = UserRanking.ranked(
    level: 4.3,
    movement: RankMovement.steady,
    weeklyDelta: 0.12,
    lastMatch: LastMatch(win: true, vsLevel: 4.1, delta: 0.12),
  );

  /// Just promoted up from Division C.
  static const UserRanking promoted = UserRanking.ranked(
    level: 3.6,
    movement: RankMovement.promoted,
    movedFrom: 'Division C',
    weeklyDelta: 0.28,
    lastMatch: LastMatch(win: true, vsLevel: 4.6, delta: 0.16),
  );

  /// Just relegated to Division C.
  static const UserRanking relegated = UserRanking.ranked(
    level: 3.2,
    movement: RankMovement.dropped,
    weeklyDelta: -0.18,
    lastMatch: LastMatch(win: false, vsLevel: 3.9, delta: -0.12),
  );

  /// Top-division elite player.
  static const UserRanking elite = UserRanking.ranked(
    level: 6.1,
    movement: RankMovement.steady,
    weeklyDelta: 0.20,
    lastMatch: LastMatch(win: true, vsLevel: 6.0, delta: 0.18),
  );
}

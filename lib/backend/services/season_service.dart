import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Seasonal leaderboard + rewards.
///
/// Points are awarded server-side only (`_award_season_points` inside
/// `_settle_rating`, plus title/podium points in `finalize_tournament`) — the
/// client never writes to `season_points`. Everything here is a read, or an
/// admin RPC that guards on `_is_admin()`.
class SeasonService {
  SeasonService._();
  static SupabaseClient get _db => Supabase.instance.client;

  // ── Player ──────────────────────────────────────────────────────

  /// The published live season, the whole board, the reward brackets and my
  /// own row — one round trip. Null when no season is live and published.
  static Future<SeasonOverview?> overview() async {
    try {
      final res = await _db.rpc('season_overview');
      if (res == null) return null;
      return SeasonOverview.fromJson(Map<String, dynamic>.from(res as Map));
    } catch (e) {
      debugPrint('[SeasonService] overview: $e');
      return null;
    }
  }

  // ── Admin console ───────────────────────────────────────────────

  /// Everything the Leaderboards console renders. [seasonId] null = the live
  /// season (or the newest one if none is live).
  static Future<SeasonConsole?> console({String? seasonId}) async {
    try {
      final res = await _db.rpc('admin_season_console',
          params: {'p_season_id': seasonId});
      if (res == null) return null;
      return SeasonConsole.fromJson(Map<String, dynamic>.from(res as Map));
    } catch (e) {
      debugPrint('[SeasonService] console: $e');
      return null;
    }
  }

  /// All RPCs below return null on success, or a message to show the operator.
  static Future<String?> createSeason({
    required String name,
    required DateTime starts,
    required DateTime ends,
    String? copyFromSeasonId,
  }) =>
      _call('admin_create_season', {
        'p_name': name,
        'p_starts': _date(starts),
        'p_ends': _date(ends),
        'p_copy_from': copyFromSeasonId,
      });

  static Future<String?> setPublished(String seasonId, bool value) =>
      _call('admin_set_season_flag', {
        'p_season_id': seasonId,
        'p_flag': 'published',
        'p_value': value,
      });

  static Future<String?> setFrozen(String seasonId, bool value) =>
      _call('admin_set_season_flag', {
        'p_season_id': seasonId,
        'p_flag': 'frozen',
        'p_value': value,
      });

  static Future<String?> closeSeason(String seasonId) =>
      _call('admin_close_season', {'p_season_id': seasonId});

  static Future<String?> saveRule(
          String seasonId, String code, int pts, String note) =>
      _call('admin_save_season_rule', {
        'p_season_id': seasonId,
        'p_code': code,
        'p_pts': pts,
        'p_note': note,
      });

  static Future<String?> saveBracket({
    String? id,
    required String seasonId,
    required int rankFrom,
    required int rankTo,
    required String label,
    required String prize,
    required List<String> extras,
    required int budget,
    String icon = 'shield',
    String color = 'inksoft',
    String? short,
  }) =>
      _call('admin_save_season_bracket', {
        'p_id': id,
        'p_season_id': seasonId,
        'p_rank_from': rankFrom,
        'p_rank_to': rankTo,
        'p_label': label,
        'p_prize': prize,
        'p_extras': extras,
        'p_budget': budget,
        'p_icon': icon,
        'p_color': color,
        'p_short': short,
      });

  static Future<String?> deleteBracket(String id) =>
      _call('admin_delete_season_bracket', {'p_id': id});

  static Future<String?> adjustPoints({
    required String seasonId,
    required String playerId,
    required int delta,
    required String reason,
  }) =>
      _call('admin_adjust_season_points', {
        'p_season_id': seasonId,
        'p_player_id': playerId,
        'p_delta': delta,
        'p_reason': reason,
      });

  /// Freeze today's ranks so next week's board shows a real trend.
  static Future<String?> snapshotRanks() =>
      _call('snapshot_season_ranks', const {});

  static Future<String?> _call(String fn, Map<String, dynamic> params) async {
    try {
      final res = await _db.rpc(fn, params: params.isEmpty ? null : params);
      if (res is String && res.trim().isNotEmpty) return res;
      return null;
    } catch (e) {
      debugPrint('[SeasonService] $fn: $e');
      return 'Something went wrong. Try again.';
    }
  }

  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

// ── Models ────────────────────────────────────────────────────────

int _int(dynamic v) => v is int ? v : int.tryParse('${v ?? ''}') ?? 0;
double _num(dynamic v) =>
    v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;

/// A season header (player view).
class Season {
  final String id, name;
  final int no, daysLeft;
  final double progress;
  final DateTime startsOn, endsOn;
  final bool frozen;
  final String? region;

  const Season({
    required this.id,
    required this.no,
    required this.name,
    required this.startsOn,
    required this.endsOn,
    required this.daysLeft,
    required this.progress,
    this.frozen = false,
    this.region,
  });

  factory Season.fromJson(Map<String, dynamic> j) => Season(
        id: j['id'] as String,
        no: _int(j['no']),
        name: (j['name'] as String?) ?? 'Season',
        startsOn: DateTime.tryParse('${j['starts_on']}') ?? DateTime.now(),
        endsOn: DateTime.tryParse('${j['ends_on']}') ?? DateTime.now(),
        daysLeft: _int(j['days_left']),
        progress: _num(j['progress']).clamp(0, 1).toDouble(),
        frozen: j['frozen'] == true,
        region: j['region'] as String?,
      );

  /// "31 Aug" — the season's closing day, as the board prints it.
  String get endsLabel {
    const m = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${endsOn.day} ${m[endsOn.month - 1]}';
  }
}

/// One row of the standings.
class Standing {
  final int rank, pts, played, trend;
  final String playerId, name, tier;
  final String? avatarUrl;
  final bool me;

  const Standing({
    required this.rank,
    required this.playerId,
    required this.name,
    required this.tier,
    required this.pts,
    required this.played,
    required this.trend,
    this.avatarUrl,
    this.me = false,
  });

  factory Standing.fromJson(Map<String, dynamic> j) => Standing(
        rank: _int(j['rank']),
        playerId: '${j['player_id']}',
        name: (j['name'] as String?) ?? 'Player',
        tier: (j['tier'] as String?) ?? 'bronze',
        pts: _int(j['pts']),
        played: _int(j['played']),
        trend: _int(j['trend']),
        avatarUrl: j['avatar_url'] as String?,
        me: j['me'] == true,
      );

  Standing copyWith({int? rank, bool? me}) => Standing(
        rank: rank ?? this.rank,
        playerId: playerId,
        name: name,
        tier: tier,
        pts: pts,
        played: played,
        trend: trend,
        avatarUrl: avatarUrl,
        me: me ?? this.me,
      );

  String get initials => initialsOf(name);

  String get firstName => name.trim().split(RegExp(r'\s+')).first;
}

/// "Karim Hassan" → "KH", "Karim" → "KA".
String initialsOf(String name) {
  String head(String s, int n) =>
      s.length <= n ? s.toUpperCase() : s.substring(0, n).toUpperCase();
  final parts =
      name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return head(parts.first, 2);
  return '${head(parts.first, 1)}${head(parts.last, 1)}';
}

/// A points-engine rule.
class SeasonRule {
  final String code, label, note, icon;
  final int pts;
  const SeasonRule(this.code, this.label, this.pts, this.note, this.icon);

  factory SeasonRule.fromJson(Map<String, dynamic> j) => SeasonRule(
        '${j['code']}',
        (j['label'] as String?) ?? '',
        _int(j['pts']),
        (j['note'] as String?) ?? '',
        (j['icon'] as String?) ?? 'star',
      );
}

/// A reward bracket — a rank range and what those players win.
class SeasonBracket {
  final String id, label, short, icon, colorKey;
  final String prize;
  final List<String> extras;
  final int rankFrom, rankTo, budget;

  const SeasonBracket({
    required this.id,
    required this.rankFrom,
    required this.rankTo,
    required this.label,
    required this.short,
    required this.icon,
    required this.colorKey,
    required this.prize,
    required this.extras,
    required this.budget,
  });

  factory SeasonBracket.fromJson(Map<String, dynamic> j) => SeasonBracket(
        id: '${j['id']}',
        rankFrom: _int(j['rank_from']),
        rankTo: _int(j['rank_to']),
        label: (j['label'] as String?) ?? '',
        short: (j['short'] as String?) ?? (j['label'] as String?) ?? '',
        icon: (j['icon'] as String?) ?? 'shield',
        colorKey: (j['color'] as String?) ?? 'inksoft',
        prize: (j['prize'] as String?) ?? '',
        extras: ((j['extras'] as List?) ?? const [])
            .map((e) => '$e')
            .where((e) => e.trim().isNotEmpty)
            .toList(),
        budget: _int(j['budget']),
      );

  bool holds(int rank) => rank >= rankFrom && rank <= rankTo;

  /// "#1" for a single rank, "#4–10" for a range.
  String get rangeLabel =>
      rankFrom == rankTo ? '#$rankFrom' : '#$rankFrom–$rankTo';
}

/// Everything the player leaderboard needs.
class SeasonOverview {
  final Season season;
  final Standing? me;
  final List<Standing> board;
  final List<SeasonRule> rules;
  final List<SeasonBracket> brackets;

  const SeasonOverview({
    required this.season,
    required this.me,
    required this.board,
    required this.rules,
    required this.brackets,
  });

  factory SeasonOverview.fromJson(Map<String, dynamic> j) => SeasonOverview(
        season: Season.fromJson(Map<String, dynamic>.from(j['season'] as Map)),
        me: j['me'] == null
            ? null
            : Standing.fromJson(Map<String, dynamic>.from(j['me'] as Map)),
        board: ((j['board'] as List?) ?? const [])
            .map((e) => Standing.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        rules: ((j['rules'] as List?) ?? const [])
            .map((e) => SeasonRule.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        brackets: ((j['brackets'] as List?) ?? const [])
            .map((e) =>
                SeasonBracket.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );

  SeasonBracket? bracketFor(int rank) {
    for (final b in brackets) {
      if (b.holds(rank)) return b;
    }
    return null;
  }

  int rulePts(String code) {
    for (final r in rules) {
      if (r.code == code) return r.pts;
    }
    return 0;
  }
}

/// A season row in the console's season grid.
class SeasonSummary {
  final String id, name, status;
  final int no, ranked;
  final DateTime startsOn, endsOn;
  final bool published, frozen, paidOut;
  final String? champion;

  const SeasonSummary({
    required this.id,
    required this.no,
    required this.name,
    required this.status,
    required this.startsOn,
    required this.endsOn,
    required this.ranked,
    required this.published,
    required this.frozen,
    required this.paidOut,
    this.champion,
  });

  factory SeasonSummary.fromJson(Map<String, dynamic> j) => SeasonSummary(
        id: '${j['id']}',
        no: _int(j['no']),
        name: (j['name'] as String?) ?? 'Season',
        status: (j['status'] as String?) ?? 'scheduled',
        startsOn: DateTime.tryParse('${j['starts_on']}') ?? DateTime.now(),
        endsOn: DateTime.tryParse('${j['ends_on']}') ?? DateTime.now(),
        ranked: _int(j['ranked']),
        published: j['published'] == true,
        frozen: j['frozen'] == true,
        paidOut: j['paid_out'] == true,
        champion: j['champion'] as String?,
      );

  String get statusLabel => switch (status) {
        'live' => 'Live',
        'scheduled' => 'Scheduled',
        _ => 'Ended',
      };

  /// "1 May – 31 Aug 2026"
  String get window {
    const m = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final a = '${startsOn.day} ${m[startsOn.month - 1]}';
    final b = '${endsOn.day} ${m[endsOn.month - 1]} ${endsOn.year}';
    return '$a – $b';
  }
}

/// Everything the admin Leaderboards console renders.
class SeasonConsole {
  final List<SeasonSummary> seasons;
  final SeasonSummary? season;
  final int daysLeft, rankedCount, matchesCounted;
  final double progress;
  final String? region;
  final List<SeasonRule> rules;
  final List<SeasonBracket> brackets;
  final List<Standing> standings;
  final String? error;

  const SeasonConsole({
    required this.seasons,
    required this.season,
    required this.daysLeft,
    required this.rankedCount,
    required this.matchesCounted,
    required this.progress,
    required this.rules,
    required this.brackets,
    required this.standings,
    this.region,
    this.error,
  });

  factory SeasonConsole.fromJson(Map<String, dynamic> j) {
    final s = j['season'] == null
        ? null
        : Map<String, dynamic>.from(j['season'] as Map);
    return SeasonConsole(
      error: j['error'] as String?,
      seasons: ((j['seasons'] as List?) ?? const [])
          .map((e) => SeasonSummary.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      season: s == null ? null : SeasonSummary.fromJson(s),
      daysLeft: _int(s?['days_left']),
      rankedCount: _int(s?['ranked']),
      matchesCounted: _int(s?['matches']),
      progress: _num(s?['progress']).clamp(0, 1).toDouble(),
      region: s?['region'] as String?,
      rules: ((j['rules'] as List?) ?? const [])
          .map((e) => SeasonRule.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      brackets: ((j['brackets'] as List?) ?? const [])
          .map((e) => SeasonBracket.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      standings: ((j['standings'] as List?) ?? const [])
          .map((e) => Standing.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }

  int get rewardBudget =>
      brackets.fold<int>(0, (n, b) => n + b.budget);

  SeasonBracket? bracketFor(int rank) {
    for (final b in brackets) {
      if (b.holds(rank)) return b;
    }
    return null;
  }
}

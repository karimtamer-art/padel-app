import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// All match I/O for the player app: browse, create, join, leave,
/// detail, and the result flow (submit → confirm/dispute → ELO settle).
///
/// Heavy lifting (capacity checks, ELO maths) happens in Postgres RPCs —
/// see `supabase/migration_player_app.sql` — so results can't be forged
/// or double-applied from the client.
class MatchService {
  MatchService._();
  static SupabaseClient get _db => Supabase.instance.client;
  static String? get _uid => _db.auth.currentUser?.id;

  static const matchCols =
      'id, status, match_type, scheduled_at, winner_team, score_team_a, '
      'score_team_b, created_by, court_id, min_elo, is_private, invite_code, '
      'result_submitted_by, '
      'courts(name, venue_name), '
      'match_players(player_id, team, elo_before, elo_after, '
      '  profiles(id, name, elo, level, tier))';

  // ── Browse ────────────────────────────────────────────────────────────────

  /// Public open matches in the future that the current user hasn't joined.
  static Future<List<Map<String, dynamic>>> fetchOpenMatches() async {
    final rows = await _db
        .from('matches')
        .select(matchCols)
        .eq('status', 'open')
        .eq('is_private', false)
        .gte('scheduled_at', DateTime.now().toIso8601String())
        .order('scheduled_at')
        .limit(40);
    final list = List<Map<String, dynamic>>.from(rows as List);
    final uid = _uid;
    if (uid == null) return list;
    return list.where((m) {
      final players = (m['match_players'] as List?) ?? const [];
      return !players.any((p) => p['player_id'] == uid);
    }).toList();
  }

  /// One match with court + players, or null.
  static Future<Map<String, dynamic>?> fetchMatch(String id) async {
    try {
      final row =
          await _db.from('matches').select(matchCols).eq('id', id).maybeSingle();
      return row == null ? null : Map<String, dynamic>.from(row);
    } catch (e) {
      debugPrint('[MatchService] fetchMatch: $e');
      return null;
    }
  }

  /// Active courts for the create flow.
  static Future<List<Map<String, dynamic>>> fetchCourts() async {
    try {
      final rows = await _db
          .from('courts')
          .select('id, name, venue_name, in_maintenance')
          .order('venue_name');
      return List<Map<String, dynamic>>.from(rows as List)
          .where((c) => c['in_maintenance'] != true)
          .toList();
    } catch (e) {
      debugPrint('[MatchService] fetchCourts: $e');
      return [];
    }
  }

  /// Player search for the partner picker (excludes self + admins).
  static Future<List<Map<String, dynamic>>> searchPlayers(String query) async {
    try {
      var q = _db
          .from('profiles')
          .select('id, name, elo, level, tier')
          .eq('is_admin', false)
          .neq('id', _uid ?? '');
      if (query.trim().isNotEmpty) q = q.ilike('name', '%${query.trim()}%');
      final rows = await q.order('elo', ascending: false).limit(20);
      return List<Map<String, dynamic>>.from(rows as List);
    } catch (e) {
      debugPrint('[MatchService] searchPlayers: $e');
      return [];
    }
  }

  // ── Create / join / leave ────────────────────────────────────────────────

  static String _inviteCode() {
    final n = Random().nextInt(9000) + 1000;
    return 'PDL-$n';
  }

  /// Creates the match and adds the creator (+ optional partner) to team A.
  /// Returns `(error, matchId)`.
  static Future<(String?, String?)> createMatch({
    required bool competitive,
    required DateTime scheduledAt,
    String? courtId,
    String? partnerId,
    required bool open,
    int minElo = 0,
  }) async {
    final uid = _uid;
    if (uid == null) return ('Not signed in.', null);
    try {
      final match = await _db
          .from('matches')
          .insert({
            'status': 'open',
            'match_type': competitive ? 'ranked' : 'casual',
            'scheduled_at': scheduledAt.toUtc().toIso8601String(),
            'created_by': uid,
            if (courtId != null) 'court_id': courtId,
            'is_private': !open,
            'min_elo': minElo,
            'invite_code': _inviteCode(),
          })
          .select('id')
          .single();
      final id = match['id'] as String;

      final players = <Map<String, dynamic>>[
        {'match_id': id, 'player_id': uid, 'team': 'a'},
        if (partnerId != null)
          {'match_id': id, 'player_id': partnerId, 'team': 'a'},
      ];
      await _db.from('match_players').insert(players);
      return (null, id);
    } on PostgrestException catch (e) {
      return (e.message, null);
    } catch (e) {
      return (e.toString(), null);
    }
  }

  /// Race-safe join via RPC. Returns an error message or null.
  static Future<String?> joinMatch(String matchId) async {
    try {
      final res = await _db.rpc('join_match', params: {'p_match_id': matchId});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  static Future<String?> leaveMatch(String matchId) async {
    try {
      final res = await _db.rpc('leave_match', params: {'p_match_id': matchId});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  // ── Result flow ──────────────────────────────────────────────────────────

  /// [sets] from team A's perspective, e.g. [[6,4],[3,6],[6,2]].
  static Future<String?> submitResult(
      String matchId, List<List<int>> sets) async {
    final aWon = sets.where((s) => s[0] > s[1]).length;
    final bWon = sets.where((s) => s[1] > s[0]).length;
    if (aWon == bWon) return 'The score must have a winner.';
    final scoreA = sets.map((s) => s[0]).join(',');
    final scoreB = sets.map((s) => s[1]).join(',');
    try {
      final res = await _db.rpc('submit_match_result', params: {
        'p_match_id': matchId,
        'p_score_a': scoreA,
        'p_score_b': scoreB,
        'p_winner': aWon > bWon ? 'a' : 'b',
      });
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  static Future<String?> confirmResult(String matchId, bool confirm) async {
    try {
      final res = await _db.rpc('confirm_match_result',
          params: {'p_match_id': matchId, 'p_confirm': confirm});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }
}

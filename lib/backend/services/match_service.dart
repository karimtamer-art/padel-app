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
      '  profiles(id, name, elo, level, tier, phone, username))';

  // ── Matchmaking discovery (band-gatekept) ──────────────────────────────────

  /// Candidate matches inside the caller's rating band (+ city + time window),
  /// via the SECURITY DEFINER `mm_candidates` RPC. There is NO public browse —
  /// this is the only way to see a match you're not already in. Returns flat
  /// rows: match_id, scheduled_at, match_type, court_name, venue_name, city,
  /// creator_id/name/rating/level, players, center_rating, level_match_pct.
  static Future<List<Map<String, dynamic>>> fetchBandCandidates({int limit = 10}) async {
    try {
      final rows = await _db.rpc('mm_candidates', params: {'p_limit': limit});
      return List<Map<String, dynamic>>.from(rows as List);
    } catch (e) {
      debugPrint('[MatchService] fetchBandCandidates: $e');
      return [];
    }
  }

  /// The single best candidate for the caller, or null. Powers the "Match
  /// found" card (Phase 2).
  static Future<Map<String, dynamic>?> findCandidate() async {
    final rows = await fetchBandCandidates(limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Count of matches in the caller's band — the home "N matches near you"
  /// teaser. Band-filtered, not a public count.
  static Future<int> countCandidates() async {
    try {
      final n = await _db.rpc('mm_count_candidates');
      return (n as num?)?.toInt() ?? 0;
    } catch (e) {
      debugPrint('[MatchService] countCandidates: $e');
      return 0;
    }
  }

  /// The caller's most recent completed-but-unacked match for the "MATCH
  /// COMPLETE" home hero, or null. Fields: match_id, won, my_team, score_team_a,
  /// score_team_b, rating_delta (null for casual), rating_after, match_type.
  static Future<Map<String, dynamic>?> resultHero() async {
    try {
      final rows = await _db.rpc('mm_result_hero');
      final list = List<Map<String, dynamic>>.from(rows as List);
      return list.isEmpty ? null : list.first;
    } catch (e) {
      debugPrint('[MatchService] resultHero: $e');
      return null;
    }
  }

  /// Acks the result hero so it doesn't reappear. Best-effort.
  static Future<void> ackResult(String matchId) async {
    try {
      await _db.rpc('mm_ack_result', params: {'p_match_id': matchId});
    } catch (e) {
      debugPrint('[MatchService] ackResult: $e');
    }
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

  /// Active courts for the create flow. Only public courts are offered to
  /// players — organizer courts (is_public = false) stay inside the community.
  /// Falls back to the unfiltered query on pre-migration DBs without is_public.
  static Future<List<Map<String, dynamic>>> fetchCourts() async {
    List rows;
    try {
      rows = await _db
          .from('courts')
          .select('id, name, venue_name, in_maintenance, is_public')
          .eq('is_public', true)
          .order('venue_name');
    } catch (_) {
      try {
        rows = await _db
            .from('courts')
            .select('id, name, venue_name, in_maintenance')
            .order('venue_name');
      } catch (e) {
        debugPrint('[MatchService] fetchCourts: $e');
        return [];
      }
    }
    return List<Map<String, dynamic>>.from(rows)
        .where((c) => c['in_maintenance'] != true)
        .toList();
  }

  /// Player search for the partner picker (excludes self + admins).
  ///
  /// Matches on the unique @username handle only — free-text name is ambiguous
  /// (two "Karim"s) and email is intentionally not exposed. A leading '@' and
  /// case are ignored. An empty query returns top players by ELO as suggestions.
  static Future<List<Map<String, dynamic>>> searchPlayers(String query) async {
    try {
      var q = _db
          .from('profiles')
          .select('id, name, username, elo, level, tier')
          .eq('is_admin', false)
          .neq('id', _uid ?? '');
      final term = query.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
      if (term.isNotEmpty) q = q.ilike('username', '%$term%');
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

  /// Accept a surfaced matchmaking candidate — race-safe join that re-checks the
  /// band server-side. Returns an error message or null. Use this from the
  /// matchmaking flow instead of [joinMatch] (which is the plain capacity join).
  static Future<String?> acceptCandidate(String matchId) async {
    try {
      final res = await _db.rpc('mm_accept', params: {'p_match_id': matchId});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
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

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/ranking_scale.dart' show flattenRatings;

/// Match I/O for the player app: detail, leave/cancel, and the result flow
/// (submit → confirm/dispute → rating settle).
///
/// Pickup is retired (Phase 4): create, join, join-by-code, matchmaking and
/// invite answers are gone from the client. What stays lets a match booked
/// before the switch finish, and serves the result hero and partner search
/// (tournament registration uses [searchPlayers]).
///
/// Heavy lifting (capacity checks, rating maths) happens in Postgres RPCs —
/// see `supabase/migration_player_app.sql` — so results can't be forged
/// or double-applied from the client.
class MatchService {
  MatchService._();
  static SupabaseClient get _db => Supabase.instance.client;
  static String? get _uid => _db.auth.currentUser?.id;

  static const matchCols =
      'id, status, match_type, scheduled_at, winner_team, score_team_a, '
      'score_team_b, created_by, court_id, min_rating, is_private, invite_code, '
      'result_submitted_by, '
      'courts(name, venue_name, lat, lng, address), '
      'match_players(player_id, team, '
      // No `phone` here on purpose. It used to ship a number to the client for
      // every co-player and leave the decision to Dart; the contact sheet now
      // asks `player_phone(uuid)`, which applies `_can_see_phone` in Postgres.
      // avatar_url IS fine to embed — it's a public bucket URL, unlike phone.
      '  profiles(id, name, username, avatar_url, '
      '           player_ratings(rating, level, tier)))';

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
      return row == null ? null : _flattenMatch(Map<String, dynamic>.from(row));
    } catch (e) {
      debugPrint('[MatchService] fetchMatch: $e');
      return null;
    }
  }

  /// Folds each embedded `player_ratings` row up into its player's profile.
  ///
  /// `matchCols` nests three deep — match → match_players[] → profiles →
  /// player_ratings — because the ranking columns moved off `profiles` on
  /// 2026-08-15. Every lobby and detail screen reads `prof['rating']` and
  /// `prof['level']` flat, so the nesting is undone once, here.
  static Map<String, dynamic> _flattenMatch(Map<String, dynamic> m) {
    final players = m['match_players'];
    if (players is! List) return m;
    for (var i = 0; i < players.length; i++) {
      final mp = players[i];
      if (mp is! Map) continue;
      final prof = mp['profiles'];
      if (prof is Map) {
        mp['profiles'] = flattenRatings(Map<String, dynamic>.from(prof));
      }
    }
    return m;
  }

  // ── Partner invites ────────────────────────────────────────────────────────
  //
  // Naming a partner raises an invite; it does NOT put them in the match. Until
  // they accept they are not a match_player, so they have no ticket membership
  // and no phone number of theirs is served anywhere. Their slot is held for
  // them server-side (see `_match_taken`), so nobody else can take it while
  // they decide.

  /// The reserved slots on a match — who was invited and to which team. Name
  /// and avatar only; there is deliberately no phone number here.
  static Future<List<Map<String, dynamic>>> pendingInvites(String matchId) async {
    try {
      final rows =
          await _db.rpc('match_pending_invites', params: {'p_match': matchId});
      return List<Map<String, dynamic>>.from(rows as List);
    } catch (e) {
      // A pre-migration DB has no such RPC — a match with no reserved slots is
      // the right answer there, not a broken lobby.
      debugPrint('[MatchService] pendingInvites: $e');
      return [];
    }
  }

  /// A co-player's phone number, or null when you're not entitled to it.
  ///
  /// Postgres decides: you must share a match with them AND either have swapped
  /// numbers or they set `phone_public`. Never cache the result — the answer
  /// changes when either of you changes your mind.
  static Future<String?> playerPhone(String playerId) async {
    try {
      final res = await _db.rpc('player_phone', params: {'p_player': playerId});
      final s = (res as String?)?.trim();
      return (s == null || s.isEmpty) ? null : s;
    } catch (e) {
      debugPrint('[MatchService] playerPhone: $e');
      return null;
    }
  }

  /// Player search for the partner picker (excludes self + admins).
  ///
  /// Matches on the unique @username handle only — free-text name is ambiguous
  /// (two "Karim"s) and email is intentionally not exposed. A leading '@' and
  /// case are ignored. An empty query returns the highest-rated players as
  /// suggestions — unrated players sort last.
  static Future<List<Map<String, dynamic>>> searchPlayers(String query) async {
    try {
      var q = _db
          .from('profiles')
          .select('id, name, username, gender, avatar_url, '
              'player_ratings(rating, level, tier)')
          .eq('is_admin', false)
          .neq('id', _uid ?? '');
      final term = query.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
      if (term.isNotEmpty) q = q.ilike('username', '%$term%');
      final rows = await q.limit(50);
      final flat = [
        for (final r in (rows as List))
          flattenRatings(Map<String, dynamic>.from(r as Map))
      ]..sort((a, b) =>
          ((b['rating'] as num?) ?? -1).compareTo((a['rating'] as num?) ?? -1));
      return flat.take(20).toList();
    } catch (e) {
      debugPrint('[MatchService] searchPlayers: $e');
      return [];
    }
  }

  // ── Create / join / leave ────────────────────────────────────────────────

  /// Fires whenever the roster of [matchId] changes — someone joins, leaves,
  /// or an invited partner accepts.
  ///
  /// Emits the raw `match_players` rows, which the lobby ignores: it re-reads
  /// the whole match instead. The rows here carry no embedded profile (a
  /// realtime stream can't join), and a lobby needs names, levels and the
  /// match's own status, which flips to 'full' on the fourth player.
  ///
  /// Realtime must be enabled for `match_players` in Supabase, same as
  /// `direct_messages` and `ticket_messages`. If it isn't, this simply never
  /// fires and the screen still refreshes on resume and on pull — so a missing
  /// publication degrades quietly instead of breaking the lobby.
  static Stream<List<Map<String, dynamic>>> rosterStream(String matchId) {
    return _db
        .from('match_players')
        .stream(primaryKey: ['id'])
        .eq('match_id', matchId)
        .map((rows) => List<Map<String, dynamic>>.from(rows));
  }

  /// Host (or admin) cancels their own match. Returns an error or null.
  static Future<String?> cancelMatch(String matchId) async {
    try {
      final res = await _db.rpc('cancel_match', params: {'p_match_id': matchId});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Fire-and-forget sweep: cancels open matches that never filled past their
  /// grace window (fallback for when pg_cron isn't scheduling the server sweep).
  static Future<void> expireStaleMatches() async {
    try {
      await _db.rpc('expire_stale_matches');
    } catch (_) {/* best-effort */}
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

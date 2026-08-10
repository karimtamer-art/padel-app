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
      'courts(name, venue_name, lat, lng, address), '
      'match_players(player_id, team, elo_before, elo_after, '
      '  profiles(id, name, elo, level, tier, phone, username))';

  // ── Matchmaking discovery (band-gatekept) ──────────────────────────────────

  /// Candidate matches inside the caller's rating band (+ city + time window),
  /// via the SECURITY DEFINER `mm_candidates` RPC. There is NO public browse —
  /// this is the only way to see a match you're not already in. Returns flat
  /// rows: match_id, scheduled_at, match_type, court_name, venue_name, city,
  /// creator_id/name/rating/level, players, center_rating, level_match_pct.
  ///
  /// Optional [from]/[to] restrict candidates to matches scheduled inside that
  /// window (the player's chosen day + time range). When both are null the
  /// server uses its default rolling window (next `mm_time_window_hours`).
  static Future<List<Map<String, dynamic>>> fetchBandCandidates(
      {int limit = 10, DateTime? from, DateTime? to}) async {
    try {
      final rows = await _db.rpc('mm_candidates', params: {
        'p_limit': limit,
        'p_from': from?.toUtc().toIso8601String(),
        'p_to': to?.toUtc().toIso8601String(),
      });
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
  static Future<int> countCandidates({DateTime? from, DateTime? to}) async {
    try {
      final n = await _db.rpc('mm_count_candidates', params: {
        'p_from': from?.toUtc().toIso8601String(),
        'p_to': to?.toUtc().toIso8601String(),
      });
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

  // ── Background search ticket ────────────────────────────────────────────────

  /// Persist that the player is searching (a ticket) so matchmaking keeps
  /// running server-side while the app is closed and pushes when a match
  /// appears. Best-effort.
  static Future<void> startSearch() async {
    try {
      await _db.rpc('mm_start_search');
    } catch (e) {
      debugPrint('[MatchService] startSearch: $e');
    }
  }

  /// Stop searching (drop the ticket). Best-effort.
  static Future<void> cancelSearch() async {
    try {
      await _db.rpc('mm_cancel_search');
    } catch (e) {
      debugPrint('[MatchService] cancelSearch: $e');
    }
  }

  /// Whether the player has a fresh active search ticket — used on launch to
  /// resume the radar hero after a background push. TTL mirrors
  /// `mm_ticket_ttl_hours` (default 6h).
  static Future<bool> isSearching() async {
    final uid = _uid;
    if (uid == null) return false;
    try {
      final row = await _db
          .from('matchmaking_tickets')
          .select('created_at')
          .eq('player_id', uid)
          .maybeSingle();
      if (row == null) return false;
      final ts = DateTime.tryParse(row['created_at'] as String? ?? '');
      if (ts == null) return true;
      return DateTime.now().difference(ts) < const Duration(hours: 6);
    } catch (e) {
      debugPrint('[MatchService] isSearching: $e');
      return false;
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

  /// Invites waiting on ME. Dead ones (match started, filled or cancelled) are
  /// filtered server-side.
  static Future<List<Map<String, dynamic>>> myInvites() async {
    try {
      final rows = await _db.rpc('my_match_invites');
      return List<Map<String, dynamic>>.from(rows as List);
    } catch (e) {
      debugPrint('[MatchService] myInvites: $e');
      return [];
    }
  }

  /// Accept or decline a partner invite. Returns an error message or null.
  /// Accepting is what actually inserts the match_players row.
  static Future<String?> respondToInvite(String inviteId,
      {required bool accept}) async {
    try {
      final res = await _db.rpc('respond_match_invite',
          params: {'p_invite': inviteId, 'p_accept': accept});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Active courts for the create flow. Only public courts are offered to
  /// players — organizer courts (is_public = false) stay inside the community.
  /// Falls back to the unfiltered query on pre-migration DBs without is_public.
  static Future<List<Map<String, dynamic>>> fetchCourts() async {
    List rows;
    // Select * (not a named column list) so a stale PostgREST schema cache
    // can't 400 the whole query on a newly-added column (area/city/indoor);
    // the tile reads those fields defensively. Mirrors the admin courts fetch.
    try {
      rows = await _db
          .from('courts')
          .select('*')
          .eq('is_public', true)
          .order('venue_name');
    } catch (_) {
      try {
        rows = await _db.from('courts').select('*').order('venue_name');
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
          .select('id, name, username, elo, level, tier, gender')
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
      // Atomic: matches + match_players are inserted together server-side, so a
      // match can never be created without its creator/partner. (Direct client
      // match_players inserts are blocked by RLS — hence the RPC.)
      final id = await _db.rpc('create_match', params: {
        'p_competitive': competitive,
        'p_scheduled_at': scheduledAt.toUtc().toIso8601String(),
        'p_court_id': courtId,
        'p_partner_id': partnerId,
        'p_min_elo': minElo,
        'p_open': open,
      });
      return (null, id as String?);
    } on PostgrestException catch (e) {
      return (e.message, null);
    } catch (e) {
      return (e.toString(), null);
    }
  }

  /// Accept a surfaced matchmaking candidate — race-safe join that re-checks the
  /// band server-side. Returns an error message or null. Use this from the
  /// matchmaking flow instead of [joinMatch] (which is the plain capacity join).
  /// [partnerId] brings a chosen partner onto your side (both take one team);
  /// null joins solo and pairs you with a random player.
  static Future<String?> acceptCandidate(String matchId, {String? partnerId}) async {
    try {
      final res = await _db.rpc('mm_accept',
          params: {'p_match_id': matchId, 'p_partner_id': partnerId});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Race-safe join via RPC. Returns an error message or null.
  /// [partnerId] brings a chosen partner onto your side; null joins solo.
  static Future<String?> joinMatch(String matchId, {String? partnerId}) async {
    try {
      final res = await _db.rpc('join_match',
          params: {'p_match_id': matchId, 'p_partner_id': partnerId});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
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

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Tournament + ranking I/O for the player app.
class TournamentService {
  TournamentService._();
  static SupabaseClient get _db => Supabase.instance.client;
  static String? get _uid => _db.auth.currentUser?.id;

  // Entries read names from the denormalised player_name/partner_name columns
  // instead of a profiles join — that join relied on an FK *hint* that doesn't
  // always resolve, and when it failed the whole tournament query fell back to
  // a no-entries result (so "am I registered?" / spot counts broke).
  static const _cols =
      'id, name, venue_name, status, start_date, end_date, start_time, capacity, '
      'entry_fee, prize_pool, description, min_elo, max_elo, format, format_note, best_of, '
      'tournament_entries(id, player_id, player_name, partner_id, partner_name, status)';

  // Fallback for a pre-migration DB: no entries join, no max_elo — but still
  // selects the display fields (prize, about, best_of) so cards/detail render.
  static const _colsPlain =
      'id, name, venue_name, status, start_date, end_date, capacity, '
      'entry_fee, prize_pool, description, min_elo, best_of';

  /// All visible tournaments, soonest first. Falls back to a plain query
  /// (no entries join) so the tab still works before the migration runs.
  static Future<List<Map<String, dynamic>>> fetchTournaments() async {
    try {
      final rows = await _db
          .from('tournaments')
          .select(_cols)
          .order('start_date', ascending: true);
      return List<Map<String, dynamic>>.from(rows as List);
    } catch (e) {
      debugPrint('[TournamentService] fetchTournaments (rich): $e — falling back');
      try {
        final rows = await _db
            .from('tournaments')
            .select(_colsPlain)
            .order('start_date', ascending: true);
        return List<Map<String, dynamic>>.from(rows as List);
      } catch (e2) {
        debugPrint('[TournamentService] fetchTournaments (plain): $e2');
        return [];
      }
    }
  }

  static Future<Map<String, dynamic>?> fetchTournament(String id) async {
    try {
      final row =
          await _db.from('tournaments').select(_cols).eq('id', id).maybeSingle();
      return row == null ? null : Map<String, dynamic>.from(row);
    } catch (e) {
      debugPrint('[TournamentService] fetchTournament (rich): $e — falling back');
      try {
        final row = await _db
            .from('tournaments')
            .select(_colsPlain)
            .eq('id', id)
            .maybeSingle();
        return row == null ? null : Map<String, dynamic>.from(row);
      } catch (e2) {
        debugPrint('[TournamentService] fetchTournament (plain): $e2');
        return null;
      }
    }
  }

  /// Tournaments the current user has registered for.
  static Future<List<Map<String, dynamic>>> fetchMyEntries() async {
    final uid = _uid;
    if (uid == null) return [];
    try {
      final rows = await _db
          .from('tournament_entries')
          .select('id, status, partner_name, registered_at, '
              'tournaments(id, name, venue_name, status, start_date, end_date, capacity, entry_fee)')
          .eq('player_id', uid)
          .order('registered_at', ascending: false);
      return List<Map<String, dynamic>>.from(rows as List);
    } catch (e) {
      debugPrint('[TournamentService] fetchMyEntries: $e');
      return [];
    }
  }

  /// Registers the current user as a pair (partner picked in-app or named).
  /// All eligibility checks (capacity, level, deadline) run server-side in the
  /// `register_for_tournament` RPC so a crafted API call can't bypass them.
  /// Returns an error message or null.
  static Future<String?> register(String tournamentId,
      {String? partnerId,
      String? partnerName,
      String? instapaySender,
      String? instapayProofUrl}) async {
    final uid = _uid;
    if (uid == null) return 'Not signed in.';
    try {
      final res = await _db.rpc('register_for_tournament', params: {
        'p_tournament_id': tournamentId,
        'p_partner_id': partnerId,
        'p_partner_name': partnerName,
        'p_instapay_sender': instapaySender,
        'p_instapay_proof_url': instapayProofUrl,
      });
      return res as String?;
    } on PostgrestException catch (e) {
      if (e.code == '23505') return "You're already registered.";
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Would withdrawing *now* refund the entry fee? Eligible only strictly
  /// before the start date — withdrawing on the start day (or later) forfeits.
  /// Mirrors the server rule in `withdraw_from_tournament`.
  static bool refundableNow(Map<String, dynamic> t) {
    final start = DateTime.tryParse((t['start_date'] as String?) ?? '');
    if (start == null) return true;
    final now = DateTime.now();
    final startDay = DateTime(start.year, start.month, start.day);
    final today = DateTime(now.year, now.month, now.day);
    return today.isBefore(startDay);
  }

  /// Bracket matches for a tournament, with pair names resolved.
  static Future<List<Map<String, dynamic>>> fetchBracket(
      String tournamentId) async {
    try {
      final rows = await _db
          .from('tournament_matches')
          .select('id, bracket, round, slot, winner_entry, score, '
              'e1:tournament_entries!tournament_matches_entry1_fkey(id, player_name, partner_name), '
              'e2:tournament_entries!tournament_matches_entry2_fkey(id, player_name, partner_name)')
          .eq('tournament_id', tournamentId)
          .order('bracket')
          .order('round')
          .order('slot');
      return List<Map<String, dynamic>>.from(rows as List);
    } catch (e) {
      debugPrint('[TournamentService] fetchBracket: $e');
      return [];
    }
  }

  /// "A. Hassan / R. Samir" style label for an entry map from [fetchBracket].
  static String pairLabel(Map<String, dynamic>? entry) {
    if (entry == null) return 'TBD';
    String short(String? full) {
      if (full == null || full.trim().isEmpty) return '?';
      final parts = full.trim().split(RegExp(r'\s+'));
      if (parts.length == 1) return parts[0];
      return '${parts.first[0]}. ${parts.last}';
    }

    final p1 = short(entry['player_name'] as String?);
    final p2raw = entry['partner_name'] as String?;
    if (p2raw == null || p2raw.trim().isEmpty) return p1;
    return '$p1 / ${short(p2raw)}';
  }

  /// Withdraws the current user's pair. The refund decision (entry fee back
  /// only if withdrawing before the start date) is made server-side.
  static Future<String?> withdraw(String tournamentId) async {
    final uid = _uid;
    if (uid == null) return 'Not signed in.';
    try {
      final res = await _db.rpc('withdraw_from_tournament',
          params: {'p_tournament_id': tournamentId});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// True if [uid] is an active participant in [entries] — either the
  /// registrant (`player_id`) or the named partner (`partner_id`) — ignoring
  /// withdrawn rows. A player added as someone's partner counts as "in", so
  /// they can't register again and their cards show the registered state.
  static bool isParticipant(List<dynamic>? entries, String? uid) {
    if (uid == null || entries == null) return false;
    for (final e in entries) {
      final m = e as Map;
      if (m['status'] == 'withdrawn') continue;
      if (m['player_id'] == uid || m['partner_id'] == uid) return true;
    }
    return false;
  }

  /// True only if [uid] is the registrant (the one who can withdraw the pair).
  static bool isRegistrant(List<dynamic>? entries, String? uid) {
    if (uid == null || entries == null) return false;
    for (final e in entries) {
      final m = e as Map;
      if (m['status'] == 'withdrawn') continue;
      if (m['player_id'] == uid) return true;
    }
    return false;
  }

  /// Derives the effective display status from a tournament map + entry count.
  /// The `status` DB column is only authoritative for 'cancelled' / 'postponed'.
  /// Everything else is computed from dates and capacity so legacy rows
  /// ('upcoming', 'open', 'completed', 'auto') all behave correctly.
  static String tournamentStatus(Map<String, dynamic> t, int entryCount) {
    final col = (t['status'] as String?) ?? '';
    if (col == 'cancelled') return 'cancelled';
    if (col == 'postponed') return 'postponed';
    final now = DateTime.now();
    final start = DateTime.tryParse((t['start_date'] as String?) ?? '');
    final end = DateTime.tryParse((t['end_date'] as String?) ?? '');
    final deadline = end ?? start;
    if (deadline != null && now.isAfter(deadline)) return 'completed';
    if (start != null && !now.isBefore(start)) return 'live';
    final cap = (t['capacity'] as num?)?.toInt() ?? 0;
    if (cap > 0 && entryCount >= cap) return 'full';
    return 'open';
  }

  /// Live leaderboard: top players by ELO (admins excluded).
  static Future<List<Map<String, dynamic>>> fetchLeaderboard(
      {int limit = 50}) async {
    try {
      final rows = await _db
          .from('profiles')
          .select('id, name, elo, tier, level')
          .eq('is_admin', false)
          .order('elo', ascending: false)
          .limit(limit);
      return List<Map<String, dynamic>>.from(rows as List);
    } catch (e) {
      debugPrint('[TournamentService] fetchLeaderboard: $e');
      return [];
    }
  }
}

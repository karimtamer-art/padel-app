import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Tournament + ranking I/O for the player app.
class TournamentService {
  TournamentService._();
  static SupabaseClient get _db => Supabase.instance.client;
  static String? get _uid => _db.auth.currentUser?.id;

  static const _cols =
      'id, name, venue_name, status, start_date, end_date, capacity, '
      'entry_fee, prize_pool, description, min_elo, format, best_of, '
      'tournament_entries(id, player_id, partner_id, partner_name, status, '
      '  profiles!tournament_entries_player_id_fkey(name, elo, level, tier))';

  static const _colsPlain =
      'id, name, venue_name, status, start_date, capacity, entry_fee';

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
      debugPrint('[TournamentService] fetchTournament: $e');
      return null;
    }
  }

  /// Tournaments the current user has registered for.
  static Future<List<Map<String, dynamic>>> fetchMyEntries() async {
    final uid = _uid;
    if (uid == null) return [];
    try {
      final rows = await _db
          .from('tournament_entries')
          .select('id, status, partner_name, created_at, '
              'tournaments(id, name, venue_name, status, start_date, entry_fee)')
          .eq('player_id', uid)
          .order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(rows as List);
    } catch (e) {
      debugPrint('[TournamentService] fetchMyEntries: $e');
      return [];
    }
  }

  /// Registers the current user as a pair (partner picked in-app or named).
  /// Returns an error message or null.
  static Future<String?> register(String tournamentId,
      {String? partnerId, String? partnerName}) async {
    final uid = _uid;
    if (uid == null) return 'Not signed in.';
    try {
      final t = await _db
          .from('tournaments')
          .select('capacity, status, min_elo, tournament_entries(count)')
          .eq('id', tournamentId)
          .single();
      final status = (t['status'] as String?) ?? '';
      if (status != 'open' && status != 'upcoming') {
        return 'Registration is closed for this tournament.';
      }
      final cap = (t['capacity'] as num?)?.toInt() ?? 0;
      final entries = (t['tournament_entries'] as List?) ?? const [];
      final count = entries.isNotEmpty
          ? (entries.first['count'] as num?)?.toInt() ?? 0
          : 0;
      if (cap > 0 && count >= cap) return 'This tournament is full.';

      // eligibility
      final minElo = (t['min_elo'] as num?)?.toInt() ?? 0;
      if (minElo > 0) {
        final me = await _db
            .from('profiles')
            .select('elo')
            .eq('id', uid)
            .single();
        if (((me['elo'] as num?)?.toInt() ?? 1000) < minElo) {
          return "This event has a minimum level you haven't reached yet.";
        }
      }

      await _db.from('tournament_entries').upsert({
        'tournament_id': tournamentId,
        'player_id': uid,
        'partner_id': partnerId,
        'partner_name': partnerName,
        'status': 'registered',
      }, onConflict: 'tournament_id,player_id');
      return null;
    } on PostgrestException catch (e) {
      if (e.code == '23505') return "You're already registered.";
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Bracket matches for a tournament, with pair names resolved.
  static Future<List<Map<String, dynamic>>> fetchBracket(
      String tournamentId) async {
    try {
      final rows = await _db
          .from('tournament_matches')
          .select('id, bracket, round, slot, winner_entry, score, '
              'e1:tournament_entries!tournament_matches_entry1_fkey(id, partner_name, '
              '  profiles!tournament_entries_player_id_fkey(name), '
              '  partner:profiles!tournament_entries_partner_id_fkey(name)), '
              'e2:tournament_entries!tournament_matches_entry2_fkey(id, partner_name, '
              '  profiles!tournament_entries_player_id_fkey(name), '
              '  partner:profiles!tournament_entries_partner_id_fkey(name))')
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

    final p1 = short((entry['profiles'] as Map?)?['name'] as String?);
    final partnerProfile = (entry['partner'] as Map?)?['name'] as String?;
    final partnerName = entry['partner_name'] as String?;
    final p2raw = partnerProfile ?? partnerName;
    if (p2raw == null || p2raw.trim().isEmpty) return p1;
    return '$p1 / ${short(p2raw)}';
  }

  static Future<String?> withdraw(String tournamentId) async {
    final uid = _uid;
    if (uid == null) return 'Not signed in.';
    try {
      await _db
          .from('tournament_entries')
          .update({'status': 'withdrawn'})
          .eq('tournament_id', tournamentId)
          .eq('player_id', uid);
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
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

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Centralised Supabase access for the admin console.
/// All methods return raw maps so screens can evolve their models independently.
class AdminService {
  AdminService._();
  static SupabaseClient get _db => Supabase.instance.client;

  // ── Players ───────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> fetchPlayers() async {
    final res = await _db
        .from('profiles')
        .select(
            'id, name, phone, city, avatar_url, elo, tier, division_pts, '
            'level, placement_played, status, verified, is_admin, created_at')
        .eq('is_admin', false)
        .order('elo', ascending: false);
    return List<Map<String, dynamic>>.from(res as List);
  }

  static Future<void> setPlayerStatus(String id, String status) async {
    await _db.from('profiles').update({'status': status}).eq('id', id);
  }

  static Future<void> setPlayerEloTier(
      String id, int elo, String tier) async {
    await _db
        .from('profiles')
        .update({'elo': elo, 'tier': tier}).eq('id', id);
  }

  // ── Dashboard stats ───────────────────────────────────────────

  static Future<Map<String, int>> fetchDivisionCounts() async {
    final res = await _db
        .from('profiles')
        .select('tier')
        .eq('is_admin', false);
    final counts = <String, int>{};
    for (final row in List<Map<String, dynamic>>.from(res as List)) {
      final tier = (row['tier'] as String?) ?? 'bronze';
      counts[tier] = (counts[tier] ?? 0) + 1;
    }
    return counts;
  }

  static Future<List<int>> fetchWeeklyMatchCounts() async {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final weekStart = DateTime(monday.year, monday.month, monday.day);
    final res = await _db
        .from('matches')
        .select('scheduled_at')
        .gte('scheduled_at', weekStart.toIso8601String());
    final counts = List<int>.filled(7, 0);
    for (final row in List<Map<String, dynamic>>.from(res as List)) {
      final iso = row['scheduled_at'] as String?;
      if (iso == null) continue;
      try {
        final idx = DateTime.parse(iso).toLocal().weekday - 1;
        if (idx >= 0 && idx < 7) counts[idx]++;
      } catch (_) {}
    }
    return counts;
  }

  static Future<Map<String, int>> fetchDashboardCounts() async {
    try {
      final players =
          await _db.from('profiles').select('id').count();
      final courts =
          await _db.from('courts').select('id').count();
      final tournaments =
          await _db.from('tournaments').select('id').count();
      final matches =
          await _db.from('matches').select('id').count();
      return {
        'players': players.count,
        'courts': courts.count,
        'tournaments': tournaments.count,
        'matches': matches.count,
      };
    } catch (e) {
      debugPrint('[AdminService] fetchDashboardCounts: $e');
      return {'players': 0, 'courts': 0, 'tournaments': 0, 'matches': 0};
    }
  }

  // ── Courts ────────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> fetchCourts() async {
    final res = await _db
        .from('courts')
        .select('*')
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(res as List);
  }

  static Future<void> setCourt(Map<String, dynamic> data) async {
    await _db.from('courts').upsert(data, onConflict: 'id');
  }

  static Future<void> deleteCourt(String id) async {
    await _db.from('courts').delete().eq('id', id);
  }

  // ── Matches ───────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> fetchMatches(
      {int limit = 50}) async {
    final res = await _db
        .from('matches')
        .select('*, profiles!matches_created_by_fkey(name)')
        .order('scheduled_at', ascending: false)
        .limit(limit);
    return List<Map<String, dynamic>>.from(res as List);
  }

  // ── Tournaments ───────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> fetchTournaments() async {
    final res = await _db
        .from('tournaments')
        .select('*, tournament_entries(count)')
        .order('start_date', ascending: false);
    return List<Map<String, dynamic>>.from(res as List);
  }

  static Future<String?> upsertTournament(Map<String, dynamic> data) async {
    try {
      await _db.from('tournaments').upsert(data, onConflict: 'id');
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  static Future<void> deleteTournament(String id) async {
    await _db.from('tournaments').delete().eq('id', id);
  }

  /// (Re)generates the knockout draw from registered pairs. Error or null.
  static Future<String?> generateDraw(String tournamentId) async {
    try {
      final res = await _db
          .rpc('generate_draw', params: {'p_tournament_id': tournamentId});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Records a bracket-match winner; the engine advances pairs. Error or null.
  static Future<String?> recordBracketWinner(String matchId, String winnerEntry,
      {String? score}) async {
    try {
      final res = await _db.rpc('record_bracket_winner', params: {
        'p_match_id': matchId,
        'p_winner': winnerEntry,
        'p_score': score,
      });
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  static Future<List<Map<String, dynamic>>> fetchBracket(
      String tournamentId) async {
    try {
      final rows = await _db
          .from('tournament_matches')
          .select('id, bracket, round, slot, winner_entry, score, '
              'e1:tournament_entries!tournament_matches_entry1_fkey(id, partner_name, '
              '  profiles!tournament_entries_player_id_fkey(name)), '
              'e2:tournament_entries!tournament_matches_entry2_fkey(id, partner_name, '
              '  profiles!tournament_entries_player_id_fkey(name))')
          .eq('tournament_id', tournamentId)
          .order('bracket')
          .order('round')
          .order('slot');
      return List<Map<String, dynamic>>.from(rows as List);
    } catch (_) {
      return [];
    }
  }

  // ── Products ──────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> fetchProducts() async {
    final res = await _db
        .from('products')
        .select('*, product_costs(cost)')
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(res as List);
  }

  static Future<void> upsertProduct(Map<String, dynamic> data) async {
    final cost = data['cost'];
    final productData = Map<String, dynamic>.from(data)..remove('cost');
    final res = await _db
        .from('products')
        .upsert(productData, onConflict: 'id')
        .select('id')
        .single();
    if (cost != null) {
      await _db.from('product_costs').upsert({
        'product_id': res['id'] as String,
        'cost': cost,
      }, onConflict: 'product_id');
    }
  }

  static Future<void> deleteProduct(String id) async {
    await _db.from('products').delete().eq('id', id);
  }

  // ── Orders ────────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> fetchOrders(
      {int limit = 50}) async {
    final res = await _db
        .from('orders')
        .select('*, profiles!orders_player_id_fkey(name)')
        .order('created_at', ascending: false)
        .limit(limit);
    return List<Map<String, dynamic>>.from(res as List);
  }

  // ── Repair requests ───────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> fetchRepairs() async {
    final res = await _db
        .from('repair_requests')
        .select('*, profiles!repair_requests_player_id_fkey(name, phone)')
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(res as List);
  }

  static Future<void> updateRepair(String id, Map<String, dynamic> data) async {
    await _db.from('repair_requests').update(data).eq('id', id);
  }

  // ── Trade requests ────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> fetchTrades() async {
    final res = await _db
        .from('trade_requests')
        .select('*, profiles!trade_requests_player_id_fkey(name, phone)')
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(res as List);
  }

  static Future<void> updateTrade(String id, Map<String, dynamic> data) async {
    await _db.from('trade_requests').update(data).eq('id', id);
  }

  // ── Broadcasts ────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> fetchBroadcasts() async {
    final res = await _db
        .from('broadcasts')
        .select('*')
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(res as List);
  }

  static Future<void> createBroadcast({
    required String title,
    required String body,
    required String segment,
    required String adminId,
  }) async {
    await _db.from('broadcasts').insert({
      'title': title,
      'body': body,
      'segment': segment,
      'admin_id': adminId,
      'sent_at': DateTime.now().toIso8601String(),
    });
  }
}

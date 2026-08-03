import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../backend/models/format_model.dart';

/// Centralised Supabase access for the admin console.
/// All methods return raw maps so screens can evolve their models independently.
class AdminService {
  AdminService._();
  static SupabaseClient get _db => Supabase.instance.client;

  // ── Players ───────────────────────────────────────────────────

  /// Rich players feed for the console: rating v2 + win/loss + last-active +
  /// email + global rank, all real (server RPC). Falls back to [fetchPlayers]
  /// on pre-migration databases so the tab still renders.
  static Future<List<Map<String, dynamic>>> playersConsole() async {
    try {
      final res = await _db.rpc('admin_players_console');
      return List<Map<String, dynamic>>.from((res as List)
          .map((e) => Map<String, dynamic>.from(e as Map)));
    } catch (_) {
      return fetchPlayers();
    }
  }

  static Future<List<Map<String, dynamic>>> fetchPlayers() async {
    const base = 'id, name, phone, city, avatar_url, elo, tier, division_pts, '
        'level, placement_played, status, verified, is_admin, created_at';
    // Rating engine v2 columns; fall back for pre-migration databases.
    try {
      final res = await _db
          .from('profiles')
          .select('$base, rating, sigma, is_anchor, competitive_matches, '
              'is_provisional, reliability')
          .eq('is_admin', false)
          .order('elo', ascending: false);
      return List<Map<String, dynamic>>.from(res as List);
    } catch (_) {
      final res = await _db
          .from('profiles')
          .select(base)
          .eq('is_admin', false)
          .order('elo', ascending: false);
      return List<Map<String, dynamic>>.from(res as List);
    }
  }

  /// Ban / unban / flag a player. profiles.status is service-role-only, so a
  /// direct client update was a silent no-op (RLS matched 0 rows) — this goes
  /// through the SECURITY DEFINER `admin_set_status` RPC. Returns an error
  /// string or null.
  static Future<String?> setPlayerStatus(String id, String status) async {
    try {
      final res = await _db.rpc('admin_set_status',
          params: {'p_player_id': id, 'p_status': status});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Seeds/overrides a player's rating via the server RPC (keeps ELO writes in
  /// Postgres, and derives level+tier + marks the player ranked). Returns an
  /// error string or null.
  static Future<String?> setPlayerRating(String id, int elo) async {
    try {
      final res = await _db.rpc('admin_set_player_rating',
          params: {'p_player_id': id, 'p_elo': elo});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Rating engine v2: hand-set a player's 0..7 [rating] with an explicit
  /// [sigma] and [isAnchor] flag (server derives level/tier, logs audit_log).
  /// Two console actions map here: Mark anchor (isAnchor, sigma 0.30) and
  /// Leveling session (sigma 0.50). Returns an error string or null.
  static Future<String?> setRating(
    String id, {
    required double rating,
    required double sigma,
    required bool isAnchor,
    String? notes,
  }) async {
    try {
      final res = await _db.rpc('admin_set_rating', params: {
        'p_player_id': id,
        'p_rating': rating,
        'p_sigma': sigma,
        'p_is_anchor': isAnchor,
        'p_notes': notes,
      });
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  // ── Dashboard stats ───────────────────────────────────────────

  /// Per-tier player breakdown for the Division split card. Backed by the same
  /// admin RPC as the counts (bypasses RLS), so it can't be filtered to empty.
  static Future<Map<String, int>> fetchDivisionCounts() async {
    try {
      final res = await _db.rpc('admin_dashboard_counts');
      final divisions = ((res as Map?)?['divisions'] as Map?) ?? const {};
      return divisions.map((k, v) => MapEntry(k as String, (v as num).toInt()));
    } catch (e) {
      debugPrint('[AdminService] fetchDivisionCounts: $e');
      return {};
    }
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

  /// Top-line counts for the Dashboard KPI cards. Backed by a SECURITY DEFINER
  /// RPC doing exact count(*) — not capped at PostgREST's row limit and not
  /// dependent on per-table SELECT policies resolving for the admin.
  static Future<Map<String, int>> fetchDashboardCounts() async {
    try {
      final res = await _db.rpc('admin_dashboard_counts');
      final m = (res as Map?) ?? const {};
      return {
        'players': (m['players'] as num?)?.toInt() ?? 0,
        'courts': (m['courts'] as num?)?.toInt() ?? 0,
        'tournaments': (m['tournaments'] as num?)?.toInt() ?? 0,
        'matches': (m['matches'] as num?)?.toInt() ?? 0,
        // Store money. Absent on a pre-migration DB → the card shows zeroes.
        'revenue': (m['revenue'] as num?)?.toInt() ?? 0,
        'revenue_delivered': (m['revenue_delivered'] as num?)?.toInt() ?? 0,
        'revenue_month': (m['revenue_month'] as num?)?.toInt() ?? 0,
        'orders': (m['orders'] as num?)?.toInt() ?? 0,
      };
    } catch (e) {
      debugPrint('[AdminService] fetchDashboardCounts: $e');
      return {};
    }
  }

  // ── Courts ────────────────────────────────────────────────────

  /// All courts (admin) or just one organizer's own courts when [ownerId] is
  /// set. Pre-migration DBs without owner_id fall back to selecting all. In the
  /// admin view, owner-owned courts are tagged with `owner_label` (the owning
  /// community's name, else the organizer's name) so the console shows which
  /// community a court belongs to.
  static Future<List<Map<String, dynamic>>> fetchCourts({String? ownerId}) async {
    List<Map<String, dynamic>> courts;
    // Organizer view: their own courts (incl. inactive/community ones) via a
    // SECURITY DEFINER RPC, since courts RLS hides non-active courts from
    // non-admins. Owner is always the caller, so the RPC needs no argument.
    if (ownerId != null) {
      try {
        final res = await _db.rpc('organizer_courts');
        return List<Map<String, dynamic>>.from(res as List);
      } catch (_) {/* fall through to the direct select below */}
    }
    try {
      var q = _db.from('courts').select('*');
      if (ownerId != null) q = q.eq('owner_id', ownerId);
      final res = await q.order('created_at', ascending: false);
      courts = List<Map<String, dynamic>>.from(res as List);
    } catch (_) {
      final res = await _db
          .from('courts')
          .select('*')
          .order('created_at', ascending: false);
      courts = List<Map<String, dynamic>>.from(res as List);
    }
    // Admin view: label each organizer-owned court with its community/owner.
    if (ownerId == null) {
      final owners = courts
          .map((c) => c['owner_id'])
          .whereType<String>()
          .toSet()
          .toList();
      if (owners.isNotEmpty) {
        try {
          final comms = await _db
              .from('communities')
              .select('organizer_id, name')
              .inFilter('organizer_id', owners);
          final profs = await _db
              .from('profiles')
              .select('id, name')
              .inFilter('id', owners);
          final byComm = {
            for (final r in (comms as List)) r['organizer_id']: r['name']
          };
          final byProf = {for (final r in (profs as List)) r['id']: r['name']};
          for (final c in courts) {
            final oid = c['owner_id'];
            if (oid != null) {
              c['owner_label'] = byComm[oid] ?? byProf[oid] ?? 'Organizer';
            }
          }
        } catch (_) {/* enrichment is best-effort */}
      }
    }
    return courts;
  }

  static Future<void> setCourt(Map<String, dynamic> data) async {
    await _db.from('courts').upsert(data, onConflict: 'id');
  }

  static Future<void> deleteCourt(String id) async {
    await _db.from('courts').delete().eq('id', id);
  }

  /// Publish a court to all players (true) or keep it community-only (false).
  static Future<void> setCourtPublic(String id, bool isPublic) async {
    await _db.from('courts').update({'is_public': isPublic}).eq('id', id);
  }

  // Organizer court management goes through SECURITY DEFINER RPCs (organizers are
  // is_admin=false, so direct writes are blocked by RLS). Return null on success.

  static Future<String?> organizerSaveCourt({
    String? id,
    required String venue,
    required String name,
    required String area,
    String? city,
    required bool indoor,
    num? lat,
    num? lng,
    String? address,
  }) async {
    try {
      await _db.rpc('organizer_save_court', params: {
        'p_id': id,
        'p_venue': venue,
        'p_name': name,
        'p_area': area,
        'p_city': city,
        'p_indoor': indoor,
        'p_lat': lat,
        'p_lng': lng,
        'p_address': address,
      });
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return 'Could not save the court. Try again.';
    }
  }

  static Future<String?> organizerDeleteCourt(String id) async {
    try {
      await _db.rpc('organizer_delete_court', params: {'p_id': id});
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return 'Could not remove the court. Try again.';
    }
  }

  static Future<void> organizerSetCourtMaintenance(String id, bool on) async {
    await _db.rpc('organizer_set_court_maintenance',
        params: {'p_id': id, 'p_on': on});
  }

  static Future<void> organizerSetCourtActive(String id, bool on) async {
    await _db.rpc('organizer_set_court_active', params: {'p_id': id, 'p_on': on});
  }

  // ── Staff provisioning ────────────────────────────────────────

  /// Super admin creates a staff account of any role (username + temp password)
  /// via the `create-staff` Edge Function. Pass [access] to override the role's
  /// default sections. Returns null on success, else a message.
  static Future<String?> createStaff({
    required String name,
    required String username,
    required String password,
    required String role,
    List<String>? access,
    String? scope,
  }) async {
    try {
      final res = await _db.functions.invoke('create-staff', body: {
        'name': name,
        'username': username,
        'password': password,
        'role': role,
        'access': access,
        'scope': scope,
      });
      final data = res.data;
      if (data is Map && data['error'] != null) return data['error'].toString();
      return null;
    } on FunctionException catch (e) {
      final d = e.details;
      if (d is Map && d['error'] != null) return d['error'].toString();
      return 'Could not create account (status ${e.status}).';
    } catch (e) {
      debugPrint('[AdminService] createStaff: $e');
      return 'Could not create account. Try again.';
    }
  }

  /// Clears the forced-reset flag after a provisioned organizer sets a real
  /// password on first login.
  static Future<void> clearMustChangePassword() async {
    try {
      await _db.rpc('clear_must_change_password');
    } catch (e) {
      debugPrint('[AdminService] clearMustChangePassword: $e');
    }
  }

  /// A random, easy-to-read temporary password for a new organizer.
  static String generateTempPassword() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
    final r = Random.secure();
    return List.generate(10, (_) => chars[r.nextInt(chars.length)]).join();
  }

  // ── Matches ───────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> fetchMatches(
      {int limit = 100}) async {
    final res = await _db.rpc('admin_list_matches', params: {'p_limit': limit});
    return List<Map<String, dynamic>>.from(res as List);
  }

  /// Rich console read: matches with court, host, players (name+team), score,
  /// winner, ELO delta. Admin-gated server-side.
  static Future<List<Map<String, dynamic>>> matchesConsole({int limit = 200}) async {
    // Graceful fallback: a transient error (or a pre-migration DB missing the
    // RPC) returns an empty list rather than throwing the whole Matches tab
    // into a red error state. Mirrors playersConsole's resilience.
    try {
      final res = await _db.rpc('admin_matches_console', params: {'p_limit': limit});
      return List<Map<String, dynamic>>.from(res as List);
    } catch (e) {
      debugPrint('[AdminService] matchesConsole: $e');
      return [];
    }
  }

  /// Admin-only: resolve a disputed match — finalize winner + score, recalc ELO,
  /// notify players, log to audit. Returns null on success, else an error.
  static Future<String?> resolveMatch(String id,
      {required String winner, String? scoreA, String? scoreB, String? note}) async {
    try {
      final res = await _db.rpc('admin_resolve_match', params: {
        'p_match_id': id,
        'p_winner': winner,
        'p_score_a': scoreA,
        'p_score_b': scoreB,
        'p_note': note,
      });
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Admin-only: soft-remove a match — marks it 'cancelled' (hidden from players,
  /// kept in the DB) and logs the reason/note to the audit trail. Returns null
  /// on success, else an error message.
  static Future<String?> removeMatch(String id, {String? reason, String? note}) async {
    try {
      final res = await _db.rpc('admin_cancel_match',
          params: {'p_match_id': id, 'p_reason': reason, 'p_note': note});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  // ── Tournaments ───────────────────────────────────────────────

  /// Tournaments (with entries). Pass [organizerId] to scope to one organizer's
  /// own events (the Organizer console view); omit for the full admin list.
  static Future<List<Map<String, dynamic>>> fetchTournaments(
      {String? organizerId}) async {
    var query = _db
        .from('tournaments')
        .select('*, tournament_entries(id, player_id, player_name, '
            'partner_id, partner_name, status, registered_at, '
            'payment_method, paid_amount, instapay_sender, instapay_proof_url, '
            'refund_status, fee_mode, payer_paid, partner_paid, '
            'partner_instapay_sender, partner_instapay_proof_url)');
    if (organizerId != null) query = query.eq('organizer_id', organizerId);
    final res = await query.order('start_date', ascending: false);
    return List<Map<String, dynamic>>.from(res as List);
  }

  /// Confirms the REGISTRANT's share of an entry's InstaPay transfer. For a
  /// 'both' entry that fully pays the pair (→ paid); for a 'split' entry it
  /// clears the payer's half (partner's half verified separately).
  static Future<String?> verifyTournamentEntry(String entryId) =>
      _verifyShare(entryId, 'payer');

  /// Confirms the PARTNER's own half of a split entry.
  static Future<String?> verifyPartnerShare(String entryId) =>
      _verifyShare(entryId, 'partner');

  static Future<String?> _verifyShare(String entryId, String which) async {
    try {
      final res = await _db.rpc('verify_entry_share',
          params: {'p_entry_id': entryId, 'p_which': which});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Rejects a pending entry (no money received) — frees the spot.
  static Future<String?> rejectTournamentEntry(String entryId) =>
      _updateEntry(entryId, {'status': 'withdrawn', 'refund_status': 'none'});

  /// Marks a due refund as processed (admin has sent the money back).
  static Future<String?> refundTournamentEntry(String entryId) =>
      _updateEntry(entryId, {'refund_status': 'refunded'});

  static Future<String?> _updateEntry(
      String entryId, Map<String, dynamic> data) async {
    try {
      await _db.from('tournament_entries').update(data).eq('id', entryId);
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Organizer adds a pair — a real player ([playerId]) or a guest (name only).
  static Future<String?> addTournamentEntry(
    String tournamentId, {
    String? playerId,
    String? playerName,
    String? partnerId,
    String? partnerName,
  }) async {
    try {
      final res = await _db.rpc('organizer_add_entry', params: {
        'p_tournament_id': tournamentId,
        'p_player_id': playerId,
        'p_player_name': playerName,
        'p_partner_id': partnerId,
        'p_partner_name': partnerName,
      });
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Organizer removes an entry (hard-delete pre-draw, else soft-withdraw).
  static Future<String?> removeTournamentEntry(String entryId) async {
    try {
      final res = await _db
          .rpc('organizer_remove_entry', params: {'p_entry_id': entryId});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Active (non-withdrawn) entries for a tournament, for the entry manager.
  static Future<List<Map<String, dynamic>>> tournamentEntries(String tid) async {
    try {
      final rows = await _db
          .from('tournament_entries')
          .select('id, player_id, player_name, partner_id, partner_name, status')
          .eq('tournament_id', tid)
          .order('created_at');
      return List<Map<String, dynamic>>.from(rows as List)
          .where((e) => e['status'] != 'withdrawn')
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Search real players by @username (for linking an app player to an entry).
  static Future<List<Map<String, dynamic>>> searchPlayers(String query) async {
    try {
      var q = _db.from('profiles').select('id, name, username').eq('is_admin', false);
      final term = query.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
      if (term.isNotEmpty) q = q.ilike('username', '%$term%');
      final rows = await q.limit(15);
      return List<Map<String, dynamic>>.from(rows as List);
    } catch (_) {
      return [];
    }
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

  // ── Custom draw building (manual matches for 'custom' format) ──────────────

  static Future<String?> addCustomMatch(
      String tournamentId, String label, String? entry1, String? entry2) async {
    try {
      final res = await _db.rpc('add_custom_match', params: {
        'p_tournament_id': tournamentId,
        'p_label': label,
        'p_entry1': entry1,
        'p_entry2': entry2,
      });
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Set (or clear, with null) a match winner without advancing rounds.
  static Future<String?> setMatchWinner(String matchId, String? winnerEntry,
      {String? score}) async {
    try {
      final res = await _db.rpc('set_match_winner', params: {
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

  static Future<String?> deleteTournamentMatch(String matchId) async {
    try {
      final res = await _db
          .rpc('delete_tournament_match', params: {'p_match_id': matchId});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  // ── Format Builder ────────────────────────────────────────────

  /// Attach a built format spec to a tournament (marks it a custom format).
  static Future<String?> saveTournamentFormat(
      String tournamentId, FormatSpec spec) async {
    try {
      final res = await _db.rpc('save_tournament_format', params: {
        'p_tournament_id': tournamentId,
        'p_spec': spec.toJson(),
      });
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Build the first stage of the saved format into real matches. [random]
  /// shuffles the field instead of seeding by level.
  static Future<String?> generateFromFormat(String tournamentId,
      {bool random = false}) async {
    try {
      final res = await _db.rpc('generate_from_format',
          params: {'p_tournament_id': tournamentId, 'p_random': random});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Advance the draw: current round → next round, or a completed group/RR
  /// stage → the next stage's knockout, seeded by standings.
  static Future<String?> advanceStage(String tournamentId) async {
    try {
      final res = await _db
          .rpc('advance_stage', params: {'p_tournament_id': tournamentId});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Finalize a tournament: apply ratings for every decided match and mark it
  /// completed. One-shot per tournament. Returns a status message or an error.
  static Future<String?> finalizeTournament(String tournamentId) async {
    try {
      final res = await _db
          .rpc('finalize_tournament', params: {'p_tournament_id': tournamentId});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// The organizer's reusable format library.
  static Future<List<Map<String, dynamic>>> savedFormats() async {
    try {
      final res = await _db
          .from('saved_formats')
          .select('id, name, spec, created_at')
          .order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(res as List);
    } catch (_) {
      return [];
    }
  }

  /// Save a named format to the reusable library.
  static Future<void> saveNamedFormat(FormatSpec spec) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    try {
      await _db.from('saved_formats').insert({
        'organizer_id': uid,
        'name': spec.name,
        'spec': spec.toJson(),
      });
    } catch (e) {
      debugPrint('[AdminService] saveNamedFormat: $e');
    }
  }

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

  /// Upserts a product and returns its id. Any field in [data] is written
  /// through (name, brand, category, description, price, stock, on_sale,
  /// sale_price, is_visible, slug, sku, …); `cost` is split into the
  /// admin-only product_costs table.
  static Future<String> upsertProduct(Map<String, dynamic> data) async {
    final cost = data['cost'];
    final productData = Map<String, dynamic>.from(data)..remove('cost');
    final res = await _db
        .from('products')
        .upsert(productData, onConflict: 'id')
        .select('id')
        .single();
    final id = res['id'] as String;
    if (cost != null) {
      await _db.from('product_costs').upsert({
        'product_id': id,
        'cost': cost,
      }, onConflict: 'product_id');
    }
    return id;
  }

  static Future<void> deleteProduct(String id) async {
    await _db.from('products').delete().eq('id', id);
  }

  /// Units sold, revenue, cost and profit per product, keyed by product id.
  /// Cancelled and refunded orders are excluded server-side. This is what
  /// replaces "stock value" for made-to-order items, which never hold stock.
  static Future<Map<String, Map<String, dynamic>>> productSales() async {
    try {
      final rows = await _db.rpc('admin_product_sales');
      final out = <String, Map<String, dynamic>>{};
      for (final r in List<Map<String, dynamic>>.from(rows as List)) {
        final id = r['product_id'] as String?;
        if (id != null) out[id] = r;
      }
      return out;
    } catch (e) {
      // Pre-migration DB — the console just shows no sales figures.
      return {};
    }
  }

  // ── Product images / storage ──────────────────────────────────

  static const _bucket = 'product-images';

  /// Uploads [bytes] to the public product-images bucket, records the row in
  /// product_images, and returns its public URL. The first image of a product
  /// also becomes the primary (`products.image_url`). [ext] is the extension
  /// without a dot, e.g. 'jpg'.
  static Future<String> uploadProductImage(
      String productId, Uint8List bytes, String ext) async {
    final safeExt = ext.toLowerCase() == 'jpeg' ? 'jpg' : ext.toLowerCase();
    final path =
        'products/$productId/${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(99999)}.$safeExt';
    await _db.storage.from(_bucket).uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(
              contentType: 'image/${safeExt == 'jpg' ? 'jpeg' : safeExt}',
              upsert: true),
        );
    final url = _db.storage.from(_bucket).getPublicUrl(path);

    final existing = await _db
        .from('product_images')
        .select('id')
        .eq('product_id', productId);
    final count = (existing as List).length;
    await _db.from('product_images').insert({
      'product_id': productId,
      'url': url,
      'sort_order': count,
    });
    if (count == 0) {
      await _db.from('products').update({'image_url': url}).eq('id', productId);
    }
    return url;
  }

  static Future<List<Map<String, dynamic>>> fetchProductImages(
      String productId) async {
    final res = await _db
        .from('product_images')
        .select('id, url, sort_order')
        .eq('product_id', productId)
        .order('sort_order');
    return List<Map<String, dynamic>>.from(res as List);
  }

  /// Removes an image (row + Storage object) and, if it was the primary,
  /// promotes the next remaining image (or clears `image_url`).
  static Future<void> removeProductImage(
      String productId, String imageId, String url) async {
    await _db.from('product_images').delete().eq('id', imageId);
    const marker = '/$_bucket/';
    final i = url.indexOf(marker);
    if (i != -1) {
      final storagePath = url.substring(i + marker.length);
      try {
        await _db.storage.from(_bucket).remove([storagePath]);
      } catch (e) {
        debugPrint('[AdminService] removeProductImage storage: $e');
      }
    }
    final prod = await _db
        .from('products')
        .select('image_url')
        .eq('id', productId)
        .maybeSingle();
    if (prod != null && prod['image_url'] == url) {
      final remaining = await fetchProductImages(productId);
      await _db.from('products').update({
        'image_url': remaining.isEmpty ? null : remaining.first['url'],
      }).eq('id', productId);
    }
  }

  static Future<void> setPrimaryImage(String productId, String url) async {
    await _db.from('products').update({'image_url': url}).eq('id', productId);
  }

  // ── Banners / promotions ──────────────────────────────────────

  static const _bannerBucket = 'banner-images';

  /// All banners (active + inactive) for the admin list, newest sort first.
  static Future<List<Map<String, dynamic>>> fetchBanners() async {
    final res = await _db
        .from('banners')
        .select('*')
        .order('sort_order')
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(res as List);
  }

  /// Products currently attached to [bannerId] (its sale set).
  static Future<List<Map<String, dynamic>>> fetchBannerProducts(
      String bannerId) async {
    final res = await _db
        .from('products')
        .select('id, name, brand, price, sale_price')
        .eq('banner_id', bannerId);
    return List<Map<String, dynamic>>.from(res as List);
  }

  /// Inserts/updates a banner and applies its sale to [items] atomically.
  /// [items] is a list of {'product_id': uuid, 'sale_price': int?}; a null
  /// sale_price means "use the percentage". Returns the banner id.
  static Future<String> saveBanner({
    String? id,
    String? title,
    String? subtitle,
    String? imageUrl,
    String? bgColor,
    bool isActive = true,
    int sortOrder = 0,
    int? discountPct,
    required List<Map<String, dynamic>> items,
  }) async {
    final res = await _db.rpc('admin_save_banner', params: {
      'p_id': id,
      'p_title': title,
      'p_subtitle': subtitle,
      'p_image_url': imageUrl,
      'p_bg_color': bgColor,
      'p_is_active': isActive,
      'p_sort_order': sortOrder,
      'p_discount_pct': discountPct,
      'p_items': items,
    });
    return res as String;
  }

  static Future<void> deleteBanner(String id) async {
    await _db.rpc('admin_delete_banner', params: {'p_id': id});
  }

  /// Uploads banner artwork to the public banner-images bucket; returns the URL.
  static Future<String> uploadBannerImage(Uint8List bytes, String ext) async {
    final safeExt = ext.toLowerCase() == 'jpeg' ? 'jpg' : ext.toLowerCase();
    final path =
        'banners/${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(99999)}.$safeExt';
    await _db.storage.from(_bannerBucket).uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(
              contentType: 'image/${safeExt == 'jpg' ? 'jpeg' : safeExt}',
              upsert: true),
        );
    return _db.storage.from(_bannerBucket).getPublicUrl(path);
  }

  // ── Orders ────────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> fetchOrders(
      {int limit = 50}) async {
    // Try the customer-name join; fall back to a plain select if the FK hint
    // can't resolve (a drifted orders table may lack the named constraint), so
    // the orders list never blanks out — names just degrade to 'Unknown'.
    try {
      final res = await _db
          .from('orders')
          .select('*, profiles!orders_player_id_fkey(name)')
          .order('created_at', ascending: false)
          .limit(limit);
      return List<Map<String, dynamic>>.from(res as List);
    } catch (e) {
      debugPrint('[AdminService] fetchOrders join failed, retrying plain: $e');
      final res = await _db
          .from('orders')
          .select('*')
          .order('created_at', ascending: false)
          .limit(limit);
      final orders = List<Map<String, dynamic>>.from(res as List);
      // No FK embed → resolve customer names with a second query and graft them
      // into each row as { profiles: { name } } so the UI reads them uniformly.
      final ids = orders
          .map((o) => o['player_id'] as String?)
          .whereType<String>()
          .toSet()
          .toList();
      if (ids.isNotEmpty) {
        try {
          final people = await _db
              .from('profiles')
              .select('id, name')
              .inFilter('id', ids);
          final byId = {
            for (final p in List<Map<String, dynamic>>.from(people as List))
              p['id'] as String: p['name']
          };
          for (final o in orders) {
            o['profiles'] = {'name': byId[o['player_id']]};
          }
        } catch (_) {}
      }
      return orders;
    }
  }

  /// Advances an order: pending → paid (InstaPay verified / cash collected) →
  /// shipped/delivered, or refunded. Error string or null.
  static Future<String?> updateOrderStatus(String id, String status) async {
    try {
      await _db.from('orders').update({'status': status}).eq('id', id);
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Kills an order WITH a reason. The reason and note must land in the same
  /// UPDATE as the status: `notify_order_status` fires on the status change
  /// and reads them off the new row, so writing them afterwards would send
  /// the player a reasonless message and then silently fix the row.
  static Future<String?> cancelOrder(
    String id, {
    required String status, // 'cancelled' or 'refunded'
    required String reason,
    String? note,
  }) async {
    try {
      final trimmed = note?.trim();
      await _db.from('orders').update({
        'status': status,
        'cancel_reason': reason,
        'cancel_note': (trimmed == null || trimmed.isEmpty) ? null : trimmed,
      }).eq('id', id);
      return null;
    } on PostgrestException catch (e) {
      // The reason columns are the newest part of this flow — a database
      // without the delta should say so, not fail cryptically.
      final m = e.message.toLowerCase();
      if (m.contains('cancel_reason') || m.contains('cancel_note')) {
        return 'Rejection reasons are not set up on this database yet — '
            'run the 2026-08-03_order_cancel_reason delta.';
      }
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Signs the private `trade-photos` paths on a trade-in request so the
  /// console can show the racket. Signing is done in one call; a failure
  /// yields an empty list rather than breaking the sheet.
  static Future<List<String>> signTradePhotoUrls(List<String> paths) async {
    if (paths.isEmpty) return const [];
    try {
      final res =
          await _db.storage.from('trade-photos').createSignedUrls(paths, 3600);
      return [
        for (final r in res)
          if (r.signedUrl.isNotEmpty) r.signedUrl,
      ];
    } catch (e) {
      debugPrint('[AdminService] signTradePhotoUrls: $e');
      return const [];
    }
  }

  /// Signs a private payment-proof storage path so the admin can view the
  /// InstaPay screenshot. Returns null if there's no proof or signing fails.
  static Future<String?> signProofUrl(String? path) async {
    if (path == null || path.isEmpty) return null;
    try {
      return await _db.storage.from('payment-proofs').createSignedUrl(path, 3600);
    } catch (e) {
      debugPrint('[AdminService] signProofUrl: $e');
      return null;
    }
  }

  // ── App settings (key/value) ──────────────────────────────────

  static Future<String?> getSetting(String key) async {
    try {
      final row = await _db
          .from('app_settings')
          .select('value')
          .eq('key', key)
          .maybeSingle();
      return row?['value'] as String?;
    } catch (e) {
      debugPrint('[AdminService] getSetting: $e');
      return null;
    }
  }

  static Future<String?> setSetting(String key, String value) async {
    try {
      await _db.from('app_settings').upsert(
        {'key': key, 'value': value, 'updated_at': DateTime.now().toIso8601String()},
        onConflict: 'key',
      );
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  // ── Admin notifications (private per-admin alerts) ────────────
  // Covers every admin alert type: 'admin_order', 'admin_trade',
  // 'admin_repair', 'admin_tournament'. All share the 'admin_' prefix.

  /// Unread admin alerts for the signed-in admin (badge count).
  static Future<int> adminUnreadCount() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return 0;
    try {
      final res = await _db
          .from('notifications')
          .select('id')
          .eq('user_id', uid)
          .like('type', 'admin_%')
          .eq('read', false);
      return (res as List).length;
    } catch (_) {
      return 0;
    }
  }

  /// Type of the newest unread admin alert, so the bell can route to the right
  /// screen ('admin_order' → Payments, 'admin_trade'/'admin_repair' → Requests,
  /// 'admin_tournament' → Tournaments). Null when there's nothing unread.
  static Future<String?> newestAdminAlertType() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return null;
    try {
      final res = await _db
          .from('notifications')
          .select('type')
          .eq('user_id', uid)
          .like('type', 'admin_%')
          .eq('read', false)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      return res?['type'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Recent admin alerts (read + unread) for the notifications sheet, newest
  /// first. Covers every 'admin_%' type (orders, trade-ins, repairs, tournament
  /// payments).
  static Future<List<Map<String, dynamic>>> recentAdminAlerts(
      {int limit = 30}) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return [];
    try {
      final res = await _db
          .from('notifications')
          .select('id, type, title, body, data, read, created_at')
          .eq('user_id', uid)
          .like('type', 'admin_%')
          .order('created_at', ascending: false)
          .limit(limit);
      return List<Map<String, dynamic>>.from(res as List);
    } catch (_) {
      return [];
    }
  }

  /// Clears the admin's alert badge (all admin alert types).
  static Future<void> markAdminNotificationsRead() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    try {
      await _db
          .from('notifications')
          .update({'read': true})
          .eq('user_id', uid)
          .like('type', 'admin_%')
          .eq('read', false);
    } catch (_) {}
  }

  /// The nav section that surfaces a given admin alert type — drives both the
  /// bell routing and the per-item sidebar badges.
  static String? sectionForAlertType(String? type) => switch (type) {
        'admin_order' => 'payments',
        'admin_trade' || 'admin_repair' => 'requests',
        'admin_tournament' => 'tournaments',
        'admin_community' => 'community',
        _ => null,
      };

  static const Map<String, List<String>> _sectionTypes = {
    'payments': ['admin_order'],
    'requests': ['admin_trade', 'admin_repair'],
    'tournaments': ['admin_tournament'],
    'community': ['admin_community'],
  };

  /// Unread admin-alert counts grouped by nav section ('payments' / 'requests'
  /// / 'tournaments'). Sections with no unread alerts are omitted — used to
  /// badge the sidebar items.
  static Future<Map<String, int>> adminAlertSectionCounts() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return {};
    try {
      final res = await _db
          .from('notifications')
          .select('type')
          .eq('user_id', uid)
          .like('type', 'admin_%')
          .eq('read', false);
      final counts = <String, int>{};
      for (final r in List<Map<String, dynamic>>.from(res as List)) {
        final section = sectionForAlertType(r['type'] as String?);
        if (section != null) counts[section] = (counts[section] ?? 0) + 1;
      }
      return counts;
    } catch (_) {
      return {};
    }
  }

  /// Marks the admin alerts feeding one nav section as read (called when the
  /// admin opens that section).
  static Future<void> markAdminSectionRead(String section) async {
    final uid = _db.auth.currentUser?.id;
    final types = _sectionTypes[section];
    if (uid == null || types == null) return;
    try {
      await _db
          .from('notifications')
          .update({'read': true})
          .eq('user_id', uid)
          .eq('read', false)
          .inFilter('type', types);
    } catch (_) {}
  }

  // ── Repair requests ───────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> fetchRepairs() =>
      _fetchRequests('repair_requests');

  /// Returns an error string, or null on success.
  static Future<String?> updateRepair(
          String id, Map<String, dynamic> data) async =>
      _updateRequest('repair_requests', id, data);

  // ── Trade requests ────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> fetchTrades() =>
      _fetchRequests('trade_requests');

  /// Returns an error string, or null on success.
  static Future<String?> updateTrade(
          String id, Map<String, dynamic> data) async =>
      _updateRequest('trade_requests', id, data);

  // Requests + the submitting player. The embed needs an FK from the request
  // table to `profiles`; both tables originally only had the legacy FK to
  // auth.users, which PostgREST cannot embed — so fall back to a plain read
  // plus a name lookup rather than letting the whole screen fail.
  static Future<List<Map<String, dynamic>>> _fetchRequests(String table) async {
    try {
      final res = await _db
          .from(table)
          .select('*, profiles!${table}_player_profile_fkey(name, phone)')
          .order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(res as List);
    } catch (e) {
      debugPrint('[AdminService] $table join failed, retrying plain: $e');
      final res =
          await _db.from(table).select('*').order('created_at', ascending: false);
      final rows = List<Map<String, dynamic>>.from(res as List);
      final ids = rows
          .map((r) => r['player_id'] as String?)
          .whereType<String>()
          .toSet()
          .toList();
      if (ids.isNotEmpty) {
        try {
          final people =
              await _db.from('profiles').select('id, name, phone').inFilter('id', ids);
          final byId = {
            for (final p in List<Map<String, dynamic>>.from(people as List))
              p['id'] as String: p
          };
          for (final r in rows) {
            final p = byId[r['player_id']];
            if (p != null) {
              r['profiles'] = {'name': p['name'], 'phone': p['phone']};
            }
          }
        } catch (_) {}
      }
      return rows;
    }
  }

  static Future<String?> _updateRequest(
      String table, String id, Map<String, dynamic> data) async {
    try {
      await _db.from(table).update(data).eq('id', id);
      return null;
    } catch (e) {
      debugPrint('[AdminService] $table update failed: $e');
      return e is PostgrestException ? e.message : e.toString();
    }
  }

  // ── Broadcasts ────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> fetchBroadcasts() async {
    final res = await _db
        .from('broadcasts')
        .select('*')
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(res as List);
  }

  /// The organizer's own broadcast history (RLS-scoped to the caller).
  static Future<List<Map<String, dynamic>>> organizerBroadcastsList() async {
    try {
      final res = await _db
          .from('organizer_broadcasts')
          .select('id, title, body, recipients, tournament_id, image_url, created_at')
          .order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(res as List);
    } catch (_) {
      return [];
    }
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

  // ── Team & Roles (RBAC) ───────────────────────────────────────
  // Reads/writes go through SECURITY DEFINER RPCs, gated on the 'team' section
  // server-side. A staffer granted Team can manage people but never mint or
  // edit a super admin, and never grant access they don't hold themselves.

  /// The signed-in staffer's own role + access row (plain own-read select).
  /// Returns null when not signed in. `admin_role` may be null for a legacy
  /// admin whose backfill hasn't run — the caller treats is_admin as super.
  static Future<Map<String, dynamic>?> currentStaff() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return null;
    try {
      final row = await _db
          .from('profiles')
          .select('admin_role, admin_access, admin_scope, is_owner, is_admin')
          .eq('id', uid)
          .maybeSingle();
      return row == null ? null : Map<String, dynamic>.from(row);
    } catch (e) {
      debugPrint('[AdminService] currentStaff error: $e');
      return null;
    }
  }

  /// All staff (admin_role not null) for the Team & Roles directory.
  static Future<List<Map<String, dynamic>>> fetchStaff() async {
    try {
      final res = await _db.rpc('admin_list_staff');
      return List<Map<String, dynamic>>.from(res as List);
    } catch (e) {
      debugPrint('[AdminService] fetchStaff error: $e');
      return [];
    }
  }

  /// Non-staff users matching [term] (name/email), to invite. Empty on <2 chars.
  static Future<List<Map<String, dynamic>>> searchUsers(String term) async {
    if (term.trim().length < 2) return [];
    try {
      final res = await _db.rpc('admin_search_users', params: {'p_term': term.trim()});
      return List<Map<String, dynamic>>.from(res as List);
    } catch (e) {
      debugPrint('[AdminService] searchUsers error: $e');
      return [];
    }
  }

  /// Grant/update a staffer's role + access. Pass [access] = null to use the
  /// role's default set. Returns an error string or null on success.
  static Future<String?> grantRole(
    String userId, {
    required String role,
    List<String>? access,
    String? scope,
  }) async {
    try {
      final res = await _db.rpc('admin_grant_role', params: {
        'p_user': userId,
        'p_role': role,
        'p_access': access,
        'p_scope': scope,
      });
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Remove all console access from a staffer. Returns an error string or null.
  static Future<String?> revokeRole(String userId) async {
    try {
      final res = await _db.rpc('admin_revoke_role', params: {'p_user': userId});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  // ── Organizer console ─────────────────────────────────────────
  // Scoped to the signed-in organizer's own events (server-enforced).

  /// KPI counts for the Organizer Overview home: tournaments, accepting,
  /// entrants, reach, fees, to_verify. Empty map on error/not-organizer.
  static Future<Map<String, dynamic>> organizerOverview() async {
    try {
      final res = await _db.rpc('organizer_overview');
      final map = Map<String, dynamic>.from(res as Map);
      if (map['error'] != null) return {};
      return map;
    } catch (e) {
      debugPrint('[AdminService] organizerOverview error: $e');
      return {};
    }
  }

  /// Broadcast to the organizer's participants (push + in-app). Pass
  /// [tournamentId] to target one event, or null for all their events.
  /// Returns an error string or null on success.
  static Future<String?> organizerBroadcast({
    required String title,
    required String body,
    String? tournamentId,
    String? imageUrl,
  }) async {
    try {
      final res = await _db.rpc('organizer_broadcast', params: {
        'p_title': title,
        'p_body': body,
        'p_tournament_id': tournamentId,
        'p_image_url': imageUrl,
      });
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  // ── Organizer InstaPay payout (username + link) ───────────────────
  /// The signed-in organizer's own InstaPay payout details (nulls if unset).
  static Future<({String? handle, String? link})> fetchMyInstapay() async {
    try {
      final uid = _db.auth.currentUser?.id;
      if (uid == null) return (handle: null, link: null);
      final row = await _db
          .from('profiles')
          .select('instapay_handle, instapay_link')
          .eq('id', uid)
          .maybeSingle();
      return (
        handle: (row?['instapay_handle'] as String?)?.trim(),
        link: (row?['instapay_link'] as String?)?.trim(),
      );
    } catch (_) {
      return (handle: null, link: null);
    }
  }

  /// Sets the organizer's payout username + link. Returns null on success,
  /// else an error string.
  /// InstaPay addresses end in `@instapay`, so the UI only ever asks for the
  /// name and appends this. A user who types a full address keeps it — some
  /// IPAs are issued against a bank (`name@cib`), and forcing @instapay on
  /// those would break the transfer.
  static const instapaySuffix = '@instapay';

  /// What to store: "karim" → "karim@instapay"; "karim@cib" → unchanged;
  /// blank → null.
  static String? normalizeInstapay(String raw) {
    var v = raw.trim();
    if (v.startsWith('@')) v = v.substring(1).trim();
    if (v.isEmpty) return null;
    return v.contains('@') ? v : '$v$instapaySuffix';
  }

  /// What to put in the text field: "karim@instapay" → "karim". A non-instapay
  /// address is shown whole, since its suffix is meaningful.
  static String instapayName(String? stored) {
    final v = (stored ?? '').trim();
    if (v.isEmpty) return '';
    return v.toLowerCase().endsWith(instapaySuffix)
        ? v.substring(0, v.length - instapaySuffix.length)
        : v;
  }

  static Future<String?> setMyInstapay(
      {required String handle, required String link}) async {
    try {
      final res = await _db.rpc('set_my_instapay',
          params: {'p_handle': handle, 'p_link': link});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }
}

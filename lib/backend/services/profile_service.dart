import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/onboarding_models.dart';
import '../models/ranking_scale.dart';
import '../models/mock_data.dart';

/// Reads/writes the onboarding fields on the `profiles` table.
///
/// Pass an instance to [AuthGate]. The static methods (getProfile,
/// updateProfile, ensureProfile) are kept for existing screens.
class ProfileService {
  ProfileService([SupabaseClient? client])
      : _sb = client ?? Supabase.instance.client;

  final SupabaseClient _sb;

  // Both old and new column names — fromJson reads whichever are non-null.
  static const _onbCols =
      'date_of_birth, gender, preferred_hand, preferred_court_side, phone, is_admin';

  /// Current user's profile, or `null` if the row doesn't exist yet.
  /// Selects the RBAC `admin_role` too, falling back for pre-migration DBs that
  /// don't have that column yet (so sign-in never breaks).
  Future<OnboardingProfile?> fetch(String userId) async {
    Map<String, dynamic>? row;
    try {
      row = await _sb
          .from('profiles')
          .select('$_onbCols, admin_role, must_change_password')
          .eq('id', userId)
          .maybeSingle();
    } catch (_) {
      row = await _sb
          .from('profiles')
          .select(_onbCols)
          .eq('id', userId)
          .maybeSingle();
    }
    if (row == null) return null;
    return OnboardingProfile.fromJson(row);
  }

  /// Persists the four onboarding answers. Upsert is safe even if the
  /// signup trigger hasn't created the row yet.
  Future<void> saveOnboarding(String userId, OnboardingProfile profile, {String? name}) async {
    await _sb.from('profiles').upsert(
          profile.toUpsert(userId, name: name),
          onConflict: 'id',
        );
  }

  // ── Static interface — legacy screens ────────────────────────────────────

  static SupabaseClient get _db => Supabase.instance.client;

  static const _profileCols =
      'id, name, username, phone, bio, date_of_birth, gender, preferred_hand, preferred_court_side, city, avatar_url, '
      'elo, tier, division_pts, level, placement_played, created_at';

  /// True when [username] is free (and validly formatted). Backed by the
  /// `username_available` RPC so it works pre-auth during signup. On a network
  /// error returns true — the unique index is the real guard on write.
  static Future<bool> isUsernameAvailable(String username) async {
    try {
      final res = await _db.rpc('username_available',
          params: {'p_username': username.trim().toLowerCase()});
      return res == true;
    } catch (e) {
      debugPrint('[ProfileService] isUsernameAvailable: $e');
      return true;
    }
  }

  static Future<Map<String, dynamic>?> getProfile(String uid) async {
    try {
      final data = await _db.from('profiles').select(_profileCols).eq('id', uid).single();
      return Map<String, dynamic>.from(data);
    } catch (e) {
      debugPrint('[ProfileService] getProfile error: $e');
      return null;
    }
  }

  /// Permanently deletes the signed-in user's account and data via the
  /// `delete_account_self` RPC (SECURITY DEFINER — removes the auth user and
  /// everything that cascades from the profile). Returns null on success, else
  /// an error message. The caller should sign out afterwards.
  static Future<String?> deleteAccount() async {
    try {
      await _db.rpc('delete_account_self');
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Marks the one-time "placement complete" reveal as shown for the signed-in
  /// user, so it never fires again. Best-effort — a failure just means the
  /// player may see it once more next launch. Display-only (never rating math).
  static Future<void> markPlacementRevealed() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    try {
      await _db
          .from('profiles')
          .update({'placement_revealed': true}).eq('id', uid);
    } catch (_) {/* non-fatal */}
  }

  static Future<String?> updateProfile(String uid, Map<String, dynamic> fields) async {
    try {
      await _db.from('profiles').update(fields).eq('id', uid);
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Fetches the full [PlayerProfile] for the Profile screen — ranking,
  /// career stats, ELO history and recent matches — all from live Supabase data.
  static Future<PlayerProfile> fetchPlayerProfile(String userId) async {
    try {
      // Rating v2 adds sigma/reliability/is_provisional; fall back for
      // pre-migration databases that don't have those columns yet.
      dynamic profileRow;
      try {
        profileRow = await _db
            .from('profiles')
            .select('elo, tier, level, placement_played, '
                'reliability, is_provisional, placement_revealed, competitive_matches')
            .eq('id', userId)
            .single();
      } catch (_) {
        profileRow = await _db
            .from('profiles')
            .select('elo, tier, level, placement_played')
            .eq('id', userId)
            .single();
      }

      // Try with creator profile join; fall back without it if FK hint missing.
      List rawMatches;
      try {
        rawMatches = await _db
            .from('match_players')
            .select('''
              team, elo_before, elo_after,
              matches!inner(
                id, status, match_type, scheduled_at, winner_team,
                score_team_a, score_team_b, created_by,
                profiles!matches_created_by_fkey(name)
              )
            ''')
            .eq('player_id', userId)
            .order('created_at', ascending: false)
            .limit(50);
      } catch (_) {
        rawMatches = await _db
            .from('match_players')
            .select('''
              team, elo_before, elo_after,
              matches!inner(
                id, status, match_type, scheduled_at, winner_team,
                score_team_a, score_team_b, created_by
              )
            ''')
            .eq('player_id', userId)
            .order('created_at', ascending: false)
            .limit(50);
      }

      final rows = List<Map<String, dynamic>>.from(rawMatches);
      final completed = rows.where((r) {
        final m = r['matches'] as Map?;
        return m?['status'] == 'completed' && m?['winner_team'] != null;
      }).toList();

      int wins = 0, losses = 0;
      for (final r in completed) {
        final m = r['matches'] as Map;
        if ((r['team'] as String?) == (m['winner_team'] as String?)) {
          wins++;
        } else {
          losses++;
        }
      }
      final played = wins + losses;
      final winRate = played > 0 ? '${(wins / played * 100).round()}%' : '—';

      int streak = 0;
      for (final r in completed) {
        final m = r['matches'] as Map;
        if ((r['team'] as String?) == (m['winner_team'] as String?)) {
          streak++;
        } else {
          break;
        }
      }

      // Rating history — built from ranking_history below (the rating-engine-v2
      // per-match trail). The legacy match_players.elo_after column is no longer
      // written by the v2 settle, so it can't feed the chart.
      List<int> eloPoints = [];

      // Recent 5 completed matches
      final recent = <RecentMatch>[];
      for (final r in completed.take(5)) {
        final m = r['matches'] as Map;
        final myTeam = r['team'] as String?;
        final won = myTeam != null && myTeam == (m['winner_team'] as String?);
        final scoreA = m['score_team_a'] as String?;
        final scoreB = m['score_team_b'] as String?;
        final score = (scoreA != null && scoreB != null)
            ? (myTeam == 'a' ? '$scoreA / $scoreB' : '$scoreB / $scoreA')
            : '—';
        final creatorId = m['created_by'] as String?;
        final creatorName = (m['profiles'] as Map?)?['name'] as String?;
        final opp = (creatorId != null && creatorId != userId && creatorName != null)
            ? creatorName
            : 'Opponent';
        final dtStr = m['scheduled_at'] as String?;
        final dt = dtStr != null ? DateTime.tryParse(dtStr)?.toLocal() : null;
        const months = ['Jan','Feb','Mar','Apr','May','Jun',
                        'Jul','Aug','Sep','Oct','Nov','Dec'];
        final date = dt != null ? '${months[dt.month - 1]} ${dt.day}' : '—';
        final type = m['match_type'] == 'ranked' ? 'Ranked' : 'Casual';
        recent.add(RecentMatch(won, opp, score, date, type));
      }

      final level = (profileRow['level'] as num?)?.toDouble() ?? 0.0;
      final placementPlayed = (profileRow['placement_played'] as num?)?.toInt() ?? 0;
      final reliability =
          (profileRow['reliability'] as num?)?.toDouble() ?? 100.0;
      final provisional = profileRow['is_provisional'] == true;

      // Rating-move breakdown + weekly delta from the player's OWN
      // ranking_history rows (RLS read-own). Skipped on pre-migration DBs.
      double weeklyDelta = 0;
      LastRankedMatch? lastMatch;
      try {
        final weekAgo = DateTime.now()
            .subtract(const Duration(days: 7))
            .toIso8601String();
        final week = await _db
            .from('ranking_history')
            .select('delta')
            .eq('profile_id', userId)
            .gte('created_at', weekAgo);
        for (final row in (week as List)) {
          weeklyDelta += (row['delta'] as num?)?.toDouble() ?? 0;
        }

        // Rating trail for the chart: rating_before of the first match, then
        // each rating_after — mapped to ELO-style points (800 + rating*200).
        final histRows = await _db
            .from('ranking_history')
            .select('rating_before, rating_after')
            .eq('profile_id', userId)
            .not('match_id', 'is', null)
            .order('created_at', ascending: true)
            .limit(20);
        final hist = histRows as List;
        if (hist.isNotEmpty) {
          int toElo(num rt) => (800 + rt.toDouble() * 200).round();
          eloPoints = [
            toElo((hist.first['rating_before'] as num?) ?? 2.0),
            for (final r in hist)
              if (r['rating_after'] != null) toElo(r['rating_after'] as num),
          ];
        }
        final lastRows = await _db
            .from('ranking_history')
            .select('delta, opp_avg_rating, games_for, games_against, won')
            .eq('profile_id', userId)
            .not('match_id', 'is', null)
            .order('created_at', ascending: false)
            .limit(1);
        if ((lastRows as List).isNotEmpty) {
          final lr = lastRows.first as Map;
          lastMatch = LastRankedMatch(
            won: lr['won'] == true,
            vsLevel: (lr['opp_avg_rating'] as num?)?.toDouble() ?? level,
            delta: (lr['delta'] as num?)?.toDouble() ?? 0,
            gamesFor: (lr['games_for'] as num?)?.toInt() ?? 0,
            gamesAgainst: (lr['games_against'] as num?)?.toInt() ?? 0,
          );
        }
      } catch (_) {/* pre-migration: no breakdown available */}

      final compMatches =
          (profileRow['competitive_matches'] as num?)?.toInt() ?? 0;
      final ranking = placementPlayed < RankingScale.placementTotal
          ? Ranking.placement(placementPlayed)
          : Ranking.placed(
              level: level,
              reliability: reliability,
              provisional: provisional,
              weeklyDelta: weeklyDelta,
              lastMatch: lastMatch,
              competitiveMatches: compMatches,
            );

      return PlayerProfile(
        isNew: played == 0,
        ranking: ranking,
        played: played,
        wins: wins,
        losses: losses,
        streak: streak,
        winRate: winRate,
        elo: (profileRow['elo'] as num?)?.toInt(),
        eloHistory: eloPoints,
        recent: recent,
        // Absent on pre-migration DBs → false (reveal simply won't fire).
        placementRevealed: profileRow['placement_revealed'] == true,
      );
    } catch (e) {
      debugPrint('[ProfileService] fetchPlayerProfile error: $e');
      return PlayerProfile.fresh;
    }
  }

  /// Uploads a new avatar to the public `avatars` bucket (overwriting the
  /// user's slot) and saves the URL to profiles.avatar_url. Returns the new URL
  /// (with a cache-busting suffix so the changed image actually refreshes), or
  /// null on failure.
  static Future<String?> uploadAvatar(Uint8List bytes, String ext) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return null;
    try {
      final e = ext.toLowerCase() == 'jpeg' ? 'jpg' : (ext.isEmpty ? 'jpg' : ext.toLowerCase());
      final path = '$uid/avatar.$e';
      await _db.storage.from('avatars').uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(
                upsert: true, contentType: 'image/${e == 'jpg' ? 'jpeg' : e}'),
          );
      final base = _db.storage.from('avatars').getPublicUrl(path);
      final url = '$base?v=${DateTime.now().millisecondsSinceEpoch}';
      await _db.from('profiles').update({'avatar_url': url}).eq('id', uid);
      return url;
    } catch (e) {
      debugPrint('[ProfileService] uploadAvatar: $e');
      return null;
    }
  }

  static Future<void> ensureProfile(User user) async {
    final meta = user.userMetadata ?? {};
    final name = ((meta['name'] as String?) ?? (meta['full_name'] as String?) ?? '').trim();
    try {
      // Start UNRANKED — no seeded elo/level/tier (matches handle_new_user).
      await _db.from('profiles').upsert(
        {
          'id': user.id,
          'name': name,
          'avatar_url': meta['avatar_url'] as String?,
          'preferred_hand': 'right',
          'preferred_court_side': 'both',
          'placement_played': 0,
        },
        onConflict: 'id',
        ignoreDuplicates: true,
      );
    } catch (e) {
      debugPrint('[ProfileService] ensureProfile error: $e');
    }
  }
}

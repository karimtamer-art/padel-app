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
  Future<OnboardingProfile?> fetch(String userId) async {
    final row = await _sb
        .from('profiles')
        .select(_onbCols)
        .eq('id', userId)
        .maybeSingle();
    if (row == null) return null;
    return OnboardingProfile.fromJson(row);
  }

  /// Returns true when the user has answered all onboarding questions.
  Future<bool> isOnboardingComplete(String userId) async {
    final row = await _sb
        .from('profiles')
        .select(_onbCols)
        .eq('id', userId)
        .maybeSingle();
    if (row == null) return false;
    return OnboardingProfile.fromJson(row).isComplete;
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
      final profileRow = await _db
          .from('profiles')
          .select('elo, tier, level, placement_played')
          .eq('id', userId)
          .single();

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

      // ELO history — elo_after values chronological, last 12 points
      final eloPoints = completed
          .where((r) => r['elo_after'] != null)
          .map((r) => (r['elo_after'] as num).toInt())
          .toList()
          .reversed
          .take(12)
          .toList()
          .reversed
          .toList();

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
      final ranking = placementPlayed < RankingScale.placementTotal
          ? Ranking.placement(placementPlayed)
          : Ranking.placed(level: level);

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
      );
    } catch (e) {
      debugPrint('[ProfileService] fetchPlayerProfile error: $e');
      return PlayerProfile.fresh;
    }
  }

  static Future<void> ensureProfile(User user) async {
    final meta = user.userMetadata ?? {};
    final name = ((meta['name'] as String?) ?? (meta['full_name'] as String?) ?? '').trim();
    try {
      await _db.from('profiles').upsert(
        {
          'id': user.id,
          'name': name,
          'avatar_url': meta['avatar_url'] as String?,
          'preferred_hand': 'right',
          'preferred_court_side': 'both',
          'elo': 1000,
          'level': 1.0,
          'placement_played': 0,
          'tier': 'bronze',
          'division_pts': 0,
        },
        onConflict: 'id',
        ignoreDuplicates: true,
      );
    } catch (e) {
      debugPrint('[ProfileService] ensureProfile error: $e');
    }
  }
}

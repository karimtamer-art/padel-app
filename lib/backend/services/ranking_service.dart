import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Raw Supabase I/O for ranking data.
/// Screens never import this — they go through RankingRepository.
class RankingService {
  static SupabaseClient get _db => Supabase.instance.client;

  /// Returns a merged map with keys:
  ///   level, placement_played, weekly_delta, last_delta, last_win, last_vs_level
  static Future<Map<String, dynamic>?> fetchRanking(String uid) async {
    try {
      // ── Base fields from profiles ────────────────────────────────────
      final profile = Map<String, dynamic>.from(
        await _db
            .from('profiles')
            .select('level, placement_played')
            .eq('id', uid)
            .single() as Map,
      );

      // ── Recent history (last 7 days) ─────────────────────────────────
      final weekAgo = DateTime.now()
          .subtract(const Duration(days: 7))
          .toIso8601String();

      final List history = await _db
          .from('ranking_history')
          .select('level_before, level_after, created_at')
          .eq('profile_id', uid)
          .gte('created_at', weekAgo)
          .order('created_at', ascending: false);

      double weeklyDelta = 0.0;
      double? lastDelta;

      for (final row in history) {
        final delta =
            (row['level_after'] as num) - (row['level_before'] as num);
        weeklyDelta += delta;
        lastDelta ??= delta.toDouble(); // most-recent entry
      }

      return {
        ...profile,
        'weekly_delta': weeklyDelta,
        'last_delta': lastDelta,
        // last_win and last_vs_level populated from match_results in Phase 3
      };
    } catch (e) {
      debugPrint('[RankingService] fetchRanking: $e');
      return null;
    }
  }
}

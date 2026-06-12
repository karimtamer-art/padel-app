import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/backend/services/ranking_service.dart';
import 'package:padel_clay/backend/models/user_ranking.dart';

/// Single entry-point for ranking data.
/// Screens depend only on this class; all Supabase details stay in RankingService.
class RankingRepository {
  /// Fetches the current user's ranking, or returns Unranked on any failure.
  static Future<UserRanking> forCurrentUser() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return const UserRanking.unranked();
    final raw = await RankingService.fetchRanking(uid);
    if (raw == null) return const UserRanking.unranked();
    return UserRanking.fromJson(raw);
  }
}

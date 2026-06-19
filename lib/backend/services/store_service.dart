import 'package:supabase_flutter/supabase_flutter.dart';

/// Store reads that aren't tied to a single screen. Product browsing still
/// lives in StoreScreen's direct query; this is for cross-screen needs like
/// the Home "featured" strip.
class StoreService {
  static SupabaseClient get _db => Supabase.instance.client;

  /// Products to feature on Home. Server picks best-sellers when anything has
  /// sold, otherwise admin-featured items, otherwise newest (see the
  /// `get_home_products` RPC). Each row carries `sold_count` and a `source`
  /// of 'bestseller' | 'featured' | 'new'. Returns [] on any error so the
  /// Home screen can fall back to its static store card.
  static Future<List<Map<String, dynamic>>> fetchHomeProducts(
      {int limit = 6}) async {
    try {
      final rows =
          await _db.rpc('get_home_products', params: {'p_limit': limit});
      return List<Map<String, dynamic>>.from(rows as List);
    } catch (_) {
      return [];
    }
  }

  /// Active promotional banners for the store top, in display order.
  /// Returns [] on error (e.g. pre-migration databases) so the store still
  /// renders without the banner strip.
  static Future<List<Map<String, dynamic>>> fetchActiveBanners() async {
    try {
      final rows = await _db
          .from('banners')
          .select('id, title, subtitle, image_url, bg_color, discount_pct')
          .eq('is_active', true)
          .order('sort_order')
          .order('created_at');
      return List<Map<String, dynamic>>.from(rows as List);
    } catch (_) {
      return [];
    }
  }
}

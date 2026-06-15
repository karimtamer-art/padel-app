import 'package:supabase_flutter/supabase_flutter.dart';

/// Saved delivery addresses for the store checkout. Backed by the detailed
/// Egyptian `addresses` table (own-row RLS, keyed by user_id), so each user
/// only ever sees their own.
class AddressService {
  AddressService._();
  static SupabaseClient get _db => Supabase.instance.client;

  static const _cols =
      'id, label, full_name, phone, governorate, city, area, street, '
      'building, apartment, landmark, is_default';

  /// Composes the structured parts into a single human line for cards/snapshots.
  static String composeLine(Map<String, dynamic> a) {
    final parts = <String>[
      if ((a['street'] as String?)?.trim().isNotEmpty ?? false) a['street'] as String,
      if ((a['building'] as String?)?.trim().isNotEmpty ?? false) 'Bldg ${a['building']}',
      if ((a['apartment'] as String?)?.trim().isNotEmpty ?? false) 'Apt ${a['apartment']}',
      if ((a['area'] as String?)?.trim().isNotEmpty ?? false) a['area'] as String,
    ];
    return parts.join(', ');
  }

  /// The current user's saved addresses, default first then newest.
  static Future<List<Map<String, dynamic>>> fetchAddresses() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return [];
    try {
      final res = await _db
          .from('addresses')
          .select(_cols)
          .eq('user_id', uid)
          .order('is_default', ascending: false)
          .order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(res as List);
    } catch (_) {
      return [];
    }
  }

  /// Saves a new address. Returns `(error, row)`. When [makeDefault] is set any
  /// other default is cleared first so exactly one stays primary.
  static Future<(String?, Map<String, dynamic>?)> addAddress({
    String? label,
    required String fullName,
    required String phone,
    required String governorate,
    required String city,
    String? area,
    required String street,
    String? building,
    String? apartment,
    String? landmark,
    bool makeDefault = false,
  }) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return ('Not signed in.', null);
    String? clean(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();
    try {
      if (makeDefault) {
        await _db.from('addresses').update({'is_default': false}).eq('user_id', uid);
      }
      final row = await _db
          .from('addresses')
          .insert({
            'user_id': uid,
            'label': clean(label),
            'full_name': fullName.trim(),
            'phone': phone.trim(),
            'governorate': governorate.trim(),
            'city': city.trim(),
            'area': clean(area),
            'street': street.trim(),
            'building': clean(building),
            'apartment': clean(apartment),
            'landmark': clean(landmark),
            'is_default': makeDefault,
            'updated_at': DateTime.now().toIso8601String(),
          })
          .select(_cols)
          .single();
      return (null, Map<String, dynamic>.from(row));
    } on PostgrestException catch (e) {
      return (e.message, null);
    } catch (e) {
      return (e.toString(), null);
    }
  }
}

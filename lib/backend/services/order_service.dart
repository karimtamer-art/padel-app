import 'dart:math';
import 'dart:typed_data';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/mock_data.dart' show CartLine;

/// Store checkout. Writes to the `orders` table the admin console reads
/// (Admin → Payments). Two payment methods: cash-on-delivery and InstaPay —
/// a manual peer-to-peer transfer the buyer makes to the merchant handle,
/// uploads a screenshot for, and an admin verifies by hand. There is no
/// automated gateway (Paymob / Fawry stays a separate, server-side task).
class OrderService {
  OrderService._();
  static SupabaseClient get _db => Supabase.instance.client;

  static const _proofBucket = 'payment-proofs';

  /// The merchant InstaPay handle buyers transfer to. Read from the
  /// admin-editable `app_settings` row; falls back to a sane default.
  static Future<String> fetchInstapayHandle() async {
    try {
      final row = await _db
          .from('app_settings')
          .select('value')
          .eq('key', 'instapay_handle')
          .maybeSingle();
      final v = (row?['value'] as String?)?.trim();
      if (v != null && v.isNotEmpty) return v;
    } catch (_) {}
    return 'padelpro@instapay';
  }

  /// Uploads an InstaPay transfer screenshot to the private proofs bucket and
  /// returns its storage path (not a URL — admins sign it to view). Returns
  /// `null` on failure; the order can still be placed without a proof.
  static Future<String?> uploadPaymentProof(Uint8List bytes, String ext) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return null;
    final safeExt = ext.toLowerCase() == 'jpeg' ? 'jpg' : ext.toLowerCase();
    final path =
        'proofs/$uid/${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(99999)}.$safeExt';
    try {
      await _db.storage.from(_proofBucket).uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(
                contentType: 'image/${safeExt == 'jpg' ? 'jpeg' : safeExt}',
                upsert: true),
          );
      return path;
    } catch (_) {
      return null;
    }
  }

  /// Server-validated promo: the discount (currency units) a code yields for a
  /// subtotal, or 0 if invalid/inactive. The order-insert trigger recomputes it
  /// too, so a forged client discount is ignored.
  static Future<int> applyPromo(String code, int subtotal) async {
    try {
      final res = await _db.rpc('apply_promo',
          params: {'p_code': code, 'p_subtotal': subtotal});
      return (res as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// The current user's orders, newest first (for the profile "My orders").
  /// RLS ("own orders read") scopes this to the signed-in player.
  static Future<List<Map<String, dynamic>>> fetchMyOrders() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return [];
    try {
      final res = await _db
          .from('orders')
          .select('*')
          .eq('player_id', uid)
          .order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(res as List);
    } catch (_) {
      return [];
    }
  }

  /// Returns `(error, orderId)`.
  static Future<(String?, String?)> placeOrder({
    required List<CartLine> cart,
    required int subtotal,
    required int shipping,
    required int discount,
    required int total,
    String? promoCode,
    String paymentMethod = 'cod', // 'cod' | 'instapay'
    Map<String, dynamic>? address,
    String? instapaySender,
    String? instapayProofPath,
  }) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return ('Not signed in.', null);
    if (cart.isEmpty) return ('Your cart is empty.', null);
    try {
      final row = await _db
          .from('orders')
          .insert({
            'player_id': uid,
            'items': [
              for (final l in cart)
                {
                  'product_id': l.product.id,
                  'name': l.product.name,
                  'brand': l.product.brand,
                  'category': l.product.cat,
                  'qty': l.qty,
                  'unit_price': l.product.discounted,
                }
            ],
            'subtotal': subtotal,
            'shipping': shipping,
            'discount': discount,
            'total': total,
            'promo_code': promoCode,
            'payment_method': paymentMethod,
            'status': 'pending',
            if (address != null) 'address': address,
            if (instapaySender != null && instapaySender.isNotEmpty)
              'instapay_sender': instapaySender,
            if (instapayProofPath != null) 'instapay_proof_url': instapayProofPath,
          })
          .select('id')
          .single();
      return (null, row['id'] as String);
    } on PostgrestException catch (e) {
      return (e.message, null);
    } catch (e) {
      return (e.toString(), null);
    }
  }
}

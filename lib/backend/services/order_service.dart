import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
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

  /// Optional InstaPay payment link for the merchant account — the other half
  /// of the handle/link pair the admin sets in Payments. Empty when unset.
  static Future<String> fetchInstapayLink() async {
    try {
      final row = await _db
          .from('app_settings')
          .select('value')
          .eq('key', 'instapay_link')
          .maybeSingle();
      return ((row?['value'] as String?) ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  /// Uploads an InstaPay transfer screenshot to the private proofs bucket.
  /// Returns `(path: ..., error: null)` on success — the storage path (not a
  /// URL; admins sign it to view) — or `(path: null, error: <reason>)` so the
  /// UI can show WHY it failed instead of a generic "check your connection".
  static Future<({String? path, String? error})> uploadPaymentProof(
      Uint8List bytes, String ext) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) {
      return (path: null, error: 'You appear to be signed out. Sign in and try again.');
    }
    final safeExt = ext.toLowerCase() == 'jpeg' ? 'jpg' : ext.toLowerCase();
    final path =
        'proofs/$uid/${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(99999)}.$safeExt';
    try {
      // Paths are unique, so this is always a fresh insert — no upsert needed
      // (upsert would additionally require an UPDATE storage policy). A hard
      // timeout keeps a stalled connection from spinning forever instead of
      // surfacing an error.
      await _db.storage.from(_proofBucket).uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(
                contentType: 'image/${safeExt == 'jpg' ? 'jpeg' : safeExt}'),
          ).timeout(const Duration(seconds: 25));
      return (path: path, error: null);
    } on StorageException catch (e) {
      debugPrint('[OrderService] uploadPaymentProof storage error: '
          '${e.statusCode} ${e.error} ${e.message}');
      final m = e.message.toLowerCase();
      final reason = (m.contains('not found') || m.contains('bucket'))
          ? 'Payment uploads aren\'t set up on the server yet. Please contact support.'
          : (e.statusCode == '403' || m.contains('policy') || m.contains('unauthorized'))
              ? 'Not allowed to upload right now. Please sign out and back in.'
              : 'Upload failed: ${e.message}';
      return (path: null, error: reason);
    } on TimeoutException catch (e) {
      debugPrint('[OrderService] uploadPaymentProof timed out: $e');
      return (
        path: null,
        error: 'Upload timed out. Try again on a stronger connection.'
      );
    } on SocketException catch (e) {
      debugPrint('[OrderService] uploadPaymentProof socket error: $e');
      return (
        path: null,
        error: 'No internet connection. Check your Wi-Fi or mobile data and try again.'
      );
    } catch (e) {
      // Anything else (TLS handshake failures, a proxy/CDN returning HTML
      // instead of JSON on a 5xx, etc.) — log the real type so the next
      // report is diagnosable instead of another opaque "check your
      // connection", but keep the user-facing text actionable.
      debugPrint('[OrderService] uploadPaymentProof error: '
          '${e.runtimeType}: $e');
      return (
        path: null,
        error: 'Couldn\'t upload your payment screenshot. Please try again in a moment.'
      );
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

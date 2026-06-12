import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/mock_data.dart' show CartLine;

/// Store checkout. Writes to the `orders` table the admin console reads
/// (Admin → Payments). Payment method is cash-on-delivery until a gateway
/// (Paymob / Fawry) is integrated — see WHATS_CHANGED.md.
class OrderService {
  OrderService._();
  static SupabaseClient get _db => Supabase.instance.client;

  /// Returns `(error, orderId)`.
  static Future<(String?, String?)> placeOrder({
    required List<CartLine> cart,
    required int subtotal,
    required int shipping,
    required int discount,
    required int total,
    String? promoCode,
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
                  'qty': l.qty,
                  'unit_price': l.product.discounted,
                }
            ],
            'subtotal': subtotal,
            'shipping': shipping,
            'discount': discount,
            'total': total,
            'promo_code': promoCode,
            'payment_method': 'cod',
            'status': 'pending',
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

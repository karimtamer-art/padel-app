import 'package:flutter/material.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/backend/models/mock_data.dart';
import 'package:padel_clay/backend/services/order_service.dart';

/// Full-screen cart: line items, quantity steppers, promo, order summary,
/// checkout → success. Push with [Navigator.push].
class CartScreen extends StatefulWidget {
  final List<CartLine> cart;
  final VoidCallback onChanged;
  const CartScreen({super.key, required this.cart, required this.onChanged});
  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  bool _placed = false;
  bool _placing = false;
  bool _applied = false;
  String _orderRef = '';
  int _placedTotal = 0;
  final _promo = TextEditingController();

  Future<void> _checkout() async {
    setState(() => _placing = true);
    final (err, orderId) = await OrderService.placeOrder(
      cart: widget.cart,
      subtotal: _subtotal,
      shipping: _shipping,
      discount: _discount,
      total: _total,
      promoCode: _applied ? _promo.text.trim() : null,
    );
    if (!mounted) return;
    setState(() => _placing = false);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.danger,
          content: Text(err)));
      return;
    }
    setState(() {
      _placed = true;
      _placedTotal = _total;
      final raw = (orderId ?? '').replaceAll('-', '').toUpperCase();
      _orderRef = raw.length >= 6 ? '#PD-${raw.substring(0, 6)}' : '#PD-NEW';
      widget.cart.clear();
    });
    widget.onChanged();
  }

  IconData _catIcon(String c) => {
        'Rackets': Icons.sports_tennis_rounded,
        'Shoes': Icons.directions_run_rounded,
        'Apparel': Icons.checkroom_rounded,
        'Balls': Icons.sports_baseball_rounded,
        'Accessories': Icons.backpack_rounded,
      }[c] ?? Icons.sports_tennis_rounded;

  Color _catColor(String c) => {
        'Rackets': AppColors.primary,
        'Shoes': AppColors.accent,
        'Apparel': AppColors.diamond,
        'Balls': AppColors.success,
        'Accessories': AppColors.platinum,
      }[c] ?? AppColors.primary;

  int get _count => widget.cart.fold(0, (n, l) => n + l.qty);
  int get _subtotal => widget.cart.fold(0, (n, l) => n + l.lineTotal);
  int get _shipping => (_subtotal > 5000 || _subtotal == 0) ? 0 : 75;
  int get _discount => _applied ? (_subtotal * 0.1).round() : 0;
  int get _total => _subtotal + _shipping - _discount;

  void _setQty(CartLine l, int q) {
    setState(() {
      if (q <= 0) {
        widget.cart.remove(l);
      } else {
        l.qty = q;
      }
    });
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          _header(),
          Expanded(
            child: _placed
                ? _success()
                : _count == 0
                    ? _empty()
                    : _list(),
          ),
          if (!_placed && _count > 0) _checkoutBar(),
          if (_placed) _bottomButton('Continue Shopping'),
          if (!_placed && _count == 0) _bottomButton('Browse the Store'),
        ],
      ),
    );
  }

  Widget _header() => Container(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + 8, 16, 16),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [AppColors.hero, AppColors.hero2]),
        ),
        child: Row(children: [
          _glassBtn(Icons.keyboard_arrow_down_rounded, () => Navigator.pop(context)),
          const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('YOUR CART', style: AppText.tag(AppColors.heroFaint).copyWith(fontSize: 11, letterSpacing: 1.5)),
            Text(_placed ? 'Order placed' : '$_count item${_count == 1 ? '' : 's'}',
                style: AppText.stat(22, AppColors.heroInk).copyWith(height: 1.1)),
          ]),
          const Spacer(),
          const Icon(Icons.shopping_cart_outlined, size: 26, color: AppColors.heroFaint),
        ]),
      );

  Widget _list() => ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 2, AppSpacing.screen, 8),
        children: [
          ...widget.cart.map(_lineItem),
          const SizedBox(height: 8),
          _promoRow(),
          const SizedBox(height: 14),
          _summary(),
          const SizedBox(height: 14),
          Row(children: [
            const Icon(Icons.verified_user_outlined, size: 15, color: AppColors.inkSoft),
            const SizedBox(width: 7),
            Expanded(
              child: Text('Secure checkout · Free returns within 14 days · Cash on delivery available.',
                  style: AppText.small().copyWith(fontSize: 11.5, height: 1.4)),
            ),
          ]),
          const SizedBox(height: 12),
        ],
      );

  Widget _lineItem(CartLine l) {
    final p = l.product;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.line))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 66, height: 66,
          child: StripedPlaceholder(
              height: 66, icon: _catIcon(p.cat), color: _catColor(p.cat),
              radius: BorderRadius.circular(12)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.brand.toUpperCase(), style: AppText.tag().copyWith(fontSize: 9, letterSpacing: 1)),
                  const SizedBox(height: 1),
                  Text(p.name, style: AppText.bodyStrong().copyWith(fontSize: 13.5, height: 1.2)),
                ]),
              ),
              GestureDetector(
                onTap: () => _setQty(l, 0),
                child: const Icon(Icons.close_rounded, size: 16, color: AppColors.inkFaint),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              _stepper(l),
              const Spacer(),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                if (p.discount > 0)
                  Text(MockData.egp(p.price * l.qty),
                      style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 10, decoration: TextDecoration.lineThrough)),
                Text(MockData.egp(l.lineTotal), style: AppText.stat(14)),
              ]),
            ]),
          ]),
        ),
      ]),
    );
  }

  Widget _stepper(CartLine l) {
    Widget btn(IconData ic, VoidCallback onTap) => GestureDetector(
          onTap: onTap,
          child: Container(
            width: 28, height: 28, alignment: Alignment.center,
            decoration: BoxDecoration(
                color: AppColors.field, borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.line)),
            child: Icon(ic, size: 15, color: AppColors.ink),
          ),
        );
    return Row(children: [
      btn(l.qty <= 1 ? Icons.delete_outline_rounded : Icons.remove_rounded, () => _setQty(l, l.qty - 1)),
      SizedBox(width: 32, child: Text('${l.qty}', textAlign: TextAlign.center, style: AppText.stat(14))),
      btn(Icons.add_rounded, () => _setQty(l, l.qty + 1)),
    ]);
  }

  Widget _promoRow() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Container(
              height: 44, padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(color: AppColors.field, borderRadius: AppRadius.btnR, border: Border.all(color: AppColors.line)),
              child: Row(children: [
                const Icon(Icons.local_activity_outlined, size: 17, color: AppColors.inkFaint),
                const SizedBox(width: 9),
                Expanded(
                  child: TextField(
                    controller: _promo,
                    onChanged: (_) => setState(() => _applied = false),
                    style: AppText.body().copyWith(fontSize: 13),
                    decoration: InputDecoration.collapsed(
                        hintText: 'Promo code — try PADEL10',
                        hintStyle: AppText.body(AppColors.inkFaint).copyWith(fontSize: 13)),
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(width: 84, child: AppButton('Apply', variant: AppBtnVariant.ghost,
              onPressed: () => setState(() => _applied = _promo.text.trim().toUpperCase() == 'PADEL10'))),
        ]),
        if (_applied)
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Row(children: [
              const Icon(Icons.check_circle_outline_rounded, size: 14, color: AppColors.success),
              const SizedBox(width: 5),
              Text('PADEL10 applied — 10% off', style: AppText.bodyStrong(AppColors.success).copyWith(fontSize: 11.5)),
            ]),
          ),
      ]);

  Widget _summary() => AppCard(
        child: Column(children: [
          _sumRow('Subtotal', MockData.egp(_subtotal)),
          _sumRow('Shipping', _shipping == 0 ? 'Free' : MockData.egp(_shipping)),
          if (_discount > 0) _sumRow('Promo (PADEL10)', '– ${MockData.egp(_discount)}'),
          const Padding(padding: EdgeInsets.only(top: 10), child: Divider(height: 1, color: AppColors.line)),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(children: [
              Text('Total', style: AppText.cardTitle().copyWith(fontSize: 15)),
              const Spacer(),
              Text(MockData.egp(_total), style: AppText.stat(19, AppColors.primary)),
            ]),
          ),
        ]),
      );

  Widget _sumRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Text(k, style: AppText.body(AppColors.inkSoft).copyWith(fontSize: 13)),
          const Spacer(),
          Text(v, style: AppText.bodyStrong().copyWith(fontSize: 13)),
        ]),
      );

  Widget _empty() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 80, height: 80,
            decoration: const BoxDecoration(color: AppColors.field, shape: BoxShape.circle),
            child: const Icon(Icons.shopping_cart_outlined, size: 38, color: AppColors.inkFaint),
          ),
          const SizedBox(height: 16),
          Text('Your cart is empty', style: AppText.cardTitle().copyWith(fontSize: 18)),
          const SizedBox(height: 5),
          SizedBox(
            width: 220,
            child: Text('Browse rackets, shoes and gear to get match-ready.',
                textAlign: TextAlign.center, style: AppText.small()),
          ),
        ]),
      );

  Widget _success() => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 26),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 92, height: 92,
              decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.12), shape: BoxShape.circle),
              child: const Icon(Icons.check_circle_outline_rounded, size: 50, color: AppColors.primary),
            ),
            const SizedBox(height: 18),
            Text('Thank you!', style: AppText.stat(23)),
            const SizedBox(height: 6),
            Text("Your order is confirmed. We'll text you a tracking link once it ships from the Cairo warehouse.",
                textAlign: TextAlign.center, style: AppText.small().copyWith(fontSize: 14, height: 1.5)),
            const SizedBox(height: 22),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _miniStat('Order', _orderRef, AppColors.ink),
              _divider(),
              _miniStat('Total', MockData.egp(_placedTotal), AppColors.primary),
              _divider(),
              _miniStat('Arrives', '2–4 days', AppColors.ink),
            ]),
          ]),
        ),
      );

  Widget _miniStat(String k, String v, Color c) => Column(children: [
        Text(k, style: AppText.small()),
        Text(v, style: AppText.stat(15, c)),
      ]);

  Widget _divider() => Container(width: 1, height: 30, color: AppColors.line, margin: const EdgeInsets.symmetric(horizontal: 18));

  Widget _checkoutBar() => Container(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 26),
        decoration: const BoxDecoration(
            color: AppColors.bg, border: Border(top: BorderSide(color: AppColors.lineSoft))),
        child: Row(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('TOTAL', style: AppText.tag().copyWith(fontSize: 10)),
            Text(MockData.egp(_total), style: AppText.stat(20)),
          ]),
          const SizedBox(width: 14),
          Expanded(
            child: AppButton(_placing ? 'Placing order…' : 'Checkout',
                full: true, height: 52, icon: Icons.arrow_forward_rounded,
                onPressed: _placing ? null : _checkout),
          ),
        ]),
      );

  Widget _bottomButton(String label) => Container(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 26),
        decoration: const BoxDecoration(
            color: AppColors.bg, border: Border(top: BorderSide(color: AppColors.lineSoft))),
        child: AppButton(label, full: true, height: 52, onPressed: () => Navigator.pop(context)),
      );

  Widget _glassBtn(IconData icon, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34, height: 34, alignment: Alignment.center,
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, size: 20, color: AppColors.heroInk),
        ),
      );
}

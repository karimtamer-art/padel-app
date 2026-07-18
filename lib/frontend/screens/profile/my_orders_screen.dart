import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/padel_refresh.dart';
import '../../widgets/skeleton.dart';
import '../../../backend/models/mock_data.dart';
import '../../../backend/services/order_service.dart';

/// Customer "My orders": list of the signed-in player's store orders →
/// order details with a real status timeline, items, totals and Reorder.
/// [onReorder] refills the cart (owned by RootScaffold) and opens it.
class MyOrdersScreen extends StatefulWidget {
  final void Function(List<CartLine>)? onReorder;
  const MyOrdersScreen({super.key, this.onReorder});

  @override
  State<MyOrdersScreen> createState() => _MyOrdersScreenState();
}

class _MyOrdersScreenState extends State<MyOrdersScreen> {
  List<Map<String, dynamic>> _orders = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await OrderService.fetchMyOrders();
      if (mounted) setState(() { _orders = data; _loading = false; });
    } catch (_) {
      // Never leave the screen stuck on the skeleton if the fetch fails.
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(children: [
        OrderUi.header(context, 'MY ACCOUNT', 'My orders',
            onBack: () => Navigator.pop(context), icon: Icons.receipt_long_outlined),
        Expanded(
          child: _loading
              ? ListView(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.screen, 14, AppSpacing.screen, 30),
                  children:
                      List.generate(4, (_) => const SkeletonListRow()),
                )
              : _orders.isEmpty
                  ? _empty()
                  : PadelRefresh(
                      onRefresh: _load,
                      slivers: [
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(
                              AppSpacing.screen, 14, AppSpacing.screen, 30),
                          sliver: SliverList(
                            delegate: SliverChildListDelegate(
                              [for (final o in _orders) _orderCard(o)],
                            ),
                          ),
                        ),
                      ],
                    ),
        ),
      ]),
    );
  }

  Widget _empty() => ListView(
        children: [
          const SizedBox(height: 90),
          Center(
            child: Column(children: [
              Container(
                width: 80, height: 80,
                decoration: const BoxDecoration(color: AppColors.field, shape: BoxShape.circle),
                child: const Icon(Icons.receipt_long_outlined, size: 36, color: AppColors.inkFaint),
              ),
              const SizedBox(height: 16),
              Text('No orders yet', style: AppText.cardTitle().copyWith(fontSize: 18)),
              const SizedBox(height: 5),
              SizedBox(
                width: 230,
                child: Text('Anything you buy from the store will show up here to track.',
                    textAlign: TextAlign.center, style: AppText.small()),
              ),
            ]),
          ),
        ],
      );

  Widget _orderCard(Map<String, dynamic> o) {
    final items = (o['items'] as List?) ?? const [];
    final n = items.fold<int>(0, (s, it) => s + (((it as Map)['qty'] as num?)?.toInt() ?? 0));
    final spec = OrderUi.statusSpec(o);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        padding: const EdgeInsets.all(16),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => OrderDetailsScreen(order: o, onReorder: widget.onReorder))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(OrderUi.ref(o), style: AppText.cardTitle().copyWith(fontSize: 17)),
              const SizedBox(height: 2),
              Text(OrderUi.fmtDate(o['created_at'] as String?),
                  style: AppText.small(AppColors.inkFaint)),
            ]),
            const Spacer(),
            OrderUi.statusPill(spec),
          ]),
          const SizedBox(height: 14),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (final _ in items.take(2)) ...[
              SizedBox(
                width: 56, height: 56,
                child: StripedPlaceholder(
                    height: 56, icon: Icons.sports_tennis_rounded,
                    color: AppColors.primary, radius: BorderRadius.circular(12)),
              ),
              const SizedBox(width: 8),
            ],
            const Spacer(),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('$n item${n == 1 ? '' : 's'}', style: AppText.small()),
              const SizedBox(height: 2),
              Text(MockData.egp(OrderUi.total(o)), style: AppText.stat(18)),
            ]),
          ]),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Divider(height: 1, color: AppColors.line),
          ),
          Row(children: [
            Icon(spec.icon, size: 16, color: spec.color),
            const SizedBox(width: 8),
            Text(spec.note, style: AppText.bodyStrong().copyWith(fontSize: 12.5)),
            const Spacer(),
            Text('Details', style: AppText.bodyStrong(AppColors.primary).copyWith(fontSize: 12.5)),
            const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.primary),
          ]),
        ]),
      ),
    );
  }
}

// ════════════════ Order details ════════════════

class OrderDetailsScreen extends StatelessWidget {
  final Map<String, dynamic> order;
  final void Function(List<CartLine>)? onReorder;
  const OrderDetailsScreen({super.key, required this.order, this.onReorder});

  void _reorder(BuildContext context) {
    final items = (order['items'] as List?) ?? const [];
    final lines = <CartLine>[];
    for (final it in items) {
      final m = it as Map;
      lines.add(CartLine(
        Product(
          (m['brand'] as String?) ?? '',
          (m['name'] as String?) ?? 'Item',
          (m['category'] as String?) ?? '',
          (m['unit_price'] as num?)?.toInt() ?? 0,
          0, 0,
          id: (m['product_id'] as String?) ?? '',
        ),
        qty: (m['qty'] as num?)?.toInt() ?? 1,
      ));
    }
    if (lines.isEmpty) return;
    Navigator.pop(context);
    onReorder?.call(lines);
  }

  @override
  Widget build(BuildContext context) {
    final items = (order['items'] as List?) ?? const [];
    final spec = OrderUi.statusSpec(order);
    final subtotal = (order['subtotal'] as num?)?.toInt();
    final shipping = (order['shipping'] as num?)?.toInt();
    final total = OrderUi.total(order);

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(children: [
        OrderUi.header(context, 'ORDER ${OrderUi.ref(order)}', spec.label,
            onBack: () => Navigator.pop(context)),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 16, AppSpacing.screen, 24),
            children: [
              _timeline(order, spec),
              const SizedBox(height: 18),
              Text('ITEMS', style: AppText.kicker()),
              const SizedBox(height: 8),
              AppCard(
                padding: EdgeInsets.zero,
                child: Column(children: [
                  for (int i = 0; i < items.length; i++) _itemRow(items[i] as Map, i == 0),
                ]),
              ),
              const SizedBox(height: 14),
              AppCard(
                child: Column(children: [
                  if (subtotal != null) _sumRow('Subtotal', MockData.egp(subtotal)),
                  if (shipping != null)
                    _sumRow('Shipping', shipping == 0 ? 'Free' : MockData.egp(shipping)),
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Divider(height: 1, color: AppColors.line),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(children: [
                      Text('Total', style: AppText.cardTitle().copyWith(fontSize: 15)),
                      const Spacer(),
                      Text(MockData.egp(total), style: AppText.stat(19, AppColors.primary)),
                    ]),
                  ),
                ]),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 26),
          decoration: const BoxDecoration(
              color: AppColors.bg, border: Border(top: BorderSide(color: AppColors.lineSoft))),
          child: AppButton('Reorder',
              full: true, height: 52, variant: AppBtnVariant.outline,
              icon: Icons.shopping_cart_outlined, onPressed: () => _reorder(context)),
        ),
      ]),
    );
  }

  Widget _timeline(Map<String, dynamic> o, OrderStatusSpec spec) {
    final status = (o['status'] as String?) ?? 'pending';
    if (status == 'cancelled' || status == 'refunded') {
      return AppCard(
        child: Row(children: [
          Container(
            width: 40, height: 40, alignment: Alignment.center,
            decoration: BoxDecoration(color: spec.color.withValues(alpha: 0.13), shape: BoxShape.circle),
            child: Icon(spec.icon, size: 20, color: spec.color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(spec.label, style: AppText.bodyStrong().copyWith(fontSize: 14)),
              const SizedBox(height: 2),
              Text(spec.note, style: AppText.small().copyWith(height: 1.4)),
            ]),
          ),
        ]),
      );
    }

    const steps = ['Placed', 'Confirmed', 'Out for delivery', 'Delivered'];
    final reached = switch (status) { 'paid' => 1, 'shipped' => 2, 'delivered' => 3, _ => 0 };
    final allDone = status == 'delivered';

    return AppCard(
      child: Column(children: [
        for (int i = 0; i < steps.length; i++)
          _step(
            label: steps[i],
            done: i < reached || allDone,
            current: !allDone && i == reached,
            future: i > reached,
            isLast: i == steps.length - 1,
            note: (!allDone && i == reached) ? spec.note : null,
            stepNo: i + 1,
          ),
      ]),
    );
  }

  Widget _step({
    required String label,
    required bool done,
    required bool current,
    required bool future,
    required bool isLast,
    required int stepNo,
    String? note,
  }) {
    final activeColor = current ? AppColors.primary : AppColors.success;
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Column(children: [
          Container(
            width: 28, height: 28, alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: future ? Colors.transparent : (current ? AppColors.primary : AppColors.success),
              border: future ? Border.all(color: AppColors.line, width: 2) : null,
            ),
            child: future
                ? Text('$stepNo', style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 12))
                : Icon(current ? Icons.circle : Icons.check_rounded,
                    size: current ? 9 : 16, color: AppColors.surface),
          ),
          if (!isLast)
            Expanded(
              child: Container(
                width: 2,
                margin: const EdgeInsets.symmetric(vertical: 2),
                color: done && !current ? AppColors.success : AppColors.line,
              ),
            ),
        ]),
        const SizedBox(width: 14),
        Padding(
          padding: EdgeInsets.only(top: 3, bottom: isLast ? 0 : 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: future
                    ? AppText.bodyStrong(AppColors.inkFaint).copyWith(fontSize: 15)
                    : AppText.cardTitle().copyWith(fontSize: 15.5)),
            if (note != null) ...[
              const SizedBox(height: 2),
              Text(note, style: AppText.bodyStrong(activeColor).copyWith(fontSize: 12.5)),
            ],
          ]),
        ),
      ]),
    );
  }

  Widget _itemRow(Map it, bool first) {
    final unit = (it['unit_price'] as num?)?.toInt() ?? 0;
    final qty = (it['qty'] as num?)?.toInt() ?? 1;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          border: first ? null : const Border(top: BorderSide(color: AppColors.line))),
      child: Row(children: [
        SizedBox(
          width: 48, height: 48,
          child: StripedPlaceholder(
              height: 48, icon: Icons.sports_tennis_rounded,
              color: AppColors.primary, radius: BorderRadius.circular(11)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${it['brand'] ?? ''}'.toUpperCase(),
                style: AppText.tag().copyWith(fontSize: 9, letterSpacing: 1)),
            const SizedBox(height: 1),
            Text('${it['name'] ?? ''}',
                style: AppText.bodyStrong().copyWith(fontSize: 13.5),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text('${MockData.egp(unit)}  ×$qty',
                style: AppText.small(AppColors.inkFaint).copyWith(fontSize: 11.5)),
          ]),
        ),
        Text(MockData.egp(unit * qty), style: AppText.bodyStrong().copyWith(fontSize: 13.5)),
      ]),
    );
  }

  Widget _sumRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Text(k, style: AppText.body(AppColors.inkSoft).copyWith(fontSize: 13)),
          const Spacer(),
          Text(v, style: AppText.bodyStrong().copyWith(fontSize: 13)),
        ]),
      );
}

// ════════════════ shared bits ════════════════

class OrderStatusSpec {
  final Color color;
  final String label; // header / pill text
  final String note; // short status line
  final IconData icon;
  const OrderStatusSpec(this.color, this.label, this.note, this.icon);
}

class OrderUi {
  OrderUi._();

  static String ref(Map<String, dynamic> o) {
    final raw = ((o['id'] as String?) ?? '').replaceAll('-', '').toUpperCase();
    return raw.length >= 6 ? 'PD-${raw.substring(0, 6)}' : 'PD-NEW';
  }

  static int total(Map<String, dynamic> o) =>
      ((o['total'] as num?) ?? (o['total_amount'] as num?) ?? 0).round();

  static OrderStatusSpec statusSpec(Map<String, dynamic> o) {
    final s = (o['status'] as String?) ?? 'pending';
    final instapay = o['payment_method'] == 'instapay';
    return switch (s) {
      'pending' when instapay =>
        const OrderStatusSpec(AppColors.warn, 'Awaiting payment', 'Awaiting payment confirmation', Icons.schedule_rounded),
      'pending' =>
        const OrderStatusSpec(AppColors.warn, 'Order placed', 'Order placed — being confirmed', Icons.schedule_rounded),
      'paid' || 'confirmed' =>
        const OrderStatusSpec(AppColors.accent, 'Confirmed', 'Confirmed — preparing your order', Icons.inventory_2_outlined),
      'shipped' =>
        const OrderStatusSpec(AppColors.primary, 'Out for delivery', 'On its way to you', Icons.local_shipping_outlined),
      'delivered' =>
        const OrderStatusSpec(AppColors.success, 'Delivered', 'Order delivered', Icons.check_circle_outline_rounded),
      'refunded' =>
        const OrderStatusSpec(AppColors.inkSoft, 'Refunded', 'This order was refunded', Icons.replay_rounded),
      'cancelled' =>
        const OrderStatusSpec(AppColors.danger, 'Cancelled', 'This order was cancelled', Icons.cancel_outlined),
      _ => const OrderStatusSpec(AppColors.inkSoft, 'Order', 'Order', Icons.receipt_long_outlined),
    };
  }

  static Widget statusPill(OrderStatusSpec spec) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
            color: spec.color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: spec.color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(spec.label, style: AppText.bodyStrong(spec.color).copyWith(fontSize: 11.5)),
        ]),
      );

  static String fmtDate(String? iso) {
    if (iso == null) return '—';
    try {
      final dt = DateTime.parse(iso).toLocal();
      const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
      return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
    } catch (_) {
      return iso.substring(0, 10);
    }
  }

  static Widget header(BuildContext context, String kicker, String title,
          {VoidCallback? onBack, IconData? icon}) =>
      Container(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + 8, 16, 16),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [AppColors.hero, AppColors.hero2]),
        ),
        child: Row(children: [
          if (onBack != null) ...[
            GestureDetector(
              onTap: onBack,
              child: Container(
                width: 34, height: 34, alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.arrow_back_rounded, size: 20, color: AppColors.heroInk),
              ),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(kicker, style: AppText.tag(AppColors.heroFaint).copyWith(fontSize: 11, letterSpacing: 1.5)),
              Text(title, style: AppText.stat(20, AppColors.heroInk).copyWith(height: 1.1)),
            ]),
          ),
          if (icon != null) Icon(icon, size: 24, color: AppColors.heroFaint),
        ]),
      );
}

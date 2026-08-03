import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:padel_clay/backend/models/order_cancel_reason.dart';
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';
import '../data/admin_service.dart';

/// Store orders — InstaPay transfer verification + fulfilment progression.
/// Adapted from the reference Store/Orders design, wired to the live `orders`
/// table. Payment is Cash on delivery + InstaPay only (no card gateway), so an
/// InstaPay order that is still `pending` is the "verify" state.
class AdminPaymentsScreen extends StatefulWidget {
  const AdminPaymentsScreen({super.key});
  @override
  State<AdminPaymentsScreen> createState() => _AdminPaymentsScreenState();
}

class _AdminPaymentsScreenState extends State<AdminPaymentsScreen> {
  List<Map<String, dynamic>> _orders = [];
  String _handle = '';
  String _link = ''; // app_settings 'instapay_link' — the pair's other half
  bool _loading = true;
  String _filter = 'all';

  // value, label
  static const _filters = <List<String>>[
    ['all', 'All orders'],
    ['verify', 'InstaPay to verify'],
    ['pending', 'New COD'],
    ['paid', 'To fulfil'],
    ['shipped', 'Shipped'],
    ['delivered', 'Delivered'],
    ['refunded', 'Refunded'],
  ];

  // fulfilment advance: effective status -> [next, button label]
  static const _flow = <String, List<String>>{
    'paid': ['shipped', 'Mark shipped'],
    'shipped': ['delivered', 'Mark delivered'],
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await AdminService.fetchOrders();
      final handle = await AdminService.getSetting('instapay_handle');
      final link = await AdminService.getSetting('instapay_link');
      if (mounted) {
        setState(() {
          _orders = data;
          _handle = handle ?? '';
          _link = link ?? '';
          _loading = false;
        });
      }
    } catch (e, st) {
      debugPrint('[AdminPayments] load failed: $e\n$st');
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── helpers ───────────────────────────────────────────────────

  /// Effective status: an InstaPay order still `pending` needs verification.
  static String _eff(Map<String, dynamic> o) {
    final s = o['status'] as String? ?? 'pending';
    if (o['payment_method'] == 'instapay' && s == 'pending') return 'verify';
    return s;
  }

  static double _amount(Map<String, dynamic> o) =>
      (o['total'] as num?)?.toDouble() ??
      (o['total_amount'] as num?)?.toDouble() ??
      0;

  static String _methodLabel(String? m) =>
      switch (m) { 'instapay' => 'InstaPay', 'cod' => 'Cash on delivery', _ => m ?? '—' };

  static bool _isInstaPay(Map<String, dynamic> o) => o['payment_method'] == 'instapay';

  static int _nItems(Map<String, dynamic> o) {
    final items = (o['items'] as List?) ?? const [];
    return items.fold<int>(0, (s, it) => s + (((it as Map)['qty'] as num?)?.toInt() ?? 0));
  }

  static String _egp(num n) {
    final s = n.round().toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return 'EGP $buf';
  }

  static String _egpShort(num n) {
    if (n >= 1000000) return 'EGP ${(n / 1000000).toStringAsFixed(n % 1000000 == 0 ? 0 : 1)}M';
    if (n >= 1000) return 'EGP ${(n / 1000).toStringAsFixed(n % 1000 == 0 ? 0 : 1)}k';
    return 'EGP ${n.toStringAsFixed(0)}';
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  /// The order survives the customer: deleting an account anonymises the row
  /// (the sale is our tax record) rather than removing it.
  static String _customer(Map<String, dynamic> o) {
    if (o['customer_deleted'] == true) return 'Deleted account';
    return (o['profiles'] as Map?)?['name'] as String? ?? 'Unknown';
  }

  static String _shortId(Map<String, dynamic> o) {
    final id = o['id'] as String? ?? '';
    return id.length >= 8 ? '#${id.substring(0, 8).toUpperCase()}' : '#$id';
  }

  static String _fmtDate(String? iso) {
    if (iso == null) return '—';
    try {
      final dt = DateTime.parse(iso).toLocal();
      const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
      return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
    } catch (_) {
      return iso.substring(0, 10);
    }
  }

  static (Color, String) _statusSpec(String eff) => switch (eff) {
        'verify' => (AdminColors.warn, 'Verify payment'),
        'pending' => (AdminColors.warn, 'Pending'),
        'paid' => (AdminColors.green, 'Paid'),
        'shipped' => (AdminColors.info, 'Shipped'),
        'delivered' => (AdminColors.success, 'Delivered'),
        'refunded' => (AdminColors.danger, 'Refunded'),
        'cancelled' => (AdminColors.danger, 'Cancelled'),
        _ => (AdminColors.inkSoft, eff),
      };

  Widget _statusPill(String eff, {bool dot = false}) {
    final (c, label) = _statusSpec(eff);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: AdminColors.wash(c, 0.14), borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (dot) ...[
          Container(width: 6, height: 6, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 5),
        ],
        Text(label, style: AdminText.sans(11, FontWeight.w700, c)),
      ]),
    );
  }

  List<Map<String, dynamic>> get _shown =>
      _filter == 'all' ? _orders : _orders.where((o) => _eff(o) == _filter).toList();

  int get _toVerify => _orders.where((o) => _eff(o) == 'verify').length;
  int get _toFulfil => _orders.where((o) => _eff(o) == 'paid').length;
  int get _refunds => _orders.where((o) => o['status'] == 'refunded').length;
  double get _revenue => _orders
      .where((o) => const ['paid', 'shipped', 'delivered'].contains(_eff(o)))
      .fold<double>(0, (s, o) => s + _amount(o));

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AdminColors.primary));
    }
    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
        children: [
          KpiGrid([
            StatCard(icon: Icons.phone_iphone_rounded, tone: AdminColors.primary, label: 'InstaPay to verify', value: '$_toVerify', foot: 'confirm transfers'),
            StatCard(icon: Icons.local_shipping_outlined, tone: AdminColors.warn, label: 'Awaiting fulfilment', value: '$_toFulfil'),
            StatCard(icon: Icons.payments_outlined, tone: AdminColors.green, label: 'Store revenue', value: _egpShort(_revenue)),
            StatCard(icon: Icons.replay_rounded, tone: AdminColors.danger, label: 'Refunded', value: '$_refunds'),
          ]),
          const SizedBox(height: 12),
          _handleCard(),
          const SizedBox(height: 14),
          // filter chips
          SizedBox(
            height: 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _filters.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final f = _filters[i];
                final on = _filter == f[0];
                return GestureDetector(
                  onTap: () => setState(() => _filter = f[0]),
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: on ? AdminColors.ink : AdminColors.surface,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: on ? AdminColors.ink : AdminColors.line),
                    ),
                    child: Text(f[1], style: AdminText.sans(12.5, FontWeight.w700, on ? AdminColors.surface : AdminColors.inkSoft)),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 14),
          for (final o in _shown)
            Padding(padding: const EdgeInsets.only(bottom: 10), child: _orderCard(o)),
          if (_shown.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 50),
              child: Column(children: [
                const Icon(Icons.check_circle_outline_rounded, size: 30, color: AdminColors.inkFaint),
                const SizedBox(height: 10),
                Text(_orders.isEmpty ? 'No orders yet.' : 'Nothing here right now.', style: AdminText.small()),
              ]),
            ),
        ],
      ),
    );
  }

  // ── InstaPay merchant handle (compact, admin-editable) ────────

  Widget _handleCard() => AdminCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(children: [
          Row(children: [
            const Icon(Icons.account_balance_wallet_outlined, size: 18, color: AdminColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('INSTAPAY HANDLE', style: AdminText.kicker()),
                const SizedBox(height: 2),
                Text(_handle.isEmpty ? 'Not set' : _handle,
                    style: AdminText.mono(13, FontWeight.w700, AdminColors.ink)),
              ]),
            ),
            AdminButton('Edit', variant: AdminBtn.ghost, height: 34, icon: Icons.edit_outlined, onPressed: _editHandle),
          ]),
          // The payment link is the second half of the pair — an organizer has
          // had both since July; the platform account only ever had the handle.
          const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.link_rounded, size: 18, color: AdminColors.inkFaint),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('PAYMENT LINK', style: AdminText.kicker()),
                const SizedBox(height: 2),
                Text(_link.isEmpty ? 'Not set — optional' : _link,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AdminText.sans(
                        12.5,
                        FontWeight.w600,
                        _link.isEmpty ? AdminColors.inkFaint : AdminColors.ink)),
              ]),
            ),
          ]),
        ]),
      );

  Future<void> _editHandle() async {
    // The field holds only the name — "@instapay" is fixed, since InstaPay
    // always completes the address.
    final ctrl =
        TextEditingController(text: AdminService.instapayName(_handle));
    final linkCtrl = TextEditingController(text: _link);
    final saved = await adminSheet<bool>(
      context,
      title: 'InstaPay payout',
      sub: 'Where buyers transfer at checkout',
      heightFactor: 0.62,
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('HANDLE', style: AdminText.kicker()),
        const SizedBox(height: 6),
        Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
              color: AdminColors.surfaceAlt,
              borderRadius: AdminUI.fieldR,
              border: Border.all(color: AdminColors.line)),
          alignment: Alignment.centerLeft,
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: ctrl,
                autofocus: true,
                style: AdminText.mono(14, FontWeight.w700, AdminColors.ink),
                decoration:
                    const InputDecoration.collapsed(hintText: 'padelpro'),
              ),
            ),
            Text(AdminService.instapaySuffix,
                style:
                    AdminText.mono(14, FontWeight.w700, AdminColors.inkFaint)),
          ]),
        ),
        const SizedBox(height: 14),
        Text('PAYMENT LINK (OPTIONAL)', style: AdminText.kicker()),
        const SizedBox(height: 6),
        Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
              color: AdminColors.surfaceAlt,
              borderRadius: AdminUI.fieldR,
              border: Border.all(color: AdminColors.line)),
          alignment: Alignment.centerLeft,
          child: TextField(
            controller: linkCtrl,
            keyboardType: TextInputType.url,
            style: AdminText.sans(13, FontWeight.w600, AdminColors.ink),
            decoration: const InputDecoration.collapsed(
                hintText: 'https://ipn.eg/… (optional)'),
          ),
        ),
      ]),
      footer: Builder(
        builder: (ctx) => AdminButton('Save',
            full: true, height: 48, icon: Icons.check_rounded, onPressed: () => Navigator.pop(ctx, true)),
      ),
    );
    if (saved != true) return;
    final handle = AdminService.normalizeInstapay(ctrl.text);
    final link = linkCtrl.text.trim();
    if (handle == null) return;
    final err = await AdminService.setSetting('instapay_handle', handle);
    final linkErr = await AdminService.setSetting('instapay_link', link);
    if (!mounted) return;
    if (err != null || linkErr != null) {
      adminToast(context, err ?? linkErr!, ok: false);
    } else {
      setState(() {
        _handle = handle;
        _link = link;
      });
      adminToast(context, 'Payout details updated');
    }
  }

  // ── Order card ────────────────────────────────────────────────

  Widget _orderCard(Map<String, dynamic> o) {
    final eff = _eff(o);
    final isVerify = eff == 'verify';
    final isNewCod = eff == 'pending'; // COD order awaiting admin acceptance
    final n = _nItems(o);
    return AdminCard(
      onTap: () => _open(o),
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AdminAvatar(_initials(_customer(o)), size: 38),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(_shortId(o), style: AdminText.mono(12, FontWeight.w700, AdminColors.ink)),
                const Spacer(),
                _statusPill(eff, dot: true),
              ]),
              const SizedBox(height: 3),
              Text('${_customer(o)} · $n item${n == 1 ? '' : 's'}',
                  style: AdminText.small(), maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        ]),
        const SizedBox(height: 11),
        Row(children: [
          Icon(_isInstaPay(o) ? Icons.phone_iphone_rounded : Icons.payments_outlined,
              size: 15, color: AdminColors.inkSoft),
          const SizedBox(width: 6),
          Text(_methodLabel(o['payment_method'] as String?), style: AdminText.small()),
          const Spacer(),
          Text(_egp(_amount(o)), style: AdminText.sans(14, FontWeight.w800, AdminColors.ink)),
        ]),
        if (isVerify || isNewCod) ...[
          const SizedBox(height: 11),
          AdminButton(isVerify ? 'Verify payment' : 'Confirm order',
              full: true, height: 40, icon: Icons.check_rounded, onPressed: () => _open(o)),
        ],
      ]),
    );
  }

  // ── Detail / action sheet ─────────────────────────────────────

  void _open(Map<String, dynamic> o) {
    final id = o['id'] as String;
    final eff = _eff(o);
    final addr = o['address'] as Map?;
    final items = (o['items'] as List?) ?? const [];
    final sender = o['instapay_sender'] as String?;
    final proofPath = o['instapay_proof_url'] as String?;

    Future<void> setStatus(String s, String msg, {bool ok = true}) async {
      final err = await AdminService.updateOrderStatus(id, s);
      if (!mounted) return;
      Navigator.pop(context);
      if (err != null) {
        adminToast(context, err, ok: false);
      } else {
        adminToast(context, msg, ok: ok);
        _load();
      }
    }

    Widget footer;
    if (eff == 'verify') {
      footer = Row(children: [
        Expanded(
          child: AdminButton('Confirm payment',
              full: true, height: 50, variant: AdminBtn.success, icon: Icons.check_rounded,
              onPressed: () => setStatus('paid', 'Payment confirmed — ${_shortId(o)} moved to fulfilment')),
        ),
        const SizedBox(width: 10),
        AdminButton('Reject',
            height: 50, variant: AdminBtn.danger,
            onPressed: () => _askReason(o, status: 'cancelled', verb: 'rejected')),
      ]);
    } else if (eff == 'pending') {
      // COD order: nothing to verify (cash collected on delivery), so the first
      // admin action is to accept it into fulfilment.
      footer = Row(children: [
        Expanded(
          child: AdminButton('Confirm order',
              full: true, height: 50, variant: AdminBtn.success, icon: Icons.check_rounded,
              onPressed: () => setStatus('paid', '${_shortId(o)} confirmed — moved to fulfilment')),
        ),
        const SizedBox(width: 10),
        AdminButton('Cancel',
            height: 50, variant: AdminBtn.danger,
            onPressed: () => _askReason(o, status: 'cancelled', verb: 'cancelled')),
      ]);
    } else if (_flow[eff] != null) {
      final next = _flow[eff]!;
      footer = Row(children: [
        Expanded(
          child: AdminButton(next[1],
              full: true, height: 50, icon: Icons.check_rounded,
              onPressed: () => setStatus(next[0], '${_shortId(o)} → ${next[0]}')),
        ),
        const SizedBox(width: 10),
        AdminButton('Refund',
            height: 50, variant: AdminBtn.danger,
            onPressed: () => _askReason(o, status: 'refunded', verb: 'refunded')),
      ]);
    } else if (eff == 'delivered') {
      footer = AdminButton('Refund',
          full: true, height: 50, variant: AdminBtn.danger,
          onPressed: () => _askReason(o, status: 'refunded', verb: 'refunded'));
    } else {
      footer = const SizedBox.shrink();
    }

    adminSheet(
      context,
      title: 'Order ${_shortId(o)}',
      sub: '${_customer(o)} · ${_fmtDate(o['created_at'] as String?)}',
      heightFactor: 0.86,
      footer: footer is SizedBox ? null : footer,
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _statusPill(eff),
          const Spacer(),
          Row(children: [
            Icon(_isInstaPay(o) ? Icons.phone_iphone_rounded : Icons.payments_outlined,
                size: 15, color: AdminColors.primary),
            const SizedBox(width: 5),
            Text(_methodLabel(o['payment_method'] as String?), style: AdminText.strong()),
          ]),
        ]),

        // What the customer was told, on an order that was killed.
        if (eff == 'cancelled' || eff == 'refunded') ...[
          const SizedBox(height: 14),
          Text('REASON GIVEN TO THE CUSTOMER', style: AdminText.kicker()),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
                color: AdminColors.surfaceAlt,
                borderRadius: BorderRadius.circular(11)),
            child: Text(
              CancelReason.playerExplanation(
                o['cancel_reason'] as String?,
                o['cancel_note'] as String?,
                instapay: _isInstaPay(o),
              ),
              style: AdminText.body().copyWith(height: 1.5),
            ),
          ),
        ],

        // InstaPay verification
        if (eff == 'verify') ...[
          const SizedBox(height: 16),
          Text('MATCH THESE AGAINST THE TRANSFER', style: AdminText.kicker()),
          const SizedBox(height: 8),
          _matchRow('Amount due', Text(_egp(_amount(o)), style: AdminText.sans(17, FontWeight.w800, AdminColors.ink))),
          const SizedBox(height: 8),
          _matchRow('Send to', _copyChip(_handle.isEmpty ? '—' : _handle)),
          const SizedBox(height: 8),
          _matchRow('Sender username', _copyChip(sender == null || sender.isEmpty ? '—' : sender)),
          const SizedBox(height: 14),
          Text('TRANSFER SCREENSHOT', style: AdminText.kicker()),
          const SizedBox(height: 8),
          if (proofPath == null || proofPath.isEmpty)
            _noProof()
          else
            FutureBuilder<String?>(
              future: AdminService.signProofUrl(proofPath),
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const SizedBox(height: 80, child: Center(child: CircularProgressIndicator(color: AdminColors.primary)));
                }
                final url = snap.data;
                if (url == null) return _noProof();
                return ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(url, width: double.infinity, height: 220, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _noProof()),
                );
              },
            ),
        ],

        // Delivery
        const SizedBox(height: 16),
        Text('DELIVERY', style: AdminText.kicker()),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: AdminColors.surfaceAlt, borderRadius: BorderRadius.circular(12)),
          child: addr == null
              ? Text('No address on this order.', style: AdminText.small())
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${addr['full_name'] ?? addr['label'] ?? '—'}', style: AdminText.strong()),
                  const SizedBox(height: 4),
                  Text('${addr['line'] ?? addr['street'] ?? ''}', style: AdminText.small()),
                  Text('${addr['city'] ?? ''}, ${addr['governorate'] ?? ''}', style: AdminText.small()),
                  if ((addr['landmark'] as String?)?.isNotEmpty ?? false)
                    Text('Landmark: ${addr['landmark']}', style: AdminText.small()),
                  const SizedBox(height: 4),
                  Row(children: [
                    const Icon(Icons.phone_outlined, size: 13, color: AdminColors.inkSoft),
                    const SizedBox(width: 5),
                    Text('${addr['phone'] ?? '—'}', style: AdminText.mono(12, FontWeight.w600, AdminColors.ink)),
                  ]),
                ]),
        ),

        // items
        const SizedBox(height: 16),
        Text('ITEMS', style: AdminText.kicker()),
        const SizedBox(height: 8),
        for (final it in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(color: AdminColors.surfaceAlt, borderRadius: BorderRadius.circular(11)),
              child: Row(children: [
                Container(
                  width: 32, height: 32, alignment: Alignment.center,
                  decoration: BoxDecoration(color: AdminColors.surface3, borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.inventory_2_outlined, size: 15, color: AdminColors.inkSoft),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${(it as Map)['name'] ?? ''}', style: AdminText.strong(), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text('${it['brand'] ?? ''}', style: AdminText.small()),
                  ]),
                ),
                Text('×${it['qty']}', style: AdminText.mono(11.5, FontWeight.w600, AdminColors.inkSoft)),
                const SizedBox(width: 12),
                Text(_egp(((it['unit_price'] as num?) ?? 0) * ((it['qty'] as num?) ?? 1)), style: AdminText.strong()),
              ]),
            ),
          ),
        const SizedBox(height: 6),
        Row(children: [
          Text('Total', style: AdminText.strong(AdminColors.inkSoft)),
          const Spacer(),
          Text(_egp(_amount(o)), style: AdminText.sans(16, FontWeight.w900, AdminColors.ink)),
        ]),
      ]),
    );
  }

  // ── Rejection reason ──────────────────────────────────────────

  /// Killing an order asks WHY first. The player is told the reason verbatim,
  /// so this is the difference between "your order was cancelled" and "the
  /// item sold out — your transfer is coming back".
  Future<void> _askReason(
    Map<String, dynamic> o, {
    required String status,
    required String verb,
  }) async {
    final id = o['id'] as String;
    final instapay = _isInstaPay(o);
    final reasons = CancelReason.forOrder(instapay: instapay);
    final noteC = TextEditingController();
    CancelReason? picked;

    Navigator.pop(context); // close the order sheet first

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AdminColors.canvas,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) {
          final needsNote = picked?.noteRequired ?? false;
          final ready = picked != null &&
              (!needsNote || noteC.text.trim().isNotEmpty);
          return Padding(
            padding: EdgeInsets.only(
                bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Why is ${_shortId(o)} being $verb?',
                      style: AdminText.cardTitle()),
                  const SizedBox(height: 4),
                  Text('The customer is told this — pick the closest match.',
                      style: AdminText.small()),
                  const SizedBox(height: 14),
                  for (final r in reasons)
                    GestureDetector(
                      onTap: () => setSheet(() => picked = r),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: picked == r
                              ? AdminColors.wash(AdminColors.primary, 0.10)
                              : AdminColors.surfaceAlt,
                          borderRadius: BorderRadius.circular(11),
                          border: Border.all(
                              color: picked == r
                                  ? AdminColors.primary
                                  : AdminColors.line,
                              width: 1.4),
                        ),
                        child: Row(children: [
                          Icon(
                              picked == r
                                  ? Icons.radio_button_checked_rounded
                                  : Icons.radio_button_unchecked_rounded,
                              size: 19,
                              color: picked == r
                                  ? AdminColors.primary
                                  : AdminColors.inkFaint),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(r.adminLabel, style: AdminText.strong()),
                                  if (r.playerLine.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text('"${r.playerLine}"',
                                        style: AdminText.small()
                                            .copyWith(height: 1.35)),
                                  ],
                                ]),
                          ),
                          // Flags, at a glance, that money has to go back.
                          if (r.refunds && instapay)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 3),
                              decoration: BoxDecoration(
                                  color: AdminColors.wash(
                                      AdminColors.warn, 0.16),
                                  borderRadius: BorderRadius.circular(999)),
                              child: Text('REFUND',
                                  style: AdminText.mono(8.5, FontWeight.w800,
                                      AdminColors.warn, ls: 0.8)),
                            ),
                        ]),
                      ),
                    ),
                  const SizedBox(height: 6),
                  Text(needsNote ? 'NOTE · REQUIRED' : 'NOTE · OPTIONAL',
                      style: AdminText.kicker()),
                  const SizedBox(height: 7),
                  TextField(
                    controller: noteC,
                    maxLines: 3,
                    onChanged: (_) => setSheet(() {}),
                    style: AdminText.body(),
                    decoration: InputDecoration(
                      hintText: 'Anything else the customer should know…',
                      hintStyle: AdminText.small(AdminColors.inkFaint),
                      isDense: true,
                      filled: true,
                      fillColor: AdminColors.surfaceAlt,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 13, vertical: 12),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: AdminUI.fieldR,
                          borderSide: const BorderSide(color: AdminColors.line)),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: AdminUI.fieldR,
                          borderSide: const BorderSide(
                              color: AdminColors.primary, width: 1.6)),
                    ),
                  ),
                  const SizedBox(height: 14),
                  AdminButton('Confirm — $verb',
                      full: true,
                      height: 50,
                      variant: AdminBtn.danger,
                      onPressed: ready
                          ? () => Navigator.pop(sheetCtx, true)
                          : null),
                  const SizedBox(height: 8),
                  AdminButton('Back',
                      full: true,
                      height: 44,
                      variant: AdminBtn.ghost,
                      onPressed: () => Navigator.pop(sheetCtx, false)),
                ],
              ),
            ),
          );
        },
      ),
    );

    final reason = picked;
    if (confirmed != true || reason == null) {
      noteC.dispose();
      return;
    }
    final err = await AdminService.cancelOrder(id,
        status: status, reason: reason.code, note: noteC.text);
    noteC.dispose();
    if (!mounted) return;
    if (err != null) {
      adminToast(context, err, ok: false);
      return;
    }
    adminToast(
        context, '${_shortId(o)} $verb — customer told why', ok: false);
    _load();
  }

  // ── pieces ────────────────────────────────────────────────────

  Widget _matchRow(String label, Widget trailing) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(color: AdminColors.surfaceAlt, borderRadius: BorderRadius.circular(11)),
        child: Row(children: [
          Text(label, style: AdminText.small(AdminColors.inkSoft).copyWith(fontWeight: FontWeight.w600)),
          const Spacer(),
          Flexible(child: Align(alignment: Alignment.centerRight, child: trailing)),
        ]),
      );

  Widget _copyChip(String value) => Material(
        color: AdminColors.surface3,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: value == '—'
              ? null
              : () {
                  Clipboard.setData(ClipboardData(text: value));
                  adminToast(context, 'Copied $value');
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.copy_rounded, size: 13, color: AdminColors.inkSoft),
              const SizedBox(width: 6),
              Flexible(
                child: Text(value,
                    style: AdminText.mono(12, FontWeight.w600, AdminColors.ink),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ]),
          ),
        ),
      );

  Widget _noProof() => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 14),
        decoration: BoxDecoration(
          color: AdminColors.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AdminColors.line),
        ),
        child: Column(children: [
          const Icon(Icons.image_outlined, size: 24, color: AdminColors.inkFaint),
          const SizedBox(height: 8),
          Text('No screenshot', style: AdminText.strong(AdminColors.inkSoft)),
          const SizedBox(height: 3),
          Text('Customer skipped the optional proof', style: AdminText.small(), textAlign: TextAlign.center),
        ]),
      );
}

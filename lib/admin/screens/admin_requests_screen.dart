import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import '../theme/admin_colors.dart';
import '../data/admin_service.dart';
import '../widgets/admin_kit.dart';

class AdminRequestsScreen extends StatefulWidget {
  const AdminRequestsScreen({super.key});
  @override
  State<AdminRequestsScreen> createState() => _AdminRequestsScreenState();
}

class _AdminRequestsScreenState extends State<AdminRequestsScreen> {
  int _tab = 0;
  List<Map<String, dynamic>> _repairs = [];
  List<Map<String, dynamic>> _trades = [];
  bool _loading = true;
  String? _error;
  // The moderation queue used to be a third segment here. It now lives under
  // Reports (AdminModerationView) — this console is service requests only.

  // DB status values: pending / quoted / in_repair / ready / collected
  static const _repairFlow = [
    'pending', 'quoted', 'in_repair', 'ready', 'collected'
  ];
  static const _repairLabel = {
    'pending': 'New',
    'quoted': 'Quoted',
    'in_repair': 'In repair',
    'ready': 'Ready',
    'collected': 'Collected',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_loading) setState(() => _loading = true);
    // Load the two queues independently: one failing (RLS, missing table)
    // must not leave the whole screen stuck on the spinner.
    final results = await Future.wait([
      AdminService.fetchRepairs().then<Object>((v) => v).catchError((e) => e),
      AdminService.fetchTrades().then<Object>((v) => v).catchError((e) => e),
    ]);
    if (!mounted) return;
    final repairs = results[0];
    final trades = results[1];
    setState(() {
      if (repairs is List<Map<String, dynamic>>) _repairs = repairs;
      if (trades is List<Map<String, dynamic>>) _trades = trades;
      _error = repairs is List<Map<String, dynamic>> &&
              trades is List<Map<String, dynamic>>
          ? null
          : _msg(repairs is List ? trades : repairs);
      _loading = false;
    });
  }

  static String _msg(Object e) =>
      e is PostgrestException ? e.message : e.toString();

  /// Profit on a recorded swap — the three prices in a trade-in:
  ///
  ///     what we sold the new racket for   (given_price)
  ///   − what the new racket cost us       (given_cost)
  ///   − what we paid for the used racket  (offer_credit)
  ///
  /// This is deliberately the SAME arithmetic the P&L now does, so the number
  /// on the trade and the number in Reports can never disagree. Note it is not
  /// `paid_amount - given_cost`: paid_amount is a record of the cash and is
  /// free to differ (part payment, haggling) without moving platform profit.
  ///
  /// Null unless the sale price is known — a "profit" computed from a missing
  /// price is just the negative of the costs, which reads as a real loss.
  static num? _recordedProfit(Map row) {
    final price = row['given_price'] as num?;
    if (price == null) return null;
    final cost = (row['given_cost'] as num?) ?? 0;
    final credit = (row['offer_credit'] as num?) ?? 0;
    return price - cost - credit;
  }

  /// The racket handed back in the swap, or null if none was recorded. Reads
  /// the stored label rather than the FK, so it survives the product being
  /// renamed or deleted.
  static String? _givenBack(Map row) {
    final v = (row['given_name'] as String?)?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  /// The seller's name: the linked account first, then the plain name typed in
  /// for a counter walk-in who has no account (trade_requests.player_name).
  static String _playerName(Map row) {
    final linked = ((row['profiles'] as Map?)?['name'] as String?)?.trim();
    if (linked != null && linked.isNotEmpty) return linked;
    final typed = (row['player_name'] as String?)?.trim();
    if (typed != null && typed.isNotEmpty) return typed;
    return 'Player';
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  static String _fmtDate(String? iso) {
    if (iso == null) return '';
    try {
      const months = [
        'Jan','Feb','Mar','Apr','May','Jun',
        'Jul','Aug','Sep','Oct','Nov','Dec'
      ];
      final dt = DateTime.parse(iso).toLocal();
      return '${months[dt.month - 1]} ${dt.day}';
    } catch (_) {
      return '';
    }
  }

  static String _shortId(String? id) {
    if (id == null) return '—';
    return id.length > 8 ? id.substring(0, 8).toUpperCase() : id.toUpperCase();
  }

  static String _egp(dynamic n) =>
      n == null ? '—' : 'EGP ${(n as num).toInt()}';

  /// Storage paths of the racket photos the player attached. Requests made
  /// before photos existed have none, so this is often empty.
  static List<String> _photos(Map row) {
    final raw = row['photos'];
    if (raw is! List) return const [];
    return [
      for (final p in raw)
        if (p is String && p.isNotEmpty) p,
    ];
  }

  static String _egpShort(int n) {
    if (n >= 1000) return 'EGP ${(n / 1000).toStringAsFixed(0)}K';
    return 'EGP $n';
  }

  @override
  Widget build(BuildContext context) {
    final newRepairs =
        _repairs.where((r) => r['status'] == 'pending').length;
    final newTrades =
        _trades.where((t) => t['status'] == 'pending').length;

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
        child: _seg(newRepairs, newTrades),
      ),
      if (_error != null && !_loading)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: AdminColors.danger.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(
                    color: AdminColors.danger.withValues(alpha: .3))),
            child: Row(children: [
              const Icon(Icons.error_outline_rounded,
                  size: 17, color: AdminColors.danger),
              const SizedBox(width: 9),
              Expanded(
                  child: Text("Couldn't load requests: $_error",
                      style: AdminText.small(AdminColors.danger))),
              TextButton(
                  onPressed: _load,
                  child: Text('Retry',
                      style: AdminText.strong(AdminColors.danger))),
            ]),
          ),
        ),
      Expanded(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AdminColors.primary))
            : _tab == 0
                ? _repairsList()
                : _tradesList(),
      ),
    ]);
  }

  Widget _seg(int newRepairs, int newTrades) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
          color: AdminColors.surfaceAlt,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: AdminColors.line)),
      child: Row(children: [
        _segBtn('Repairs', newRepairs, 0),
        _segBtn('Trade-ins', newTrades, 1),
      ]),
    );
  }

  Widget _segBtn(String label, int badge, int idx) {
    final on = _tab == idx;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _tab = idx),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
              color: on ? AdminColors.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              boxShadow: on ? AdminColors.cardShadow : null),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label,
                style: AdminText.sans(
                    12.5,
                    FontWeight.w700,
                    on ? AdminColors.ink : AdminColors.inkSoft)),
            if (badge > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                    color: AdminColors.primary,
                    borderRadius: BorderRadius.circular(999)),
                child: Text('$badge',
                    style: AdminText.sans(
                        10.5, FontWeight.w800, AdminColors.primaryInk)),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  // ── Repairs ───────────────────────────────────────────────────

  Widget _repairsList() {
    final quotedRevenue = _repairs
        .where((r) => r['quote_amount'] != null)
        .fold<int>(
            0,
            (s, r) =>
                s + ((r['quote_amount'] as num?)?.toInt() ?? 0));

    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
        children: [
          KpiGrid([
            StatCard(
                icon: Icons.notifications_outlined,
                tone: AdminColors.warn,
                label: 'New requests',
                value:
                    '${_repairs.where((r) => r['status'] == 'pending').length}'),
            StatCard(
                icon: Icons.build_outlined,
                tone: AdminColors.primary,
                label: 'In repair',
                value:
                    '${_repairs.where((r) => r['status'] == 'in_repair').length}'),
            StatCard(
                icon: Icons.check_circle_outline_rounded,
                tone: AdminColors.green,
                label: 'Ready',
                value:
                    '${_repairs.where((r) => r['status'] == 'ready').length}'),
            StatCard(
                icon: Icons.payments_outlined,
                tone: AdminColors.info,
                label: 'Quoted value',
                value: _egpShort(quotedRevenue)),
          ]),
          const SizedBox(height: 16),
          if (_repairs.isEmpty)
            Container(
              padding: const EdgeInsets.all(28),
              alignment: Alignment.center,
              child: Text('No repair requests yet',
                  style: AdminText.small(AdminColors.inkFaint)),
            )
          else
            for (final r in _repairs)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: AdminCard(
                  onTap: () => _openRepair(r),
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    AdminAvatar(_initials(_playerName(r)), size: 38),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Expanded(
                                  child: Text(
                                      r['racket_desc'] as String? ?? '—',
                                      style: AdminText.strong(),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis)),
                              StatusBadge(r['status'] as String? ?? 'pending',
                                  dot: true),
                            ]),
                            const SizedBox(height: 3),
                            Text(
                                '${_playerName(r)} · ${r['issue'] ?? '—'}',
                                style: AdminText.small(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 3),
                            Row(children: [
                              Text(
                                  _fmtDate(
                                      r['created_at'] as String?),
                                  style: AdminText.mono(10.5,
                                      FontWeight.w500, AdminColors.inkFaint)),
                              if (r['quote_amount'] != null) ...[
                                const SizedBox(width: 8),
                                Text(_egp(r['quote_amount']),
                                    style: AdminText.strong()),
                              ],
                            ]),
                          ]),
                    ),
                  ]),
                ),
              ),
        ],
      ),
    );
  }

  void _openRepair(Map<String, dynamic> r) {
    final quoteC = TextEditingController(
        text: r['quote_amount'] != null ? '${r['quote_amount']}' : '');
    final status = r['status'] as String? ?? 'pending';
    final idx = _repairFlow.indexOf(status);
    final next =
        idx >= 0 && idx < _repairFlow.length - 1 ? _repairFlow[idx + 1] : null;
    const advanceLabel = {
      'quoted': 'Start repair',
      'in_repair': 'Mark ready',
      'ready': 'Mark collected',
      'collected': 'Collected',
    };

    adminSheet(
      context,
      title: r['racket_desc'] as String? ?? '—',
      sub: '${_shortId(r['id'] as String?)} · ${_playerName(r)}',
      heightFactor: 0.74,
      footer: Column(mainAxisSize: MainAxisSize.min, children: [
        (status == 'pending'
            ? AdminButton('Send quote', full: true, height: 50,
                icon: Icons.check_rounded, onPressed: () async {
                Navigator.pop(context);
                final err = await AdminService.updateRepair(r['id'] as String, {
                  'status': 'quoted',
                  'quote_amount': int.tryParse(quoteC.text) ?? 0,
                });
                await _load();
                if (mounted) {
                  adminToast(
                      context,
                      err == null
                          ? 'Quote sent to ${_playerName(r)}'
                          : "Couldn't send quote: $err",
                      ok: err == null);
                }
              })
            : next != null && next != 'collected'
                // Label the CURRENT step's action (keyed by `status`), not the
                // destination — `advanceLabel[next]` was one step ahead.
                ? AdminButton(advanceLabel[status]!, full: true, height: 50,
                    icon: Icons.check_rounded, onPressed: () async {
                    Navigator.pop(context);
                    final err = await AdminService.updateRepair(
                        r['id'] as String, {'status': next});
                    await _load();
                    if (mounted) {
                      adminToast(
                          context,
                          err == null
                              ? '${_shortId(r['id'] as String?)} → ${_repairLabel[next]}'
                              : "Couldn't update: $err",
                          ok: err == null);
                    }
                  })
                : next == 'collected'
                    ? AdminButton('Mark collected', full: true, height: 50,
                        variant: AdminBtn.success, onPressed: () async {
                        Navigator.pop(context);
                        final err = await AdminService.updateRepair(
                            r['id'] as String, {'status': 'collected'});
                        await _load();
                        if (mounted) {
                          adminToast(
                              context,
                              err == null
                                  ? 'Repair complete'
                                  : "Couldn't update: $err",
                              ok: err == null);
                        }
                      })
                    : const SizedBox.shrink()),
        if (status != 'collected' && status != 'rejected') ...[
          const SizedBox(height: 8),
          AdminButton('Decline request', full: true, height: 44,
              variant: AdminBtn.danger, onPressed: () => _declineRepair(r)),
        ],
      ]),
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          for (int i = 0; i < _repairFlow.length; i++)
            Expanded(
              child: Column(children: [
                Row(children: [
                  Expanded(
                    child: Container(
                        height: 2,
                        color: i == 0
                            ? Colors.transparent
                            : (i <= idx
                                ? AdminColors.primary
                                : AdminColors.line)),
                  ),
                  Container(
                    width: 18,
                    height: 18,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        color: i <= idx
                            ? AdminColors.primary
                            : AdminColors.surface3,
                        shape: BoxShape.circle),
                    child: i < idx
                        ? const Icon(Icons.check_rounded,
                            size: 11, color: Colors.white)
                        : null,
                  ),
                  Expanded(
                    child: Container(
                        height: 2,
                        color: i == _repairFlow.length - 1
                            ? Colors.transparent
                            : (i < idx
                                ? AdminColors.primary
                                : AdminColors.line)),
                  ),
                ]),
                const SizedBox(height: 5),
                Text(
                  _repairLabel[_repairFlow[i]] ?? '',
                  textAlign: TextAlign.center,
                  style: AdminText.sans(
                      9,
                      FontWeight.w700,
                      i <= idx ? AdminColors.ink : AdminColors.inkFaint),
                ),
              ]),
            ),
        ]),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: AdminColors.surfaceAlt,
              borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text("PLAYER'S DESCRIPTION", style: AdminText.kicker()),
            const SizedBox(height: 6),
            Text(r['issue'] as String? ?? '—',
                style: AdminText.body().copyWith(height: 1.5)),
          ]),
        ),
        const SizedBox(height: 14),
        Text('Quote (EGP)', style: AdminText.strong(AdminColors.inkSoft)),
        const SizedBox(height: 7),
        TextField(
          controller: quoteC,
          keyboardType: TextInputType.number,
          style: AdminText.body(),
          decoration: InputDecoration(
            isDense: true,
            prefixText: 'EGP ',
            prefixStyle:
                AdminText.mono(12, FontWeight.w700, AdminColors.inkFaint),
            filled: true,
            fillColor: AdminColors.surfaceAlt,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
            enabledBorder: OutlineInputBorder(
                borderRadius: AdminUI.fieldR,
                borderSide: const BorderSide(color: AdminColors.line)),
            focusedBorder: OutlineInputBorder(
                borderRadius: AdminUI.fieldR,
                borderSide: const BorderSide(
                    color: AdminColors.primary, width: 1.6)),
          ),
        ),
      ]),
    );
  }

  // ── Trades ────────────────────────────────────────────────────

  Widget _tradesList() {
    final liability = _trades
        .where((t) =>
            ['offer_made', 'accepted'].contains(t['status']))
        .fold<int>(
            0,
            (s, t) =>
                s + ((t['offer_credit'] as num?)?.toInt() ?? 0));

    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
        children: [
          KpiGrid([
            StatCard(
                icon: Icons.notifications_outlined,
                tone: AdminColors.warn,
                label: 'New trade-ins',
                value:
                    '${_trades.where((t) => t['status'] == 'pending').length}'),
            StatCard(
                icon: Icons.swap_horiz_rounded,
                tone: AdminColors.info,
                label: 'Offers out',
                value:
                    '${_trades.where((t) => t['status'] == 'offer_made').length}'),
            StatCard(
                icon: Icons.check_circle_outline_rounded,
                tone: AdminColors.green,
                label: 'Accepted',
                value:
                    '${_trades.where((t) => t['status'] == 'accepted').length}'),
            StatCard(
                icon: Icons.account_balance_wallet_outlined,
                tone: AdminColors.primary,
                label: 'Credit committed',
                value: _egpShort(liability)),
          ]),
          const SizedBox(height: 12),
          // A trade-in taken at the counter never passed through the app, so
          // the console has to be able to enter one itself — otherwise its
          // credit never reaches the P&L.
          AdminButton('Record a trade-in',
              icon: Icons.add_rounded,
              full: true,
              height: 46,
              onPressed: _openAddTrade),
          const SizedBox(height: 16),
          if (_trades.isEmpty)
            Container(
              padding: const EdgeInsets.all(28),
              alignment: Alignment.center,
              child: Text('No trade-ins yet',
                  style: AdminText.small(AdminColors.inkFaint)),
            )
          else
            for (final t in _trades)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: AdminCard(
                  onTap: () => _openTrade(t),
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    AdminAvatar(_initials(_playerName(t)), size: 38),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Expanded(
                                  child: Text(
                                      t['racket_desc'] as String? ?? '—',
                                      style: AdminText.strong(),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis)),
                              StatusBadge(
                                  t['status'] as String? ?? 'pending',
                                  dot: true),
                            ]),
                            const SizedBox(height: 3),
                            Text(
                                '${_playerName(t)} · ${t['condition'] ?? '—'}',
                                style: AdminText.small()),
                            const SizedBox(height: 5),
                            Row(children: [
                              // Players no longer name an asking price — older
                              // requests still carry one, so show it if set.
                              Text(
                                  t['asking_credit'] != null
                                      ? 'Asking ${_egp(t['asking_credit'])}'
                                      : 'No asking price',
                                  style:
                                      AdminText.small(AdminColors.inkSoft)),
                              if (t['offer_credit'] != null) ...[
                                const SizedBox(width: 8),
                                Text('→ ${_egp(t['offer_credit'])}',
                                    style: AdminText.sans(12, FontWeight.w700,
                                        AdminColors.primary)),
                              ],
                              const Spacer(),
                              // Whether there's anything to look at before
                              // opening the request.
                              Icon(
                                  _photos(t).isEmpty
                                      ? Icons.no_photography_outlined
                                      : Icons.photo_camera_outlined,
                                  size: 13,
                                  color: _photos(t).isEmpty
                                      ? AdminColors.inkFaint
                                      : AdminColors.inkSoft),
                              const SizedBox(width: 3),
                              Text('${_photos(t).length}',
                                  style: AdminText.small(_photos(t).isEmpty
                                      ? AdminColors.inkFaint
                                      : AdminColors.inkSoft)),
                            ]),
                          ]),
                    ),
                  ]),
                ),
              ),
        ],
      ),
    );
  }

  void _openTrade(Map<String, dynamic> t) {
    final asking = (t['asking_credit'] as num?)?.toInt();
    final existingOffer = (t['offer_credit'] as num?)?.toInt();
    // Suggest 85% of the asking price only when the (legacy) field is set —
    // new requests come in without one, so start the offer field empty.
    final suggested = existingOffer ?? (asking != null ? (asking * 0.85).round() : null);
    final offerC = TextEditingController(text: suggested?.toString() ?? '');
    final status = t['status'] as String? ?? 'pending';

    adminSheet(
      context,
      title: t['racket_desc'] as String? ?? '—',
      sub: '${_shortId(t['id'] as String?)} · ${_playerName(t)}',
      heightFactor: 0.68,
      footer: Column(mainAxisSize: MainAxisSize.min, children: [
        (status == 'pending'
            ? AdminButton('Send offer', full: true, height: 50,
                icon: Icons.check_rounded, onPressed: () async {
                Navigator.pop(context);
                final err = await AdminService.updateTrade(t['id'] as String, {
                  'status': 'offer_made',
                  'offer_credit': int.tryParse(offerC.text) ?? 0,
                });
                await _load();
                if (mounted) {
                  adminToast(
                      context,
                      err == null
                          ? 'Offer sent to ${_playerName(t)}'
                          : "Couldn't send offer: $err",
                      ok: err == null);
                }
              })
            : status == 'offer_made'
                ? AdminButton('Mark accepted', full: true, height: 50,
                    variant: AdminBtn.success, onPressed: () async {
                    Navigator.pop(context);
                    final err = await AdminService.updateTrade(
                        t['id'] as String, {'status': 'accepted'});
                    await _load();
                    // No wallet/store-credit ledger exists yet, so credit is
                    // arranged manually — don't claim it was auto-issued.
                    if (mounted) {
                      adminToast(
                          context,
                          err == null
                              ? 'Trade accepted — arrange store credit'
                              : "Couldn't accept: $err",
                          ok: err == null);
                    }
                  })
                : const SizedBox.shrink()),
        if (status == 'pending' || status == 'offer_made') ...[
          const SizedBox(height: 8),
          AdminButton('Decline trade-in', full: true, height: 44,
              variant: AdminBtn.danger, onPressed: () => _declineTrade(t)),
        ],
      ]),
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('THE RACKET', style: AdminText.kicker()),
        const SizedBox(height: 8),
        _tradePhotos(_photos(t)),
        const SizedBox(height: 14),
        Row(children: [
          _kv('Condition', t['condition'] as String? ?? '—'),
          const SizedBox(width: 10),
          if (t['asking_credit'] != null) ...[
            _kv('Asking', _egp(t['asking_credit'])),
            const SizedBox(width: 10),
          ],
          _kv('Your offer',
              t['offer_credit'] != null ? _egp(t['offer_credit']) : '—'),
        ]),
        // The other half of the swap. A player-submitted trade-in arrives with
        // none of this, so the button below is how it gets filled in — without
        // it the deal would show as pure credit out and nothing in.
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: Text('THE SWAP', style: AdminText.kicker())),
          TextButton(
            onPressed: () => _openTradeMoney(t),
            child: Text(
                _givenBack(t) == null ? 'Record the swap' : 'Edit',
                style: AdminText.strong(AdminColors.primary)),
          ),
        ]),
        const SizedBox(height: 4),
        if (_givenBack(t) == null && t['given_price'] == null)
          Text(
            'Nothing recorded yet, so Reports counts only the credit going '
            'out. Add what you sold them and what it cost you.',
            style: AdminText.small(AdminColors.inkFaint),
          )
        else ...[
          Row(children: [
            _kv('Given back', _givenBack(t) ?? '—'),
            const SizedBox(width: 10),
            _kv('Sold it for',
                t['given_price'] != null ? _egp(t['given_price']) : '—'),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            _kv('It cost us',
                t['given_cost'] != null ? _egp(t['given_cost']) : '—'),
            const SizedBox(width: 10),
            _kv('Profit on the deal',
                _recordedProfit(t) != null ? _egp(_recordedProfit(t)!) : '—'),
          ]),
          if (t['paid_amount'] != null) ...[
            const SizedBox(height: 6),
            Text('They handed over ${_egp(t['paid_amount'])} in cash.',
                style: AdminText.small(AdminColors.inkFaint)),
          ],
        ],
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: AdminColors.surfaceAlt,
              borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text("PLAYER'S NOTE", style: AdminText.kicker()),
            const SizedBox(height: 6),
            Text(t['note'] as String? ?? 'No notes provided.',
                style: AdminText.body().copyWith(height: 1.5)),
          ]),
        ),
        if (status == 'pending' || status == 'offer_made') ...[
          const SizedBox(height: 14),
          Text('Trade-in offer (store credit)',
              style: AdminText.strong(AdminColors.inkSoft)),
          const SizedBox(height: 7),
          TextField(
            controller: offerC,
            keyboardType: TextInputType.number,
            style: AdminText.body(),
            decoration: InputDecoration(
              isDense: true,
              prefixText: 'EGP ',
              prefixStyle:
                  AdminText.mono(12, FontWeight.w700, AdminColors.inkFaint),
              filled: true,
              fillColor: AdminColors.surfaceAlt,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
              enabledBorder: OutlineInputBorder(
                  borderRadius: AdminUI.fieldR,
                  borderSide: const BorderSide(color: AdminColors.line)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: AdminUI.fieldR,
                  borderSide: const BorderSide(
                      color: AdminColors.primary, width: 1.6)),
            ),
          ),
        ],
      ]),
    );
  }

  /// The player's racket shots. The bucket is private, so the paths are
  /// signed once and the strip is built from the resulting URLs.
  Widget _tradePhotos(List<String> paths) {
    if (paths.isEmpty) return _noPhotos();
    return FutureBuilder<List<String>>(
      future: AdminService.signTradePhotoUrls(paths),
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(
              height: 120,
              child: Center(
                  child: CircularProgressIndicator(color: AdminColors.primary)));
        }
        final urls = snap.data ?? const <String>[];
        if (urls.isEmpty) return _noPhotos(couldNotLoad: true);
        return SizedBox(
          height: 120,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: urls.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) => GestureDetector(
              onTap: () => _viewPhoto(urls, i),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(urls[i],
                    width: 120,
                    height: 120,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                          width: 120,
                          height: 120,
                          color: AdminColors.surfaceAlt,
                          child: const Icon(Icons.broken_image_outlined,
                              color: AdminColors.inkFaint),
                        )),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _noPhotos({bool couldNotLoad = false}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 14),
        decoration: BoxDecoration(
            color: AdminColors.surfaceAlt,
            borderRadius: BorderRadius.circular(12)),
        child: Column(children: [
          Icon(
              couldNotLoad
                  ? Icons.broken_image_outlined
                  : Icons.no_photography_outlined,
              color: AdminColors.inkFaint),
          const SizedBox(height: 7),
          Text(
              couldNotLoad
                  ? 'Could not load the photos.'
                  : 'No photos attached — this request predates photo uploads. '
                      'Inspect the racket in person before making an offer.',
              textAlign: TextAlign.center,
              style: AdminText.small(AdminColors.inkFaint)),
        ]),
      );

  /// Full-screen, pinch-to-zoom viewer — the edge guard and any hairline
  /// cracks are the whole reason for the photos, and they don't read at 120px.
  void _viewPhoto(List<String> urls, int index) {
    final page = PageController(initialPage: index);
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      builder: (dialogCtx) => Stack(children: [
        PageView.builder(
          controller: page,
          itemCount: urls.length,
          itemBuilder: (_, i) => InteractiveViewer(
            minScale: 1,
            maxScale: 5,
            child: Center(
              child: Image.network(urls[i],
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white54,
                      size: 48)),
            ),
          ),
        ),
        Positioned(
          top: 44,
          right: 16,
          child: GestureDetector(
            onTap: () => Navigator.pop(dialogCtx),
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  shape: BoxShape.circle),
              child: const Icon(Icons.close_rounded, color: Colors.white),
            ),
          ),
        ),
        if (urls.length > 1)
          Positioned(
            bottom: 42,
            left: 0,
            right: 0,
            child: Text('${urls.length} photos — swipe to see the rest',
                textAlign: TextAlign.center,
                style: AdminText.small(Colors.white70)),
          ),
      ]),
    ).whenComplete(page.dispose);
  }

  Future<void> _declineRepair(Map<String, dynamic> r) async {
    Navigator.pop(context);
    final err =
        await AdminService.updateRepair(r['id'] as String, {'status': 'rejected'});
    await _load();
    if (mounted) {
      adminToast(context,
          err == null ? 'Repair request declined' : "Couldn't decline: $err",
          ok: err == null);
    }
  }

  Future<void> _declineTrade(Map<String, dynamic> t) async {
    Navigator.pop(context);
    final err =
        await AdminService.updateTrade(t['id'] as String, {'status': 'rejected'});
    await _load();
    if (mounted) {
      adminToast(context,
          err == null ? 'Trade-in declined' : "Couldn't decline: $err",
          ok: err == null);
    }
  }

  Future<void> _openAddTrade() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _AddTradeSheet(),
    );
    if (saved == true) {
      await _load();
      if (mounted) adminToast(context, 'Trade-in recorded');
    }
  }

  /// Fills in (or corrects) the swap on a trade-in that already exists —
  /// including one the player submitted through the app, which arrives with
  /// nothing but their racket and so has no way to reach the P&L otherwise.
  /// Same sheet as recording one from scratch, so the money fields, the
  /// catalogue picker and the profit sum are written once.
  Future<void> _openTradeMoney(Map<String, dynamic> t) async {
    Navigator.pop(context); // close the trade sheet underneath
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AddTradeSheet(existing: t),
    );
    if (saved == true) {
      await _load();
      if (mounted) adminToast(context, 'Swap saved');
    }
  }

  Widget _kv(String k, String v) => Expanded(
        child: Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
              color: AdminColors.surfaceAlt,
              borderRadius: BorderRadius.circular(11)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(k.toUpperCase(), style: AdminText.kicker()),
            const SizedBox(height: 4),
            Text(v,
                style: AdminText.sans(13.5, FontWeight.w800, AdminColors.ink)),
          ]),
        ),
      );
}

// ============================================================================
// Record a trade-in the console took in itself. The player-facing flow inserts
// its own row; this is the counter walk-in, which otherwise has no record and
// whose credit never reaches the P&L.
//
// player_id is NOT NULL and an FK to profiles, so a real account must be
// picked — there is deliberately no free-text "walk-in stranger" path.
// ============================================================================
class _AddTradeSheet extends StatefulWidget {
  /// The trade being edited, or null when recording a new one. Editing reuses
  /// this sheet so the money fields and the profit sum exist in one place; what
  /// changes is that the seller is already settled and cannot be re-picked.
  final Map<String, dynamic>? existing;
  const _AddTradeSheet({this.existing});
  @override
  State<_AddTradeSheet> createState() => _AddTradeSheetState();
}

class _AddTradeSheetState extends State<_AddTradeSheet> {
  final _search = TextEditingController();
  final _walkIn = TextEditingController();
  final _racket = TextEditingController();
  final _credit = TextEditingController();
  final _note = TextEditingController();

  final _given = TextEditingController();
  final _givenPrice = TextEditingController();
  final _paid = TextEditingController();
  final _cost = TextEditingController();

  List<Map<String, dynamic>> _results = [];
  Map<String, dynamic>? _player;
  // The catalogue, loaded once so the "what we gave" picker can filter it
  // locally — it is a shop's worth of products, not a searchable table.
  List<Map<String, dynamic>> _products = [];
  Map<String, dynamic>? _givenProduct;
  String _givenQuery = '';
  String? _condition;
  // Accepted is what moves money, so it is never the default — the admin has
  // to choose it. See the hint under the selector.
  String _status = 'offer_made';
  bool _searching = false;
  bool _busy = false;

  static const _conditions = {
    'new': 'New',
    'like_new': 'Like new',
    'good': 'Good',
    'fair': 'Fair',
    'poor': 'Poor',
  };

  /// True when this sheet is correcting a trade that already exists.
  bool get _editing => widget.existing != null;

  /// Whether to offer the offer-made / accepted choice. A new trade always
  /// does. An existing one only when it is already at one of those two —
  /// pending, rejected and completed are moved by the buttons on the trade
  /// sheet, and a selector here would silently drag it somewhere else.
  bool get _showsStatus {
    final s = widget.existing?['status'] as String?;
    return s == null || s == 'offer_made' || s == 'accepted';
  }

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _racket.text = (e['racket_desc'] as String?) ?? '';
      _given.text = (e['given_name'] as String?) ?? '';
      _note.text = (e['note'] as String?) ?? '';
      _condition = e['condition'] as String?;
      for (final (c, v) in [
        (_credit, e['offer_credit']),
        (_givenPrice, e['given_price']),
        (_paid, e['paid_amount']),
        (_cost, e['given_cost']),
      ]) {
        if (v is num) c.text = _plain(v);
      }
      // Only the two money-bearing statuses get a selector (see build); any
      // other status is left exactly as it is and never sent.
      final s = e['status'] as String?;
      if (s == 'offer_made' || s == 'accepted') _status = s!;
    }
    _loadProducts();
  }

  Future<void> _loadProducts() async {
    try {
      final rows = await AdminService.fetchProducts();
      if (!mounted) return;
      setState(() => _products = rows);
    } catch (_) {
      // A missing catalogue just means the free-text field is the only route.
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _walkIn.dispose();
    _given.dispose();
    _givenPrice.dispose();
    _paid.dispose();
    _cost.dispose();
    _racket.dispose();
    _credit.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _runSearch(String q) async {
    setState(() => _searching = true);
    final rows = await AdminService.searchPlayers(q);
    if (!mounted) return;
    setState(() {
      _results = rows;
      _searching = false;
    });
  }

  Future<void> _save() async {
    final player = _player;
    // One of the two, mirroring trade_requests_who_chk on the table — a row
    // with neither belongs to nobody and could never be chased up. An existing
    // trade already satisfies this and its seller is not re-picked here.
    if (!_editing && player == null && _walkIn.text.trim().isEmpty) {
      adminToast(context, 'Pick an account or type who sold it', ok: false);
      return;
    }
    if (_racket.text.trim().isEmpty) {
      adminToast(context, 'Say what the racket is', ok: false);
      return;
    }
    final credit = int.tryParse(_credit.text.trim());
    if (credit == null || credit <= 0) {
      adminToast(context, 'Enter what you paid for their racket', ok: false);
      return;
    }

    setState(() => _busy = true);
    // Whichever route was used, the label is stored as written today.
    final givenName =
        (_givenProduct != null ? _productLabel(_givenProduct!) : _given.text)
            .trim();
    final existing = widget.existing;
    final err = existing == null
        ? await AdminService.createTrade(
            playerId: player?['id'] as String?,
            playerName: _walkIn.text,
            racketDesc: _racket.text.trim(),
            condition: _condition,
            offerCredit: credit,
            note: _note.text,
            status: _status,
            givenProductId: _givenProduct?['id'] as String?,
            givenName: givenName,
            givenPrice: num.tryParse(_givenPrice.text.trim()),
            paidAmount: num.tryParse(_paid.text.trim()),
            givenCost: num.tryParse(_cost.text.trim()),
          )
        : await AdminService.updateTrade(existing['id'] as String, {
            'racket_desc': _racket.text.trim(),
            'condition': _condition,
            'offer_credit': credit,
            'note': _note.text.trim(),
            // Clearing a field has to be possible, so these are sent even when
            // empty — unlike the insert, where absent means "leave the default".
            'given_name': givenName.isEmpty ? null : givenName,
            if (_givenProduct != null) 'given_product_id': _givenProduct!['id'],
            'given_price': num.tryParse(_givenPrice.text.trim()),
            'paid_amount': num.tryParse(_paid.text.trim()),
            'given_cost': num.tryParse(_cost.text.trim()),
            // Only when this trade is at one of the two statuses the selector
            // covers; anything else belongs to the buttons on the trade sheet.
            if (_showsStatus) 'status': _status,
          });
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      adminToast(context, err, ok: false);
      return;
    }
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.86,
        decoration: const BoxDecoration(
            color: AdminColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
        child: Column(children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
                color: AdminColors.line,
                borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 12, 6),
            child: Row(children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_editing ? 'The swap' : 'Record a trade-in',
                          style: AdminText.h2()),
                      const SizedBox(height: 2),
                      Text(
                          _editing
                              ? 'What changed hands, and what it made'
                              : 'A racket taken in outside the app',
                          style: AdminText.small()),
                    ]),
              ),
              IconButton(
                  icon: const Icon(Icons.close_rounded,
                      color: AdminColors.inkSoft),
                  onPressed: () => Navigator.pop(context)),
            ]),
          ),
          const Divider(height: 16, color: AdminColors.lineSoft),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
              children: [
                _label('Who sold it'),
                // Settled on an existing trade — re-picking the seller here
                // would be a different trade, not an edit of this one.
                if (_editing)
                  _staticRow(_AdminRequestsScreenState._playerName(
                      widget.existing!))
                else if (_player != null)
                  _selectedPlayer()
                else ...[
                  // Two ways in, and only one is needed: link an account, or
                  // just write the name down for someone who has never
                  // installed the app.
                  TextField(
                    controller: _walkIn,
                    style: AdminText.body(),
                    textCapitalization: TextCapitalization.words,
                    onChanged: (_) => setState(() {}),
                    decoration: _dec('Their name'),
                  ),
                  const SizedBox(height: 10),
                  Row(children: [
                    const Expanded(child: Divider(color: AdminColors.lineSoft)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text('or link an account',
                          style: AdminText.small(AdminColors.inkFaint)),
                    ),
                    const Expanded(child: Divider(color: AdminColors.lineSoft)),
                  ]),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _search,
                    style: AdminText.body(),
                    onChanged: _runSearch,
                    decoration: _dec('Search by @username'),
                  ),
                  const SizedBox(height: 8),
                  if (_searching)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AdminColors.primary),
                        ),
                      ),
                    )
                  else if (_search.text.trim().isNotEmpty && _results.isEmpty)
                    Text('No player matches that username.',
                        style: AdminText.small(AdminColors.inkFaint))
                  else
                    for (final p in _results)
                      InkWell(
                        onTap: () => setState(() {
                          _player = p;
                          _results = [];
                          // A linked account wins over a typed name; drop it
                          // so the sheet can't imply both are being saved.
                          _walkIn.clear();
                        }),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          child: Row(children: [
                            AdminAvatar(
                                _AdminRequestsScreenState._initials(
                                    (p['name'] as String?) ?? '?'),
                                size: 30),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                  '${p['name'] ?? 'Player'}  ·  @${p['username'] ?? ''}',
                                  style: AdminText.body(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ]),
                        ),
                      ),
                ],
                const SizedBox(height: 16),
                _label('Racket'),
                TextField(
                    controller: _racket,
                    style: AdminText.body(),
                    textCapitalization: TextCapitalization.sentences,
                    decoration: _dec('e.g. Babolat Viper 2023')),
                const SizedBox(height: 16),
                _label('Racket given back (optional)'),
                if (_givenProduct != null)
                  _selectedGiven()
                else ...[
                  TextField(
                    controller: _given,
                    style: AdminText.body(),
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) => setState(() {}),
                    decoration: _dec('What they walked out with'),
                  ),
                  if (_products.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      const Expanded(
                          child: Divider(color: AdminColors.lineSoft)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Text('or pick from the store',
                            style: AdminText.small(AdminColors.inkFaint)),
                      ),
                      const Expanded(
                          child: Divider(color: AdminColors.lineSoft)),
                    ]),
                    const SizedBox(height: 10),
                    TextField(
                      style: AdminText.body(),
                      onChanged: (v) => setState(() => _givenQuery = v),
                      decoration: _dec('Search the catalogue'),
                    ),
                    const SizedBox(height: 8),
                    for (final p in _matchingProducts())
                      InkWell(
                        onTap: () => setState(() {
                          _givenProduct = p;
                          _givenQuery = '';
                          // A catalogue pick wins over free text.
                          _given.clear();
                          _fillFromProduct(p);
                        }),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          child: Row(children: [
                            const Icon(Icons.sports_tennis_rounded,
                                size: 17, color: AdminColors.inkSoft),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(_productLabel(p),
                                  style: AdminText.body(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ]),
                        ),
                      ),
                  ],
                ],
                const SizedBox(height: 16),
                // The three prices in a swap, kept together because the profit
                // below is made of all three — the credit used to live in its
                // own section further down, where you could not see what it did
                // to the deal.
                _label('The money'),
                Row(children: [
                  Expanded(
                      child: _money(_credit, 'We paid for theirs',
                          onChanged: () => _syncPaid())),
                  const SizedBox(width: 10),
                  Expanded(child: _money(_cost, 'The new one cost us')),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                      child: _money(_givenPrice, 'We sold the new one for',
                          onChanged: () => _syncPaid())),
                  const SizedBox(width: 10),
                  Expanded(child: _profitBox()),
                ]),
                const SizedBox(height: 10),
                _money(_paid, 'They handed over, in cash'),
                const SizedBox(height: 8),
                Text(
                  'Picking from the store fills the sale price and the cost in '
                  'for you. The cash figure starts at the sale price minus the '
                  'credit — change it if they actually paid something else. It '
                  'is a record only; the profit above is the three prices.',
                  style: AdminText.small(AdminColors.inkFaint),
                ),
                const SizedBox(height: 6),
                Text(
                  'Once this is accepted, Reports counts all three: the sale as '
                  'money in, the cost and the credit as money out. Do NOT also '
                  'ring this racket up as a store order — it would be counted '
                  'twice.',
                  style: AdminText.small(AdminColors.warn),
                ),
                const SizedBox(height: 16),
                _label('Condition'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final e in _conditions.entries)
                      _chip(e.value, _condition == e.key,
                          () => setState(() => _condition = e.key)),
                  ],
                ),
                if (_showsStatus) ...[
                  const SizedBox(height: 16),
                  _label('Status'),
                  Row(children: [
                    _chip('Offer made', _status == 'offer_made',
                        () => setState(() => _status = 'offer_made')),
                    const SizedBox(width: 8),
                    _chip('Accepted', _status == 'accepted',
                        () => setState(() => _status = 'accepted')),
                  ]),
                  const SizedBox(height: 8),
                  Text(
                    _status == 'accepted'
                        ? 'Accepted puts the whole deal into Reports straight '
                            'away — the sale, the cost and the credit.'
                        : 'An offer moves no money yet. Mark it accepted once '
                            'the rackets and the money have actually changed '
                            'hands.',
                    style: AdminText.small(_status == 'accepted'
                        ? AdminColors.warn
                        : AdminColors.inkSoft),
                  ),
                ],
                const SizedBox(height: 16),
                _label('Note (optional)'),
                TextField(
                    controller: _note,
                    style: AdminText.body(),
                    maxLines: 3,
                    decoration: _dec('Anything worth remembering')),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 26),
            decoration: const BoxDecoration(
                color: AdminColors.surfaceAlt,
                border: Border(top: BorderSide(color: AdminColors.lineSoft))),
            child: AdminButton(
                _busy
                    ? 'Saving…'
                    : (_editing ? 'Save the swap' : 'Save trade-in'),
                full: true,
                height: 48,
                onPressed: _busy ? null : _save),
          ),
        ]),
      ),
    );
  }

  /// Prefills the money from the catalogue: the sale price if the product is on
  /// sale, otherwise its price, and the admin-only cost from product_costs.
  /// Only fills blanks — a figure already typed by hand is never overwritten.
  void _fillFromProduct(Map<String, dynamic> p) {
    final onSale = p['on_sale'] == true && p['sale_price'] != null;
    final price = (onSale ? p['sale_price'] : p['price']) as num?;
    // fetchProducts embeds product_costs(cost); PostgREST hands back either a
    // single object or a one-row list depending on the relationship.
    final costRaw = p['product_costs'];
    final cost = costRaw is List
        ? (costRaw.isEmpty ? null : (costRaw.first as Map)['cost'] as num?)
        : (costRaw as Map?)?['cost'] as num?;

    if (price != null && _givenPrice.text.trim().isEmpty) {
      _givenPrice.text = _plain(price);
    }
    if (cost != null && _cost.text.trim().isEmpty) {
      _cost.text = _plain(cost);
    }
    _syncPaid();
  }

  /// What they hand over is the ticket price less the credit we gave them.
  /// A default, not a rule — it stays editable for a part payment or a
  /// haggled number.
  void _syncPaid() {
    if (_paid.text.trim().isNotEmpty) return;
    final price = num.tryParse(_givenPrice.text.trim());
    if (price == null) return;
    final credit = num.tryParse(_credit.text.trim()) ?? 0;
    final due = price - credit;
    _paid.text = _plain(due < 0 ? 0 : due);
  }

  static String _plain(num v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  /// Profit on this swap: sold for, less what it cost us, less what we paid for
  /// their old racket. Same sum as [_AdminRequestsScreenState._recordedProfit]
  /// and as the P&L — see the note there for why paid_amount is not in it.
  num? get _dealProfit {
    final price = num.tryParse(_givenPrice.text.trim());
    if (price == null) return null;
    final cost = num.tryParse(_cost.text.trim()) ?? 0;
    final credit = num.tryParse(_credit.text.trim()) ?? 0;
    return price - cost - credit;
  }

  /// Catalogue rows matching what has been typed, capped so the sheet cannot
  /// turn into an endless list. An empty query shows the newest few.
  List<Map<String, dynamic>> _matchingProducts() {
    final q = _givenQuery.trim().toLowerCase();
    final hits = q.isEmpty
        ? _products
        : _products.where((p) {
            final hay = '${p['name'] ?? ''} ${p['brand'] ?? ''}'.toLowerCase();
            return hay.contains(q);
          });
    return hits.take(6).toList();
  }

  static String _productLabel(Map<String, dynamic> p) {
    final brand = (p['brand'] as String?)?.trim() ?? '';
    final name = (p['name'] as String?)?.trim() ?? 'Product';
    return brand.isEmpty ? name : '$brand $name';
  }

  /// A small labelled EGP field. [onChanged] runs after the rebuild so
  /// dependent figures (the profit line, the suggested "they paid") follow.
  Widget _money(TextEditingController c, String label,
          {VoidCallback? onChanged}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label.toUpperCase(), style: AdminText.kicker()),
        const SizedBox(height: 6),
        TextField(
          controller: c,
          keyboardType: TextInputType.number,
          style: AdminText.sans(17, FontWeight.w800, AdminColors.ink),
          onChanged: (_) => setState(() => onChanged?.call()),
          decoration: _dec('0').copyWith(
            prefixText: 'EGP ',
            prefixStyle: AdminText.small(AdminColors.inkFaint),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
        ),
      ]);

  Widget _profitBox() {
    final p = _dealProfit;
    final tone = p == null
        ? AdminColors.inkFaint
        : (p < 0 ? AdminColors.danger : AdminColors.success);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('PROFIT ON THIS DEAL', style: AdminText.kicker()),
      const SizedBox(height: 6),
      Container(
        height: 48,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: p == null
              ? AdminColors.surfaceAlt
              : tone.withValues(alpha: .10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: p == null ? AdminColors.line : tone.withValues(alpha: .5)),
        ),
        child: Text(
          p == null ? '—' : 'EGP ${_plain(p)}',
          style: AdminText.sans(17, FontWeight.w800, tone),
        ),
      ),
    ]);
  }

  Widget _selectedGiven() => Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: AdminColors.surfaceAlt,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: AdminColors.line),
        ),
        child: Row(children: [
          const Icon(Icons.sports_tennis_rounded,
              size: 18, color: AdminColors.inkSoft),
          const SizedBox(width: 10),
          Expanded(
            child: Text(_productLabel(_givenProduct!),
                style: AdminText.strong(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          TextButton(
            onPressed: () => setState(() {
              _givenProduct = null;
              _givenQuery = '';
            }),
            child: Text('Change', style: AdminText.strong(AdminColors.primary)),
          ),
        ]),
      );

  /// A settled value the sheet shows but will not let you change.
  Widget _staticRow(String text) => Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: AdminColors.surfaceAlt,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: AdminColors.line),
        ),
        child: Row(children: [
          AdminAvatar(_AdminRequestsScreenState._initials(text), size: 32),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: AdminText.strong(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
        ]),
      );

  Widget _selectedPlayer() => Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: AdminColors.surfaceAlt,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: AdminColors.line),
        ),
        child: Row(children: [
          AdminAvatar(
              _AdminRequestsScreenState._initials(
                  (_player!['name'] as String?) ?? '?'),
              size: 32),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
                '${_player!['name'] ?? 'Player'}  ·  @${_player!['username'] ?? ''}',
                style: AdminText.strong(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          TextButton(
            onPressed: () => setState(() {
              _player = null;
              _search.clear();
              _results = [];
            }),
            child: Text('Change', style: AdminText.strong(AdminColors.primary)),
          ),
        ]),
      );

  Widget _chip(String label, bool on, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: on
                ? AdminColors.primary.withValues(alpha: .14)
                : AdminColors.surfaceAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: on ? AdminColors.primary : AdminColors.line),
          ),
          child: Text(label,
              style: AdminText.sans(12.5, FontWeight.w700,
                  on ? AdminColors.primary : AdminColors.inkSoft)),
        ),
      );

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Text(t.toUpperCase(), style: AdminText.kicker()),
      );

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: AdminText.body(AdminColors.inkFaint),
        filled: true,
        fillColor: AdminColors.surfaceAlt,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AdminColors.line)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AdminColors.line)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AdminColors.primary)),
      );
}

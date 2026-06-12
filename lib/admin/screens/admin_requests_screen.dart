import 'package:flutter/material.dart';
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
    final results = await Future.wait([
      AdminService.fetchRepairs(),
      AdminService.fetchTrades(),
    ]);
    if (!mounted) return;
    setState(() {
      _repairs = results[0];
      _trades = results[1];
      _loading = false;
    });
  }

  static String _playerName(Map row) =>
      (row['profiles'] as Map?)?['name'] as String? ?? 'Player';

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
      footer: status == 'pending'
          ? AdminButton('Send quote', full: true, height: 50,
              icon: Icons.check_rounded, onPressed: () async {
              Navigator.pop(context);
              await AdminService.updateRepair(r['id'] as String, {
                'status': 'quoted',
                'quote_amount': int.tryParse(quoteC.text) ?? 0,
              });
              await _load();
              if (mounted) adminToast(context, 'Quote sent to ${_playerName(r)}');
            })
          : next != null && next != 'collected'
              ? AdminButton(advanceLabel[next]!, full: true, height: 50,
                  icon: Icons.check_rounded, onPressed: () async {
                  Navigator.pop(context);
                  await AdminService.updateRepair(
                      r['id'] as String, {'status': next});
                  await _load();
                  if (mounted) {
                    adminToast(context,
                        '${_shortId(r['id'] as String?)} → ${_repairLabel[next]}');
                  }
                })
              : next == 'collected'
                  ? AdminButton('Mark collected', full: true, height: 50,
                      variant: AdminBtn.success, onPressed: () async {
                      Navigator.pop(context);
                      await AdminService.updateRepair(
                          r['id'] as String, {'status': 'collected'});
                      await _load();
                      if (mounted) adminToast(context, 'Repair complete');
                    })
                  : null,
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
          const SizedBox(height: 16),
          if (_trades.isEmpty)
            Container(
              padding: const EdgeInsets.all(28),
              alignment: Alignment.center,
              child: Text('No trade-in requests yet',
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
                              Text(
                                  'Asking ${_egp(t['asking_credit'])}',
                                  style:
                                      AdminText.small(AdminColors.inkSoft)),
                              if (t['offer_credit'] != null) ...[
                                const SizedBox(width: 8),
                                Text('→ ${_egp(t['offer_credit'])}',
                                    style: AdminText.sans(12, FontWeight.w700,
                                        AdminColors.primary)),
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

  void _openTrade(Map<String, dynamic> t) {
    final asking = (t['asking_credit'] as num?)?.toInt() ?? 0;
    final existingOffer = (t['offer_credit'] as num?)?.toInt();
    final offerC = TextEditingController(
        text: '${existingOffer ?? (asking * 0.85).round()}');
    final status = t['status'] as String? ?? 'pending';

    adminSheet(
      context,
      title: t['racket_desc'] as String? ?? '—',
      sub: '${_shortId(t['id'] as String?)} · ${_playerName(t)}',
      heightFactor: 0.68,
      footer: status == 'pending'
          ? AdminButton('Send offer', full: true, height: 50,
              icon: Icons.check_rounded, onPressed: () async {
              Navigator.pop(context);
              await AdminService.updateTrade(t['id'] as String, {
                'status': 'offer_made',
                'offer_credit': int.tryParse(offerC.text) ?? 0,
              });
              await _load();
              if (mounted) adminToast(context, 'Offer sent to ${_playerName(t)}');
            })
          : status == 'offer_made'
              ? AdminButton('Mark accepted', full: true, height: 50,
                  variant: AdminBtn.success, onPressed: () async {
                  Navigator.pop(context);
                  await AdminService.updateTrade(
                      t['id'] as String, {'status': 'accepted'});
                  await _load();
                  if (mounted) adminToast(context, 'Trade accepted — credit issued');
                })
              : null,
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _kv('Condition', t['condition'] as String? ?? '—'),
          const SizedBox(width: 10),
          _kv('Asking', _egp(t['asking_credit'])),
          const SizedBox(width: 10),
          _kv('Your offer',
              t['offer_credit'] != null ? _egp(t['offer_credit']) : '—'),
        ]),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: AdminColors.surfaceAlt,
              borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text("PLAYER'S NOTE", style: AdminText.kicker()),
            const SizedBox(height: 6),
            Text(t['notes'] as String? ?? 'No notes provided.',
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

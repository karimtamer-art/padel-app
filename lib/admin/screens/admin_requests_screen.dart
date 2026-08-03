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

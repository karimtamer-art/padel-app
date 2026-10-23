import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';
import '../data/admin_service.dart';

// Organizer entry manager: add pairs (real app players by @username, or guests
// by name) and remove entries — for events where not everyone is on the app yet.
// Website registrations (padel-rivals.com) are listed too, with one-tap "Add to
// draw": the server links each person to their app account by phone so their
// results count, and falls back to a guest (admin_web_to_draw).

Future<void> showTournamentEntries(
  BuildContext context, {
  required String tournamentId,
  required String tournamentName,
  VoidCallback? onChanged,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _EntriesSheet(
      tournamentId: tournamentId,
      tournamentName: tournamentName,
      onChanged: onChanged,
    ),
  );
}

class _EntriesSheet extends StatefulWidget {
  final String tournamentId, tournamentName;
  final VoidCallback? onChanged;
  const _EntriesSheet({
    required this.tournamentId,
    required this.tournamentName,
    this.onChanged,
  });

  @override
  State<_EntriesSheet> createState() => _EntriesSheetState();
}

class _Side {
  final TextEditingController ctrl = TextEditingController();
  String? linkedId, linkedName;
  void reset() {
    ctrl.clear();
    linkedId = null;
    linkedName = null;
  }
}

class _EntriesSheetState extends State<_EntriesSheet> {
  bool _loading = true, _busy = false;
  List<Map<String, dynamic>> _entries = [];
  List<Map<String, dynamic>> _web = [];
  String? _webBusy; // registration id being added
  final _p1 = _Side();
  final _p2 = _Side();
  int _searchSide = -1; // 0 = player, 1 = partner, -1 = none
  List<Map<String, dynamic>> _results = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _p1.ctrl.dispose();
    _p2.ctrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      AdminService.tournamentEntries(widget.tournamentId),
      AdminService.webRegistrations(widget.tournamentId),
    ]);
    if (!mounted) return;
    setState(() {
      _entries = results[0];
      _web = results[1];
      _loading = false;
    });
  }

  Future<void> _onType(int side, String text) async {
    final s = side == 0 ? _p1 : _p2;
    if (s.linkedId != null && text != s.linkedName) {
      s.linkedId = null;
      s.linkedName = null;
    }
    setState(() => _searchSide = side);
    final rows = await AdminService.searchPlayers(text);
    if (!mounted || _searchSide != side) return;
    setState(() => _results = rows);
  }

  void _pick(int side, Map<String, dynamic> r) {
    final s = side == 0 ? _p1 : _p2;
    setState(() {
      s.linkedId = r['id'] as String?;
      s.linkedName = (r['name'] as String?)?.trim();
      s.ctrl.text = s.linkedName ?? '';
      _results = [];
      _searchSide = -1;
    });
  }

  Future<void> _add() async {
    final name1 = _p1.linkedName ?? _p1.ctrl.text.trim();
    if (name1.isEmpty) {
      adminToast(context, 'Enter a name for the first player', ok: false);
      return;
    }
    setState(() => _busy = true);
    final err = await AdminService.addTournamentEntry(
      widget.tournamentId,
      playerId: _p1.linkedId,
      playerName: _p1.ctrl.text.trim().isEmpty ? _p1.linkedName : _p1.ctrl.text.trim(),
      partnerId: _p2.linkedId,
      partnerName: _p2.ctrl.text.trim().isEmpty ? _p2.linkedName : _p2.ctrl.text.trim(),
    );
    if (!mounted) return;
    if (err != null) {
      setState(() => _busy = false);
      adminToast(context, err, ok: false);
      return;
    }
    _p1.reset();
    _p2.reset();
    _searchSide = -1;
    _results = [];
    await _load();
    widget.onChanged?.call();
    if (mounted) setState(() => _busy = false);
    if (mounted) adminToast(context, 'Pair added');
  }

  Future<void> _remove(Map<String, dynamic> e) async {
    final label = _label(e);
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AdminColors.surface,
        title: Text('Remove $label?', style: AdminText.sans(16, FontWeight.w800, AdminColors.ink)),
        content: Text('They come out of the tournament. If the draw is already made they’re marked withdrawn.',
            style: AdminText.body(AdminColors.inkSoft)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
        ],
      ),
    );
    if (sure != true) return;
    final err = await AdminService.removeTournamentEntry(e['id'] as String);
    if (!mounted) return;
    if (err != null) {
      adminToast(context, err, ok: false);
      return;
    }
    await _load();
    widget.onChanged?.call();
  }

  static String _label(Map<String, dynamic> e) {
    final p = (e['player_name'] as String?)?.trim();
    final pa = (e['partner_name'] as String?)?.trim();
    final player = (p != null && p.isNotEmpty) ? p : 'Player';
    return (pa != null && pa.isNotEmpty) ? '$player / $pa' : player;
  }

  bool _isGuest(Map<String, dynamic> e) => e['player_id'] == null;

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        height: h * 0.9,
        decoration: const BoxDecoration(
          color: AdminColors.bg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(children: [
          const SizedBox(height: 8),
          Container(width: 42, height: 4,
              decoration: BoxDecoration(color: AdminColors.line, borderRadius: BorderRadius.circular(4))),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 10, 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Entries', style: AdminText.sans(18, FontWeight.w800, AdminColors.ink)),
                  const SizedBox(height: 3),
                  Text('${widget.tournamentName} · ${_entries.length} pairs',
                      style: AdminText.small(AdminColors.inkSoft)),
                ]),
              ),
              IconButton(
                  icon: const Icon(Icons.close_rounded, color: AdminColors.inkSoft),
                  onPressed: () => Navigator.pop(context)),
            ]),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: AdminColors.primary))
                : ListView(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
                    children: [
                      _addCard(),
                      if (_web.isNotEmpty) ..._webSection(),
                      const SizedBox(height: 18),
                      Text('CURRENT PAIRS', style: AdminText.kicker()),
                      const SizedBox(height: 8),
                      if (_entries.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Center(child: Text('No entries yet — add pairs above.', style: AdminText.small())),
                        )
                      else
                        for (var i = 0; i < _entries.length; i++) _entryRow(i, _entries[i]),
                    ],
                  ),
          ),
        ]),
      ),
    );
  }

  Widget _addCard() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: AdminColors.surface,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: AdminColors.lineSoft)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Add a pair', style: AdminText.sans(14.5, FontWeight.w800, AdminColors.ink)),
          const SizedBox(height: 2),
          Text('Type a name for a guest, or @username to link an app player.',
              style: AdminText.small(AdminColors.inkFaint)),
          const SizedBox(height: 12),
          _sideField(0, 'Player 1', _p1),
          const SizedBox(height: 10),
          _sideField(1, 'Partner (optional)', _p2),
          const SizedBox(height: 14),
          AdminButton(_busy ? 'Adding…' : 'Add pair',
              full: true, height: 46, icon: Icons.person_add_alt_1_rounded,
              onPressed: _busy ? null : _add),
        ]),
      );

  Widget _sideField(int side, String hint, _Side s) {
    final linked = s.linkedId != null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
            color: AdminColors.surfaceAlt,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: linked ? AdminColors.primary : AdminColors.line)),
        child: Row(children: [
          Icon(linked ? Icons.person_rounded : Icons.person_outline_rounded,
              size: 17, color: linked ? AdminColors.primary : AdminColors.inkFaint),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: s.ctrl,
              onChanged: (t) => _onType(side, t),
              onTap: () => setState(() => _searchSide = side),
              style: AdminText.body(),
              decoration: InputDecoration(
                isCollapsed: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 13),
                border: InputBorder.none,
                hintText: hint,
                hintStyle: AdminText.small(AdminColors.inkFaint),
              ),
            ),
          ),
          if (linked)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text('App player', style: AdminText.sans(10.5, FontWeight.w800, AdminColors.primary)),
            ),
        ]),
      ),
      if (_searchSide == side && _results.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(top: 6),
          decoration: BoxDecoration(
              color: AdminColors.surface,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: AdminColors.line)),
          child: Column(children: [
            for (final r in _results.take(5))
              InkWell(
                onTap: () => _pick(side, r),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(children: [
                    Expanded(child: Text((r['name'] as String?) ?? 'Player',
                        style: AdminText.sans(13, FontWeight.w700, AdminColors.ink))),
                    Text('@${(r['username'] as String?) ?? ''}',
                        style: AdminText.mono(11, FontWeight.w500, AdminColors.inkFaint)),
                  ]),
                ),
              ),
          ]),
        ),
    ]);
  }

  Widget _entryRow(int i, Map<String, dynamic> e) {
    final guest = _isGuest(e);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
          color: AdminColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AdminColors.lineSoft)),
      child: Row(children: [
        SizedBox(width: 22, child: Text('${i + 1}',
            style: AdminText.mono(12, FontWeight.w600, AdminColors.inkFaint))),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_label(e), maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AdminText.sans(13.5, FontWeight.w700, AdminColors.ink)),
            if (guest) ...[
              const SizedBox(height: 1),
              Text('Guest', style: AdminText.sans(10.5, FontWeight.w800, AdminColors.gold)),
            ],
          ]),
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline_rounded, size: 19, color: AdminColors.inkFaint),
          onPressed: () => _remove(e),
        ),
      ]),
    );
  }

  // ── Website registrations ───────────────────────────────────────────────
  static bool _webOpen(Map<String, dynamic> w) =>
      w['entry_id'] == null && (w['status'] == 'pending' || w['status'] == 'confirmed');

  List<Widget> _webSection() {
    final open = _web.where(_webOpen).toList();
    final done = _web.where((w) => w['entry_id'] != null).length;
    return [
      const SizedBox(height: 18),
      Text('FROM THE WEBSITE', style: AdminText.kicker()),
      const SizedBox(height: 4),
      Text(
          'Check the payment, then add them. Anyone whose number matches an app '
          'account goes in as that player, so their results count.'
          '${done > 0 ? ' $done already added.' : ''}',
          style: AdminText.small(AdminColors.inkFaint)),
      const SizedBox(height: 8),
      if (open.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text('Nothing waiting.', style: AdminText.small()),
        )
      else
        for (final w in open) _webRow(w),
    ];
  }

  Widget _who(String name, String? level, String? account) {
    final linked = account != null && account.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(children: [
        Icon(linked ? Icons.person_rounded : Icons.person_outline_rounded,
            size: 15, color: linked ? AdminColors.primary : AdminColors.inkFaint),
        const SizedBox(width: 6),
        Expanded(
          child: Text('$name${level != null ? ' · $level' : ''}',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AdminText.sans(13, FontWeight.w700, AdminColors.ink)),
        ),
        Text(linked ? 'App: $account' : 'Guest',
            style: AdminText.sans(10.5, FontWeight.w800,
                linked ? AdminColors.primary : AdminColors.gold)),
      ]),
    );
  }

  Widget _webRow(Map<String, dynamic> w) {
    final solo = w['needs_partner'] == true;
    final due = (w['amount_due'] as num?)?.toDouble() ?? 0;
    final sender = (w['instapay_sender'] as String?)?.trim();
    final proof = w['proof_path'] as String?;
    final busy = _webBusy == w['id'];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
          color: AdminColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AdminColors.lineSoft)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _who(w['name'] as String? ?? 'Player', w['level'] as String?,
            w['player_account'] as String?),
        if (solo)
          Padding(
            padding: const EdgeInsets.only(top: 3, left: 21),
            child: Text('Needs a partner',
                style: AdminText.sans(11.5, FontWeight.w700, AdminColors.warn)),
          )
        else
          _who(w['partner_name'] as String? ?? 'Partner', w['partner_level'] as String?,
              w['partner_account'] as String?),
        const SizedBox(height: 6),
        Text(
            [
              'WhatsApp ${w['phone'] ?? '—'}',
              due > 0 ? 'EGP ${due.toStringAsFixed(0)} InstaPay' : 'Free entry',
              if (sender != null && sender.isNotEmpty) 'from $sender',
            ].join(' · '),
            style: AdminText.small(AdminColors.inkSoft)),
        const SizedBox(height: 10),
        Row(children: [
          if (proof != null && proof.isNotEmpty) ...[
            Expanded(
              child: AdminButton('Proof',
                  variant: AdminBtn.ghost, height: 38,
                  onPressed: () => _showProof(proof)),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: AdminButton('Reject',
                variant: AdminBtn.danger, height: 38,
                onPressed: _webBusy != null ? null : () => _webReject(w)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: AdminButton(
                busy ? 'Adding…' : (solo ? 'Pair & add' : 'Add to draw'),
                height: 38,
                icon: solo ? Icons.people_alt_outlined : Icons.playlist_add_rounded,
                onPressed: _webBusy != null ? null : () => _webAdd(w)),
          ),
        ]),
      ]),
    );
  }

  Future<void> _webReject(Map<String, dynamic> w) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AdminColors.surface,
        title: Text('Reject ${w['name']}?',
            style: AdminText.sans(16, FontWeight.w800, AdminColors.ink)),
        content: Text(
            'Use this when the payment is not valid. They are NOT told automatically '
            '— message them on WhatsApp. Their spot is freed on the website.',
            style: AdminText.body(AdminColors.inkSoft)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Reject')),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _webBusy = w['id'] as String);
    final err = await AdminService.rejectWebRegistration(w['id'] as String);
    if (!mounted) return;
    if (err != null) {
      setState(() => _webBusy = null);
      adminToast(context, err, ok: false);
      return;
    }
    await _load();
    widget.onChanged?.call();
    if (!mounted) return;
    setState(() => _webBusy = null);
    adminToast(context, 'Rejected');
  }

  Future<void> _showProof(String path) async {
    final url = await AdminService.signProofUrl(path, bucket: 'web-payment-proofs');
    if (!mounted) return;
    if (url == null) {
      adminToast(context, 'Could not load the screenshot.', ok: false);
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (c) => Dialog(
        backgroundColor: AdminColors.surface,
        insetPadding: const EdgeInsets.all(16),
        child: InteractiveViewer(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(url, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }

  Future<void> _webAdd(Map<String, dynamic> w) async {
    String? pairWith;
    if (w['needs_partner'] == true) {
      final others = _web
          .where((o) => o['id'] != w['id'] && o['needs_partner'] == true && _webOpen(o))
          .toList();
      if (others.isEmpty) {
        adminToast(context, 'No other solo player to pair with yet.', ok: false);
        return;
      }
      pairWith = await showDialog<String>(
        context: context,
        builder: (c) => SimpleDialog(
          backgroundColor: AdminColors.surface,
          title: Text('Pair ${w['name']} with…',
              style: AdminText.sans(16, FontWeight.w800, AdminColors.ink)),
          children: [
            for (final o in others)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(c, o['id'] as String),
                child: Text('${o['name']} · ${o['level'] ?? ''}',
                    style: AdminText.body()),
              ),
          ],
        ),
      );
      if (pairWith == null) return;
    }
    final other = pairWith == null
        ? null
        : _web.firstWhere((o) => o['id'] == pairWith, orElse: () => const {});
    setState(() => _webBusy = w['id'] as String);
    final err = await AdminService.webRegistrationToDraw(w['id'] as String, pairWith: pairWith);
    if (!mounted) return;
    if (err != null) {
      setState(() => _webBusy = null);
      adminToast(context, err, ok: false);
      return;
    }
    // Entry is in — now the WhatsApp confirmation (Edge Function).
    final wa = await AdminService.sendWebWhatsApp(
        [w['id'] as String, if (pairWith != null) pairWith]);
    await _load();
    widget.onChanged?.call();
    if (!mounted) return;
    setState(() => _webBusy = null);
    if (wa.status == 'sent') {
      adminToast(context, 'Added to the draw · WhatsApp sent');
      return;
    }
    adminToast(
        context,
        wa.status == 'not_configured'
            ? 'Added to the draw'
            : 'Added to the draw · WhatsApp failed${wa.error != null ? ': ${wa.error}' : ''}',
        ok: wa.status == 'not_configured');
    await _manualWhatsApp(w, other);
  }

  /// Fallback when the API didn't send: one tap per person opens WhatsApp on
  /// this phone with the confirmation already typed.
  Future<void> _manualWhatsApp(Map<String, dynamic> w, Map<String, dynamic>? other) async {
    final targets = <(String name, String phone, String partner)>[];
    void add(String? name, String? phone, String partner) {
      final n = (name ?? '').trim();
      final p = (phone ?? '').trim();
      if (n.isNotEmpty && p.isNotEmpty) targets.add((n, p, partner));
    }
    if (other != null && other.isNotEmpty) {
      add(w['name'] as String?, w['phone'] as String?, (other['name'] as String?) ?? '');
      add(other['name'] as String?, other['phone'] as String?, (w['name'] as String?) ?? '');
    } else {
      add(w['name'] as String?, w['phone'] as String?, (w['partner_name'] as String?) ?? '');
      add(w['partner_name'] as String?, w['partner_phone'] as String?, (w['name'] as String?) ?? '');
    }
    if (targets.isEmpty || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) => SimpleDialog(
        backgroundColor: AdminColors.surface,
        title: Text('Send the confirmation',
            style: AdminText.sans(16, FontWeight.w800, AdminColors.ink)),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('Opens WhatsApp with the message typed — just press Send.',
                style: AdminText.small(AdminColors.inkFaint)),
          ),
          for (final t in targets)
            SimpleDialogOption(
              onPressed: () => _openWhatsApp(t.$1, t.$2, t.$3),
              child: Row(children: [
                const Icon(Icons.chat_outlined, size: 18, color: AdminColors.primary),
                const SizedBox(width: 10),
                Expanded(child: Text('${t.$1} · ${t.$2}', style: AdminText.body())),
              ]),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: () => Navigator.pop(c), child: const Text('Done')),
          ),
        ],
      ),
    );
  }

  /// Egyptian number as typed → wa.me digits (mirrors toWaNumber in the
  /// whatsapp-confirm Edge Function).
  static String _waDigits(String raw) {
    var d = raw.replaceAll(RegExp(r'\D'), '');
    if (d.startsWith('00')) d = d.substring(2);
    if (d.length == 11 && d.startsWith('01')) d = '2$d';
    if (d.length == 10 && d.startsWith('1')) d = '20$d';
    return d;
  }

  Future<void> _openWhatsApp(String name, String phone, String partner) async {
    final first = name.split(RegExp(r'\s+')).first;
    final p = partner.trim();
    final text = 'Hi $first, your entry for ${widget.tournamentName} is confirmed ✅'
        '${p.isNotEmpty ? '\nPartner: $p' : ''}'
        '\nSee you on court! — Padel Rivals';
    final uri = Uri.parse(
        'https://wa.me/${_waDigits(phone)}?text=${Uri.encodeComponent(text)}');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && mounted) {
      adminToast(context, 'Could not open WhatsApp.', ok: false);
    }
  }
}

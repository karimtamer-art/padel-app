import 'package:flutter/material.dart';
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';
import '../data/admin_service.dart';

// Organizer entry manager: add pairs (real app players by @username, or guests
// by name) and remove entries — for events where not everyone is on the app yet.

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
    final rows = await AdminService.tournamentEntries(widget.tournamentId);
    if (!mounted) return;
    setState(() {
      _entries = rows;
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
}

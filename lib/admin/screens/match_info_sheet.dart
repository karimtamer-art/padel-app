import 'package:flutter/material.dart';
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';
import '../data/admin_service.dart';

/// Court and LIVE for each match in a draw. Players see them as soon as they're
/// set, and neither shows while it's empty.
Future<void> showMatchInfoSheet(BuildContext context,
        {required String tournamentId}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MatchInfoSheet(tournamentId: tournamentId),
    );

class _MatchInfoSheet extends StatefulWidget {
  final String tournamentId;
  const _MatchInfoSheet({required this.tournamentId});
  @override
  State<_MatchInfoSheet> createState() => _MatchInfoSheetState();
}

class _MatchInfoSheetState extends State<_MatchInfoSheet> {
  List<Map<String, dynamic>>? _rows;
  bool _loading = true;
  final _courts = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _courts.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final rows = await AdminService.fetchMatchInfo(widget.tournamentId);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  /// A row counts if both pairs are set and it isn't decided: nothing else can
  /// be on a court.
  List<Map<String, dynamic>> get _playable => (_rows ?? const [])
      .where((m) =>
          m['e1'] != null && m['e2'] != null && m['winner_entry'] == null)
      .toList();

  TextEditingController _courtOf(Map<String, dynamic> m) =>
      _courts.putIfAbsent(
          m['id'] as String,
          () => TextEditingController(text: (m['court'] as String?) ?? ''));

  Future<void> _save(Map<String, dynamic> m, {bool? live}) async {
    final status = (m['result_status'] as String?) ?? 'open';
    final wantLive = live ?? status == 'live';
    final err = await AdminService.setMatchInfo(
      m['id'] as String,
      court: _courtOf(m).text,
      live: wantLive,
    );
    if (!mounted) return;
    if (err != null) {
      adminToast(context, err, ok: false);
      return;
    }
    setState(() {
      m['court'] = _courtOf(m).text.trim();
      if (status == 'open' || status == 'live') {
        m['result_status'] = wantLive ? 'live' : 'open';
      }
    });
  }

  static String _pair(Map<String, dynamic>? e) {
    String first(String? n) => (n ?? '').trim().split(RegExp(r'\s+')).first;
    final a = first(e?['player_name'] as String?);
    final b = first(e?['partner_name'] as String?);
    if (a.isEmpty) return 'Pair';
    return b.isEmpty ? a : '$a / $b';
  }

  static String _label(Map<String, dynamic> m) {
    final b = (m['bracket'] as String?) ?? '';
    final slot = ((m['slot'] as num?)?.toInt() ?? 0) + 1;
    final round = (m['round'] as num?)?.toInt() ?? 1;
    return switch (b) {
      'wb' => 'Winners R$round · $slot',
      'lb' => 'Losers R$round · $slot',
      'gf' => 'Grand final',
      _ => '$b · $slot',
    };
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(maxHeight: mq.size.height * 0.85),
        padding: EdgeInsets.fromLTRB(18, 16, 18, 16 + mq.padding.bottom),
        decoration: const BoxDecoration(
          color: AdminColors.bg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Courts & live',
                style: AdminText.sans(18, FontWeight.w800, AdminColors.ink)),
            const SizedBox(height: 2),
            Text('Players see these as soon as you set them.',
                style: AdminText.small(AdminColors.inkSoft)),
            const SizedBox(height: 14),
            Flexible(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(30),
        child: Center(
            child: CircularProgressIndicator(
                strokeWidth: 2.4, color: AdminColors.primary)),
      );
    }
    if (_rows == null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text("Couldn't load this. The server may not have courts yet.",
            textAlign: TextAlign.center, style: AdminText.small()),
      );
    }
    final rows = _playable;
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text('No matches are waiting to be played.',
            textAlign: TextAlign.center, style: AdminText.small()),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      itemCount: rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) => _row(rows[i]),
    );
  }

  Widget _row(Map<String, dynamic> m) {
    final status = (m['result_status'] as String?) ?? 'open';
    final canLive = status == 'open' || status == 'live';
    final court = _courtOf(m);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AdminColors.surface,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: AdminColors.lineSoft),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_label(m), style: AdminText.kicker()),
        const SizedBox(height: 2),
        Text(
          '${_pair(m['e1'] as Map<String, dynamic>?)} v ${_pair(m['e2'] as Map<String, dynamic>?)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AdminText.sans(13.5, FontWeight.w700, AdminColors.ink),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: Focus(
              onFocusChange: (focused) {
                final was = (m['court'] as String?)?.trim() ?? '';
                if (!focused && court.text.trim() != was) _save(m);
              },
              child: TextField(
                controller: court,
                textInputAction: TextInputAction.done,
                style: AdminText.body(),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Court, e.g. 3',
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text('LIVE',
              style: AdminText.sans(12, FontWeight.w800,
                  canLive ? AdminColors.ink : AdminColors.inkFaint)),
          Switch(
            value: status == 'live',
            activeThumbColor: AdminColors.green,
            onChanged: canLive ? (v) => _save(m, live: v) : null,
          ),
        ]),
        if (!canLive)
          Text('A result is waiting to be confirmed.',
              style: AdminText.small(AdminColors.inkFaint)),
      ]),
    );
  }
}

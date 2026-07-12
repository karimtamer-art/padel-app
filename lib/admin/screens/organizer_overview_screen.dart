// ============================================================================
// organizer_overview_screen.dart — the Organizer's console home.
// Events-only KPIs (scoped to their own tournaments), a "reach your community"
// hub, and a broadcast composer that messages their participants (push +
// in-app) via organizer_broadcast. All data is server-scoped to the caller.
// ============================================================================
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../data/admin_service.dart';
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';

class OrganizerOverviewScreen extends StatefulWidget {
  final VoidCallback? onOpenTournaments;
  const OrganizerOverviewScreen({super.key, this.onOpenTournaments});

  @override
  State<OrganizerOverviewScreen> createState() => _OrganizerOverviewScreenState();
}

class _OrganizerOverviewScreenState extends State<OrganizerOverviewScreen> {
  Map<String, dynamic> _kpi = {};
  List<Map<String, dynamic>> _tournaments = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final uid = Supabase.instance.client.auth.currentUser?.id;
    final results = await Future.wait([
      AdminService.organizerOverview(),
      AdminService.fetchTournaments(organizerId: uid),
    ]);
    if (!mounted) return;
    setState(() {
      _kpi = results[0] as Map<String, dynamic>;
      _tournaments = results[1] as List<Map<String, dynamic>>;
      _loading = false;
    });
  }

  int _n(String k) => (_kpi[k] as num?)?.toInt() ?? 0;

  static String _egp(num v) {
    if (v >= 1000) {
      final k = v / 1000;
      return 'EGP ${k == k.roundToDouble() ? k.toStringAsFixed(0) : k.toStringAsFixed(1)}k';
    }
    return 'EGP ${v.toStringAsFixed(0)}';
  }

  static List<Map<String, dynamic>> _activeEntries(Map row) {
    final e = row['tournament_entries'];
    if (e is! List) return const [];
    return e
        .where((x) => x is Map && x['status'] != 'withdrawn' && x['status'] != 'cancelled')
        .map((x) => Map<String, dynamic>.from(x as Map))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AdminColors.primary));
    }
    final accepting = _n('accepting');
    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(AdminUI.screen), children: [
        // events-only KPIs (no store / platform revenue)
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.2,
          children: [
            _kpiCard(Icons.emoji_events_outlined, AdminColors.gold, 'Your tournaments',
                '${_n('tournaments')}',
                accepting > 0 ? '$accepting accepting entries' : 'none accepting'),
            _kpiCard(Icons.groups_outlined, AdminColors.green, 'Total entrants',
                '${_n('entrants')}', 'across your events'),
            _kpiCard(Icons.swap_horiz_rounded, AdminColors.info, 'Entry fees collected',
                _egp(_n('fees')),
                _n('to_verify') > 0 ? '${_n('to_verify')} to verify' : 'all verified'),
            _kpiCard(Icons.notifications_outlined, AdminColors.primary, 'Community reach',
                '${_n('reach')}', 'players you can message'),
          ],
        ),
        const SizedBox(height: 16),
        // reach your community
        AdminCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Reach your community', style: AdminText.cardTitle()),
                Text('Message everyone in your events — push + in-app',
                    style: AdminText.small()),
              ])),
              AdminButton('New broadcast',
                  icon: Icons.add,
                  variant: AdminBtn.primary,
                  onPressed: _n('reach') > 0 ? () => _composer() : null),
            ]),
            const SizedBox(height: 6),
            if (_n('reach') == 0)
              Text('No participants yet — reach unlocks once players enter your events.',
                  style: AdminText.small(AdminColors.inkFaint))
            else ...[
              const SizedBox(height: 6),
              Row(children: [
                _reachStat('${_n('reach')}', 'participants'),
                _reachStat('${_n('largest_event')}', 'largest event'),
                _reachStat('${_n('open_rate')}%', 'avg. open rate'),
              ]),
            ],
          ]),
        ),
        const SizedBox(height: 16),
        // your tournaments
        AdminCard(
          padding: EdgeInsets.zero,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                Expanded(child: Text('Your tournaments', style: AdminText.cardTitle())),
                if (widget.onOpenTournaments != null)
                  GestureDetector(
                    onTap: widget.onOpenTournaments,
                    child: Text('Manage all',
                        style: AdminText.sans(12.5, FontWeight.w700, AdminColors.primary)),
                  ),
              ]),
            ),
            if (_tournaments.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                child: Row(children: [
                  const Icon(Icons.emoji_events_outlined, size: 18, color: AdminColors.inkFaint),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text('No tournaments yet. Create one from the Tournaments section.',
                          style: AdminText.small())),
                ]),
              )
            else
              for (final t in _tournaments) _tourneyRow(t),
          ]),
        ),
      ]),
    );
  }

  Widget _reachStat(String value, String label) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: AdminText.sans(18, FontWeight.w800, AdminColors.ink, ls: -0.5)),
          Text(label, style: AdminText.small(AdminColors.inkFaint)),
        ]),
      );

  Widget _kpiCard(IconData i, Color tone, String label, String value, String foot) =>
      AdminCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
              child: Icon(i, size: 19, color: tone)),
          const Spacer(),
          Text(label, style: AdminText.small()),
          Text(value,
              style: AdminText.sans(21, FontWeight.w800, AdminColors.ink, ls: -0.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          Text(foot,
              style: AdminText.small(AdminColors.inkFaint),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ]),
      );

  Widget _tourneyRow(Map<String, dynamic> t) {
    final name = (t['name'] as String?) ?? 'Tournament';
    final status = (t['status'] as String?) ?? 'open';
    final entrants = _activeEntries(t).length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AdminColors.lineSoft))),
      child: Row(children: [
        Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(
                child: Text(name,
                    style: AdminText.strong(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 8),
            StatusBadge(status),
          ]),
          const SizedBox(height: 4),
          Text('$entrants entrant${entrants == 1 ? '' : 's'}', style: AdminText.small()),
        ])),
        const SizedBox(width: 12),
        AdminButton('Message',
            icon: Icons.notifications_outlined,
            variant: AdminBtn.ghost,
            onPressed: entrants > 0
                ? () => _composer(tournamentId: t['id'] as String?, tournamentName: name)
                : null),
      ]),
    );
  }

  void _composer({String? tournamentId, String? tournamentName}) {
    final audience = tournamentName == null
        ? 'All my participants (${_n('reach')})'
        : 'Everyone in $tournamentName';
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _BroadcastSheet(
        audience: audience,
        tournamentId: tournamentId,
        onSent: _load,
      ),
    );
  }
}

class _BroadcastSheet extends StatefulWidget {
  final String audience;
  final String? tournamentId;
  final VoidCallback onSent;
  const _BroadcastSheet(
      {required this.audience, this.tournamentId, required this.onSent});
  @override
  State<_BroadcastSheet> createState() => _BroadcastSheetState();
}

class _BroadcastSheetState extends State<_BroadcastSheet> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_title.text.trim().isEmpty) return;
    setState(() => _busy = true);
    final err = await AdminService.organizerBroadcast(
      title: _title.text.trim(),
      body: _body.text.trim(),
      tournamentId: widget.tournamentId,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      adminToast(context, err, ok: false);
      return;
    }
    Navigator.pop(context);
    adminToast(context, 'Broadcast sent to your community');
    widget.onSent();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          18, 0, 18, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Container(
        decoration: const BoxDecoration(
            color: AdminColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                  color: AdminColors.line, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          Text('Broadcast to your community', style: AdminText.h2()),
          Text('Reaches participants by push + in-app', style: AdminText.small()),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
                color: AdminColors.surfaceAlt,
                borderRadius: AdminUI.fieldR,
                border: Border.all(color: AdminColors.lineSoft)),
            child: Row(children: [
              const Icon(Icons.groups_outlined, size: 17, color: AdminColors.primary),
              const SizedBox(width: 9),
              Expanded(child: Text(widget.audience, style: AdminText.strong())),
            ]),
          ),
          const SizedBox(height: 12),
          Text('Title', style: AdminText.strong(AdminColors.inkSoft)),
          const SizedBox(height: 6),
          _field(_title, 'e.g. Finals moved to Court 1'),
          const SizedBox(height: 12),
          Text('Message', style: AdminText.strong(AdminColors.inkSoft)),
          const SizedBox(height: 6),
          _field(_body, 'Add the details players need…', lines: 3),
          const SizedBox(height: 16),
          AdminButton(_busy ? 'Sending…' : 'Send broadcast',
              icon: Icons.send,
              variant: AdminBtn.primary,
              full: true,
              onPressed: _busy ? null : _send),
        ]),
      ),
    );
  }

  Widget _field(TextEditingController c, String hint, {int lines = 1}) => TextField(
        controller: c,
        maxLines: lines,
        style: AdminText.body(),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: AdminText.small(AdminColors.inkFaint),
          filled: true,
          fillColor: AdminColors.surfaceAlt,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide: const BorderSide(color: AdminColors.line)),
          enabledBorder: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide: const BorderSide(color: AdminColors.line)),
          focusedBorder: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide: const BorderSide(color: AdminColors.primary)),
        ),
      );
}

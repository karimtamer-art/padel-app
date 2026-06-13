import 'package:flutter/cupertino.dart' show CupertinoDatePicker, CupertinoDatePickerMode, CupertinoButton;
import 'package:flutter/material.dart';
import '../theme/admin_colors.dart';
import '../data/admin_service.dart';
import '../widgets/admin_kit.dart';
import 'package:padel_clay/backend/services/tournament_service.dart';

class AdminTournamentsScreen extends StatefulWidget {
  const AdminTournamentsScreen({super.key});
  @override
  State<AdminTournamentsScreen> createState() => _AdminTournamentsScreenState();
}

class _AdminTournamentsScreenState extends State<AdminTournamentsScreen> {
  List<Map<String, dynamic>> _list = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_loading) setState(() => _loading = true);
    final data = await AdminService.fetchTournaments();
    if (!mounted) return;
    setState(() {
      _list = data;
      _loading = false;
    });
  }

  static int _entryCount(Map row) {
    return _activeEntries(row).length;
  }

  /// Registered (non-withdrawn) entry rows for a tournament.
  static List<Map<String, dynamic>> _activeEntries(Map row) {
    final entries = row['tournament_entries'];
    if (entries is! List) return const [];
    return entries
        .where((e) => e is Map && e['status'] != 'withdrawn')
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  static String _month(String? iso) {
    if (iso == null) return '?';
    try {
      const m = ['JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC'];
      return m[DateTime.parse(iso).month - 1];
    } catch (_) {
      return '?';
    }
  }

  static String _day(String? iso) {
    if (iso == null) return '?';
    try {
      return DateTime.parse(iso).day.toString().padLeft(2, '0');
    } catch (_) {
      return '?';
    }
  }

  static String _dateRange(String? start, String? end) {
    if (start == null) return '—';
    try {
      const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
      final s = DateTime.parse(start);
      final sStr = '${months[s.month - 1]} ${s.day}';
      if (end == null) return sStr;
      final e = DateTime.parse(end);
      if (e.year == s.year && e.month == s.month) return '$sStr – ${e.day}';
      return '$sStr – ${months[e.month - 1]} ${e.day}';
    } catch (_) {
      return start;
    }
  }

  static String _egp(dynamic n) {
    if (n == null) return '—';
    final v = (n as num).toInt();
    return 'EGP $v';
  }

  static String _lvLabel(dynamic minElo, dynamic maxElo) {
    double lvFmt(dynamic elo) {
      final v = ((((elo as num?)?.toInt() ?? 800) - 800) / 200.0).clamp(0.0, 7.0);
      return (v / 0.5).round() * 0.5;
    }
    final minLv = lvFmt(minElo);
    final maxInt = (maxElo as num?)?.toInt() ?? 0;
    if (maxInt > 0) {
      return '${minLv.toStringAsFixed(1)}–${lvFmt(maxElo).toStringAsFixed(1)}';
    }
    return '${minLv.toStringAsFixed(1)}+';
  }

  static String _egpShort(int n) {
    if (n >= 1000000) return 'EGP ${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return 'EGP ${(n / 1000).toStringAsFixed(0)}K';
    return 'EGP $n';
  }

  @override
  Widget build(BuildContext context) {
    final active = _list.where((t) {
      final ds = TournamentService.tournamentStatus(t, _entryCount(t));
      return ds != 'completed' && ds != 'cancelled';
    }).length;
    final totalEntries = _list.fold<int>(0, (s, t) => s + _entryCount(t));
    final totalPrize = _list.fold<int>(
        0, (s, t) => s + ((t['prize_pool'] as num?)?.toInt() ?? 0));
    final totalSpots = _list.fold<int>(
        0,
        (s, t) =>
            s +
            ((t['capacity'] as num?)?.toInt() ?? 0) -
            _entryCount(t));

    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
        children: [
          KpiGrid([
            StatCard(
                icon: Icons.emoji_events_outlined,
                tone: AdminColors.primary,
                label: 'Active events',
                value: '$active'),
            StatCard(
                icon: Icons.groups_outlined,
                tone: AdminColors.green,
                label: 'Pairs registered',
                value: '$totalEntries'),
            StatCard(
                icon: Icons.payments_outlined,
                tone: AdminColors.info,
                label: 'Total prize pool',
                value: _egpShort(totalPrize)),
            StatCard(
                icon: Icons.confirmation_number_outlined,
                tone: AdminColors.gold,
                label: 'Spots left',
                value: '${totalSpots.clamp(0, 99999)}'),
          ]),
          const SizedBox(height: 16),
          AdminSection(
            'All tournaments',
            sub: '${_list.length} events',
            action: AdminButton('Create',
                icon: Icons.add_rounded, height: 34, onPressed: _create),
          ),
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AdminColors.primary),
              ),
            )
          else if (_list.isEmpty)
            Container(
              margin: const EdgeInsets.only(top: 24),
              padding: const EdgeInsets.all(28),
              alignment: Alignment.center,
              child: Text('No tournaments yet — tap Create to add one',
                  style: AdminText.small(AdminColors.inkFaint)),
            )
          else
            for (final t in _list) _card(t),
        ],
      ),
    );
  }

  Widget _card(Map<String, dynamic> t) {
    final registered = _entryCount(t);
    final capacity = (t['capacity'] as num?)?.toInt() ?? 0;
    final fill = capacity > 0 ? (registered / capacity).clamp(0.0, 1.0) : 0.0;
    final status = TournamentService.tournamentStatus(t, registered);
    final revenue = registered * ((t['entry_fee'] as num?)?.toInt() ?? 0);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AdminCard(
        onTap: () => _detail(t),
        padding: EdgeInsets.zero,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 52,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: AdminColors.line),
                  color: AdminColors.surfaceAlt,
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  Container(
                    width: double.infinity,
                    color: AdminColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(_month(t['start_date'] as String?),
                        textAlign: TextAlign.center,
                        style: AdminText.mono(
                            9, FontWeight.w700, AdminColors.primaryInk,
                            ls: 1)),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Text(_day(t['start_date'] as String?),
                        style: AdminText.sans(20, FontWeight.w800, AdminColors.ink)),
                  ),
                ]),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                        child: Text(t['name'] as String? ?? '—',
                            style: AdminText.cardTitle().copyWith(fontSize: 15.5))),
                    StatusBadge(status),
                  ]),
                  const SizedBox(height: 4),
                  Row(children: [
                    const Icon(Icons.place_outlined,
                        size: 13, color: AdminColors.inkFaint),
                    const SizedBox(width: 4),
                    Expanded(
                        child: Text(t['venue_name'] as String? ?? '—',
                            style: AdminText.small(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)),
                  ]),
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    _tag(Icons.calendar_today_outlined,
                        _dateRange(t['start_date'] as String?, t['end_date'] as String?)),
                    if (t['prize_pool'] != null)
                      _tag(Icons.military_tech_outlined,
                          _egpShort((t['prize_pool'] as num).toInt())),
                    if (((t['min_elo'] as num?)?.toInt() ?? 0) > 0)
                      _tag(Icons.shield_outlined,
                          'Lv ${_lvLabel(t['min_elo'], t['max_elo'])}'),
                  ]),
                ]),
              ),
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: const BoxDecoration(
                color: AdminColors.surfaceAlt,
                border: Border(top: BorderSide(color: AdminColors.lineSoft))),
            child: Row(children: [
              Text('$registered/$capacity pairs',
                  style: AdminText.mono(11, FontWeight.w500, AdminColors.inkSoft)),
              const SizedBox(width: 10),
              Expanded(
                  child: AdminProgress(fill,
                      color: fill >= 1.0 ? AdminColors.warn : AdminColors.primary)),
              const SizedBox(width: 10),
              Text(_egpShort(revenue), style: AdminText.strong()),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _tag(IconData? icon, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: AdminColors.surfaceAlt,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AdminColors.lineSoft)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: AdminColors.inkSoft),
            const SizedBox(width: 4)
          ],
          Text(text,
              style: AdminText.sans(11, FontWeight.w600, AdminColors.inkSoft)),
        ]),
      );

  void _detail(Map<String, dynamic> t) {
    final entries = _activeEntries(t)
      ..sort((a, b) => ((a['registered_at'] as String?) ?? '')
          .compareTo((b['registered_at'] as String?) ?? ''));
    final registered = entries.length;
    final fee = (t['entry_fee'] as num?)?.toInt() ?? 0;
    final prize = (t['prize_pool'] as num?)?.toInt() ?? 0;
    final courtFees = (t['court_fees'] as num?)?.toInt() ?? 0;
    final capacity = (t['capacity'] as num?)?.toInt() ?? 0;
    final income = registered * fee;
    final net = income - prize - courtFees;

    adminSheet(
      context,
      title: t['name'] as String? ?? '—',
      sub: '${t['venue_name'] ?? '—'} · ${_dateRange(t['start_date'] as String?, t['end_date'] as String?)}',
      heightFactor: 0.85,
      footer: Row(children: [
        Expanded(
          child: AdminButton('Edit',
              height: 50,
              variant: AdminBtn.ghost,
              icon: Icons.edit_outlined,
              onPressed: () {
                Navigator.pop(context);
                _edit(t);
              }),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: AdminButton('Delete',
              height: 50,
              variant: AdminBtn.danger,
              icon: Icons.delete_outline_rounded,
              onPressed: () async {
                Navigator.pop(context);
                await AdminService.deleteTournament(t['id'] as String);
                await _load();
                if (mounted) adminToast(context, 'Tournament deleted');
              }),
        ),
      ]),
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AdminButton('Manage draw & results',
            full: true,
            height: 46,
            icon: Icons.account_tree_outlined,
            onPressed: () {
              Navigator.pop(context);
              _bracketSheet(t);
            }),
        const SizedBox(height: 14),
        Row(children: [
          _kv('Prize pool', _egp(t['prize_pool'])),
          const SizedBox(width: 10),
          _kv('Entry fee', _egp(t['entry_fee'])),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          _kv('Registered', '$registered pairs'),
          const SizedBox(width: 10),
          _kv('Spots left', '${(capacity - registered).clamp(0, capacity)}'),
        ]),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: AdminColors.surfaceAlt,
              borderRadius: BorderRadius.circular(13)),
          child: Column(children: [
            _line('Entry income', _egp(income), AdminColors.ink),
            _line('Prize pool', '− ${_egp(prize)}', AdminColors.danger),
            if (courtFees > 0)
              _line('Court fees', '− ${_egp(courtFees)}', AdminColors.danger),
            const Divider(height: 18, color: AdminColors.line),
            _line('Net', _egp(net),
                net >= 0 ? AdminColors.success : AdminColors.danger,
                bold: true),
          ]),
        ),
        const SizedBox(height: 18),
        Row(children: [
          Text('REGISTERED PAIRS', style: AdminText.kicker()),
          const Spacer(),
          Text('$registered', style: AdminText.kicker()),
        ]),
        const SizedBox(height: 8),
        if (entries.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 18),
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: AdminColors.surfaceAlt,
                borderRadius: BorderRadius.circular(12)),
            child: Text('No pairs registered yet',
                style: AdminText.small(AdminColors.inkFaint)),
          )
        else
          Container(
            decoration: BoxDecoration(
                color: AdminColors.surfaceAlt,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AdminColors.lineSoft)),
            child: Column(children: [
              for (int i = 0; i < entries.length; i++)
                _pairRow(i + 1, entries[i], divider: i > 0),
            ]),
          ),
      ]),
    );
  }

  Widget _pairRow(int seed, Map<String, dynamic> e, {bool divider = false}) {
    final player = (e['player_name'] as String?)?.trim();
    final partner = (e['partner_name'] as String?)?.trim();
    final label = (partner != null && partner.isNotEmpty)
        ? '${player?.isNotEmpty == true ? player : 'Player'} / $partner'
        : (player?.isNotEmpty == true ? player! : 'Player');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: divider
            ? const Border(top: BorderSide(color: AdminColors.lineSoft))
            : null,
      ),
      child: Row(children: [
        SizedBox(
          width: 22,
          child: Text('$seed',
              style: AdminText.mono(11, FontWeight.w700, AdminColors.inkFaint)),
        ),
        Expanded(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AdminText.sans(13, FontWeight.w700, AdminColors.ink)),
        ),
        if (partner == null || partner.isEmpty)
          Text('solo / no partner',
              style: AdminText.small(AdminColors.warn)),
      ]),
    );
  }

  Widget _kv(String k, String v) => Expanded(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: AdminColors.surfaceAlt,
              borderRadius: BorderRadius.circular(11)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(k.toUpperCase(), style: AdminText.kicker()),
            const SizedBox(height: 4),
            Text(v, style: AdminText.sans(14, FontWeight.w800, AdminColors.ink)),
          ]),
        ),
      );

  Widget _line(String k, String v, Color c, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Text(k,
              style: bold
                  ? AdminText.strong()
                  : AdminText.small(AdminColors.inkSoft)),
          const Spacer(),
          Text(v,
              style: AdminText.sans(
                  bold ? 15 : 13, bold ? FontWeight.w800 : FontWeight.w700, c)),
        ]),
      );

  void _create() => _form(null);
  void _edit(Map<String, dynamic> t) => _form(t);

  // ── Draw & results management ─────────────────────────────────

  void _bracketSheet(Map<String, dynamic> t) {
    final tid = t['id'] as String;
    adminSheet(
      context,
      title: 'Draw — ${t['name'] ?? ''}',
      sub: 'Tap a pending match to record its winner',
      heightFactor: 0.88,
      body: _BracketManager(tournamentId: tid),
    );
  }

  void _form(Map<String, dynamic>? t) {
    final isNew = t == null;
    final nameC = TextEditingController(text: t?['name'] ?? '');
    final venueC = TextEditingController(text: t?['venue_name'] ?? '');
    final startC = TextEditingController(text: t?['start_date'] ?? '');
    final endC = TextEditingController(text: t?['end_date'] ?? '');
    final prizeC =
        TextEditingController(text: t?['prize_pool']?.toString() ?? '');
    final feeC = TextEditingController(text: t?['entry_fee']?.toString() ?? '');
    final capC = TextEditingController(text: t?['capacity']?.toString() ?? '');
    final descC = TextEditingController(text: t?['description'] ?? '');
    const String format = 'double_elim';
    final rawStatus = t?['status'] as String? ?? 'auto';
    String status = (rawStatus == 'upcoming' || rawStatus == 'open' || rawStatus == 'completed')
        ? 'auto'
        : rawStatus;

    // Eligibility — derive mode from existing data
    final existingMin = (t?['min_elo'] as num?)?.toInt() ?? 0;
    final existingMax = (t?['max_elo'] as num?)?.toInt();
    String eligMode;
    double minLevel;
    double maxLevel;
    if (existingMin <= 0 && existingMax == null) {
      eligMode = 'open'; minLevel = 1.0; maxLevel = 7.0;
    } else if (existingMax != null && existingMax > 0) {
      eligMode = 'range';
      minLevel = (((existingMin - 800) / 200.0).clamp(1.0, 7.0) / 0.5).round() * 0.5;
      maxLevel = (((existingMax - 800) / 200.0).clamp(1.0, 7.0) / 0.5).round() * 0.5;
    } else {
      eligMode = 'min';
      minLevel = (((existingMin - 800) / 200.0).clamp(1.0, 7.0) / 0.5).round() * 0.5;
      maxLevel = 7.0;
    }

    adminSheet(
      context,
      title: isNew ? 'Create tournament' : 'Edit ${t['name']}',
      sub: isNew ? 'Goes live once published' : '',
      heightFactor: 0.9,
      footer: AdminButton(
        isNew ? 'Create & publish' : 'Save changes',
        full: true,
        height: 50,
        icon: Icons.check_rounded,
        onPressed: () async {
          if (nameC.text.trim().isEmpty) return;
          final data = <String, dynamic>{
            'name': nameC.text.trim(),
            'venue_name': venueC.text.trim(),
            'start_date':
                startC.text.trim().isEmpty ? null : startC.text.trim(),
            'end_date': endC.text.trim().isEmpty ? null : endC.text.trim(),
            'prize_pool': num.tryParse(prizeC.text),
            'entry_fee': num.tryParse(feeC.text),
            'capacity': int.tryParse(capC.text),
            'description':
                descC.text.trim().isEmpty ? null : descC.text.trim(),
            'min_elo': eligMode == 'open' ? 0 : (800 + (minLevel * 200)).round(),
            'max_elo': eligMode == 'range' ? (800 + (maxLevel * 200)).round() : null,
            'format': format,
            'status': status,
          };
          if (!isNew) data['id'] = t['id'];
          final err = await AdminService.upsertTournament(data);
          if (!mounted) return;
          Navigator.pop(context);
          await _load();
          if (mounted) {
            adminToast(context, err != null
                ? 'Error: $err'
                : isNew ? '"${nameC.text.trim()}" created' : 'Tournament updated');
          }
        },
      ),
      body: Column(children: [
        _field('Tournament name', nameC, hint: 'e.g. Nile Padel Open'),
        const SizedBox(height: 14),
        _field('Venue', venueC, hint: 'Gezira Sporting Club'),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: _dateField('Start date', startC)),
          const SizedBox(width: 12),
          Expanded(child: _dateField('End date', endC)),
        ]),
        const SizedBox(height: 14),
        _field('Prize pool', prizeC, prefix: 'EGP'),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: _field('Entry fee', feeC, prefix: 'EGP')),
          const SizedBox(width: 12),
          Expanded(child: _field('Capacity', capC, suffix: 'pairs')),
        ]),
        const SizedBox(height: 14),
        _field('About / description', descC,
            hint: 'Shown to players on the tournament page', maxLines: 3),
        const SizedBox(height: 14),
        StatefulBuilder(builder: (ctx, setSheet) {
          Widget statusBtn(String label, String value) {
            final on = status == value;
            return Expanded(
              child: GestureDetector(
                onTap: () => setSheet(() => status = value),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  margin: const EdgeInsets.only(right: 6),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: on ? AdminColors.primary : AdminColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(
                        color: on ? AdminColors.primary : AdminColors.line),
                  ),
                  child: Text(label,
                      style: AdminText.sans(11, FontWeight.w800,
                          on ? Colors.white : AdminColors.inkSoft)),
                ),
              ),
            );
          }

          Widget eligBtn(String label, String value) {
            final on = eligMode == value;
            return Expanded(
              child: GestureDetector(
                onTap: () => setSheet(() => eligMode = value),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  margin: const EdgeInsets.only(right: 6),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: on ? AdminColors.primary : AdminColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(
                        color: on ? AdminColors.primary : AdminColors.line),
                  ),
                  child: Text(label,
                      style: AdminText.sans(11, FontWeight.w800,
                          on ? Colors.white : AdminColors.inkSoft)),
                ),
              ),
            );
          }

          Widget levelDrop(String label, double current, void Function(double) onChange) {
            const lvls = [1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 5.5, 6.0, 6.5, 7.0];
            String divName(double l) {
              if (l < 2.0) return 'Bronze';
              if (l < 3.5) return 'Silver';
              if (l < 5.0) return 'Gold';
              return 'Elite';
            }
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: AdminText.strong(AdminColors.inkSoft)),
              const SizedBox(height: 7),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: AdminColors.surfaceAlt,
                  borderRadius: AdminUI.fieldR,
                  border: Border.all(color: AdminColors.line),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<double>(
                    value: current,
                    isExpanded: true,
                    dropdownColor: AdminColors.surface,
                    style: AdminText.body(),
                    onChanged: (v) { if (v != null) onChange(v); },
                    items: [
                      for (final l in lvls)
                        DropdownMenuItem(
                          value: l,
                          child: Text(
                            'Lv ${l.toStringAsFixed(1)}  ·  ${divName(l)}',
                            style: AdminText.body(),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ]);
          }

          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // ── Status ────────────────────────────────────────────
            Text('Status', style: AdminText.strong(AdminColors.inkSoft)),
            const SizedBox(height: 7),
            Row(children: [
              statusBtn('Auto (by dates)', 'auto'),
              statusBtn('Postponed', 'postponed'),
              statusBtn('Cancelled', 'cancelled'),
            ]),
            const SizedBox(height: 6),
            Text(
              'Normally leave on Auto — to extend or delay, just change the dates.',
              style: AdminText.small(AdminColors.inkFaint),
            ),
            const SizedBox(height: 16),
            // ── Eligibility ───────────────────────────────────────
            Text('Player eligibility', style: AdminText.strong(AdminColors.inkSoft)),
            const SizedBox(height: 7),
            Row(children: [
              eligBtn('Open to all', 'open'),
              eligBtn('Min level', 'min'),
              eligBtn('Level range', 'range'),
            ]),
            if (eligMode != 'open') ...[
              const SizedBox(height: 10),
              if (eligMode == 'range')
                Row(children: [
                  Expanded(child: levelDrop('From level', minLevel,
                      (v) => setSheet(() => minLevel = v))),
                  const SizedBox(width: 12),
                  Expanded(child: levelDrop('To level', maxLevel,
                      (v) => setSheet(() => maxLevel = v))),
                ])
              else
                levelDrop('Minimum level', minLevel,
                    (v) => setSheet(() => minLevel = v)),
            ] else ...[
              const SizedBox(height: 6),
              Text('Any player level can register.',
                  style: AdminText.small(AdminColors.inkFaint)),
            ],
          ]);
        }),
      ]),
    );
  }

  Widget _dateField(String label, TextEditingController c) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: AdminText.strong(AdminColors.inkSoft)),
      const SizedBox(height: 7),
      TextField(
        controller: c,
        readOnly: true,
        onTap: () => _pickDate(c),
        style: AdminText.body(),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Tap to pick',
          suffixIcon: const Icon(Icons.calendar_today_outlined,
              size: 16, color: AdminColors.inkFaint),
          filled: true,
          fillColor: AdminColors.surfaceAlt,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
          enabledBorder: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide: const BorderSide(color: AdminColors.line)),
          focusedBorder: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide:
                  const BorderSide(color: AdminColors.primary, width: 1.6)),
        ),
      ),
    ]);
  }

  Future<void> _pickDate(TextEditingController c) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final min = DateTime(2020);
    final max = DateTime(DateTime.now().year + 3, 12, 31);
    var initial = DateTime.tryParse(c.text) ?? DateTime.now();
    if (initial.isBefore(min)) initial = min;
    if (initial.isAfter(max)) initial = max;
    var temp = initial;
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        height: 320,
        decoration: const BoxDecoration(
          color: AdminColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          child: Column(children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
              decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AdminColors.lineSoft))),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Pick a date', style: AdminText.strong()),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () {
                      c.text =
                          '${temp.year}-${temp.month.toString().padLeft(2, '0')}-${temp.day.toString().padLeft(2, '0')}';
                      Navigator.pop(ctx);
                    },
                    child: Text('Done',
                        style: AdminText.strong(AdminColors.primary)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.date,
                initialDateTime: initial,
                minimumDate: min,
                maximumDate: max,
                onDateTimeChanged: (d) => temp = d,
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController c,
      {String? hint, String? prefix, String? suffix, int maxLines = 1}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: AdminText.strong(AdminColors.inkSoft)),
      const SizedBox(height: 7),
      TextField(
        controller: c,
        maxLines: maxLines,
        keyboardType: (prefix != null || suffix != null)
            ? TextInputType.number
            : maxLines > 1
                ? TextInputType.multiline
                : TextInputType.text,
        style: AdminText.body(),
        decoration: InputDecoration(
          isDense: true,
          prefixText: prefix != null ? '$prefix ' : null,
          suffixText: suffix,
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
              borderSide:
                  const BorderSide(color: AdminColors.primary, width: 1.6)),
        ),
      ),
      if (hint != null) ...[
        const SizedBox(height: 5),
        Text(hint, style: AdminText.small(AdminColors.inkFaint))
      ],
    ]);
  }
}


/// Admin bracket manager: generate/regenerate the draw and record winners.
class _BracketManager extends StatefulWidget {
  final String tournamentId;
  const _BracketManager({required this.tournamentId});
  @override
  State<_BracketManager> createState() => _BracketManagerState();
}

class _BracketManagerState extends State<_BracketManager> {
  List<Map<String, dynamic>> _matches = [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await AdminService.fetchBracket(widget.tournamentId);
    if (!mounted) return;
    setState(() {
      _matches = rows;
      _loading = false;
    });
  }

  static String _pair(Map<String, dynamic>? e) {
    if (e == null) return 'TBD';
    final name = (e['player_name'] as String?)?.trim().isNotEmpty == true
        ? (e['player_name'] as String)
        : 'Player';
    final partner = e['partner_name'] as String?;
    final first = name.split(' ').first;
    if (partner == null || partner.trim().isEmpty) return first;
    return '$first / ${partner.split(' ').first}';
  }

  Future<void> _generate() async {
    setState(() => _busy = true);
    final err = await AdminService.generateDraw(widget.tournamentId);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      adminToast(context, err);
    } else {
      adminToast(context, 'Draw generated');
      _load();
    }
  }

  Future<void> _pickWinner(Map<String, dynamic> m) async {
    final e1 = m['e1'] as Map<String, dynamic>?;
    final e2 = m['e2'] as Map<String, dynamic>?;
    if (e1 == null || e2 == null) {
      adminToast(context, 'This match is still waiting for a pair.');
      return;
    }
    final scoreC = TextEditingController();
    final winner = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AdminColors.surface,
        title: Text('Who won?',
            style: AdminText.sans(16, FontWeight.w800, AdminColors.ink)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: scoreC,
            style: AdminText.body(),
            decoration: const InputDecoration(
                isDense: true, hintText: 'Score (optional) e.g. 6-4, 6-2'),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, e1['id'] as String),
              child: Text(_pair(e1))),
          TextButton(
              onPressed: () => Navigator.pop(c, e2['id'] as String),
              child: Text(_pair(e2))),
        ],
      ),
    );
    if (winner == null || !mounted) return;
    setState(() => _busy = true);
    final err = await AdminService.recordBracketWinner(
        m['id'] as String, winner,
        score: scoreC.text.trim().isEmpty ? null : scoreC.text.trim());
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      adminToast(context, err);
    } else {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(30),
          child: CircularProgressIndicator(
              strokeWidth: 2.4, color: AdminColors.primary),
        ),
      );
    }
    final byBracket = <String, List<Map<String, dynamic>>>{};
    for (final m in _matches) {
      byBracket.putIfAbsent(m['bracket'] as String? ?? 'wb', () => []).add(m);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminButton(
          _busy
              ? 'Working…'
              : _matches.isEmpty
                  ? 'Generate draw from registered pairs'
                  : 'Regenerate draw (clears results)',
          full: true,
          height: 46,
          variant: _matches.isEmpty ? AdminBtn.primary : AdminBtn.ghost,
          icon: Icons.shuffle_rounded,
          onPressed: _busy ? null : _generate),
      const SizedBox(height: 16),
      if (_matches.isEmpty)
        Text('No draw yet. Generating seeds pairs by level — strongest meets weakest in round 1.',
            style: AdminText.small(AdminColors.inkSoft))
      else
        for (final bracket in ['wb', 'lb', 'gf'])
          if (byBracket.containsKey(bracket)) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8, top: 6),
              child: Text(
                  bracket == 'wb'
                      ? 'WINNERS BRACKET'
                      : bracket == 'lb'
                          ? 'LOSERS BRACKET'
                          : 'GRAND FINAL',
                  style: AdminText.kicker()),
            ),
            for (final m in byBracket[bracket]!) _matchTile(m),
          ],
    ]);
  }

  Widget _matchTile(Map<String, dynamic> m) {
    final e1 = m['e1'] as Map<String, dynamic>?;
    final e2 = m['e2'] as Map<String, dynamic>?;
    final winner = m['winner_entry'] as String?;
    final done = winner != null;
    final ready = e1 != null && e2 != null && !done;
    return GestureDetector(
      onTap: ready && !_busy ? () => _pickWinner(m) : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(
          color: AdminColors.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: ready ? AdminColors.primary : AdminColors.line,
              width: ready ? 1.4 : 1),
        ),
        child: Row(children: [
          SizedBox(
            width: 44,
            child: Text('R${m['round']}·${(m['slot'] as num).toInt() + 1}',
                style: AdminText.mono(11, FontWeight.w700, AdminColors.inkFaint)),
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_pair(e1),
                  style: AdminText.sans(13, FontWeight.w700,
                      done && winner == e1?['id'] ? AdminColors.success : AdminColors.ink)),
              Text(_pair(e2),
                  style: AdminText.sans(13, FontWeight.w700,
                      done && winner == e2?['id'] ? AdminColors.success : AdminColors.ink)),
            ]),
          ),
          if (done)
            const Icon(Icons.check_circle_rounded,
                size: 18, color: AdminColors.success)
          else if (ready)
            Text('Tap to score',
                style: AdminText.small(AdminColors.primary))
          else
            Text('Waiting',
                style: AdminText.small(AdminColors.inkFaint)),
        ]),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';
import '../data/admin_service.dart';
import '../data/finance_model.dart';
import 'admin_moderation_view.dart';

/// Reports — two things under one tab:
///
///  • **Money** — what we pay, what we get back, the profit between them, and a
///    Monday-to-Sunday weekly report. Every figure comes from
///    `admin_finance_summary` / `admin_weekly_finance`; nothing is computed
///    here. The server refuses anyone who isn't a super admin or a
///    Reports-holding analyst, so a lesser staffer sees a locked card.
///  • **Moderation** — the player-report queue, moved here from Requests. Its
///    own server guard (`_can_edit('requests')`) is unchanged.
class AdminReportsScreen extends StatefulWidget {
  /// Super admins record money in and out; everyone else reads.
  final bool canEdit;

  /// Holds the Requests section — the moderation queue's real permission.
  final bool canModerate;

  const AdminReportsScreen({
    super.key,
    this.canEdit = false,
    this.canModerate = false,
  });

  @override
  State<AdminReportsScreen> createState() => _AdminReportsScreenState();
}

class _AdminReportsScreenState extends State<AdminReportsScreen> {
  // id, label
  static const _periods = <List<String>>[
    ['week', 'This week'],
    ['last_week', 'Last week'],
    ['30d', 'Last 30 days'],
    ['90d', 'Last 90 days'],
    ['all', 'All time'],
  ];

  String _period = 'week';
  bool _loading = true;
  bool _showModeration = false;
  FinanceReport _report = const FinanceReport();
  FinanceReport? _prev; // same-length window immediately before, for the delta
  List<FinanceWeek> _weeks = const [];
  List<Map<String, dynamic>> _expenses = const [];
  List<Map<String, dynamic>> _income = const [];

  /// A staffer with Requests but no finance access lands straight on the queue
  /// — the Money half would only ever show them a locked card.
  @override
  void initState() {
    super.initState();
    _showModeration = widget.canModerate && !widget.canEdit;
    _load();
  }

  // ── period maths (local dates, both ends inclusive) ───────────

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  static DateTime _mondayOf(DateTime d) =>
      d.subtract(Duration(days: d.weekday - 1));

  (DateTime?, DateTime?) _range(String id) {
    final today = _today();
    switch (id) {
      case 'week':
        return (_mondayOf(today), today);
      case 'last_week':
        final lastMonday = _mondayOf(today).subtract(const Duration(days: 7));
        return (lastMonday, lastMonday.add(const Duration(days: 6)));
      case '30d':
        return (today.subtract(const Duration(days: 29)), today);
      case '90d':
        return (today.subtract(const Duration(days: 89)), today);
      default:
        return (null, null); // all time
    }
  }

  /// The equally long window ending the day before [from] — what "vs previous"
  /// compares against. Null for all-time, which has nothing before it.
  (DateTime?, DateTime?) _previousRange(DateTime? from, DateTime? to) {
    if (from == null || to == null) return (null, null);
    final days = to.difference(from).inDays + 1;
    final prevTo = from.subtract(const Duration(days: 1));
    return (prevTo.subtract(Duration(days: days - 1)), prevTo);
  }

  String get _periodLabel =>
      _periods.firstWhere((p) => p.first == _period)[1];

  // ── loading ───────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() => _loading = true);
    final (from, to) = _range(_period);
    final (pFrom, pTo) = _previousRange(from, to);

    final results = await Future.wait([
      AdminService.financeSummary(from: from, to: to),
      if (pFrom != null)
        AdminService.financeSummary(from: pFrom, to: pTo)
      else
        Future.value(<String, dynamic>{'error': 'no_baseline'}),
      AdminService.weeklyFinance(weeks: 8),
      AdminService.fetchLedger(LedgerKind.expense, from: from, to: to),
      AdminService.fetchLedger(LedgerKind.income, from: from, to: to),
    ]);

    if (!mounted) return;
    final prev = FinanceReport.fromJson(results[1] as Map<String, dynamic>);
    setState(() {
      _report = FinanceReport.fromJson(results[0] as Map<String, dynamic>);
      _prev = prev.ok ? prev : null;
      _weeks = (results[2] as List<Map<String, dynamic>>)
          .map(FinanceWeek.fromJson)
          .toList();
      _expenses = results[3] as List<Map<String, dynamic>>;
      _income = results[4] as List<Map<String, dynamic>>;
      _loading = false;
    });
  }

  void _setPeriod(String id) {
    if (id == _period) return;
    setState(() => _period = id);
    _load();
  }

  // ── build ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Both halves available → a segmented switch above everything else.
    final bothHalves = widget.canModerate && !_report.locked;

    if (_showModeration) {
      return Column(children: [
        if (bothHalves)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
            child: _halfSwitch(),
          ),
        const Expanded(child: AdminModerationView()),
      ]);
    }

    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: AdminColors.primary));
    }

    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
        children: [
          if (bothHalves) ...[
            _halfSwitch(),
            const SizedBox(height: 14),
          ],
          const AdminSection('Reports', sub: 'Money in, money out — and profit'),
          // The two things you come here to DO, before the numbers you come
          // here to read — recording money shouldn't need a scroll.
          if (widget.canEdit && _report.ok && !_report.locked) ...[
            Row(children: [
              Expanded(
                child: AdminButton('Add money in',
                    icon: Icons.south_west_rounded,
                    full: true,
                    height: 44,
                    variant: AdminBtn.success,
                    onPressed: () => _openEntry(LedgerKind.income, null)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: AdminButton('Record expense',
                    icon: Icons.north_east_rounded,
                    full: true,
                    height: 44,
                    variant: AdminBtn.ghost,
                    onPressed: () => _openEntry(LedgerKind.expense, null)),
              ),
            ]),
            const SizedBox(height: 8),
            Text(
              'For anything that happened outside the app — a cash sale, '
              'materials you bought, court hire you paid for.',
              style: AdminText.small().copyWith(height: 1.35),
            ),
            const SizedBox(height: 16),
          ],
          _periodBar(),
          const SizedBox(height: 14),
          if (_report.locked)
            _notice(
              Icons.lock_outline_rounded,
              AdminColors.warn,
              'Financials are restricted',
              'Revenue, costs and profit are visible to super admins (and a '
                  'read-only Analyst). Ask a super admin if you need them.',
            )
          else if (!_report.ok)
            _notice(
              Icons.storage_rounded,
              AdminColors.info,
              'Finance reporting isn\'t installed yet',
              'Run supabase/changes/2026-08-06_expenses_and_pl.sql on the '
                  'database, then pull to refresh.',
            )
          else ...[
            _headline(),
            const SizedBox(height: 18),
            _breakdown(
              title: 'What we get',
              sub: 'Money in · $_periodLabel',
              tone: AdminColors.success,
              icon: Icons.south_west_rounded,
              lines: _report.inLines,
              total: _report.moneyIn,
              foot: _report.storeCollected > 0
                  ? '${egp(_report.storeCollected)} of store sales has been '
                      'delivered and collected — the rest is still in flight.'
                  : null,
            ),
            const SizedBox(height: 18),
            _breakdown(
              title: 'What we pay',
              sub: 'Money out · $_periodLabel',
              tone: AdminColors.danger,
              icon: Icons.north_east_rounded,
              lines: _report.outLines,
              total: _report.moneyOut,
              foot: 'Cost of goods sold and trade-in credit are counted '
                  'automatically from the store and trade-in ledgers. '
                  'Everything else is what you recorded below.',
            ),
            const SizedBox(height: 18),
            _ledgerCard(LedgerKind.income, _income),
            const SizedBox(height: 18),
            _ledgerCard(LedgerKind.expense, _expenses),
            const SizedBox(height: 18),
            _weeklyCard(),
          ],
        ],
      ),
    );
  }

  /// Money ⇄ Moderation. Only built when the staffer can reach both.
  Widget _halfSwitch() => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
            color: AdminColors.surfaceAlt,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: AdminColors.line)),
        child: Row(children: [
          _halfBtn('Money', false),
          _halfBtn('Moderation', true),
        ]),
      );

  Widget _halfBtn(String label, bool moderation) {
    final on = _showModeration == moderation;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _showModeration = moderation),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
              color: on ? AdminColors.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              boxShadow: on ? AdminColors.cardShadow : null),
          child: Text(label,
              style: AdminText.sans(12.5, FontWeight.w700,
                  on ? AdminColors.ink : AdminColors.inkSoft)),
        ),
      ),
    );
  }

  Widget _periodBar() => SizedBox(
        height: 34,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _periods.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (_, i) {
            final p = _periods[i];
            final on = p.first == _period;
            return GestureDetector(
              onTap: () => _setPeriod(p.first),
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: on ? AdminColors.ink : AdminColors.surface,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                      color: on ? AdminColors.ink : AdminColors.line),
                ),
                child: Text(
                  p[1],
                  style: AdminText.sans(12.5, FontWeight.w700,
                      on ? AdminColors.surface : AdminColors.inkSoft),
                ),
              ),
            );
          },
        ),
      );

  // ── the headline P&L card ─────────────────────────────────────

  Widget _headline() {
    final profit = _report.profit;
    final up = profit >= 0;
    final tone = up ? AdminColors.success : AdminColors.danger;
    final delta = _prev == null ? null : pctChange(_prev!.profit, profit);

    return AdminCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(up ? 'NET PROFIT' : 'NET LOSS', style: AdminText.kicker()),
          const Spacer(),
          if (delta != null) _deltaChip(delta),
        ]),
        const SizedBox(height: 6),
        Text(egp(profit.abs()),
            style: AdminText.sans(30, FontWeight.w800, tone, ls: -1.2)),
        const SizedBox(height: 4),
        Text(
          _report.moneyIn == 0
              ? 'Nothing moved in this period.'
              : '${pct(_report.margin)}% margin · $_periodLabel',
          style: AdminText.small(),
        ),
        const SizedBox(height: 16),
        _scaleBar('Money in', _report.moneyIn, AdminColors.success),
        const SizedBox(height: 10),
        _scaleBar('Money out', _report.moneyOut, AdminColors.danger),
        if (_prev != null) ...[
          const Divider(height: 26, color: AdminColors.lineSoft),
          Text(
            'Previous $_periodLabel: ${egp(_prev!.moneyIn)} in · '
            '${egp(_prev!.moneyOut)} out · ${egp(_prev!.profit)} profit',
            style: AdminText.small(),
          ),
        ],
      ]),
    );
  }

  /// One bar sized against the larger of money in / money out, so the two rows
  /// are directly comparable by eye.
  Widget _scaleBar(String label, num value, Color tone) {
    final max = [_report.moneyIn, _report.moneyOut]
        .fold<num>(0, (m, v) => v > m ? v : m);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(label, style: AdminText.strong()),
        const Spacer(),
        Text(egp(value), style: AdminText.mono(13, FontWeight.w800, tone)),
      ]),
      const SizedBox(height: 6),
      AdminProgress(max == 0 ? 0 : value / max, color: tone),
    ]);
  }

  Widget _deltaChip(double pct) {
    final up = pct >= 0;
    final tone = up ? AdminColors.success : AdminColors.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: AdminColors.wash(tone, 0.14),
          borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
            size: 12, color: tone),
        const SizedBox(width: 3),
        Text('${pct.abs().toStringAsFixed(0)}%',
            style: AdminText.mono(11, FontWeight.w800, tone)),
      ]),
    );
  }

  // ── a money-in / money-out breakdown ──────────────────────────

  Widget _breakdown({
    required String title,
    required String sub,
    required Color tone,
    required IconData icon,
    required List<MoneyLine> lines,
    required num total,
    String? foot,
  }) {
    return AdminCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: AdminColors.wash(tone, 0.14),
                borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, size: 17, color: tone),
          ),
          const SizedBox(width: 11),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AdminText.cardTitle()),
              const SizedBox(height: 2),
              Text(sub, style: AdminText.small()),
            ]),
          ),
          Text(egp(total), style: AdminText.mono(15, FontWeight.w800, tone)),
        ]),
        if (lines.isEmpty) ...[
          const SizedBox(height: 14),
          Text('Nothing recorded in this period.', style: AdminText.small()),
        ] else
          for (final l in lines) ...[
            const SizedBox(height: 14),
            _moneyLine(l, total),
          ],
        if (foot != null) ...[
          const Divider(height: 24, color: AdminColors.lineSoft),
          Text(foot, style: AdminText.small().copyWith(height: 1.35)),
        ],
      ]),
    );
  }

  Widget _moneyLine(MoneyLine l, num total) {
    final share = total == 0 ? 0.0 : l.amount / total;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(l.icon, size: 15, color: l.tone),
        const SizedBox(width: 8),
        Expanded(child: Text(l.label, style: AdminText.strong())),
        Text(egp(l.amount),
            style: AdminText.mono(13, FontWeight.w800, AdminColors.ink)),
      ]),
      const SizedBox(height: 5),
      AdminProgress(share, color: l.tone),
      const SizedBox(height: 4),
      Row(children: [
        Text('${(share * 100).toStringAsFixed(0)}% of the total',
            style: AdminText.small()),
        if (l.hint.isNotEmpty) ...[
          Text(' · ', style: AdminText.small()),
          Text(l.hint, style: AdminText.small()),
        ],
        if (l.auto) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
                color: AdminColors.surface3,
                borderRadius: BorderRadius.circular(999)),
            child: Text('AUTO',
                style: AdminText.mono(9, FontWeight.w800, AdminColors.inkFaint)),
          ),
        ],
      ]),
    ]);
  }

  // ── the two hand-kept ledgers ─────────────────────────────────
  // Expenses and money-in differ only in their labels, categories and column
  // names — all of which live on LedgerKind — so one card renders both.

  Widget _ledgerCard(LedgerKind kind, List<Map<String, dynamic>> rows) {
    return AdminCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(kind.sectionTitle, style: AdminText.cardTitle()),
              const SizedBox(height: 2),
              Text(
                  '${kind.isIncome ? 'Money taken' : 'Money spent'} outside the '
                  'app · ${rows.length} in ${_periodLabel.toLowerCase()}',
                  style: AdminText.small()),
            ]),
          ),
          if (widget.canEdit)
            AdminButton('Add',
                icon: Icons.add_rounded,
                height: 34,
                variant: AdminBtn.ghost,
                onPressed: () => _openEntry(kind, null)),
        ]),
        const Divider(height: 22, color: AdminColors.lineSoft),
        if (rows.isEmpty)
          Text(
            widget.canEdit
                ? (kind.isIncome
                    ? 'Nothing recorded yet. Add anything you were paid outside '
                        'the app — a racket sold in person, a coaching session, '
                        'court hire, sponsorship — and it counts towards profit '
                        'straight away.'
                    : 'Nothing recorded yet. Add anything you paid for outside '
                        'the app — materials and supplies, court hire, prizes, '
                        'ads, wages — and it counts against profit straight '
                        'away.')
                : 'Nothing recorded in this period.',
            style: AdminText.small().copyWith(height: 1.35),
          )
        else
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const Divider(height: 18, color: AdminColors.lineSoft),
            _ledgerRow(kind, rows[i]),
          ],
      ]),
    );
  }

  Widget _ledgerRow(LedgerKind kind, Map<String, dynamic> e) {
    final cat = kind.category(e['category'] as String?);
    final party = (e[kind.partyColumn] as String?)?.trim() ?? '';
    final note = (e['note'] as String?)?.trim() ?? '';
    final detail = [if (party.isNotEmpty) party, if (note.isNotEmpty) note]
        .join(' · ');
    final date = prettyYmd(e[kind.dateColumn] as String?);
    return InkWell(
      onTap: widget.canEdit ? () => _openEntry(kind, e) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: AdminColors.wash(cat.tone, 0.12),
                borderRadius: BorderRadius.circular(9)),
            child: Icon(cat.icon, size: 16, color: cat.tone),
          ),
          const SizedBox(width: 11),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(cat.label, style: AdminText.strong()),
              const SizedBox(height: 2),
              Text(
                detail.isEmpty ? date : '$date · $detail',
                style: AdminText.small(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ]),
          ),
          const SizedBox(width: 8),
          Text('${kind.isIncome ? '+' : '−'}${egp((e['amount'] as num?) ?? 0)}',
              style: AdminText.mono(13, FontWeight.w800, kind.tone)),
          if (widget.canEdit)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.chevron_right_rounded,
                  size: 17, color: AdminColors.inkFaint),
            ),
        ]),
      ),
    );
  }

  // ── weekly reports ────────────────────────────────────────────

  Widget _weeklyCard() {
    return AdminCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: AdminColors.wash(AdminColors.primary, 0.14),
                borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.calendar_view_week_rounded,
                size: 17, color: AdminColors.primary),
          ),
          const SizedBox(width: 11),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Weekly report', style: AdminText.cardTitle()),
              const SizedBox(height: 2),
              Text(
                  widget.canEdit
                      ? 'Monday to Sunday · tap a week to read, share or email it'
                      : 'Monday to Sunday · tap a week for the full breakdown',
                  style: AdminText.small()),
            ]),
          ),
        ]),
        const Divider(height: 22, color: AdminColors.lineSoft),
        if (_weeks.isEmpty)
          Text('No weeks to report yet.', style: AdminText.small())
        else
          for (var i = 0; i < _weeks.length; i++) ...[
            if (i > 0) const Divider(height: 18, color: AdminColors.lineSoft),
            _weekRow(_weeks[i], i + 1 < _weeks.length ? _weeks[i + 1] : null),
          ],
      ]),
    );
  }

  Widget _weekRow(FinanceWeek w, FinanceWeek? before) {
    final r = w.report;
    final tone = r.profit >= 0 ? AdminColors.success : AdminColors.danger;
    final delta =
        before == null ? null : pctChange(before.report.profit, r.profit);

    return InkWell(
      onTap: () => _openWeek(w),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(w.label, style: AdminText.strong()),
                if (w.isCurrent) ...[
                  const SizedBox(width: 7),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                        color: AdminColors.wash(AdminColors.primary, 0.14),
                        borderRadius: BorderRadius.circular(999)),
                    child: Text('So far',
                        style: AdminText.sans(
                            10, FontWeight.w800, AdminColors.primary)),
                  ),
                ],
              ]),
              const SizedBox(height: 3),
              Text(
                r.isEmpty
                    ? 'No money moved'
                    : '${egpShort(r.moneyIn)} in · ${egpShort(r.moneyOut)} out',
                style: AdminText.small(),
              ),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(egpShort(r.profit),
                style: AdminText.mono(13.5, FontWeight.w800, tone)),
            const SizedBox(height: 3),
            if (delta != null)
              _deltaChip(delta)
            else
              Text('—', style: AdminText.small()),
          ]),
          const Padding(
            padding: EdgeInsets.only(left: 6),
            child: Icon(Icons.chevron_right_rounded,
                size: 17, color: AdminColors.inkFaint),
          ),
        ]),
      ),
    );
  }

  Future<void> _openWeek(FinanceWeek w) async {
    final r = w.report;
    await adminSheet<void>(
      context,
      title: 'Week of ${w.label}',
      sub: w.isCurrent ? 'This week, so far' : 'Monday to Sunday',
      heightFactor: 0.86,
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AdminCard(
          color: AdminColors.surfaceAlt,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.profit >= 0 ? 'NET PROFIT' : 'NET LOSS',
                style: AdminText.kicker()),
            const SizedBox(height: 5),
            Text(egp(r.profit.abs()),
                style: AdminText.sans(
                    26,
                    FontWeight.w800,
                    r.profit >= 0 ? AdminColors.success : AdminColors.danger,
                    ls: -1)),
            const SizedBox(height: 3),
            Text(
                r.moneyIn == 0
                    ? 'Nothing moved this week.'
                    : '${pct(r.margin)}% margin on ${egp(r.moneyIn)} in',
                style: AdminText.small()),
          ]),
        ),
        const SizedBox(height: 14),
        _sheetLines('What we get', r.inLines, r.moneyIn, AdminColors.success),
        const SizedBox(height: 14),
        _sheetLines('What we pay', r.outLines, r.moneyOut, AdminColors.danger),
        const SizedBox(height: 14),
        Text(
          '${r.counts['orders'] ?? 0} orders · ${r.counts['entries'] ?? 0} paid '
          'entries · ${r.counts['repairs'] ?? 0} repairs collected · '
          '${r.counts['expenses'] ?? 0} expenses recorded',
          style: AdminText.small().copyWith(height: 1.35),
        ),
      ]),
      footer: Column(mainAxisSize: MainAxisSize.min, children: [
        // Sharing the week — super admins only, same rule as recording money.
        // An Analyst can read these numbers but can't hand out a login-free
        // link to them; the server enforces it either way.
        if (widget.canEdit) ...[
          AdminButton('Email the report',
              icon: Icons.mail_outline_rounded,
              full: true,
              height: 48,
              onPressed: () => _emailWeek(w)),
          const SizedBox(height: 8),
        ],
        Row(children: [
          if (widget.canEdit) ...[
            Expanded(
              child: AdminButton('Copy link',
                  icon: Icons.link_rounded,
                  height: 44,
                  variant: AdminBtn.ghost,
                  onPressed: () => _copyWeekLink(w)),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: AdminButton('Copy summary',
                icon: Icons.copy_rounded,
                height: 44,
                variant: AdminBtn.ghost, onPressed: () {
              Clipboard.setData(ClipboardData(text: _weekText(w)));
              Navigator.pop(context);
              adminToast(context, 'Weekly summary copied');
            }),
          ),
        ]),
      ]),
    );
  }

  // ── sharing a week ────────────────────────────────────────────
  //
  // The link opens a read-only page of that week's full P&L without a login —
  // that's what makes it something you can put in an email. It's permanent and
  // reusable: the same week always resolves to the same URL.

  Future<void> _copyWeekLink(FinanceWeek w) async {
    Navigator.pop(context);
    adminToast(context, 'Building the link…');
    final url = await AdminService.reportLink(w.start);
    if (!mounted) return;
    if (url == null) {
      adminToast(context, "Couldn't create the link for that week.", ok: false);
      return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) adminToast(context, 'Report link copied');
  }

  Future<void> _emailWeek(FinanceWeek w) async {
    Navigator.pop(context);
    adminToast(context, 'Sending…');
    final err = await AdminService.emailWeeklyReport(w.start);
    if (!mounted) return;
    adminToast(context, err ?? 'Report sent to padelrivals@gmail.com',
        ok: err == null);
  }

  Widget _sheetLines(String title, List<MoneyLine> lines, num total, Color tone) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(title, style: AdminText.strong()),
        const Spacer(),
        Text(egp(total), style: AdminText.mono(13, FontWeight.w800, tone)),
      ]),
      if (lines.isEmpty) ...[
        const SizedBox(height: 8),
        Text('Nothing this week.', style: AdminText.small()),
      ] else
        for (final l in lines) ...[
          const SizedBox(height: 11),
          _moneyLine(l, total),
        ],
    ]);
  }

  /// A plain-text weekly report — what a super admin pastes into a message.
  String _weekText(FinanceWeek w) {
    final r = w.report;
    final b = StringBuffer()
      ..writeln('Padel Egypt — week of ${w.label}'
          '${w.isCurrent ? ' (so far)' : ''}')
      ..writeln('')
      ..writeln('Money in:  ${egp(r.moneyIn)}');
    for (final l in r.inLines) {
      b.writeln('  · ${l.label}: ${egp(l.amount)}');
    }
    b
      ..writeln('Money out: ${egp(r.moneyOut)}')
      ..writeln('');
    for (final l in r.outLines) {
      b.writeln('  · ${l.label}: ${egp(l.amount)}');
    }
    b
      ..writeln('')
      ..writeln('${r.profit >= 0 ? 'Profit' : 'Loss'}: '
          '${egp(r.profit.abs())} (${pct(r.margin)}% margin)');
    return b.toString();
  }

  // ── add / edit a ledger entry ─────────────────────────────────

  Future<void> _openEntry(
      LedgerKind kind, Map<String, dynamic>? existing) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LedgerSheet(kind: kind, existing: existing),
    );
    if (saved == true) _load();
  }

  // ── shared notice card ────────────────────────────────────────

  Widget _notice(IconData icon, Color tone, String title, String body) =>
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AdminColors.wash(tone, 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AdminColors.wash(tone, 0.2)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 20, color: tone),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AdminText.strong(tone)),
              const SizedBox(height: 3),
              Text(body,
                  style: AdminText.small(tone).copyWith(height: 1.35)),
            ]),
          ),
        ]),
      );
}

// ============================================================================
// The add / edit sheet for both hand-kept ledgers. Writes straight to
// `expenses` or `income`; RLS keeps the insert to super admins, so an error
// here is shown verbatim rather than guessed at.
// ============================================================================
class _LedgerSheet extends StatefulWidget {
  final LedgerKind kind;
  final Map<String, dynamic>? existing;
  const _LedgerSheet({required this.kind, this.existing});
  @override
  State<_LedgerSheet> createState() => _LedgerSheetState();
}

class _LedgerSheetState extends State<_LedgerSheet> {
  late final TextEditingController _amount;
  late final TextEditingController _party;
  late final TextEditingController _note;
  late String _category;
  late DateTime _date;
  bool _busy = false;

  LedgerKind get _kind => widget.kind;
  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _amount = TextEditingController(
        text: e == null ? '' : ((e['amount'] as num?) ?? 0).round().toString());
    _party =
        TextEditingController(text: (e?[_kind.partyColumn] as String?) ?? '');
    _note = TextEditingController(text: (e?['note'] as String?) ?? '');
    _category = (e?['category'] as String?) ?? _kind.defaultCategory;
    final ymd = e?[_kind.dateColumn] as String?;
    _date = ymd == null ? DateTime.now() : DateTime.parse(ymd);
  }

  @override
  void dispose() {
    _amount.dispose();
    _party.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year + 1),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amount.text.trim());
    if (amount == null || amount <= 0) {
      adminToast(context, 'Enter an amount in EGP', ok: false);
      return;
    }
    setState(() => _busy = true);
    final err = await AdminService.saveLedger(_kind, {
      if (_editing) 'id': widget.existing!['id'],
      _kind.dateColumn: '${_date.year.toString().padLeft(4, '0')}-'
          '${_date.month.toString().padLeft(2, '0')}-'
          '${_date.day.toString().padLeft(2, '0')}',
      'category': _category,
      'amount': amount,
      _kind.partyColumn:
          _party.text.trim().isEmpty ? null : _party.text.trim(),
      'note': _note.text.trim().isEmpty ? null : _note.text.trim(),
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      adminToast(context, err, ok: false);
      return;
    }
    Navigator.pop(context, true);
  }

  Future<void> _delete() async {
    // Deleting rewrites past profit figures, so ask first.
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AdminColors.surface,
        title: Text(
            _kind.isIncome ? 'Delete this entry?' : 'Delete this expense?',
            style: AdminText.h2()),
        content: Text(
          'It changes the profit figures for '
          '${prettyYmd(widget.existing![_kind.dateColumn] as String?)} and '
          'can\'t be undone.',
          style: AdminText.body(),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Keep it', style: AdminText.strong())),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Delete', style: AdminText.strong(AdminColors.danger))),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _busy = true);
    final err =
        await AdminService.deleteLedger(_kind, widget.existing!['id'] as String);
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
    final cat = _kind.category(_category);
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
                      Text(_editing ? _kind.editTitle : _kind.newTitle,
                          style: AdminText.h2()),
                      const SizedBox(height: 2),
                      Text(_kind.sheetSub, style: AdminText.small()),
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
                _label('Amount (EGP)'),
                TextField(
                  controller: _amount,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  style: AdminText.sans(22, FontWeight.w800, AdminColors.ink),
                  decoration: _dec('0'),
                ),
                const SizedBox(height: 16),
                _label(_kind.isIncome ? 'Where it came from' : 'What for'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in _kind.categories)
                      GestureDetector(
                        onTap: () => setState(() => _category = c.id),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 11, vertical: 8),
                          decoration: BoxDecoration(
                            color: _category == c.id
                                ? AdminColors.wash(c.tone, 0.16)
                                : AdminColors.surfaceAlt,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: _category == c.id
                                    ? c.tone
                                    : AdminColors.line),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(c.icon,
                                size: 15,
                                color: _category == c.id
                                    ? c.tone
                                    : AdminColors.inkSoft),
                            const SizedBox(width: 6),
                            Text(c.label,
                                style: AdminText.sans(
                                    12.5,
                                    FontWeight.w700,
                                    _category == c.id
                                        ? c.tone
                                        : AdminColors.inkSoft)),
                          ]),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(cat.hint, style: AdminText.small()),
                const SizedBox(height: 16),
                _label('Date'),
                GestureDetector(
                  onTap: _pickDate,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                    decoration: BoxDecoration(
                      color: AdminColors.surfaceAlt,
                      borderRadius: AdminUI.fieldR,
                      border: Border.all(color: AdminColors.line),
                    ),
                    child: Row(children: [
                      const Icon(Icons.event_rounded,
                          size: 16, color: AdminColors.inkSoft),
                      const SizedBox(width: 9),
                      Text(prettyDate(_date), style: AdminText.body()),
                    ]),
                  ),
                ),
                const SizedBox(height: 16),
                _label('${_kind.partyLabel} (optional)'),
                TextField(
                    controller: _party,
                    style: AdminText.body(),
                    decoration: _dec(_kind.partyHint)),
                const SizedBox(height: 16),
                _label('Note (optional)'),
                TextField(
                    controller: _note,
                    style: AdminText.body(),
                    maxLines: 3,
                    decoration: _dec(
                        _kind.isIncome ? 'What this was for' : 'What this covered')),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                    color: AdminColors.wash(AdminColors.info, 0.07),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.info_outline_rounded,
                            size: 16, color: AdminColors.info),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            _kind.isIncome
                                ? 'Only money the app never saw. Store orders, '
                                    'paid tournament entries and repairs are '
                                    'already counted from their own records — '
                                    'adding them here would count them twice.'
                                : 'Materials you buy and use up belong here. '
                                    'Stock you buy to RESELL does not — set '
                                    'that product\'s cost in Store & Orders and '
                                    'it counts against profit when the item '
                                    'sells. Recording it in both places would '
                                    'charge you for it twice.',
                            style: AdminText.small(AdminColors.info)
                                .copyWith(height: 1.35),
                          ),
                        ),
                      ]),
                ),
                if (_editing) ...[
                  const SizedBox(height: 16),
                  AdminButton(
                      _kind.isIncome
                          ? 'Delete this entry'
                          : 'Delete this expense',
                      icon: Icons.delete_outline_rounded,
                      full: true,
                      variant: AdminBtn.danger,
                      onPressed: _busy ? null : _delete),
                ],
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
                    : (_kind.isIncome ? 'Save money in' : 'Save expense'),
                full: true,
                height: 48,
                color: _kind.isIncome ? AdminColors.success : null,
                onPressed: _busy ? null : _save),
          ),
        ]),
      ),
    );
  }

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
            borderRadius: AdminUI.fieldR,
            borderSide: const BorderSide(color: AdminColors.line)),
        enabledBorder: OutlineInputBorder(
            borderRadius: AdminUI.fieldR,
            borderSide: const BorderSide(color: AdminColors.line)),
        focusedBorder: OutlineInputBorder(
            borderRadius: AdminUI.fieldR,
            borderSide: const BorderSide(color: AdminColors.primary)),
      );
}

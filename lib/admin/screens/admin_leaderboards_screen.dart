import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../backend/services/season_service.dart';
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';
import 'season_player_sheet.dart';

/// Season console (super admin only — every RPC behind this guards on
/// `_is_admin()`). Run the season: lifecycle, points engine, reward brackets,
/// live standings with manual adjustments.
class AdminLeaderboardsScreen extends StatefulWidget {
  const AdminLeaderboardsScreen({super.key});
  @override
  State<AdminLeaderboardsScreen> createState() =>
      _AdminLeaderboardsScreenState();
}

class _AdminLeaderboardsScreenState extends State<AdminLeaderboardsScreen> {
  SeasonConsole? _data;
  bool _loading = true;
  bool _busy = false;
  String? _seasonId; // null = the live season
  String _query = '';
  List<SeasonPlayerHit> _hits = const [];
  int _searchSeq = 0; // drops results from stale keystrokes

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_loading && mounted) setState(() => _loading = true);
    final d = await SeasonService.console(seasonId: _seasonId);
    if (!mounted) return;
    setState(() {
      _data = d;
      _seasonId = d?.season?.id ?? _seasonId;
      _loading = false;
    });
  }

  /// Run an admin RPC, surface its message, and refresh.
  Future<void> _run(Future<String?> Function() action, String okMessage) async {
    if (_busy) return;
    setState(() => _busy = true);
    final err = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    adminToast(context, err ?? okMessage, ok: err == null);
    await _load();
  }

  // One source of truth for season formatting — see season_player_sheet.dart.
  static String _egp(int n) => 'EGP ${seasonThousands(n)}';
  static String _thousands(int n) => seasonThousands(n);
  static Color _bracketTone(String key) => seasonBracketTone(key);
  static IconData _ruleIcon(String name) => seasonRuleIcon(name);

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
        children: [
          AdminSection(
            'Leaderboards',
            sub: d?.season == null
                ? 'Seasonal standings & rewards'
                : 'Season ${d!.season!.no} · ${d.season!.window}',
            action: AdminButton('New season',
                icon: Icons.add_rounded, height: 34, onPressed: _newSeason),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AdminColors.primary)),
            )
          else if (d == null || d.error != null)
            _empty(
              Icons.lock_outline_rounded,
              'Not available',
              d?.error ?? 'Only a super admin can run the season.',
            )
          else if (d.season == null)
            _empty(
              Icons.emoji_events_outlined,
              'No season yet',
              'Create the first season — it arrives with the default points '
                  'engine and reward brackets, ready to edit.',
            )
          else ...[
            _kpis(d),
            const SizedBox(height: 16),
            _lifecycle(d),
            const SizedBox(height: 16),
            _pointsEngine(d),
            const SizedBox(height: 16),
            _brackets(d),
            const SizedBox(height: 16),
            _standings(d),
          ],
        ],
      ),
    );
  }

  Widget _empty(IconData icon, String title, String text) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: AdminCard(
          child: Column(children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: AdminColors.wash(AdminColors.primary, 0.12),
                  borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, size: 24, color: AdminColors.primary),
            ),
            const SizedBox(height: 12),
            Text(title, style: AdminText.cardTitle()),
            const SizedBox(height: 3),
            Text(text, textAlign: TextAlign.center, style: AdminText.small()),
          ]),
        ),
      );

  // ── KPI row ───────────────────────────────────────────────────────
  Widget _kpis(SeasonConsole d) => KpiGrid([
        StatCard(
            icon: Icons.groups_outlined,
            tone: AdminColors.green,
            label: 'Ranked players',
            value: _thousands(d.rankedCount)),
        StatCard(
            icon: Icons.sports_tennis_rounded,
            tone: AdminColors.primary,
            label: 'Matches counted',
            value: _thousands(d.matchesCounted)),
        StatCard(
            icon: Icons.emoji_events_outlined,
            tone: AdminColors.gold,
            label: 'Reward budget',
            value: _egp(d.rewardBudget),
            foot: '${d.brackets.length} brackets'),
        StatCard(
            icon: Icons.schedule_rounded,
            tone: AdminColors.warn,
            label: 'Days remaining',
            value: '${d.daysLeft}',
            foot: 'Closes ${_short(d.season!.endsOn)}'),
      ]);

  static String _short(DateTime d) {
    const m = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${d.day} ${m[d.month - 1]}';
  }

  // ── lifecycle ─────────────────────────────────────────────────────
  Widget _lifecycle(SeasonConsole d) {
    final s = d.season!;
    final ended = s.status == 'ended';
    return AdminCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: AdminColors.wash(AdminColors.gold, 0.14),
                borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.military_tech_rounded,
                size: 17, color: AdminColors.gold),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(ended ? 'Season' : 'Live season', style: AdminText.cardTitle()),
              Text('Visibility and lifecycle for the player-facing board',
                  style: AdminText.small()),
            ]),
          ),
          StatusBadge(s.published ? 'live' : 'hidden', dot: true),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: Text(s.name, style: AdminText.small())),
          Text('${(d.progress * 100).round()}%',
              style: AdminText.mono(12, FontWeight.w800, AdminColors.ink)),
        ]),
        const SizedBox(height: 7),
        AdminProgress(d.progress, color: AdminColors.gold),
        const SizedBox(height: 7),
        Row(children: [
          Expanded(
            child: Text(_short(s.startsOn),
                style: AdminText.small(AdminColors.inkFaint)),
          ),
          Text(
            s.frozen
                ? 'Standings frozen'
                : 'Live · updates after every confirmed match',
            style: AdminText.small(AdminColors.inkFaint),
          ),
        ]),
        const SizedBox(height: 14),
        Wrap(spacing: 10, runSpacing: 10, children: [
          AdminButton(
            s.published ? 'Unpublish' : 'Publish',
            icon: s.published
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
            variant: AdminBtn.ghost,
            height: 36,
            onPressed: _busy
                ? null
                : () => _run(
                      () => SeasonService.setPublished(s.id, !s.published),
                      s.published
                          ? 'Leaderboard hidden from players'
                          : 'Leaderboard published to players',
                    ),
          ),
          AdminButton(
            s.frozen ? 'Frozen' : 'Freeze',
            icon: Icons.lock_outline_rounded,
            variant: s.frozen ? AdminBtn.success : AdminBtn.ghost,
            height: 36,
            onPressed: _busy
                ? null
                : () => _run(
                      () => SeasonService.setFrozen(s.id, !s.frozen),
                      s.frozen
                          ? 'Standings unfrozen'
                          : 'Standings frozen — no further points',
                    ),
          ),
          if (!ended)
            AdminButton('Close & pay out',
                icon: Icons.emoji_events_rounded,
                height: 36,
                onPressed: _busy ? null : () => _confirmClose(s)),
          AdminButton('Export',
              icon: Icons.copy_all_rounded,
              variant: AdminBtn.soft,
              height: 36,
              onPressed: () => _exportCsv(d)),
          AdminButton('Snapshot ranks',
              icon: Icons.timeline_rounded,
              variant: AdminBtn.soft,
              height: 36,
              onPressed: _busy
                  ? null
                  : () => _run(SeasonService.snapshotRanks,
                      'Ranks snapshotted — next week\'s board will show movement')),
        ]),
        const SizedBox(height: 16),
        for (final row in d.seasons) ...[
          _seasonRow(row, selected: row.id == s.id),
          const SizedBox(height: 8),
        ],
      ]),
    );
  }

  Widget _seasonRow(SeasonSummary s, {required bool selected}) {
    return GestureDetector(
      onTap: () {
        setState(() => _seasonId = s.id);
        _load();
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
        decoration: BoxDecoration(
          color: AdminColors.surfaceAlt,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
              color: selected ? AdminColors.primary : AdminColors.lineSoft,
              width: selected ? 1.5 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text('SEASON ${s.no}', style: AdminText.kicker())),
            StatusBadge(
                s.status == 'live'
                    ? 'live'
                    : (s.status == 'scheduled' ? 'Upcoming' : 'completed')),
          ]),
          const SizedBox(height: 5),
          Text(s.name, style: AdminText.strong()),
          const SizedBox(height: 3),
          Text(s.window, style: AdminText.small(AdminColors.inkFaint)),
          const SizedBox(height: 7),
          Row(children: [
            if (s.champion != null) ...[
              const Icon(Icons.workspace_premium_rounded,
                  size: 13, color: AdminColors.gold),
              const SizedBox(width: 5),
              Expanded(child: Text(s.champion!, style: AdminText.small())),
            ] else
              Expanded(
                  child: Text('${s.ranked} players ranked',
                      style: AdminText.small())),
            if (!s.published)
              Text('Hidden', style: AdminText.small(AdminColors.inkFaint)),
          ]),
        ]),
      ),
    );
  }

  // ── points engine ─────────────────────────────────────────────────
  Widget _pointsEngine(SeasonConsole d) => AdminCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const AdminSection('Points engine', sub: 'What earns season points'),
          for (final r in d.rules) ...[
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                  color: AdminColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(11)),
              child: Row(children: [
                Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: AdminColors.wash(AdminColors.primary, 0.14),
                      borderRadius: BorderRadius.circular(8)),
                  child: Icon(_ruleIcon(r.icon),
                      size: 15, color: AdminColors.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.label, style: AdminText.strong()),
                        const SizedBox(height: 2),
                        Text(r.note,
                            style: AdminText.small(AdminColors.inkFaint)),
                      ]),
                ),
                const SizedBox(width: 8),
                Text('+${r.pts}',
                    style:
                        AdminText.mono(15, FontWeight.w800, AdminColors.ink)),
                IconButton(
                  icon: const Icon(Icons.edit_outlined,
                      size: 16, color: AdminColors.inkSoft),
                  onPressed: () => _editRule(d, r),
                ),
              ]),
            ),
          ],
        ]),
      );

  // ── reward brackets ───────────────────────────────────────────────
  Widget _brackets(SeasonConsole d) => AdminCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AdminSection(
            'Reward brackets',
            sub: '${d.brackets.length} brackets · ${_egp(d.rewardBudget)} committed',
            action: AdminButton('Add',
                icon: Icons.add_rounded,
                height: 32,
                variant: AdminBtn.ghost,
                onPressed: () => _editBracket(d, null)),
          ),
          if (d.brackets.isEmpty)
            Text('No reward brackets — players see no prizes on the board.',
                style: AdminText.small(AdminColors.inkFaint)),
          for (final b in d.brackets)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: AdminColors.surfaceAlt,
                borderRadius: BorderRadius.circular(11),
                border: Border(
                    left: BorderSide(
                        color: _bracketTone(b.colorKey), width: 3)),
              ),
              child: Row(children: [
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Flexible(
                            child: Text(b.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AdminText.strong()),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                                color: AdminColors.surface3,
                                borderRadius: BorderRadius.circular(999)),
                            child: Text(b.rangeLabel,
                                style: AdminText.mono(
                                    10, FontWeight.w700, AdminColors.inkSoft)),
                          ),
                        ]),
                        const SizedBox(height: 3),
                        Text(b.prize.isEmpty ? '—' : b.prize,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AdminText.small()),
                      ]),
                ),
                const SizedBox(width: 8),
                Text(b.budget > 0 ? _egp(b.budget) : '—',
                    style: AdminText.mono(
                        12, FontWeight.w600, AdminColors.inkFaint)),
                IconButton(
                  icon: const Icon(Icons.edit_outlined,
                      size: 16, color: AdminColors.inkSoft),
                  onPressed: () => _editBracket(d, b),
                ),
              ]),
            ),
        ]),
      );

  // ── standings ─────────────────────────────────────────────────────
  Widget _standings(SeasonConsole d) {
    final searching = _query.trim().isNotEmpty;
    return AdminCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AdminSection('Season standings',
            sub: '${d.standings.length} ranked · tap a player to see and edit everything'),
        TextField(
          onChanged: _search,
          style: AdminText.body(),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search_rounded,
                size: 18, color: AdminColors.inkFaint),
            hintText: 'Find any player…',
            filled: true,
            fillColor: AdminColors.surfaceAlt,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            enabledBorder: OutlineInputBorder(
                borderRadius: AdminUI.fieldR,
                borderSide: const BorderSide(color: AdminColors.line)),
            focusedBorder: OutlineInputBorder(
                borderRadius: AdminUI.fieldR,
                borderSide:
                    const BorderSide(color: AdminColors.primary, width: 1.6)),
          ),
        ),
        const SizedBox(height: 12),
        // Searching covers EVERY player, not just the ones already scoring —
        // otherwise a fresh season (empty ledger) has nothing to tap.
        if (searching) ...[
          if (_hits.isEmpty)
            _note('No player matches that name.')
          else
            for (final h in _hits) _hitRow(d, h),
        ] else ...[
          if (d.standings.isEmpty)
            _note('Nobody has scored yet. Points land here automatically when a '
                'ranked match is confirmed — or search for a player above to '
                'open their record and award points by hand.'),
          for (final r in d.standings) _standingRow(d, r),
        ],
      ]),
    );
  }

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
        child: Text(text,
            textAlign: TextAlign.center,
            style: AdminText.small(AdminColors.inkFaint).copyWith(height: 1.45)),
      );

  /// A search hit — already on the board, or not scoring yet.
  Widget _hitRow(SeasonConsole d, SeasonPlayerHit h) {
    final tone = AdminColors.tier(h.tier);
    return GestureDetector(
      onTap: () => _openPlayerRecord(d, h.playerId, h.name),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
            color: AdminColors.surfaceAlt,
            borderRadius: BorderRadius.circular(11)),
        child: Row(children: [
          SizedBox(
            width: 34,
            child: Text(h.rank == null ? '—' : '${h.rank}',
                textAlign: TextAlign.right,
                style: AdminText.mono(
                    13,
                    FontWeight.w800,
                    h.rank == null ? AdminColors.inkFaint : AdminColors.ink)),
          ),
          const SizedBox(width: 10),
          AdminAvatar(h.initials, size: 34, color: tone, imageUrl: h.avatarUrl),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(h.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AdminText.strong()),
                  const SizedBox(height: 2),
                  Text(
                      h.scoring
                          ? '${_titleCase(h.tier)} · on the board'
                          : '${_titleCase(h.tier)} · not scoring yet',
                      style: AdminText.small(AdminColors.inkFaint)),
                ]),
          ),
          const SizedBox(width: 8),
          Text(h.scoring ? _thousands(h.pts) : '—',
              style: AdminText.mono(
                  14,
                  FontWeight.w800,
                  h.scoring ? AdminColors.ink : AdminColors.inkFaint)),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right_rounded,
              size: 20, color: AdminColors.inkFaint),
          const SizedBox(width: 2),
        ]),
      ),
    );
  }

  Widget _standingRow(SeasonConsole d, Standing r) {
    final b = d.bracketFor(r.rank);
    final tone = AdminColors.tier(r.tier == 'elite' ? 'elite' : r.tier);
    return GestureDetector(
      onTap: () => _openPlayer(d, r),
      child: Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
          color: AdminColors.surfaceAlt,
          borderRadius: BorderRadius.circular(11)),
      child: Row(children: [
        SizedBox(
          width: 26,
          child: Text('${r.rank}',
              textAlign: TextAlign.right,
              style: AdminText.mono(13, FontWeight.w800, AdminColors.ink)),
        ),
        SizedBox(
          width: 20,
          child: Icon(
            r.trend > 0
                ? Icons.arrow_upward_rounded
                : r.trend < 0
                    ? Icons.arrow_downward_rounded
                    : Icons.remove_rounded,
            size: 13,
            color: r.trend > 0
                ? AdminColors.green
                : r.trend < 0
                    ? AdminColors.danger
                    : AdminColors.inkFaint,
          ),
        ),
        const SizedBox(width: 4),
        AdminAvatar(r.initials, size: 34, color: tone, imageUrl: r.avatarUrl),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AdminText.strong()),
                const SizedBox(height: 2),
                Text('${_titleCase(r.tier)} · ${r.played} matches',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AdminText.small(AdminColors.inkFaint)),
              ]),
        ),
        if (b != null) ...[
          const SizedBox(width: 6),
          Icon(_ruleIcon(b.icon), size: 14, color: _bracketTone(b.colorKey)),
        ],
        const SizedBox(width: 8),
        Text(_thousands(r.pts),
            style: AdminText.mono(14, FontWeight.w800, AdminColors.ink)),
        const SizedBox(width: 4),
        const Icon(Icons.chevron_right_rounded,
            size: 20, color: AdminColors.inkFaint),
        const SizedBox(width: 2),
      ]),
      ),
    );
  }

  /// The player table row → everything about that player, all of it editable.
  Future<void> _openPlayer(SeasonConsole d, Standing r) =>
      _openPlayerRecord(d, r.playerId, r.name);

  Future<void> _openPlayerRecord(
      SeasonConsole d, String playerId, String name) async {
    await showSeasonPlayerSheet(context,
        seasonId: d.season!.id, playerId: playerId, playerName: name);
    await _load();
    if (_query.trim().isNotEmpty) await _search(_query);
  }

  /// Search every player in the app, not only those already on the board.
  Future<void> _search(String v) async {
    setState(() => _query = v);
    final id = _data?.season?.id;
    final term = v.trim();
    if (id == null || term.isEmpty) {
      if (mounted) setState(() => _hits = const []);
      return;
    }
    final seq = ++_searchSeq;
    final hits = await SeasonService.findPlayers(id, term: term);
    if (!mounted || seq != _searchSeq) return; // a newer keystroke won
    setState(() => _hits = hits);
  }

  static String _titleCase(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  // ── actions ───────────────────────────────────────────────────────

  Future<void> _exportCsv(SeasonConsole d) async {
    final b = StringBuffer('rank,player,tier,points,matches,trend\n');
    for (final r in d.standings) {
      b.writeln('${r.rank},"${r.name}",${r.tier},${r.pts},${r.played},${r.trend}');
    }
    await Clipboard.setData(ClipboardData(text: b.toString()));
    if (mounted) adminToast(context, 'Standings copied as CSV');
  }

  Future<void> _confirmClose(SeasonSummary s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AdminColors.surface,
        title: Text('Close ${s.name}?', style: AdminText.h2()),
        content: Text(
          'Standings are frozen for good, the champion is stamped, and every '
          'player inside a reward bracket is notified. The next scheduled '
          'season goes live immediately. This cannot be undone.',
          style: AdminText.body(AdminColors.inkSoft),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel', style: AdminText.strong(AdminColors.inkSoft))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  Text('Close & pay out', style: AdminText.strong(AdminColors.danger))),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => SeasonService.closeSeason(s.id), 'Season closed');
  }

  Future<void> _editRule(SeasonConsole d, SeasonRule r) async {
    final pts = TextEditingController(text: '${r.pts}');
    final note = TextEditingController(text: r.note);
    final saved = await adminSheet<bool>(
      context,
      title: r.label,
      sub: 'Points awarded each time this happens',
      heightFactor: 0.62,
      body: Column(children: [
        _field('Points', pts, prefix: 'PTS', hint: 'Applies from today onward'),
        const SizedBox(height: 14),
        _field('Description shown to players', note),
      ]),
      footer: Row(children: [
        Expanded(
          child: AdminButton('Save rule',
              icon: Icons.check_rounded,
              full: true,
              onPressed: () => Navigator.pop(context, true)),
        ),
      ]),
    );
    if (saved != true) return;
    await _run(
      () => SeasonService.saveRule(
          d.season!.id, r.code, int.tryParse(pts.text.trim()) ?? r.pts, note.text.trim()),
      '${r.label} updated',
    );
  }

  Future<void> _editBracket(SeasonConsole d, SeasonBracket? b) async {
    final label = TextEditingController(text: b?.label ?? '');
    final from = TextEditingController(text: '${b?.rankFrom ?? _nextFreeRank(d)}');
    final to = TextEditingController(text: '${b?.rankTo ?? _nextFreeRank(d) + 49}');
    final prize = TextEditingController(text: b?.prize ?? '');
    final extras = TextEditingController(text: (b?.extras ?? const []).join('\n'));
    final budget = TextEditingController(text: '${b?.budget ?? 0}');
    var icon = b?.icon ?? 'shield';
    var color = b?.colorKey ?? 'inksoft';

    final action = await adminSheet<String>(
      context,
      title: b == null ? 'New reward bracket' : b.label,
      sub: 'Rank range → what those players win',
      body: StatefulBuilder(
        builder: (ctx, setSheet) => Column(children: [
          _field('Bracket name', label, hint: 'e.g. Top 100'),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: _field('From rank', from, prefix: '#')),
            const SizedBox(width: 12),
            Expanded(child: _field('To rank', to, prefix: '#')),
          ]),
          const SizedBox(height: 14),
          _field('Main reward', prize, hint: 'e.g. EGP 500 store voucher'),
          const SizedBox(height: 14),
          _field('Extra perks (one per line)', extras, maxLines: 3),
          const SizedBox(height: 14),
          _field('Budget', budget,
              prefix: 'EGP', hint: 'Total cash committed across this bracket'),
          const SizedBox(height: 16),
          _picker('Icon', const [
            'crown', 'medal', 'trophy', 'star', 'shield'
          ], icon, (v) => setSheet(() => icon = v),
              build: (v, on) => Icon(_ruleIcon(v),
                  size: 18, color: on ? AdminColors.primary : AdminColors.inkSoft)),
          const SizedBox(height: 12),
          _picker('Colour', const [
            'gold', 'silver', 'primary', 'bronzegold', 'inksoft'
          ], color, (v) => setSheet(() => color = v),
              build: (v, on) => Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                        color: _bracketTone(v), shape: BoxShape.circle),
                  )),
        ]),
      ),
      footer: Row(children: [
        Expanded(
          child: AdminButton('Save bracket',
              icon: Icons.check_rounded,
              full: true,
              onPressed: () => Navigator.pop(context, 'save')),
        ),
        if (b != null) ...[
          const SizedBox(width: 10),
          AdminButton('Remove',
              icon: Icons.delete_outline_rounded,
              variant: AdminBtn.danger,
              onPressed: () => Navigator.pop(context, 'remove')),
        ],
      ]),
    );

    if (action == 'remove' && b != null) {
      await _run(() => SeasonService.deleteBracket(b.id), 'Bracket removed');
      return;
    }
    if (action != 'save') return;
    await _run(
      () => SeasonService.saveBracket(
        id: b?.id,
        seasonId: d.season!.id,
        rankFrom: int.tryParse(from.text.trim()) ?? 1,
        rankTo: int.tryParse(to.text.trim()) ?? 1,
        label: label.text.trim(),
        prize: prize.text.trim(),
        extras: extras.text
            .split('\n')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        budget: int.tryParse(budget.text.trim()) ?? 0,
        icon: icon,
        color: color,
      ),
      'Reward bracket saved',
    );
  }

  /// First rank not already covered by a bracket — a sane default for a new one.
  int _nextFreeRank(SeasonConsole d) {
    var n = 1;
    for (final b in d.brackets) {
      if (b.rankTo >= n) n = b.rankTo + 1;
    }
    return n;
  }

  Future<void> _newSeason() async {
    final d = _data;
    final name = TextEditingController();
    final now = DateTime.now();
    var start = DateTime(now.year, now.month, now.day);
    var end = start.add(const Duration(days: 120));
    var copy = d?.season != null;

    final saved = await adminSheet<bool>(
      context,
      title: 'New season',
      sub: 'Schedule the next leaderboard cycle',
      heightFactor: 0.72,
      body: StatefulBuilder(
        builder: (ctx, setSheet) => Column(children: [
          _field('Season name', name, hint: 'e.g. Autumn Season'),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: _dateField('Starts', start, (v) => setSheet(() => start = v)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _dateField('Ends', end, (v) => setSheet(() => end = v)),
            ),
          ]),
          if (d?.season != null) ...[
            const SizedBox(height: 14),
            GestureDetector(
              onTap: () => setSheet(() => copy = !copy),
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(
                    color: AdminColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color:
                            copy ? AdminColors.primary : AdminColors.line)),
                child: Row(children: [
                  Icon(
                      copy
                          ? Icons.check_box_rounded
                          : Icons.check_box_outline_blank_rounded,
                      size: 20,
                      color:
                          copy ? AdminColors.primary : AdminColors.inkFaint),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Copy the points engine & reward brackets from '
                      '${d!.season!.name}',
                      style: AdminText.small(AdminColors.ink),
                    ),
                  ),
                ]),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            decoration: BoxDecoration(
                color: AdminColors.surfaceAlt,
                borderRadius: BorderRadius.circular(11)),
            child: Row(children: [
              const Icon(Icons.info_outline_rounded,
                  size: 17, color: AdminColors.inkSoft),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Everyone starts at 0 points. The new season goes live '
                  'automatically when the current one closes — or straight '
                  'away if none is running.',
                  style: AdminText.small().copyWith(height: 1.4),
                ),
              ),
            ]),
          ),
        ]),
      ),
      footer: Row(children: [
        Expanded(
          child: AdminButton('Schedule season',
              icon: Icons.check_rounded,
              full: true,
              onPressed: () => Navigator.pop(context, true)),
        ),
      ]),
    );
    if (saved != true) return;
    await _run(
      () => SeasonService.createSeason(
        name: name.text.trim(),
        starts: start,
        ends: end,
        copyFromSeasonId: copy ? d?.season?.id : null,
      ),
      'Season scheduled',
    );
  }

  // ── small inputs ──────────────────────────────────────────────────

  Widget _field(String label, TextEditingController c,
      {String? hint,
      String? prefix,
      int maxLines = 1,
      ValueChanged<String>? onChanged}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: AdminText.strong(AdminColors.inkSoft)),
      const SizedBox(height: 7),
      TextField(
        controller: c,
        maxLines: maxLines,
        onChanged: onChanged,
        keyboardType: prefix == null
            ? TextInputType.text
            : const TextInputType.numberWithOptions(signed: true),
        style: AdminText.body(),
        decoration: InputDecoration(
          isDense: true,
          prefixText: prefix != null ? '$prefix ' : null,
          prefixStyle: AdminText.mono(12, FontWeight.w700, AdminColors.inkFaint),
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
        Text(hint, style: AdminText.small(AdminColors.inkFaint)),
      ],
    ]);
  }

  Widget _dateField(String label, DateTime value, ValueChanged<DateTime> onPick) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: AdminText.strong(AdminColors.inkSoft)),
      const SizedBox(height: 7),
      GestureDetector(
        onTap: () async {
          final picked = await showDatePicker(
            context: context,
            initialDate: value,
            firstDate: DateTime(value.year - 2),
            lastDate: DateTime(value.year + 4),
          );
          if (picked != null) onPick(picked);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
          decoration: BoxDecoration(
            color: AdminColors.surfaceAlt,
            borderRadius: AdminUI.fieldR,
            border: Border.all(color: AdminColors.line),
          ),
          child: Row(children: [
            const Icon(Icons.calendar_today_rounded,
                size: 15, color: AdminColors.inkFaint),
            const SizedBox(width: 9),
            Text('${_short(value)} ${value.year}', style: AdminText.body()),
          ]),
        ),
      ),
    ]);
  }

  Widget _picker(String label, List<String> options, String value,
      ValueChanged<String> onPick,
      {required Widget Function(String value, bool selected) build}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: AdminText.strong(AdminColors.inkSoft)),
      const SizedBox(height: 7),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final o in options)
          GestureDetector(
            onTap: () => onPick(o),
            child: Container(
              width: 44,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AdminColors.surfaceAlt,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(
                    color: o == value ? AdminColors.primary : AdminColors.line,
                    width: o == value ? 1.6 : 1),
              ),
              child: build(o, o == value),
            ),
          ),
      ]),
    ]);
  }
}

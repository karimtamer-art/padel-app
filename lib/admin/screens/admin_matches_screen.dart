import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';
import '../data/admin_service.dart';

/// Super-Admin Matches console: KPIs, volume + format insights, and
/// Disputes / Lobbies / Completed tabs with a detail sheet and a
/// remove-with-reason flow (soft cancel + audit log).
class AdminMatchesScreen extends StatefulWidget {
  /// Organizers run events, not the platform — they don't need the
  /// competitive-vs-casual format split, so it's hidden for them.
  final bool isOrganizer;
  const AdminMatchesScreen({super.key, this.isOrganizer = false});
  @override
  State<AdminMatchesScreen> createState() => _AdminMatchesScreenState();
}

const _reasons = [
  'Fake or test match',
  'Abusive / inappropriate content',
  'Duplicate entry',
  'Venue cancelled the booking',
  'Cheating or score manipulation',
  'Player requested removal',
  'Other',
];

class _AdminMatchesScreenState extends State<AdminMatchesScreen> {
  List<Map<String, dynamic>> _matches = [];
  List<int> _weekly = const [0, 0, 0, 0, 0, 0, 0];
  bool _loading = true;
  String? _error;
  int _tab = 0; // 0 disputes · 1 lobbies · 2 completed
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        AdminService.matchesConsole(),
        AdminService.fetchWeeklyMatchCounts(),
      ]);
      if (!mounted) return;
      setState(() {
        _matches = results[0] as List<Map<String, dynamic>>;
        _weekly = results[1] as List<int>;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  // ── derived buckets ──
  // Active/ongoing matches: open + full lobbies, plus matches whose time has
  // passed and are awaiting result confirmation (pending_confirm / in_progress).
  // Without these two, a match that filled and played was in NO tab — invisible
  // to the admin until it completed or was disputed.
  static const _awaiting = {'pending_confirm', 'in_progress'};
  List<Map<String, dynamic>> get _lobbies =>
      _matches.where((m) =>
          m['status'] == 'open' ||
          m['status'] == 'full' ||
          _awaiting.contains(m['status'])).toList();
  List<Map<String, dynamic>> get _completed =>
      _matches.where((m) => m['status'] == 'completed').toList();
  List<Map<String, dynamic>> get _disputes =>
      _matches.where((m) => m['status'] == 'disputed').toList();

  static bool _isToday(Map m) {
    final dt = DateTime.tryParse(m['scheduled_at'] as String? ?? '')?.toLocal();
    if (dt == null) return false;
    final now = DateTime.now();
    return dt.year == now.year && dt.month == now.month && dt.day == now.day;
  }

  static bool _isCompetitive(Map m) => m['match_type'] == 'ranked';

  static String _court(Map m) =>
      (m['venue_name'] as String?)?.trim().isNotEmpty == true
          ? m['venue_name'] as String
          : (m['court_name'] as String?)?.trim().isNotEmpty == true
              ? m['court_name'] as String
              : 'Court TBD';

  static const _dow = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
  static const _mon = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  static String _when(Map m) {
    final dt = DateTime.tryParse(m['scheduled_at'] as String? ?? '')?.toLocal();
    if (dt == null) return 'TBD';
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final mm = dt.minute.toString().padLeft(2, '0');
    return '${_dow[dt.weekday - 1]} · $h:$mm ${dt.hour < 12 ? 'AM' : 'PM'}';
  }

  static String _date(Map m) {
    final dt = DateTime.tryParse(m['scheduled_at'] as String? ?? '')?.toLocal();
    return dt == null ? '' : '${_mon[dt.month - 1]} ${dt.day}';
  }

  /// Player names split by team → (teamA, teamB).
  static (List<String>, List<String>) _teams(Map m) {
    final a = <String>[], b = <String>[];
    for (final p in (m['players'] as List? ?? const [])) {
      final name = (p['name'] as String?) ?? 'Player';
      if (p['team'] == 'b') { b.add(name); } else { a.add(name); }
    }
    return (a, b);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AdminColors.primary));
    }
    if (_error != null) {
      return RefreshIndicator(
        color: AdminColors.primary,
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 60, 14, 40), children: [
          _empty(Icons.wifi_off_rounded, "Couldn't load matches", 'Pull down to refresh or tap retry.'),
          const SizedBox(height: 16),
          Center(child: AdminButton('Retry', onPressed: _load)),
        ]),
      );
    }

    final weekTotal = _weekly.fold<int>(0, (a, b) => a + b);
    final today = _lobbies.where(_isToday).length;
    final disputes = _disputes.length;
    final comp = _matches.where((m) => m['status'] != 'cancelled' && _isCompetitive(m)).length;
    final casual = _matches.where((m) => m['status'] != 'cancelled' && !_isCompetitive(m)).length;
    final settled = _completed.length + disputes;
    final disputeRate = settled == 0 ? 0.0 : disputes / settled * 100;

    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 40), children: [
        KpiGrid([
          StatCard(icon: Icons.trending_up_rounded, tone: AdminColors.primary,
              label: 'Matches / week', value: '$weekTotal'),
          StatCard(icon: Icons.lock_open_outlined, tone: AdminColors.success,
              label: 'Open lobbies', value: '${_lobbies.length}',
              foot: today > 0 ? '$today starting today' : 'none today'),
          StatCard(icon: Icons.check_circle_outline_rounded, tone: AdminColors.info,
              label: 'Completed', value: '${_completed.length}'),
          StatCard(icon: Icons.gavel_rounded,
              tone: disputes > 0 ? AdminColors.danger : AdminColors.inkSoft,
              label: 'Open disputes', value: '$disputes',
              foot: disputes > 0 ? 'Needs review' : 'All clear'),
        ]),
        const SizedBox(height: 16),
        _volumeCard(weekTotal),
        if (!widget.isOrganizer) ...[
          const SizedBox(height: 12),
          _formatCard(comp, casual, disputeRate),
        ],
        const SizedBox(height: 18),
        _tabs(),
        const SizedBox(height: 12),
        ..._tabBody(),
      ]),
    );
  }

  // ── Insight: 7-day volume ──
  Widget _volumeCard(int weekTotal) {
    final peak = _weekly.isEmpty ? 0 : _weekly.reduce(math.max);
    return AdminCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('Match volume', style: AdminText.strong())),
          Text('$weekTotal this week', style: AdminText.small()),
        ]),
        const SizedBox(height: 14),
        SizedBox(
          height: 112,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (int i = 0; i < 7; i++)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                    Text('${_weekly.length > i ? _weekly[i] : 0}',
                        style: AdminText.mono(9.5, FontWeight.w600, AdminColors.inkFaint)),
                    const SizedBox(height: 3),
                    Container(
                      height: (peak == 0 ? 0 : (_weekly.length > i ? _weekly[i] : 0) / peak) * 64 + 2,
                      decoration: BoxDecoration(
                        color: (_weekly.length > i && _weekly[i] == peak && peak > 0)
                            ? AdminColors.primary
                            : AdminColors.wash(AdminColors.primary, 0.28),
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(_dow[i], style: AdminText.sans(9.5, FontWeight.w600, AdminColors.inkFaint)),
                  ]),
                ),
              ),
          ]),
        ),
      ]),
    );
  }

  // ── Insight: format split donut + dispute rate ──
  Widget _formatCard(int comp, int casual, double disputeRate) {
    final total = comp + casual;
    return AdminCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Format split', style: AdminText.strong()),
        const SizedBox(height: 14),
        Row(children: [
          SizedBox(
            width: 84, height: 84,
            child: CustomPaint(
              painter: _DonutPainter(total == 0 ? 0 : comp / total),
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('$total', style: AdminText.sans(18, FontWeight.w800, AdminColors.ink)),
                  Text('total', style: AdminText.sans(9, FontWeight.w600, AdminColors.inkFaint)),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(children: [
              _legendRow(AdminColors.primary, 'Competitive', comp, total),
              const SizedBox(height: 8),
              _legendRow(AdminColors.info, 'Casual', casual, total),
            ]),
          ),
        ]),
        const Divider(height: 22, color: AdminColors.lineSoft),
        Row(children: [
          Icon(disputeRate > 8 ? Icons.warning_amber_rounded : Icons.verified_outlined,
              size: 16, color: disputeRate > 8 ? AdminColors.danger : AdminColors.success),
          const SizedBox(width: 8),
          Expanded(child: Text('Dispute rate', style: AdminText.small())),
          Text('${disputeRate.toStringAsFixed(1)}%',
              style: AdminText.sans(13, FontWeight.w800,
                  disputeRate > 8 ? AdminColors.danger : AdminColors.ink)),
        ]),
      ]),
    );
  }

  Widget _legendRow(Color c, String label, int n, int total) {
    final pct = total == 0 ? 0 : (n / total * 100).round();
    return Row(children: [
      Container(width: 9, height: 9, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
      const SizedBox(width: 8),
      Expanded(child: Text(label, style: AdminText.small(AdminColors.inkSoft))),
      Text('$n', style: AdminText.sans(12.5, FontWeight.w800, AdminColors.ink)),
      const SizedBox(width: 5),
      Text('· $pct%', style: AdminText.small()),
    ]);
  }

  // ── Tabs ──
  Widget _tabs() {
    Widget seg(int i, String label, int count) {
      final on = _tab == i;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() { _tab = i; _filter = 'all'; }),
          child: Container(
            margin: const EdgeInsets.all(3),
            padding: const EdgeInsets.symmetric(vertical: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? AdminColors.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text('$label · $count',
                style: AdminText.sans(12, FontWeight.w700,
                    on ? Colors.white : AdminColors.inkSoft)),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
          color: AdminColors.surfaceAlt, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        seg(0, 'Disputes', _disputes.length),
        seg(1, 'Lobbies', _lobbies.length),
        seg(2, 'Completed', _completed.length),
      ]),
    );
  }

  List<Widget> _tabBody() {
    switch (_tab) {
      case 1:
        return _lobbiesTab();
      case 2:
        return _completedTab();
      default:
        return _disputesTab();
    }
  }

  Widget _chips(List<String> keys, List<String> labels) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (int i = 0; i < keys.length; i++) ...[
            GestureDetector(
              onTap: () => setState(() => _filter = keys[i]),
              child: Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                decoration: BoxDecoration(
                  color: _filter == keys[i] ? AdminColors.primary : AdminColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(labels[i],
                    style: AdminText.sans(12, FontWeight.w700,
                        _filter == keys[i] ? Colors.white : AdminColors.inkSoft)),
              ),
            ),
          ],
        ]),
      );

  // ── Disputes ──
  List<Widget> _disputesTab() {
    final items = List<Map<String, dynamic>>.from(_disputes)
      ..sort((a, b) => ((b['min_elo'] as num?) ?? 0).compareTo((a['min_elo'] as num?) ?? 0));
    if (items.isEmpty) {
      return [_empty(Icons.verified_outlined, 'No open disputes', 'Contested results show up here for review.')];
    }
    return [for (final m in items) _disputeCard(m)];
  }

  Widget _disputeCard(Map<String, dynamic> m) {
    final (teamA, teamB) = _teams(m);
    final minElo = (m['min_elo'] as num?)?.toInt() ?? 0;
    final subs = (m['submissions'] as List?) ?? const [];
    Map<String, dynamic>? subA, subB;
    for (final s in subs) {
      if (s['team'] == 'a') {
        subA = Map<String, dynamic>.from(s as Map);
      } else if (s['team'] == 'b') {
        subB = Map<String, dynamic>.from(s as Map);
      }
    }
    final conflict = subA != null && subB != null && subA['winner'] != subB['winner'];
    return _accentCard(
      accent: AdminColors.danger,
      onTap: () => _detail(m, 'dispute'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(_court(m), style: AdminText.strong(), maxLines: 1, overflow: TextOverflow.ellipsis)),
          _pill('Disputed', AdminColors.danger),
        ]),
        const SizedBox(height: 4),
        Text('${_when(m)} · ${_date(m)}', style: AdminText.small()),
        const SizedBox(height: 10),
        _teamLine(teamA, false),
        const SizedBox(height: 4),
        _teamLine(teamB, false),
        const SizedBox(height: 10),
        // Both teams' claims side-by-side.
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _claimBox(subA, 'TEAM A CLAIMS'),
            const SizedBox(width: 8),
            _claimBox(subB, 'TEAM B CLAIMS'),
          ]),
        ),
        if (conflict) ...[
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.report_gmailerrorred_outlined, size: 14, color: AdminColors.danger),
            const SizedBox(width: 6),
            Text('Teams disagree on the winner', style: AdminText.sans(11, FontWeight.w700, AdminColors.danger)),
          ]),
        ],
        const SizedBox(height: 10),
        Row(children: [
          if (minElo > 0) ...[
            _tag('Min ELO $minElo'),
            const SizedBox(width: 6),
          ],
          _tag(_isCompetitive(m) ? 'Competitive' : 'Casual'),
          const Spacer(),
          _removeBtn(m),
        ]),
        const SizedBox(height: 10),
        AdminButton('Resolve dispute',
            full: true, height: 40, icon: Icons.gavel_rounded,
            onPressed: () => _resolve(m)),
      ]),
    );
  }

  Future<void> _resolve(Map<String, dynamic> m) async {
    final id = m['id'] as String?;
    if (id == null) return;
    final (teamA, teamB) = _teams(m);
    String? winner;
    final aC = TextEditingController();
    final bC = TextEditingController();
    final noteC = TextEditingController();

    Widget opt(String team, String label, List<String> names, void Function(void Function()) setSheet) {
      final on = winner == team;
      return GestureDetector(
        onTap: () => setSheet(() => winner = team),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: on ? AdminColors.wash(AdminColors.primary, 0.10) : AdminColors.surfaceAlt,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
                color: on ? AdminColors.primary : AdminColors.line, width: 1.5),
          ),
          child: Row(children: [
            Icon(on ? Icons.emoji_events_rounded : Icons.circle_outlined,
                size: 18, color: on ? AdminColors.gold : AdminColors.inkFaint),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: AdminText.kicker()),
                const SizedBox(height: 1),
                Text(names.isEmpty ? '—' : names.join(' & '),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: AdminText.strong()),
              ]),
            ),
          ]),
        ),
      );
    }

    final res = await showModalBottomSheet<Map<String, String?>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            margin: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: AdminColors.surface, borderRadius: BorderRadius.circular(18)),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Resolve dispute', style: AdminText.h2()),
                  const SizedBox(height: 4),
                  Text('Pick the winner and confirm the score. ELO recalculates for all players and both teams are notified.',
                      style: AdminText.small()),
                  const SizedBox(height: 16),
                  Text('WINNING TEAM', style: AdminText.kicker()),
                  const SizedBox(height: 8),
                  opt('a', 'Team A', teamA, setSheet),
                  const SizedBox(height: 8),
                  opt('b', 'Team B', teamB, setSheet),
                  const SizedBox(height: 14),
                  Text('SCORE (optional)', style: AdminText.kicker()),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: aC,
                        decoration: const InputDecoration(hintText: 'A games · e.g. 6, 4'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: bC,
                        decoration: const InputDecoration(hintText: 'B games · e.g. 3, 6'),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteC,
                    minLines: 1,
                    maxLines: 2,
                    decoration: const InputDecoration(hintText: 'Resolution note (optional)'),
                  ),
                  const SizedBox(height: 16),
                  AdminButton('Finalize result',
                      full: true,
                      onPressed: winner == null
                          ? null
                          : () => Navigator.pop(ctx, {
                                'winner': winner,
                                'a': aC.text.trim(),
                                'b': bC.text.trim(),
                                'note': noteC.text.trim(),
                              })),
                ]),
              ),
            ),
          ),
        );
      }),
    );
    aC.dispose();
    bC.dispose();
    noteC.dispose();
    if (res == null) return;
    final err = await AdminService.resolveMatch(id,
        winner: res['winner']!, scoreA: res['a'], scoreB: res['b'], note: res['note']);
    if (!mounted) return;
    if (err != null) {
      adminToast(context, err);
      return;
    }
    adminToast(context, 'Dispute resolved');
    _load(); // now completed → moves to the Completed tab
  }

  // ── Lobbies ──
  List<Widget> _lobbiesTab() {
    var items = List<Map<String, dynamic>>.from(_lobbies);
    switch (_filter) {
      case 'open': items = items.where((m) => m['status'] == 'open').toList(); break;
      case 'full': items = items.where((m) => m['status'] == 'full').toList(); break;
      case 'awaiting': items = items.where((m) => _awaiting.contains(m['status'])).toList(); break;
      case 'competitive': items = items.where(_isCompetitive).toList(); break;
      case 'casual': items = items.where((m) => !_isCompetitive(m)).toList(); break;
    }
    return [
      _chips(const ['all', 'open', 'full', 'awaiting', 'competitive', 'casual'],
          const ['All', 'Open', 'Full', 'Awaiting result', 'Competitive', 'Casual']),
      const SizedBox(height: 12),
      if (items.isEmpty)
        _empty(Icons.sports_tennis_rounded, 'No lobbies',
            'Open, full and awaiting-result matches appear here.')
      else
        for (final m in items) _lobbyCard(m),
    ];
  }

  Widget _lobbyCard(Map<String, dynamic> m) {
    final players = (m['player_count'] as num?)?.toInt() ?? 0;
    final awaiting = _awaiting.contains(m['status']);
    final full = m['status'] == 'full' || players >= 4;
    final minElo = (m['min_elo'] as num?)?.toInt() ?? 0;
    final host = m['host'] as String?;
    final faulty = players == 0;
    return _accentCard(
      accent: faulty
          ? AdminColors.danger
          : (awaiting ? AdminColors.info : (full ? AdminColors.warn : AdminColors.success)),
      onTap: () => _detail(m, 'lobby'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(_court(m), style: AdminText.strong(), maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (faulty) ...[_pill('Faulty', AdminColors.danger), const SizedBox(width: 6)]
          else if (!awaiting && _isToday(m)) ...[_pill('Soon', AdminColors.warn), const SizedBox(width: 6)],
          _pill(awaiting ? 'Awaiting result' : (full ? 'Full' : 'Open'),
              awaiting ? AdminColors.info : (full ? AdminColors.warn : AdminColors.success)),
        ]),
        const SizedBox(height: 4),
        Text('${_when(m)}${host != null ? '  ·  $host' : ''}', style: AdminText.small()),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: (players / 4).clamp(0.0, 1.0),
                minHeight: 7,
                backgroundColor: AdminColors.surface3,
                color: full ? AdminColors.warn : AdminColors.success,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text('$players/4', style: AdminText.mono(11.5, FontWeight.w700, AdminColors.ink)),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          _tag(_isCompetitive(m) ? 'Competitive' : 'Casual'),
          if (minElo > 0) ...[const SizedBox(width: 6), _tag('Min ELO $minElo')],
          const Spacer(),
          _removeBtn(m),
        ]),
      ]),
    );
  }

  // ── Completed ──
  List<Widget> _completedTab() {
    var items = List<Map<String, dynamic>>.from(_completed);
    if (_filter == 'competitive') items = items.where(_isCompetitive).toList();
    if (_filter == 'casual') items = items.where((m) => !_isCompetitive(m)).toList();
    return [
      _chips(const ['all', 'competitive', 'casual'], const ['All', 'Competitive', 'Casual']),
      const SizedBox(height: 12),
      if (items.isEmpty)
        _empty(Icons.check_circle_outline_rounded, 'No completed matches', 'Finished results appear here.')
      else
        for (final m in items) _completedCard(m),
    ];
  }

  Widget _completedCard(Map<String, dynamic> m) {
    final (teamA, teamB) = _teams(m);
    final aWon = m['winner_team'] == 'a';
    final delta = (m['elo_delta'] as num?)?.toDouble();
    final scoreA = m['score_team_a'] as String?;
    final scoreB = m['score_team_b'] as String?;
    final score = (scoreA != null && scoreB != null)
        ? _zipScore(scoreA, scoreB)
        : null;
    return _accentCard(
      accent: AdminColors.info,
      onTap: () => _detail(m, 'completed'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(_court(m), style: AdminText.strong(), maxLines: 1, overflow: TextOverflow.ellipsis)),
          Text('${_when(m)} · ${_date(m)}', style: AdminText.small()),
        ]),
        const SizedBox(height: 10),
        _teamLine(teamA, aWon),
        const SizedBox(height: 4),
        _teamLine(teamB, !aWon),
        const SizedBox(height: 10),
        Row(children: [
          if (score != null) _tag(score),
          const Spacer(),
          if (delta != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AdminColors.wash(delta >= 0 ? AdminColors.success : AdminColors.danger, 0.14),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text('${delta >= 0 ? '▲' : '▼'} ${delta.abs().toStringAsFixed(2)}',
                  style: AdminText.mono(11, FontWeight.w800,
                      delta >= 0 ? AdminColors.success : AdminColors.danger)),
            ),
          const SizedBox(width: 8),
          _removeBtn(m),
        ]),
      ]),
    );
  }

  static String _zipScore(String a, String b) {
    final sa = a.split(','), sb = b.split(',');
    final n = math.min(sa.length, sb.length);
    final out = <String>[];
    for (int i = 0; i < n; i++) {
      final x = sa[i].trim(), y = sb[i].trim();
      if (x.isEmpty || y.isEmpty) continue;
      out.add('$x-$y');
    }
    return out.join('  ');
  }

  // ── Shared bits ──
  Widget _teamLine(List<String> names, bool winner) => Row(children: [
        Icon(winner ? Icons.emoji_events_rounded : Icons.circle,
            size: winner ? 15 : 7, color: winner ? AdminColors.gold : AdminColors.inkFaint),
        const SizedBox(width: 8),
        Expanded(
          child: Text(names.isEmpty ? '—' : names.join(' & '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: winner
                  ? AdminText.sans(13, FontWeight.w800, AdminColors.ink)
                  : AdminText.small(AdminColors.inkSoft)),
        ),
      ]);

  Widget _claimBox(Map<String, dynamic>? sub, String label) {
    if (sub == null) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(color: AdminColors.surfaceAlt, borderRadius: BorderRadius.circular(9)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: AdminText.kicker()),
            const SizedBox(height: 4),
            Text('No submission', style: AdminText.small()),
          ]),
        ),
      );
    }
    final score = _zipScore((sub['score_a'] as String?) ?? '', (sub['score_b'] as String?) ?? '');
    final w = sub['winner'];
    final winnerLabel = w == 'a' ? 'Team A won' : w == 'b' ? 'Team B won' : '—';
    final by = sub['submitter'] as String?;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(color: AdminColors.surfaceAlt, borderRadius: BorderRadius.circular(9)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: AdminText.kicker()),
          const SizedBox(height: 4),
          Text(score.isEmpty ? '—' : score, style: AdminText.mono(12, FontWeight.w800, AdminColors.ink)),
          const SizedBox(height: 2),
          Text(winnerLabel, style: AdminText.sans(11, FontWeight.w700, AdminColors.inkSoft)),
          if (by != null) ...[
            const SizedBox(height: 1),
            Text('by ${by.split(' ').first}',
                style: AdminText.sans(10, FontWeight.w500, AdminColors.inkFaint)),
          ],
        ]),
      ),
    );
  }

  Widget _accentCard({required Color accent, required Widget child, VoidCallback? onTap}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: AdminCard(
          padding: EdgeInsets.zero,
          onTap: onTap,
          // IntrinsicHeight so the stretched accent bar has a bounded height
          // (a stretch Row inside a ListView is otherwise unbounded → crash).
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(width: 4,
                  decoration: BoxDecoration(
                      color: accent,
                      borderRadius: const BorderRadius.horizontal(left: Radius.circular(12)))),
              Expanded(child: Padding(padding: const EdgeInsets.all(12), child: child)),
            ]),
          ),
        ),
      );

  Widget _pill(String s, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: AdminColors.wash(c, 0.14), borderRadius: BorderRadius.circular(999)),
        child: Text(s, style: AdminText.sans(10.5, FontWeight.w800, c)),
      );

  Widget _tag(String s) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: AdminColors.surfaceAlt, borderRadius: BorderRadius.circular(7)),
        child: Text(s, style: AdminText.sans(10.5, FontWeight.w700, AdminColors.inkSoft)),
      );

  Widget _removeBtn(Map<String, dynamic> m) => GestureDetector(
        onTap: () => _remove(m),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.delete_outline_rounded, size: 16, color: AdminColors.danger),
          const SizedBox(width: 3),
          Text('Remove', style: AdminText.sans(11.5, FontWeight.w700, AdminColors.danger)),
        ]),
      );

  Widget _empty(IconData icon, String title, String sub) => Padding(
        padding: const EdgeInsets.only(top: 40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 56, height: 56, alignment: Alignment.center,
            decoration: BoxDecoration(color: AdminColors.surfaceAlt, borderRadius: BorderRadius.circular(16)),
            child: Icon(icon, size: 26, color: AdminColors.inkFaint),
          ),
          const SizedBox(height: 14),
          Text(title, style: AdminText.h2()),
          const SizedBox(height: 6),
          Text(sub, textAlign: TextAlign.center, style: AdminText.small()),
        ]),
      );

  // ── Detail sheet ──
  void _detail(Map<String, dynamic> m, String kind) {
    final (teamA, teamB) = _teams(m);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: AdminColors.surface, borderRadius: BorderRadius.circular(18)),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(_court(m), style: AdminText.h2())),
                _pill(_statusLabel(m['status'] as String?), _statusColor(m['status'] as String?)),
              ]),
              const SizedBox(height: 4),
              Text('${_when(m)} · ${_date(m)}', style: AdminText.small()),
              const SizedBox(height: 16),
              Text('TEAM A', style: AdminText.kicker()),
              const SizedBox(height: 4),
              Text(teamA.isEmpty ? '—' : teamA.join(' & '), style: AdminText.strong()),
              const SizedBox(height: 10),
              Text('TEAM B', style: AdminText.kicker()),
              const SizedBox(height: 4),
              Text(teamB.isEmpty ? '—' : teamB.join(' & '), style: AdminText.strong()),
              if (m['score_team_a'] != null) ...[
                const SizedBox(height: 14),
                Text('SCORE (A / B)', style: AdminText.kicker()),
                const SizedBox(height: 4),
                Text('${m['score_team_a']}  /  ${m['score_team_b'] ?? '—'}',
                    style: AdminText.mono(13, FontWeight.w700, AdminColors.ink)),
              ],
              const SizedBox(height: 18),
              AdminButton('Remove from app',
                  full: true, variant: AdminBtn.ghost, icon: Icons.delete_outline_rounded,
                  onPressed: () { Navigator.pop(ctx); _remove(m); }),
            ]),
          ),
        ),
      ),
    );
  }

  // ── Remove with reason ──
  Future<void> _remove(Map<String, dynamic> m) async {
    final id = m['id'] as String?;
    if (id == null) return;
    final noteC = TextEditingController();
    String? reason;
    final isResult = m['status'] == 'completed' || m['status'] == 'disputed';

    final res = await showModalBottomSheet<Map<String, String?>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        final needsNote = reason == 'Other';
        final canRemove = reason != null && (!needsNote || noteC.text.trim().isNotEmpty);
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            margin: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: AdminColors.surface, borderRadius: BorderRadius.circular(18)),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Remove match', style: AdminText.h2()),
                  const SizedBox(height: 4),
                  Text(
                      isResult
                          ? 'Hides it from every player’s history. The record + ratings stay in the DB (ELO revert is a later step).'
                          : 'Cancels the lobby and removes it from players’ apps. The record is kept in the DB.',
                      style: AdminText.small()),
                  const SizedBox(height: 14),
                  Text('REASON', style: AdminText.kicker()),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final r in _reasons)
                      GestureDetector(
                        onTap: () => setSheet(() => reason = r),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: reason == r ? AdminColors.primary : AdminColors.surfaceAlt,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(r,
                              style: AdminText.sans(11.5, FontWeight.w700,
                                  reason == r ? Colors.white : AdminColors.inkSoft)),
                        ),
                      ),
                  ]),
                  const SizedBox(height: 14),
                  TextField(
                    controller: noteC,
                    minLines: 1,
                    maxLines: 3,
                    onChanged: (_) => setSheet(() {}),
                    decoration: InputDecoration(
                      hintText: needsNote ? 'Add a note (required for Other)' : 'Internal note (optional)',
                    ),
                  ),
                  const SizedBox(height: 16),
                  AdminButton('Remove from app',
                      full: true,
                      variant: AdminBtn.primary,
                      onPressed: canRemove
                          ? () => Navigator.pop(ctx, {'reason': reason, 'note': noteC.text.trim()})
                          : null),
                ]),
              ),
            ),
          ),
        );
      }),
    );
    noteC.dispose();
    if (res == null) return;
    final err = await AdminService.removeMatch(id, reason: res['reason'], note: res['note']);
    if (!mounted) return;
    if (err != null) {
      adminToast(context, err);
      return;
    }
    setState(() => m['status'] = 'cancelled');
    adminToast(context, 'Match removed');
  }

  static Color _statusColor(String? s) => switch (s) {
        'open' => AdminColors.success,
        'full' => AdminColors.warn,
        'completed' => AdminColors.info,
        'disputed' => AdminColors.danger,
        'cancelled' => AdminColors.inkFaint,
        _ => AdminColors.inkSoft,
      };

  static String _statusLabel(String? s) =>
      s == null ? 'Unknown' : s[0].toUpperCase() + s.substring(1);
}

/// Competitive-vs-casual donut. [frac] = competitive share (0..1).
class _DonutPainter extends CustomPainter {
  final double frac;
  const _DonutPainter(this.frac);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 7;
    final stroke = 12.0;
    final bg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = AdminColors.info;
    final fg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = AdminColors.primary;
    // full ring = casual (info), arc = competitive (primary)
    canvas.drawCircle(c, r, bg);
    if (frac > 0) {
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), -math.pi / 2,
          2 * math.pi * frac, false, fg);
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) => old.frac != frac;
}

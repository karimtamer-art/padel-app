import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/backend/services/tournament_service.dart';
import 'package:padel_clay/backend/services/match_service.dart';
import 'package:padel_clay/backend/models/ranking_scale.dart' show RankingScale;

/// Tournament detail — Clay Court prototype parity:
/// Overview (prize/entry, about, where & when, eligibility, partner picker)
/// + Bracket (winners / losers columns rendered from `tournament_matches`).
class TournamentDetailScreen extends StatefulWidget {
  final String tournamentId;
  const TournamentDetailScreen({super.key, required this.tournamentId});
  @override
  State<TournamentDetailScreen> createState() => _TournamentDetailScreenState();
}

class _TournamentDetailScreenState extends State<TournamentDetailScreen> {
  int _tab = 0; // 0 overview, 1 bracket
  int _bracketSide = 0; // 0 winners, 1 losers
  Map<String, dynamic>? _t;
  List<Map<String, dynamic>> _bracket = [];
  bool _loading = true;
  bool _busy = false;

  // partner picker
  Map<String, dynamic>? _partner;
  List<Map<String, dynamic>> _players = [];
  bool _playersLoading = true;
  final _search = TextEditingController();

  String? get _uid => Supabase.instance.client.auth.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      TournamentService.fetchTournament(widget.tournamentId),
      TournamentService.fetchBracket(widget.tournamentId),
      MatchService.searchPlayers(''),
    ]);
    if (!mounted) return;
    setState(() {
      _t = results[0] as Map<String, dynamic>?;
      _bracket = results[1] as List<Map<String, dynamic>>;
      _players = results[2] as List<Map<String, dynamic>>;
      _loading = false;
      _playersLoading = false;
    });
  }

  Future<void> _searchPlayers(String q) async {
    setState(() => _playersLoading = true);
    final rows = await MatchService.searchPlayers(q);
    if (!mounted) return;
    setState(() {
      _players = rows;
      _playersLoading = false;
    });
  }

  // ── Derived ──────────────────────────────────────────────────────────────

  List<Map<String, dynamic>> get _entries =>
      List<Map<String, dynamic>>.from((_t?['tournament_entries'] as List?) ?? const [])
          .where((e) => e['status'] != 'withdrawn')
          .toList();

  bool get _registered => _entries.any((e) => e['player_id'] == _uid);
  int get _cap => (_t?['capacity'] as num?)?.toInt() ?? 0;
  bool get _full => _cap > 0 && _entries.length >= _cap;
  String get _status => (_t?['status'] as String?) ?? 'upcoming';
  int get _minElo => (_t?['min_elo'] as num?)?.toInt() ?? 0;
  int get _fee => (_t?['entry_fee'] as num?)?.toInt() ?? 0;
  bool get _isDoubleElim => (_t?['format'] as String? ?? 'double_elim') == 'double_elim';
  bool get _canRegister =>
      !_registered && !_full && (_status == 'open' || _status == 'upcoming');

  void _snack(String msg, {Color? color}) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: color ?? AppColors.ink,
          content: Text(msg)));

  Future<void> _register() async {
    setState(() => _busy = true);
    final err = await TournamentService.register(
      widget.tournamentId,
      partnerId: _partner?['id'] as String?,
      partnerName: _partner?['name'] as String?,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      _snack(err, color: AppColors.danger);
    } else {
      _snack("You're in! See you at ${(_t?['venue_name'] as String?) ?? 'the club'}.");
      _load();
    }
  }

  Future<void> _withdraw() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Withdraw?', style: AppText.cardTitle().copyWith(fontSize: 17)),
        content: Text('Your spot opens for another pair. Entry fees are handled by the organisers.',
            style: AppText.body(AppColors.inkSoft).copyWith(fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Stay in')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Withdraw')),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _busy = true);
    final err = await TournamentService.withdraw(widget.tournamentId);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      _snack(err, color: AppColors.danger);
    } else {
      _snack('You have withdrawn from this tournament.');
      _load();
    }
  }

  // ── Formatting ───────────────────────────────────────────────────────────

  static const _monthsShort = ['JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC'];
  static const _months = ['January','February','March','April','May','June',
                          'July','August','September','October','November','December'];

  DateTime? get _start =>
      DateTime.tryParse(_t?['start_date'] as String? ?? '')?.toLocal();
  DateTime? get _end =>
      DateTime.tryParse(_t?['end_date'] as String? ?? '')?.toLocal();

  String get _dateRange {
    final s = _start;
    if (s == null) return 'TBD';
    final e = _end;
    if (e == null || (e.year == s.year && e.month == s.month && e.day == s.day)) {
      return '${_months[s.month - 1]} ${s.day}';
    }
    if (e.year == s.year && e.month == s.month) {
      return '${_months[s.month - 1]} ${s.day} – ${e.day}';
    }
    return '${_months[s.month - 1]} ${s.day} – ${_months[e.month - 1]} ${e.day}';
  }

  static String _egp(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return 'EGP $buf';
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: AppColors.bg,
        body: Center(child: CircularProgressIndicator(strokeWidth: 2.4, color: AppColors.primary)),
      );
    }
    if (_t == null) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: SafeArea(
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('Tournament not found', style: AppText.cardTitle()),
              const SizedBox(height: 18),
              AppButton('Back', onPressed: () => Navigator.pop(context)),
            ]),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(children: [
        _hero(),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 12, AppSpacing.screen, 0),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: AppColors.field,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.line),
            ),
            child: Row(children: [_seg('Overview', 0), _seg('Bracket', 1)]),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.primary,
            onRefresh: _load,
            child: _tab == 0 ? _overview() : _bracketView(),
          ),
        ),
        _footer(),
      ]),
    );
  }

  Widget _seg(String label, int i) => Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _tab = i),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: _tab == i ? AppColors.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(9)),
            child: Text(label,
                style: AppText.bodyStrong(_tab == i ? AppColors.primaryInk : AppColors.inkSoft)
                    .copyWith(fontSize: 13.5)),
          ),
        ),
      );

  Widget _hero() {
    final s = _start;
    final sc = _full || _status == 'completed'
        ? AppColors.inkSoft
        : _status == 'open'
            ? AppColors.success
            : AppColors.gold;
    final statusLabel = _full && _status == 'open'
        ? 'Full'
        : _status[0].toUpperCase() + _status.substring(1).replaceAll('_', ' ');
    return Container(
      padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + 6, 16, 18),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [AppColors.hero, AppColors.hero2]),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.close_rounded, size: 18, color: AppColors.heroInk),
            ),
          ),
          const Spacer(),
          AppTag(statusLabel, color: sc, solid: true),
        ]),
        const SizedBox(height: 14),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          // date badge
          Container(
            width: 58, height: 58, alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
            ),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(s == null ? '–' : '${s.day}',
                  style: AppText.stat(20, AppColors.heroInk).copyWith(height: 1)),
              Text(s == null ? '' : _monthsShort[s.month - 1],
                  style: AppText.tag(AppColors.heroFaint).copyWith(fontSize: 10, letterSpacing: 1)),
            ]),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text((_t?['name'] as String?) ?? 'Tournament',
                  style: AppText.bigTitle(AppColors.heroInk).copyWith(fontSize: 22)),
              const SizedBox(height: 3),
              Row(children: [
                const Icon(Icons.place_outlined, size: 13, color: AppColors.heroFaint),
                const SizedBox(width: 4),
                Flexible(
                  child: Text((_t?['venue_name'] as String?) ?? '—',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: AppText.body(AppColors.heroFaint).copyWith(fontSize: 13)),
                ),
              ]),
            ]),
          ),
        ]),
      ]),
    );
  }

  // ── Overview tab ─────────────────────────────────────────────────────────

  Widget _overview() {
    final prize = (_t?['prize_pool'] as num?)?.toInt() ?? 0;
    final about = (_t?['description'] as String?) ?? '';
    final bestOf = (_t?['best_of'] as num?)?.toInt() ?? 3;
    final remaining = _cap > 0 ? (_cap - _entries.length).clamp(0, _cap) : null;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 16, AppSpacing.screen, 24),
      children: [
        // prize / entry cards
        Row(children: [
          Expanded(
            child: _bigStat('PRIZE POOL', prize > 0 ? _egp(prize) : '—',
                highlight: true),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _bigStat('ENTRY / PAIR', _fee > 0 ? _egp(_fee) : 'Free'),
          ),
        ]),
        if (about.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('THE COMPETITION', style: AppText.kicker(AppColors.primary)),
          const SizedBox(height: 4),
          Text('About', style: AppText.cardTitle().copyWith(fontSize: 18)),
          const SizedBox(height: 8),
          Text(about,
              style: AppText.body(AppColors.inkSoft).copyWith(fontSize: 14, height: 1.55)),
        ],
        const SizedBox(height: 20),
        Text('Where & when', style: AppText.cardTitle().copyWith(fontSize: 18)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _infoCard(Icons.calendar_today_rounded, 'WHEN',
              _dateRange, _start != null ? '${_start!.year}' : '')),
          const SizedBox(width: 10),
          Expanded(child: _infoCard(Icons.place_outlined, 'WHERE',
              (_t?['venue_name'] as String?) ?? '—', '')),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _infoCard(Icons.groups_outlined, 'FORMAT',
              'Doubles', 'Best of $bestOf sets')),
          const SizedBox(width: 10),
          Expanded(child: _infoCard(Icons.confirmation_number_outlined, 'SPOTS',
              remaining != null ? '$remaining of $_cap' : '${_entries.length} pairs',
              remaining != null ? 'remaining' : 'registered')),
        ]),
        if (_minElo > 0) ...[
          const SizedBox(height: 22),
          Text('ELIGIBILITY', style: AppText.kicker(AppColors.primary)),
          const SizedBox(height: 4),
          Text('Who should play', style: AppText.cardTitle().copyWith(fontSize: 18)),
          const SizedBox(height: 10),
          _eligibilityCard(),
        ],
        if (_canRegister) ...[
          const SizedBox(height: 22),
          Text('IT TAKES TWO', style: AppText.kicker(AppColors.primary)),
          const SizedBox(height: 4),
          Text('Find your partner', style: AppText.cardTitle().copyWith(fontSize: 18)),
          const SizedBox(height: 10),
          _partnerPicker(),
        ],
        if (_entries.isNotEmpty) ...[
          const SizedBox(height: 22),
          Text('REGISTERED PAIRS', style: AppText.kicker()),
          const SizedBox(height: 10),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(children: [
              for (int i = 0; i < _entries.length; i++)
                _entryRow(_entries[i], divider: i > 0),
            ]),
          ),
        ],
      ],
    );
  }

  Widget _bigStat(String label, String value, {bool highlight = false}) =>
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: highlight
              ? AppColors.primary.withValues(alpha: 0.1)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: highlight
                  ? AppColors.primary.withValues(alpha: 0.3)
                  : AppColors.line),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: AppText.kicker(highlight ? AppColors.primary : AppColors.inkSoft)),
          const SizedBox(height: 5),
          Text(value,
              style: AppText.stat(22, highlight ? AppColors.primary : AppColors.ink)),
        ]),
      );

  Widget _infoCard(IconData icon, String label, String value, String sub) =>
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.line),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
                color: AppColors.field, borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 18, color: AppColors.primary),
          ),
          const SizedBox(height: 10),
          Text(label, style: AppText.kicker()),
          const SizedBox(height: 3),
          Text(value,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AppText.bodyStrong().copyWith(fontSize: 14.5)),
          if (sub.isNotEmpty)
            Text(sub, style: AppText.small().copyWith(fontSize: 11.5)),
        ]),
      );

  Widget _eligibilityCard() {
    final lv = RankingScale.levelFromElo(_minElo);
    // divisions at or above the minimum level
    final divs = RankingScale.divisions
        .where((d) => d.max >= lv)
        .map((d) => d.metalName)
        .toList();
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(11)),
            child: const Icon(Icons.shield_outlined, size: 20, color: AppColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Minimum Lv ${RankingScale.fmtLevel(lv)}',
                  style: AppText.bodyStrong().copyWith(fontSize: 15)),
              Text('Open to the divisions below',
                  style: AppText.small().copyWith(fontSize: 12)),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final d in divs) AppTag(d, color: AppColors.gold),
        ]),
      ]),
    );
  }

  // ── Partner picker ───────────────────────────────────────────────────────

  Widget _partnerPicker() => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
                color: AppColors.field,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.line)),
            child: Row(children: [
              const Icon(Icons.search_rounded, size: 18, color: AppColors.inkFaint),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _search,
                  onChanged: _searchPlayers,
                  decoration: InputDecoration(
                    hintText: 'Search players to team up with…',
                    hintStyle: AppText.body(AppColors.inkFaint).copyWith(fontSize: 13.5),
                    border: InputBorder.none,
                  ),
                  style: AppText.body().copyWith(fontSize: 13.5),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 10),
          if (_partner != null)
            _playerTile(_partner!, selected: true)
          else if (_playersLoading)
            const Center(child: Padding(
              padding: EdgeInsets.all(14),
              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
            ))
          else if (_players.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text('No players found — try another name.',
                  style: AppText.small().copyWith(fontSize: 12.5)),
            )
          else
            SizedBox(
              height: 200,
              child: ListView(children: [for (final p in _players) _playerTile(p)]),
            ),
        ]),
      );

  Widget _playerTile(Map<String, dynamic> p, {bool selected = false}) {
    final name = p['name'] as String? ?? 'Player';
    final elo = (p['elo'] as num?)?.toInt() ?? 1000;
    final lv = (p['level'] as num?)?.toDouble() ?? RankingScale.levelFromElo(elo);
    final initials = name.trim().isEmpty
        ? 'P'
        : name.trim().split(RegExp(r'\s+')).take(2).map((w) => w[0]).join().toUpperCase();
    return GestureDetector(
      onTap: () => setState(() => _partner = selected ? null : p),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withValues(alpha: 0.08) : AppColors.field,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? AppColors.primary : AppColors.line, width: 1.5),
        ),
        child: Row(children: [
          AppAvatar(initials, size: 36, ring: 1.5,
              color: selected ? AppColors.primary : AppColors.gold),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: AppText.bodyStrong().copyWith(fontSize: 13.5)),
              Text(RankingScale.levelTag(lv),
                  style: AppText.small().copyWith(fontSize: 11.5)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(RankingScale.fmtLevel(lv), style: AppText.stat(15)),
            Text('level', style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 9.5)),
          ]),
          const SizedBox(width: 8),
          Icon(selected ? Icons.close_rounded : Icons.add_circle_outline_rounded,
              size: 20, color: selected ? AppColors.inkSoft : AppColors.primary),
        ]),
      ),
    );
  }

  Widget _entryRow(Map<String, dynamic> e, {bool divider = false}) {
    final prof = e['profiles'] as Map?;
    final name = (prof?['name'] as String?) ?? 'Player';
    final partner = e['partner_name'] as String?;
    final isMe = e['player_id'] == _uid;
    final label = (partner != null && partner.isNotEmpty) ? '$name / $partner' : name;
    final initials = name.trim().split(RegExp(r'\s+')).take(2)
        .map((w) => w.isEmpty ? '' : w[0]).join().toUpperCase();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isMe ? AppColors.primary.withValues(alpha: 0.06) : null,
        border: divider ? const Border(top: BorderSide(color: AppColors.line)) : null,
      ),
      child: Row(children: [
        AppAvatar(initials.isEmpty ? 'P' : initials, size: 34, ring: 1.5,
            color: isMe ? AppColors.primary : AppColors.gold),
        const SizedBox(width: 10),
        Expanded(
          child: Text(isMe ? '$label (You)' : label,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AppText.bodyStrong().copyWith(fontSize: 13.5)),
        ),
      ]),
    );
  }

  // ── Bracket tab ──────────────────────────────────────────────────────────

  Widget _bracketView() {
    final side = _bracketSide == 0 ? 'wb' : 'lb';
    final matches = _bracket.where((m) => m['bracket'] == side).toList();
    final rounds = <int, List<Map<String, dynamic>>>{};
    for (final m in matches) {
      rounds.putIfAbsent((m['round'] as num).toInt(), () => []).add(m);
    }
    final roundKeys = rounds.keys.toList()..sort();

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 16, AppSpacing.screen, 24),
      children: [
        Row(children: [
          Text('Knockout bracket', style: AppText.cardTitle().copyWith(fontSize: 17)),
          const SizedBox(width: 8),
          AppTag(_isDoubleElim ? 'DOUBLE ELIMINATION' : 'SINGLE ELIMINATION',
              color: AppColors.accent),
        ]),
        const SizedBox(height: 12),
        if (_isDoubleElim)
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: AppColors.field,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.line),
            ),
            child: Row(children: [
              _bracketSeg('Winners', 0),
              _bracketSeg('Losers', 1),
            ]),
          ),
        const SizedBox(height: 16),
        if (_bracket.isEmpty)
          AppCard(
            child: Column(children: [
              Container(
                width: 52, height: 52,
                decoration: BoxDecoration(
                    color: AppColors.field, borderRadius: BorderRadius.circular(14)),
                child: const Icon(Icons.account_tree_outlined,
                    size: 24, color: AppColors.inkSoft),
              ),
              const SizedBox(height: 12),
              Text('No draw yet', style: AppText.cardTitle().copyWith(fontSize: 15)),
              const SizedBox(height: 6),
              Text('The bracket appears here once the organisers make the draw.',
                  textAlign: TextAlign.center,
                  style: AppText.small().copyWith(fontSize: 12.5, height: 1.5)),
            ]),
          )
        else if (matches.isEmpty)
          AppCard(
            color: AppColors.field,
            child: Text(
                _bracketSide == 1
                    ? 'No one has dropped to the losers bracket yet.'
                    : 'No matches on this side yet.',
                style: AppText.small().copyWith(fontSize: 13)),
          )
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final r in roundKeys) ...[
                  _roundColumn(side, r, rounds[r]!, roundKeys.length),
                  const SizedBox(width: 14),
                ],
              ],
            ),
          ),
        const SizedBox(height: 16),
        if (_isDoubleElim)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.info_outline_rounded, size: 16, color: AppColors.inkFaint),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  "Lose once and you drop to the Losers bracket — two losses and you're out. Every pair is guaranteed at least two matches.",
                  style: AppText.small().copyWith(fontSize: 12.5, height: 1.5)),
            ),
          ]),
      ],
    );
  }

  Widget _bracketSeg(String label, int i) => Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _bracketSide = i),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: _bracketSide == i ? AppColors.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(9)),
            child: Text(label,
                style: AppText.bodyStrong(
                        _bracketSide == i ? AppColors.primaryInk : AppColors.inkSoft)
                    .copyWith(fontSize: 13)),
          ),
        ),
      );

  String _roundName(String side, int round, int totalRounds) {
    if (side == 'lb') return 'LB Round $round';
    final fromEnd = totalRounds - round;
    if (fromEnd == 0) return totalRounds == 1 ? 'Final' : 'Final';
    if (fromEnd == 1) return 'Semifinals';
    if (fromEnd == 2) return 'Quarterfinals';
    return 'Round $round';
  }

  Widget _roundColumn(String side, int round,
      List<Map<String, dynamic>> matches, int totalRounds) {
    matches.sort((a, b) =>
        ((a['slot'] as num).toInt()).compareTo((b['slot'] as num).toInt()));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(_roundName(side, round, totalRounds).toUpperCase(),
            style: AppText.kicker()),
      ),
      for (final m in matches) _bracketMatch(m),
    ]);
  }

  Widget _bracketMatch(Map<String, dynamic> m) {
    final e1 = m['e1'] as Map<String, dynamic>?;
    final e2 = m['e2'] as Map<String, dynamic>?;
    final winner = m['winner_entry'] as String?;
    final myEntryIds = _entries
        .where((e) => e['player_id'] == _uid)
        .map((e) => e['id'])
        .toSet();
    Widget pairRow(Map<String, dynamic>? e, bool top) {
      final won = e != null && winner != null && e['id'] == winner;
      final mine = e != null && myEntryIds.contains(e['id']);
      final label = e == null
          ? 'TBD'
          : mine
              ? 'You${(e['partner_name'] != null && (e['partner_name'] as String).isNotEmpty) ? ' & ${(e['partner_name'] as String).split(' ').first}' : ' & ?'}'
              : TournamentService.pairLabel(e);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: mine ? AppColors.primary.withValues(alpha: 0.08) : null,
          border: top ? null : const Border(top: BorderSide(color: AppColors.line)),
        ),
        child: Row(children: [
          Expanded(
            child: Text(label,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppText
                    .bodyStrong(mine
                        ? AppColors.primary
                        : e == null
                            ? AppColors.inkFaint
                            : AppColors.ink)
                    .copyWith(fontSize: 13)),
          ),
          if (won)
            const Icon(Icons.check_rounded, size: 16, color: AppColors.success),
        ]),
      );
    }

    return Container(
      width: 220,
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
        boxShadow: kCardShadow,
      ),
      child: Column(children: [
        pairRow(e1, true),
        pairRow(e2, false),
        if (m['score'] != null && (m['score'] as String).isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppColors.lineSoft))),
            child: Text(m['score'] as String,
                style: AppText.tag(AppColors.inkSoft).copyWith(fontSize: 11)),
          ),
      ]),
    );
  }

  // ── Footer ───────────────────────────────────────────────────────────────

  Widget _footer() {
    final needPartner = _canRegister && _partner == null;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 26),
      decoration: const BoxDecoration(
          color: AppColors.bg,
          border: Border(top: BorderSide(color: AppColors.lineSoft))),
      child: Row(children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('ENTRY / PAIR', style: AppText.tag().copyWith(fontSize: 9.5)),
          Text(_fee > 0 ? _egp(_fee) : 'Free', style: AppText.stat(20)),
        ]),
        const SizedBox(width: 14),
        Expanded(
          child: _registered
              ? AppButton(_busy ? '…' : 'Withdraw', full: true, height: 52,
                  variant: AppBtnVariant.ghost, onPressed: _busy ? null : _withdraw)
              : AppButton(
                  _busy
                      ? 'Registering…'
                      : _full
                          ? 'Tournament Full'
                          : _status == 'completed'
                              ? 'Tournament Ended'
                              : needPartner
                                  ? 'Pick a partner first'
                                  : 'Register Pair',
                  full: true, height: 52,
                  icon: needPartner ? Icons.arrow_forward_rounded : Icons.emoji_events_rounded,
                  onPressed: (_canRegister && !needPartner && !_busy) ? _register : null),
        ),
      ]),
    );
  }
}

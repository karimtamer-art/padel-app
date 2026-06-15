import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/backend/services/tournament_service.dart';
import 'package:padel_clay/backend/services/order_service.dart';
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

  // Registered = in the pair as registrant OR partner. Only the registrant
  // can withdraw the pair; a partner is "in" but didn't create the entry.
  bool get _registered =>
      TournamentService.isParticipant(_t?['tournament_entries'] as List?, _uid);
  bool get _isRegistrant =>
      TournamentService.isRegistrant(_t?['tournament_entries'] as List?, _uid);
  int get _cap => (_t?['capacity'] as num?)?.toInt() ?? 0;
  int get _minElo => (_t?['min_elo'] as num?)?.toInt() ?? 0;
  int? get _maxElo => (_t?['max_elo'] as num?)?.toInt();
  int get _fee => (_t?['entry_fee'] as num?)?.toInt() ?? 0;
  String get _derivedStatus => TournamentService.tournamentStatus(_t ?? {}, _entries.length);
  bool get _canRegister {
    final ds = _derivedStatus;
    return !_registered && (ds == 'open' || ds == 'postponed');
  }

  void _snack(String msg, {Color? color}) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: color ?? AppColors.ink,
          content: Text(msg)));

  /// Entry point for the Register button. Free events register straight away;
  /// paid events collect an InstaPay transfer (sender + proof) first.
  Future<void> _startRegister() async {
    if (_fee <= 0) {
      await _register();
      return;
    }
    final result = await showModalBottomSheet<Map<String, String?>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _TournamentPaymentSheet(
        amount: _fee,
        tournamentName: (_t?['name'] as String?) ?? 'this tournament',
      ),
    );
    if (result == null || !mounted) return; // cancelled
    await _register(
        instapaySender: result['sender'], instapayProofUrl: result['proof']);
  }

  Future<void> _register({String? instapaySender, String? instapayProofUrl}) async {
    setState(() => _busy = true);
    final err = await TournamentService.register(
      widget.tournamentId,
      partnerId: _partner?['id'] as String?,
      partnerName: _partner?['name'] as String?,
      instapaySender: instapaySender,
      instapayProofUrl: instapayProofUrl,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      _snack(err, color: AppColors.danger);
    } else {
      _snack(_fee > 0
          ? "Spot reserved — we'll confirm once your transfer is verified."
          : "You're in! See you at ${(_t?['venue_name'] as String?) ?? 'the club'}.");
      _load();
    }
  }

  Future<void> _withdraw() async {
    final paidEntry = _fee > 0;
    final refundable = TournamentService.refundableNow(_t ?? {});
    final body = !paidEntry
        ? 'Your spot opens for another pair.'
        : refundable
            ? 'Your spot opens up, and your ${_egp(_fee)} entry fee will be '
                'refunded once an admin processes it.'
            : 'Withdrawing on the tournament day — your ${_egp(_fee)} entry fee '
                'is non-refundable.';
    final sure = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (c) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 32),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 20),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Withdraw?',
                  style: AppText.stat(24, AppColors.ink).copyWith(letterSpacing: -0.4)),
              const SizedBox(height: 10),
              Text(body,
                  style: AppText.body(AppColors.inkSoft).copyWith(fontSize: 14, height: 1.5)),
              const SizedBox(height: 22),
              AppButton('Stay in',
                  full: true, height: 52, onPressed: () => Navigator.pop(c, false)),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: TextButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: Text('Withdraw my pair',
                      style: AppText.bodyStrong(AppColors.danger)
                          .copyWith(fontSize: 14, fontWeight: FontWeight.w800)),
                ),
              ),
            ],
          ),
        ),
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
    final ds = _derivedStatus;
    final sc = switch (ds) {
      'open' || 'live' => AppColors.success,
      'full' || 'postponed' => AppColors.gold,
      _ => AppColors.inkSoft,
    };
    final statusLabel = switch (ds) {
      'open' => 'Open',
      'live' => 'Live',
      'full' => 'Full',
      'completed' => 'Completed',
      'cancelled' => 'Cancelled',
      'postponed' => 'Postponed',
      _ => ds,
    };
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
        if (_minElo > 0 || _maxElo != null) ...[
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
    final minLv = _minElo > 0 ? RankingScale.levelFromElo(_minElo) : null;
    final maxElo = _maxElo;
    final maxLv = (maxElo != null && maxElo > 0) ? RankingScale.levelFromElo(maxElo) : null;
    final isRange = minLv != null && maxLv != null;

    String subtitle;
    if (isRange) {
      subtitle = 'Lv ${RankingScale.fmtLevel(minLv)} – ${RankingScale.fmtLevel(maxLv)} only';
    } else if (minLv != null) {
      subtitle = 'Minimum Lv ${RankingScale.fmtLevel(minLv)} and above';
    } else {
      subtitle = 'Maximum Lv ${RankingScale.fmtLevel(maxLv!)}';
    }

    // which divisions are eligible
    final eligDivs = RankingScale.divisions.where((d) {
      final aboveMin = minLv == null || d.max >= minLv;
      final belowMax = maxLv == null || d.min <= maxLv;
      return aboveMin && belowMax;
    }).map((d) => d.metalName).toList();

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
              Text(subtitle, style: AppText.bodyStrong().copyWith(fontSize: 15)),
              Text('Eligible divisions shown below',
                  style: AppText.small().copyWith(fontSize: 12)),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final d in eligDivs) AppTag(d, color: AppColors.gold),
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
                    hintText: 'Search players by @username…',
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
    final username = p['username'] as String?;
    final elo = (p['elo'] as num?)?.toInt() ?? 1000;
    final lv = (p['level'] as num?)?.toDouble() ?? RankingScale.levelFromElo(elo);
    final initials = name.trim().isEmpty
        ? 'P'
        : name.trim().split(RegExp(r'\s+')).take(2).map((w) => w[0]).join().toUpperCase();
    final subtitle = (username != null && username.isNotEmpty)
        ? '@$username'
        : RankingScale.levelTag(lv);
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
              Text(subtitle,
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
    final name = (e['player_name'] as String?)?.trim().isNotEmpty == true
        ? (e['player_name'] as String)
        : 'Player';
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
          const AppTag('DOUBLE ELIMINATION', color: AppColors.accent),
        ]),
        const SizedBox(height: 12),
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
          child: _isRegistrant
              ? AppButton(_busy ? '…' : 'Withdraw', full: true, height: 52,
                  variant: AppBtnVariant.ghost, onPressed: _busy ? null : _withdraw)
              : _registered
              // Added as a partner — already in, can't register again.
              ? const AppButton("You're in this tournament",
                  full: true, height: 52, variant: AppBtnVariant.outline,
                  icon: Icons.check_circle_rounded, onPressed: null)
              : AppButton(
                  _busy
                      ? 'Registering…'
                      : switch (_derivedStatus) {
                          'full' => 'Tournament Full',
                          'completed' => 'Tournament Ended',
                          'cancelled' => 'Registration Closed',
                          'live' => 'Tournament in Progress',
                          _ => needPartner ? 'Pick a partner first' : 'Register Pair',
                        },
                  full: true, height: 52,
                  icon: needPartner ? Icons.arrow_forward_rounded : Icons.emoji_events_rounded,
                  onPressed: (_canRegister && !needPartner && !_busy) ? _startRegister : null),
        ),
      ]),
    );
  }
}

/// InstaPay payment step for a paid tournament entry. Pops with
/// `{sender, proof}` on confirm (proof = uploaded storage path or null), or
/// null if cancelled. Mirrors the store checkout's InstaPay step.
class _TournamentPaymentSheet extends StatefulWidget {
  final int amount;
  final String tournamentName;
  const _TournamentPaymentSheet(
      {required this.amount, required this.tournamentName});
  @override
  State<_TournamentPaymentSheet> createState() => _TournamentPaymentSheetState();
}

class _TournamentPaymentSheetState extends State<_TournamentPaymentSheet> {
  final _sender = TextEditingController();
  Uint8List? _proofBytes;
  String _proofExt = 'jpg';
  String _handle = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    OrderService.fetchInstapayHandle().then((h) {
      if (mounted) setState(() => _handle = h);
    });
    _sender.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _sender.dispose();
    super.dispose();
  }

  static String _egp(int n) => 'EGP $n';

  Future<void> _pickProof() async {
    final f = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (f == null) return;
    final bytes = await f.readAsBytes();
    final ext =
        f.name.contains('.') ? f.name.split('.').last.toLowerCase() : 'jpg';
    if (mounted) {
      setState(() {
        _proofBytes = bytes;
        _proofExt = ext;
      });
    }
  }

  Future<void> _submit() async {
    final sender = _sender.text.trim();
    if (sender.isEmpty) return;
    setState(() => _busy = true);
    String? proofPath;
    if (_proofBytes != null) {
      proofPath = await OrderService.uploadPaymentProof(_proofBytes!, _proofExt);
    }
    if (!mounted) return;
    Navigator.pop(context, {'sender': sender, 'proof': proofPath});
  }

  void _copy(String v) {
    Clipboard.setData(ClipboardData(text: v));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating, content: Text('Copied $v')));
  }

  @override
  Widget build(BuildContext context) {
    final ready = _sender.text.trim().isNotEmpty && !_busy;
    return Container(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      decoration: const BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                          color: AppColors.line,
                          borderRadius: BorderRadius.circular(2))),
                ),
                Text('Pay entry fee', style: AppText.stat(22, AppColors.ink)),
                const SizedBox(height: 4),
                Text(
                    'Transfer to the InstaPay account below, then enter your '
                    'sending username so we can match the payment.',
                    style: AppText.small().copyWith(fontSize: 13, height: 1.4)),
                const SizedBox(height: 18),
                _copyRow('Send to · InstaPay', _handle.isEmpty ? '…' : _handle,
                    mono: true),
                const SizedBox(height: 10),
                _copyRow('Amount', _egp(widget.amount)),
                const SizedBox(height: 18),
                Text('YOUR INSTAPAY USERNAME', style: AppText.kicker()),
                const SizedBox(height: 7),
                TextField(
                  controller: _sender,
                  style: AppText.body(),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'e.g. yourname@instapay',
                    filled: true,
                    fillColor: AppColors.field,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 13, vertical: 13),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppColors.line)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                            color: AppColors.primary, width: 1.6)),
                  ),
                ),
                const SizedBox(height: 16),
                Text('TRANSFER SCREENSHOT (OPTIONAL)', style: AppText.kicker()),
                const SizedBox(height: 7),
                _proofTile(),
                const SizedBox(height: 22),
                AppButton(_busy ? 'Submitting…' : "I've sent the transfer",
                    full: true, height: 52, onPressed: ready ? _submit : null),
                const SizedBox(height: 6),
                Center(
                  child: TextButton(
                    onPressed: _busy ? null : () => Navigator.pop(context),
                    child: Text('Cancel',
                        style: AppText.bodyStrong(AppColors.inkSoft)
                            .copyWith(fontSize: 14)),
                  ),
                ),
              ]),
        ),
      ),
    );
  }

  Widget _copyRow(String label, String value, {bool mono = false}) {
    return GestureDetector(
      onTap: value == '…' ? null : () => _copy(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
            color: AppColors.field, borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: AppText.small().copyWith(fontSize: 11)),
              const SizedBox(height: 2),
              Text(value,
                  style: mono
                      ? AppText.bodyStrong().copyWith(
                          fontFamily: 'monospace', fontSize: 14)
                      : AppText.bodyStrong().copyWith(fontSize: 15)),
            ]),
          ),
          const Icon(Icons.copy_rounded, size: 16, color: AppColors.inkSoft),
        ]),
      ),
    );
  }

  Widget _proofTile() {
    if (_proofBytes != null) {
      return Stack(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.memory(_proofBytes!,
              width: double.infinity, height: 140, fit: BoxFit.cover),
        ),
        Positioned(
          top: 6,
          right: 6,
          child: GestureDetector(
            onTap: () => setState(() => _proofBytes = null),
            child: Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                  color: AppColors.ink, shape: BoxShape.circle),
              child: const Icon(Icons.close_rounded,
                  size: 15, color: AppColors.bg),
            ),
          ),
        ),
      ]);
    }
    return GestureDetector(
      onTap: _pickProof,
      child: Container(
        height: 64,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.field,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.line),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.add_photo_alternate_outlined,
              size: 19, color: AppColors.inkSoft),
          const SizedBox(width: 8),
          Text('Attach a screenshot',
              style: AppText.bodyStrong(AppColors.inkSoft).copyWith(fontSize: 13)),
        ]),
      ),
    );
  }
}

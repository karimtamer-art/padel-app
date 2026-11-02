import 'package:padel_clay/backend/models/tournament_payment.dart';
import 'bracket_view.dart' show pairNameFor;
import 'payment_status.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/frontend/theme/tournament_tokens.dart';
import 'package:padel_clay/frontend/widgets/app_toast.dart';
import 'package:padel_clay/frontend/widgets/padel_refresh.dart';
import 'package:padel_clay/frontend/widgets/auto_refresh.dart';
import 'package:padel_clay/frontend/widgets/tournament_kit.dart';
import 'package:padel_clay/backend/services/tournament_service.dart';
import 'package:padel_clay/backend/services/region_service.dart' show money;
import 'tournament_detail_screen.dart';

class TournamentsScreen extends StatefulWidget {
  const TournamentsScreen({super.key});
  @override
  State<TournamentsScreen> createState() => _TournamentsScreenState();
}

class _TournamentsScreenState extends State<TournamentsScreen> with AutoRefresh<TournamentsScreen> {
  List<Map<String, dynamic>> _tournaments = [];
  bool _loading = true;
  int _tab = 0; // 0 open, 1 registered, 2 past
  String? _category; // null = every category

  RealtimeChannel? _payChannel;

  String? get _uid => Supabase.instance.client.auth.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _load();
    _payChannel = TournamentService.watchMyTournaments((_) => _load());
  }

  @override
  void dispose() {
    TournamentService.stopWatching(_payChannel);
    super.dispose();
  }

  @override
  Future<void> onAutoRefresh() => _load();

  Future<void> _load() async {
    final tournaments = await TournamentService.fetchTournaments();
    _sortActiveFirst(tournaments);
    if (!mounted) return;
    setState(() {
      _tournaments = tournaments;
      _loading = false;
    });
  }

  /// Active events (open/live/full/postponed) first by soonest date; finished
  /// ones (completed/cancelled) sink to the bottom, most recent first.
  static void _sortActiveFirst(List<Map<String, dynamic>> list) {
    bool done(Map<String, dynamic> t) => _isPast(t);

    list.sort((a, b) {
      final da = done(a), db = done(b);
      if (da != db) return da ? 1 : -1;
      final sa = DateTime.tryParse((a['start_date'] as String?) ?? '');
      final sb = DateTime.tryParse((b['start_date'] as String?) ?? '');
      if (sa == null || sb == null) return 0;
      // active: soonest first; finished: most recent first
      return da ? sb.compareTo(sa) : sa.compareTo(sb);
    });
  }

  // ── Filters ──────────────────────────────────────────────────────────────

  static bool _isPast(Map<String, dynamic> t) {
    final entries = ((t['tournament_entries'] as List?) ?? const [])
        .where((e) => e['status'] != 'withdrawn')
        .length;
    final ds = TournamentService.tournamentStatus(t, entries);
    return ds == 'completed' || ds == 'cancelled';
  }

  bool _isRegistered(Map<String, dynamic> t) =>
      TournamentService.isParticipant(t['tournament_entries'] as List?, _uid);

  bool _matchesCategory(Map<String, dynamic> t) =>
      _category == null || (t['category'] as String? ?? 'open') == _category;

  /// Open = everything not finished yet, so a live event stays findable.
  List<Map<String, dynamic>> _inTab(int tab) => _tournaments
      .where(_matchesCategory)
      .where((t) => switch (tab) {
            1 => _isRegistered(t),
            2 => _isPast(t),
            _ => !_isPast(t),
          })
      .toList();

  void _openFilter() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: TColors.cream,
      shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(TRadius.sheet))),
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Filter by category', style: tStyle(20, FontWeight.w800)),
              const SizedBox(height: 8),
              for (final (value, label) in const [
                (null, 'All tournaments'),
                ('open', 'Open'),
                ('mens', "Men's"),
                ('womens', "Women's"),
                ('mixed', 'Mixed'),
              ])
                InkWell(
                  onTap: () {
                    setState(() => _category = value);
                    Navigator.pop(c);
                  },
                  child: SizedBox(
                    height: 48,
                    child: Row(children: [
                      Expanded(
                        child: Text(label,
                            style: tStyle(15,
                                _category == value
                                    ? FontWeight.w700
                                    : FontWeight.w500)),
                      ),
                      if (_category == value)
                        const Icon(Icons.check_rounded,
                            size: 20, color: TColors.accent),
                    ]),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: TColors.cream,
      child: Column(
        children: [
          _header(),
          Expanded(
            child: PadelRefresh(
              onRefresh: _load,
              slivers: _tournamentSlivers(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header() => Padding(
        padding: EdgeInsets.fromLTRB(
            20, MediaQuery.of(context).padding.top + 12, 20, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('TOURNAMENTS',
                    style: tStyle(13, FontWeight.w600,
                        color: TColors.muted, letterSpacing: 1.2)),
                const SizedBox(height: 2),
                Text('Compete',
                    style: tStyle(34, FontWeight.w800, letterSpacing: -0.5)),
              ]),
            ),
            TapTarget(
              label: 'Filter tournaments',
              onTap: _openFilter,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _category == null ? TColors.surface : TColors.green,
                  borderRadius: BorderRadius.circular(TRadius.button),
                  border: Border.all(
                      color: _category == null
                          ? TColors.borderStrong
                          : TColors.green),
                ),
                child: Icon(Icons.filter_list_rounded,
                    size: 20,
                    color: _category == null ? TColors.text : TColors.white),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 8, children: [
            _pill(0, _loading ? 'Open' : 'Open · ${_inTab(0).length}'),
            _pill(1, 'Registered'),
            _pill(2, 'Past'),
          ]),
        ]),
      );

  Widget _pill(int tab, String label) {
    final on = _tab == tab;
    return TapTarget(
      label: label,
      onTap: () => setState(() => _tab = tab),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: on ? TColors.green : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          border: on ? null : Border.all(color: TColors.borderStrong),
        ),
        child: Center(
          widthFactor: 1,
          child: Text(label,
              style: tStyle(14, on ? FontWeight.w600 : FontWeight.w500,
                  color: on ? TColors.white : TColors.text2)),
        ),
      ),
    );
  }

  // ── Tournaments ──────────────────────────────────────────────────────────

  List<Widget> _tournamentSlivers() {
    if (_loading) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
              child: CircularProgressIndicator(
                  strokeWidth: 2.4, color: TColors.accent)),
        ),
      ];
    }
    final list = _inTab(_tab);
    if (list.isEmpty && _tab != 0) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _tab == 1
              ? _emptyList(Icons.emoji_events_outlined, 'Nothing here yet',
                  'Tournaments you register for will appear here.')
              : _emptyList(Icons.history_rounded, 'No past tournaments',
                  'Finished tournaments will appear here.'),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
        sliver: SliverList(
          delegate: SliverChildListDelegate([
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 40, bottom: 28),
                child: _emptyList(
                    Icons.emoji_events_outlined,
                    'No tournaments yet',
                    'Open and upcoming tournaments will appear here once they are created.'),
              ),
            for (final t in list) ...[
              _tournamentCard(t),
              const SizedBox(height: 18),
            ],
            if (_tab == 0) _comingSoonCard(),
          ]),
        ),
      ),
    ];
  }

  Widget _comingSoonCard() => CustomPaint(
        painter: _DashedBorderPainter(),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: TColors.accentSoft,
                borderRadius: BorderRadius.circular(TRadius.button),
              ),
              child: const Icon(Icons.notifications_none_rounded,
                  size: 22, color: TColors.accent),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('More tournaments coming',
                    style: tStyle(15, FontWeight.w700)),
                const SizedBox(height: 2),
                Text('Get a heads-up when registration opens.',
                    style: tStyle(13, FontWeight.w400, color: TColors.muted)),
              ]),
            ),
            const SizedBox(width: 10),
            // TODO(notifications): nothing sends a "registration is open" alert
            // yet, and notify_tournament only gates events a player is already
            // in, so there is nothing to subscribe to. Wire this up once the
            // server sends one.
            TButton(
              'Notify me',
              height: 40,
              fontSize: 14,
              radius: 12,
              horizontalPadding: 14,
              style: TButtonStyle.outlineGreen,
              onPressed: () => AppToast.show(
                  context, 'Registration alerts are coming soon.'),
            ),
          ]),
        ),
      );

  static String? _timeOf(Map<String, dynamic> t) {
    final v = (t['start_time'] as String?)?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  Widget _tournamentCard(Map<String, dynamic> t) {
    final entries = ((t['tournament_entries'] as List?) ?? const [])
        .where((e) => e['status'] != 'withdrawn')
        .toList();
    final registered = _isRegistered(t);
    final ds = TournamentService.tournamentStatus(t, entries.length);
    final cap = (t['capacity'] as num?)?.toInt() ?? 0;
    final prize = (t['prize_pool'] as num?)?.toInt() ?? 0;
    final fee = (t['entry_fee'] as num?)?.toInt() ?? 0;
    final minRating = (t['min_rating'] as num?)?.toDouble() ?? 0;
    final maxRating = (t['max_rating'] as num?)?.toDouble();
    final venue = (t['venue_name'] as String?)?.trim() ?? '';
    final canRegister = !registered && (ds == 'open' || ds == 'postponed');
    final start = DateTime.tryParse((t['start_date'] as String?) ?? '')?.toLocal();
    final time = _timeOf(t);
    final level = tournamentLevelLabel(minRating, maxRating);
    final format = tournamentFormatLabel(t);
    final bestOf = (t['best_of'] as num?)?.toInt();
    final cat = _catLabel(t['category'] as String?);

    Future<void> open() async {
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => TournamentDetailScreen(tournamentId: t['id'] as String)));
      _load();
    }

    final subtitle = [if (venue.isNotEmpty) venue, if (time != null) time];
    final payment = registered
        ? EntryPayment.forTournament(t['tournament_entries'] as List?, uid: _uid, fee: fee)
        : null;
    final pair = pairNameFor(_myEntryIn(t), _uid);

    // The Registered tab is about where you stand, so it shows the short card.
    if (_tab == 1 && payment != null) {
      return Material(
        color: TColors.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(TRadius.card),
            side: const BorderSide(color: TColors.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: open,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              color: TColors.green,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(children: [
                DateTile(start),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    PaymentChip(payment),
                    const SizedBox(height: 5),
                    Text((t['name'] as String?) ?? 'Tournament',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: tStyle(18, FontWeight.w700, color: TColors.white)),
                    if (subtitle.isNotEmpty)
                      Text(subtitle.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tStyle(13, FontWeight.w400,
                              color: TColors.onGreenMuted)),
                  ]),
                ),
              ]),
            ),
            PaymentCardFooter(payment, pair: pair),
          ]),
        ),
      );
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: TColors.surface,
        borderRadius: BorderRadius.circular(TRadius.card),
        border: Border.all(color: TColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          color: TColors.green,
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            DateTile(start),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    tournamentStatusChip(ds),
                    if (payment != null)
                      PaymentChip(payment)
                    else if (registered)
                      const InfoChip('Registered', onGreen: true),
                    if (t['sponsored'] == true)
                      Text('SPONSORED',
                          style: tStyle(11, FontWeight.w600,
                              color: TColors.sponsored, letterSpacing: 1)),
                  ],
                ),
                const SizedBox(height: 4),
                Text((t['name'] as String?) ?? 'Tournament',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tStyle(20, FontWeight.w700, color: TColors.white)),
                if (subtitle.isNotEmpty)
                  Text(subtitle.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tStyle(13, FontWeight.w400,
                          color: TColors.onGreenMuted)),
              ]),
            ),
          ]),
        ),
        if (payment != null)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: open,
            child: PaymentCardFooter(payment, pair: pair),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 6, runSpacing: 6, children: [
              if (level != null) InfoChip(level),
              const InfoChip('Doubles'),
              if (cat != null) InfoChip(cat),
              InfoChip(format),
              if (bestOf != null) InfoChip('Best of $bestOf'),
            ]),
            const SizedBox(height: 14),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (prize > 0) ...[
                Expanded(
                  child: _stat(
                      'Prize pool',
                      Text(money(prize),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tStyle(22, FontWeight.w800,
                              color: TColors.accent))),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: _stat(
                  'Entry',
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(
                          text: fee > 0 ? money(fee) : 'Free',
                          style: tStyle(22, FontWeight.w800)),
                      if (fee > 0)
                        TextSpan(
                            text: ' /player',
                            style: tStyle(13, FontWeight.w500,
                                color: TColors.muted)),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ]),
            if (cap > 0) ...[
              const SizedBox(height: 14),
              SpotsProgress(filled: entries.length, capacity: cap),
            ],
            const SizedBox(height: 14),
            TButton(
              canRegister ? 'View & register' : 'View tournament',
              full: true,
              fontSize: 16,
              trailingIcon: Icons.arrow_forward_rounded,
              onPressed: open,
            ),
          ]),
        ),
      ]),
    );
  }

  Map<String, dynamic>? _myEntryIn(Map<String, dynamic> t) {
    for (final e in (t['tournament_entries'] as List?) ?? const []) {
      final m = Map<String, dynamic>.from(e as Map);
      if (m['status'] != 'withdrawn' &&
          (m['player_id'] == _uid || m['partner_id'] == _uid)) {
        return m;
      }
    }
    return null;
  }

  Widget _stat(String label, Widget value) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: tStyle(12, FontWeight.w600, color: TColors.muted)),
        const SizedBox(height: 2),
        value,
      ]);

  // Short tag for a gender category, or null for 'open'/unset (no tag).
  static String? _catLabel(String? c) => switch (c) {
        'mens' => "Men's",
        'womens' => "Women's",
        'mixed' => 'Mixed',
        _ => null,
      };

  // Non-scrolling empty body — fills the SliverFillRemaining so pull-to-refresh
  // stays on the outer scroll view.
  Widget _emptyList(IconData icon, String title, String sub) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 56,
            height: 56,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
                color: TColors.sunken, shape: BoxShape.circle),
            child: Icon(icon, size: 28, color: TColors.muted),
          ),
          const SizedBox(height: 14),
          Text(title, style: tStyle(17, FontWeight.w800)),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(sub,
                textAlign: TextAlign.center,
                style: tStyle(14, FontWeight.w400,
                    color: TColors.muted, height: 1.5)),
          ),
        ]),
      );
}

class _DashedBorderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
          Offset.zero & size, const Radius.circular(20)));
    final paint = Paint()
      ..color = TColors.borderDashed
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    for (final metric in path.computeMetrics()) {
      for (double d = 0; d < metric.length; d += 9) {
        canvas.drawPath(metric.extractPath(d, d + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

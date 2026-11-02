import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/theme/tournament_tokens.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/tournament_kit.dart';
import 'package:padel_clay/frontend/widgets/app_toast.dart';
import 'package:padel_clay/frontend/widgets/copy_icon.dart';
import 'package:padel_clay/frontend/widgets/instapay_field.dart';
import 'package:padel_clay/backend/services/tournament_service.dart';
import 'package:padel_clay/backend/services/region_service.dart' show money;
import 'package:padel_clay/backend/services/order_service.dart';
import 'package:padel_clay/backend/models/ranking_scale.dart' show RankingScale;
import 'package:padel_clay/backend/models/tournament_bracket.dart';
import 'bracket_view.dart';
import 'match_result_sheet.dart';
import 'partner_sheet.dart';

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
  final _selection = BracketSelection();
  Map<String, dynamic>? _t;
  Map<String, dynamic>? _formatSpec;
  Map<String, dynamic> _extras = const {};
  List<Map<String, dynamic>>? _standings;
  List<Map<String, dynamic>> _bracket = [];
  bool _loading = true;
  bool _busy = false;

  Map<String, dynamic>? _partner;
  String? _myGender; // for client-side gender-category pre-check

  String? get _uid => Supabase.instance.client.auth.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      TournamentService.fetchTournament(widget.tournamentId),
      TournamentService.fetchBracket(widget.tournamentId),
      TournamentService.fetchFormatSpec(widget.tournamentId),
      TournamentService.fetchTournamentExtras(widget.tournamentId),
      TournamentService.fetchMatchCourts(widget.tournamentId),
      TournamentService.fetchStandings(widget.tournamentId),
    ]);
    final myGender = await _fetchMyGender();
    if (!mounted) return;
    setState(() {
      _t = results[0] as Map<String, dynamic>?;
      final courts = results[4] as Map<String, String>;
      _bracket = [
        for (final m in results[1] as List<Map<String, dynamic>>)
          {...m, 'court': courts[m['id']]},
      ];
      _formatSpec = results[2] as Map<String, dynamic>?;
      _extras = results[3] as Map<String, dynamic>;
      _standings = results[5] as List<Map<String, dynamic>>?;
      _myGender = myGender;
      _loading = false;
    });
  }

  Future<String?> _fetchMyGender() async {
    final uid = _uid;
    if (uid == null) return null;
    try {
      final r = await Supabase.instance.client
          .from('profiles')
          .select('gender')
          .eq('id', uid)
          .maybeSingle();
      return r?['gender'] as String?;
    } catch (_) {
      return null;
    }
  }

  String get _category => (_t?['category'] as String?) ?? 'open';

  /// A friendly reason the current pairing can't enter this category, or null if
  /// it's fine (also null when data is unknown — the server does the final check).
  String? _categoryBlock() {
    final cat = _category;
    if (cat == 'open' || _myGender == null) return null;
    final pg = _partner?['gender'] as String?;
    switch (cat) {
      case 'mens':
        if (_myGender != 'male' || (pg != null && pg != 'male')) {
          return "This is a men's-only event — both players must be men.";
        }
        break;
      case 'womens':
        if (_myGender != 'female' || (pg != null && pg != 'female')) {
          return "This is a women's-only event — both players must be women.";
        }
        break;
      case 'mixed':
        if (_myGender == 'male' && pg == 'male') {
          return "Mixed event — a team can't be two men.";
        }
        break;
    }
    return null;
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
  double get _minRating => (_t?['min_rating'] as num?)?.toDouble() ?? 0;
  double? get _maxRating => (_t?['max_rating'] as num?)?.toDouble();
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
    final block = _categoryBlock();
    if (block != null) {
      _snack(block, color: AppColors.danger);
      return;
    }
    if (_fee <= 0) {
      await _register();
      return;
    }
    final result = await showModalBottomSheet<Map<String, String?>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _TournamentPaymentSheet(
        feePerPlayer: _fee,
        allowSplit: _partner != null,
        tournamentId: widget.tournamentId,
        tournamentName: (_t?['name'] as String?) ?? 'this tournament',
        partnerName: _partner?['name'] as String?,
      ),
    );
    if (result == null || !mounted) return; // cancelled
    await _register(
        instapaySender: result['sender'],
        instapayProofUrl: result['proof'],
        feeMode: result['feeMode'] ?? 'both');
  }

  Future<void> _register(
      {String? instapaySender,
      String? instapayProofUrl,
      String feeMode = 'both'}) async {
    setState(() => _busy = true);
    final err = await TournamentService.register(
      widget.tournamentId,
      partnerId: _partner?['id'] as String?,
      partnerName: _partner?['name'] as String?,
      instapaySender: instapaySender,
      instapayProofUrl: instapayProofUrl,
      feeMode: feeMode,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      _snack(err, color: AppColors.danger);
    } else {
      _snack(_fee > 0
          ? (feeMode == 'split'
              ? "Your share is in — we've asked your partner to pay theirs."
              : "Spot reserved — we'll confirm once your transfer is verified.")
          : "You're in! See you at ${(_t?['venue_name'] as String?) ?? 'the club'}.");
      _load();
    }
  }

  // The current user is a partner on a split entry whose own half is unpaid.
  Map<String, dynamic>? get _myUnpaidPartnerShare {
    final uid = _uid;
    if (uid == null) return null;
    for (final e in _entries) {
      final sender = e['partner_instapay_sender'] as String?;
      if (e['partner_id'] == uid &&
          e['fee_mode'] == 'split' &&
          e['partner_paid'] != true &&
          (sender == null || sender.isEmpty)) {
        return e;
      }
    }
    return null;
  }

  Future<void> _startPartnerShare(Map<String, dynamic> entry) async {
    if (_fee <= 0) return;
    final result = await showModalBottomSheet<Map<String, String?>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _TournamentPaymentSheet(
        feePerPlayer: _fee,
        allowSplit: false,
        partnerShare: true,
        tournamentId: widget.tournamentId,
        tournamentName: (_t?['name'] as String?) ?? 'this tournament',
        partnerName: null,
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _busy = true);
    final err = await TournamentService.payPartnerShare(
      entry['id'] as String,
      instapaySender: result['sender'],
      instapayProofUrl: result['proof'],
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      _snack(err, color: AppColors.danger);
    } else {
      _snack("Your share is in — the organizer will confirm your spot.");
      _load();
    }
  }

  Future<void> _withdraw() async {
    final paidEntry = _fee > 0;
    final refundable = TournamentService.refundableNow(_t ?? {});
    final body = !paidEntry
        ? 'Your spot opens for another pair.'
        : refundable
            ? 'Your spot opens up, and your ${money(_fee)} entry fee will be '
                'refunded once an admin processes it.'
            : 'Withdrawing on the tournament day — your ${money(_fee)} entry fee '
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
      _snack(paidEntry && refundable
          ? 'Withdrawn — your ${money(_fee)} refund will be processed by an admin.'
          : 'You have withdrawn from this tournament.');
      _load();
    }
  }

  // ── Formatting ───────────────────────────────────────────────────────────

  static const _weekdays = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
  static const _monthsShort = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  static const _months = ['January','February','March','April','May','June',
                          'July','August','September','October','November','December'];

  DateTime? get _start =>
      DateTime.tryParse(_t?['start_date'] as String? ?? '')?.toLocal();
  DateTime? get _end =>
      DateTime.tryParse(_t?['end_date'] as String? ?? '')?.toLocal();

  /// "Fri, Nov 6".
  String get _factDate {
    final d = _start;
    if (d == null) return 'TBD';
    return '${_weekdays[d.weekday - 1]}, ${_monthsShort[d.month - 1]} ${d.day}';
  }

  /// "5:00 PM", and how long it runs when that's more than a day.
  String get _factTime {
    final s = _start, e = _end;
    final days = s == null || e == null ? 1 : e.difference(s).inDays + 1;
    return [
      if (_startTime != null) _startTime!,
      if (days > 1) '$days days',
    ].join(' · ');
  }

  String get _venue => ((_t?['venue_name'] as String?) ?? '').trim();

  String get _venueAddress =>
      ((_extras['venue_address'] as String?) ?? '').trim();

  /// "Fri, Nov 6 at 5:00 PM" while the draw is still ahead. Null otherwise: a
  /// time that has passed with no draw published shouldn't be repeated.
  String? get _drawAtLabel {
    final d = DateTime.tryParse((_extras['draw_at'] as String?) ?? '')?.toLocal();
    if (d == null || d.isBefore(DateTime.now())) return null;
    final hour = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final minute = d.minute.toString().padLeft(2, '0');
    return '${_weekdays[d.weekday - 1]}, ${_monthsShort[d.month - 1]} ${d.day} '
        'at $hour:$minute ${d.hour < 12 ? 'AM' : 'PM'}';
  }

  String? get _categoryLabel => switch (_category) {
        'mens' => "Men's",
        'womens' => "Women's",
        'mixed' => 'Mixed',
        _ => null,
      };

  /// Eligibility, in plain lines. Empty when anyone can enter.
  List<String> get _whoCanPlay {
    final minLv = _minRating > 0 ? _minRating : null;
    final maxR = _maxRating;
    final maxLv = (maxR != null && maxR > 0) ? maxR : null;
    return [
      switch (_category) {
        'mens' => 'Both players in a pair must be men.',
        'womens' => 'Both players in a pair must be women.',
        'mixed' => "A team can't be two men: pair with a woman.",
        _ => '',
      },
      if (minLv != null && maxLv != null)
        'Levels ${RankingScale.fmtLevel(minLv)} to ${RankingScale.fmtLevel(maxLv)} only.'
      else if (minLv != null)
        'Level ${RankingScale.fmtLevel(minLv)} and above.'
      else if (maxLv != null)
        'Up to level ${RankingScale.fmtLevel(maxLv)}.',
    ].where((l) => l.isNotEmpty).toList();
  }

  bool get _doubleElim =>
      (_t?['format'] as String?) == 'double_elim' ||
      _bracket.any((m) => m['bracket'] == 'lb');

  String? get _startTime {
    final t = (_t?['start_time'] as String?)?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  /// "Jun 15" for the registration-opens date, or null when not set.
  String? get _regOpensLabel {
    final d = DateTime.tryParse(_t?['registration_opens'] as String? ?? '')?.toLocal();
    return d == null ? null : '${_months[d.month - 1]} ${d.day}';
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: TColors.cream,
        body: Center(child: CircularProgressIndicator(strokeWidth: 2.4, color: TColors.accent)),
      );
    }
    if (_t == null) {
      return Scaffold(
        backgroundColor: TColors.cream,
        body: SafeArea(
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('Tournament not found', style: tStyle(20, FontWeight.w800)),
              const SizedBox(height: 18),
              TButton('Back', onPressed: () => Navigator.pop(context)),
            ]),
          ),
        ),
      );
    }
    final bar = _actionBar();
    return Scaffold(
      backgroundColor: TColors.cream,
      body: Column(children: [
        Expanded(child: _tab == 0 ? _overview() : _bracketTab()),
        if (bar != null) bar,
      ]),
    );
  }

  void _setTab(int i) => setState(() => _tab = i);

  Widget _tabs() => HeaderSegmentedTabs(
        labels: const ['Overview', 'Bracket'],
        index: _tab,
        onChanged: _setTab,
      );

  // ── Overview header ──────────────────────────────────────────────────────

  Widget _fullHeader() {
    final level = tournamentLevelLabel(_minRating, _maxRating);
    return Container(
      padding: EdgeInsets.fromLTRB(
          20, MediaQuery.of(context).padding.top + 8, 20, 22),
      decoration: const BoxDecoration(
        color: TColors.green,
        borderRadius:
            BorderRadius.vertical(bottom: Radius.circular(TRadius.sheet)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          HeaderIconButton(
            icon: Icons.chevron_left_rounded,
            label: 'Back to tournaments',
            onTap: () => Navigator.pop(context),
          ),
          HeaderIconButton(
            icon: Icons.ios_share_rounded,
            label: 'Share tournament',
            onTap: () => _shareOnWhatsApp(invite: false),
          ),
        ]),
        const SizedBox(height: 18),
        Wrap(spacing: 6, runSpacing: 6, children: [
          tournamentStatusChip(_derivedStatus),
          if (level != null) InfoChip(level, onGreen: true),
          const InfoChip('Doubles', onGreen: true),
          if (_categoryLabel != null) InfoChip(_categoryLabel!, onGreen: true),
        ]),
        const SizedBox(height: 8),
        Text((_t?['name'] as String?) ?? 'Tournament',
            style: tStyle(32, FontWeight.w800,
                color: TColors.white, letterSpacing: -0.5, height: 1.05)),
        if (_venue.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.place_outlined,
                size: 16, color: TColors.onGreenMuted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(_venue,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tStyle(15, FontWeight.w400,
                      color: TColors.onGreenMuted)),
            ),
          ]),
        ],
        const SizedBox(height: 18),
        _factStrip(),
        const SizedBox(height: 18),
        _tabs(),
      ]),
    );
  }

  Widget _factStrip() {
    final bestOf = (_t?['best_of'] as num?)?.toInt() ?? 3;
    final remaining = _cap > 0 ? (_cap - _entries.length).clamp(0, _cap) : null;
    final line = BorderSide(color: TColors.white.withValues(alpha: 0.14));
    Widget fact(String label, String value, String sub, {bool first = false}) =>
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: first
                ? null
                : BoxDecoration(border: Border(left: line)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style: tStyle(11, FontWeight.w600,
                      color: TColors.onGreenMuted, letterSpacing: 1)),
              const SizedBox(height: 2),
              // Shrinks rather than cuts off: "Groups + KO" only just misses
              // fitting a third of a 360px phone at the design's 16px.
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value,
                    maxLines: 1,
                    style: tStyle(16, FontWeight.w700, color: TColors.white)),
              ),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(sub,
                    maxLines: 1,
                    style: tStyle(13, FontWeight.w400,
                        color: TColors.onGreenMuted)),
              ),
            ]),
          ),
        );
    return Container(
      decoration: BoxDecoration(
        color: TColors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(TRadius.matchCard),
        border: Border.all(color: TColors.white.withValues(alpha: 0.14)),
      ),
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          fact('DATE', _factDate, _factTime, first: true),
          fact('FORMAT', tournamentFormatLabel(_t), 'Best of $bestOf'),
          fact(
            'SPOTS',
            remaining != null ? '$remaining left' : '${_entries.length}',
            remaining != null ? 'of $_cap' : 'pairs',
          ),
        ]),
      ),
    );
  }

  // ── Overview ─────────────────────────────────────────────────────────────

  Widget _overview() {
    final about = ((_t?['description'] as String?) ?? '').trim();
    final prize = (_t?['prize_pool'] as num?)?.toInt() ?? 0;
    final sections = <Widget>[
      if (_myUnpaidPartnerShare != null) _partnerShareCard(_myUnpaidPartnerShare!),
      if (prize > 0 || _cap > 0) _prizeCard(prize),
      if (_canRegister) _yourTeam(),
      if (about.isNotEmpty)
        _section('About', _card(Text(about,
            style: tStyle(14, FontWeight.w400,
                color: TColors.text2, height: 1.5)))),
      if (_whoCanPlay case final rules when rules.isNotEmpty)
        _section('Who can play', _card(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < rules.length; i++) ...[
              if (i > 0) const SizedBox(height: 6),
              Text(rules[i],
                  style: tStyle(14, FontWeight.w500, color: TColors.text2)),
            ],
          ],
        ))),
      if (_venue.isNotEmpty) _venueCard(),
      _howItWorks(prize),
    ];
    return RefreshIndicator(
      color: TColors.accent,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        children: [
          _fullHeader(),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (var i = 0; i < sections.length; i++) ...[
                if (i > 0) const SizedBox(height: 22),
                sections[i],
              ],
            ]),
          ),
        ],
      ),
    );
  }

  Widget _card(Widget child, {EdgeInsets padding = const EdgeInsets.all(18)}) =>
      Container(
        clipBehavior: Clip.antiAlias,
        padding: padding,
        decoration: BoxDecoration(
          color: TColors.surface,
          borderRadius: BorderRadius.circular(TRadius.card),
          border: Border.all(color: TColors.border),
        ),
        child: child,
      );

  Widget _section(String title, Widget child) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TournamentSectionHeader(title, size: 20),
        const SizedBox(height: 12),
        child,
      ]);

  Widget _prizeCard(int prize) => _card(
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (prize > 0)
            Row(children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: TColors.accentSoft,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.emoji_events_outlined,
                    size: 26, color: TColors.accent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Prize pool',
                      style:
                          tStyle(13, FontWeight.w600, color: TColors.muted)),
                  Text(money(prize),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tStyle(32, FontWeight.w800,
                          color: TColors.accent,
                          letterSpacing: -0.5,
                          height: 1.05)),
                ]),
              ),
            ]),
          if (prize > 0 && _cap > 0) const SizedBox(height: 16),
          if (_cap > 0)
            SpotsProgress(filled: _entries.length, capacity: _cap, large: true),
        ]),
      );

  // Shown to a partner whose own half of a split entry is still unpaid. The
  // button is the bottom bar's: one terracotta action per screen.
  Widget _partnerShareCard(Map<String, dynamic> entry) {
    final registrant = (entry['player_name'] as String?)?.split(' ').first ?? 'Your partner';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TColors.accentTint,
        borderRadius: BorderRadius.circular(TRadius.matchCard),
        border: Border.all(color: TColors.accentTintBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$registrant registered you as their partner',
            style: tStyle(15, FontWeight.w700, color: TColors.accentDeep)),
        const SizedBox(height: 4),
        Text('Pay your ${money(_fee)} share to lock in your spot together.',
            style: tStyle(13, FontWeight.w400,
                color: TColors.accentDeep, height: 1.4)),
      ]),
    );
  }

  // ── Your team ────────────────────────────────────────────────────────────

  Future<void> _choosePartner() async {
    final picked = await showPartnerSheet(
      context,
      feePerPlayer: _fee,
      onShareInvite: () => _shareOnWhatsApp(invite: true),
    );
    if (picked != null && mounted) setState(() => _partner = picked);
  }

  Widget _yourTeam() {
    final partnerName = (_partner?['name'] as String?)?.trim();
    Widget slot(Widget circle, String label, {Color? color}) => SizedBox(
          width: 110,
          child: Column(children: [
            circle,
            const SizedBox(height: 6),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tStyle(13,
                    color != null ? FontWeight.w700 : FontWeight.w600,
                    color: color ?? TColors.text)),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const TournamentSectionHeader('Your team', eyebrow: 'IT TAKES TWO'),
      const SizedBox(height: 12),
      _card(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          slot(
            Container(
              width: 64,
              height: 64,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                  color: TColors.green, shape: BoxShape.circle),
              child: Text('You',
                  style: tStyle(22, FontWeight.w700, color: TColors.white)),
            ),
            'Player 1',
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Text('+',
                style: tStyle(20, FontWeight.w800, color: TColors.faint)),
          ),
          TapTarget(
            label: _partner == null ? 'Add partner' : 'Change partner',
            onTap: _choosePartner,
            child: _partner == null
                ? slot(
                    CustomPaint(
                      painter: const _DashedCirclePainter(),
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: const BoxDecoration(
                            color: TColors.accentTint, shape: BoxShape.circle),
                        child: const Icon(Icons.add_rounded,
                            size: 26, color: TColors.accent),
                      ),
                    ),
                    'Add partner',
                    color: TColors.accent,
                  )
                : slot(
                    Container(
                      width: 64,
                      height: 64,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                          color: TColors.avatar, shape: BoxShape.circle),
                      child: Text(initialsOf(partnerName),
                          style: tStyle(22, FontWeight.w700,
                              color: TColors.text2)),
                    ),
                    partnerName == null || partnerName.isEmpty
                        ? 'Partner'
                        : partnerName,
                  ),
          ),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: TButton(
              _partner == null ? 'Invite a friend' : 'Change partner',
              full: true,
              height: 46,
              fontSize: 14,
              horizontalPadding: 8,
              style: TButtonStyle.outlineGreen,
              onPressed: _choosePartner,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TButton(
              _partner == null ? 'Find a partner' : 'Remove',
              full: true,
              height: 46,
              fontSize: 14,
              horizontalPadding: 8,
              style: TButtonStyle.sunken,
              onPressed: _partner == null
                  ? _choosePartner
                  : () => setState(() => _partner = null),
            ),
          ),
        ]),
      ])),
    ]);
  }

  // ── Venue + how it works ─────────────────────────────────────────────────

  // Tournaments carry a free-text venue_name (no coords) — open the maps app to
  // a search on that name.
  Future<void> _openVenueDirections() async {
    final name = (_t?['venue_name'] as String?)?.trim();
    if (name == null || name.isEmpty) return;
    final v = _venueAddress.isEmpty ? name : '$name, $_venueAddress';
    try {
      await launchUrl(
          Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${Uri.encodeComponent(v)}'),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) AppToast.show(context, "Couldn't open Maps", kind: ToastKind.error);
    }
  }

  Widget _venueCard() => _section(
        'Venue',
        _card(
          padding: EdgeInsets.zero,
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(
              height: 110,
              child: CustomPaint(
                painter: const _MapPlaceholderPainter(),
                child: Center(
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: TColors.accent,
                      shape: BoxShape.circle,
                      border: Border.all(color: TColors.white, width: 3),
                    ),
                    child: const Icon(Icons.place_outlined,
                        size: 18, color: TColors.white),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_venue,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: tStyle(16, FontWeight.w700)),
                    if (_venueAddress.isNotEmpty)
                      Text(_venueAddress,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: tStyle(13, FontWeight.w400,
                              color: TColors.muted)),
                  ]),
                ),
                const SizedBox(width: 12),
                TButton(
                  'Directions',
                  height: 44,
                  fontSize: 14,
                  radius: 12,
                  horizontalPadding: 14,
                  style: TButtonStyle.green,
                  trailingIcon: Icons.north_east_rounded,
                  onPressed: _openVenueDirections,
                ),
              ]),
            ),
          ]),
        ),
      );

  Widget _howItWorks(int prize) {
    final bestOf = (_t?['best_of'] as num?)?.toInt() ?? 3;
    final sets = 'best of $bestOf sets';
    final finish = prize > 0
        ? 'Winners take the ${money(prize)} prize pool'
        : 'Winners take the title';
    final steps = <(String, String)>[
      ...switch (_t?['format'] as String?) {
        'knockout' => [
            ('Knockout', "Lose once and you're out · $sets"),
          ],
        'double_elim' => [
            ('Winners bracket', 'Every pair starts here · $sets'),
            ('Losers bracket', "Lose once and you play on. Lose again and you're out"),
          ],
        'round_robin' => [
            ('Round robin', 'Every pair plays every other pair · $sets'),
          ],
        'group_knockout' => [
            ('Group stage', 'Every team plays its group · $sets'),
            ('Knockout', 'Top teams advance to the KO bracket'),
          ],
        _ => [
            ('The draw', 'The organiser sets the matches · $sets'),
          ],
      },
      ('Final', finish),
    ];
    return _section(
      'How it works',
      _card(
        padding: EdgeInsets.zero,
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < steps.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: i == 0
                  ? null
                  : const BoxDecoration(
                      border:
                          Border(top: BorderSide(color: TColors.divider))),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i == steps.length - 1
                        ? TColors.accent
                        : TColors.green,
                  ),
                  child: Text('${i + 1}',
                      style:
                          tStyle(13, FontWeight.w700, color: TColors.white)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(steps[i].$1, style: tStyle(15, FontWeight.w700)),
                    Text(steps[i].$2,
                        style: tStyle(13, FontWeight.w400,
                            color: TColors.muted)),
                  ]),
                ),
              ]),
            ),
        ]),
      ),
    );
  }

  // ── Bracket tab ──────────────────────────────────────────────────────────

  Widget _bracketTab() => Column(children: [
        _compactHeader(),
        Expanded(
          child: BracketView(
            rows: _bracket,
            entries: _entries,
            uid: _uid,
            doubleElim: _doubleElim,
            formatSpec: _formatSpec,
            standings: _standings,
            finished: _derivedStatus == 'completed',
            drawAtLabel: _drawAtLabel,
            selection: _selection,
            onSelectionChanged: () => setState(() {}),
            onRefresh: _load,
            onOpenResult: _openResult,
          ),
        ),
      ]);

  Widget _compactHeader() {
    final ds = _derivedStatus;
    final drawSoon =
        _bracket.isEmpty && ds != 'completed' && ds != 'cancelled';
    return Container(
      color: TColors.green,
      padding: EdgeInsets.fromLTRB(
          20, MediaQuery.of(context).padding.top + 8, 20, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          HeaderIconButton(
            icon: Icons.chevron_left_rounded,
            label: 'Back',
            onTap: () => Navigator.pop(context),
          ),
          HeaderIconButton(
            icon: Icons.more_horiz_rounded,
            label: 'More options',
            onTap: _openManage,
          ),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          DateTile(_start, compact: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text((_t?['name'] as String?) ?? 'Tournament',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tStyle(22, FontWeight.w800,
                      color: TColors.white, height: 1.1)),
              if (_venue.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(_venue,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tStyle(13, FontWeight.w400,
                        color: TColors.onGreenMuted)),
              ],
            ]),
          ),
          const SizedBox(width: 8),
          drawSoon
              ? const StatusChip(ChipKind.drawSoon)
              : tournamentStatusChip(ds),
        ]),
        const SizedBox(height: 14),
        _tabs(),
      ]),
    );
  }

  void _openResult(Map<String, dynamic> row) {
    showTournamentMatchResult(context, match: row, uid: _uid, onChanged: _load);
  }

  // ── Manage ───────────────────────────────────────────────────────────────

  void _openManage() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: TColors.cream,
      shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(TRadius.sheet))),
      builder: (c) {
        Widget item(IconData icon, String label, VoidCallback onTap,
                {Color color = TColors.text}) =>
            InkWell(
              onTap: () {
                Navigator.pop(c);
                onTap();
              },
              child: SizedBox(
                height: 52,
                child: Row(children: [
                  Icon(icon, size: 20, color: color),
                  const SizedBox(width: 12),
                  Text(label, style: tStyle(15, FontWeight.w600, color: color)),
                ]),
              ),
            );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text((_t?['name'] as String?) ?? 'Tournament',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tStyle(20, FontWeight.w800)),
                const SizedBox(height: 8),
                item(Icons.ios_share_rounded, 'Share tournament',
                    () => _shareOnWhatsApp(invite: false)),
                // Only the registrant can withdraw the pair (server rule too).
                if (_isRegistrant && !_busy)
                  item(Icons.logout_rounded, 'Withdraw my pair', _withdraw,
                      color: TColors.accentPressed),
              ],
            ),
          ),
        );
      },
    );
  }

  /// No per-tournament deep link exists yet, so this points at the registration
  /// page. wa.me rather than share_plus: no new dependency for one screen.
  Future<void> _shareOnWhatsApp({required bool invite}) async {
    final name = (_t?['name'] as String?) ?? 'this tournament';
    final where = _venue.isEmpty ? '' : ' at $_venue';
    final text = invite
        ? 'Be my partner for $name on $_factDate$where? '
            'Sign up here: https://padel-rivals.com/register'
        : 'Check out $name on $_factDate$where: '
            'https://padel-rivals.com/register';
    try {
      await launchUrl(
        Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}'),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      if (mounted) {
        AppToast.show(context, "Couldn't open WhatsApp", kind: ToastKind.error);
      }
    }
  }

  // ── Bottom bar ───────────────────────────────────────────────────────────

  /// The state machine from the design. Null hides the bar: a dead-end disabled
  /// button is what it replaces.
  Widget? _actionBar() {
    final share = _myUnpaidPartnerShare;
    if (share != null) {
      return StickyActionBar(
        expandButton: true,
        left: BarLabel(value: money(_fee), sub: 'your share', valueSize: 22),
        button: TButton(
          _busy ? '…' : 'Pay my share',
          full: true,
          height: 54,
          fontSize: 16,
          radius: 16,
          onPressed: _busy ? null : () => _startPartnerShare(share),
        ),
      );
    }

    if (_registered && _bracket.isNotEmpty) return _nextMatchBar();
    if (_registered) return _youreInBar();

    if (_canRegister) {
      final needPartner = _partner == null;
      return StickyActionBar(
        expandButton: true,
        left: BarLabel(
          value: _fee > 0 ? money(_fee) : 'Free',
          sub: _fee > 0 ? 'per player' : 'entry',
          valueSize: 22,
        ),
        button: TButton(
          _busy
              ? 'Registering…'
              : needPartner
                  ? 'Choose partner'
                  : _fee > 0
                      ? 'Register & pay'
                      : 'Register',
          full: true,
          height: 54,
          fontSize: 16,
          radius: 16,
          icon: needPartner ? Icons.person_add_alt_rounded : null,
          onPressed: _busy
              ? null
              : needPartner
                  ? _choosePartner
                  : _startRegister,
        ),
      );
    }

    // Not in it, can't get in: say why on the Overview, stay out of the way on
    // the bracket. No waitlist exists to offer instead.
    if (_tab == 1) return null;
    final reason = switch (_derivedStatus) {
      'full' => 'Tournament full',
      'closed' => 'Registration closed',
      'upcoming' => _regOpensLabel != null
          ? 'Registration opens $_regOpensLabel'
          : 'Registration not open yet',
      'live' => 'Tournament in progress',
      'completed' => 'Tournament ended',
      'cancelled' => 'Tournament cancelled',
      _ => null,
    };
    return reason == null ? null : StickyActionBar(left: BarLabel(value: reason));
  }

  Map<String, dynamic>? get _myEntry {
    for (final e in _entries) {
      if (entryHasPlayer(e, _uid)) return e;
    }
    return null;
  }

  Widget _youreInBar() {
    final e = _myEntry;
    final status = e?['status'] as String?;
    final paidNote = switch (status) {
      'paid' || 'confirmed' => 'paid',
      'pending' => 'payment being verified',
      _ => 'registered',
    };
    return StickyActionBar(
      leading: Container(
        width: 40,
        height: 40,
        decoration: const BoxDecoration(
            color: TColors.statusGreenBg, shape: BoxShape.circle),
        child: const Icon(Icons.check_rounded,
            size: 20, color: TColors.statusGreenText),
      ),
      left: BarLabel(
        value: "You're in · ${pairNameFor(e, _uid)}",
        sub: _fee > 0 ? '${money(_fee)} per player · $paidNote' : 'Free entry',
      ),
      button: TButton(
        'Manage',
        height: 44,
        fontSize: 14,
        style: TButtonStyle.outlineQuiet,
        onPressed: _openManage,
      ),
    );
  }

  Widget? _nextMatchBar() {
    final next = nextMatchFor(
        _uid, allRoundsOf(_bracket, doubleElim: _doubleElim));
    if (next == null) return null;

    final opp = opponentEntry(next, _uid);
    final String against = opp != null
        ? 'vs ${pairNameFor(opp, _uid)}'
        : opponentPlaceholder(next, _uid) != null
            ? 'vs ${opponentPlaceholder(next, _uid)!.replaceFirst('Winner', 'winner')}'
            : 'vs TBD';
    final value = isGroupLabel(next.side)
        ? against
        : next.side == 'lb'
            ? next.roundLabel == 'LB Final'
                ? 'LB Final · $against'
                : 'Losers ${next.roundLabel.replaceFirst('Round ', 'R')} · $against'
            : '${next.roundLabel} · $against';

    final submittedBy = next.row?['submitted_by'] as String?;
    final iSubmitted = (entryHasPlayer(next.e1, _uid) &&
            entryHasPlayer(next.e1, submittedBy)) ||
        (entryHasPlayer(next.e2, _uid) && entryHasPlayer(next.e2, submittedBy));
    final String? resultAction = !next.canAct(_uid)
        ? null
        : switch (next.state) {
            SlotState.ready || SlotState.live => 'Enter result',
            SlotState.disputed => 'Re-enter result',
            SlotState.pending => iSubmitted ? null : 'Confirm result',
            _ => null,
          };

    return StickyActionBar(
      left: BarLabel(eyebrow: 'YOUR NEXT MATCH', value: value),
      button: resultAction != null
          ? TButton(resultAction,
              height: 48, onPressed: () => _openResult(next.row!))
          : TButton('Details',
              height: 48,
              onPressed: () => setState(() {
                    _tab = 1;
                    _selection.showSlot(next);
                  })),
    );
  }
}

/// The map area on the Venue card: a quiet placeholder, not a real map (venues
/// have no coordinates, and "Directions" searches on the name).
class _MapPlaceholderPainter extends CustomPainter {
  const _MapPlaceholderPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = TColors.paleGreen);
    final road = Paint()
      ..color = TColors.mapRoad
      ..style = PaintingStyle.stroke;
    final sx = size.width / 390;
    canvas.drawPath(
      Path()
        ..moveTo(0, 70)
        ..lineTo(120 * sx, 40)
        ..lineTo(230 * sx, 80)
        ..lineTo(size.width, 30),
      road..strokeWidth = 14,
    );
    canvas.drawLine(
        Offset(150 * sx, 0), Offset(170 * sx, size.height), road..strokeWidth = 10);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// The dashed ring on the empty partner slot.
class _DashedCirclePainter extends CustomPainter {
  const _DashedCirclePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = TColors.accent
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final rect = Offset.zero & size;
    const dashes = 18;
    const step = 2 * 3.141592653589793 / dashes;
    for (var i = 0; i < dashes; i++) {
      canvas.drawArc(rect.deflate(1), i * step, step * 0.6, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// InstaPay payment step for a paid tournament entry. Pops with
/// `{sender, proof}` on confirm (proof = uploaded storage path or null), or
/// null if cancelled. Mirrors the store checkout's InstaPay step.
class _TournamentPaymentSheet extends StatefulWidget {
  final int feePerPlayer;
  final bool allowSplit; // show the "just me / both of us" choice
  final bool partnerShare; // this is a partner paying their own half
  final String tournamentId;
  final String tournamentName;
  final String? partnerName;
  const _TournamentPaymentSheet({
    required this.feePerPlayer,
    required this.allowSplit,
    this.partnerShare = false,
    required this.tournamentId,
    required this.tournamentName,
    this.partnerName,
  });
  @override
  State<_TournamentPaymentSheet> createState() => _TournamentPaymentSheetState();
}

class _TournamentPaymentSheetState extends State<_TournamentPaymentSheet> {
  final _sender = TextEditingController();
  Uint8List? _proofBytes;
  String _proofExt = 'jpg';
  String _handle = '';
  String? _payLink;
  bool _busy = false;
  String _mode = 'both'; // 'both' (pay 2×) | 'split' (pay own share)

  // What the user pays right now.
  int get _amount => widget.partnerShare
      ? widget.feePerPlayer
      : (_mode == 'split' ? widget.feePerPlayer : widget.feePerPlayer * 2);

  @override
  void initState() {
    super.initState();
    TournamentService.fetchPayInfo(widget.tournamentId).then((info) {
      if (mounted) {
        setState(() {
          _handle = info.handle;
          _payLink = info.link;
        });
      }
    });
    _sender.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _sender.dispose();
    super.dispose();
  }

  Future<void> _pickProof() async {
    // Downscale + compress so proofs stay small (full-res photos time out /
    // hit bucket size limits on mobile data).
    final f = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 70,
    );
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
    // The field holds the username only — the @instapay suffix is fixed in
    // the UI and added back here.
    final sender = InstapayHandle.compose(_sender.text);
    if (sender.isEmpty || _proofBytes == null) return;
    setState(() => _busy = true);
    final res = await OrderService.uploadPaymentProof(_proofBytes!, _proofExt);
    if (!mounted) return;
    // Screenshot is required here — if it didn't upload, show why and let them
    // retry rather than submitting a proof-less (unverifiable) payment.
    if (res.path == null) {
      setState(() => _busy = false);
      AppToast.show(
          context,
          res.error ??
              "Couldn't upload your payment screenshot — check your connection and try again.",
          kind: ToastKind.error);
      return;
    }
    Navigator.pop(context, {
      'sender': sender,
      'proof': res.path,
      'feeMode': widget.partnerShare ? 'split' : _mode,
    });
  }


  Future<void> _openPayLink() async {
    final l = (_payLink ?? '').trim();
    if (l.isEmpty) return;
    final uri = Uri.tryParse(l.startsWith('http') ? l : 'https://$l');
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        AppToast.show(context, "Couldn't open the link", kind: ToastKind.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _sender.text.trim().isNotEmpty && _proofBytes != null && !_busy;
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
                Text(widget.partnerShare ? 'Pay your share' : 'Pay entry fee',
                    style: AppText.stat(22, AppColors.ink)),
                const SizedBox(height: 4),
                Text(
                    widget.partnerShare
                        ? 'Transfer your share to the InstaPay account below, then '
                            'enter your sending username so we can match it.'
                        : 'Transfer to the InstaPay account below, then enter your '
                            'sending username so we can match the payment.',
                    style: AppText.small().copyWith(fontSize: 13, height: 1.4)),
                if (widget.allowSplit && !widget.partnerShare) ...[
                  const SizedBox(height: 16),
                  Text('WHO ARE YOU PAYING FOR?', style: AppText.kicker()),
                  const SizedBox(height: 8),
                  _payForToggle(),
                ],
                const SizedBox(height: 18),
                _copyRow('Send to · InstaPay', _handle.isEmpty ? '…' : _handle,
                    mono: true),
                const SizedBox(height: 10),
                _copyRow('Amount', money(_amount), copyable: false),
                if ((_payLink ?? '').isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _openPayLink,
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      label: const Text('Open payment link'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.ink,
                        side: const BorderSide(color: AppColors.line),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                Text('YOUR INSTAPAY USERNAME', style: AppText.kicker()),
                const SizedBox(height: 7),
                TextField(
                  controller: _sender,
                  inputFormatters: InstapayHandle.formatters,
                  autocorrect: false,
                  style: AppText.body(),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'e.g. yourname',
                    // Fixed — nobody should have to type "@instapay".
                    suffixText: InstapayHandle.suffix,
                    suffixStyle: AppText.bodyStrong(AppColors.inkFaint),
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
                Text('TRANSFER SCREENSHOT (REQUIRED)', style: AppText.kicker()),
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

  Widget _payForToggle() {
    Widget opt(String key, String title, String sub, int amount) {
      final on = _mode == key;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _mode = key),
          child: Container(
            margin: EdgeInsets.only(right: key == 'both' ? 8 : 0),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: on
                  ? AppColors.primary.withValues(alpha: 0.08)
                  : AppColors.surface,
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                  color: on ? AppColors.primary : AppColors.line,
                  width: on ? 1.6 : 1),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(
                    on
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_off_rounded,
                    size: 17,
                    color: on ? AppColors.primary : AppColors.inkSoft),
                const SizedBox(width: 6),
                Expanded(
                    child: Text(title,
                        style: AppText.bodyStrong().copyWith(fontSize: 13.5))),
              ]),
              const SizedBox(height: 6),
              Text(money(amount),
                  style: AppText.stat(18, on ? AppColors.primary : AppColors.ink)),
              const SizedBox(height: 3),
              Text(sub, style: AppText.small().copyWith(fontSize: 11, height: 1.3)),
            ]),
          ),
        ),
      );
    }

    // IntrinsicHeight is load-bearing: this sits in a scroll view, which gives no
    // height limit, and `stretch` with no limit breaks layout for the whole sheet.
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        opt('both', 'Both of us', 'Cover the full pair entry.',
            widget.feePerPlayer * 2),
        opt('split', 'Just me', 'Your partner pays their share.',
            widget.feePerPlayer),
      ]),
    );
  }

  Widget _copyRow(String label, String value,
      {bool mono = false, bool copyable = true}) {
    return Container(
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
        if (copyable && value != '…') CopyIcon(value, size: 16),
      ]),
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

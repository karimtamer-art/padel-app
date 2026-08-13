import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/app_toast.dart';
import 'package:padel_clay/frontend/widgets/screen_bar.dart';
import 'package:padel_clay/backend/services/match_service.dart';
import 'package:padel_clay/backend/models/ranking_scale.dart' show RankingScale;

/// 3-step Create-a-Match, wired to Supabase:
///   Type → Schedule (real dates + courts from DB) → Team (partner search).
/// After the record is written it runs an in-sheet saving → success confirmation
/// (with a match summary), then pops with the new match id ONLY when the user
/// taps "View match" (null otherwise — the caller always refreshes Home).
class CreateMatchSheet extends StatefulWidget {
  /// The signed-in player's display name + initials — used for the success
  /// summary card's "you" avatar. Optional; falls back to a neutral badge.
  final String myName;
  final String myInitials;
  const CreateMatchSheet({super.key, this.myName = '', this.myInitials = 'P'});
  @override
  State<CreateMatchSheet> createState() => _CreateMatchSheetState();
}

/// form = the 3-step wizard · creating = saving spinner · done = confirmation.
enum _CreatePhase { form, creating, done }

class _CreateMatchSheetState extends State<CreateMatchSheet> {
  _CreatePhase _phase = _CreatePhase.form;
  String? _createdId; // set once the match is written; "View match" pops it
  int _step = 0;
  int _type = 0; // 0 competitive 1 casual
  bool _private = false; // casual only — see _typeStep
  int _date = 0;
  late TimeOfDay _tod; // scroll-picked time
  bool _busy = false;

  // live data
  List<Map<String, dynamic>> _courts = [];
  bool _courtsLoading = true;
  String? _courtId;

  List<Map<String, dynamic>> _players = [];
  bool _playersLoading = true;
  Map<String, dynamic>? _partner;
  final _search = TextEditingController();

  late final List<DateTime> _days;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _days = List.generate(
        7, (i) => DateTime(now.year, now.month, now.day).add(Duration(days: i)));
    // Default to the next full hour so the picker starts on a valid slot.
    _tod = TimeOfDay(hour: (now.hour + 1) % 24, minute: 0);
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final results = await Future.wait(
        [MatchService.fetchCourts(), MatchService.searchPlayers('')]);
    if (!mounted) return;
    setState(() {
      _courts = results[0];
      _players = results[1];
      _courtsLoading = false;
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

  String _dayLabel(int i) {
    if (i == 0) return 'Today';
    if (i == 1) return 'Tomorrow';
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${wd[_days[i].weekday - 1]} ${_days[i].day}';
  }

  String _todLabel(TimeOfDay t) {
    final ap = t.hour < 12 ? 'AM' : 'PM';
    final hh = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final mm = t.minute.toString().padLeft(2, '0');
    return '$hh:$mm $ap';
  }

  DateTime get _scheduledAt =>
      _days[_date].add(Duration(hours: _tod.hour, minutes: _tod.minute));

  /// On step 1, the chosen slot must be in the future.
  bool get _canNext {
    if (_step != 1) return true;
    return _scheduledAt.isAfter(DateTime.now());
  }

  void _back() => _step > 0 ? setState(() => _step--) : Navigator.pop(context);

  Future<void> _next() async {
    if (_step < 2) {
      setState(() => _step++);
      return;
    }
    // Move into the saving state (spinner, non-dismissible) while the record
    // writes. A short floor keeps the spinner from flashing on fast networks.
    setState(() {
      _busy = true;
      _phase = _CreatePhase.creating;
    });
    // No manual min-ELO: the band handles who a competitive match is offered
    // to. Visibility is the one thing the host chooses, and only for casual —
    // the server ignores `open` on a ranked match rather than trusting this.
    final createFuture = MatchService.createMatch(
      competitive: _type == 0,
      scheduledAt: _scheduledAt,
      courtId: _courtId,
      partnerId: _partner?['id'] as String?,
      open: !(_type == 1 && _private),
    );
    await Future.delayed(const Duration(milliseconds: 700));
    final (err, id) = await createFuture;
    if (!mounted) return;
    if (err != null) {
      // Back to the form so the user can fix it and retry.
      setState(() {
        _busy = false;
        _phase = _CreatePhase.form;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.danger,
          content: Text(err)));
      return;
    }
    setState(() {
      _busy = false;
      _createdId = id;
      _phase = _CreatePhase.done;
    });
  }

  /// "Create another" — reset the wizard to a fresh first step, keeping the
  /// already-loaded courts/players so it opens instantly.
  void _reset() => setState(() {
        _phase = _CreatePhase.form;
        _step = 0;
        _partner = null;
        _createdId = null;
        _busy = false;
      });

  static const _sheetDeco = BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)));

  Widget _grip() => Container(
      width: 40, height: 4, margin: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(color: AppColors.line, borderRadius: BorderRadius.circular(2)));

  @override
  Widget build(BuildContext context) {
    // Can't dismiss while the record is being written.
    return PopScope(
      canPop: _phase != _CreatePhase.creating,
      child: switch (_phase) {
        _CreatePhase.creating => _creatingSheet(),
        _CreatePhase.done => _doneSheet(),
        _CreatePhase.form => _formSheet(),
      },
    );
  }

  // ── saving spinner ──
  Widget _creatingSheet() => Container(
        height: MediaQuery.of(context).size.height * 0.92,
        decoration: _sheetDeco,
        child: Column(children: [
          _grip(),
          Expanded(
            child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(
                    width: 54, height: 54,
                    child: CircularProgressIndicator(
                        strokeWidth: 4, color: AppColors.primary, backgroundColor: AppColors.field)),
                const SizedBox(height: 20),
                Text('Creating your match…',
                    style: AppText.cardTitle().copyWith(fontSize: 18)),
                const SizedBox(height: 4),
                Text('Saving and opening the lobby', style: AppText.small()),
              ]),
            ),
          ),
        ]),
      );

  // ── success confirmation ──
  Widget _doneSheet() {
    final partnerName = _partner?['name'] as String?;
    final courtName = _courtName();
    return Container(
      height: MediaQuery.of(context).size.height * 0.92,
      decoration: _sheetDeco,
      child: Column(children: [
        _grip(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
            children: [
              Center(
                child: _PopIn(
                  child: Container(
                    width: 84, height: 84,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.success.withValues(alpha: 0.16)),
                    child: Center(
                      child: Container(
                        width: 60, height: 60,
                        decoration: const BoxDecoration(
                            shape: BoxShape.circle, color: AppColors.success),
                        child: const Icon(Icons.check_rounded, color: Colors.white, size: 32),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Center(child: Text('Match created!', style: AppText.cardTitle().copyWith(fontSize: 21))),
              const SizedBox(height: 5),
              Center(
                child: Text(
                  partnerName == null
                      ? "We're finding players near your level and city. You'll be notified when your match fills."
                      : "We've asked ${_firstName(partnerName)} and we're holding their spot. We're finding your opponents in the meantime.",
                  textAlign: TextAlign.center,
                  style: AppText.small().copyWith(fontSize: 13.5, height: 1.5),
                ),
              ),
              const SizedBox(height: 20),
              _summaryCard(partnerName: partnerName, courtName: courtName),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                    color: AppColors.field, borderRadius: BorderRadius.circular(12)),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.notifications_none_rounded, size: 16, color: AppColors.inkSoft),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text.rich(TextSpan(
                        style: AppText.small().copyWith(fontSize: 12, height: 1.4),
                        children: [
                          const TextSpan(text: 'Added to '),
                          TextSpan(text: 'Upcoming Matches', style: AppText.bodyStrong().copyWith(fontSize: 12)),
                          const TextSpan(text: ". We'll ping you when it's full and confirmed."),
                        ])),
                  ),
                ]),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 26),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.lineSoft))),
          child: Column(children: [
            AppButton('View match', full: true, height: 52,
                onPressed: () => Navigator.pop(context, _createdId)),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: AppButton('Create another', height: 48, variant: AppBtnVariant.outline, onPressed: _reset)),
              const SizedBox(width: 10),
              Expanded(child: AppButton('Done', height: 48, variant: AppBtnVariant.ghost, onPressed: () => Navigator.pop(context))),
            ]),
          ]),
        ),
      ]),
    );
  }

  Widget _summaryCard({String? partnerName, required String courtName}) {
    final partnerInitials = (partnerName == null || partnerName.trim().isEmpty)
        ? null
        : partnerName.trim().split(RegExp(r'\s+')).take(2).map((w) => w[0]).join().toUpperCase();
    return Container(
      decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.line)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          color: AppColors.hero,
          child: Row(children: [
            SizedBox(
              width: partnerInitials != null ? 62 : 38, height: 38,
              child: Stack(children: [
                _stackAvatar(widget.myInitials, AppColors.primary, 0),
                if (partnerInitials != null)
                  _stackAvatar(partnerInitials, Colors.white.withValues(alpha: 0.18), 24),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${_type == 0 ? 'Competitive' : 'Casual'} · Doubles',
                    style: AppText.bodyStrong(AppColors.heroInk).copyWith(fontSize: 14.5)),
                Text('Finding players nearby',
                    style: AppText.small(AppColors.heroFaint).copyWith(fontSize: 12)),
              ]),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999)),
              child: Text('MATCHMAKING',
                  style: AppText.tag(AppColors.heroInk).copyWith(fontSize: 10.5)),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(14),
          child: Column(children: [
            _sumRow('When', '${_dayLabel(_date)}, ${_todLabel(_tod)}'),
            _sumRow('Court', courtName),
            _sumRow('Your partner',
                partnerName == null ? 'Open spot' : '$partnerName · awaiting reply'),
          ]),
        ),
      ]),
    );
  }

  Widget _stackAvatar(String s, Color bg, double left) => Positioned(
        left: left,
        child: Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
              shape: BoxShape.circle, color: bg,
              border: Border.all(color: AppColors.hero, width: 2)),
          child: Center(child: Text(s, style: AppText.bodyStrong(Colors.white).copyWith(fontSize: 13))),
        ),
      );

  // ── the 3-step wizard (unchanged) ──
  Widget _formSheet() {
    return Container(
      height: MediaQuery.of(context).size.height * 0.92,
      decoration: _sheetDeco,
      // Reserve the keyboard height so the partner-search field and the pinned
      // Continue/Create button stay above it.
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(children: [
        _grip(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(children: [
            Text('New Match', style: AppText.cardTitle().copyWith(fontSize: 20)),
            const Spacer(),
            IconChip(Icons.close_rounded, onTap: () => Navigator.pop(context)),
          ]),
        ),
        const Divider(height: 18, color: AppColors.lineSoft),
        _StepDots(step: _step),
        const Divider(height: 1, color: AppColors.lineSoft),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: _step == 0 ? _typeStep() : _step == 1 ? _scheduleStep() : _playersStep(),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 26),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.lineSoft))),
          child: Row(children: [
            if (_step > 0) ...[
              SizedBox(width: 92, child: AppButton('Back', height: 52, variant: AppBtnVariant.ghost, onPressed: _busy ? null : _back)),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: AppButton(
                  _busy ? 'Creating…' : (_step < 2 ? 'Continue' : 'Create Match'),
                  full: true, height: 52,
                  onPressed: (_canNext && !_busy) ? _next : null),
            ),
          ]),
        ),
        ]),
      ),
    );
  }

  // ── Step 0: type ──
  Widget _typeStep() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('What kind of match?', style: AppText.cardTitle().copyWith(fontSize: 16)),
        const SizedBox(height: 3),
        Text('Choose your match format', style: AppText.small()),
        const SizedBox(height: 20),
        _typeCard(Icons.emoji_events_rounded, 'Competitive', 'Ranked — affects your ELO rating', AppColors.accent, 0),
        const SizedBox(height: 12),
        _typeCard(Icons.sports_tennis_rounded, 'Casual', 'Play for fun — no ranking impact', AppColors.inkSoft, 1),
        // Casual only. A competitive match moves everybody's rating, so it
        // stays open to the band — a private ranked lobby is how you would
        // farm rating off a hand-picked opponent.
        if (_type == 1) ...[
          const SizedBox(height: 22),
          Text('Who can join?', style: AppText.cardTitle().copyWith(fontSize: 16)),
          const SizedBox(height: 3),
          Text('You can\'t change this after the match is created',
              style: AppText.small()),
          const SizedBox(height: 14),
          _visCard(Icons.public_rounded, 'Public',
              'Anyone nearby can find it and join', false),
          const SizedBox(height: 12),
          _visCard(Icons.lock_outline_rounded, 'Private',
              'Hidden — only people you send the code to can join', true),
        ],
      ]);

  Widget _visCard(IconData icon, String title, String sub, bool value) {
    final on = _private == value;
    final accent = value ? AppColors.gold : AppColors.primary;
    return GestureDetector(
      onTap: () => setState(() => _private = value),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: on ? accent.withValues(alpha: 0.08) : AppColors.field,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: on ? accent : AppColors.line, width: 1.5),
        ),
        child: Row(children: [
          Icon(icon, size: 20, color: on ? accent : AppColors.inkFaint),
          const SizedBox(width: 13),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: AppText.bodyStrong(on ? AppColors.ink : AppColors.inkSoft)
                      .copyWith(fontSize: 14.5)),
              const SizedBox(height: 1),
              Text(sub, style: AppText.small()),
            ]),
          ),
          Container(
            width: 22, height: 22,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: on ? accent : Colors.transparent,
                border: Border.all(color: on ? accent : AppColors.line, width: 1.5)),
            child: on
                ? const Icon(Icons.check_rounded, size: 13, color: AppColors.primaryInk)
                : null,
          ),
        ]),
      ),
    );
  }

  Widget _typeCard(IconData icon, String title, String sub, Color accent, int i) {
    final on = _type == i;
    return GestureDetector(
      onTap: () => setState(() => _type = i),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: on ? accent.withValues(alpha: 0.08) : AppColors.field,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: on ? accent : AppColors.line, width: 1.5),
        ),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(color: accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(11)),
            child: Icon(icon, size: 22, color: accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppText.bodyStrong(on ? AppColors.ink : AppColors.inkSoft).copyWith(fontSize: 15)),
              const SizedBox(height: 1),
              Text(sub, style: AppText.small()),
            ]),
          ),
          Container(
            width: 22, height: 22,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: on ? accent : Colors.transparent,
                border: Border.all(color: on ? accent : AppColors.line, width: 1.5)),
            child: on ? const Icon(Icons.check_rounded, size: 13, color: AppColors.primaryInk) : null,
          ),
        ]),
      ),
    );
  }

  // ── Step 1: schedule ──
  Widget _scheduleStep() {
    final pastSlot = !_scheduledAt.isAfter(DateTime.now());
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _label('Date'),
      _pills([for (int i = 0; i < _days.length; i++) _dayLabel(i)], _date,
          (i) => setState(() => _date = i)),
      const SizedBox(height: 22),
      Row(children: [
        _label('Time'),
        const Spacer(),
        Text(_todLabel(_tod),
            style: AppText.bodyStrong().copyWith(color: AppColors.primary)),
      ]),
      const SizedBox(height: 8),
      _timeWheel(),
      if (pastSlot)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('That time has already passed — pick a later slot.',
              style: AppText.small(AppColors.danger).copyWith(fontSize: 12)),
        ),
      const SizedBox(height: 22),
      _label('Court'),
      _courtsMap(),
      Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(
          color: AppColors.gold.withValues(alpha: 0.11),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.gold.withValues(alpha: 0.32)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('⚠️', style: TextStyle(fontSize: 15)),
          const SizedBox(width: 9),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: "Court booking isn't handled by the app. ",
                    style: AppText.bodyStrong().copyWith(fontSize: 12, fontWeight: FontWeight.w800)),
                TextSpan(text: 'Make sure the court is already booked before creating the match.',
                    style: AppText.small().copyWith(fontSize: 12, height: 1.45)),
              ]),
            ),
          ),
        ]),
      ),
      if (_courtsLoading)
        const Center(child: Padding(
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
        ))
      else if (_courts.isEmpty)
        _emptyBox(Icons.place_outlined, 'No courts listed yet',
            'Courts will appear here once added to the system. You can still create the match and agree on a venue with the players.')
      else
        Column(children: [
          for (final c in _courts) _courtTile(c),
        ]),
    ]);
  }

  Widget _timeWheel() => Container(
        height: 168,
        decoration: BoxDecoration(
          color: AppColors.field,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: CupertinoTheme(
          data: CupertinoThemeData(
            textTheme: CupertinoTextThemeData(
              dateTimePickerTextStyle:
                  AppText.bodyStrong().copyWith(fontSize: 20),
            ),
          ),
          child: CupertinoDatePicker(
            mode: CupertinoDatePickerMode.time,
            minuteInterval: 5,
            use24hFormat: false,
            initialDateTime: DateTime(2020, 1, 1, _tod.hour, _tod.minute),
            onDateTimeChanged: (dt) => setState(
                () => _tod = TimeOfDay(hour: dt.hour, minute: dt.minute)),
          ),
        ),
      );

  // Decorative header — Directions on each card open the court in the maps app.
  Widget _courtsMap() => Container(
        height: 132,
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.field, AppColors.surface]),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(children: [
          Positioned(top: -22, right: -12, child: _mapBlob(92, AppColors.primary.withValues(alpha: 0.05))),
          Positioned(bottom: -26, left: -16, child: _mapBlob(84, AppColors.gold.withValues(alpha: 0.06))),
          Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.location_on_outlined, size: 26, color: AppColors.inkFaint),
              const SizedBox(height: 6),
              Text('Tap Directions on a court to open it in Maps',
                  textAlign: TextAlign.center,
                  style: AppText.small().copyWith(fontSize: 11.5)),
            ]),
          ),
        ]),
      );

  Widget _mapBlob(double d, Color c) =>
      Container(width: d, height: d, decoration: BoxDecoration(color: c, shape: BoxShape.circle));

  Widget _courtTile(Map<String, dynamic> c) {
    final id = c['id'] as String;
    final on = _courtId == id;
    final venue = (c['venue_name'] as String?)?.trim() ?? '';
    final name = (c['name'] as String?)?.trim() ?? '';
    final area = (c['area'] as String?)?.trim() ?? '';
    final city = (c['city'] as String?)?.trim() ?? '';
    final indoor = c['indoor'] == true;
    final lat = (c['lat'] as num?)?.toDouble();
    final lng = (c['lng'] as num?)?.toDouble();
    final address = (c['address'] as String?)?.trim();
    final hasLoc = (lat != null && lng != null) || (address != null && address.isNotEmpty);
    // Headline is the club/venue (big + bold); the court label sits in the
    // sub-line beside the area and Indoor/Outdoor.
    final title = venue.isNotEmpty ? venue : (name.isNotEmpty ? name : 'Court');
    final place = area.isNotEmpty ? area : city;
    final showName = venue.isNotEmpty && name.isNotEmpty && name.toLowerCase() != 'court';
    final sub = [
      if (showName) name,
      if (place.isNotEmpty) place,
      indoor ? 'Indoor' : 'Outdoor',
    ].join('  ·  ');
    final accent = on ? AppColors.primary : AppColors.inkFaint;
    return GestureDetector(
      onTap: () => setState(() => _courtId = on ? null : id),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: on ? AppColors.primary.withValues(alpha: 0.07) : AppColors.field,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: on ? AppColors.primary : AppColors.line, width: 1.5),
        ),
        child: Row(children: [
          Container(
            width: 38, height: 38, alignment: Alignment.center,
            decoration: BoxDecoration(
                color: on ? AppColors.primary.withValues(alpha: 0.14) : AppColors.surface,
                borderRadius: BorderRadius.circular(10)),
            child: Icon(Icons.location_on_rounded, size: 19, color: accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.bodyStrong().copyWith(fontSize: 15.5, fontWeight: FontWeight.w800)),
              if (sub.isNotEmpty) ...[
                const SizedBox(height: 2),
                Row(children: [
                  Icon(indoor ? Icons.home_rounded : Icons.wb_sunny_rounded,
                      size: 12, color: AppColors.inkFaint),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.small().copyWith(fontSize: 12)),
                  ),
                ]),
              ],
            ]),
          ),
          const SizedBox(width: 8),
          if (hasLoc)
            GestureDetector(
              onTap: () => _openDirections(lat, lng, address),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.directions_rounded, size: 20, color: AppColors.primary),
                  const SizedBox(height: 1),
                  Text('Directions',
                      style: AppText.tag(AppColors.primary).copyWith(fontSize: 8.5)),
                ]),
              ),
            )
          else if (on)
            const Icon(Icons.check_circle_rounded, size: 20, color: AppColors.primary)
          else
            const Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.inkFaint),
        ]),
      ),
    );
  }

  // Opens the maps app with a route to the court (coords preferred, else address).
  Future<void> _openDirections(double? lat, double? lng, String? address) async {
    final dest = (lat != null && lng != null)
        ? '$lat,$lng'
        : (address != null && address.isNotEmpty ? Uri.encodeComponent(address) : null);
    if (dest == null) return;
    final uri = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$dest');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) AppToast.show(context, "Couldn't open Maps", kind: ToastKind.error);
    }
  }

  // ── Step 2: team ──
  Widget _playersStep() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _label('Your partner'),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text('Padel is doubles — ask a friend to take your side, or leave it open and the matchmaker fills all spots.',
              style: AppText.small().copyWith(fontSize: 12.5, height: 1.5)),
        ),
        _partnerPick(),
        // The invite is a request, not an enrolment: they are not in the match,
        // and none of their details are shared, until they say yes.
        if (_partner != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: AppColors.gold.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.gold.withValues(alpha: 0.3)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.schedule_rounded, size: 18, color: AppColors.gold),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(TextSpan(children: [
                  TextSpan(
                      text: '${_firstName(_partner!['name'] as String?)} has to accept. ',
                      style: AppText.bodyStrong().copyWith(fontSize: 12.5)),
                  TextSpan(
                      text: "We'll hold the spot for them until they do — nobody else can take it.",
                      style: AppText.small().copyWith(fontSize: 12.5, height: 1.45)),
                ])),
              ),
            ]),
          ),
        ],
        const SizedBox(height: 22),
        // A private match is the exact opposite of what the matchmaking note
        // promises, so it must not be shown alongside one.
        if (_type == 1 && _private)
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: AppColors.gold.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.gold.withValues(alpha: 0.3)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.lock_outline_rounded, size: 18, color: AppColors.gold),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: 'Nobody can find this match. ',
                      style: AppText.bodyStrong().copyWith(fontSize: 12.5)),
                  TextSpan(
                      text: "You'll get an invite code once it's created — share it and they can join with it.",
                      style: AppText.small().copyWith(fontSize: 12.5, height: 1.45)),
                ])),
              ),
            ]),
          )
        else
          // The matchmaker (rating band + city + time window) decides who this
          // match is offered to.
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.bolt_rounded, size: 18, color: AppColors.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: 'Matchmaking finds your opponents. ',
                      style: AppText.bodyStrong().copyWith(fontSize: 12.5)),
                  TextSpan(
                      text: "We'll offer this match to players near your level, in your city, free around this time.",
                      style: AppText.small().copyWith(fontSize: 12.5, height: 1.45)),
                ])),
              ),
            ]),
          ),
        const SizedBox(height: 22),
        AppCard(
          color: AppColors.field,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('SUMMARY', style: AppText.kicker()),
            const SizedBox(height: 8),
            _sumRow('Type', _type == 0 ? 'Competitive · Doubles' : 'Casual · Doubles'),
            if (_type == 1)
              _sumRow('Who can join', _private ? 'Private · code only' : 'Anyone nearby'),
            _sumRow('When', '${_dayLabel(_date)}, ${_todLabel(_tod)}'),
            _sumRow('Court', _courtName()),
            _sumRow(
                'Your partner',
                _partner == null
                    ? 'Open spot'
                    : '${_partner!['name']} · awaiting reply'),
          ]),
        ),
      ]);

  static String _firstName(String? full) {
    final t = (full ?? '').trim();
    if (t.isEmpty) return 'They';
    return t.split(RegExp(r'\s+')).first;
  }

  String _courtName() {
    if (_courtId == null) return 'To be agreed';
    final c = _courts.firstWhere((c) => c['id'] == _courtId, orElse: () => {});
    return (c['venue_name'] as String?) ?? (c['name'] as String?) ?? '—';
  }

  Widget _partnerPick() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
        _emptyBox(Icons.group_outlined, 'No players found',
            'Try another name, or leave the spot open — your side fills from the lobby.')
      else
        SizedBox(
          height: 220,
          child: ListView(children: [for (final p in _players) _playerTile(p)]),
        ),
    ]);
  }

  Widget _playerTile(Map<String, dynamic> p, {bool selected = false}) {
    final name = p['name'] as String? ?? 'Player';
    final username = p['username'] as String?;
    final ranked = p['rating'] != null || p['level'] != null;
    final lv = (p['rating'] as num?)?.toDouble()
        ?? (p['level'] as num?)?.toDouble() ?? 0.0;
    final rankTag = ranked ? RankingScale.levelTag(lv) : 'Unranked';
    final initials = name.trim().isEmpty
        ? 'P'
        : name.trim().split(RegExp(r'\s+')).take(2).map((w) => w[0]).join().toUpperCase();
    final subtitle = (username != null && username.isNotEmpty)
        ? '@$username · $rankTag'
        : rankTag;
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
              imageUrl: p['avatar_url'] as String?),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: AppText.bodyStrong().copyWith(fontSize: 13.5)),
              Text(subtitle,
                  style: AppText.small().copyWith(fontSize: 11.5)),
            ]),
          ),
          Icon(selected ? Icons.close_rounded : Icons.add_circle_outline_rounded,
              size: 20, color: selected ? AppColors.inkSoft : AppColors.primary),
        ]),
      ),
    );
  }

  Widget _emptyBox(IconData icon, String title, String sub) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: AppColors.field,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.line)),
        child: Row(children: [
          Container(
            width: 38, height: 38, alignment: Alignment.center,
            decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 20, color: AppColors.inkFaint),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppText.bodyStrong().copyWith(fontSize: 13.5)),
              const SizedBox(height: 2),
              Text(sub, style: AppText.small().copyWith(fontSize: 12, height: 1.4)),
            ]),
          ),
        ]),
      );

  Widget _sumRow(String k, String v) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          Text(k, style: AppText.small()),
          const Spacer(),
          Flexible(child: Text(v, textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStrong())),
        ]),
      );

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(t, style: AppText.bodyStrong(AppColors.inkSoft).copyWith(fontSize: 13)),
      );

  Widget _pills(List<String> items, int value, ValueChanged<int> onChange) => Wrap(
        spacing: 8, runSpacing: 8,
        children: [
          for (int i = 0; i < items.length; i++)
            GestureDetector(
              onTap: () => onChange(i),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
                decoration: BoxDecoration(
                  color: value == i ? AppColors.primary : AppColors.field,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: value == i ? AppColors.primary : AppColors.line),
                ),
                child: Text(items[i],
                    style: AppText.bodyStrong(value == i ? AppColors.primaryInk : AppColors.inkSoft).copyWith(fontSize: 13)),
              ),
            ),
        ],
      );
}

class _StepDots extends StatelessWidget {
  final int step;
  const _StepDots({required this.step});
  @override
  Widget build(BuildContext context) {
    const labels = ['Type', 'Schedule', 'Team'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
      child: Row(children: [
        for (int i = 0; i < 3; i++) ...[
          Column(children: [
            Container(
              width: 28, height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i <= step ? AppColors.primary : Colors.transparent,
                border: Border.all(color: i <= step ? AppColors.primary : AppColors.line, width: 1.5),
              ),
              child: i < step
                  ? const Icon(Icons.check_rounded, size: 14, color: AppColors.primaryInk)
                  : Text('${i + 1}', style: AppText.bodyStrong(i <= step ? AppColors.primaryInk : AppColors.inkFaint).copyWith(fontSize: 12)),
            ),
            const SizedBox(height: 5),
            Text(labels[i], style: AppText.tag(i == step ? AppColors.ink : i < step ? AppColors.primary : AppColors.inkFaint).copyWith(fontSize: 10, letterSpacing: 0)),
          ]),
          if (i < 2)
            Expanded(
              child: Container(
                height: 1.5,
                margin: const EdgeInsets.only(bottom: 16, left: 6, right: 6),
                color: i < step ? AppColors.primary : AppColors.line,
              ),
            ),
        ],
      ]),
    );
  }
}

/// One-shot elastic pop-in for the success check mark.
class _PopIn extends StatefulWidget {
  final Widget child;
  const _PopIn({required this.child});
  @override
  State<_PopIn> createState() => _PopInState();
}

class _PopInState extends State<_PopIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 460))..forward();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScaleTransition(
      scale: CurvedAnimation(parent: _c, curve: Curves.elasticOut), child: widget.child);
}

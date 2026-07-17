import 'dart:async';
import 'package:flutter/cupertino.dart' show CupertinoDatePicker, CupertinoDatePickerMode, CupertinoTheme, CupertinoThemeData, CupertinoTextThemeData;
import 'package:flutter/material.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/backend/services/match_service.dart';
import 'package:padel_clay/backend/models/ranking_scale.dart' show RankingScale;
import 'package:padel_clay/backend/models/matchmaking_config.dart';
import '../detail/join_match_sheet.dart';

/// The searching → "match found" flow AS THE HOME HERO (in-widget, not a
/// screen). Morphs radar → candidate card → accept/decline, all in the slot.
/// Polls the band-gatekept `mm_candidates` while the app is open.
class MatchmakingHero extends StatefulWidget {
  final String initials; // center puck (the player)
  final String levelLabel; // LEVEL criteria (e.g. "Div B")
  final void Function(String matchId) onAccepted;
  final VoidCallback onCancel;
  // Optional starting day + time-range window (from the "choose when" entry).
  // Null = quick auto-match (default rolling window).
  final DateTime? initialFrom;
  final DateTime? initialTo;
  const MatchmakingHero({
    super.key,
    required this.initials,
    required this.levelLabel,
    required this.onAccepted,
    required this.onCancel,
    this.initialFrom,
    this.initialTo,
  });

  @override
  State<MatchmakingHero> createState() => _MatchmakingHeroState();
}

enum _MMPhase { searching, found, joining }

class _MatchmakingHeroState extends State<MatchmakingHero> {
  _MMPhase _phase = _MMPhase.searching;
  Map<String, dynamic>? _candidate;
  final Set<String> _declined = {};
  int _elapsed = 0;
  int _confirmLeft = 0;
  Timer? _poll;
  Timer? _tick;
  // Optional day + time-range filter. Null = default rolling window (next Nh).
  DateTime? _from;
  DateTime? _to;

  @override
  void initState() {
    super.initState();
    _from = widget.initialFrom;
    _to = widget.initialTo;
    _startSearch();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  void _startSearch() {
    _poll?.cancel();
    _tick?.cancel();
    setState(() {
      _phase = _MMPhase.searching;
      _candidate = null;
      _confirmLeft = 0;
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed++);
    });
    _pollOnce();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _pollOnce());
  }

  Future<void> _pollOnce() async {
    if (!mounted || _phase != _MMPhase.searching) return;
    final rows =
        await MatchService.fetchBandCandidates(limit: 10, from: _from, to: _to);
    if (!mounted || _phase != _MMPhase.searching) return;
    Map<String, dynamic>? next;
    for (final r in rows) {
      if (!_declined.contains(r['match_id'])) {
        next = r;
        break;
      }
    }
    if (next != null) _onFound(next);
  }

  void _onFound(Map<String, dynamic> c) {
    _poll?.cancel();
    _tick?.cancel();
    setState(() {
      _candidate = c;
      _phase = _MMPhase.found;
      _confirmLeft = MatchmakingConfig.confirmSeconds;
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_confirmLeft <= 1) {
        _decline();
      } else {
        setState(() => _confirmLeft--);
      }
    });
  }

  void _decline() {
    final c = _candidate;
    if (c != null) _declined.add(c['match_id'] as String);
    _startSearch();
  }

  Future<void> _accept() async {
    final c = _candidate;
    if (c == null) return;
    final id = c['match_id'] as String;
    // Ask: join solo (random partner) or bring your own partner.
    _tick?.cancel();
    final choice = await showJoinMatchSheet(context);
    if (choice == null || !mounted) return; // dismissed → keep the found card
    setState(() => _phase = _MMPhase.joining);
    final err = await MatchService.acceptCandidate(id, partnerId: choice.partnerId);
    if (!mounted) return;
    if (err != null) {
      _declined.add(id);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.danger,
          content: Text(err)));
      _startSearch();
      return;
    }
    widget.onAccepted(id);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 16, AppSpacing.screen, 0),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: AppRadius.cardR,
          gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.hero, AppColors.hero2]),
          boxShadow: kCardShadow,
        ),
        child: Stack(children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -0.6),
                  radius: 1.0,
                  colors: [AppColors.primary.withValues(alpha: 0.22), Colors.transparent],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(18),
            child: switch (_phase) {
              _MMPhase.searching => _searching(),
              _MMPhase.found => _found(),
              _MMPhase.joining => _joining(),
            },
          ),
        ]),
      ),
    );
  }

  // ── searching ──
  Widget _searching() {
    final widening = _elapsed >= 15;
    return Column(children: [
      Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(999)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.bolt_rounded, size: 12, color: AppColors.heroInk),
            const SizedBox(width: 5),
            Text('QUICK MATCH',
                style: AppText.tag(AppColors.heroFaint).copyWith(fontSize: 10.5, letterSpacing: 1)),
          ]),
        ),
        const Spacer(),
        Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.schedule_rounded, size: 12, color: AppColors.heroFaint),
          const SizedBox(width: 4),
          Text('${_elapsed}s',
              style: AppText.tag(AppColors.heroFaint).copyWith(fontSize: 11)),
        ]),
      ]),
      const SizedBox(height: 18),
      _Radar(initials: widget.initials),
      const SizedBox(height: 18),
      Text('Finding your match…',
          style: AppText.stat(21, AppColors.heroInk).copyWith(letterSpacing: -0.3)),
      const SizedBox(height: 6),
      Text(
          _from != null
              ? 'Pairing you with a ${widget.levelLabel} player for ${_whenLong()}.'
              : widening
                  ? 'Widening your search — pairing you with the closest ${widget.levelLabel} player available.'
                  : 'Pairing you with a ${widget.levelLabel} player free soon, near you.',
          textAlign: TextAlign.center,
          style: AppText.small(AppColors.heroFaint).copyWith(fontSize: 12.5, height: 1.5)),
      const SizedBox(height: 18),
      Row(children: [
        _criteria(Icons.military_tech_rounded, 'LEVEL', widget.levelLabel),
        _criteria(Icons.place_rounded, 'RANGE', 'Nearby'),
        _criteria(Icons.schedule_rounded, 'WHEN', _whenShort(), onTap: _editWhen),
      ]),
      const SizedBox(height: 16),
      SizedBox(
        width: double.infinity,
        child: AppButton('Cancel search',
            height: 46, variant: AppBtnVariant.ghost, onPressed: widget.onCancel),
      ),
    ]);
  }

  Widget _criteria(IconData icon, String label, String value, {VoidCallback? onTap}) {
    final active = onTap != null && _from != null;
    final tile = Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 6),
      decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: active ? 0.13 : 0.07),
          borderRadius: BorderRadius.circular(12),
          border: onTap != null
              ? Border.all(color: AppColors.gold.withValues(alpha: active ? 0.55 : 0.28))
              : null),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 16, color: AppColors.gold),
          if (onTap != null) ...[
            const SizedBox(width: 3),
            const Icon(Icons.expand_more_rounded, size: 13, color: AppColors.heroFaint),
          ],
        ]),
        const SizedBox(height: 6),
        Text(value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.bodyStrong(AppColors.heroInk).copyWith(fontSize: 12.5)),
        const SizedBox(height: 2),
        Text(label,
            style: AppText.tag(AppColors.heroFaint).copyWith(fontSize: 9, letterSpacing: 0.5)),
      ]),
    );
    return Expanded(
      child: onTap == null
          ? tile
          : GestureDetector(onTap: onTap, behavior: HitTestBehavior.opaque, child: tile),
    );
  }

  // ── WHEN filter ──
  String _whenShort() {
    if (_from == null) return 'Next ${MatchmakingConfig.timeWindowHours}h';
    return '${_dayShort(_from!)} ${_hm(_from!)}';
  }

  String _whenLong() {
    if (_from == null) return 'the next ${MatchmakingConfig.timeWindowHours} hours';
    final to = _to;
    final range = to == null ? _hm(_from!) : '${_hm(_from!)}–${_hm(to)}';
    return '${_dayLong(_from!)}, $range';
  }

  static const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _mo = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _dayShort(DateTime d) {
    final now = DateTime.now();
    if (_sameDay(d, now)) return 'Today';
    if (_sameDay(d, now.add(const Duration(days: 1)))) return 'Tmrw';
    return _wd[d.weekday - 1];
  }

  String _dayLong(DateTime d) {
    final now = DateTime.now();
    if (_sameDay(d, now)) return 'today';
    if (_sameDay(d, now.add(const Duration(days: 1)))) return 'tomorrow';
    return '${_wd[d.weekday - 1]} ${d.day} ${_mo[d.month - 1]}';
  }

  static String _hm(DateTime d) {
    final h = d.hour == 0 ? 12 : (d.hour > 12 ? d.hour - 12 : d.hour);
    final ap = d.hour < 12 ? 'am' : 'pm';
    return d.minute == 0 ? '$h$ap' : '$h:${d.minute.toString().padLeft(2, '0')}$ap';
  }

  Future<void> _editWhen() async {
    final w = await showMatchWhenPicker(context, from: _from, to: _to);
    if (w == null || !mounted) return; // dismissed
    setState(() {
      _from = w.from;
      _to = w.to;
      _declined.clear();
    });
    _startSearch();
  }

  // ── found ──
  Widget _found() {
    final c = _candidate!;
    final name = (c['creator_name'] as String?)?.trim().isNotEmpty == true
        ? c['creator_name'] as String
        : 'Player';
    final level = (c['creator_level'] as num?)?.toDouble() ?? 2.0;
    final div = RankingScale.divisionFor(level);
    final pct = (c['level_match_pct'] as num?)?.toInt() ?? 0;
    final venue = (c['venue_name'] as String?)?.trim().isNotEmpty == true
        ? c['venue_name'] as String
        : (c['court_name'] as String?)?.trim().isNotEmpty == true
            ? c['court_name'] as String
            : 'Court to be agreed';
    final mm = '${_confirmLeft ~/ 60}:${(_confirmLeft % 60).toString().padLeft(2, '0')}';

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const AppTag('Match Found', color: AppColors.success, solid: true),
        Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.timer_outlined, size: 14, color: AppColors.gold),
          const SizedBox(width: 5),
          Text('Confirm in $mm',
              style: AppText.bodyStrong(AppColors.gold).copyWith(fontSize: 12.5)),
        ]),
      ]),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          Container(
            width: 50, height: 50,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                shape: BoxShape.circle, color: AppColors.gold.withValues(alpha: 0.28)),
            child: Text(_initials(name), style: AppText.stat(17, const Color(0xFFF0D9A4))),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.bodyStrong(AppColors.heroInk).copyWith(fontSize: 15.5)),
                ),
                const SizedBox(width: 7),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                      color: AppColors.primary, borderRadius: BorderRadius.circular(6)),
                  child: Text('DIV ${div.key}',
                      style: AppText.tag(AppColors.primaryInk).copyWith(fontSize: 9.5)),
                ),
              ]),
              const SizedBox(height: 3),
              Text('Lv ${RankingScale.fmtQuarter(level)} · $pct% level match',
                  style: AppText.small(AppColors.heroFaint).copyWith(fontSize: 11.5)),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: (pct / 100).clamp(0.0, 1.0),
                  minHeight: 5,
                  backgroundColor: Colors.white.withValues(alpha: 0.15),
                  color: AppColors.success,
                ),
              ),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      Row(children: [
        const Icon(Icons.place_outlined, size: 15, color: AppColors.heroFaint),
        const SizedBox(width: 8),
        Expanded(
          child: Text('$venue · Doubles',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.small(AppColors.heroFaint).copyWith(fontSize: 13)),
        ),
      ]),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(
          flex: 2,
          child: AppButton('Decline',
              height: 50, variant: AppBtnVariant.ghost, onPressed: _decline),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 3,
          child: AppButton('Accept match',
              height: 50, icon: Icons.check_rounded, onPressed: _accept),
        ),
      ]),
    ]);
  }

  // ── joining ──
  Widget _joining() => const Column(children: [
        SizedBox(height: 20),
        SizedBox(
            width: 40, height: 40,
            child: CircularProgressIndicator(strokeWidth: 3.4, color: AppColors.heroInk)),
        SizedBox(height: 16),
        _JoiningText(),
        SizedBox(height: 20),
      ]);

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return 'P';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}

class _JoiningText extends StatelessWidget {
  const _JoiningText();
  @override
  Widget build(BuildContext context) => Text('Locking it in…',
      style: AppText.bodyStrong(AppColors.heroInk).copyWith(fontSize: 16));
}

/// Opens the day + time-range picker. Returns the chosen window, or null if the
/// sheet was dismissed. A result with both fields null means "any time" (the
/// quick/rolling window). Shared by the searching hero's WHEN tile and the
/// home "choose a day & time" entry.
Future<({DateTime? from, DateTime? to})?> showMatchWhenPicker(
    BuildContext context, {DateTime? from, DateTime? to}) async {
  final res = await showModalBottomSheet<_WhenResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _WhenSheet(from: from, to: to),
  );
  return res == null ? null : (from: res.from, to: res.to);
}

/// Result of the WHEN filter sheet: both null → any time (rolling window),
/// otherwise the chosen [from, to] window (local time).
class _WhenResult {
  final DateTime? from;
  final DateTime? to;
  const _WhenResult(this.from, this.to);
}

/// Bottom sheet: pick "any time" or a specific day + time-of-day range for
/// which matches to matchmake against.
class _WhenSheet extends StatefulWidget {
  final DateTime? from;
  final DateTime? to;
  const _WhenSheet({this.from, this.to});
  @override
  State<_WhenSheet> createState() => _WhenSheetState();
}

class _WhenSheetState extends State<_WhenSheet> {
  late bool _any;
  late DateTime _day;
  late TimeOfDay _start;
  late TimeOfDay _end;
  String? _picking; // null · 'from' · 'to' — which field the wheel edits

  @override
  void initState() {
    super.initState();
    final f = widget.from;
    final now = DateTime.now();
    _any = f == null;
    _day = f != null
        ? DateTime(f.year, f.month, f.day)
        : DateTime(now.year, now.month, now.day);
    _start = f != null
        ? TimeOfDay(hour: f.hour, minute: f.minute)
        : const TimeOfDay(hour: 18, minute: 0);
    final t = widget.to;
    _end = t != null
        ? TimeOfDay(hour: t.hour, minute: t.minute)
        : const TimeOfDay(hour: 22, minute: 0);
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  void _apply() {
    if (_any) {
      Navigator.pop(context, const _WhenResult(null, null));
      return;
    }
    var from = DateTime(_day.year, _day.month, _day.day, _start.hour, _start.minute);
    var to = DateTime(_day.year, _day.month, _day.day, _end.hour, _end.minute);
    if (!to.isAfter(from)) to = from.add(const Duration(hours: 2));
    Navigator.pop(context, _WhenResult(from, to));
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _day.isBefore(today) ? today : _day,
      firstDate: today,
      lastDate: today.add(const Duration(days: 30)),
    );
    if (picked != null) setState(() => _day = DateTime(picked.year, picked.month, picked.day));
  }


  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final beyond = !_sameDay(_day, today) && !_sameDay(_day, tomorrow);
    final loc = MaterialLocalizations.of(context);

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: EdgeInsets.only(
          left: 20, right: 20, top: 10, bottom: 20 + MediaQuery.of(context).padding.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(
          child: Container(
            width: 40, height: 4,
            decoration: BoxDecoration(color: AppColors.line, borderRadius: BorderRadius.circular(999)),
          ),
        ),
        const SizedBox(height: 16),
        Text('When do you want to play?', style: AppText.stat(19, AppColors.ink)),
        const SizedBox(height: 4),
        Text('Match against games created for a time that suits you.',
            style: AppText.small(AppColors.inkSoft).copyWith(fontSize: 12.5)),
        const SizedBox(height: 16),
        Row(children: [
          _mode('Any time', _any, () => setState(() => _any = true)),
          const SizedBox(width: 10),
          _mode('Specific slot', !_any, () => setState(() => _any = false)),
        ]),
        const SizedBox(height: 18),
        if (_any)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(14)),
            child: Text(
                'We\'ll pair you with any matching-level game in the next '
                '${MatchmakingConfig.timeWindowHours} hours near you.',
                style: AppText.small(AppColors.inkSoft).copyWith(fontSize: 12.5, height: 1.4)),
          )
        else ...[
          Text('DAY', style: AppText.tag(AppColors.inkFaint)),
          const SizedBox(height: 8),
          Row(children: [
            _dayChip('Today', _sameDay(_day, today), () => setState(() => _day = today)),
            const SizedBox(width: 8),
            _dayChip('Tomorrow', _sameDay(_day, tomorrow), () => setState(() => _day = tomorrow)),
            const SizedBox(width: 8),
            _dayChip(beyond ? '${_day.day} ${_MatchmakingHeroState._mo[_day.month - 1]}' : 'Pick date',
                beyond, _pickDate,
                icon: Icons.event_rounded),
          ]),
          const SizedBox(height: 16),
          Text('TIME RANGE', style: AppText.tag(AppColors.inkFaint)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _timeBox('from', 'From', loc.formatTimeOfDay(_start))),
            const SizedBox(width: 10),
            Expanded(child: _timeBox('to', 'To', loc.formatTimeOfDay(_end))),
          ]),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: _picking == null ? const SizedBox(width: double.infinity) : _wheel(),
          ),
        ],
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: AppButton('Apply', height: 50, icon: Icons.check_rounded, onPressed: _apply),
        ),
      ]),
    );
  }

  Widget _mode(String label, bool on, VoidCallback onTap) => Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? AppColors.primary : AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: on ? AppColors.primary : AppColors.line),
            ),
            child: Text(label,
                style: AppText.bodyStrong(on ? AppColors.primaryInk : AppColors.inkSoft)
                    .copyWith(fontSize: 13.5)),
          ),
        ),
      );

  Widget _dayChip(String label, bool on, VoidCallback onTap, {IconData? icon}) => Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            height: 42,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: on ? AppColors.gold.withValues(alpha: 0.14) : AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: on ? AppColors.gold : AppColors.line),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: on ? AppColors.gold : AppColors.inkFaint),
                const SizedBox(width: 5),
              ],
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.bodyStrong(on ? AppColors.ink : AppColors.inkSoft)
                        .copyWith(fontSize: 12.5)),
              ),
            ]),
          ),
        ),
      );

  Widget _timeBox(String field, String label, String value) {
    final on = _picking == field;
    return GestureDetector(
      onTap: () => setState(() => _picking = on ? null : field),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: on ? AppColors.primary.withValues(alpha: 0.08) : AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? AppColors.primary : AppColors.line, width: on ? 1.5 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(), style: AppText.tag(AppColors.inkFaint)),
          const SizedBox(height: 4),
          Row(children: [
            Icon(on ? Icons.expand_more_rounded : Icons.schedule_rounded,
                size: 15, color: AppColors.primary),
            const SizedBox(width: 6),
            Text(value, style: AppText.bodyStrong(AppColors.ink).copyWith(fontSize: 14)),
          ]),
        ]),
      ),
    );
  }

  // Inline scroll-wheel for the active From/To field (no dial popup).
  Widget _wheel() {
    final editingFrom = _picking == 'from';
    final t = editingFrom ? _start : _end;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      height: 168,
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: CupertinoTheme(
        data: CupertinoThemeData(
          textTheme: CupertinoTextThemeData(
            dateTimePickerTextStyle: AppText.bodyStrong().copyWith(fontSize: 20),
          ),
        ),
        child: CupertinoDatePicker(
          key: ValueKey(_picking), // rebuild the wheel when switching fields
          mode: CupertinoDatePickerMode.time,
          minuteInterval: 5,
          use24hFormat: false,
          initialDateTime: DateTime(2020, 1, 1, t.hour, t.minute - (t.minute % 5)),
          onDateTimeChanged: (dt) => setState(() {
            final tod = TimeOfDay(hour: dt.hour, minute: dt.minute);
            if (editingFrom) {
              _start = tod;
            } else {
              _end = tod;
            }
          }),
        ),
      ),
    );
  }
}

/// Expanding-ring radar with the player's initials on the center puck.
class _Radar extends StatefulWidget {
  final String initials;
  const _Radar({required this.initials});
  @override
  State<_Radar> createState() => _RadarState();
}

class _RadarState extends State<_Radar> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 116, height: 116,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, __) {
            Widget ring(double t) {
              final v = t % 1.0;
              return Opacity(
                opacity: (0.7 * (1 - v)).clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: 0.42 + v * 0.9,
                  child: Container(
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.primary, width: 2)),
                  ),
                ),
              );
            }

            return Stack(alignment: Alignment.center, children: [
              Container(
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withValues(alpha: 0.12), width: 2)),
              ),
              ring(_c.value),
              ring(_c.value + 0.5),
              Container(
                width: 54, height: 54,
                alignment: Alignment.center,
                decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.primary),
                child: Text(widget.initials,
                    style: AppText.stat(17, AppColors.primaryInk)),
              ),
            ]);
          },
        ),
      );
}

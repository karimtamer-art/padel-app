import 'dart:async';
import 'package:flutter/material.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/screen_bar.dart';
import 'package:padel_clay/backend/services/match_service.dart';
import 'package:padel_clay/backend/models/ranking_scale.dart' show RankingScale;
import 'package:padel_clay/backend/models/matchmaking_config.dart';
import '../detail/match_detail_screen.dart';

/// Matchmaking (video-game style): the engine surfaces ONE band candidate at a
/// time. On open we drop into a "searching" radar, poll the band-gatekept
/// `mm_candidates` RPC, and when a candidate appears show a "Match found" card
/// with a 2:00 confirm countdown → Accept (race-safe `mm_accept`) or Decline
/// (skip it, keep searching). There is no public browse — only your band.
class FindMatchScreen extends StatefulWidget {
  /// The player's level chip for the search criteria row (e.g. "Div B").
  final String levelLabel;
  const FindMatchScreen({super.key, this.levelLabel = 'Your level'});
  @override
  State<FindMatchScreen> createState() => _FindMatchScreenState();
}

enum _MMPhase { searching, found, joining }

class _FindMatchScreenState extends State<FindMatchScreen> {
  _MMPhase _phase = _MMPhase.searching;
  Map<String, dynamic>? _candidate;
  final Set<String> _declined = {};
  int _elapsed = 0; // seconds spent searching
  int _confirmLeft = 0; // seconds left to accept the surfaced candidate
  Timer? _poll;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
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
    final rows = await MatchService.fetchBandCandidates(limit: 10);
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
        _decline(); // ran out of time → skip and keep looking
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
    _tick?.cancel();
    setState(() => _phase = _MMPhase.joining);
    final id = c['match_id'] as String;
    final err = await MatchService.acceptCandidate(id);
    if (!mounted) return;
    if (err != null) {
      // e.g. someone else took the last slot → skip this one, keep searching.
      _declined.add(id);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.danger,
          content: Text(err)));
      _startSearch();
      return;
    }
    // Locked in — open the lobby, then leave matchmaking.
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => MatchDetailScreen(matchId: id)));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(children: [
        ScreenBar(
          title: 'Find a Match',
          big: true,
          onBack: () => Navigator.pop(context),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 4, AppSpacing.screen, 24),
            child: Center(
              child: switch (_phase) {
                _MMPhase.searching => _searchingCard(),
                _MMPhase.found => _foundCard(),
                _MMPhase.joining => _joiningCard(),
              },
            ),
          ),
        ),
      ]),
    );
  }

  BoxDecoration get _heroDeco => BoxDecoration(
        borderRadius: AppRadius.cardR,
        gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.hero, AppColors.hero2]),
        boxShadow: kCardShadow,
      );

  // ── State 4: searching ──
  Widget _searchingCard() {
    final widening = _elapsed >= 15;
    return Container(
      width: double.infinity,
      decoration: _heroDeco,
      clipBehavior: Clip.antiAlias,
      child: Stack(children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -0.7),
                radius: 1.0,
                colors: [AppColors.primary.withValues(alpha: 0.22), Colors.transparent],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 26),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
              decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(999)),
              child: Text('QUICK MATCH',
                  style: AppText.tag(AppColors.heroFaint)
                      .copyWith(fontSize: 10.5, letterSpacing: 1)),
            ),
            const SizedBox(height: 22),
            const _Radar(),
            const SizedBox(height: 22),
            Text('Finding your match…',
                style: AppText.stat(20, AppColors.heroInk).copyWith(letterSpacing: -0.3)),
            const SizedBox(height: 6),
            Text(
                widening
                    ? 'Widening your search — pairing you with the closest player available.'
                    : 'Pairing you with a player near your level, in your city, free soon.',
                textAlign: TextAlign.center,
                style: AppText.small(AppColors.heroFaint).copyWith(fontSize: 12.5, height: 1.5)),
            const SizedBox(height: 20),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _criteria(Icons.military_tech_rounded, 'LEVEL', widget.levelLabel),
              _criteria(Icons.place_rounded, 'RANGE', 'Your city'),
              _criteria(Icons.schedule_rounded, 'WHEN', 'Next ${MatchmakingConfig.timeWindowHours}h'),
            ]),
            const SizedBox(height: 20),
            Text('Searching ${_elapsed}s',
                style: AppText.tag(AppColors.heroFaint).copyWith(fontSize: 11)),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: AppButton('Cancel search',
                  height: 46,
                  variant: AppBtnVariant.ghost,
                  onPressed: () => Navigator.pop(context)),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _criteria(IconData icon, String label, String value) => Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 6),
          decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(12)),
          child: Column(children: [
            Icon(icon, size: 16, color: AppColors.gold),
            const SizedBox(height: 6),
            Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.bodyStrong(AppColors.heroInk).copyWith(fontSize: 12.5)),
            const SizedBox(height: 2),
            Text(label,
                style: AppText.tag(AppColors.heroFaint).copyWith(fontSize: 9, letterSpacing: 0.5)),
          ]),
        ),
      );

  // ── State 5: match found ──
  Widget _foundCard() {
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
    final when = _fmtTime(c['scheduled_at'] as String?);
    final mm = '${_confirmLeft ~/ 60}:${(_confirmLeft % 60).toString().padLeft(2, '0')}';

    return Container(
      width: double.infinity,
      decoration: _heroDeco,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const AppTag('Match Found', color: AppColors.success, solid: true),
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.timer_outlined, size: 14, color: AppColors.gold),
              const SizedBox(width: 5),
              Text('Confirm in $mm',
                  style: AppText.bodyStrong(AppColors.gold).copyWith(fontSize: 12.5)),
            ]),
          ]),
          const SizedBox(height: 18),
          // Opponent
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(14)),
            child: Row(children: [
              Container(
                width: 52, height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.gold.withValues(alpha: 0.28)),
                child: Text(_initials(name),
                    style: AppText.stat(18, const Color(0xFFF0D9A4))),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(
                      child: Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.bodyStrong(AppColors.heroInk).copyWith(fontSize: 16)),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                          color: AppColors.primary,
                          borderRadius: BorderRadius.circular(6)),
                      child: Text('DIV ${div.key}',
                          style: AppText.tag(AppColors.primaryInk).copyWith(fontSize: 9.5)),
                    ),
                  ]),
                  const SizedBox(height: 3),
                  Text('Lv ${RankingScale.fmtQuarter(level)} · $pct% level match',
                      style: AppText.small(AppColors.heroFaint).copyWith(fontSize: 12)),
                  const SizedBox(height: 7),
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
          _line(Icons.place_outlined, venue),
          const SizedBox(height: 7),
          _line(Icons.schedule_rounded, '$when · Doubles'),
          const SizedBox(height: 18),
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
        ]),
      ),
    );
  }

  Widget _line(IconData icon, String text) => Row(children: [
        Icon(icon, size: 15, color: AppColors.heroFaint),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.small(AppColors.heroFaint).copyWith(fontSize: 13)),
        ),
      ]);

  // ── joining ──
  Widget _joiningCard() => Container(
        width: double.infinity,
        decoration: _heroDeco,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 48),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(
                width: 44, height: 44,
                child: CircularProgressIndicator(strokeWidth: 3.5, color: AppColors.heroInk)),
            const SizedBox(height: 18),
            Text('Locking it in…',
                style: AppText.bodyStrong(AppColors.heroInk).copyWith(fontSize: 16)),
          ]),
        ),
      );

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return 'P';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  static String _fmtTime(String? iso) {
    if (iso == null) return 'Time to be set';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return 'Time to be set';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(dt.year, dt.month, dt.day);
    final diff = day.difference(today).inDays;
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final d = diff == 0 ? 'Today' : diff == 1 ? 'Tomorrow' : '${months[dt.month - 1]} ${dt.day}';
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$d, $h:$mm ${dt.hour < 12 ? 'AM' : 'PM'}';
  }
}

/// Expanding-ring radar pulse behind a center puck.
class _Radar extends StatefulWidget {
  const _Radar();
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
        width: 108, height: 108,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, __) {
            Widget ring(double t) {
              final v = t % 1.0;
              return Opacity(
                opacity: (0.7 * (1 - v)).clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: 0.45 + v * 0.85,
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
                width: 50, height: 50,
                decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.primary),
                child: const Icon(Icons.sports_tennis_rounded, size: 24, color: AppColors.primaryInk),
              ),
            ]);
          },
        ),
      );
}

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/screen_bar.dart';
import 'package:padel_clay/frontend/widgets/padel_refresh.dart';
import 'package:padel_clay/frontend/widgets/auto_refresh.dart';
import 'package:padel_clay/backend/services/tournament_service.dart';
import 'package:padel_clay/backend/models/ranking_scale.dart' show RankingScale;
import 'tournament_detail_screen.dart';

class TournamentsScreen extends StatefulWidget {
  const TournamentsScreen({super.key});
  @override
  State<TournamentsScreen> createState() => _TournamentsScreenState();
}

class _TournamentsScreenState extends State<TournamentsScreen> with AutoRefresh<TournamentsScreen> {
  List<Map<String, dynamic>> _tournaments = [];
  bool _loading = true;

  String? get _uid => Supabase.instance.client.auth.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _load();
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
    bool done(Map<String, dynamic> t) {
      final entries = ((t['tournament_entries'] as List?) ?? const [])
          .where((e) => e['status'] != 'withdrawn')
          .length;
      final ds = TournamentService.tournamentStatus(t, entries);
      return ds == 'completed' || ds == 'cancelled';
    }

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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const ScreenBar(title: 'Compete', big: true),
        Expanded(
          child: PadelRefresh(
            onRefresh: _load,
            slivers: _tournamentSlivers(),
          ),
        ),
      ],
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
                  strokeWidth: 2.4, color: AppColors.primary)),
        ),
      ];
    }
    if (_tournaments.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _emptyList(Icons.emoji_events_outlined, 'No tournaments yet',
              'Open and upcoming tournaments will appear here once they are created.'),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.screen, 4, AppSpacing.screen, 120),
        sliver: SliverList(
          delegate: SliverChildListDelegate(
            [for (final t in _tournaments) _tournamentCard(t)],
          ),
        ),
      ),
    ];
  }

  Widget _tournamentCard(Map<String, dynamic> t) {
    final entries = ((t['tournament_entries'] as List?) ?? const [])
        .where((e) => e['status'] != 'withdrawn')
        .toList();
    final registered =
        TournamentService.isParticipant(t['tournament_entries'] as List?, _uid);
    final ds = TournamentService.tournamentStatus(t, entries.length);
    final sc = switch (ds) {
      'open' || 'live' => AppColors.success,
      'full' || 'postponed' || 'upcoming' => AppColors.gold,
      _ => AppColors.inkSoft,
    };
    final statusLabel = switch (ds) {
      'open' => 'Open',
      'live' => 'Live',
      'full' => 'Full',
      'closed' => 'Registration closed',
      'upcoming' => 'Upcoming',
      'completed' => 'Completed',
      'cancelled' => 'Cancelled',
      'postponed' => 'Postponed',
      _ => ds,
    };
    final cap = (t['capacity'] as num?)?.toInt() ?? 0;
    final remaining = cap > 0 ? (cap - entries.length).clamp(0, cap) : null;
    final prize = (t['prize_pool'] as num?)?.toInt() ?? 0;
    final fee = (t['entry_fee'] as num?)?.toInt() ?? 0;
    final minElo = (t['min_elo'] as num?)?.toInt() ?? 0;
    final maxElo = (t['max_elo'] as num?)?.toInt();
    final venue = (t['venue_name'] as String?) ?? '';
    final canRegister = !registered && (ds == 'open' || ds == 'postponed');

    Future<void> open() async {
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => TournamentDetailScreen(tournamentId: t['id'] as String)));
      _load();
    }

    final isCommunity = t['organizer_id'] != null;
    final sponsored = t['sponsored'] == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Stack(clipBehavior: Clip.none, children: [
      AppCard(
        onTap: open,
        borderColor: isCommunity ? AppColors.gold : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.emoji_events_rounded, size: 18, color: AppColors.gold),
            const SizedBox(width: 7),
            Expanded(
              child: Text((t['name'] as String?) ?? 'Tournament',
                  style: AppText.bodyStrong().copyWith(fontSize: 15.5),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            AppTag(statusLabel, color: sc),
          ]),
          const SizedBox(height: 9),
          Row(children: [
            const Icon(Icons.calendar_today_rounded, size: 13, color: AppColors.inkFaint),
            const SizedBox(width: 5),
            Text(_fmtRange(t['start_date'] as String?, t['end_date'] as String?),
                style: AppText.small().copyWith(fontSize: 12.5)),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            if (_catLabel(t['category'] as String?) != null)
              AppTag(_catLabel(t['category'] as String?)!, color: AppColors.accent),
            if (venue.isNotEmpty) AppTag(venue),
            if (minElo > 0 && maxElo != null && maxElo > 0)
              AppTag('Lv ${RankingScale.fmtLevel(RankingScale.levelFromElo(minElo))}–${RankingScale.fmtLevel(RankingScale.levelFromElo(maxElo))}')
            else if (minElo > 0)
              AppTag('Lv ${RankingScale.fmtLevel(RankingScale.levelFromElo(minElo))}+'),
            if (registered) const AppTag('Registered', color: AppColors.primary),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(prize > 0 ? _egp(prize) : (fee > 0 ? _egp(fee) : 'Free'),
                  style: AppText.stat(18, AppColors.primary)),
              Text(prize > 0 ? 'Prize Pool' : 'Entry / Pair',
                  style: AppText.small().copyWith(fontSize: 11)),
            ]),
            const SizedBox(width: 18),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(remaining != null ? '$remaining left' : '${entries.length} pairs',
                  style: AppText.stat(16,
                      remaining != null && remaining <= cap * 0.25
                          ? AppColors.success
                          : AppColors.ink)),
              Text(remaining != null ? 'of $cap spots' : 'registered',
                  style: AppText.small().copyWith(fontSize: 11)),
            ]),
            const Spacer(),
            AppButton(canRegister ? 'Register' : 'View',
                height: 42,
                variant: canRegister ? AppBtnVariant.solid : AppBtnVariant.outline,
                onPressed: open),
          ]),
        ]),
      ),
      // Blue 3D "SPONSORED" tab overhanging the right edge, vertically centered.
      if (sponsored)
        Positioned(
          right: -10,
          top: 0,
          bottom: 0,
          child: IgnorePointer(
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(7),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF6FA2F7), Color(0xFF3A6FDD), Color(0xFF2450B8)],
                    stops: [0.0, 0.45, 1.0],
                  ),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
                  boxShadow: [
                    BoxShadow(
                        color: const Color(0xFF18347C).withValues(alpha: 0.7),
                        blurRadius: 14,
                        offset: const Offset(0, 7)),
                    BoxShadow(
                        color: const Color(0xFF18347C).withValues(alpha: 0.35),
                        blurRadius: 3,
                        offset: const Offset(0, 2)),
                  ],
                ),
                child: Text('SPONSORED',
                    style: AppText.tag(Colors.white).copyWith(
                        fontSize: 8.5, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  // Short tag for a gender category, or null for 'open'/unset (no tag).
  static String? _catLabel(String? c) => switch (c) {
        'mens' => "Men's",
        'womens' => "Women's",
        'mixed' => 'Mixed',
        _ => null,
      };

  static String _egp(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return 'EGP $buf';
  }

  static String _fmtRange(String? startIso, String? endIso) {
    final s = startIso == null ? null : DateTime.tryParse(startIso)?.toLocal();
    if (s == null) return 'TBD';
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final e = endIso == null ? null : DateTime.tryParse(endIso)?.toLocal();
    if (e == null || (e.year == s.year && e.month == s.month && e.day == s.day)) {
      return '${months[s.month - 1]} ${s.day}, ${s.year}';
    }
    if (e.year == s.year && e.month == s.month) {
      return '${months[s.month - 1]} ${s.day} – ${e.day}';
    }
    return '${months[s.month - 1]} ${s.day} – ${months[e.month - 1]} ${e.day}';
  }

  // Non-scrolling empty body — fills the SliverFillRemaining so pull-to-refresh
  // stays on the outer scroll view.
  Widget _emptyList(IconData icon, String title, String sub) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 56, height: 56, alignment: Alignment.center,
            decoration: const BoxDecoration(
                color: AppColors.field, shape: BoxShape.circle),
            child: Icon(icon, size: 28, color: AppColors.inkFaint),
          ),
          const SizedBox(height: 14),
          Text(title, style: AppText.cardTitle().copyWith(fontSize: 17)),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(sub,
                textAlign: TextAlign.center,
                style: AppText.body(AppColors.inkSoft)
                    .copyWith(fontSize: 13.5, height: 1.5)),
          ),
        ]),
      );
}

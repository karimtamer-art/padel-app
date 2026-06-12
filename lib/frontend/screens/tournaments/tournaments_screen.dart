import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/screen_bar.dart';
import 'package:padel_clay/backend/services/tournament_service.dart';
import 'package:padel_clay/backend/models/ranking_scale.dart';
import 'tournament_detail_screen.dart';

/// Rankings (live podium + leaderboard) and Tournaments (live list).
class TournamentsScreen extends StatefulWidget {
  const TournamentsScreen({super.key});
  @override
  State<TournamentsScreen> createState() => _TournamentsScreenState();
}

class _TournamentsScreenState extends State<TournamentsScreen> {
  int _tab = 0; // 0 rankings, 1 tournaments
  List<Map<String, dynamic>> _leaderboard = [];
  List<Map<String, dynamic>> _tournaments = [];
  bool _loading = true;

  String? get _uid => Supabase.instance.client.auth.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      TournamentService.fetchLeaderboard(),
      TournamentService.fetchTournaments(),
    ]);
    if (!mounted) return;
    setState(() {
      _leaderboard = results[0];
      _tournaments = results[1];
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const ScreenBar(title: 'Compete', big: true),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 4, AppSpacing.screen, 12),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: AppColors.field,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.line),
            ),
            child: Row(children: [
              _seg('Rankings', 0),
              _seg('Tournaments', 1),
            ]),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.primary,
            onRefresh: _load,
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: AppColors.primary))
                : _tab == 0
                    ? _rankings()
                    : _tournamentList(),
          ),
        ),
      ],
    );
  }

  Widget _seg(String label, int i) => Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _tab = i),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: _tab == i ? AppColors.surface : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
                boxShadow: _tab == i ? kCardShadow : null),
            child: Text(label,
                style: AppText.bodyStrong(_tab == i ? AppColors.ink : AppColors.inkSoft)
                    .copyWith(fontSize: 13)),
          ),
        ),
      );

  // ── Rankings ─────────────────────────────────────────────────────────────

  Widget _rankings() {
    if (_leaderboard.isEmpty) {
      return _emptyList(Icons.leaderboard_outlined, 'No ranked players yet',
          'Rankings appear once players complete competitive matches.');
    }
    final podium = _leaderboard.take(3).toList();
    final rest = _leaderboard.skip(3).toList();
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 120),
      children: [
        if (podium.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 8, AppSpacing.screen, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: podium.length > 1 ? _podium(podium[1], 2) : const SizedBox()),
                const SizedBox(width: 10),
                Expanded(child: _podium(podium[0], 1)),
                const SizedBox(width: 10),
                Expanded(child: podium.length > 2 ? _podium(podium[2], 3) : const SizedBox()),
              ],
            ),
          ),
        Padding(
          padding: AppSpacing.screenH,
          child: AppCard(
            padding: EdgeInsets.zero,
            child: Column(children: [
              for (int i = 0; i < rest.length; i++)
                _rankRow(rest[i], i + 4, divider: i > 0),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _podium(Map<String, dynamic> p, int place) {
    final name = (p['name'] as String?) ?? 'Player';
    final elo = (p['elo'] as num?)?.toInt() ?? 1000;
    final level = (p['level'] as num?)?.toDouble() ??
        RankingScale.levelFromElo(elo);
    final isMe = p['id'] == _uid;
    final color = switch (place) {
      1 => AppColors.gold,
      2 => AppColors.platinum,
      _ => AppColors.accent,
    };
    final initials = name.trim().split(RegExp(r'\s+')).take(2)
        .map((w) => w.isEmpty ? '' : w[0]).join().toUpperCase();
    return Container(
      padding: EdgeInsets.fromLTRB(8, place == 1 ? 18 : 12, 8, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isMe ? AppColors.primary : AppColors.line,
            width: isMe ? 1.5 : 1),
        boxShadow: kCardShadow,
      ),
      child: Column(children: [
        AppAvatar(initials.isEmpty ? 'P' : initials,
            size: place == 1 ? 52 : 42, color: color, ring: 2),
        const SizedBox(height: 7),
        Text('#$place', style: AppText.stat(14, color)),
        const SizedBox(height: 2),
        Text(name.split(' ').first,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: AppText.bodyStrong().copyWith(fontSize: 12.5)),
        Text('Lv ${RankingScale.fmtLevel(level)}',
            style: AppText.small().copyWith(fontSize: 11)),
      ]),
    );
  }

  Widget _rankRow(Map<String, dynamic> p, int rank, {bool divider = false}) {
    final name = (p['name'] as String?) ?? 'Player';
    final elo = (p['elo'] as num?)?.toInt() ?? 1000;
    final level = (p['level'] as num?)?.toDouble() ??
        RankingScale.levelFromElo(elo);
    final isMe = p['id'] == _uid;
    final initials = name.trim().split(RegExp(r'\s+')).take(2)
        .map((w) => w.isEmpty ? '' : w[0]).join().toUpperCase();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isMe ? AppColors.primary.withValues(alpha: 0.06) : null,
        border: divider ? const Border(top: BorderSide(color: AppColors.line)) : null,
      ),
      child: Row(children: [
        SizedBox(width: 30, child: Text('$rank', style: AppText.stat(14, AppColors.inkSoft))),
        AppAvatar(initials.isEmpty ? 'P' : initials, size: 34, ring: 1.5,
            color: isMe ? AppColors.primary : AppColors.gold),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(isMe ? '$name (You)' : name,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppText.bodyStrong().copyWith(fontSize: 13.5)),
            Text(
                '${RankingScale.divisionFor(level).name} · ${RankingScale.tierFor(level)}',
                style: AppText.small().copyWith(fontSize: 11)),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(RankingScale.fmtLevel(level), style: AppText.stat(15)),
          Text('$elo ELO',
              style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 9.5)),
        ]),
      ]),
    );
  }

  // ── Tournaments ──────────────────────────────────────────────────────────

  Widget _tournamentList() {
    if (_tournaments.isEmpty) {
      return _emptyList(Icons.emoji_events_outlined, 'No tournaments yet',
          'Open and upcoming tournaments will appear here once they are created.');
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 4, AppSpacing.screen, 120),
      children: [
        for (final t in _tournaments) _tournamentCard(t),
      ],
    );
  }

  Widget _tournamentCard(Map<String, dynamic> t) {
    final status = (t['status'] as String?) ?? 'upcoming';
    final entries = ((t['tournament_entries'] as List?) ?? const [])
        .where((e) => e['status'] != 'withdrawn')
        .toList();
    final cap = (t['capacity'] as num?)?.toInt() ?? 0;
    final fee = (t['entry_fee'] as num?)?.toInt() ?? 0;
    final registered = entries.any((e) => e['player_id'] == _uid);
    final full = cap > 0 && entries.length >= cap;
    final sc = full || status == 'completed'
        ? AppColors.inkSoft
        : status == 'open'
            ? AppColors.success
            : AppColors.gold;
    final statusLabel = full && status == 'open'
        ? 'Full'
        : status[0].toUpperCase() + status.substring(1).replaceAll('_', ' ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => TournamentDetailScreen(tournamentId: t['id'] as String)));
          _load();
        },
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            AppTag(statusLabel, color: sc),
            if (registered) ...[
              const SizedBox(width: 6),
              const AppTag('Registered', color: AppColors.primary),
            ],
            const Spacer(),
            Text(cap > 0 ? '${entries.length}/$cap' : '${entries.length}',
                style: AppText.stat(14)),
            const SizedBox(width: 3),
            Text('teams', style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 10)),
          ]),
          const SizedBox(height: 10),
          Text((t['name'] as String?) ?? 'Tournament',
              style: AppText.bodyStrong().copyWith(fontSize: 15),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 3),
          Text((t['venue_name'] as String?) ?? '—',
              style: AppText.small().copyWith(fontSize: 12.5)),
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.calendar_today_rounded, size: 13, color: AppColors.inkFaint),
            const SizedBox(width: 5),
            Text(_fmtDate(t['start_date'] as String?),
                style: AppText.small().copyWith(fontSize: 12)),
            const Spacer(),
            Text(fee > 0 ? 'EGP $fee entry' : 'Free entry',
                style: AppText.bodyStrong(AppColors.primary).copyWith(fontSize: 12.5)),
          ]),
        ]),
      ),
    );
  }

  static String _fmtDate(String? iso) {
    final dt = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return 'TBD';
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  Widget _emptyList(IconData icon, String title, String sub) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.16),
          Center(
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
          ),
        ],
      );
}

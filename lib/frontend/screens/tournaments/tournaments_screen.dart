import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/screen_bar.dart';
import 'package:padel_clay/backend/services/tournament_service.dart';
import 'tournament_detail_screen.dart';

class TournamentsScreen extends StatefulWidget {
  const TournamentsScreen({super.key});
  @override
  State<TournamentsScreen> createState() => _TournamentsScreenState();
}

class _TournamentsScreenState extends State<TournamentsScreen> {
  List<Map<String, dynamic>> _tournaments = [];
  bool _loading = true;

  String? get _uid => Supabase.instance.client.auth.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final tournaments = await TournamentService.fetchTournaments();
    if (!mounted) return;
    setState(() {
      _tournaments = tournaments;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const ScreenBar(title: 'Compete', big: true),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.primary,
            onRefresh: _load,
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: AppColors.primary))
                : _tournamentList(),
          ),
        ),
      ],
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
    final entries = ((t['tournament_entries'] as List?) ?? const [])
        .where((e) => e['status'] != 'withdrawn')
        .toList();
    final fee = (t['entry_fee'] as num?)?.toInt() ?? 0;
    final registered = entries.any((e) => e['player_id'] == _uid);
    final ds = TournamentService.tournamentStatus(t, entries.length);
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
            Text(((t['capacity'] as num?)?.toInt() ?? 0) > 0 ? '${entries.length}/${(t['capacity'] as num).toInt()}' : '${entries.length}',
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

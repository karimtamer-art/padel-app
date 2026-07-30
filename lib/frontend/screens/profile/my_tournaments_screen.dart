import 'package:flutter/material.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/backend/services/tournament_service.dart';
import '../tournaments/tournament_detail_screen.dart';
import 'settings_common.dart';

/// The user's tournament entries, live from `tournament_entries`.
class MyTournamentsScreen extends StatefulWidget {
  const MyTournamentsScreen({super.key});
  @override
  State<MyTournamentsScreen> createState() => _MyTournamentsScreenState();
}

class _MyTournamentsScreenState extends State<MyTournamentsScreen> {
  int _tab = 0; // 0 upcoming · 1 past
  List<Map<String, dynamic>> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await TournamentService.fetchMyEntries();
    if (!mounted) return;
    setState(() {
      _entries = rows;
      _loading = false;
    });
  }

  bool _isPast(Map<String, dynamic> e) {
    final t = (e['tournaments'] as Map?)?.cast<String, dynamic>() ?? {};
    final ds = TournamentService.tournamentStatus(t, 0);
    return ds == 'completed' || ds == 'cancelled';
  }

  @override
  Widget build(BuildContext context) {
    final upcoming = _entries.where((e) => !_isPast(e)).toList();
    final past = _entries.where(_isPast).toList();
    final shown = _tab == 0 ? upcoming : past;
    return SettingsScaffold(
      title: 'My Tournaments',
      children: [
        _segmented(),
        const SizedBox(height: 18),
        if (_loading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(28),
              child: CircularProgressIndicator(strokeWidth: 2.4, color: AppColors.primary),
            ),
          )
        else if (shown.isEmpty)
          _empty()
        else
          for (final e in shown) _entryCard(e),
      ],
    );
  }

  Widget _segmented() {
    Widget tab(String label, int i) {
      final on = _tab == i;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _tab = i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(vertical: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? AppColors.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
              boxShadow: on ? kCardShadow : null,
            ),
            child: Text(label,
                style: AppText.bodyStrong(on ? AppColors.ink : AppColors.inkSoft)
                    .copyWith(fontSize: 13.5)),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.field,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(children: [tab('Upcoming', 0), tab('Past', 1)]),
    );
  }

  Widget _empty() => Padding(
        padding: const EdgeInsets.only(top: 38),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 56, height: 56, alignment: Alignment.center,
              decoration: const BoxDecoration(
                  color: AppColors.field, shape: BoxShape.circle),
              child: const Icon(Icons.emoji_events_outlined,
                  size: 28, color: AppColors.inkFaint),
            ),
            const SizedBox(height: 14),
            Text(_tab == 0 ? 'No upcoming tournaments' : 'No past tournaments',
                style: AppText.cardTitle().copyWith(fontSize: 16)),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 36),
              child: Text(
                  _tab == 0
                      ? 'Browse the Tournaments tab and register to see your entries here.'
                      : 'Tournaments you played in will show up here.',
                  textAlign: TextAlign.center,
                  style: AppText.body(AppColors.inkSoft)
                      .copyWith(fontSize: 13, height: 1.5)),
            ),
          ]),
        ),
      );

  Widget _entryCard(Map<String, dynamic> e) {
    final t = ((e['tournaments'] as Map?)?.cast<String, dynamic>()) ?? {};
    final withdrawn = e['status'] == 'withdrawn';
    final ds = TournamentService.tournamentStatus(t, 0);
    final sc = withdrawn
        ? AppColors.inkFaint
        : switch (ds) {
            'open' || 'live' => AppColors.success,
            'full' || 'postponed' || 'upcoming' => AppColors.gold,
            _ => AppColors.inkSoft,
          };
    final label = withdrawn
        ? 'Withdrawn'
        : switch (ds) {
            'open' => 'Open',
            'live' => 'Live',
            'full' => 'Full',
            'upcoming' => 'Upcoming',
            'completed' => 'Completed',
            'cancelled' => 'Cancelled',
            'postponed' => 'Postponed',
            _ => ds,
          };
    final partner = e['partner_name'] as String?;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        onTap: () async {
          final id = t['id'] as String?;
          if (id == null) return;
          await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => TournamentDetailScreen(tournamentId: id)));
          _load();
        },
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            AppTag(label, color: sc),
            const Spacer(),
            const Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.inkFaint),
          ]),
          const SizedBox(height: 9),
          Text((t['name'] as String?) ?? 'Tournament',
              style: AppText.bodyStrong().copyWith(fontSize: 14.5),
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
            if (partner != null && partner.isNotEmpty) ...[
              const Spacer(),
              const Icon(Icons.group_outlined, size: 13, color: AppColors.inkFaint),
              const SizedBox(width: 5),
              Flexible(
                child: Text('With $partner',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: AppText.small().copyWith(fontSize: 12)),
              ),
            ],
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
}

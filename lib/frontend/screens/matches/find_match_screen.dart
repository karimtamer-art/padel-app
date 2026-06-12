import 'package:flutter/material.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/screen_bar.dart';
import 'package:padel_clay/backend/services/match_service.dart';
import 'package:padel_clay/backend/models/ranking_scale.dart' show RankingScale;
import '../detail/match_detail_screen.dart';

/// Browse open matches (live), filter by type, tap to view the lobby,
/// or join straight from the list.
class FindMatchScreen extends StatefulWidget {
  const FindMatchScreen({super.key});
  @override
  State<FindMatchScreen> createState() => _FindMatchScreenState();
}

class _FindMatchScreenState extends State<FindMatchScreen> {
  List<Map<String, dynamic>> _matches = [];
  bool _loading = true;
  int _filter = 0; // 0 all, 1 competitive, 2 casual
  String? _joining;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rows = await MatchService.fetchOpenMatches();
    if (!mounted) return;
    setState(() {
      _matches = rows;
      _loading = false;
    });
  }

  List<Map<String, dynamic>> get _filtered => switch (_filter) {
        1 => _matches.where((m) => m['match_type'] == 'ranked').toList(),
        2 => _matches.where((m) => m['match_type'] != 'ranked').toList(),
        _ => _matches,
      };

  Future<void> _join(Map<String, dynamic> m) async {
    final id = m['id'] as String;
    setState(() => _joining = id);
    final err = await MatchService.joinMatch(id);
    if (!mounted) return;
    setState(() => _joining = null);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.danger,
          content: Text(err)));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => MatchDetailScreen(matchId: id)));
    _load();
  }

  Future<void> _open(Map<String, dynamic> m) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => MatchDetailScreen(matchId: m['id'] as String)));
    _load();
  }

  static String _fmtTime(String? iso) {
    if (iso == null) return '—';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '—';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(dt.year, dt.month, dt.day);
    final diff = day.difference(today).inDays;
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final d = diff == 0 ? 'Today' : diff == 1 ? 'Tomorrow' : '${months[dt.month - 1]} ${dt.day}';
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$d · $h:$mm ${dt.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          ScreenBar(
            title: 'Find a Match',
            big: true,
            onBack: () => Navigator.pop(context),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 6, AppSpacing.screen, 12),
            child: Row(children: [
              _chip('All', 0),
              const SizedBox(width: 8),
              _chip('Competitive', 1),
              const SizedBox(width: 8),
              _chip('Casual', 2),
            ]),
          ),
          Expanded(
            child: RefreshIndicator(
              color: AppColors.primary,
              onRefresh: _load,
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(
                          strokeWidth: 2.4, color: AppColors.primary))
                  : _filtered.isEmpty
                      ? _empty()
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(
                              AppSpacing.screen, 0, AppSpacing.screen, 24),
                          children: [
                            for (final m in _filtered) _matchCard(m),
                          ],
                        ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, int i) {
    final on = _filter == i;
    return GestureDetector(
      onTap: () => setState(() => _filter = i),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: on ? AppColors.primary : AppColors.field,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: on ? AppColors.primary : AppColors.line),
        ),
        child: Text(label,
            style: AppText.bodyStrong(on ? AppColors.primaryInk : AppColors.inkSoft)
                .copyWith(fontSize: 12.5)),
      ),
    );
  }

  Widget _empty() => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.18),
          Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 56, height: 56, alignment: Alignment.center,
                decoration: const BoxDecoration(
                    color: AppColors.field, shape: BoxShape.circle),
                child: const Icon(Icons.sports_tennis_rounded,
                    size: 26, color: AppColors.inkFaint),
              ),
              const SizedBox(height: 14),
              Text('No open matches right now',
                  style: AppText.cardTitle().copyWith(fontSize: 17)),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                    'Pull to refresh, or create your own match and let players come to you.',
                    textAlign: TextAlign.center,
                    style: AppText.body(AppColors.inkSoft)
                        .copyWith(fontSize: 13.5, height: 1.5)),
              ),
            ]),
          ),
        ],
      );

  Widget _matchCard(Map<String, dynamic> m) {
    final court = m['courts'] as Map?;
    final courtName = court?['venue_name'] as String? ??
        court?['name'] as String? ?? 'Court TBD';
    final players = (m['match_players'] as List?) ?? const [];
    final isRanked = m['match_type'] == 'ranked';
    final minElo = (m['min_elo'] as num?)?.toInt() ?? 0;
    final id = m['id'] as String;
    final names = players
        .map((p) => ((p['profiles'] as Map?)?['name'] as String? ?? 'Player')
            .split(' ')
            .first)
        .join(', ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        onTap: () => _open(m),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            AppTag(isRanked ? 'Ranked' : 'Casual',
                color: isRanked ? AppColors.warn : AppColors.primary),
            if (isRanked && minElo > 0) ...[
              const SizedBox(width: 6),
              AppTag(
                  'Lv ${RankingScale.fmtLevel(RankingScale.levelFromElo(minElo))}+',
                  color: AppColors.inkSoft),
            ],
            const Spacer(),
            Text('${players.length}/4',
                style: AppText.stat(15, AppColors.ink)),
            const SizedBox(width: 3),
            Text('players', style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 10)),
          ]),
          const SizedBox(height: 10),
          Text(courtName,
              style: AppText.bodyStrong().copyWith(fontSize: 14.5),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 3),
          Text(_fmtTime(m['scheduled_at'] as String?),
              style: AppText.small().copyWith(fontSize: 12.5)),
          if (names.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text('With $names',
                style: AppText.small().copyWith(fontSize: 12),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: AppButton('View Lobby', full: true, height: 42,
                  variant: AppBtnVariant.outline, onPressed: () => _open(m)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: AppButton(_joining == id ? 'Joining…' : 'Join',
                  full: true, height: 42, icon: Icons.add_rounded,
                  onPressed: _joining == null ? () => _join(m) : null),
            ),
          ]),
        ]),
      ),
    );
  }
}

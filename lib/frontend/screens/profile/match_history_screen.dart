import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'settings_common.dart';

class _Match {
  final bool won;
  final String opp, score, date, type, court;
  final int elo; // signed delta
  const _Match(this.won, this.opp, this.score, this.date, this.type, this.court, this.elo);
}

class MatchHistoryScreen extends StatefulWidget {
  const MatchHistoryScreen({super.key});
  @override
  State<MatchHistoryScreen> createState() => _MatchHistoryScreenState();
}

class _MatchHistoryScreenState extends State<MatchHistoryScreen> {
  int _filter = 0; // 0 All · 1 Wins · 2 Losses · 3 Competitive
  static const _filters = ['All', 'Wins', 'Losses', 'Competitive'];

  List<_Match> _all = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = Supabase.instance.client;
    final uid = db.auth.currentUser?.id;
    if (uid == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final rows = await db
          .from('match_players')
          .select('''
            team, elo_before, elo_after,
            matches!inner(
              id, status, match_type, scheduled_at, winner_team,
              score_team_a, score_team_b,
              courts(name, venue_name),
              match_players(player_id, team, profiles(name))
            )
          ''')
          .eq('player_id', uid)
          .order('created_at', ascending: false)
          .limit(100);
      final list = <_Match>[];
      const months = ['Jan','Feb','Mar','Apr','May','Jun',
                      'Jul','Aug','Sep','Oct','Nov','Dec'];
      for (final r in List<Map<String, dynamic>>.from(rows as List)) {
        final m = r['matches'] as Map?;
        if (m == null || m['status'] != 'completed' || m['winner_team'] == null) {
          continue;
        }
        final myTeam = r['team'] as String?;
        final won = myTeam == m['winner_team'];
        // opponents = first players not on my team
        final mps = (m['match_players'] as List?) ?? const [];
        final opps = mps
            .where((p) => p['team'] != myTeam && p['player_id'] != uid)
            .map((p) => ((p['profiles'] as Map?)?['name'] as String? ?? 'Opponent')
                .split(' ')
                .first)
            .toList();
        final opp = opps.isEmpty ? 'Opponents' : opps.join(' & ');
        final sa = m['score_team_a'] as String?;
        final sb = m['score_team_b'] as String?;
        String score = '—';
        if (sa != null && sb != null) {
          final a = sa.split(',');
          final b = sb.split(',');
          final mine = myTeam == 'a' ? a : b;
          final theirs = myTeam == 'a' ? b : a;
          score = [
            for (int i = 0; i < mine.length && i < theirs.length; i++)
              '${mine[i].trim()}-${theirs[i].trim()}'
          ].join(', ');
        }
        final dt = DateTime.tryParse(m['scheduled_at'] as String? ?? '')?.toLocal();
        final date = dt == null ? '—' : '${months[dt.month - 1]} ${dt.day}';
        final court = (m['courts'] as Map?)?['venue_name'] as String? ??
            (m['courts'] as Map?)?['name'] as String? ?? '—';
        final before = (r['elo_before'] as num?)?.toInt();
        final after = (r['elo_after'] as num?)?.toInt();
        final delta = (before != null && after != null) ? after - before : 0;
        list.add(_Match(won, opp, score, date,
            m['match_type'] == 'ranked' ? 'Competitive' : 'Casual', court, delta));
      }
      if (mounted) setState(() { _all = list; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<_Match> get _list {
    switch (_filter) {
      case 1:
        return _all.where((m) => m.won).toList();
      case 2:
        return _all.where((m) => !m.won).toList();
      case 3:
        return _all.where((m) => m.type == 'Competitive').toList();
      default:
        return _all;
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    final wins = _all.where((m) => m.won).length;
    if (_loading) {
      return const SettingsScaffold(
        title: 'Match History',
        children: [
          Padding(
            padding: EdgeInsets.only(top: 60),
            child: Center(
                child: CircularProgressIndicator(
                    strokeWidth: 2.4, color: AppColors.primary)),
          ),
        ],
      );
    }
    return SettingsScaffold(
      title: 'Match History',
      children: [
        // summary strip
        AppCard(
          padding: EdgeInsets.zero,
          child: Row(children: [
            _stat('${_all.length}', 'Matches', null),
            _stat('$wins', 'Wins', AppColors.success),
            _stat('${_all.length - wins}', 'Losses', AppColors.danger),
            _stat(_all.isEmpty ? '—' : '${((wins / _all.length) * 100).round()}%',
                'Win Rate', AppColors.primary),
          ]),
        ),
        const SizedBox(height: 16),
        // filter chips
        SizedBox(
          height: 34,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _filters.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final on = _filter == i;
              return GestureDetector(
                onTap: () => setState(() => _filter = i),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: on ? AppColors.primary : AppColors.field,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: on ? AppColors.primary : AppColors.line),
                  ),
                  child: Text(_filters[i],
                      style: AppText.bodyStrong(on ? AppColors.primaryInk : AppColors.inkSoft)
                          .copyWith(fontSize: 13)),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        for (final m in list) ...[_MatchRow(m), const SizedBox(height: 10)],
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 30),
            child: Text('No matches in this filter.',
                textAlign: TextAlign.center,
                style: AppText.small(AppColors.inkFaint).copyWith(fontSize: 13)),
          ),
      ],
    );
  }

  Widget _stat(String value, String label, Color? c) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            border: label == 'Matches'
                ? null
                : const Border(left: BorderSide(color: AppColors.line)),
          ),
          child: Column(children: [
            Text(value, style: AppText.stat(18, c ?? AppColors.ink)),
            const SizedBox(height: 2),
            Text(label, style: AppText.tag().copyWith(fontSize: 10)),
          ]),
        ),
      );
}

class _MatchRow extends StatelessWidget {
  final _Match m;
  const _MatchRow(this.m);
  @override
  Widget build(BuildContext context) {
    final wc = m.won ? AppColors.success : AppColors.danger;
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(children: [
        Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: wc.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(m.won ? 'W' : 'L', style: AppText.stat(15, wc)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('vs ${m.opp}', style: AppText.bodyStrong().copyWith(fontSize: 14.5))),
            ]),
            const SizedBox(height: 3),
            Text('${m.type} · ${m.court} · ${m.date}',
                style: AppText.small().copyWith(fontSize: 11.5)),
          ]),
        ),
        const SizedBox(width: 10),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(m.score, style: AppText.bodyStrong().copyWith(fontSize: 13.5)),
          const SizedBox(height: 3),
          if (m.elo != 0)
            Text(m.elo > 0 ? '+${m.elo} ELO' : '${m.elo} ELO',
                style: AppText.tag(m.elo > 0 ? AppColors.success : AppColors.danger)
                    .copyWith(fontSize: 10.5, letterSpacing: 0))
          else
            Text('Casual', style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 10.5, letterSpacing: 0)),
        ]),
      ]),
    );
  }
}

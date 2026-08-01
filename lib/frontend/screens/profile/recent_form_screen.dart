import 'package:flutter/material.dart';

import '../../../backend/services/profile_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_text.dart';

/// "Recap" behind the Home Recent Form strip — the same matches, with the
/// opponents, the score from your side and what each one did to your rating.
class RecentFormScreen extends StatefulWidget {
  /// Passed from Home so the recap opens already populated.
  final List<FormMatch>? initial;
  final int limit;
  const RecentFormScreen({super.key, this.initial, this.limit = 6});

  @override
  State<RecentFormScreen> createState() => _RecentFormScreenState();
}

class _RecentFormScreenState extends State<RecentFormScreen> {
  List<FormMatch> _matches = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _matches = widget.initial ?? const [];
    _loading = widget.initial == null;
    _load();
  }

  Future<void> _load() async {
    final m = await ProfileService.recentForm(limit: widget.limit);
    if (!mounted) return;
    setState(() {
      if (m.isNotEmpty || _matches.isEmpty) _matches = m;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final wins = _matches.where((m) => m.won).length;
    final losses = _matches.length - wins;
    final rate = _matches.isEmpty
        ? '—'
        : '${(wins / _matches.length * 100).round()}% win rate';

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(children: [
        _hero(wins, losses, rate),
        Expanded(
          child: _loading && _matches.isEmpty
              ? const Center(
                  child: CircularProgressIndicator(color: AppColors.primary))
              : _matches.isEmpty
                  ? _empty()
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(
                          AppSpacing.screen, 16, AppSpacing.screen, 32),
                      itemCount: _matches.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (_, i) => _row(_matches[i]),
                    ),
        ),
      ]),
    );
  }

  Widget _hero(int wins, int losses, String rate) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
          AppSpacing.screen, MediaQuery.of(context).padding.top + 14,
          AppSpacing.screen, 22),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.hero, AppColors.hero2],
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.keyboard_arrow_down_rounded,
                  size: 24, color: AppColors.heroInk),
            ),
          ),
          const SizedBox(width: 12),
          Text('RECENT FORM',
              style: AppText.kicker(AppColors.heroFaint)
                  .copyWith(fontSize: 11, letterSpacing: 1.6)),
        ]),
        const SizedBox(height: 16),
        Text('Last ${_matches.length} Matches',
            style: AppText.stat(24, AppColors.heroInk)
                .copyWith(letterSpacing: -0.6, height: 1.1)),
        const SizedBox(height: 6),
        Text('$wins–$losses · $rate',
            style: AppText.small(AppColors.heroFaint).copyWith(fontSize: 12.5)),
      ]),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.history_rounded, size: 38, color: AppColors.inkFaint),
            const SizedBox(height: 12),
            Text('No matches played yet',
                style: AppText.bodyStrong().copyWith(fontSize: 14)),
            const SizedBox(height: 4),
            Text('Your win/loss form appears here after your first match.',
                textAlign: TextAlign.center,
                style: AppText.small().copyWith(fontSize: 12.5, height: 1.5)),
          ]),
        ),
      );

  Widget _row(FormMatch m) {
    final wc = m.won ? AppColors.success : AppColors.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.lineSoft),
      ),
      child: Row(children: [
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: wc.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(m.won ? 'W' : 'L', style: AppText.stat(14, wc)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('vs ${m.opp}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.bodyStrong().copyWith(fontSize: 13.5)),
              const SizedBox(height: 3),
              Text(m.date,
                  style: AppText.small().copyWith(fontSize: 11.5)),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(m.score, style: AppText.bodyStrong().copyWith(fontSize: 13)),
          const SizedBox(height: 3),
          // A competitive match with no settled delta shows nothing rather than
          // claiming a change that never happened.
          if (m.type == 'Casual')
            Text('Casual',
                style: AppText.tag(AppColors.inkFaint)
                    .copyWith(fontSize: 10.5, letterSpacing: 0))
          else if (m.delta != null && m.delta != 0)
            Text(
                '${m.delta! > 0 ? '+' : '−'}${m.delta!.abs().toStringAsFixed(2)}',
                style: AppText.bodyStrong(
                        m.delta! > 0 ? AppColors.success : AppColors.danger)
                    .copyWith(fontSize: 11.5)),
        ]),
      ]),
    );
  }
}

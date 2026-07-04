import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_text.dart';
import '../../../backend/models/ranking_scale.dart';

/// Dynamic ranking card. Renders the **placement** (unranked) state for a
/// brand-new account and the full **placed** state — level, league, tier
/// segments and movement banner — once the player has been placed.
///
/// Drop-in replacement for the old hard-coded `_rankCard()` on the profile.
class DivisionCard extends StatelessWidget {
  final Ranking ranking;
  final EdgeInsetsGeometry margin;

  /// Tapped on the unranked CTA ("Play Placement Match").
  final VoidCallback? onPlayPlacement;

  const DivisionCard({
    super.key,
    required this.ranking,
    this.margin = const EdgeInsets.fromLTRB(AppSpacing.screen, 8, AppSpacing.screen, 0),
    this.onPlayPlacement,
  });

  // Palette on the green hero.
  static const _cream = Color(0xFFF4EFE2);
  static const _gold = Color(0xFFE0BB63);
  static const _ink = Color(0xFF16201C);
  static const _success = Color(0xFF5BB97D);
  static const _danger = Color(0xFFE08572);
  static const _goldGrad = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFFF3DE9E), Color(0xFFC99B33)]);

  Color get _faint => _cream.withValues(alpha: 0.55);
  TextStyle get _kick =>
      AppText.tag(_faint).copyWith(fontSize: 9.5, letterSpacing: 1.8);
  Widget _hr() => Container(
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 13),
      color: _cream.withValues(alpha: 0.13));

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: const BoxDecoration(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.card)),
          gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.hero, AppColors.hero2]),
          boxShadow: kCardShadow,
        ),
        child: Stack(children: [
          Positioned(
            right: -26,
            top: -44,
            child: Container(
              width: 170,
              height: 170,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                      colors: [_gold.withValues(alpha: 0.16), Colors.transparent],
                      stops: const [0, 0.64])),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: ranking.placed ? _placed(context) : _unranked(context),
          ),
        ]),
      ),
    );
  }

  // ── PLACED ──────────────────────────────────────────────────────────────
  Widget _placed(BuildContext context) {
    final lv = ranking.level;
    final d = RankingScale.divisionFor(lv);
    final tier = RankingScale.tierFor(lv);
    final next = RankingScale.nextDivision(lv);
    final divPct = (RankingScale.progressInDivision(lv) * 100).round();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // header — big level + league + hex badge
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('CURRENT LEVEL', style: _kick),
              if (ranking.provisional) ...[
                const SizedBox(width: 8),
                _provisionalPill(),
              ],
            ]),
            const SizedBox(height: 5),
            Text(RankingScale.fmtQuarter(lv),
                style: AppText.stat(46, _gold).copyWith(letterSpacing: -2.5, height: 0.9)),
            const SizedBox(height: 6),
            Text(d.league, style: AppText.bodyStrong(_gold).copyWith(fontSize: 14.5)),
            const SizedBox(height: 11),
            _reliabilityRow(),
          ]),
        ),
        const SizedBox(width: 12),
        _hexBadge(d.key),
      ]),
      _hr(),
      // current tier + segments
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('CURRENT TIER', style: _kick),
        RichText(
          text: TextSpan(
              style: AppText.small(_faint).copyWith(fontSize: 12, fontWeight: FontWeight.w700),
              children: next == null
                  ? const [TextSpan(text: 'Top division', style: TextStyle(color: _gold, fontWeight: FontWeight.w800))]
                  : [
                      TextSpan(text: '$divPct% ', style: const TextStyle(color: _gold, fontWeight: FontWeight.w800)),
                      TextSpan(text: 'to ${next.name}'),
                    ]),
        ),
      ]),
      const SizedBox(height: 12),
      _tierSegments(tier),
      _hr(),
      // progress / movement
      _progressBlock(lv, d),
      _hr(),
      // this week
      Text('THIS WEEK', style: _kick),
      const SizedBox(height: 9),
      _weekStrip(),
      if (ranking.lastMatch != null) ...[
        const SizedBox(height: 14),
        Text('WHY YOUR LEVEL MOVED', style: _kick),
        const SizedBox(height: 9),
        _lastMatch(ranking.lastMatch!),
      ],
    ]);
  }

  Widget _hexBadge(String key) => Column(children: [
        Container(
          width: 62,
          height: 62,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [_gold.withValues(alpha: 0.22), const Color(0xFFB07E22).withValues(alpha: 0.05)]),
            border: Border.all(color: _gold.withValues(alpha: 0.5), width: 1.5),
            boxShadow: [BoxShadow(color: _gold.withValues(alpha: 0.35), blurRadius: 18, offset: const Offset(0, 8))],
          ),
          child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
            Text(key, style: AppText.stat(31, _gold)),
            const Positioned(top: 4, right: 5, child: Icon(Icons.star_rounded, size: 12, color: _gold)),
          ]),
        ),
        const SizedBox(height: 6),
        Text('LEVEL', style: AppText.tag(_gold).copyWith(fontSize: 9, letterSpacing: 1.3)),
      ]);

  Widget _provisionalPill() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: _cream.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: _gold.withValues(alpha: 0.45))),
        child: Text('PROVISIONAL',
            style: AppText.tag(_gold).copyWith(fontSize: 8.5, letterSpacing: 1.2)),
      );

  /// Reliability ring — rating confidence (1 − sigma), 0–100%.
  Widget _reliabilityRow() {
    final pct = ranking.reliability.clamp(0, 100).toDouble();
    return Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: 34,
        height: 34,
        child: Stack(alignment: Alignment.center, children: [
          SizedBox(
            width: 34,
            height: 34,
            child: CircularProgressIndicator(
              value: (pct / 100).clamp(0, 1).toDouble(),
              strokeWidth: 3.5,
              backgroundColor: _cream.withValues(alpha: 0.12),
              valueColor: const AlwaysStoppedAnimation<Color>(_gold),
            ),
          ),
          Text('${pct.round()}',
              style: AppText.stat(11, _cream).copyWith(height: 1)),
        ]),
      ),
      const SizedBox(width: 9),
      Text('rating confidence',
          style: AppText.small(_faint)
              .copyWith(fontSize: 12, fontWeight: FontWeight.w700)),
    ]);
  }

  Widget _tierSegments(String tier) {
    const tiers = ['Low', 'Mid', 'High'];
    final idx = tiers.indexOf(tier);
    Widget seg(String label, int i) {
      final now = i == idx, done = i < idx;
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.center,
          decoration: now
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  gradient: _goldGrad,
                  boxShadow: [BoxShadow(color: _gold.withValues(alpha: 0.4), blurRadius: 14, offset: const Offset(0, 5))])
              : BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: done ? _gold.withValues(alpha: 0.07) : _cream.withValues(alpha: 0.05),
                  border: Border.all(color: done ? _gold.withValues(alpha: 0.25) : _cream.withValues(alpha: 0.13))),
          child: Text(label.toUpperCase(),
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 10.5,
                  letterSpacing: 0.5,
                  color: now ? _ink : (done ? _gold.withValues(alpha: 0.85) : _faint))),
        ),
      );
    }

    return Row(children: [
      seg('Low', 0),
      const SizedBox(width: 7),
      seg('Mid', 1),
      const SizedBox(width: 7),
      seg('High', 2),
    ]);
  }

  Widget _progressBlock(double lv, Division d) {
    if (ranking.movement == RankMovement.promoted) {
      return _banner(
          icon: Icons.trending_up_rounded,
          tint: _success,
          title: 'Promoted!',
          sub: 'Up from ${ranking.movedFrom} · welcome to ${d.name}');
    }
    if (ranking.movement == RankMovement.dropped) {
      return _banner(
          icon: Icons.trending_down_rounded,
          tint: _danger,
          title: 'Relegated',
          sub: 'Dropped to ${d.name} · win to climb back');
    }
    final atTop = lv >= RankingScale.maxLevel;
    final nextLvl = RankingScale.nextLevelMilestone(lv);
    final pct = RankingScale.levelMilestoneProgress(lv);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(atTop ? 'NEXT LEVEL' : 'NEXT LEVEL · ${RankingScale.fmtLevel(nextLvl)}', style: _kick),
        Text(atTop ? 'Max level reached' : '${(pct * 100).round()}% to Level ${RankingScale.fmtLevel(nextLvl)}',
            style: AppText.small(_faint).copyWith(fontSize: 12, fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 11),
      _bar(atTop ? 1 : pct),
    ]);
  }

  Widget _banner({required IconData icon, required Color tint, required String title, required String sub}) =>
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: tint.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: tint.withValues(alpha: 0.3))),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: tint, width: 1.5)),
            child: Icon(icon, size: 18, color: tint),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppText.bodyStrong(tint == _success ? _gold : const Color(0xFFF0C7BD)).copyWith(fontSize: 14)),
              const SizedBox(height: 2),
              Text(sub, style: AppText.small(_faint).copyWith(fontSize: 11.5, height: 1.3)),
            ]),
          ),
        ]),
      );

  Widget _weekStrip() {
    final d = ranking.weeklyDelta;
    final down = d < 0;
    final tint = down ? _danger : _success;
    final ic = d > 0
        ? Icons.trending_up_rounded
        : (down ? Icons.trending_down_rounded : Icons.trending_flat_rounded);
    final label = d > 0 ? 'Level increase' : (down ? 'Level decrease' : 'No change this week');
    return Row(children: [
      Icon(ic, size: 19, color: tint),
      const SizedBox(width: 9),
      Text(RankingScale.fmtSigned(d), style: AppText.stat(23, tint).copyWith(letterSpacing: -0.5)),
      const SizedBox(width: 8),
      Flexible(child: Text(label, style: AppText.small(_faint).copyWith(fontSize: 12.5, fontWeight: FontWeight.w600))),
    ]);
  }

  Widget _lastMatch(LastRankedMatch m) {
    final pos = m.delta >= 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
          color: _cream.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _cream.withValues(alpha: 0.13))),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
              color: (m.won ? _success : _danger).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(6)),
          child: Text(m.won ? 'WIN' : 'LOSS',
              style: AppText.tag(m.won ? const Color(0xFFBFE9CD) : const Color(0xFFF0C7BD)).copyWith(fontSize: 10)),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('vs Level ${RankingScale.fmtLevel(m.vsLevel)}',
                    style: AppText.body(_cream)
                        .copyWith(fontSize: 11.5, fontWeight: FontWeight.w600)),
                if (m.hasScore) ...[
                  const SizedBox(height: 2),
                  Text('${m.won ? 'won' : 'lost'} ${m.gamesFor}–${m.gamesAgainst} games',
                      style: AppText.small(_faint).copyWith(fontSize: 10.5)),
                ],
              ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(RankingScale.fmtSigned(m.delta),
              style: AppText.bodyStrong(pos ? _success : _danger).copyWith(fontSize: 16, fontWeight: FontWeight.w800)),
          Text('LEVEL', style: AppText.tag(_faint).copyWith(fontSize: 9, letterSpacing: 0.5)),
        ]),
      ]),
    );
  }

  // ── UNRANKED / PLACEMENT ──────────────────────────────────────────────────
  Widget _unranked(BuildContext context) {
    final total = RankingScale.placementTotal;
    final done = ranking.placement.clamp(0, total);
    final remaining = total - done;
    final pct = done / total;
    final help = done == 0
        ? 'Complete 5 placement matches to determine your level.'
        : remaining == 1
            ? 'One more match to determine your level and unlock your division.'
            : remaining > 0
                ? 'Complete $remaining more matches to unlock your level.'
                : 'All placement matches done — calculating your level.';

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('CURRENT DIVISION', style: _kick),
            const SizedBox(height: 5),
            Text('Unranked', style: AppText.stat(24, _cream).copyWith(letterSpacing: -0.8, height: 1)),
            const SizedBox(height: 7),
            Text('Level not assigned yet', style: AppText.bodyStrong(_faint).copyWith(fontSize: 13)),
            const SizedBox(height: 7),
            Row(children: [
              Icon(Icons.lock_outline_rounded, size: 15, color: _faint),
              const SizedBox(width: 6),
              Text('Placement in progress', style: AppText.bodyStrong(_faint).copyWith(fontSize: 12.5)),
            ]),
          ]),
        ),
        const SizedBox(width: 12),
        Column(children: [
          Container(
            width: 62,
            height: 62,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: _cream.withValues(alpha: 0.05),
              border: Border.all(color: _cream.withValues(alpha: 0.32), width: 1.5, style: BorderStyle.solid),
            ),
            child: Text('?', style: AppText.stat(30, _faint)),
          ),
          const SizedBox(height: 6),
          Text('UNRANKED', style: AppText.tag(_faint).copyWith(fontSize: 9, letterSpacing: 1.3)),
        ]),
      ]),
      _hr(),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('PLACEMENT MATCHES', style: _kick),
        RichText(
          text: TextSpan(
              style: AppText.small(_faint).copyWith(fontSize: 12, fontWeight: FontWeight.w700),
              children: [
                TextSpan(text: '$done', style: const TextStyle(color: _gold, fontWeight: FontWeight.w800)),
                TextSpan(text: ' / $total'),
              ]),
        ),
      ]),
      const SizedBox(height: 11),
      Row(children: [
        for (int i = 0; i < total; i++) ...[
          if (i > 0) const SizedBox(width: 7),
          Expanded(child: _placementDot(i, done)),
        ],
      ]),
      const SizedBox(height: 11),
      _bar(pct),
      const SizedBox(height: 11),
      Text(help, style: AppText.small(_faint).copyWith(fontSize: 12, height: 1.45, fontWeight: FontWeight.w500)),
      const SizedBox(height: 14),
      _goldButton(
        label: remaining > 0 ? 'Play Placement Match' : 'See Your Division',
        icon: Icons.play_arrow_rounded,
        onTap: onPlayPlacement,
      ),
    ]);
  }

  Widget _placementDot(int i, int done) {
    final filled = i < done;
    return Container(
      height: 34,
      alignment: Alignment.center,
      decoration: filled
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              gradient: _goldGrad,
              boxShadow: [BoxShadow(color: _gold.withValues(alpha: 0.4), blurRadius: 12, offset: const Offset(0, 4))])
          : BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: _cream.withValues(alpha: 0.05),
              border: Border.all(color: _cream.withValues(alpha: 0.13))),
      child: filled
          ? const Icon(Icons.check_rounded, size: 15, color: _ink)
          : Text('${i + 1}', style: AppText.bodyStrong(_faint).copyWith(fontSize: 12, fontWeight: FontWeight.w800)),
    );
  }

  Widget _goldButton({required String label, required IconData icon, VoidCallback? onTap}) =>
      Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(13),
          onTap: onTap,
          child: Container(
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(13),
                gradient: _goldGrad,
                boxShadow: [BoxShadow(color: _gold.withValues(alpha: 0.4), blurRadius: 16, offset: const Offset(0, 8))]),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 18, color: _ink),
              const SizedBox(width: 8),
              Text(label, style: AppText.bodyStrong(_ink).copyWith(fontSize: 13.5, fontWeight: FontWeight.w800)),
            ]),
          ),
        ),
      );

  Widget _bar(double value) => ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 7,
          color: _cream.withValues(alpha: 0.10),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: value.clamp(0, 1),
            child: Container(
              decoration: const BoxDecoration(
                  gradient: LinearGradient(colors: [Color(0xFFC99B33), Color(0xFFF3DE9E)])),
            ),
          ),
        ),
      );
}

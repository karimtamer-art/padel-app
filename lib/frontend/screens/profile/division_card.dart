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
    final leagueWord = d.league.split(' ').first; // "Beginner League" → "Beginner"
    final atTop = lv >= RankingScale.maxLevel;
    final nextLvl = RankingScale.nextLevelMilestone(lv);
    final pct = RankingScale.levelMilestoneProgress(lv);
    final toGo = nextLvl - lv;
    final wk = ranking.weeklyDelta;
    final trend = wk > 0.001
        ? 'improving fast'
        : (wk < -0.001 ? 'finding your level' : 'holding steady');
    final trendColor = wk < -0.001 ? _danger : _success;
    final rel = ranking.reliability.clamp(0, 100).toDouble();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Header: big level + trend + NEXT ring.
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
            const SizedBox(height: 6),
            Text(lv.toStringAsFixed(2),
                style: AppText.stat(52, _gold).copyWith(letterSpacing: -2.5, height: 0.9)),
            const SizedBox(height: 8),
            Text.rich(TextSpan(children: [
              TextSpan(text: leagueWord, style: AppText.bodyStrong(_cream).copyWith(fontSize: 15)),
              TextSpan(
                  text: '  ·  $trend',
                  style: AppText.body(trendColor).copyWith(fontSize: 13.5, fontWeight: FontWeight.w600)),
            ])),
          ]),
        ),
        const SizedBox(width: 12),
        _nextRing(atTop ? 1.0 : pct, atTop ? 'MAX' : RankingScale.fmtLevel(nextLvl)),
      ]),
      const SizedBox(height: 16),
      _reliabilityBlock(rel),
      const SizedBox(height: 16),
      // Progress to next 0.5 milestone.
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(atTop ? 'TOP LEVEL REACHED' : 'PROGRESS TO LEVEL ${RankingScale.fmtLevel(nextLvl)}',
            style: _kick),
        if (!atTop)
          Text.rich(TextSpan(children: [
            TextSpan(text: '${(pct * 100).round()}% ', style: AppText.bodyStrong(_gold).copyWith(fontSize: 12.5)),
            TextSpan(
                text: '· +${toGo.toStringAsFixed(2)} to go',
                style: AppText.small(_faint).copyWith(fontSize: 12, fontWeight: FontWeight.w600)),
          ])),
      ]),
      const SizedBox(height: 10),
      _bar(atTop ? 1 : pct),
      if (ranking.lastMatch != null) ...[
        const SizedBox(height: 16),
        _lastMatchCard(ranking.lastMatch!, wk),
      ],
    ]);
  }

  Widget _provisionalPill() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: _cream.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: _gold.withValues(alpha: 0.45))),
        child: Text('PROVISIONAL',
            style: AppText.tag(_gold).copyWith(fontSize: 8.5, letterSpacing: 1.2)),
      );

  /// "NEXT / level" ring — arc = progress to the next 0.5 milestone.
  Widget _nextRing(double value, String label) => SizedBox(
        width: 66,
        height: 66,
        child: Stack(alignment: Alignment.center, children: [
          SizedBox(
            width: 66,
            height: 66,
            child: CircularProgressIndicator(
              value: value.clamp(0, 1).toDouble(),
              strokeWidth: 5,
              backgroundColor: _cream.withValues(alpha: 0.12),
              valueColor: const AlwaysStoppedAnimation<Color>(_gold),
            ),
          ),
          Column(mainAxisSize: MainAxisSize.min, children: [
            Text('NEXT', style: AppText.tag(_faint).copyWith(fontSize: 7.5, letterSpacing: 1.2)),
            Text(label, style: AppText.stat(15, _cream).copyWith(height: 1.05)),
          ]),
        ]),
      );

  /// Reliability ring + "Rating reliability · N%" and the confirm nudge.
  Widget _reliabilityBlock(double rel) {
    final confirm = ranking.matchesToConfirm;
    final sub = ranking.provisional
        ? (confirm > 0
            ? 'Play $confirm more ${confirm == 1 ? 'match' : 'matches'} to confirm your level.'
            : 'Keep playing to sharpen your rating.')
        : 'Your level is confirmed.';
    return Row(children: [
      SizedBox(
        width: 38,
        height: 38,
        child: Stack(alignment: Alignment.center, children: [
          SizedBox(
            width: 38,
            height: 38,
            child: CircularProgressIndicator(
              value: (rel / 100).clamp(0, 1).toDouble(),
              strokeWidth: 3.5,
              backgroundColor: _cream.withValues(alpha: 0.12),
              valueColor: const AlwaysStoppedAnimation<Color>(_gold),
            ),
          ),
          Text('${rel.round()}', style: AppText.stat(11, _cream).copyWith(height: 1)),
        ]),
      ),
      const SizedBox(width: 11),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Rating reliability · ${rel.round()}%',
              style: AppText.bodyStrong(_cream).copyWith(fontSize: 13.5)),
          const SizedBox(height: 2),
          Text(sub, style: AppText.small(_faint).copyWith(fontSize: 12, height: 1.35)),
        ]),
      ),
    ]);
  }

  /// Inset last-ranked-match card with the week's level movement.
  Widget _lastMatchCard(LastRankedMatch m, double wk) {
    final verb = m.won ? 'Beat' : 'Lost to';
    final pos = wk >= 0;
    final score = m.hasScore ? ' · ${m.gamesFor}–${m.gamesAgainst}' : '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      decoration: BoxDecoration(
          color: _ink.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _cream.withValues(alpha: 0.10))),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
              color: (m.won ? _success : _danger).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(6)),
          child: Text(m.won ? 'WIN' : 'LOSS',
              style: AppText.tag(m.won ? const Color(0xFFBFE9CD) : const Color(0xFFF0C7BD))
                  .copyWith(fontSize: 10)),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('$verb Level ${RankingScale.fmtLevel(m.vsLevel)}$score',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.bodyStrong(_cream).copyWith(fontSize: 13.5)),
            const SizedBox(height: 2),
            Text('Your last ranked match this week',
                style: AppText.small(_faint).copyWith(fontSize: 11.5)),
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(RankingScale.fmtSigned(wk),
              style: AppText.stat(19, pos ? _success : _danger).copyWith(letterSpacing: -0.5)),
          Text('THIS WEEK', style: AppText.tag(_faint).copyWith(fontSize: 8.5, letterSpacing: 0.8)),
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
    // Placement finds a first useful level, it does not settle one — the
    // reliability figure on the placed card is where confidence is stated.
    final help = done == 0
        ? 'Play $total placement matches to find your starting level.'
        : remaining == 1
            ? 'One more match to find your level and unlock your division.'
            : remaining > 0
                ? 'Play $remaining more ${remaining == 1 ? 'match' : 'matches'} to unlock your level.'
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

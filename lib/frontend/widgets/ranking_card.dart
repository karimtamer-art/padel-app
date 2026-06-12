import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text.dart';
import 'package:padel_clay/backend/models/user_ranking.dart';

/// Profile Division Card — a reusable, fully data-driven ranking widget.
///
/// Renders one of two states from a [UserRanking]:
///   • **Unranked** — placement progress (n/5), locked ladder, "Play Placement
///     Match" CTA.
///   • **Ranked** — division, level, in-division tier, league ladder, progress
///     to the next division, and recent movement.
///
/// No UI string is hardcoded where it depends on ranking data — everything
/// flows from the model and [RankingScale]. Drop it anywhere:
///
/// ```dart
/// RankingCard(
///   ranking: userRanking,
///   onPlayPlacement: () => Navigator.push(...),
/// )
/// ```
class RankingCard extends StatelessWidget {
  final UserRanking ranking;

  /// Tapped from the unranked CTA ("Play Placement Match" / "See Your Division").
  final VoidCallback? onPlayPlacement;

  const RankingCard({super.key, required this.ranking, this.onPlayPlacement});

  // Card-local palette (bright accents on the dark hero card).
  static const _cream = Color(0xFFF4EFE2);
  static const _gold = Color(0xFFE0BB63);
  static const _ink = Color(0xFF16201C);
  static const _success = Color(0xFF5BB97D);
  static const _danger = Color(0xFFE08572);
  Color get _faint => _cream.withValues(alpha: 0.55);
  Color get _hair => _cream.withValues(alpha: 0.13);

  TextStyle get _kick =>
      AppText.tag(_faint).copyWith(fontSize: 9.5, letterSpacing: 1.8);

  @override
  Widget build(BuildContext context) {
    return Container(
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
        // Soft corner glow.
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
          child: ranking.placed ? _ranked() : _unranked(),
        ),
      ]),
    );
  }

  Widget _hr() => Container(
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 13),
      color: _hair);

  // ── RANKED ───────────────────────────────────────────────────────────────
  Widget _ranked() {
    final r = ranking;
    final d = r.division;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Header — level-centric
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('CURRENT LEVEL', style: _kick),
            const SizedBox(height: 5),
            Text(r.level.toStringAsFixed(1),
                style: AppText.stat(46, _gold)
                    .copyWith(letterSpacing: -2.5, height: 0.9)),
            const SizedBox(height: 6),
            Text(d.league,
                style: AppText.bodyStrong(_gold)
                    .copyWith(fontSize: 14.5, fontWeight: FontWeight.w800)),
          ]),
        ),
        const SizedBox(width: 12),
        _hexBadge(),
      ]),
      _hr(),

      // Current tier — Low / Mid / High
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('CURRENT TIER', style: _kick),
        RichText(
            text: TextSpan(
                style: AppText.small(_faint)
                    .copyWith(fontSize: 12, fontWeight: FontWeight.w700),
                children: [
                  const TextSpan(text: 'Currently '),
                  TextSpan(
                      text: r.tier,
                      style: const TextStyle(color: _gold, fontWeight: FontWeight.w800)),
                ])),
      ]),
      const SizedBox(height: 12),
      _tierSegments(r.tier),
      _hr(),

      // Next level / promoted / demoted
      _milestoneBlock(r),
      _hr(),

      // This week
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('THIS WEEK', style: _kick),
      ]),
      const SizedBox(height: 9),
      _thisWeek(r.weeklyDelta),

      // Last match
      if (r.lastMatch != null) ...[
        const SizedBox(height: 14),
        Text('LAST MATCH', style: _kick),
        const SizedBox(height: 9),
        _lastMatchBox(r.lastMatch!),
      ],
    ]);
  }

  Widget _tierSegments(String tier) {
    const tiers = ['Low', 'Mid', 'High'];
    final idx = tiers.indexOf(tier);
    final goldGrad = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFF3DE9E), Color(0xFFC99B33)]);

    Widget seg(int i) {
      final isNow = i == idx;
      final done = i < idx;
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          alignment: Alignment.center,
          decoration: isNow
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  gradient: goldGrad,
                  boxShadow: [BoxShadow(color: _gold.withValues(alpha: 0.4), blurRadius: 14, offset: const Offset(0, 5))])
              : BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: done ? _gold.withValues(alpha: 0.07) : _cream.withValues(alpha: 0.05),
                  border: Border.all(color: done ? _gold.withValues(alpha: 0.25) : _hair)),
          child: Text(tiers[i].toUpperCase(),
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                  letterSpacing: 0.6,
                  color: isNow ? _ink : done ? _gold.withValues(alpha: 0.85) : _faint)),
        ),
      );
    }

    return Row(children: [
      seg(0),
      const SizedBox(width: 7),
      seg(1),
      const SizedBox(width: 7),
      seg(2),
    ]);
  }

  Widget _hexBadge() => SizedBox(
        width: 62,
        height: 62,
        child: CustomPaint(painter: _HexBadgePainter()),
      );

  Widget _milestoneBlock(UserRanking r) {
    switch (r.movement) {
      case RankMovement.promoted:
        return _milestone(
            icon: Icons.arrow_upward_rounded,
            tone: _gold,
            title: 'Promoted!',
            sub: 'Up from ${r.movedFrom} · welcome to ${r.division.name}');
      case RankMovement.dropped:
        return _milestone(
            icon: Icons.arrow_downward_rounded,
            tone: _danger,
            title: 'Relegated',
            sub: 'Dropped to ${r.division.name} · win to climb back');
      case RankMovement.steady:
        if (r.atMaxLevel) {
          return _nextLevelBar(label: 'NEXT LEVEL', trailing: 'Max level reached', pct: 100);
        }
        return _nextLevelBar(
            label: 'NEXT LEVEL · ${r.nextLevel.toStringAsFixed(1)}',
            trailing: '${r.nextLevelPercent}% to Level ${r.nextLevel.toStringAsFixed(1)}',
            pct: r.nextLevelPercent);
    }
  }

  Widget _nextLevelBar({required String label, required String trailing, required int pct}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: _kick),
          RichText(
              text: TextSpan(
                  style: AppText.small(_faint)
                      .copyWith(fontSize: 12, fontWeight: FontWeight.w700),
                  children: [
                    if (trailing.contains('%')) ...[
                      TextSpan(
                          text: '${trailing.split(' ').first} ',
                          style: const TextStyle(color: _gold, fontWeight: FontWeight.w800)),
                      TextSpan(text: trailing.substring(trailing.indexOf(' ') + 1)),
                    ] else
                      TextSpan(
                          text: trailing,
                          style: const TextStyle(color: _gold, fontWeight: FontWeight.w800)),
                  ])),
        ]),
        const SizedBox(height: 11),
        _placementBar(pct / 100),
      ]);

  Widget _milestone(
          {required IconData icon,
          required Color tone,
          required String title,
          required String sub}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        decoration: BoxDecoration(
            color: tone.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: tone.withValues(alpha: 0.30))),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: tone, width: 1.5)),
            child: Icon(icon, size: 18, color: tone),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: AppText.bodyStrong(tone == _danger ? const Color(0xFFF0C7BD) : _gold)
                      .copyWith(fontSize: 14, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(sub,
                  style: AppText.small(_faint)
                      .copyWith(fontSize: 11.5, height: 1.3, fontWeight: FontWeight.w500)),
            ]),
          ),
        ]),
      );

  Widget _thisWeek(double delta) {
    final pos = delta > 0, neg = delta < 0;
    final tone = neg ? _danger : _success;
    final icon = pos
        ? Icons.trending_up_rounded
        : neg
            ? Icons.trending_down_rounded
            : Icons.trending_flat_rounded;
    final label = pos ? 'Level increase' : neg ? 'Level decrease' : 'No change this week';
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Icon(icon, size: 19, color: tone),
      const SizedBox(width: 9),
      Text(RankingScale.signed(delta),
          style: AppText.stat(23, tone).copyWith(letterSpacing: -0.5, height: 1)),
      const SizedBox(width: 9),
      Text(label, style: AppText.small(_faint).copyWith(fontSize: 12.5, fontWeight: FontWeight.w600)),
    ]);
  }

  Widget _lastMatchBox(LastMatch m) {
    final tone = m.win ? _success : _danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
          color: _cream.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _hair)),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
              color: tone.withValues(alpha: 0.20),
              borderRadius: BorderRadius.circular(6)),
          child: Text(m.win ? 'WIN' : 'LOSS',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                  color: m.win ? const Color(0xFFBFE9CD) : const Color(0xFFF0C7BD))),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text('vs Level ${m.vsLevel.toStringAsFixed(1)} players',
              style: AppText.bodyStrong(_cream).copyWith(fontSize: 11.5, fontWeight: FontWeight.w600)),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(RankingScale.signed(m.delta),
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  height: 1,
                  color: m.delta < 0 ? _danger : _success)),
          const SizedBox(height: 3),
          Text('LEVEL',
              style: AppText.tag(_faint).copyWith(fontSize: 9, letterSpacing: 0.5)),
        ]),
      ]),
    );
  }

  // ── UNRANKED ───────────────────────────────────────────────────────────────
  Widget _unranked() {
    final r = ranking;
    final done = r.placementPlayed.clamp(0, RankingScale.placementTotal);
    final remaining = r.placementRemaining;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Header
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('CURRENT DIVISION', style: _kick),
            const SizedBox(height: 5),
            Text('Unranked',
                style: AppText.stat(24, _cream).copyWith(letterSpacing: -0.8, height: 1)),
            const SizedBox(height: 7),
            Text('Level not assigned yet',
                style: AppText.bodyStrong(_faint).copyWith(fontSize: 13)),
            const SizedBox(height: 7),
            Row(children: [
              Icon(Icons.lock_outline_rounded, size: 15, color: _faint),
              const SizedBox(width: 6),
              Text('Placement in progress',
                  style: AppText.bodyStrong(_faint).copyWith(fontSize: 12.5)),
            ]),
          ]),
        ),
        const SizedBox(width: 12),
        _lockShield(),
      ]),
      _hr(),

      // Placement progress
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('PLACEMENT MATCHES', style: _kick),
        RichText(
            text: TextSpan(
                style: AppText.small(_faint)
                    .copyWith(fontSize: 12, fontWeight: FontWeight.w700),
                children: [
                  TextSpan(
                      text: '$done',
                      style: const TextStyle(color: _gold, fontWeight: FontWeight.w800)),
                  const TextSpan(text: ' / ${RankingScale.placementTotal}'),
                ])),
      ]),
      const SizedBox(height: 12),
      _placementDots(done),
      const SizedBox(height: 11),
      _placementBar(r.placementProgress),
      const SizedBox(height: 11),
      _placementHelp(done, remaining),

      const SizedBox(height: 12),
      _cta(remaining > 0 ? 'Play Placement Match' : 'See Your Division'),
    ]);
  }

  Widget _lockShield() => Column(children: [
        Container(
          width: 62,
          height: 62,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [_cream.withValues(alpha: 0.10), _cream.withValues(alpha: 0.02)]),
              border: Border.all(color: _cream.withValues(alpha: 0.32), width: 1.5)),
          child: Text('?', style: AppText.stat(30, _faint)),
        ),
        const SizedBox(height: 6),
        Text('UNRANKED',
            style: AppText.tag(_faint).copyWith(fontSize: 9, letterSpacing: 1.3)),
      ]);

  Widget _placementDots(int done) {
    const goldGrad = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFF3DE9E), Color(0xFFC99B33)]);
    return Row(children: [
      for (var i = 0; i < RankingScale.placementTotal; i++) ...[
        if (i > 0) const SizedBox(width: 7),
        Expanded(
          child: Container(
            height: 34,
            alignment: Alignment.center,
            decoration: i < done
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    gradient: goldGrad,
                    boxShadow: [BoxShadow(color: _gold.withValues(alpha: 0.45), blurRadius: 12, offset: const Offset(0, 4))])
                : BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: _cream.withValues(alpha: 0.05),
                    border: Border.all(color: _hair)),
            child: i < done
                ? const Icon(Icons.check_rounded, size: 16, color: _ink)
                : Text('${i + 1}',
                    style: TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 12, color: _faint)),
          ),
        ),
      ],
    ]);
  }

  Widget _placementBar(double value) => ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Container(
          height: 7,
          color: _cream.withValues(alpha: 0.10),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: value.clamp(0, 1),
            child: Container(
                decoration: const BoxDecoration(
                    gradient: LinearGradient(colors: [Color(0xFFC99B33), Color(0xFFF3DE9E)]))),
          ),
        ),
      );

  Widget _placementHelp(int done, int remaining) {
    final strong = AppText.bodyStrong(_cream).copyWith(fontSize: 12, height: 1.45);
    final base = AppText.small(_faint).copyWith(fontSize: 12, height: 1.45, fontWeight: FontWeight.w500);

    List<InlineSpan> spans;
    if (done == 0) {
      spans = [
        const TextSpan(text: 'Complete '),
        TextSpan(text: '5 placement matches', style: strong),
        const TextSpan(text: ' to determine your level and unlock your division.'),
      ];
    } else if (remaining > 0) {
      spans = [
        TextSpan(text: '$done of ${RankingScale.placementTotal}', style: strong),
        const TextSpan(text: ' placement matches completed — '),
        TextSpan(text: '$remaining more', style: strong),
        const TextSpan(text: ' to unlock your division.'),
      ];
    } else {
      spans = [const TextSpan(text: 'All placement matches done — calculating your division.')];
    }
    return RichText(text: TextSpan(style: base, children: spans));
  }

  Widget _cta(String label) => SizedBox(
        width: double.infinity,
        child: Material(
          borderRadius: BorderRadius.circular(13),
          clipBehavior: Clip.antiAlias,
          color: Colors.transparent,
          child: InkWell(
            onTap: onPlayPlacement,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
                  gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFFF3DE9E), Color(0xFFC99B33)]),
                  boxShadow: [BoxShadow(color: _gold.withValues(alpha: 0.5), blurRadius: 18, offset: const Offset(0, 8))]),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.play_arrow_rounded, size: 19, color: _ink),
                const SizedBox(width: 7),
                Text(label,
                    style: AppText.bodyStrong(_ink)
                        .copyWith(fontSize: 13.5, fontWeight: FontWeight.w800)),
              ]),
            ),
          ),
        ),
      );
}

/// Gold hexagon badge with a centered star and a soft glow — the ranked emblem.
class _HexBadgePainter extends CustomPainter {
  static const _gold = Color(0xFFE0BB63);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final cx = w / 2, cy = h / 2;
    final r = w / 2 - 2;

    // Hexagon (flat-ish top, pointy sides matching the HTML polygon).
    final hex = Path();
    final pts = <Offset>[
      Offset(cx, cy - r),
      Offset(cx + r * 0.92, cy - r * 0.5),
      Offset(cx + r * 0.92, cy + r * 0.5),
      Offset(cx, cy + r),
      Offset(cx - r * 0.92, cy + r * 0.5),
      Offset(cx - r * 0.92, cy - r * 0.5),
    ];
    hex.addPolygon(pts, true);

    // Glow.
    canvas.drawPath(
        hex,
        Paint()
          ..color = _gold.withValues(alpha: 0.40)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9));

    // Fill gradient.
    canvas.drawPath(
        hex,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0x47E0BB63), Color(0x0AB07E22)],
          ).createShader(Rect.fromLTWH(0, 0, w, h)));

    // Stroke.
    canvas.drawPath(
        hex,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = _gold);

    // Star.
    final star = Path();
    const n = 5;
    final outer = r * 0.46, inner = outer * 0.42;
    for (var i = 0; i < n * 2; i++) {
      final rad = i.isEven ? outer : inner;
      final ang = -math.pi / 2 + i * math.pi / n;
      final p = Offset(cx + rad * math.cos(ang), cy + rad * math.sin(ang));
      i == 0 ? star.moveTo(p.dx, p.dy) : star.lineTo(p.dx, p.dy);
    }
    star.close();
    canvas.drawPath(star, Paint()..color = _gold);
  }

  @override
  bool shouldRepaint(covariant _HexBadgePainter oldDelegate) => false;
}

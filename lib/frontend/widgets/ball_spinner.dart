import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Brand loading indicator: a spinning padel ball drawn with [CustomPaint] —
/// no icon-font glyph, so it always renders (a missing `sports_tennis` glyph on
/// some devices showed a "prohibited" symbol instead). Honors reduced motion.
class BallSpinner extends StatefulWidget {
  final double size;
  final Color? color; // ball fill
  final Color? seamColor; // seam line
  const BallSpinner({super.key, this.size = 30, this.color, this.seamColor});

  @override
  State<BallSpinner> createState() => _BallSpinnerState();
}

class _BallSpinnerState extends State<BallSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ball = CustomPaint(
      size: Size.square(widget.size),
      painter: _BallPainter(
        widget.color ?? AppColors.primary,
        widget.seamColor ?? AppColors.primaryInk,
      ),
    );
    if (MediaQuery.of(context).disableAnimations) return ball;
    return RotationTransition(turns: _c, child: ball);
  }
}

class _BallPainter extends CustomPainter {
  final Color ball;
  final Color seam;
  _BallPainter(this.ball, this.seam);

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final c = Offset(r, r);
    canvas.drawCircle(
        c, r, Paint()..color = ball..isAntiAlias = true);

    // Classic tennis-ball seam: two facing arcs ")(" through the ball.
    final seamPaint = Paint()
      ..color = seam
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.20
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    final leftRect =
        Rect.fromCircle(center: Offset(c.dx - r * 0.7, c.dy), radius: r * 1.05);
    canvas.drawArc(leftRect, -0.91, 1.82, false, seamPaint);
    final rightRect =
        Rect.fromCircle(center: Offset(c.dx + r * 0.7, c.dy), radius: r * 1.05);
    canvas.drawArc(rightRect, 2.23, 1.82, false, seamPaint);
  }

  @override
  bool shouldRepaint(_BallPainter old) => old.ball != ball || old.seam != seam;
}

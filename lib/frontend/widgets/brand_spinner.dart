import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Clean loading spinner: a rotating terracotta arc with rounded caps. Drawn
/// with [CustomPaint] (no icon font, no asset), so it always renders. Honors
/// reduced motion (shows a static arc).
class BrandSpinner extends StatefulWidget {
  final double size;
  final Color? color;
  final double strokeWidth;
  const BrandSpinner({super.key, this.size = 30, this.color, this.strokeWidth = 3});

  @override
  State<BrandSpinner> createState() => _BrandSpinnerState();
}

class _BrandSpinnerState extends State<BrandSpinner>
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
    final arc = CustomPaint(
      size: Size.square(widget.size),
      painter: _ArcPainter(
          widget.color ?? AppColors.primary, widget.strokeWidth),
    );
    if (MediaQuery.of(context).disableAnimations) return arc;
    return RotationTransition(turns: _c, child: arc);
  }
}

class _ArcPainter extends CustomPainter {
  final Color color;
  final double stroke;
  _ArcPainter(this.color, this.stroke);

  @override
  void paint(Canvas canvas, Size size) {
    final r = (size.width - stroke) / 2;
    final rect = Rect.fromCircle(center: Offset(size.width / 2, size.height / 2), radius: r);
    // faint full track + a brighter 270° sweep that rotates
    final track = Paint()
      ..color = color.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawCircle(rect.center, r, track);

    final sweep = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    canvas.drawArc(rect, -math.pi / 2, math.pi * 1.5, false, sweep);
  }

  @override
  bool shouldRepaint(_ArcPainter old) =>
      old.color != color || old.stroke != stroke;
}

import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Smooth rating sparkline (line + gradient area). Plots the player's actual
/// 0.00-7.00 rating; it used to plot a fake ELO series derived as
/// `800 + rating*200`, which was invented purely to keep the old axis.
class RatingChart extends StatelessWidget {
  final List<double> data;
  final double height;
  final Color accent;
  const RatingChart(this.data,
      {super.key, this.height = 96, this.accent = AppColors.primary});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _RatingPainter(data, accent)),
    );
  }
}

class _RatingPainter extends CustomPainter {
  final List<double> data;
  final Color accent;
  _RatingPainter(this.data, this.accent);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    const pad = 10.0;
    final minV = data.reduce((a, b) => a < b ? a : b).toDouble();
    final maxV = data.reduce((a, b) => a > b ? a : b).toDouble();
    final span = (maxV - minV) == 0 ? 1 : (maxV - minV);
    final n = data.length;

    double dx(int i) => pad + (i / (n - 1)) * (size.width - pad * 2);
    double dy(num v) => pad + (1 - (v - minV) / span) * (size.height - pad * 2 - 6);

    final pts = [for (int i = 0; i < n; i++) Offset(dx(i), dy(data[i]))];

    // baseline gridline
    final grid = Paint()
      ..color = AppColors.line
      ..strokeWidth = 1;
    final midY = pad + 0.5 * (size.height - pad * 2 - 6);
    canvas.drawLine(Offset(pad, midY), Offset(size.width - pad, midY), grid);

    // smooth path (Catmull-Rom → cubic bezier)
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (int i = 0; i < pts.length - 1; i++) {
      final p0 = i == 0 ? pts[i] : pts[i - 1];
      final p1 = pts[i];
      final p2 = pts[i + 1];
      final p3 = (i + 2 < pts.length) ? pts[i + 2] : p2;
      final c1 = Offset(p1.dx + (p2.dx - p0.dx) / 6, p1.dy + (p2.dy - p0.dy) / 6);
      final c2 = Offset(p2.dx - (p3.dx - p1.dx) / 6, p2.dy - (p3.dy - p1.dy) / 6);
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    }

    // area fill
    final area = Path.from(path)
      ..lineTo(pts.last.dx, size.height - pad)
      ..lineTo(pts.first.dx, size.height - pad)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [accent.withValues(alpha: 0.26), accent.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );

    // line
    canvas.drawPath(
      path,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // end dot
    canvas.drawCircle(pts.last, 4.5, Paint()..color = accent);
    canvas.drawCircle(
        pts.last, 4.5, Paint()..color = AppColors.surface..style = PaintingStyle.stroke..strokeWidth = 2.5);
  }

  @override
  bool shouldRepaint(covariant _RatingPainter old) => old.data != data;
}

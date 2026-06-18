import 'package:flutter/cupertino.dart';
import '../theme/app_colors.dart';

/// A branded pull-to-refresh. Wraps a [CustomScrollView] and renders a spinning
/// padel-ball as the refresh indicator instead of the default Material spinner.
///
/// Usage:
///   PadelRefresh(
///     onRefresh: () async => controller.reload(),
///     slivers: [ SliverList(...) ],     // lazy lists / grids
///   )
///   PadelRefresh(
///     onRefresh: ...,
///     child: Column(...),               // simple, short bodies
///   )
class PadelRefresh extends StatelessWidget {
  final Future<void> Function() onRefresh;
  final List<Widget>? slivers;
  final Widget? child;
  final EdgeInsets padding;
  final ScrollController? controller;

  const PadelRefresh({
    super.key,
    required this.onRefresh,
    this.slivers,
    this.child,
    this.padding = EdgeInsets.zero,
    this.controller,
  }) : assert(slivers != null || child != null, 'Provide slivers or child');

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.of(context).disableAnimations;
    return CustomScrollView(
      controller: controller,
      physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics()),
      slivers: [
        CupertinoSliverRefreshControl(
          refreshTriggerPullDistance: 80,
          refreshIndicatorExtent: 70,
          onRefresh: onRefresh,
          builder: (context, mode, pulled, triggerExtent, indicatorExtent) {
            return _BallIndicator(
              mode: mode,
              pulled: pulled,
              triggerExtent: triggerExtent,
              reduceMotion: reduce,
            );
          },
        ),
        if (slivers != null)
          ...slivers!
        else
          SliverPadding(
            padding: padding,
            sliver: SliverToBoxAdapter(child: child),
          ),
      ],
    );
  }
}

class _BallIndicator extends StatefulWidget {
  final RefreshIndicatorMode mode;
  final double pulled;
  final double triggerExtent;
  final bool reduceMotion;
  const _BallIndicator({
    required this.mode,
    required this.pulled,
    required this.triggerExtent,
    required this.reduceMotion,
  });

  @override
  State<_BallIndicator> createState() => _BallIndicatorState();
}

class _BallIndicatorState extends State<_BallIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

  void _syncSpin() {
    final refreshing = widget.mode == RefreshIndicatorMode.refresh ||
        widget.mode == RefreshIndicatorMode.armed;
    if (refreshing && !widget.reduceMotion) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      if (_spin.isAnimating) _spin.stop();
    }
  }

  @override
  void didUpdateWidget(covariant _BallIndicator old) {
    super.didUpdateWidget(old);
    _syncSpin();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = (widget.pulled / widget.triggerExtent).clamp(0.0, 1.0);
    final armed = widget.mode == RefreshIndicatorMode.armed ||
        widget.mode == RefreshIndicatorMode.refresh;
    final color = armed ? AppColors.primary : AppColors.inkFaint;

    return Center(
      child: Opacity(
        opacity: (progress * 1.4).clamp(0.0, 1.0),
        child: AnimatedBuilder(
          animation: _spin,
          builder: (context, _) {
            final angle = _spin.isAnimating
                ? _spin.value * 6.28318 // full spin while refreshing
                : progress * 3.14159 * 1.2; // rotate with the drag
            return Transform.rotate(
              angle: widget.reduceMotion ? 0 : angle,
              child: CustomPaint(
                size: const Size.square(28),
                painter: _TennisBall(color),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A padel/tennis ball: filled circle + a single S-curve seam (clipped to the
/// ball). The parent Transform.rotate spins it. [color] is the ball fill
/// (terracotta when armed); the seam is the cream surface tone.
class _TennisBall extends CustomPainter {
  final Color color;
  _TennisBall(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final c = Offset(r, r);
    canvas.drawCircle(c, r, Paint()..color = color..isAntiAlias = true);

    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r)));
    final seam = Paint()
      ..color = AppColors.surface
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.22
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    final path = Path()
      ..moveTo(c.dx, c.dy - r)
      ..cubicTo(c.dx + 0.9 * r, c.dy - 0.45 * r, c.dx - 0.9 * r,
          c.dy + 0.45 * r, c.dx, c.dy + r);
    canvas.drawPath(path, seam);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TennisBall old) => old.color != color;
}

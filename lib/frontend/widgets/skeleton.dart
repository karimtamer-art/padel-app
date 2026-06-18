import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// A single shimmering placeholder block. Compose several to mimic a real row
/// or card. Paints an [AppColors.lineSoft] block with a soft light band
/// sweeping across it; falls back to a static block under reduced motion.
class Skeleton extends StatefulWidget {
  final double? width;
  final double height;
  final double radius;
  final EdgeInsetsGeometry margin;
  const Skeleton({
    super.key,
    this.width,
    this.height = 12,
    this.radius = 8,
    this.margin = EdgeInsets.zero,
  });

  /// Circle convenience (avatars).
  const Skeleton.circle(double size, {super.key, this.margin = EdgeInsets.zero})
      : width = size,
        height = size,
        radius = size; // >= size/2 => circle

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1350))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.of(context).disableAnimations;
    final block = Container(
      width: widget.width,
      height: widget.height,
      margin: widget.margin,
      decoration: BoxDecoration(
        color: AppColors.lineSoft,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
    );
    if (reduce) return block;

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final t = _c.value; // 0..1
          return ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (rect) {
              return LinearGradient(
                begin: Alignment(-1 + 2 * t - 0.6, 0),
                end: Alignment(-1 + 2 * t + 0.6, 0),
                colors: const [
                  Color(0x00FFFFFF),
                  Color(0x99FFFFFF),
                  Color(0x00FFFFFF),
                ],
                stops: const [0.35, 0.5, 0.65],
              ).createShader(Rect.fromLTWH(0, 0, rect.width, rect.height));
            },
            child: child,
          );
        },
        child: block,
      ),
    );
  }
}

/// One placeholder row matching a list-item silhouette:
/// 40px avatar + two text bars + a trailing pill.
class SkeletonListRow extends StatelessWidget {
  const SkeletonListRow({super.key});
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Skeleton.circle(40),
          SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Skeleton(height: 11, width: double.infinity),
                SizedBox(height: 7),
                Skeleton(height: 9, width: 120),
              ],
            ),
          ),
          SizedBox(width: 11),
          Skeleton(width: 44, height: 22, radius: 999),
        ],
      ),
    );
  }
}

/// Fade + slide-in wrapper for revealed content, staggered by [index].
class RevealIn extends StatelessWidget {
  final int index;
  final Widget child;
  const RevealIn({super.key, required this.index, required this.child});

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      builder: (context, v, c) {
        final delayed = ((v * 1.3) - (index * 0.12)).clamp(0.0, 1.0);
        return Opacity(
          opacity: delayed,
          child: Transform.translate(
              offset: Offset(0, (1 - delayed) * 10), child: c),
        );
      },
      child: child,
    );
  }
}

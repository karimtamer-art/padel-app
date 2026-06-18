import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Press-to-compress: scales its child down to [pressedScale] while held, then
/// springs back. Wrap arbitrary tappables (cards, custom buttons). For
/// [AppButton] the compress is baked into its InkWell directly so the ripple is
/// preserved — use this for tap targets that don't already own a Material ink.
class PressableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double pressedScale;
  const PressableScale(
      {super.key,
      required this.child,
      this.onTap,
      this.pressedScale = 0.95});
  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  double _scale = 1;
  void _set(bool down) {
    if (MediaQuery.of(context).disableAnimations) return;
    setState(() => _scale = down ? widget.pressedScale : 1);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// Fly-to-cart: a small token arcs from the add-button to the cart icon, then
/// fires [onArrive] (where you bump the cart count). Provide [GlobalKey]s placed
/// on the add-button and the cart icon.
class FlyToCart {
  static void run({
    required BuildContext context,
    required GlobalKey fromKey,
    required GlobalKey toKey,
    required VoidCallback onArrive,
    IconData icon = Icons.sports_tennis_rounded,
  }) {
    if (MediaQuery.of(context).disableAnimations) {
      onArrive();
      return;
    }
    final fromBox = fromKey.currentContext?.findRenderObject() as RenderBox?;
    final toBox = toKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context, rootOverlay: true);
    if (fromBox == null || toBox == null) {
      onArrive();
      return;
    }

    final start = fromBox.localToGlobal(fromBox.size.center(Offset.zero));
    final end = toBox.localToGlobal(toBox.size.center(Offset.zero));

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _FlyingToken(
        start: start,
        end: end,
        icon: icon,
        onDone: () {
          entry.remove();
          onArrive();
        },
      ),
    );
    overlay.insert(entry);
  }
}

class _FlyingToken extends StatefulWidget {
  final Offset start, end;
  final IconData icon;
  final VoidCallback onDone;
  const _FlyingToken(
      {required this.start,
      required this.end,
      required this.icon,
      required this.onDone});
  @override
  State<_FlyingToken> createState() => _FlyingTokenState();
}

class _FlyingTokenState extends State<_FlyingToken>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 600))
    ..forward()
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    });

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = Curves.easeInCubic.transform(_c.value);
        final pos = Offset.lerp(widget.start, widget.end, t)!;
        final scale = 1.0 - 0.7 * t;
        final opacity =
            _c.value > 0.8 ? (1 - (_c.value - 0.8) / 0.2) : 1.0;
        return Positioned(
          left: pos.dx - 11,
          top: pos.dy - 11,
          child: Opacity(
            opacity: opacity.clamp(0, 1),
            child: Transform.scale(
              scale: scale,
              child: Container(
                width: 22,
                height: 22,
                decoration: const BoxDecoration(
                    color: AppColors.primary, shape: BoxShape.circle),
                child: Icon(widget.icon, size: 13, color: AppColors.primaryInk),
              ),
            ),
          ),
        );
      },
    );
  }
}

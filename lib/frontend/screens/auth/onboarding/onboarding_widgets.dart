import 'package:flutter/material.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_spacing.dart';
import '../../../theme/app_text.dart';

/// Animated segmented progress bar shown at the top of onboarding.
class OnbProgress extends StatelessWidget {
  final int step; // 0-based
  final int total;
  const OnbProgress({super.key, required this.step, required this.total});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      for (int i = 0; i < total; i++) ...[
        Expanded(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOut,
            height: 6,
            decoration: BoxDecoration(
              color: i <= step ? AppColors.primary : AppColors.line,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
        if (i < total - 1) const SizedBox(width: 6),
      ],
    ]);
  }
}

/// Large, touch-friendly selectable card. Animates a lift + accent ring when
/// chosen. Use as a grid cell or full-width row item.
class ChoiceCard extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Provide either an [icon] or a custom [glyph] (e.g. a court diagram).
  final IconData? icon;
  final bool flipIcon;
  final Widget? glyph;

  /// Card height — keep generous for thumb targets.
  final double height;

  const ChoiceCard({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.flipIcon = false,
    this.glyph,
    this.height = 132,
  });

  @override
  Widget build(BuildContext context) {
    final accent = selected ? AppColors.primary : AppColors.ink;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        height: height,
        transform: selected
            ? Matrix4.translationValues(0.0, -2.0, 0.0)
            : Matrix4.identity(),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withValues(alpha: 0.10) : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.line,
            width: selected ? 2 : 1.5,
          ),
          boxShadow: selected
              ? [BoxShadow(color: AppColors.primary.withValues(alpha: 0.18), blurRadius: 22, offset: const Offset(0, 10))]
              : kCardShadow,
        ),
        child: Stack(children: [
          // selected check
          AnimatedPositioned(
            duration: const Duration(milliseconds: 160),
            top: selected ? 12 : 8,
            right: 12,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 160),
              opacity: selected ? 1 : 0,
              child: Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
                child: const Icon(Icons.check_rounded, size: 15, color: AppColors.primaryInk),
              ),
            ),
          ),
          Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                height: 56,
                child: Center(
                  child: glyph ??
                      Transform.flip(
                        flipX: flipIcon,
                        child: Icon(icon, size: 40, color: selected ? AppColors.primary : AppColors.inkSoft),
                      ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                label,
                textAlign: TextAlign.center,
                style: AppText.cardTitle(accent).copyWith(
                    fontSize: 16, fontWeight: selected ? FontWeight.w800 : FontWeight.w700),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Padel-court diagram highlighting the chosen half — used for Court Side.
class CourtSideGlyph extends StatelessWidget {
  final bool leftActive;
  final bool selected;
  const CourtSideGlyph({super.key, required this.leftActive, required this.selected});

  @override
  Widget build(BuildContext context) {
    final c = selected ? AppColors.primary : AppColors.inkFaint;
    final fill = selected ? AppColors.primary.withValues(alpha: 0.18) : AppColors.primary.withValues(alpha: 0.06);
    final left = leftActive ? fill : Colors.transparent;
    final right = leftActive ? Colors.transparent : fill;
    return Container(
      width: 70,
      height: 46,
      decoration: BoxDecoration(border: Border.all(color: c, width: 2), borderRadius: BorderRadius.circular(6)),
      child: Stack(children: [
        Row(children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(color: left, border: Border(right: BorderSide(color: c, width: 1.5))),
            ),
          ),
          Expanded(child: Container(color: right)),
        ]),
        Center(
          child: Container(width: 7, height: 7, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        ),
      ]),
    );
  }
}

/// Inline error chip (validation / save failures).
class OnbErrorBar extends StatelessWidget {
  final String message;
  const OnbErrorBar(this.message, {super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.btn),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.30)),
      ),
      child: Row(children: [
        const Icon(Icons.error_outline_rounded, size: 18, color: AppColors.danger),
        const SizedBox(width: 10),
        Expanded(
          child: Text(message,
              style: AppText.bodyStrong(AppColors.danger).copyWith(fontSize: 12.5, height: 1.35)),
        ),
      ]),
    );
  }
}

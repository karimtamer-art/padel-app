import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text.dart';

/// ── Card ───────────────────────────────────────────────────────
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final bool active;
  final Color? color;
  final Color? borderColor;
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.card),
    this.onTap,
    this.active = false,
    this.color,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: padding,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: color ?? AppColors.surface,
        borderRadius: AppRadius.cardR,
        border: Border.all(
          color: borderColor ??
              (active ? AppColors.primary.withValues(alpha: 0.45) : AppColors.line),
          width: borderColor != null ? 1.5 : 1,
        ),
        boxShadow: kCardShadow,
      ),
      child: child,
    );
    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(borderRadius: AppRadius.cardR, onTap: onTap, child: card),
    );
  }
}

/// ── Tag / pill badge ───────────────────────────────────────────
class AppTag extends StatelessWidget {
  final String text;
  final Color color;
  final bool solid;
  final Widget? leading;
  const AppTag(this.text,
      {super.key, this.color = AppColors.inkSoft, this.solid = false, this.leading});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: solid ? color : color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 4)],
          Text(text.toUpperCase(),
              style: AppText.tag(solid ? AppColors.surface : color)),
        ],
      ),
    );
  }
}

/// ── Tier badge (dot + name) ────────────────────────────────────
class TierBadge extends StatelessWidget {
  final String tier;
  const TierBadge(this.tier, {super.key});
  @override
  Widget build(BuildContext context) {
    final c = AppColors.tier(tier);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 6, height: 6, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
      const SizedBox(width: 4),
      Text(tier.toUpperCase(), style: AppText.tag(c)),
    ]);
  }
}

/// ── Avatar (initials, tinted ring) ─────────────────────────────
class AppAvatar extends StatelessWidget {
  final String initials;
  final double size;
  final Color color;
  final double ring;

  /// The player's photo (`profiles.avatar_url`). Null/empty shows [initials].
  /// Until this existed the widget could ONLY draw initials, so an uploaded
  /// profile picture never appeared anywhere that used it.
  final String? imageUrl;

  const AppAvatar(this.initials,
      {super.key,
      this.size = 44,
      this.color = AppColors.primary,
      this.ring = 2,
      this.imageUrl});

  @override
  Widget build(BuildContext context) {
    final url = imageUrl?.trim() ?? '';
    final label = Text(initials,
        style: AppText.bodyStrong(color).copyWith(
            fontSize: size * 0.34, fontWeight: FontWeight.w800));
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.14),
        border: Border.all(color: color, width: ring),
      ),
      child: url.isEmpty
          ? label
          : Image.network(
              url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              // A broken or expired URL must never leave a blank circle —
              // fall back to the initials that were there before.
              errorBuilder: (_, __, ___) => Center(child: label),
              loadingBuilder: (_, child, progress) =>
                  progress == null ? child : Center(child: label),
            ),
    );
  }
}

/// ── Button ─────────────────────────────────────────────────────
enum AppBtnVariant { solid, accent, outline, ghost }

class AppButton extends StatefulWidget {
  final String label;
  final VoidCallback? onPressed;
  final AppBtnVariant variant;
  final IconData? icon;
  final bool full;
  final double height;
  const AppButton(this.label,
      {super.key,
      this.onPressed,
      this.variant = AppBtnVariant.solid,
      this.icon,
      this.full = false,
      this.height = 40});

  @override
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton> {
  // press-to-compress; driven by the InkWell so the ripple is preserved
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onPressed == null;
    late Color bg, fg;
    BoxBorder? border;
    switch (widget.variant) {
      case AppBtnVariant.solid:
        bg = disabled ? AppColors.line : AppColors.primary;
        fg = disabled ? AppColors.inkFaint : AppColors.primaryInk;
        break;
      case AppBtnVariant.accent:
        bg = AppColors.accent;
        fg = AppColors.accentInk;
        break;
      case AppBtnVariant.outline:
        bg = Colors.transparent;
        fg = AppColors.primary;
        border = Border.all(color: AppColors.primary, width: 1.4);
        break;
      case AppBtnVariant.ghost:
        bg = AppColors.field;
        fg = AppColors.ink;
        break;
    }
    return AnimatedScale(
      scale: _pressed ? 0.96 : 1,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: SizedBox(
        width: widget.full ? double.infinity : null,
        height: widget.height,
        child: Material(
          color: bg,
          borderRadius: AppRadius.btnR,
          child: InkWell(
            borderRadius: AppRadius.btnR,
            onTap: widget.onPressed,
            onHighlightChanged: (v) {
              if (MediaQuery.of(context).disableAnimations) return;
              setState(() => _pressed = v);
            },
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              decoration:
                  BoxDecoration(borderRadius: AppRadius.btnR, border: border),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.icon != null) ...[
                    Icon(widget.icon, size: 16, color: fg),
                    const SizedBox(width: 6)
                  ],
                  Text(widget.label,
                      style: AppText.bodyStrong(fg)
                          .copyWith(fontWeight: FontWeight.w800, fontSize: 13)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// ── Section header ─────────────────────────────────────────────
class SectionHeader extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onAction;
  const SectionHeader(this.title, {super.key, this.action, this.onAction});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 0, AppSpacing.screen, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
              child: Text(title,
                  style: AppText.cardTitle().copyWith(fontSize: 19))),
          if (action != null)
            GestureDetector(
              onTap: onAction,
              child: Text(action!, style: AppText.bodyStrong(AppColors.primary)),
            ),
        ],
      ),
    );
  }
}

/// ── Progress bar ───────────────────────────────────────────────
class AppBar2 extends StatelessWidget {
  final double value;
  final Color color;
  final double height;
  const AppBar2(this.value, {super.key, this.color = AppColors.primary, this.height = 7});
  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: LinearProgressIndicator(
        value: value.clamp(0, 1),
        minHeight: height,
        backgroundColor: AppColors.line,
        valueColor: AlwaysStoppedAnimation(color),
      ),
    );
  }
}

/// ── Striped image placeholder ──────────────────────────────────
class StripedPlaceholder extends StatelessWidget {
  final double height;
  final IconData icon;
  final Color color;
  final BorderRadius? radius;
  const StripedPlaceholder(
      {super.key,
      this.height = 120,
      this.icon = Icons.sports_tennis,
      this.color = AppColors.primary,
      this.radius});
  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: radius ?? AppRadius.cardR,
      child: Container(
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          border: Border.all(color: AppColors.lineSoft),
        ),
        child: Icon(icon, size: (height * 0.34).clamp(20, 46), color: color.withValues(alpha: 0.5)),
      ),
    );
  }
}

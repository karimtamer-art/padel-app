import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../theme/app_spacing.dart';

/// Translucent sticky app bar used across screens.
class ScreenBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final bool big;
  final bool accentTitle;
  final List<Widget> actions;
  final String? leadingInitials;
  final VoidCallback? onBack;
  const ScreenBar({
    super.key,
    required this.title,
    this.big = false,
    this.accentTitle = false,
    this.actions = const [],
    this.leadingInitials,
    this.onBack,
  });

  @override
  Size get preferredSize => Size.fromHeight(big ? 64 : 56);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
          AppSpacing.screen, MediaQuery.of(context).padding.top + 6, AppSpacing.screen, 10),
      decoration: const BoxDecoration(
        color: AppColors.bg,
        border: Border(bottom: BorderSide(color: AppColors.lineSoft)),
      ),
      child: Row(
        children: [
          if (onBack != null) ...[
            _SquareBtn(icon: Icons.chevron_left_rounded, onTap: onBack!),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Text(
              big ? title : title.toUpperCase(),
              style: big
                  ? AppText.bigTitle(accentTitle ? AppColors.primary : AppColors.ink)
                  : AppText.barTitle(accentTitle ? AppColors.primary : AppColors.ink),
            ),
          ),
          ...actions,
          if (leadingInitials != null) ...[
            const SizedBox(width: 8),
            _Avatar(leadingInitials!),
          ],
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String initials;
  const _Avatar(this.initials);
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.primary.withValues(alpha: 0.14),
        border: Border.all(color: AppColors.primary, width: 1.5),
      ),
      child: Text(initials,
          style: AppText.bodyStrong(AppColors.primary).copyWith(fontSize: 12)),
    );
  }
}

class IconChip extends StatelessWidget {
  final IconData icon;
  final int badge;
  final VoidCallback? onTap;
  const IconChip(this.icon, {super.key, this.badge = 0, this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(clipBehavior: Clip.none, children: [
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: AppColors.field, borderRadius: BorderRadius.circular(11)),
          child: Icon(icon, size: 19, color: AppColors.ink),
        ),
        if (badge > 0)
          Positioned(
            top: -5,
            right: -5,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              constraints: const BoxConstraints(minWidth: 17),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: AppColors.primary, borderRadius: BorderRadius.circular(9)),
              child: Text('$badge',
                  style: AppText.tag(AppColors.primaryInk).copyWith(fontSize: 10)),
            ),
          ),
      ]),
    );
  }
}

class _SquareBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _SquareBtn({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
            color: AppColors.field, borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, size: 22, color: AppColors.ink),
      ),
    );
  }
}

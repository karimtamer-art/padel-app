import 'package:flutter/material.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/screen_bar.dart';

/// Standard page chrome for settings / detail screens.
class SettingsScaffold extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final List<Widget> actions;
  final EdgeInsetsGeometry? padding;
  const SettingsScaffold({
    super.key,
    required this.title,
    required this.children,
    this.actions = const [],
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: ScreenBar(
        title: title,
        onBack: () => Navigator.pop(context),
        actions: actions,
      ),
      body: ListView(
        padding: padding ??
            EdgeInsets.fromLTRB(AppSpacing.screen, 16, AppSpacing.screen,
                MediaQuery.of(context).padding.bottom + 32),
        children: children,
      ),
    );
  }
}

/// Uppercase section label above a group.
class SectionLabel extends StatelessWidget {
  final String text;
  final EdgeInsetsGeometry padding;
  const SectionLabel(this.text,
      {super.key, this.padding = const EdgeInsets.fromLTRB(2, 4, 2, 10)});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Text(text.toUpperCase(), style: AppText.kicker()),
    );
  }
}

/// Group of tiles inside one rounded card (auto-draws dividers).
class TileGroup extends StatelessWidget {
  final List<Widget> children;
  const TileGroup({super.key, required this.children});
  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(children: [
        for (int i = 0; i < children.length; i++) ...[
          if (i > 0) const Divider(height: 1, color: AppColors.line),
          children[i],
        ],
      ]),
    );
  }
}

/// Tappable row: icon · title (+subtitle) · trailing/chevron.
class NavTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? tint;
  final bool chevron;
  const NavTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.tint,
    this.chevron = true,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: (tint ?? AppColors.primary).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 19, color: tint ?? AppColors.primary),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title,
                    style: AppText.body(tint ?? AppColors.ink)
                        .copyWith(fontSize: 15, fontWeight: FontWeight.w700)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: AppText.small().copyWith(fontSize: 12)),
                ],
              ]),
            ),
            if (trailing != null) trailing!,
            if (trailing == null && chevron)
              const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.inkFaint),
          ]),
        ),
      ),
    );
  }
}

/// Row with a themed toggle on the right.
class SwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const SwitchTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    return NavTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      chevron: false,
      onTap: () => onChanged(!value),
      trailing: Switch.adaptive(
        value: value,
        onChanged: onChanged,
        activeThumbColor: AppColors.primaryInk,
        activeTrackColor: AppColors.primary,
        inactiveThumbColor: AppColors.surface,
        inactiveTrackColor: AppColors.line,
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
    );
  }
}

/// Small status pill (reuses AppTag look) for tournament states etc.
Color statusColor(String status) {
  switch (status.toLowerCase()) {
    case 'open':
    case 'registered':
    case 'won':
      return AppColors.success;
    case 'full':
    case 'lost':
      return AppColors.danger;
    case 'upcoming':
      return AppColors.warn;
    default:
      return AppColors.inkSoft;
  }
}

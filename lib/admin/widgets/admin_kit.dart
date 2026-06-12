import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/admin_colors.dart';

class AdminText {
  AdminText._();
  static TextStyle sans(double size, FontWeight w, Color c,
          {double ls = 0, double? height}) =>
      GoogleFonts.outfit(fontSize: size, fontWeight: w, color: c, letterSpacing: ls, height: height);
  static TextStyle mono(double size, FontWeight w, Color c, {double ls = 0}) =>
      GoogleFonts.jetBrainsMono(fontSize: size, fontWeight: w, color: c, letterSpacing: ls);

  static TextStyle h1([Color c = AdminColors.ink]) => sans(22, FontWeight.w800, c, ls: -0.6);
  static TextStyle h2([Color c = AdminColors.ink]) => sans(16, FontWeight.w800, c, ls: -0.2);
  static TextStyle cardTitle([Color c = AdminColors.ink]) => sans(14.5, FontWeight.w800, c, ls: -0.2);
  static TextStyle body([Color c = AdminColors.ink]) => sans(13.5, FontWeight.w600, c);
  static TextStyle strong([Color c = AdminColors.ink]) => sans(13, FontWeight.w700, c);
  static TextStyle small([Color c = AdminColors.inkSoft]) => sans(12, FontWeight.w500, c);
  static TextStyle kicker([Color c = AdminColors.inkFaint]) =>
      mono(10.5, FontWeight.w700, c, ls: 0.8);
}

class AdminCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;
  const AdminCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.onTap, this.color});
  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? AdminColors.surface,
        borderRadius: AdminUI.cardR,
        border: Border.all(color: AdminColors.line),
        boxShadow: AdminColors.cardShadow,
      ),
      child: child,
    );
    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(borderRadius: AdminUI.cardR, onTap: onTap, child: card),
    );
  }
}

class StatCard extends StatelessWidget {
  final IconData icon;
  final Color tone;
  final String label, value, foot;
  final double? delta;
  const StatCard({super.key, required this.icon, required this.tone, required this.label, required this.value, this.foot = '', this.delta});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AdminColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AdminColors.line),
        boxShadow: AdminColors.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 30, height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: AdminColors.wash(tone, 0.14), borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, size: 17, color: tone),
            ),
            const Spacer(),
            if (delta != null)
              Row(children: [
                Icon(delta! >= 0 ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                    size: 13, color: delta! >= 0 ? AdminColors.success : AdminColors.danger),
                Text('${delta!.abs()}%',
                    style: AdminText.mono(11, FontWeight.w800, delta! >= 0 ? AdminColors.success : AdminColors.danger)),
              ]),
          ]),
          const SizedBox(height: 10),
          Text(label.toUpperCase(), style: AdminText.kicker(), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 5),
          Text(value, style: AdminText.sans(22, FontWeight.w800, AdminColors.ink, ls: -0.6)),
          if (foot.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(foot, style: AdminText.small(), maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ],
      ),
    );
  }
}

class KpiGrid extends StatelessWidget {
  final List<Widget> children;
  const KpiGrid(this.children, {super.key});
  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.45,
      children: children,
    );
  }
}

class StatusBadge extends StatelessWidget {
  final String status;
  final bool dot;
  const StatusBadge(this.status, {super.key, this.dot = false});

  static const _map = <String, List<dynamic>>{
    'active': [AdminColors.success, 'Active'],
    'unverified': [AdminColors.warn, 'Unverified'],
    'flagged': [AdminColors.info, 'Flagged'],
    'banned': [AdminColors.danger, 'Banned'],
    'in': [AdminColors.success, 'In stock'],
    'low': [AdminColors.warn, 'Low'],
    'out': [AdminColors.danger, 'Out'],
    'Open': [AdminColors.success, 'Open'],
    'Upcoming': [AdminColors.info, 'Upcoming'],
    'Full': [AdminColors.warn, 'Full'],
    'Completed': [AdminColors.inkSoft, 'Completed'],
    'maintenance': [AdminColors.warn, 'Maintenance'],
    'new': [AdminColors.warn, 'New'],
    'quoted': [AdminColors.info, 'Quoted'],
    'in_repair': [AdminColors.primary, 'In repair'],
    'ready': [AdminColors.green, 'Ready'],
    'collected': [AdminColors.inkSoft, 'Collected'],
    'offered': [AdminColors.info, 'Offer sent'],
    'accepted': [AdminColors.success, 'Accepted'],
    'declined': [AdminColors.danger, 'Declined'],
    'completed': [AdminColors.inkSoft, 'Completed'],
  };

  @override
  Widget build(BuildContext context) {
    final spec = _map[status] ?? [AdminColors.inkSoft, status];
    final Color c = spec[0] as Color;
    final String label = spec[1] as String;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: AdminColors.wash(c, 0.14), borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (dot) ...[
          Container(width: 6, height: 6, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 5),
        ],
        Text(label, style: AdminText.sans(11, FontWeight.w700, c)),
      ]),
    );
  }
}

class AdminAvatar extends StatelessWidget {
  final String initials;
  final double size;
  final Color color;
  const AdminAvatar(this.initials, {super.key, this.size = 32, this.color = AdminColors.green});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: size, height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: AdminColors.wash(color, 0.16)),
      child: Text(initials, style: AdminText.sans(size * 0.36, FontWeight.w800, color)),
    );
  }
}

enum AdminBtn { primary, ghost, soft, danger, success }

class AdminButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final AdminBtn variant;
  final IconData? icon;
  final bool full;
  final double height;
  const AdminButton(this.label, {super.key, this.onPressed, this.variant = AdminBtn.primary, this.icon, this.full = false, this.height = 40});
  @override
  Widget build(BuildContext context) {
    late Color bg, fg;
    Border? border;
    switch (variant) {
      case AdminBtn.primary:
        bg = AdminColors.primary; fg = AdminColors.primaryInk; break;
      case AdminBtn.ghost:
        bg = AdminColors.surface; fg = AdminColors.ink; border = Border.all(color: AdminColors.line); break;
      case AdminBtn.soft:
        bg = AdminColors.surfaceAlt; fg = AdminColors.ink; break;
      case AdminBtn.danger:
        bg = AdminColors.wash(AdminColors.danger, 0.12); fg = AdminColors.danger; break;
      case AdminBtn.success:
        bg = AdminColors.success; fg = Colors.white; break;
    }
    return SizedBox(
      width: full ? double.infinity : null,
      height: height,
      child: Material(
        color: bg,
        borderRadius: AdminUI.btnR,
        child: InkWell(
          borderRadius: AdminUI.btnR,
          onTap: onPressed,
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(borderRadius: AdminUI.btnR, border: border),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[Icon(icon, size: 16, color: fg), const SizedBox(width: 7)],
              Text(label, style: AdminText.sans(13, FontWeight.w700, fg)),
            ]),
          ),
        ),
      ),
    );
  }
}

class AdminSection extends StatelessWidget {
  final String title;
  final String? sub;
  final Widget? action;
  const AdminSection(this.title, {super.key, this.sub, this.action});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: AdminText.h2()),
            if (sub != null) ...[const SizedBox(height: 2), Text(sub!, style: AdminText.small())],
          ]),
        ),
        if (action != null) action!,
      ]),
    );
  }
}

class AdminProgress extends StatelessWidget {
  final double value;
  final Color color;
  const AdminProgress(this.value, {super.key, this.color = AdminColors.primary});
  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: LinearProgressIndicator(
        value: value.clamp(0, 1),
        minHeight: 7,
        backgroundColor: AdminColors.surface3,
        valueColor: AlwaysStoppedAnimation(color),
      ),
    );
  }
}

void adminToast(BuildContext context, String msg, {bool ok = true}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AdminColors.ink,
      duration: const Duration(milliseconds: 2400),
      content: Row(children: [
        Icon(ok ? Icons.check_circle_rounded : Icons.notifications_rounded, size: 18, color: AdminColors.primary),
        const SizedBox(width: 10),
        Expanded(child: Text(msg, style: AdminText.strong(AdminColors.surface).copyWith(fontSize: 13))),
      ]),
    ));
}

Future<T?> adminSheet<T>(BuildContext context, {required String title, String? sub, required Widget body, Widget? footer, double heightFactor = 0.82}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => Container(
      height: MediaQuery.of(context).size.height * heightFactor,
      decoration: const BoxDecoration(color: AdminColors.surface, borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      child: Column(children: [
        Container(width: 40, height: 4, margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(color: AdminColors.line, borderRadius: BorderRadius.circular(2))),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 12, 6),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: AdminText.h2()),
                if (sub != null) ...[const SizedBox(height: 2), Text(sub, style: AdminText.small())],
              ]),
            ),
            IconButton(icon: const Icon(Icons.close_rounded, color: AdminColors.inkSoft), onPressed: () => Navigator.pop(context)),
          ]),
        ),
        const Divider(height: 16, color: AdminColors.lineSoft),
        Expanded(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(18, 4, 18, 18), child: body)),
        if (footer != null)
          Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 26),
            decoration: const BoxDecoration(color: AdminColors.surfaceAlt, border: Border(top: BorderSide(color: AdminColors.lineSoft))),
            child: footer,
          ),
      ]),
    ),
  );
}

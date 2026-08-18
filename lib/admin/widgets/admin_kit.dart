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
          const SizedBox(height: 8),
          Text(label.toUpperCase(),
              style: AdminText.kicker().copyWith(height: 1.1),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 5),
          Text(value,
              style: AdminText.sans(22, FontWeight.w800, AdminColors.ink,
                  ls: -0.6, height: 1.0),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          if (foot.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(foot,
                style: AdminText.small().copyWith(height: 1.1),
                maxLines: 1, overflow: TextOverflow.ellipsis),
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
    // Fixed per-card height (not aspect ratio) so cards with a `foot` line
    // never overflow regardless of column width.
    return GridView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        mainAxisExtent: 132,
      ),
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
    'ranked': [AdminColors.success, 'Ranked'],
    'provisional': [AdminColors.warn, 'Provisional'],
    'unranked': [AdminColors.inkFaint, 'Unranked'],
    'flagged': [AdminColors.info, 'Flagged'],
    'banned': [AdminColors.danger, 'Banned'],
    'in': [AdminColors.success, 'In stock'],
    'low': [AdminColors.warn, 'Low'],
    'out': [AdminColors.danger, 'Out'],
    'Open': [AdminColors.success, 'Open'],
    'Upcoming': [AdminColors.info, 'Upcoming'],
    'Full': [AdminColors.warn, 'Full'],
    'Completed': [AdminColors.inkSoft, 'Completed'],
    'open': [AdminColors.success, 'Open'],
    'live': [AdminColors.green, 'Live'],
    'full': [AdminColors.warn, 'Full'],
    'cancelled': [AdminColors.danger, 'Cancelled'],
    'postponed': [AdminColors.gold, 'Postponed'],
    'auto': [AdminColors.info, 'Auto'],
    'maintenance': [AdminColors.warn, 'Maintenance'],
    'hidden': [AdminColors.inkSoft, 'Hidden'],
    'new': [AdminColors.warn, 'New'],
    'quoted': [AdminColors.info, 'Quoted'],
    'in_repair': [AdminColors.primary, 'In repair'],
    'ready': [AdminColors.green, 'Ready'],
    'collected': [AdminColors.inkSoft, 'Collected'],
    // Used rackets: bought to sell on, so "on the shelf" is the working state
    // and "sold" is the finished one — the opposite polarity to stock levels.
    'on_shelf': [AdminColors.info, 'On the shelf'],
    'sold': [AdminColors.success, 'Sold'],
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
  final String? imageUrl;
  const AdminAvatar(this.initials,
      {super.key, this.size = 32, this.color = AdminColors.green, this.imageUrl});
  @override
  Widget build(BuildContext context) {
    final url = imageUrl?.trim();
    if (url != null && url.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          url,
          width: size, height: size, fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _initialsCircle(),
        ),
      );
    }
    return _initialsCircle();
  }

  Widget _initialsCircle() => Container(
        width: size, height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(shape: BoxShape.circle, color: AdminColors.wash(color, 0.16)),
        child: Text(initials, style: AdminText.sans(size * 0.36, FontWeight.w800, color)),
      );
}

/// Full-screen, pinch-zoomable photo viewer. Tap anywhere (or the ✕) to close.
Future<void> showAdminPhoto(BuildContext context, String url) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.92),
    builder: (ctx) => GestureDetector(
      onTap: () => Navigator.pop(ctx),
      child: Stack(children: [
        Center(
          child: InteractiveViewer(
            minScale: 0.8,
            maxScale: 4,
            child: Image.network(
              url,
              fit: BoxFit.contain,
              loadingBuilder: (_, child, progress) => progress == null
                  ? child
                  : const SizedBox(
                      width: 40, height: 40,
                      child: Center(child: CircularProgressIndicator(color: Colors.white70, strokeWidth: 2))),
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48),
            ),
          ),
        ),
        Positioned(
          top: MediaQuery.of(ctx).padding.top + 6, right: 6,
          child: IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white, size: 26),
              onPressed: () => Navigator.pop(ctx)),
        ),
      ]),
    ),
  );
}

enum AdminBtn { primary, ghost, soft, danger, success }

class AdminButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final AdminBtn variant;
  final IconData? icon;
  final bool full;
  final double height;
  final Color? color; // overrides the fill (solid variants) / tint (ghost/danger)
  const AdminButton(this.label, {super.key, this.onPressed, this.variant = AdminBtn.primary, this.icon, this.full = false, this.height = 40, this.color});
  @override
  Widget build(BuildContext context) {
    late Color bg, fg;
    Border? border;
    switch (variant) {
      case AdminBtn.primary:
        bg = color ?? AdminColors.primary; fg = AdminColors.primaryInk; break;
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
        if (action != null) ...[const SizedBox(width: 12), action!],
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
    builder: (ctx) {
      final keyboardHeight = MediaQuery.of(ctx).viewInsets.bottom;
      return Padding(
        padding: EdgeInsets.only(bottom: keyboardHeight),
        child: Container(
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
                IconButton(icon: const Icon(Icons.close_rounded, color: AdminColors.inkSoft), onPressed: () => Navigator.pop(ctx)),
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
    },
  );
}

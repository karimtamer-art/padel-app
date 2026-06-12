import 'package:flutter/material.dart';
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';

class AdminReportsScreen extends StatelessWidget {
  const AdminReportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
      children: [
        const AdminSection('Reports', sub: 'Analytics & exports'),
        _reportCard(
          icon: Icons.people_alt_outlined,
          tone: AdminColors.green,
          title: 'Player growth',
          sub: 'Signups over time, retention, churn',
        ),
        _reportCard(
          icon: Icons.sports_tennis_rounded,
          tone: AdminColors.primary,
          title: 'Match activity',
          sub: 'Matches per day, peak hours, court utilisation',
        ),
        _reportCard(
          icon: Icons.payments_outlined,
          tone: AdminColors.info,
          title: 'Revenue summary',
          sub: 'Store sales, tournament entry fees, repairs',
        ),
        _reportCard(
          icon: Icons.emoji_events_outlined,
          tone: AdminColors.warn,
          title: 'Tournament outcomes',
          sub: 'Registration rates, prize distribution',
        ),
        _reportCard(
          icon: Icons.download_outlined,
          tone: AdminColors.inkSoft,
          title: 'Export data',
          sub: 'Download CSV — players, matches, orders',
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AdminColors.wash(AdminColors.primary, 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AdminColors.wash(AdminColors.primary, 0.2)),
          ),
          child: Row(children: [
            const Icon(Icons.construction_rounded, size: 20, color: AdminColors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Reports coming soon', style: AdminText.strong(AdminColors.primary)),
                const SizedBox(height: 3),
                Text(
                  'Analytics will be wired once match and order data accumulates.',
                  style: AdminText.small(AdminColors.primary),
                ),
              ]),
            ),
          ]),
        ),
      ],
    );
  }

  Widget _reportCard({
    required IconData icon,
    required Color tone,
    required String title,
    required String sub,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: AdminCard(
          child: Row(children: [
            Container(
              width: 40, height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AdminColors.wash(tone, 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 19, color: tone),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: AdminText.strong()),
                const SizedBox(height: 2),
                Text(sub, style: AdminText.small()),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, size: 18, color: AdminColors.inkFaint),
          ]),
        ),
      );
}

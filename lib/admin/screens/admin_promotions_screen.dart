import 'package:flutter/material.dart';
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';

class AdminPromotionsScreen extends StatelessWidget {
  const AdminPromotionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
      children: [
        AdminSection(
          'Promotions',
          sub: 'Discount codes & banners',
          action: AdminButton('Create', icon: Icons.add_rounded, height: 34,
              onPressed: () => adminToast(context, 'Promotions coming soon')),
        ),
        const SizedBox(height: 24),
        _placeholder(
          icon: Icons.local_offer_outlined,
          tone: AdminColors.primary,
          title: 'Discount codes',
          sub: 'Create % or fixed-amount codes for store checkout',
        ),
        _placeholder(
          icon: Icons.image_outlined,
          tone: AdminColors.green,
          title: 'Banners',
          sub: 'In-app promotional banners shown on the home screen',
        ),
        _placeholder(
          icon: Icons.card_giftcard_outlined,
          tone: AdminColors.warn,
          title: 'Store credit',
          sub: 'Issue manual store credit to individual players',
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
                Text('Promotions coming soon', style: AdminText.strong(AdminColors.primary)),
                const SizedBox(height: 3),
                Text('Discount codes and banners will be available in the next update.',
                    style: AdminText.small(AdminColors.primary)),
              ]),
            ),
          ]),
        ),
      ],
    );
  }

  Widget _placeholder({
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
                  borderRadius: BorderRadius.circular(10)),
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
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AdminColors.surfaceAlt,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text('Soon', style: AdminText.sans(11, FontWeight.w700, AdminColors.inkFaint)),
            ),
          ]),
        ),
      );
}

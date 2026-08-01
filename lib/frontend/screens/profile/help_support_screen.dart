import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'settings_common.dart';

/// Support contact details. Referenced anywhere the app tells a player how to
/// reach us, so there is one place to change them.
const String kSupportEmail = 'Padelrivals@gmail.com';
/// As shown to players (local Egyptian format).
const String kSupportPhone = '01501800943';
/// What the dialer is handed — international form, so it works from abroad too.
const String kSupportPhoneDial = '+201501800943';

class HelpSupportScreen extends StatelessWidget {
  const HelpSupportScreen({super.key});

  static Future<void> _launch(BuildContext context, Uri uri) async {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text("Couldn't open ${uri.scheme == 'mailto' ? 'your mail app' : uri.scheme == 'tel' ? 'the dialer' : 'that link'}.")));
    }
  }

  static void _comingSoon(BuildContext context, String what) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('$what is coming soon — email us in the meantime.')));

  static const _faqs = [
    ('How does the ELO ranking work?',
        'You start with 5 placement matches that seed your initial rating. After that, every competitive match adjusts your ELO based on the result and your opponent\'s rating.'),
    ('How do divisions and tiers work?',
        'Players are grouped into divisions (D → A) and tiers (Low / Mid / High) within each. Win consistently against players at or above your level to get promoted.'),
    ('Can I cancel a registered tournament?',
        'Yes — open the tournament from My Tournaments and tap Withdraw. Withdrawals close 48 hours before the first round.'),
    ('How do I find a match?',
        'Open Home to browse open matches near your level, or create your own from the + button and wait for players to join. You can contact players from the match lobby to coordinate.'),
  ];

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: 'Help & Support',
      children: [
        // hero help card
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.hero, AppColors.hero2],
            ),
          ),
          child: Row(children: [
            Container(
              width: 46,
              height: 46,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.support_agent_rounded, size: 24, color: AppColors.primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Need a hand?', style: AppText.cardTitle(AppColors.heroInk).copyWith(fontSize: 17)),
                const SizedBox(height: 3),
                Text('We usually reply within a few hours.',
                    style: AppText.small(AppColors.heroFaint).copyWith(fontSize: 12.5)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 22),

        const SectionLabel('Contact'),
        TileGroup(children: [
          NavTile(icon: Icons.chat_bubble_outline_rounded, title: 'Live Chat', subtitle: 'Coming soon', onTap: () => _comingSoon(context, 'Live chat')),
          NavTile(icon: Icons.mail_outline_rounded, title: 'Email Support', subtitle: kSupportEmail,
              onTap: () => _launch(context, Uri(scheme: 'mailto', path: kSupportEmail, queryParameters: {'subject': 'Padel Rivals support'}))),
          NavTile(icon: Icons.phone_outlined, title: 'Call Us', subtitle: kSupportPhone,
              onTap: () => _launch(context, Uri(scheme: 'tel', path: kSupportPhoneDial))),
        ]),
        const SizedBox(height: 22),

        const SectionLabel('Frequently Asked'),
        TileGroup(children: [for (final f in _faqs) _Faq(question: f.$1, answer: f.$2)]),
        const SizedBox(height: 22),

        const SectionLabel('About'),
        TileGroup(children: [
          NavTile(icon: Icons.description_outlined, title: 'Terms of Service',
              onTap: () => _launch(context, Uri.parse('https://padel.eg/terms'))),
          NavTile(icon: Icons.shield_outlined, title: 'Privacy Policy',
              onTap: () => _launch(context, Uri.parse('https://padel.eg/privacy'))),
          NavTile(icon: Icons.star_outline_rounded, title: 'Rate Padel',
              onTap: () => _comingSoon(context, 'App Store rating')),
        ]),
        const SizedBox(height: 18),
        Center(
          child: Text('Padel Rivals · v1.0.0',
              style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 11, letterSpacing: 0.5)),
        ),
      ],
    );
  }
}

class _Faq extends StatefulWidget {
  final String question, answer;
  const _Faq({required this.question, required this.answer});
  @override
  State<_Faq> createState() => _FaqState();
}

class _FaqState extends State<_Faq> {
  bool _open = false;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(widget.question,
                    style: AppText.bodyStrong().copyWith(fontSize: 14.5)),
              ),
              const SizedBox(width: 10),
              AnimatedRotation(
                turns: _open ? 0.5 : 0,
                duration: const Duration(milliseconds: 180),
                child: const Icon(Icons.expand_more_rounded, size: 20, color: AppColors.inkFaint),
              ),
            ]),
            AnimatedCrossFade(
              firstChild: const SizedBox(width: double.infinity),
              secondChild: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(widget.answer,
                    style: AppText.body(AppColors.inkSoft).copyWith(fontSize: 13, height: 1.5)),
              ),
              crossFadeState: _open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 180),
            ),
          ]),
        ),
      ),
    );
  }
}

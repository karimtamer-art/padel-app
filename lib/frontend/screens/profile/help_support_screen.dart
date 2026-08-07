import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/app_version.dart';
import 'settings_common.dart';

/// Support contact details. Referenced anywhere the app tells a player how to
/// reach us, so there is one place to change them.
/// Forwards to Padelrivals@gmail.com via Cloudflare Email Routing, and is
/// replied to from there through Resend — so it stays one inbox in practice.
/// This is also the address given to App Store Connect and Google Play.
const String kSupportEmail = 'help@padel-rivals.com';
/// As shown to players (local Egyptian format).
const String kSupportPhone = '01501800943';
/// What the dialer is handed — international form, so it works from abroad too.
const String kSupportPhoneDial = '+201501800943';

/// The legal page. One document covers BOTH the terms and the privacy policy
/// ("Padel Rivals — Terms of Agreement"), so both tiles open the same URL.
/// This is also the URL to give Google Play and App Store Connect.
const String kLegalUrl = 'https://sites.google.com/view/padel-rivals/home';

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

  // Keep these true to the app. Every answer below is checked against the
  // live rules (rating engine v2, the match status machine, withdrawal refunds
  // and the season ladder) — if you change those, change these.
  static const _faqs = [
    ('How is my level calculated?',
        'Your level is a single number from 0 to 7. Every confirmed competitive match moves it based on who won, how strong the other pair was and how close the games were — beating stronger opponents moves you more than beating weaker ones. In doubles, each pair is judged on the average of its two levels. Casual matches never affect it.'),
    ('What are placement matches?',
        'You start unranked. Play 5 competitive matches and the app gives you a level. During placement your level moves in bigger steps so it can find your real standard quickly, then it settles down.'),
    ('Why does my level say "provisional"?',
        'Because the app isn\'t confident about it yet — that\'s the reliability figure on your profile. It rises every time you play a competitive match and falls if you go quiet for a while. Once you\'ve played enough, the provisional label disappears.'),
    ('How do divisions and tiers work?',
        'Your level places you in a division: D · Bronze (0–1.9), C · Silver (2.0–3.4), B · Gold (3.5–4.9) and A · Elite (5.0–7.0). Inside each division you sit in the Low, Mid or High third. Raise your level and you move up automatically — there\'s nothing to claim.'),
    ('Does my level drop if I stop playing?',
        'Only after a long break. Go 60 days without a competitive match and your level eases down very slightly over time. It will never fall below your division\'s floor, and never below 1.0, so a break can\'t undo your progress.'),
    ('How do I find a match?',
        'Tap Find a Match on Home — either right now, or pick a day and a time window. You\'ll see open matches near your level that you can join in one tap, and you can create your own from the + button and wait for players. Once a match is full you can contact the other players from the lobby.'),
    ('Who enters the score, and who confirms it?',
        'Any player in the match can submit the result after the start time. A player from the OTHER team then confirms it — only then does it count towards your level. If nobody confirms within 48 hours the submitted score stands. Disagree instead and the match is disputed, and an admin settles it. Casual matches are done as soon as the score goes in.'),
    ('How does the Season Leaderboard work?',
        'It\'s a separate ladder from your level. While a season is running, every confirmed competitive match earns season points — a win is worth more than a loss, and tournaments are worth far more than either. Finish inside a reward bracket when the season closes and you win what that bracket lists.'),
    ('Can I cancel a tournament registration?',
        'Yes — open the tournament and tap Withdraw, at any point. If you paid an entry fee, you get it back only if you withdraw BEFORE the tournament\'s start date; withdrawing on the day itself forfeits the fee.'),
    ('How do payments work?',
        'Tournament entry fees are sent by InstaPay to the organizer running the event, and the organizer confirms your payment. Store orders are cash on delivery, or an InstaPay transfer where you upload the receipt. There\'s no card payment in the app yet.'),
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
              subtitle: 'Terms & privacy — one document',
              onTap: () => _launch(context, Uri.parse(kLegalUrl))),
          NavTile(icon: Icons.shield_outlined, title: 'Privacy Policy',
              onTap: () => _launch(context, Uri.parse(kLegalUrl))),
          NavTile(icon: Icons.star_outline_rounded, title: 'Rate Padel',
              onTap: () => _comingSoon(context, 'App Store rating')),
        ]),
        const SizedBox(height: 18),
        Center(
          child: Text('Padel Rivals · v$kAppVersion',
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

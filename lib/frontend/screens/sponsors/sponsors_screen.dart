import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/screen_bar.dart';
import 'package:padel_clay/frontend/widgets/padel_refresh.dart';
import 'package:padel_clay/backend/services/sponsor_service.dart';

/// "Our Partners" — the brands and clubs backing the platform.
///
/// Read-only for players: a hero, then the sponsors grouped by tier (title
/// partners get a full-width feature card, everyone else a compact row). Tap
/// one to open its detail sheet, and from there its website.
class SponsorsScreen extends StatefulWidget {
  const SponsorsScreen({super.key});

  @override
  State<SponsorsScreen> createState() => _SponsorsScreenState();
}

class _SponsorsScreenState extends State<SponsorsScreen> {
  List<Sponsor> _sponsors = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await SponsorService.fetchActive();
    if (!mounted) return;
    setState(() {
      _sponsors = rows;
      _loading = false;
    });
  }

  /// Tier colour, reusing the palette's existing tier ramp so partners read as
  /// part of the same visual language as player tiers.
  static Color _tierColor(SponsorTier t) => switch (t) {
        SponsorTier.title => AppColors.primary,
        SponsorTier.gold => AppColors.gold,
        SponsorTier.silver => AppColors.silver,
        SponsorTier.partner => AppColors.accent,
      };

  @override
  Widget build(BuildContext context) {
    final title = _sponsors.where((s) => s.tier == SponsorTier.title).toList();
    final rest = _sponsors.where((s) => s.tier != SponsorTier.title).toList();

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: ScreenBar(
        title: 'Our Partners',
        onBack: () => Navigator.pop(context),
      ),
      body: PadelRefresh(
        onRefresh: _load,
        padding: EdgeInsets.fromLTRB(AppSpacing.screen, 16, AppSpacing.screen,
            MediaQuery.of(context).padding.bottom + 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _hero(),
            if (_loading) ...[
              const SizedBox(height: 28),
              const Center(
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.primary),
              ),
            ] else if (_sponsors.isEmpty)
              _empty()
            else ...[
              if (title.isNotEmpty) ...[
                const SizedBox(height: 24),
                _label('Title Partner${title.length > 1 ? 's' : ''}'),
                for (final s in title) ...[
                  _featureCard(s),
                  const SizedBox(height: AppSpacing.gap),
                ],
              ],
              if (rest.isNotEmpty) ...[
                SizedBox(height: title.isEmpty ? 24 : 12),
                _label('Supported by'),
                for (final s in rest) ...[
                  _row(s),
                  const SizedBox(height: AppSpacing.gap),
                ],
              ],
              const SizedBox(height: 8),
              _becomeAPartner(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 0, 2, 12),
        child: Text(text.toUpperCase(), style: AppText.kicker()),
      );

  Widget _hero() => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.card),
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
            child: const Icon(Icons.handshake_rounded,
                size: 24, color: AppColors.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('The people behind the game',
                  style: AppText.cardTitle(AppColors.heroInk)
                      .copyWith(fontSize: 16)),
              const SizedBox(height: 4),
              Text(
                  'Every tournament, prize and giveaway on here is backed by '
                  'someone. These are them.',
                  style: AppText.small(AppColors.heroFaint).copyWith(height: 1.45)),
            ]),
          ),
        ]),
      );

  Widget _empty() => Padding(
        padding: const EdgeInsets.only(top: 28),
        child: AppCard(
          child: Column(children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: AppColors.wash(AppColors.primary),
                  borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.handshake_outlined,
                  size: 24, color: AppColors.primary),
            ),
            const SizedBox(height: 12),
            Text('No partners yet', style: AppText.cardTitle()),
            const SizedBox(height: 4),
            Text('This page fills up as brands come on board.',
                textAlign: TextAlign.center, style: AppText.small()),
          ]),
        ),
      );

  /// Title partners — full-width, logo on a tinted plate above the copy.
  Widget _featureCard(Sponsor s) {
    final tone = _tierColor(s.tier);
    return AppCard(
      padding: EdgeInsets.zero,
      borderColor: tone.withValues(alpha: 0.35),
      onTap: () => _openSheet(s),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          height: 116,
          width: double.infinity,
          alignment: Alignment.center,
          color: AppColors.wash(tone, 0.10),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
          child: _logo(s, size: 80, tone: tone, contain: true),
        ),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.card),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                  child: Text(s.name,
                      style: AppText.cardTitle(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              AppTag(sponsorTierLabel(s.tier), color: tone),
            ]),
            if (s.tagline != null) ...[
              const SizedBox(height: 6),
              Text(s.tagline!,
                  style: AppText.small().copyWith(height: 1.45),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ],
          ]),
        ),
      ]),
    );
  }

  /// Everyone else — a compact row.
  Widget _row(Sponsor s) {
    final tone = _tierColor(s.tier);
    return AppCard(
      padding: const EdgeInsets.all(12),
      onTap: () => _openSheet(s),
      child: Row(children: [
        _logo(s, size: 52, tone: tone),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.name,
                style: AppText.bodyStrong(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 3),
            Text(s.tagline ?? sponsorTierLabel(s.tier),
                style: AppText.small(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ]),
        ),
        const SizedBox(width: 8),
        AppTag(sponsorTierLabel(s.tier), color: tone),
        const SizedBox(width: 4),
        const Icon(Icons.chevron_right_rounded,
            size: 20, color: AppColors.inkFaint),
      ]),
    );
  }

  /// Logo, falling back to initials on a tinted plate when there's no image
  /// (or the URL fails to load).
  Widget _logo(Sponsor s, {required double size, required Color tone, bool contain = false}) {
    final url = s.logoUrl;
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.wash(tone, 0.14),
        borderRadius: BorderRadius.circular(size * 0.24),
        border: Border.all(color: tone.withValues(alpha: 0.3)),
      ),
      child: Text(s.initials,
          style: AppText.bodyStrong(tone)
              .copyWith(fontSize: size * 0.34, fontWeight: FontWeight.w800)),
    );
    if (url == null) return fallback;
    final image = Image.network(
      url,
      width: contain ? null : size,
      height: size,
      fit: contain ? BoxFit.contain : BoxFit.cover,
      errorBuilder: (_, __, ___) => fallback,
    );
    return contain
        ? image
        : ClipRRect(
            borderRadius: BorderRadius.circular(size * 0.24), child: image);
  }

  void _openSheet(Sponsor s) {
    final tone = _tierColor(s.tier);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: EdgeInsets.fromLTRB(
            AppSpacing.screen, 12, AppSpacing.screen,
            MediaQuery.of(ctx).padding.bottom + 22),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 18),
            decoration: BoxDecoration(
                color: AppColors.line, borderRadius: BorderRadius.circular(2)),
          ),
          Row(children: [
            _logo(s, size: 58, tone: tone),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.name, style: AppText.cardTitle(), maxLines: 2),
                const SizedBox(height: 5),
                AppTag(sponsorTierLabel(s.tier), color: tone),
              ]),
            ),
          ]),
          if (s.blurb != null || s.tagline != null) ...[
            const SizedBox(height: 18),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(s.blurb ?? s.tagline!,
                  style: AppText.body(AppColors.inkSoft).copyWith(height: 1.6)),
            ),
          ],
          if (s.websiteUrl != null) ...[
            const SizedBox(height: 20),
            AppButton('Visit website',
                icon: Icons.open_in_new_rounded,
                full: true,
                height: 48,
                onPressed: () => _launch(ctx, s.websiteUrl!)),
          ],
          const SizedBox(height: 10),
        ]),
      ),
    );
  }

  Widget _becomeAPartner() => AppCard(
        color: AppColors.surfaceAlt,
        child: Row(children: [
          const Icon(Icons.mail_outline_rounded,
              size: 20, color: AppColors.inkSoft),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
                'Want your brand here? Reach us from Profile → Help & Support.',
                style: AppText.small().copyWith(height: 1.45)),
          ),
        ]),
      );

  /// Sponsors type their own URLs in the console, so assume https:// when the
  /// scheme is missing rather than failing to launch.
  static Future<void> _launch(BuildContext context, String raw) async {
    final url = raw.startsWith('http://') || raw.startsWith('https://')
        ? raw
        : 'https://$raw';
    final uri = Uri.tryParse(url);
    var ok = false;
    if (uri != null) {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text("Couldn't open that link.")));
    }
  }
}

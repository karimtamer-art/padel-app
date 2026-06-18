import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';
import '../../widgets/common.dart';
import 'auth_widgets.dart';

/// Brand mark — logo badge + "PADEL RIVALS" wordmark.
class BrandMark extends StatelessWidget {
  final bool light;
  const BrandMark({super.key, this.light = false});
  @override
  Widget build(BuildContext context) {
    final ink = light ? AppColors.heroInk : AppColors.ink;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.asset('assets/brand/logo_mark.png', height: 42),
      ),
      const SizedBox(width: 11),
      Text('PADEL RIVALS',
          style: AppText.barTitle(ink)
              .copyWith(fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 0.5)),
    ]);
  }
}

class WelcomeScreen extends StatelessWidget {
  final VoidCallback onCreate;
  final VoidCallback onSignIn;
  final Future<void> Function()? onGoogle;
  final Future<void> Function()? onApple;

  const WelcomeScreen({
    super.key,
    required this.onCreate,
    required this.onSignIn,
    this.onGoogle,
    this.onApple,
  });

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final hasSocial = onGoogle != null || onApple != null;
    return Container(
      color: AppColors.bg,
      padding: EdgeInsets.fromLTRB(20, top + 14, 20, 34),
      child: Column(children: [
        // hero panel
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(26),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.hero, AppColors.hero2],
                ),
              ),
              child: Stack(children: [
                const Positioned.fill(child: _CourtLines()),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const BrandMark(light: true),
                  const Spacer(),
                  // badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: AppColors.heroFaint),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(width: 6, height: 6, decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle)),
                      const SizedBox(width: 6),
                      Text("EGYPT'S PADEL COMMUNITY",
                          style: AppText.tag(AppColors.heroInk).copyWith(fontSize: 10.5, letterSpacing: 1.2)),
                    ]),
                  ),
                  const SizedBox(height: 16),
                  // headline
                  RichText(
                    text: TextSpan(
                      style: AppText.stat(33, AppColors.heroInk).copyWith(height: 1.08, letterSpacing: -0.8),
                      children: const [
                        TextSpan(text: 'Find Matches.\nBuild Your Team.\n'),
                        TextSpan(text: 'Climb The Rankings.', style: TextStyle(color: AppColors.primary)),
                      ],
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 22),
        if (onGoogle != null) ...[
          GoogleSignInButton(onPressed: onGoogle),
          const SizedBox(height: 11),
        ],
        if (onApple != null) ...[
          SocialButton(provider: 'apple', onPressed: () => onApple?.call()),
          const SizedBox(height: 11),
        ],
        if (hasSocial) ...[
          const OrDivider('or'),
          const SizedBox(height: 11),
        ],
        AppButton('Create Account', full: true, height: 54, onPressed: onCreate),
        const SizedBox(height: 11),
        AppButton('Sign In', full: true, height: 54, variant: AppBtnVariant.ghost, onPressed: onSignIn),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text.rich(
            TextSpan(
              style: AppText.small(AppColors.inkFaint).copyWith(fontSize: 11, height: 1.5),
              children: [
                const TextSpan(text: 'By continuing you agree to our '),
                TextSpan(text: 'Terms', style: AppText.bodyStrong(AppColors.inkSoft).copyWith(fontSize: 11)),
                const TextSpan(text: ' & '),
                TextSpan(text: 'Privacy Policy', style: AppText.bodyStrong(AppColors.inkSoft).copyWith(fontSize: 11)),
                const TextSpan(text: '.'),
              ],
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ]),
    );
  }
}

/// Faint padel-court line motif behind the hero headline.
class _CourtLines extends StatelessWidget {
  const _CourtLines();
  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _CourtPainter());
  }
}

class _CourtPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xFFF4EFE2).withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final w = size.width, h = size.height;
    final r = Rect.fromLTRB(w * 0.09, h * 0.14, w * 0.91, h * 0.86);
    canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(4)), p);
    canvas.drawLine(Offset(w * 0.5, r.top), Offset(w * 0.5, r.bottom), p);
    canvas.drawLine(Offset(r.left, h * 0.38), Offset(r.right, h * 0.38), p);
    canvas.drawLine(Offset(r.left, h * 0.62), Offset(r.right, h * 0.62), p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

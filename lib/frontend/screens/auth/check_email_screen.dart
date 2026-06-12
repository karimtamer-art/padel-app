import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'auth_widgets.dart';

class CheckEmailScreen extends StatelessWidget {
  final String email;
  final VoidCallback onBack;
  const CheckEmailScreen({super.key, required this.email, required this.onBack});

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final bottom = MediaQuery.of(context).padding.bottom;
    return Container(
      color: AppColors.bg,
      padding: EdgeInsets.fromLTRB(20, top + 14, 20, bottom + 30),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        BackSquare(onTap: onBack),
        const Spacer(),
        Center(
          child: Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.mark_email_unread_outlined,
                size: 44, color: AppColors.primary),
          ),
        ),
        const SizedBox(height: 28),
        Center(
          child: Text('Check your inbox',
              textAlign: TextAlign.center,
              style: AppText.stat(29, AppColors.ink)
                  .copyWith(letterSpacing: -0.6, height: 1.0)),
        ),
        const SizedBox(height: 14),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Text.rich(
              TextSpan(
                style: AppText.body(AppColors.inkSoft).copyWith(fontSize: 15, height: 1.55),
                children: [
                  const TextSpan(text: 'We sent a verification link to\n'),
                  TextSpan(
                    text: email,
                    style: AppText.bodyStrong(AppColors.ink).copyWith(fontSize: 15),
                  ),
                ],
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        const SizedBox(height: 28),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppRadius.cardR,
            border: Border.all(color: AppColors.line),
            boxShadow: kCardShadow,
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.info_outline_rounded, size: 20, color: AppColors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Tap the link in the email to verify your account. The app will open automatically and take you to the next step.',
                style: AppText.body(AppColors.inkSoft).copyWith(fontSize: 13, height: 1.5),
              ),
            ),
          ]),
        ),
        const Spacer(),
        Center(
          child: TextButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              try {
                await Supabase.instance.client.auth
                    .resend(type: OtpType.signup, email: email);
                messenger.showSnackBar(SnackBar(
                    behavior: SnackBarBehavior.floating,
                    content: Text('Verification email re-sent to $email.')));
              } on AuthException catch (e) {
                messenger.showSnackBar(SnackBar(
                    behavior: SnackBarBehavior.floating,
                    content: Text(e.message)));
              }
            },
            child: Text('Resend verification email',
                style: AppText.bodyStrong(AppColors.primary).copyWith(fontSize: 14)),
          ),
        ),
      ]),
    );
  }
}

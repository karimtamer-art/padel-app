import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';
import '../../widgets/common.dart';
import '../../../backend/services/auth_service.dart';
import 'auth_widgets.dart';

class SignInScreen extends StatefulWidget {
  final VoidCallback onBack;
  final VoidCallback onCreate;
  final VoidCallback onDone;
  final Future<void> Function()? onGoogle;
  final Future<void> Function()? onApple;
  const SignInScreen({
    super.key,
    required this.onBack,
    required this.onCreate,
    required this.onDone,
    this.onGoogle,
    this.onApple,
  });

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Please enter your email and password.');
      return;
    }
    setState(() { _loading = true; _error = null; });
    final err = await AuthService.signIn(email, password);
    if (!mounted) return;
    if (err != null) {
      setState(() { _loading = false; _error = err; });
    } else {
      setState(() => _loading = false);
      widget.onDone();
    }
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Container(
      color: AppColors.bg,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, top + 14, 20, 30),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            BackSquare(onTap: widget.onBack),
            const SizedBox(height: 20),
            Text('Welcome back',
                style: AppText.stat(29, AppColors.ink)
                    .copyWith(letterSpacing: -0.6, height: 1.0)),
            const SizedBox(height: 8),
            Text('Sign in to pick up your ranking journey.',
                style: AppText.body(AppColors.inkSoft)
                    .copyWith(fontSize: 14, height: 1.5)),
            const SizedBox(height: 26),

            AuthField(
              label: 'Email',
              icon: Icons.mail_outline_rounded,
              hint: 'you@email.com',
              keyboard: TextInputType.emailAddress,
              controller: _email,
            ),
            const SizedBox(height: 16),
            AuthField(
              label: 'Password',
              icon: Icons.lock_outline_rounded,
              hint: '••••••••',
              obscure: true,
              controller: _password,
            ),
            const SizedBox(height: 9),
            Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                onTap: () async {
                  final email = _email.text.trim();
                  final messenger = ScaffoldMessenger.of(context);
                  if (email.isEmpty || !email.contains('@')) {
                    messenger.showSnackBar(const SnackBar(
                        behavior: SnackBarBehavior.floating,
                        content: Text('Enter your email above first, then tap Forgot password.')));
                    return;
                  }
                  try {
                    await Supabase.instance.client.auth
                        .resetPasswordForEmail(email);
                    messenger.showSnackBar(SnackBar(
                        behavior: SnackBarBehavior.floating,
                        content: Text('Password reset link sent to $email.')));
                  } on AuthException catch (e) {
                    messenger.showSnackBar(SnackBar(
                        behavior: SnackBarBehavior.floating,
                        content: Text(e.message)));
                  }
                },
                child: Text('Forgot password?',
                    style: AppText.bodyStrong(AppColors.primary)
                        .copyWith(fontSize: 13)),
              ),
            ),
            const SizedBox(height: 18),

            if (_error != null) ...[
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                decoration: BoxDecoration(
                  color: AppColors.danger.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: AppColors.danger.withValues(alpha: 0.3)),
                ),
                child: Text(_error!,
                    style: AppText.body(AppColors.danger)
                        .copyWith(fontSize: 13, height: 1.4)),
              ),
              const SizedBox(height: 14),
            ],

            AppButton('Sign In',
                full: true,
                height: 54,
                onPressed: _loading ? null : _submit),
            const SizedBox(height: 18),
            const OrDivider('or continue with'),
            const SizedBox(height: 18),
            GoogleSignInButton(onPressed: widget.onGoogle),
            const SizedBox(height: 11),
            SocialButton(provider: 'apple', onPressed: () => widget.onApple?.call()),
            const SizedBox(height: 24),

            Center(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('New to Padel? ',
                    style: AppText.body(AppColors.inkSoft)
                        .copyWith(fontSize: 13.5)),
                GestureDetector(
                  onTap: widget.onCreate,
                  child: Text('Create account',
                      style: AppText.bodyStrong(AppColors.primary)
                          .copyWith(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w800)),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

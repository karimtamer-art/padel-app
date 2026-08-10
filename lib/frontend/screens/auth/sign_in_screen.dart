import 'dart:async';

import 'package:flutter/material.dart';
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

  // Reset-email state. The link used to fire with no visible feedback at all,
  // so people tapped it repeatedly and tripped Supabase's own rate limit — at
  // which point nothing arrives and it looks broken. The label reports what
  // happened, and the cooldown makes a second tap impossible rather than
  // merely pointless.
  bool _resetBusy = false;
  int _resetCooldown = 0;
  Timer? _resetTimer;

  @override
  void initState() {
    super.initState();
    // A cooldown started before this screen was built (or on a previous visit)
    // still applies — pick it up rather than showing a live-looking link.
    _email.addListener(_syncResetCooldown);
    _syncResetCooldown();
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    _email.removeListener(_syncResetCooldown);
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Re-reads the countdown from AuthService, which is where it actually lives.
  /// Called on every tick and whenever the typed email changes, so leaving the
  /// screen and coming back resumes the same clock instead of clearing it.
  void _syncResetCooldown() {
    final left = AuthService.resetCooldownRemaining(_email.text);
    if (left == _resetCooldown) return;
    setState(() => _resetCooldown = left);
    if (left > 0) {
      _resetTimer ??= Timer.periodic(
          const Duration(seconds: 1), (_) => _syncResetCooldown());
    } else {
      _resetTimer?.cancel();
      _resetTimer = null;
    }
  }

  Future<void> _forgotPassword() async {
    final email = _email.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    if (email.isEmpty || !email.contains('@')) {
      messenger.showSnackBar(const SnackBar(
          behavior: SnackBarBehavior.floating,
          content:
              Text('Enter your email above first, then tap Forgot password.')));
      return;
    }
    // Re-check against the shared clock, not just the label: this screen may
    // have been rebuilt since the last send.
    if (AuthService.resetCooldownRemaining(email) > 0) {
      _syncResetCooldown();
      messenger.showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
              'Already sent — check your inbox and spam, or try again in ${_resetCooldown}s.')));
      return;
    }
    setState(() => _resetBusy = true);

    // A Google/Apple account has no password to reset. Sending anyway mails a
    // link that sets a password they'll never use, which reads as a bug.
    // A null answer means the lookup failed — fall through and send rather
    // than block a real reset on a bad connection.
    final methods = await AuthService.loginMethodsFor(email);
    if (!mounted) return;
    if (methods != null &&
        methods.isNotEmpty &&
        !methods.contains('email')) {
      final label = methods.contains('google')
          ? 'Google'
          : (methods.contains('apple') ? 'Apple' : methods.first);
      setState(() => _resetBusy = false);
      messenger.showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
          content: Text(
              'That account signs in with $label — there\'s no password to '
              'reset. Use the $label button below.')));
      return;
    }

    final err = await AuthService.sendPasswordReset(email);
    if (!mounted) return;
    setState(() => _resetBusy = false);
    // Either way the service may have stamped the clock (it does so on a
    // server-side rate-limit too), so always resync before reporting.
    _syncResetCooldown();
    if (err != null) {
      messenger.showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating, content: Text(err)));
      return;
    }
    messenger.showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
        content: Text('Reset link sent to $email. Check your inbox and spam.')));
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
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => FocusScope.of(context).nextFocus(),
            ),
            const SizedBox(height: 16),
            AuthField(
              label: 'Password',
              icon: Icons.lock_outline_rounded,
              hint: '••••••••',
              obscure: true,
              controller: _password,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _loading ? null : _submit(),
            ),
            const SizedBox(height: 9),
            Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                onTap: (_resetBusy || _resetCooldown > 0) ? null : _forgotPassword,
                child: Text(
                    _resetBusy
                        ? 'Sending…'
                        : (_resetCooldown > 0
                            ? 'Sent — retry in ${_resetCooldown}s'
                            : 'Forgot password?'),
                    style: AppText.bodyStrong(
                            (_resetBusy || _resetCooldown > 0)
                                ? AppColors.inkFaint
                                : AppColors.primary)
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
            // Apple sign-in is offered on iOS only (native flow).
            if (widget.onApple != null) ...[
              const SizedBox(height: 11),
              SocialButton(provider: 'apple', onPressed: widget.onApple),
            ],
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

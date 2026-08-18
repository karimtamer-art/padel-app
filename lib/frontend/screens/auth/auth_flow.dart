import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import 'welcome_screen.dart';
import 'sign_in_screen.dart';
import 'sign_up_flow.dart';
import 'check_email_screen.dart';
import 'success_screen.dart';

enum _AuthView { welcome, signIn, signUp, checkEmail, success }

/// Auth gate: Welcome → Sign In / Sign Up → Check Email (or Success).
/// Calls [onAuthenticated] when the user completes email auth.
/// [onGoogleSignIn], when provided, wires the "Continue with Google" buttons —
/// the Supabase auth-state stream (in [AuthGate]) then drives navigation.
class AuthFlow extends StatefulWidget {
  final VoidCallback onAuthenticated;
  final Future<void> Function()? onGoogleSignIn;
  final Future<void> Function()? onAppleSignIn;
  const AuthFlow({super.key, required this.onAuthenticated, this.onGoogleSignIn, this.onAppleSignIn});

  @override
  State<AuthFlow> createState() => _AuthFlowState();
}

class _AuthFlowState extends State<AuthFlow> {
  _AuthView _view = _AuthView.welcome;
  String _email = '';
  String _name = '';

  /// Held only for the confirm-by-code path: the photo picked during sign-up
  /// can't be uploaded until verifying the code produces a session.
  SignUpData? _pending;

  void _go(_AuthView v) => setState(() => _view = v);

  @override
  Widget build(BuildContext context) {
    late final Widget screen;
    switch (_view) {
      case _AuthView.welcome:
        screen = WelcomeScreen(
          onCreate: () => _go(_AuthView.signUp),
          onSignIn: () => _go(_AuthView.signIn),
          onGoogle: widget.onGoogleSignIn,
          onApple: widget.onAppleSignIn,
        );
        break;
      case _AuthView.signIn:
        screen = SignInScreen(
          onBack: () => _go(_AuthView.welcome),
          onCreate: () => _go(_AuthView.signUp),
          onDone: widget.onAuthenticated,
          onGoogle: widget.onGoogleSignIn,
          onApple: widget.onAppleSignIn,
        );
        break;
      case _AuthView.signUp:
        screen = SignUpFlow(
          onExit: () => _go(_AuthView.welcome),
          onComplete: (data, sessionCreated) {
            if (sessionCreated) {
              _name = data.name;
              _go(_AuthView.success);
              return;
            }
            _email = data.email.trim();
            _pending = data;
            _go(_AuthView.checkEmail);
          },
        );
        break;
      case _AuthView.checkEmail:
        screen = CheckEmailScreen(
          email: _email,
          onBack: () => _go(_AuthView.welcome),
          avatarBytes: _pending?.avatarBytes,
          avatarExt: _pending?.avatarExt ?? 'jpg',
        );
        break;
      case _AuthView.success:
        screen = SuccessScreen(name: _name, onDone: widget.onAuthenticated);
        break;
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 320),
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.02), end: Offset.zero).animate(anim),
            child: child,
          ),
        ),
        child: KeyedSubtree(key: ValueKey(_view), child: screen),
      ),
    );
  }
}

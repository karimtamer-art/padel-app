import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';
import '../../widgets/common.dart';
import '../../../backend/services/auth_service.dart';
import '../../../backend/models/onboarding_models.dart';
import '../../../backend/models/ranking_scale.dart';
import '../../../backend/services/profile_service.dart';
import '../../../backend/services/push_service.dart';
import '../../navigation/push_router.dart';
import '../shell/root_scaffold.dart';
import '../splash/splash_screen.dart';
import '../../../../admin/admin_console.dart';
import 'auth_flow.dart';
import 'onboarding/onboarding_flow.dart';

/// Root of the app once Supabase is initialised. Owns the routing decision:
///
/// ```
///                 ┌─ no session ──────────────► AuthFlow (Welcome / Google)
///  AuthGate ──────┤
///                 └─ session ─► check profile ─┬─ complete ─► RootScaffold
///                                              └─ missing ──► OnboardingFlow
/// ```
///
/// The onboarding screen is mandatory: a signed-in user with an incomplete
/// profile can only reach the app by finishing it (or signing out).
class AuthGate extends StatefulWidget {
  final AuthService authService;
  final ProfileService profileService;
  const AuthGate({
    super.key,
    required this.authService,
    required this.profileService,
  });

  @override
  State<AuthGate> createState() => _AuthGateState();
}

enum _Phase { booting, signedOut, checking, onboarding, ready, error }

class _AuthGateState extends State<AuthGate> {
  _Phase _phase = _Phase.booting;
  OnboardingProfile _existing = const OnboardingProfile();
  StreamSubscription<AuthState>? _sub;
  bool _isAdmin = false;

  String _displayName = '';
  String _initials = 'P';
  String _memberSince = '';
  PlayerProfile _playerProfile = PlayerProfile.fresh;

  @override
  void initState() {
    super.initState();
    if (widget.authService.currentUser != null) {
      _resolve();
    } else {
      _phase = _Phase.signedOut;
    }
    _sub = widget.authService.onAuthStateChange.listen((state) {
      switch (state.event) {
        case AuthChangeEvent.signedIn:
        case AuthChangeEvent.initialSession:
        case AuthChangeEvent.userUpdated:
          if (widget.authService.currentUser != null) _resolve();
          break;
        case AuthChangeEvent.signedOut:
          if (mounted) {
            setState(() => _phase = _Phase.signedOut);
          }
          break;
        default:
          break;
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _resolve() async {
    final user = widget.authService.currentUser;
    if (user == null) {
      setState(() => _phase = _Phase.signedOut);
      return;
    }
    setState(() => _phase = _Phase.checking);
    try {
      final profile = await widget.profileService.fetch(user.id);
      if (!mounted) return;
      _existing = profile ?? const OnboardingProfile();
      _isAdmin = profile?.isAdmin ?? false;
      final meta = user.userMetadata ?? {};
      final rawName = (meta['full_name'] ?? meta['name'] ?? user.email ?? 'Player') as String;
      _displayName = rawName.trim();
      _initials = _buildInitials(_displayName);
      _memberSince = _buildMemberSince(DateTime.tryParse(user.createdAt) ?? DateTime.now());
      final complete = profile?.isComplete ?? false;
      // Admins skip player onboarding entirely — straight to the console. They
      // have no player profile to load, and never see the phone/onboarding step.
      if (!_isAdmin && complete) {
        _playerProfile = await ProfileService.fetchPlayerProfile(user.id);
      }
      if (!mounted) return;
      final ready = _isAdmin || complete;
      setState(() => _phase = ready ? _Phase.ready : _Phase.onboarding);
      // Signed in & resolved → register this device for push (Android-only,
      // no-op elsewhere). Fire-and-forget; failures are swallowed internally.
      // Also wire notification taps to deep-link into the right screen.
      if (ready) {
        PushService.registerToken();
        PushRouter.attach();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _phase = _Phase.error);
    }
  }

  Future<void> _signOut() async {
    await PushService.unregister(); // stop push to this device before sign-out
    await widget.authService.signOut();
  }

  static String _buildInitials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return 'P';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  static String _buildMemberSince(DateTime dt) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[dt.month - 1]} ${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final child = switch (_phase) {
      _Phase.booting || _Phase.checking =>
        const SplashScreen(key: ValueKey('splash')),
      _Phase.signedOut => AuthFlow(
          key: const ValueKey('auth'),
          onAuthenticated: _resolve,
          onGoogleSignIn: AuthService.signInWithGoogle,
          onAppleSignIn: AuthService.signInWithApple,
        ),
      _Phase.onboarding => OnboardingFlow(
          key: const ValueKey('onboarding'),
          userId: widget.authService.currentUser!.id,
          displayName: _displayName,
          profileService: widget.profileService,
          initial: _existing,
          onCompleted: _resolve,
          onSignOut: _signOut,
        ),
      _Phase.ready => _isAdmin
          ? AdminConsole(
              key: const ValueKey('admin'),
              onExit: _signOut,
              displayName: _displayName,
              initials: _initials,
            )
          : RootScaffold(
              key: const ValueKey('app'),
              profile: _playerProfile,
              displayName: _displayName,
              initials: _initials,
              memberSince: _memberSince,
              onSignOut: _signOut,
            ),
      _Phase.error => _ErrorView(
          key: const ValueKey('error'),
          onRetry: _resolve,
          onSignOut: _signOut,
        ),
    };

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 320),
      child: child,
    );
  }
}

/// Profile-load failure with retry + sign-out.
class _ErrorView extends StatelessWidget {
  final VoidCallback onRetry;
  final Future<void> Function() onSignOut;
  const _ErrorView({super.key, required this.onRetry, required this.onSignOut});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 64,
                height: 64,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    shape: BoxShape.circle, color: AppColors.danger.withValues(alpha: 0.12)),
                child: const Icon(Icons.wifi_off_rounded, size: 30, color: AppColors.danger),
              ),
              const SizedBox(height: 18),
              Text('Something went wrong',
                  style: AppText.cardTitle().copyWith(fontSize: 19)),
              const SizedBox(height: 8),
              Text("We couldn't load your profile. Check your connection and try again.",
                  textAlign: TextAlign.center,
                  style: AppText.body(AppColors.inkSoft).copyWith(fontSize: 14, height: 1.5)),
              const SizedBox(height: 24),
              AppButton('Try Again', full: true, height: 52, icon: Icons.refresh_rounded, onPressed: onRetry),
              const SizedBox(height: 11),
              AppButton('Sign Out', full: true, height: 52, variant: AppBtnVariant.ghost,
                  onPressed: () => onSignOut()),
            ]),
          ),
        ),
      ),
    );
  }
}

import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/update_gate.dart';
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
import 'set_password_screen.dart';

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

enum _Phase {
  booting,
  signedOut,
  checking,
  onboarding,
  mustSetPassword,
  recovering, // arrived from the reset email — must choose a new password
  ready,
  error
}

class _AuthGateState extends State<AuthGate> {
  _Phase _phase = _Phase.booting;
  OnboardingProfile _existing = const OnboardingProfile();
  StreamSubscription<AuthState>? _sub;
  bool _isStaff = false; // super admin OR a granted staff role (RBAC)

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
        // The reset email's deep link signs the user in with a short-lived
        // recovery session. Jump straight to the new-password form — this must
        // come BEFORE the signedIn cases, which would otherwise drop them into
        // the app with the reset silently unfinished.
        case AuthChangeEvent.passwordRecovery:
          if (mounted) setState(() => _phase = _Phase.recovering);
          break;
        case AuthChangeEvent.signedIn:
        case AuthChangeEvent.initialSession:
        case AuthChangeEvent.userUpdated:
          // Setting the new password fires userUpdated; staying put would bounce
          // them out of the form mid-edit.
          if (_phase == _Phase.recovering) break;
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
      var profile = await widget.profileService.fetch(user.id);
      // No row AT ALL — handle_new_user() failed and swallowed it. Left alone
      // this is survivable and invisible: onboarding appears to save (PostgREST
      // reports no error when a write matches nothing) and the player ends up
      // in the app with no profile and no ranking row. Create it, then read it
      // back once so the rest of this method sees the real thing.
      if (profile == null) {
        await ProfileService.ensureProfile(user);
        profile = await widget.profileService.fetch(user.id);
      }
      if (!mounted) return;
      _existing = profile ?? const OnboardingProfile();
      _isStaff = profile?.isStaff ?? false;
      final meta = user.userMetadata ?? {};
      // profiles.name FIRST. Auth metadata is fixed at signup and never changes,
      // so preferring it meant an edited name never appeared anywhere — the
      // header kept the old one and the save looked broken.
      //
      // user.email is deliberately NOT a fallback any more. Apple puts the name
      // in the credential rather than the ID token, and only on the very first
      // authorization, so an Apple account usually arrives with none — falling
      // back to the address listed Hide-My-Email players as
      // x7k2m9@privaterelay.appleid.com. Onboarding asks for a real one instead.
      final candidates = [
        profile?.name,
        meta['full_name'] as String?,
        meta['name'] as String?,
      ];
      _displayName = candidates
              .firstWhere(OnboardingProfile.isUsableName, orElse: () => null)
              ?.trim() ??
          'Player';
      ProfileService.currentName.value = _displayName;
      _initials = _buildInitials(_displayName);
      _memberSince = _buildMemberSince(DateTime.tryParse(user.createdAt) ?? DateTime.now());
      // A provisioned organizer signed in with a temp password must set a real
      // one before reaching the console.
      if (_isStaff && _existing.mustChangePassword) {
        if (!mounted) return;
        setState(() => _phase = _Phase.mustSetPassword);
        return;
      }
      // Two separate reasons to onboard. isComplete mirrors the server's
      // generated onboarding_completed column; handleSettled asks whether a
      // human ever picked the username. A Google signup satisfies the first
      // and not the second — its handle was derived from its display name by
      // _unique_username and it was never asked — which is why it used to sail
      // past onboarding with a name it did not choose.
      final complete =
          (profile?.isComplete ?? false) && (profile?.handleSettled ?? false);
      // Staff (super admin or a granted role) skip player onboarding entirely —
      // straight to the console. They never see the phone/onboarding step.
      if (!_isStaff && complete) {
        _playerProfile = await ProfileService.fetchPlayerProfile(user.id);
      }
      if (!mounted) return;
      final ready = _isStaff || complete;
      setState(() => _phase = ready ? _Phase.ready : _Phase.onboarding);
      // The "a new version is out" nudge waits for this — a sheet over the
      // splash or over half-finished onboarding reads as a bug. The hard block
      // doesn't wait; it applies at the sign-in screen too.
      if (ready) UpdateGate.appReady.value = true;
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
          // Native Sign in with Apple is iOS-only; hide it elsewhere. Guard
          // kIsWeb first — dart:io Platform is unavailable on Flutter web.
          onAppleSignIn:
              (!kIsWeb && Platform.isIOS) ? AuthService.signInWithApple : null,
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
      _Phase.mustSetPassword => SetPasswordScreen(
          key: const ValueKey('set-password'),
          displayName: _displayName,
          onDone: _resolve,
          onSignOut: _signOut,
        ),
      _Phase.recovering => SetPasswordScreen(
          key: const ValueKey('recover-password'),
          displayName: _displayName,
          recovery: true,
          // The password is already saved by the time onDone runs, so resolving
          // drops them into the app signed in — no second login.
          onDone: _resolve,
          // Cancelling a half-finished reset must not leave the recovery
          // session lying around; signing out returns to the sign-in screen.
          onSignOut: _signOut,
        ),
      _Phase.ready => _isStaff
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

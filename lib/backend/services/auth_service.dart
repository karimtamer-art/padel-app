import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/frontend/screens/auth/sign_up_flow.dart';

/// Thrown when the user dismisses the Google account picker. Callers should
/// treat it as a no-op, not an error.
class AuthCancelled implements Exception {
  const AuthCancelled();
  @override
  String toString() => 'Sign-in was cancelled.';
}

/// Auth data-access: native Google / Apple sign-in, Supabase OAuth in a
/// browser as the fallback, plus email/password and phone OTP.
///
/// Pass an instance to [AuthGate]. The static methods cover OAuth, email/password,
/// and phone OTP for use from individual screens.
class AuthService {
  AuthService({
    this.googleWebClientId = '',
    this.googleIosClientId,
  }) {
    // [signInWithGoogle] is static because AuthGate passes it as a tear-off,
    // so the ids have to be reachable from a static context. main.dart builds
    // this instance before any sign-in UI can be shown.
    _webClientId = googleWebClientId;
    _iosClientId = googleIosClientId;
  }

  final String googleWebClientId;
  final String? googleIosClientId;

  SupabaseClient get _sb => Supabase.instance.client;

  User? get currentUser => _sb.auth.currentUser;
  Session? get currentSession => _sb.auth.currentSession;
  Stream<AuthState> get onAuthStateChange => _sb.auth.onAuthStateChange;

  Future<void> signOut() async {
    await _sb.auth.signOut();
    // Drop the Google session too. Without this the native picker silently
    // reuses the last account on the next sign-in, so a shared phone can never
    // switch users. Best-effort: never let it block signing out of the app.
    if (_googleReady) {
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {/* already signed out / no Play Services */}
    }
  }

  // ── Static interface — OAuth + email/password + phone OTP ────────────────

  static SupabaseClient get _db => Supabase.instance.client;

  /// Must also be registered as an intent-filter on
  /// `com.linusu.flutter_web_auth_2.CallbackActivity` in
  /// android/app/src/main/AndroidManifest.xml — change one, change the other.
  static const _redirectUrl = 'padelclay://login-callback/';
  static const _callbackScheme = 'padelclay';

  // Set from the constructor — see the note there on why these are static.
  static String _webClientId = '';
  static String? _iosClientId;
  static bool _googleReady = false;

  /// Whether the native account picker can be used instead of a browser.
  ///
  /// The Web (server) client id is non-negotiable: on Android it is the
  /// audience the ID token is minted for, and it is what Supabase checks the
  /// token against. iOS additionally needs its own client id, because the
  /// Google SDK there reads it to build the callback. Anything else — desktop,
  /// web, or simply an unconfigured build — falls back to the browser flow.
  static bool get _nativeGoogleAvailable {
    if (kIsWeb || _webClientId.isEmpty) return false;
    if (Platform.isAndroid) return true;
    if (Platform.isIOS) return (_iosClientId ?? '').isNotEmpty;
    return false;
  }

  /// Google sign-in, native where possible.
  ///
  /// Native means the system account sheet appears over the app and Supabase
  /// takes Google's ID token directly ([signInWithIdToken]) — the same shape as
  /// [signInWithApple], and no browser at all. The browser flow it falls back
  /// to is the slow one: Custom Tab → Google → Supabase callback → back into
  /// the app, several seconds and several round trips.
  static Future<void> signInWithGoogle() async {
    if (!_nativeGoogleAvailable) return _oauthFlow(OAuthProvider.google);

    final google = GoogleSignIn.instance;
    if (!_googleReady) {
      // Must complete before any other call on the singleton, and must happen
      // exactly once — calling it twice is documented as undefined behaviour.
      await google.initialize(
        clientId: Platform.isIOS ? _iosClientId : null,
        serverClientId: _webClientId,
      );
      _googleReady = true;
    }
    // Platforms that drive sign-in from their own button widget instead.
    if (!google.supportsAuthenticate()) return _oauthFlow(OAuthProvider.google);

    final GoogleSignInAccount account;
    try {
      account = await google.authenticate();
    } on GoogleSignInException catch (e) {
      // Dismissing the sheet is a no-op, same as Apple and the browser flow.
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw const AuthCancelled();
      }
      rethrow;
    }

    final idToken = account.authentication.idToken;
    if (idToken == null) {
      // Almost always a console problem: no Android OAuth client for this
      // package + SHA-1, or a serverClientId that isn't the Web one.
      throw const AuthException('Google did not return an identity token.');
    }

    await _db.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
    );
  }

  /// Native "Sign in with Apple": get an Apple ID credential (the system sheet
  /// / Face ID), then exchange its identity token for a Supabase session via
  /// signInWithIdToken. A raw nonce is sent hashed to Apple and raw to Supabase
  /// so the token can't be replayed.
  static Future<void> signInWithApple() async {
    final rawNonce = _generateNonce();
    final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();

    final AuthorizationCredentialAppleID cred;
    try {
      cred = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      // User dismissed the Apple sheet — treat as a no-op like Google.
      if (e.code == AuthorizationErrorCode.canceled) throw const AuthCancelled();
      rethrow;
    }

    final idToken = cred.identityToken;
    if (idToken == null) {
      throw const AuthException('Apple did not return an identity token.');
    }

    await _db.auth.signInWithIdToken(
      provider: OAuthProvider.apple,
      idToken: idToken,
      nonce: rawNonce,
    );

    // Apple only returns the user's name on the FIRST authorization. If we got
    // one and the profile has no name yet, persist it (best-effort).
    final name = [cred.givenName, cred.familyName]
        .where((p) => (p ?? '').trim().isNotEmpty)
        .join(' ')
        .trim();
    if (name.isNotEmpty) {
      final uid = _db.auth.currentUser?.id;
      if (uid != null) {
        try {
          final row =
              await _db.from('profiles').select('name').eq('id', uid).maybeSingle();
          if (((row?['name'] as String?) ?? '').trim().isEmpty) {
            await _db.from('profiles').update({'name': name}).eq('id', uid);
          }
        } catch (_) {/* non-fatal */}
      }
    }
  }

  /// Cryptographically-random nonce for the Apple sign-in exchange.
  static String _generateNonce([int length = 32]) {
    const charset =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._';
    final rng = Random.secure();
    return List.generate(length, (_) => charset[rng.nextInt(charset.length)])
        .join();
  }

  static Future<void> _oauthFlow(OAuthProvider provider) async {
    // Generate the OAuth URL with PKCE challenge stored in gotrue's local storage.
    final res = await _db.auth.getOAuthSignInUrl(
      provider: provider,
      redirectTo: _redirectUrl,
    );
    // ASWebAuthenticationSession opens as an in-app modal and intercepts the
    // padelclay:// redirect automatically — no white screen, no app switch.
    final String callbackUrl;
    try {
      callbackUrl = await FlutterWebAuth2.authenticate(
        url: res.url,
        callbackUrlScheme: _callbackScheme,
      );
    } on PlatformException catch (e) {
      if (e.code == 'CANCELED') throw const AuthCancelled();
      rethrow;
    }
    // Exchange the PKCE code for a session.
    await _db.auth.getSessionFromUrl(Uri.parse(callbackUrl));
  }

  static String formatPhone(String phone) =>
      phone.startsWith('+') ? phone : '+20${phone.replaceAll(RegExp(r'[^0-9]'), '')}';

  static Future<String?> sendPhoneOtp(String phone) async {
    try {
      await _db.auth.updateUser(UserAttributes(phone: formatPhone(phone)));
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  static Future<String?> verifyPhoneOtp(String phone, String token) async {
    try {
      await _db.auth.verifyOTP(
        phone: formatPhone(phone),
        token: token,
        type: OtpType.phoneChange,
      );
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Domain appended to a bare username so it becomes a valid Supabase email.
  /// e.g. typing `admin` signs in as `admin@padelegypt.app`. An admin/staff
  /// auth account must be created with this exact email (see signIn).
  static const usernameDomain = 'padelegypt.app';

  /// Treat an input with no `@` as a username: lowercase it, strip spaces, and
  /// append [usernameDomain]. Real emails (containing `@`) pass through.
  static String resolveLogin(String input) {
    final v = input.trim();
    if (v.contains('@')) return v;
    return '${v.toLowerCase().replaceAll(RegExp(r'\s+'), '')}@$usernameDomain';
  }

  static Future<String?> signIn(String email, String password) async {
    final loginEmail = resolveLogin(email);
    try {
      await _db.auth.signInWithPassword(email: loginEmail, password: password);
      return null;
    } on AuthException catch (e) {
      final m = e.message.toLowerCase();
      // Supabase returns one generic "Invalid login credentials" for both an
      // unknown email and a wrong password. Split them via email_exists().
      if (m.contains('invalid login') || m.contains('invalid credentials')) {
        final exists = await _emailExists(loginEmail);
        if (exists == null) {
          return 'Incorrect email or password. Please check both and try again.';
        }
        return exists
            ? 'Incorrect password. Please try again.'
            : 'No account found with this email.';
      }
      return _friendlyAuthError(e);
    } catch (e) {
      return 'Something went wrong signing in. Please try again.';
    }
  }

  /// Sets a new password for the signed-in user (used by the forced first-login
  /// reset for provisioned organizers). Returns null on success, else a message.
  static Future<String?> setPassword(String newPassword) async {
    try {
      await _db.auth.updateUser(UserAttributes(password: newPassword));
      return null;
    } on AuthException catch (e) {
      return _friendlyAuthError(e);
    } catch (e) {
      return 'Could not update your password. Please try again.';
    }
  }

  // ── Password reset ─────────────────────────────────────────────────────────

  /// Where the recovery email sends the player back to. A DIFFERENT host from
  /// [_redirectUrl] on purpose: on Android the two are claimed by different
  /// activities (flutter_web_auth_2's CallbackActivity handles login-callback,
  /// MainActivity handles this one). If both hosts matched both filters Android
  /// would show an app chooser. Must also be allow-listed in Supabase under
  /// Authentication → URL Configuration → Redirect URLs, or the link dies with
  /// "requested path is invalid".
  static const passwordResetUrl = 'padelclay://reset-password/';

  /// Sign-in providers behind the CURRENT user, e.g. {email, google, apple}.
  /// `email` present means there is a real password on the account.
  static Set<String> get currentProviders {
    final ids = _db.auth.currentUser?.identities ?? const [];
    return ids.map((i) => i.provider).toSet();
  }

  /// Whether the signed-in user can actually change a password. False for a
  /// Google/Apple-only account — there is nothing to change, and offering it
  /// just sends a confusing email.
  static bool get hasPasswordLogin => currentProviders.contains('email');

  /// Human label for how a social-only account signs in ("Google", "Apple"),
  /// or null when it has a password.
  static String? get socialProviderLabel {
    if (hasPasswordLogin) return null;
    final p = currentProviders;
    if (p.contains('google')) return 'Google';
    if (p.contains('apple')) return 'Apple';
    return p.isEmpty ? null : p.first;
  }

  /// Same question for an email we're NOT signed in as — the "Forgot password?"
  /// case. Returns null when the lookup itself failed, so the caller can fall
  /// back to sending rather than blocking a legitimate reset on a network blip.
  static Future<Set<String>?> loginMethodsFor(String email) async {
    try {
      final res = await _db
          .rpc('email_login_methods', params: {'p_email': email.trim()});
      if (res is List) return res.map((e) => e.toString()).toSet();
      return null;
    } catch (_) {
      return null;
    }
  }

  // ── Reset cooldown ─────────────────────────────────────────────────────────
  //
  // Lives HERE, not in the screens' state, because widget state dies with the
  // widget: a countdown held in the sign-in screen resets the moment you back
  // out and come back, which is two taps away and turns the whole guard into
  // decoration. Keyed by email so one player waiting doesn't block another on
  // a shared device.
  //
  // In-memory on purpose — this exists to stop impatient tapping, not to
  // enforce a quota. Supabase's own per-hour limit is the real ceiling; if
  // this survived restarts it would start lying to someone who reinstalled.

  static const resetCooldown = Duration(seconds: 60);
  static final Map<String, DateTime> _resetSentAt = {};

  static String _emailKey(String email) => email.trim().toLowerCase();

  /// Seconds still to wait before [email] may request another link. 0 = ready.
  static int resetCooldownRemaining(String email) {
    final at = _resetSentAt[_emailKey(email)];
    if (at == null) return 0;
    final left = resetCooldown.inSeconds - DateTime.now().difference(at).inSeconds;
    return left > 0 ? left : 0;
  }

  /// Mails a password-reset link. Returns null on success, else a message.
  ///
  /// [redirectTo] is what makes the link come back INTO the app rather than
  /// Supabase's default web page, which is what gives the player somewhere to
  /// type a new password.
  /// The cooldown is enforced here rather than only in the button, so a screen
  /// that forgets to check can't punch through it.
  static Future<String?> sendPasswordReset(String email) async {
    final wait = resetCooldownRemaining(email);
    if (wait > 0) {
      return 'We just sent one — check your inbox and spam, or try again in ${wait}s.';
    }
    try {
      await _db.auth.resetPasswordForEmail(email.trim(),
          redirectTo: passwordResetUrl);
      // Stamped only on success: a send that failed is worth retrying at once.
      _resetSentAt[_emailKey(email)] = DateTime.now();
      return null;
    } on AuthException catch (e) {
      // Supabase rate-limited us anyway (its window is longer than ours, and
      // it counts sends we didn't make — e.g. from another device). Start the
      // cooldown so the UI stops inviting another tap.
      if (e.statusCode == '429' ||
          e.message.toLowerCase().contains('rate limit') ||
          e.message.toLowerCase().contains('security purposes')) {
        _resetSentAt[_emailKey(email)] = DateTime.now();
      }
      return _friendlyAuthError(e);
    } catch (e) {
      return 'Could not send the reset email. Please try again.';
    }
  }

  /// Whether [email] is registered. Returns null if the check itself failed
  /// (so the caller falls back to a generic message rather than guessing).
  static Future<bool?> _emailExists(String email) async {
    try {
      final res = await _db.rpc('email_exists', params: {'p_email': email});
      return res == true;
    } catch (_) {
      return null;
    }
  }

  /// Friendly text for non-credential auth errors.
  static String _friendlyAuthError(AuthException e) {
    final m = e.message.toLowerCase();
    if (m.contains('not confirmed')) {
      return 'Please confirm your email before signing in.';
    }
    if (m.contains('rate') || m.contains('too many')) {
      return 'Too many attempts. Please wait a moment and try again.';
    }
    return e.message;
  }

  /// Returns `(error, sessionCreated)`.
  static Future<(String?, bool)> signUp(SignUpData data) async {
    try {
      final res = await _db.auth.signUp(
        email: data.email.trim(),
        password: data.password,
        data: {
          'name': data.name.trim(),
          'username': data.username.trim().toLowerCase(),
          'phone': data.phone.trim(),
          'bio': data.bio.trim(),
          'date_of_birth': data.dob?.toIso8601String().split('T').first ?? '',
          'gender': data.gender,
          'preferred_hand': data.hand,
          'preferred_court_side': data.side,
        },
      );
      if (res.user?.identities?.isEmpty ?? false) {
        return ('An account with this email already exists. Please sign in instead.', false);
      }
      final sessionCreated = res.session != null;
      // Upload the picked profile photo now that a session exists (storage RLS
      // needs auth). Best-effort: a failure here never blocks account creation,
      // and if email confirmation is on (no session yet) we simply skip it.
      if (sessionCreated && data.avatarBytes != null && res.user != null) {
        await _uploadAvatar(res.user!.id, data.avatarBytes!, data.avatarExt);
      }
      return (null, sessionCreated);
    } on AuthException catch (e) {
      return (e.message, false);
    } catch (e) {
      return (e.toString(), false);
    }
  }

  /// Uploads [bytes] to the public `avatars` bucket under `<uid>/avatar.<ext>`
  /// and writes the public URL to `profiles.avatar_url`. Swallows errors — the
  /// photo is optional and the user can set one later.
  static Future<void> _uploadAvatar(String uid, Uint8List bytes, String ext) async {
    try {
      final e = ext.isEmpty ? 'jpg' : ext;
      final path = '$uid/avatar.$e';
      await _db.storage.from('avatars').uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(
              upsert: true,
              contentType: 'image/${e == 'jpg' ? 'jpeg' : e}',
            ),
          );
      final url = _db.storage.from('avatars').getPublicUrl(path);
      await _db.from('profiles').update({'avatar_url': url}).eq('id', uid);
    } catch (_) {
      // best-effort — never block sign-up on an avatar upload
    }
  }
}

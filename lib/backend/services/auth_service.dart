import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
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

/// Auth data-access: browser-based Supabase OAuth + email/password + phone OTP.
///
/// Pass an instance to [AuthGate]. The static methods cover OAuth, email/password,
/// and phone OTP for use from individual screens.
class AuthService {
  AuthService({
    this.googleWebClientId = '',
    this.googleIosClientId,
  });

  final String googleWebClientId;
  final String? googleIosClientId;

  SupabaseClient get _sb => Supabase.instance.client;

  User? get currentUser => _sb.auth.currentUser;
  Session? get currentSession => _sb.auth.currentSession;
  Stream<AuthState> get onAuthStateChange => _sb.auth.onAuthStateChange;

  Future<void> signOut() async {
    await _sb.auth.signOut();
  }

  // ── Static interface — OAuth + email/password + phone OTP ────────────────

  static SupabaseClient get _db => Supabase.instance.client;

  static const _redirectUrl = 'padelclay://login-callback/';
  static const _callbackScheme = 'padelclay';

  /// Opens Google sign-in in an ASWebAuthenticationSession (iOS) — an in-app
  /// modal that monitors for the padelclay:// callback and dismisses itself
  /// automatically, so no browser switch and no white-screen stuck state.
  static Future<void> signInWithGoogle() => _oauthFlow(OAuthProvider.google);

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

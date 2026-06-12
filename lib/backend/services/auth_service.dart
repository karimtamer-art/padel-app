import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
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

  /// Same ASWebAuthenticationSession flow for Apple OAuth.
  static Future<void> signInWithApple() => _oauthFlow(OAuthProvider.apple);

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

  static Future<String?> signIn(String email, String password) async {
    try {
      await _db.auth.signInWithPassword(email: email.trim(), password: password);
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Returns `(error, sessionCreated)`.
  static Future<(String?, bool)> signUp(SignUpData data) async {
    try {
      final res = await _db.auth.signUp(
        email: data.email.trim(),
        password: data.password,
        data: {
          'name': data.name.trim(),
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
      return (null, res.session != null);
    } on AuthException catch (e) {
      return (e.message, false);
    } catch (e) {
      return (e.toString(), false);
    }
  }
}

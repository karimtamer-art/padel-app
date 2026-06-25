import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Required top-level background handler. Notification-type messages are shown
/// by the Android system tray automatically; this satisfies the plugin and is
/// where data-only messages would be processed if we add any later.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {}

/// Android push via FCM. iOS/web are intentionally NOT wired (no APNs yet), so
/// every entry point is guarded — calling these off-Android is a safe no-op.
/// The backend inserts a row into `notifications`; a Supabase Edge Function
/// (push-notify) fans that out to this device's stored token.
class PushService {
  PushService._();

  static bool get _supported => !kIsWeb && Platform.isAndroid;
  static bool _ready = false;

  static SupabaseClient get _db => Supabase.instance.client;

  /// Initialise Firebase + messaging once (no permission prompt yet). Safe to
  /// call repeatedly and on any platform.
  static Future<void> init() async {
    if (!_supported || _ready) return;
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      FirebaseMessaging.instance.onTokenRefresh.listen(_save);
      _ready = true;
    } catch (e) {
      debugPrint('[PushService] init failed: $e');
    }
  }

  /// Request the notification permission (Android 13+) and store this device's
  /// token for the signed-in user. Call once the user is signed in.
  static Future<void> registerToken() async {
    if (!_supported) return;
    if (!_ready) await init();
    if (!_ready) return;
    try {
      await FirebaseMessaging.instance.requestPermission();
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await _save(token);
    } catch (e) {
      debugPrint('[PushService] registerToken failed: $e');
    }
  }

  static Future<void> _save(String token) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    try {
      await _db.from('device_tokens').upsert(
        {'user_id': uid, 'token': token, 'platform': 'android'},
        onConflict: 'token',
      );
    } catch (e) {
      debugPrint('[PushService] save token failed: $e');
    }
  }

  /// Drop this device's token on sign-out so the user stops receiving push.
  static Future<void> unregister() async {
    if (!_supported || !_ready) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        await _db.from('device_tokens').delete().eq('token', token);
      }
    } catch (e) {
      debugPrint('[PushService] unregister failed: $e');
    }
  }
}

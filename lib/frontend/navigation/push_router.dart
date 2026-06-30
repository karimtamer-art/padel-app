import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../widgets/app_toast.dart';
import '../screens/detail/match_detail_screen.dart';
import '../screens/tournaments/tournament_detail_screen.dart';
import '../screens/profile/my_orders_screen.dart';
import '../screens/chat/dm_chat_screen.dart';

/// Turns a tapped FCM notification into a screen.
///
/// Lives in the frontend (not PushService) on purpose: routing needs to know
/// about screens, and services must not import UI. PushService still owns the
/// token lifecycle; this only handles tap → navigate.
///
/// The payload is whatever the `push-notify` Edge Function sends. Every value
/// in `message.data` is a string (FCM requirement); the keys mirror the
/// `data` jsonb on the `notifications` row:
///   message      → { conversation_id, sender_id }
///   match        → { match_id }
///   tournament   → { tournament_id, entry_id }
///   order        → { order_id, status }
class PushRouter {
  PushRouter._();

  /// Wired into MaterialApp so we can navigate from outside the widget tree
  /// (a notification tapped while the app was backgrounded or killed).
  static final navigatorKey = GlobalKey<NavigatorState>();

  /// Admin alerts ('admin_*') can't be pushed as a route — the admin console is
  /// a single screen that switches sections by internal state. Instead we hand
  /// it the target nav id ('payments'/'requests'/'tournaments') here; the
  /// console listens and switches to it. Survives cold start: the value may be
  /// set before the console mounts, so the console reads it on init too.
  static final ValueNotifier<String?> adminSection = ValueNotifier<String?>(null);

  static bool _attached = false;

  /// Register the three FCM entry points. Idempotent; call once the user is
  /// signed in and the navigator exists (AuthGate, when ready).
  static Future<void> attach() async {
    if (_attached) return;
    _attached = true;

    // 1) Cold start: app launched by tapping a notification while terminated.
    //    The navigator isn't mounted yet, so defer to the first frame.
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _route(initial));
    }

    // 2) Warm start: notification tapped while the app was in the background.
    FirebaseMessaging.onMessageOpenedApp.listen(_route);

    // 3) Foreground: Android does NOT draw a tray notification while the app
    //    is in front, so surface it as an in-app toast with an Open action.
    FirebaseMessaging.onMessage.listen(_onForeground);
  }

  static void _onForeground(RemoteMessage m) {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    final title = m.notification?.title ?? 'New notification';
    final body = m.notification?.body ?? '';
    final text = body.isEmpty ? title : '$title — $body';
    AppToast.show(
      ctx,
      text,
      kind: ToastKind.info,
      actionLabel: 'Open',
      onAction: () => _route(m),
      duration: const Duration(seconds: 5),
    );
  }

  static void _route(RemoteMessage m) {
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    final data = m.data;

    // Admin alerts → tell the console which section to open (never a player
    // screen — that's what caused the blank/loading loop for admins).
    switch (data['type']) {
      case 'admin_order':
        adminSection.value = 'payments';
        return;
      case 'admin_trade':
      case 'admin_repair':
        adminSection.value = 'requests';
        return;
      case 'admin_tournament':
        adminSection.value = 'tournaments';
        return;
    }

    Widget? screen;
    switch (data['type']) {
      case 'message':
        final senderId = data['sender_id'];
        if (senderId is String && senderId.isNotEmpty) {
          final name = m.notification?.title ?? 'Chat';
          screen =
              DMChatScreen(otherId: senderId, name: name, initials: _initials(name));
        }
        break;
      case 'match':
        final id = data['match_id'];
        if (id is String && id.isNotEmpty) screen = MatchDetailScreen(matchId: id);
        break;
      case 'tournament':
        final id = data['tournament_id'];
        if (id is String && id.isNotEmpty) {
          screen = TournamentDetailScreen(tournamentId: id);
        }
        break;
      case 'order':
        screen = const MyOrdersScreen();
        break;
    }

    if (screen == null) return; // unknown/typeless → app just opens to home
    final s = screen;
    nav.push(MaterialPageRoute(builder: (_) => s));
  }

  static String _initials(String name) {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}

import 'package:supabase_flutter/supabase_flutter.dart';

/// Per-user notification inbox. Rows are produced server-side (the orders
/// status trigger inserts them); the client only reads, counts unread, and
/// marks read. RLS scopes everything to the signed-in user.
class NotificationService {
  NotificationService._();
  static SupabaseClient get _db => Supabase.instance.client;

  /// Notifications older than this drop OFF THE VIEW (and stop counting toward
  /// the bell). Rows are only hidden, never deleted — see [pruneOld].
  static const _retention = Duration(days: 14);

  /// ISO timestamp of the display cutoff (rows older than this are hidden).
  static String get _cutoff =>
      DateTime.now().toUtc().subtract(_retention).toIso8601String();

  /// This user's notifications, newest first — last [_retention], capped at 50.
  static Future<List<Map<String, dynamic>>> fetch() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return [];
    try {
      final res = await _db
          .from('notifications')
          .select('id, type, title, body, data, read, created_at')
          .eq('user_id', uid)
          .gte('created_at', _cutoff)
          .order('created_at', ascending: false)
          .limit(50);
      return List<Map<String, dynamic>>.from(res as List);
    } catch (_) {
      return [];
    }
  }

  /// Unread badge count for the Home bell (same retention window as [fetch]).
  static Future<int> unreadCount() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return 0;
    try {
      final res = await _db
          .from('notifications')
          .select('id')
          .eq('user_id', uid)
          .eq('read', false)
          .gte('created_at', _cutoff);
      return (res as List).length;
    } catch (_) {
      return 0;
    }
  }

  /// Mark a single notification read (called when its row is tapped).
  static Future<void> markRead(String id) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    try {
      await _db
          .from('notifications')
          .update({'read': true})
          .eq('id', id)
          .eq('user_id', uid);
    } catch (_) {}
  }

  /// Notifications past the display window are HIDDEN by [fetch]/[unreadCount],
  /// not deleted — they stay in the DB. This is intentionally a no-op so that
  /// nothing is destroyed; kept as a stable entry point for older callers.
  static Future<void> pruneOld() async {}

  // ── Push preferences (mirrored on profiles.notify_*) ─────────────
  // Keys: push (master) | match | tournament | order. Missing columns
  // (pre-migration) default to on.
  static const _prefColumns = <String, String>{
    'push': 'notify_push',
    'match': 'notify_match',
    'tournament': 'notify_tournament',
    'order': 'notify_order',
  };

  static Map<String, bool> get _prefDefaults =>
      {for (final k in _prefColumns.keys) k: true};

  /// Load this user's push preferences (defaults to all-on).
  static Future<Map<String, bool>> fetchPrefs() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return _prefDefaults;
    try {
      final res = await _db
          .from('profiles')
          .select(_prefColumns.values.join(', '))
          .eq('id', uid)
          .maybeSingle();
      if (res == null) return _prefDefaults;
      return {
        for (final e in _prefColumns.entries)
          e.key: (res[e.value] as bool?) ?? true,
      };
    } catch (_) {
      return _prefDefaults;
    }
  }

  /// Persist one push preference. [key] is one of the [_prefColumns] keys.
  static Future<void> setPref(String key, bool value) async {
    final uid = _db.auth.currentUser?.id;
    final col = _prefColumns[key];
    if (uid == null || col == null) return;
    try {
      await _db.from('profiles').update({col: value}).eq('id', uid);
    } catch (_) {}
  }

  /// Clears the unread 'message' notification(s) for one conversation — called
  /// when its chat is open so the bell doesn't keep counting messages you're
  /// actively reading.
  static Future<void> markConversationRead(String conversationId) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    try {
      await _db
          .from('notifications')
          .update({'read': true})
          .eq('user_id', uid)
          .eq('type', 'message')
          .eq('read', false)
          .eq('data->>conversation_id', conversationId);
    } catch (_) {}
  }

  /// Mark every unread notification for this user as read.
  static Future<void> markAllRead() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    try {
      await _db
          .from('notifications')
          .update({'read': true})
          .eq('user_id', uid)
          .eq('read', false);
    } catch (_) {}
  }
}

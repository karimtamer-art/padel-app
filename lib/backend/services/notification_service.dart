import 'package:supabase_flutter/supabase_flutter.dart';

/// Per-user notification inbox. Rows are produced server-side (the orders
/// status trigger inserts them); the client only reads, counts unread, and
/// marks read. RLS scopes everything to the signed-in user.
class NotificationService {
  NotificationService._();
  static SupabaseClient get _db => Supabase.instance.client;

  /// This user's notifications, newest first.
  static Future<List<Map<String, dynamic>>> fetch() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return [];
    try {
      final res = await _db
          .from('notifications')
          .select('id, type, title, body, data, read, created_at')
          .eq('user_id', uid)
          .order('created_at', ascending: false)
          .limit(50);
      return List<Map<String, dynamic>>.from(res as List);
    } catch (_) {
      return [];
    }
  }

  /// Unread badge count for the Home bell.
  static Future<int> unreadCount() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return 0;
    try {
      final res = await _db
          .from('notifications')
          .select('id')
          .eq('user_id', uid)
          .eq('read', false);
      return (res as List).length;
    } catch (_) {
      return 0;
    }
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

import 'package:supabase_flutter/supabase_flutter.dart';

/// Player ↔ player direct messages. A conversation is one row per unordered
/// pair (resolved server-side by `get_or_create_conversation`); RLS scopes all
/// reads/writes to the two participants.
class DmService {
  DmService._();
  static SupabaseClient get _db => Supabase.instance.client;
  static String? get _uid => _db.auth.currentUser?.id;

  /// The conversation id for me + [otherId], creating it if needed.
  static Future<String?> getOrCreateConversation(String otherId,
      {String? matchId}) async {
    try {
      final res = await _db.rpc('get_or_create_conversation',
          params: {'p_other': otherId, 'p_match_id': matchId});
      return res as String?;
    } catch (_) {
      return null;
    }
  }

  /// Live, ordered message stream for a conversation (drives the chat UI).
  static Stream<List<Map<String, dynamic>>> messageStream(String conversationId) {
    return _db
        .from('direct_messages')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', conversationId)
        // Supabase's stream .order() defaults to DESCENDING — be explicit so
        // oldest is first and new messages append at the bottom of the chat.
        .order('sent_at', ascending: true)
        .map((rows) => List<Map<String, dynamic>>.from(rows));
  }

  /// Every conversation the signed-in user is part of that has at least one
  /// message — newest activity first. Each row:
  /// { conversation_id, other_id, other_name, other_username, last_text,
  ///   last_at, unread }. Drives the standalone Messages inbox.
  static Future<List<Map<String, dynamic>>> inbox() async {
    try {
      final res = await _db.rpc('dm_inbox');
      return List<Map<String, dynamic>>.from(res as List);
    } catch (_) {
      return [];
    }
  }

  /// Total unread direct messages (across all conversations) — drives the
  /// Messages icon badge on Home. Counted off the 'message' notifications.
  static Future<int> unreadCount() async {
    final uid = _uid;
    if (uid == null) return 0;
    try {
      final res = await _db
          .from('notifications')
          .select('id')
          .eq('user_id', uid)
          .eq('type', 'message')
          .eq('read', false);
      return (res as List).length;
    } catch (_) {
      return 0;
    }
  }

  /// Deletes the conversation FOR THE CALLER ONLY. Returns an error or null.
  ///
  /// Nothing is removed from `direct_messages` — the server stamps a
  /// `conversation_clears` row and every surface hides what came before it. The
  /// other person keeps their thread, and a message someone reported outlives
  /// the reported person tapping delete. If they write again the thread returns
  /// carrying only the new messages.
  static Future<String?> clearConversation(String conversationId) async {
    try {
      await _db.rpc('clear_conversation',
          params: {'p_conversation': conversationId});
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return 'Could not delete this chat. Please try again.';
    }
  }

  /// When the caller last cleared this conversation, or null if never.
  ///
  /// The chat screen hides everything at or before this, so a deleted thread
  /// re-opened from a profile starts empty instead of restoring itself. Null on
  /// any failure, which shows the full history — the safe way to be wrong,
  /// since the alternative hides messages that were never deleted.
  static Future<DateTime?> clearedAt(String conversationId) async {
    final uid = _uid;
    if (uid == null) return null;
    try {
      final row = await _db
          .from('conversation_clears')
          .select('cleared_at')
          .eq('conversation_id', conversationId)
          .eq('user_id', uid)
          .maybeSingle();
      return DateTime.tryParse('${row?['cleared_at']}');
    } catch (_) {
      return null; // pre-migration DB has no such table
    }
  }

  /// Sends a message. Returns an error string or null. The row arrives back
  /// through [messageStream], so the UI shouldn't append it manually.
  static Future<String?> send(String conversationId, String text) async {
    final uid = _uid;
    if (uid == null) return 'Not signed in.';
    final t = text.trim();
    if (t.isEmpty) return null;
    try {
      await _db.from('direct_messages').insert({
        'conversation_id': conversationId,
        'sender_id': uid,
        'text': t,
      });
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }
}

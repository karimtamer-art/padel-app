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
        .order('sent_at')
        .map((rows) => List<Map<String, dynamic>>.from(rows));
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

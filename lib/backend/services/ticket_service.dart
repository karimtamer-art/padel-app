import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Match tickets — the automatic group thread that opens with every match.
///
/// Membership and open/closed both derive from the match server-side, so
/// there is nothing to keep in sync here: joining a match puts you in the
/// thread, and it locks itself 24h after the match was scheduled.
///
/// Phone numbers come only from [roster], which the server refuses for
/// non-members and blanks once the ticket closes. Never cache them.
class TicketService {
  TicketService._();
  static SupabaseClient get _db => Supabase.instance.client;
  static String? get _uid => _db.auth.currentUser?.id;

  /// Every ticket the player is in, newest activity first. Empty (rather
  /// than throwing) on a database that hasn't had the delta run yet, so the
  /// inbox still shows DMs instead of breaking outright.
  static Future<List<Map<String, dynamic>>> inbox() async {
    try {
      final res = await _db.rpc('ticket_inbox');
      return List<Map<String, dynamic>>.from(res as List);
    } catch (e) {
      debugPrint('[TicketService] inbox: $e');
      return [];
    }
  }

  /// Total unread across all tickets — added to the DM count on the Home
  /// chat badge.
  static Future<int> unreadCount() async {
    try {
      final res = await _db.rpc('ticket_unread_total');
      return (res as num?)?.toInt() ?? 0;
    } catch (e) {
      debugPrint('[TicketService] unreadCount: $e');
      return 0;
    }
  }

  /// The four players. `phone` is null on a closed ticket, and null for anyone
  /// you haven't swapped numbers with — both are the server's decision, not
  /// something to work around.
  ///
  /// `share_state` says which of those it is, and is what the row renders from:
  /// `me` · `shared` (a number is present) · `pending` (you asked) · `none`.
  static Future<List<Map<String, dynamic>>> roster(String ticketId) async {
    try {
      final res = await _db.rpc('ticket_roster', params: {'p_ticket': ticketId});
      return List<Map<String, dynamic>>.from(res as List);
    } catch (e) {
      debugPrint('[TicketService] roster: $e');
      return [];
    }
  }

  /// Ask a co-player for their number. Accepting is a mutual swap, so this is
  /// also an offer of your own. Returns an error message or null.
  static Future<String?> requestNumber(String ticketId, String playerId) async {
    try {
      final res = await _db.rpc('request_number',
          params: {'p_ticket': ticketId, 'p_target': playerId});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Answer a request someone made of me. Accepting inserts the swap.
  static Future<String?> respondToNumberRequest(String requestId,
      {required bool accept}) async {
    try {
      final res = await _db.rpc('respond_number_request',
          params: {'p_request': requestId, 'p_accept': accept});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Number requests waiting on me.
  static Future<List<Map<String, dynamic>>> myNumberRequests() async {
    try {
      final res = await _db.rpc('my_number_requests');
      return List<Map<String, dynamic>>.from(res as List);
    } catch (e) {
      debugPrint('[TicketService] myNumberRequests: $e');
      return [];
    }
  }

  /// Live messages, oldest first.
  ///
  /// `.order()` on postgrest defaults to DESCENDING, unlike the JS client —
  /// passing `ascending: true` explicitly is what keeps the thread the right
  /// way up (the same trap that bit community chat).
  static Stream<List<Map<String, dynamic>>> messageStream(String ticketId) {
    return _db
        .from('ticket_messages')
        .stream(primaryKey: ['id'])
        .eq('ticket_id', ticketId)
        .order('sent_at', ascending: true)
        .map((rows) => List<Map<String, dynamic>>.from(rows));
  }

  /// Returns an error string, or null on success.
  static Future<String?> send(String ticketId, String text) async {
    final uid = _uid;
    final body = text.trim();
    if (uid == null || body.isEmpty) return null;
    try {
      await _db.from('ticket_messages').insert({
        'ticket_id': ticketId,
        'sender_id': uid,
        'text': body,
      });
      return null;
    } on PostgrestException catch (e) {
      debugPrint('[TicketService] send: ${e.code} ${e.message}');
      // The insert policy requires an OPEN ticket, so a closed thread fails
      // the RLS check rather than returning a tidy error.
      final m = e.message.toLowerCase();
      if (m.contains('policy') || m.contains('violates')) {
        return 'This ticket has closed — the match is over.';
      }
      return "Couldn't send. Try again.";
    } catch (e) {
      debugPrint('[TicketService] send: $e');
      return "Couldn't send. Try again.";
    }
  }

  static Future<void> markRead(String ticketId) async {
    try {
      await _db.rpc('mark_ticket_read', params: {'p_ticket': ticketId});
    } catch (e) {
      debugPrint('[TicketService] markRead: $e');
    }
  }
}

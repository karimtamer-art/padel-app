import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// What a player can be reported for. The wording is what they pick from, so
/// it is written plainly rather than in policy language.
class ReportReason {
  final String code, label;
  const ReportReason(this.code, this.label);

  static const all = <ReportReason>[
    ReportReason('harassment', 'Harassment or bullying'),
    ReportReason('hate', 'Hate speech'),
    ReportReason('sexual', 'Sexual or explicit content'),
    ReportReason('violence', 'Violence or threats'),
    ReportReason('spam', 'Spam or a scam'),
    ReportReason('impersonation', 'Pretending to be someone else'),
    ReportReason('other', 'Something else'),
  ];

  static String labelFor(String? code) {
    for (final r in all) {
      if (r.code == code) return r.label;
    }
    return code ?? '—';
  }
}

/// Blocking and reporting.
///
/// Blocking is symmetric and takes effect immediately — once either side
/// blocks, neither sees the other's messages. Reporting goes to the operators
/// and is handled in the admin console.
///
/// Both are App Store Guideline 1.2 requirements for user-generated content.
class ModerationService {
  ModerationService._();
  static SupabaseClient get _db => Supabase.instance.client;

  // ── blocking ────────────────────────────────────────────────────────────

  /// Returns an error string, or null on success.
  static Future<String?> block(String userId) async {
    try {
      await _db.rpc('block_user', params: {'p_user': userId});
      return null;
    } catch (e) {
      debugPrint('[ModerationService] block: $e');
      return _setupHint(e) ?? "Couldn't block this player. Try again.";
    }
  }

  static Future<String?> unblock(String userId) async {
    try {
      await _db.rpc('unblock_user', params: {'p_user': userId});
      return null;
    } catch (e) {
      debugPrint('[ModerationService] unblock: $e');
      return _setupHint(e) ?? "Couldn't unblock this player. Try again.";
    }
  }

  static Future<List<Map<String, dynamic>>> blockedUsers() async {
    try {
      final res = await _db.rpc('my_blocked_users');
      return List<Map<String, dynamic>>.from(res as List);
    } catch (e) {
      debugPrint('[ModerationService] blockedUsers: $e');
      return [];
    }
  }

  /// Whether the signed-in player has blocked [userId]. Only their own list is
  /// readable, so this cannot be used to detect being blocked BY someone.
  static Future<bool> hasBlocked(String userId) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return false;
    try {
      final res = await _db
          .from('blocked_users')
          .select('blocked_id')
          .eq('blocker_id', uid)
          .eq('blocked_id', userId)
          .maybeSingle();
      return res != null;
    } catch (e) {
      debugPrint('[ModerationService] hasBlocked: $e');
      return false;
    }
  }

  // ── reporting ───────────────────────────────────────────────────────────

  /// Files a report. [targetType] is one of dm_message, ticket_message,
  /// community_message, announcement_comment, user.
  ///
  /// The server resolves who is being reported and snapshots the content, so
  /// only the id needs sending — except for a 'user' report, where there is no
  /// content row and [targetUserId] carries it.
  static Future<String?> report({
    required String targetType,
    String? targetId,
    required String reason,
    String? note,
    String? targetUserId,
  }) async {
    try {
      await _db.rpc('report_content', params: {
        'p_target_type': targetType,
        'p_target_id': targetId,
        'p_reason': reason,
        'p_note': note,
        'p_target_user': targetUserId,
      });
      return null;
    } catch (e) {
      debugPrint('[ModerationService] report: $e');
      return _setupHint(e) ?? "Couldn't send the report. Try again.";
    }
  }

  /// The whole feature is one delta — say so plainly rather than letting a
  /// missing-function error reach the player as "try again", which never works.
  static String? _setupHint(Object e) {
    final m = e.toString().toLowerCase();
    if (m.contains('block_user') ||
        m.contains('report_content') ||
        m.contains('blocked_users') ||
        m.contains('does not exist')) {
      return 'Blocking and reporting are not set up on the server yet. '
          'Please contact support.';
    }
    return null;
  }
}

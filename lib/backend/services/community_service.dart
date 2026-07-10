import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// One organizer-run community + everything the hub / console need.
/// Reads use RLS-public selects; mutations + fan-out go through RPCs.
class CommunityService {
  CommunityService._();
  static SupabaseClient get _db => Supabase.instance.client;
  static String? get _uid => _db.auth.currentUser?.id;

  // ── Discovery / hub ─────────────────────────────────────────────

  /// The community for the Home card: the one the player has joined, else the
  /// newest community to discover. Null when none exist.
  static Future<Community?> homeCommunity() async {
    final uid = _uid;
    if (uid == null) return null;
    try {
      final mine = await _db
          .from('community_members')
          .select('community_id')
          .eq('player_id', uid)
          .limit(1)
          .maybeSingle();
      if (mine != null) {
        return fetchCommunity(mine['community_id'] as String);
      }
      final any = await _db
          .from('communities')
          .select('id')
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      if (any == null) return null;
      return fetchCommunity(any['id'] as String);
    } catch (e) {
      debugPrint('[CommunityService] homeCommunity: $e');
      return null;
    }
  }

  /// Full community + organizer name + member count + whether I've joined.
  static Future<Community?> fetchCommunity(String id) async {
    try {
      final row = await _db
          .from('communities')
          .select('id, organizer_id, name, handle, city, about, verified')
          .eq('id', id)
          .maybeSingle();
      if (row == null) return null;

      final org = await _db
          .from('profiles')
          .select('name')
          .eq('id', row['organizer_id'] as String)
          .maybeSingle();

      final members = await _db
          .from('community_members')
          .select('player_id')
          .eq('community_id', id);
      final memberIds =
          (members as List).map((m) => m['player_id'] as String).toList();

      return Community.fromRow(
        row,
        organizerName: (org?['name'] as String?) ?? 'Organizer',
        memberCount: memberIds.length,
        isMember: _uid != null && memberIds.contains(_uid),
      );
    } catch (e) {
      debugPrint('[CommunityService] fetchCommunity: $e');
      return null;
    }
  }

  /// Members (name + avatar) for the Members tab, capped for the grid.
  static Future<List<MemberLite>> members(String communityId,
      {int limit = 60}) async {
    try {
      final res = await _db
          .from('community_members')
          .select('player_id, joined_at, '
              'profiles!community_members_player_id_fkey(name, avatar_url)')
          .eq('community_id', communityId)
          .order('joined_at')
          .limit(limit);
      return (res as List).map((r) {
        final p = r['profiles'] as Map?;
        return MemberLite(
          id: r['player_id'] as String,
          name: (p?['name'] as String?) ?? 'Player',
          avatarUrl: p?['avatar_url'] as String?,
        );
      }).toList();
    } catch (e) {
      debugPrint('[CommunityService] members: $e');
      return [];
    }
  }

  /// The organizer's open/upcoming events shown in the hub Events tab.
  static Future<List<CommunityEvent>> events(String organizerId) async {
    try {
      final res = await _db
          .from('tournaments')
          .select('id, name, status, start_date, entry_fee, prize_pool')
          .eq('organizer_id', organizerId)
          .neq('status', 'cancelled')
          .order('start_date', ascending: false)
          .limit(20);
      return (res as List)
          .map((r) => CommunityEvent.fromRow(Map<String, dynamic>.from(r as Map)))
          .toList();
    } catch (e) {
      debugPrint('[CommunityService] events: $e');
      return [];
    }
  }

  /// Announcements with going counts + whether I'm going (RPC).
  static Future<List<Announcement>> feed(String communityId) async {
    try {
      final res = await _db.rpc('community_feed', params: {'p_community_id': communityId});
      return (res as List)
          .map((r) => Announcement.fromRow(Map<String, dynamic>.from(r as Map)))
          .toList();
    } catch (e) {
      debugPrint('[CommunityService] feed: $e');
      return [];
    }
  }

  // ── Player actions ──────────────────────────────────────────────

  static Future<String?> join(String communityId) =>
      _rpc('join_community', {'p_community_id': communityId});

  static Future<String?> leave(String communityId) =>
      _rpc('leave_community', {'p_community_id': communityId});

  /// Toggle RSVP; returns the new going state (defaults false on error).
  static Future<bool> toggleRsvp(String announcementId) async {
    try {
      final res = await _db
          .rpc('toggle_rsvp', params: {'p_announcement_id': announcementId});
      return res == true;
    } catch (e) {
      debugPrint('[CommunityService] toggleRsvp: $e');
      return false;
    }
  }

  // ── Messaging (member ↔ organizer) ──────────────────────────────

  /// The signed-in member's thread with the organizer, oldest first.
  static Future<List<CommunityMessage>> myThread(String communityId) async {
    final uid = _uid;
    if (uid == null) return [];
    return _thread(communityId, uid, 'member');
  }

  /// A specific member's thread (organizer console view), oldest first.
  static Future<List<CommunityMessage>> threadWith(
          String communityId, String memberId) =>
      _thread(communityId, memberId, 'organizer');

  static Future<List<CommunityMessage>> _thread(
      String communityId, String memberId, String viewerRole) async {
    try {
      final res = await _db
          .from('community_messages')
          .select('sender_role, body, created_at')
          .eq('community_id', communityId)
          .eq('member_id', memberId)
          .order('created_at');
      return (res as List)
          .map((r) => CommunityMessage.fromRow(
              Map<String, dynamic>.from(r as Map),
              viewerRole: viewerRole))
          .toList();
    } catch (e) {
      debugPrint('[CommunityService] thread: $e');
      return [];
    }
  }

  static Future<String?> sendMessage(String communityId, String body) =>
      _rpc('send_community_message',
          {'p_community_id': communityId, 'p_body': body});

  // ── Organizer console ───────────────────────────────────────────

  /// The signed-in organizer's own community, or null if not created yet.
  static Future<Community?> myCommunity() async {
    final uid = _uid;
    if (uid == null) return null;
    try {
      final row = await _db
          .from('communities')
          .select('id')
          .eq('organizer_id', uid)
          .maybeSingle();
      if (row == null) return null;
      return fetchCommunity(row['id'] as String);
    } catch (e) {
      debugPrint('[CommunityService] myCommunity: $e');
      return null;
    }
  }

  static Future<String?> upsertMyCommunity({
    required String name,
    String? handle,
    String? city,
    String? about,
  }) =>
      _rpc('upsert_my_community', {
        'p_name': name,
        'p_handle': handle,
        'p_city': city,
        'p_about': about,
      });

  static Future<String?> postAnnouncement({
    required String title,
    String? body,
    bool pinned = false,
  }) =>
      _rpc('post_announcement',
          {'p_title': title, 'p_body': body, 'p_pinned': pinned});

  /// One row per member thread for the organizer inbox, newest first.
  static Future<List<InboxThread>> inbox() async {
    try {
      final res = await _db.rpc('community_inbox');
      return (res as List)
          .map((r) => InboxThread.fromRow(Map<String, dynamic>.from(r as Map)))
          .toList();
    } catch (e) {
      debugPrint('[CommunityService] inbox: $e');
      return [];
    }
  }

  static Future<String?> reply(String memberId, String body) =>
      _rpc('reply_community_message', {'p_member_id': memberId, 'p_body': body});

  // ── helper ──────────────────────────────────────────────────────
  static Future<String?> _rpc(String fn, Map<String, dynamic> params) async {
    try {
      final res = await _db.rpc(fn, params: params);
      return res is String ? res : null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }
}

// ── Models ────────────────────────────────────────────────────────
class Community {
  final String id, organizerId, name, organizerName;
  final String? handle, city, about;
  final bool verified, isMember;
  final int memberCount;
  const Community({
    required this.id,
    required this.organizerId,
    required this.name,
    required this.organizerName,
    required this.memberCount,
    required this.isMember,
    this.handle,
    this.city,
    this.about,
    this.verified = false,
  });

  factory Community.fromRow(Map<String, dynamic> r,
          {required String organizerName,
          required int memberCount,
          required bool isMember}) =>
      Community(
        id: r['id'] as String,
        organizerId: r['organizer_id'] as String,
        name: (r['name'] as String?) ?? 'Community',
        organizerName: organizerName,
        memberCount: memberCount,
        isMember: isMember,
        handle: r['handle'] as String?,
        city: r['city'] as String?,
        about: r['about'] as String?,
        verified: r['verified'] == true,
      );
}

class MemberLite {
  final String id, name;
  final String? avatarUrl;
  const MemberLite({required this.id, required this.name, this.avatarUrl});

  String get initials {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}

class CommunityEvent {
  final String id, name, status;
  final String? startDate;
  final int? entryFee, prizePool;
  const CommunityEvent({
    required this.id,
    required this.name,
    required this.status,
    this.startDate,
    this.entryFee,
    this.prizePool,
  });

  factory CommunityEvent.fromRow(Map<String, dynamic> r) => CommunityEvent(
        id: r['id'] as String,
        name: (r['name'] as String?) ?? 'Tournament',
        status: (r['status'] as String?) ?? 'open',
        startDate: r['start_date'] as String?,
        entryFee: (r['entry_fee'] as num?)?.toInt(),
        prizePool: (r['prize_pool'] as num?)?.toInt(),
      );
}

class Announcement {
  final String id, title;
  final String? body;
  final bool pinned, iGoing;
  final int going;
  final DateTime? createdAt;
  const Announcement({
    required this.id,
    required this.title,
    this.body,
    this.pinned = false,
    this.iGoing = false,
    this.going = 0,
    this.createdAt,
  });

  factory Announcement.fromRow(Map<String, dynamic> r) => Announcement(
        id: r['id'] as String,
        title: (r['title'] as String?) ?? '',
        body: r['body'] as String?,
        pinned: r['pinned'] == true,
        iGoing: r['i_going'] == true,
        going: (r['going'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse(r['created_at']?.toString() ?? ''),
      );
}

class CommunityMessage {
  final bool fromMe; // relative to the viewer's role
  final String body;
  final DateTime? at;
  const CommunityMessage({required this.fromMe, required this.body, this.at});

  /// [viewerRole] is 'member' or 'organizer' — a row is "mine" when its
  /// sender_role matches the viewer.
  factory CommunityMessage.fromRow(Map<String, dynamic> r,
          {String viewerRole = 'member'}) =>
      CommunityMessage(
        fromMe: (r['sender_role'] as String?) == viewerRole,
        body: (r['body'] as String?) ?? '',
        at: DateTime.tryParse(r['created_at']?.toString() ?? ''),
      );
}

class InboxThread {
  final String memberId, memberName;
  final String? avatarUrl, lastBody, lastRole;
  final bool unanswered;
  final DateTime? lastAt;
  const InboxThread({
    required this.memberId,
    required this.memberName,
    this.avatarUrl,
    this.lastBody,
    this.lastRole,
    this.unanswered = false,
    this.lastAt,
  });

  factory InboxThread.fromRow(Map<String, dynamic> r) => InboxThread(
        memberId: r['member_id'] as String,
        memberName: (r['member_name'] as String?) ?? 'Player',
        avatarUrl: r['avatar_url'] as String?,
        lastBody: r['last_body'] as String?,
        lastRole: r['last_role'] as String?,
        unanswered: r['unanswered'] == true,
        lastAt: DateTime.tryParse(r['last_at']?.toString() ?? ''),
      );

  String get initials {
    final parts = memberName.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}

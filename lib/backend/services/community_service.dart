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
          .select('id, organizer_id, name, handle, city, about, verified, approval_required')
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

  /// Join by the organizer's shared handle/code. Returns the community id on
  /// success, or an error message to show the player.
  static Future<({String? communityId, String? error})> joinByHandle(
      String handle) async {
    try {
      final res = await _db
          .rpc('join_community_by_handle', params: {'p_handle': handle});
      final m = Map<String, dynamic>.from(res as Map);
      if (m['ok'] == true) {
        return (communityId: m['community_id'] as String?, error: null);
      }
      return (
        communityId: null,
        error: (m['error'] as String?) ?? 'Could not join.'
      );
    } on PostgrestException catch (e) {
      return (communityId: null, error: e.message);
    } catch (e) {
      debugPrint('[CommunityService] joinByHandle: $e');
      return (communityId: null, error: 'Could not join. Try again.');
    }
  }

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

  /// Organizer console KPI + member-tier stats for their community.
  static Future<Map<String, dynamic>> organizerStats() async {
    try {
      final res = await _db.rpc('organizer_community_stats');
      return res is Map ? Map<String, dynamic>.from(res) : {};
    } catch (e) {
      debugPrint('[CommunityService] organizerStats: $e');
      return {};
    }
  }

  /// Toggle like on an announcement; returns the new liked state.
  static Future<bool> toggleLike(String announcementId) async {
    try {
      final res = await _db.rpc('toggle_announcement_like',
          params: {'p_announcement_id': announcementId});
      return res == true;
    } catch (e) {
      debugPrint('[CommunityService] toggleLike: $e');
      return false;
    }
  }

  /// Comments on an announcement, oldest first.
  static Future<List<CommentLite>> comments(String announcementId) async {
    try {
      final res = await _db.rpc('announcement_comments',
          params: {'p_announcement_id': announcementId});
      return (res as List)
          .map((r) => CommentLite.fromRow(Map<String, dynamic>.from(r as Map)))
          .toList();
    } catch (e) {
      debugPrint('[CommunityService] comments: $e');
      return [];
    }
  }

  /// Post a comment; returns null on success, else an error message.
  static Future<String?> addComment(String announcementId, String body) =>
      _rpc('add_announcement_comment',
          {'p_announcement_id': announcementId, 'p_body': body});

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

  // ── Community channels (hub "Chat" tab) ─────────────────────────

  /// The community's channels with a last-message preview. Each row:
  /// { id, name, post, is_custom, preview, last_at }.
  static Future<List<Map<String, dynamic>>> channelList(String communityId) async {
    try {
      final res = await _db
          .rpc('community_channel_list', params: {'p_community_id': communityId});
      return List<Map<String, dynamic>>.from(res as List);
    } catch (e) {
      debugPrint('[CommunityService] channelList: $e');
      return [];
    }
  }

  /// Messages in one channel, oldest first. Each row:
  /// { id, body, created_at, sender_id, fromMe, senderName }.
  static Future<List<Map<String, dynamic>>> channelMessages(String channelId) async {
    final uid = _uid;
    try {
      final res = await _db
          .from('community_chat')
          .select('id, body, created_at, sender_id, profiles(name)')
          .eq('channel_id', channelId)
          .order('created_at')
          .limit(200);
      return (res as List).map((r) {
        final m = Map<String, dynamic>.from(r as Map);
        return {
          'id': m['id'],
          'body': m['body'],
          'created_at': m['created_at'],
          'sender_id': m['sender_id'],
          'fromMe': m['sender_id'] == uid,
          'senderName': (m['profiles'] as Map?)?['name'] as String? ?? 'Player',
        };
      }).toList();
    } catch (e) {
      debugPrint('[CommunityService] channelMessages: $e');
      return [];
    }
  }

  /// Post to a channel. Returns null on success, else an error.
  static Future<String?> sendChannelMessage(
      String communityId, String channelId, String body) async {
    final uid = _uid;
    if (uid == null) return 'Not signed in.';
    try {
      await _db.from('community_chat').insert({
        'community_id': communityId,
        'channel_id': channelId,
        'sender_id': uid,
        'body': body,
      });
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  // ── Organizer channel management ────────────────────────────────

  static Future<String?> createChannel(String name, String post) =>
      _rpc('create_community_channel', {'p_name': name, 'p_post': post});

  static Future<String?> setChannelPost(String channelId, String post) =>
      _rpc('set_channel_post', {'p_channel_id': channelId, 'p_post': post});

  static Future<String?> deleteChannel(String channelId) =>
      _rpc('delete_community_channel', {'p_channel_id': channelId});

  static Future<String?> setChannelSettings(String eventPost, bool casualAuto) =>
      _rpc('set_channel_settings',
          {'p_event_post': eventPost, 'p_casual_auto': casualAuto});

  /// The organizer's channel settings { channel_event_post, channel_casual_auto }.
  static Future<Map<String, dynamic>> channelSettings() async {
    final uid = _uid;
    if (uid == null) return {'channel_event_post': 'registered', 'channel_casual_auto': false};
    try {
      final row = await _db
          .from('communities')
          .select('channel_event_post, channel_casual_auto')
          .eq('organizer_id', uid)
          .maybeSingle();
      return Map<String, dynamic>.from(row ?? const {});
    } catch (e) {
      debugPrint('[CommunityService] channelSettings: $e');
      return {'channel_event_post': 'registered', 'channel_casual_auto': false};
    }
  }

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

  static Future<String?> reply(String memberId, String body) =>
      _rpc('reply_community_message', {'p_member_id': memberId, 'p_body': body});

  /// Typed inbox: match requests + join requests + message threads.
  static Future<List<InboxItem>> typedInbox() async {
    try {
      final res = await _db.rpc('community_inbox_typed');
      return (res as List)
          .map((r) => InboxItem.fromRow(Map<String, dynamic>.from(r as Map)))
          .toList();
    } catch (e) {
      debugPrint('[CommunityService] typedInbox: $e');
      return [];
    }
  }

  static Future<String?> approveJoin(String requestId, bool approve) =>
      _rpc('approve_join_request', {'p_id': requestId, 'p_approve': approve});

  static Future<String?> resolveMatchRequest(String requestId) =>
      _rpc('resolve_match_request', {'p_id': requestId});

  static Future<String?> setApproval(bool on) =>
      _rpc('set_community_approval', {'p_on': on});

  /// Member posts a "looking for a match" request to the organizer.
  static Future<String?> createMatchRequest(String communityId, String note) =>
      _rpc('create_match_request',
          {'p_community_id': communityId, 'p_note': note});

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
  final bool verified, isMember, approvalRequired;
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
    this.approvalRequired = false,
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
        approvalRequired: r['approval_required'] == true,
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
  final bool pinned, iGoing, iLiked;
  final int going, likes, comments;
  final DateTime? createdAt;
  const Announcement({
    required this.id,
    required this.title,
    this.body,
    this.pinned = false,
    this.iGoing = false,
    this.iLiked = false,
    this.going = 0,
    this.likes = 0,
    this.comments = 0,
    this.createdAt,
  });

  factory Announcement.fromRow(Map<String, dynamic> r) => Announcement(
        id: r['id'] as String,
        title: (r['title'] as String?) ?? '',
        body: r['body'] as String?,
        pinned: r['pinned'] == true,
        iGoing: r['i_going'] == true,
        iLiked: r['i_liked'] == true,
        going: (r['going'] as num?)?.toInt() ?? 0,
        likes: (r['likes'] as num?)?.toInt() ?? 0,
        comments: (r['comments'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse(r['created_at']?.toString() ?? ''),
      );

  Announcement copyWith({bool? iGoing, int? going, bool? iLiked, int? likes, int? comments}) =>
      Announcement(
        id: id,
        title: title,
        body: body,
        pinned: pinned,
        iGoing: iGoing ?? this.iGoing,
        iLiked: iLiked ?? this.iLiked,
        going: going ?? this.going,
        likes: likes ?? this.likes,
        comments: comments ?? this.comments,
        createdAt: createdAt,
      );
}

class CommentLite {
  final String id, name, body;
  final String? avatarUrl;
  final DateTime? at;
  const CommentLite({required this.id, required this.name, required this.body, this.avatarUrl, this.at});

  factory CommentLite.fromRow(Map<String, dynamic> r) => CommentLite(
        id: r['id'] as String,
        name: (r['name'] as String?) ?? 'Player',
        body: (r['body'] as String?) ?? '',
        avatarUrl: r['avatar_url'] as String?,
        at: DateTime.tryParse(r['created_at']?.toString() ?? ''),
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

/// A typed inbox row: 'match' / 'join' / 'message'.
class InboxItem {
  final String kind; // match | join | message
  final String? id; // request id (match/join); null for message threads
  final String memberId, memberName;
  final String? avatarUrl, preview;
  final bool actionable;
  final DateTime? at;
  const InboxItem({
    required this.kind,
    this.id,
    required this.memberId,
    required this.memberName,
    this.avatarUrl,
    this.preview,
    this.actionable = false,
    this.at,
  });

  factory InboxItem.fromRow(Map<String, dynamic> r) => InboxItem(
        kind: (r['kind'] as String?) ?? 'message',
        id: r['id'] as String?,
        memberId: r['member_id'] as String,
        memberName: (r['member_name'] as String?) ?? 'Player',
        avatarUrl: r['avatar_url'] as String?,
        preview: r['preview'] as String?,
        actionable: r['actionable'] == true,
        at: DateTime.tryParse(r['created_at']?.toString() ?? ''),
      );

  String get initials {
    final parts = memberName.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/backend/services/notification_service.dart';
import '../chat/dm_chat_screen.dart';
import '../detail/match_detail_screen.dart';
import '../tournaments/tournament_detail_screen.dart';
import 'my_orders_screen.dart';
import 'settings_common.dart';

class _Notif {
  final IconData icon;
  final Color tint;
  final String title, body, time;
  final bool unread;
  final DateTime? at; // for cross-source sorting
  final String? type;
  final Map<String, dynamic>? data; // {conversation_id, sender_id, ...}
  const _Notif(this.icon, this.tint, this.title, this.body, this.time, this.unread,
      {this.at, this.type, this.data});

  /// Icon + tint for a personal notification's `type`.
  static (IconData, Color) styleFor(String? type) => switch (type) {
        'order' => (Icons.shopping_bag_outlined, AppColors.primary),
        'message' => (Icons.chat_bubble_outline_rounded, AppColors.success),
        'match' => (Icons.sports_tennis_outlined, AppColors.success),
        'tournament' => (Icons.emoji_events_outlined, AppColors.warn),
        _ => (Icons.notifications_none_rounded, AppColors.primary),
      };
}

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});
  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  bool _push = true;
  bool _invites = true;
  bool _results = true;
  bool _tournaments = false;

  List<_Notif> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Two sources merged, newest first:
  ///  • personal notifications (orders, etc.) — carry real read state;
  ///  • global `broadcasts` the admin console writes (announcements).
  Future<void> _load() async {
    final items = <_Notif>[];

    // Personal notifications.
    for (final n in await NotificationService.fetch()) {
      final (icon, tint) = _Notif.styleFor(n['type'] as String?);
      final at = DateTime.tryParse('${n['created_at']}')?.toLocal();
      items.add(_Notif(
        icon,
        tint,
        (n['title'] as String?) ?? 'Notification',
        (n['body'] as String?) ?? '',
        _ago(n['created_at'] as String?),
        n['read'] != true,
        at: at,
        type: n['type'] as String?,
        data: n['data'] is Map
            ? Map<String, dynamic>.from(n['data'] as Map)
            : null,
      ));
    }

    // Global announcements.
    try {
      final rows = await Supabase.instance.client
          .from('broadcasts')
          .select('title, body, sent_at')
          .order('sent_at', ascending: false)
          .limit(20);
      for (final r in List<Map<String, dynamic>>.from(rows as List)) {
        items.add(_Notif(
          Icons.campaign_outlined,
          AppColors.primary,
          (r['title'] as String?) ?? 'Announcement',
          (r['body'] as String?) ?? '',
          _ago(r['sent_at'] as String?),
          false,
          at: DateTime.tryParse('${r['sent_at']}')?.toLocal(),
        ));
      }
    } catch (_) {}

    items.sort((a, b) =>
        (b.at ?? DateTime(0)).compareTo(a.at ?? DateTime(0)));
    if (mounted) setState(() => _items = items);
  }

  Future<void> _markAllRead() async {
    await NotificationService.markAllRead();
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < _items.length; i++) {
        final n = _items[i];
        _items[i] = _Notif(n.icon, n.tint, n.title, n.body, n.time, false, at: n.at);
      }
    });
  }

  static String _ago(String? iso) {
    final dt = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    final d = DateTime.now().difference(dt);
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return '${dt.day}/${dt.month}';
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: 'Notifications',
      actions: [
        GestureDetector(
          onTap: _markAllRead,
          child: Text('Mark all',
              style: AppText.bodyStrong(AppColors.primary).copyWith(fontSize: 14)),
        ),
      ],
      children: [
        const SectionLabel('Recent'),
        if (_items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text('No notifications yet.',
                textAlign: TextAlign.center,
                style: AppText.body(AppColors.inkSoft).copyWith(fontSize: 13.5)),
          )
        else
          TileGroup(children: [for (final n in _items) _row(n)]),
        const SizedBox(height: 22),
        const SectionLabel('Preferences'),
        TileGroup(children: [
          SwitchTile(
            icon: Icons.notifications_active_outlined,
            title: 'Push Notifications',
            subtitle: 'Allow Padel to send alerts',
            value: _push,
            onChanged: (v) => setState(() => _push = v),
          ),
          SwitchTile(
            icon: Icons.person_add_alt_outlined,
            title: 'Match Invites',
            value: _invites,
            onChanged: (v) => setState(() => _invites = v),
          ),
          SwitchTile(
            icon: Icons.scoreboard_outlined,
            title: 'Match Results & ELO',
            value: _results,
            onChanged: (v) => setState(() => _results = v),
          ),
          SwitchTile(
            icon: Icons.emoji_events_outlined,
            title: 'Tournament Updates',
            value: _tournaments,
            onChanged: (v) => setState(() => _tournaments = v),
          ),
        ]),
      ],
    );
  }

  /// Whether tapping this row navigates somewhere (mirrors the push deep-link
  /// targets). Broadcasts and typeless rows stay display-only.
  bool _isTappable(_Notif n) {
    switch (n.type) {
      case 'message':
        return n.data?['sender_id'] is String;
      case 'match':
        return n.data?['match_id'] is String;
      case 'tournament':
        return n.data?['tournament_id'] is String;
      case 'order':
      case 'admin_order':
        return true;
      default:
        return false;
    }
  }

  void _open(_Notif n) {
    switch (n.type) {
      case 'message':
        _openChat(n);
        return;
      case 'match':
        final id = n.data?['match_id'];
        if (id is String) {
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => MatchDetailScreen(matchId: id)));
        }
        return;
      case 'tournament':
        final id = n.data?['tournament_id'];
        if (id is String) {
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => TournamentDetailScreen(tournamentId: id)));
        }
        return;
      case 'order':
      case 'admin_order':
        Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const MyOrdersScreen()));
        return;
    }
  }

  Widget _row(_Notif n) {
    // Tappable rows deep-link to their subject; others are display-only.
    final tappable = _isTappable(n);
    final content = Container(
      color: n.unread ? AppColors.primary.withValues(alpha: 0.05) : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: n.tint.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(n.icon, size: 19, color: n.tint),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(n.title,
                style: AppText.bodyStrong()
                    .copyWith(fontSize: 14, fontWeight: n.unread ? FontWeight.w800 : FontWeight.w700)),
            const SizedBox(height: 2),
            Text(n.body, style: AppText.small().copyWith(fontSize: 12, height: 1.35)),
          ]),
        ),
        const SizedBox(width: 8),
        Column(children: [
          Text(n.time, style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 10.5, letterSpacing: 0)),
          const SizedBox(height: 6),
          if (n.unread)
            Container(width: 8, height: 8, decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle)),
        ]),
        if (tappable) ...[
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.inkFaint),
        ],
      ]),
    );
    if (!tappable) return content;
    return GestureDetector(
        behavior: HitTestBehavior.opaque, onTap: () => _open(n), child: content);
  }

  void _openChat(_Notif n) {
    final senderId = n.data?['sender_id'] as String?;
    if (senderId == null) return;
    // Optimistically clear the unread dot for this row.
    final i = _items.indexOf(n);
    if (i >= 0 && n.unread) {
      setState(() => _items[i] = _Notif(
          n.icon, n.tint, n.title, n.body, n.time, false,
          at: n.at, type: n.type, data: n.data));
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DMChatScreen(
        otherId: senderId,
        name: n.title,
        initials: _initials(n.title),
      ),
    ));
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}

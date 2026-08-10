import 'package:flutter/material.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/backend/services/notification_service.dart';
import 'package:padel_clay/backend/services/ticket_service.dart';
import '../chat/dm_chat_screen.dart';
import '../detail/match_detail_screen.dart';
import '../tournaments/tournament_detail_screen.dart';
import 'my_orders_screen.dart';
import 'settings_common.dart';

class _Notif {
  final String? id; // notifications.id — for per-row mark-read
  final IconData icon;
  final Color tint;
  final String title, body, time;
  final bool unread;
  final DateTime? at; // for cross-source sorting
  final String? type;
  final Map<String, dynamic>? data; // {conversation_id, sender_id, ...}
  const _Notif(this.icon, this.tint, this.title, this.body, this.time, this.unread,
      {this.id, this.at, this.type, this.data});

  /// Copy with the unread flag flipped (keeps id/type/data intact).
  _Notif read() =>
      _Notif(icon, tint, title, body, time, false, id: id, at: at, type: type, data: data);

  /// Icon + tint for a personal notification's `type`.
  static (IconData, Color) styleFor(String? type) => switch (type) {
        'order' => (Icons.shopping_bag_outlined, AppColors.primary),
        'message' => (Icons.chat_bubble_outline_rounded, AppColors.success),
        'match' => (Icons.sports_tennis_outlined, AppColors.success),
        'tournament' => (Icons.emoji_events_outlined, AppColors.warn),
        'broadcast' => (Icons.campaign_outlined, AppColors.primary),
        _ => (Icons.notifications_none_rounded, AppColors.primary),
      };
}

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});
  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  // Push preferences (persisted to profiles.notify_*). Master gates everything;
  // the category toggles gate their own notification type. Honoured server-side
  // by the push-notify Edge Function.
  bool _push = true;
  bool _match = true;
  bool _tournaments = true;
  bool _orders = true;

  List<_Notif> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final p = await NotificationService.fetchPrefs();
    if (!mounted) return;
    setState(() {
      _push = p['push'] ?? true;
      _match = p['match'] ?? true;
      _tournaments = p['tournament'] ?? true;
      _orders = p['order'] ?? true;
    });
  }

  /// Flip a toggle locally and persist it (fire-and-forget).
  void _setPref(String key, bool value, void Function(bool) apply) {
    setState(() => apply(value));
    NotificationService.setPref(key, value);
  }

  /// Personal notifications, newest first. Broadcasts now arrive here too: a DB
  /// trigger fans each admin broadcast into a per-user 'broadcast' row (so they
  /// carry real read state, badge the bell, and push), rather than the client
  /// reading the global `broadcasts` table directly.
  Future<void> _load() async {
    final items = <_Notif>[];

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
        id: n['id'] as String?,
        at: at,
        type: n['type'] as String?,
        data: n['data'] is Map
            ? Map<String, dynamic>.from(n['data'] as Map)
            : null,
      ));
    }

    items.sort((a, b) =>
        (b.at ?? DateTime(0)).compareTo(a.at ?? DateTime(0)));
    if (!mounted) return;
    setState(() => _items = items);

    // Opening the bell IS the read receipt — seeing the list is what "read"
    // means here, so nobody should have to tap "Mark all" to clear the badge.
    if (items.any((n) => n.unread)) await _markAllRead();
  }

  Future<void> _markAllRead() async {
    await NotificationService.markAllRead();
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < _items.length; i++) {
        _items[i] = _items[i].read();
      }
    });
  }

  /// Mark one row read locally + in the DB (called on tap-through).
  void _markReadLocal(_Notif n) {
    if (!n.unread) return;
    final i = _items.indexOf(n);
    if (i >= 0) setState(() => _items[i] = n.read());
    if (n.id != null) NotificationService.markRead(n.id!);
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
      // No "Mark all" action — opening this screen already marks everything
      // read, so the button would never have anything left to do.
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
        const SectionLabel('Push Alerts'),
        TileGroup(children: [
          SwitchTile(
            icon: Icons.notifications_active_outlined,
            title: 'Push Notifications',
            subtitle: 'Allow Padel to send alerts',
            value: _push,
            onChanged: (v) => _setPref('push', v, (x) => _push = x),
          ),
          SwitchTile(
            icon: Icons.sports_tennis_outlined,
            title: 'Match Updates',
            subtitle: 'Joins, results & ELO changes',
            value: _match,
            onChanged: (v) => _setPref('match', v, (x) => _match = x),
          ),
          SwitchTile(
            icon: Icons.emoji_events_outlined,
            title: 'Tournament Updates',
            value: _tournaments,
            onChanged: (v) => _setPref('tournament', v, (x) => _tournaments = x),
          ),
          SwitchTile(
            icon: Icons.shopping_bag_outlined,
            title: 'Store & Orders',
            subtitle: 'Order status & trade-ins',
            value: _orders,
            onChanged: (v) => _setPref('order', v, (x) => _orders = x),
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
        // A number request has no match to open — it opens an answer sheet.
        return n.data?['match_id'] is String ||
            n.data?['request_id'] is String;
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
    // Tapping any notification clears its unread state; only rows with a real
    // target then navigate — the rest (broadcasts, announcements) just mark read.
    _markReadLocal(n);
    if (!_isTappable(n)) return;
    switch (n.type) {
      case 'message':
        _openChat(n);
        return;
      case 'match':
        final req = n.data?['request_id'];
        if (req is String) {
          _answerNumberRequest(req, n.title);
          return;
        }
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

  /// Someone asked for my number. Answering here rather than deep-linking into
  /// the ticket keeps it to one tap, and the dialog is explicit that saying yes
  /// is a swap — the requester gets mine too.
  Future<void> _answerNumberRequest(String requestId, String title) async {
    final accept = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(title, style: AppText.bodyStrong()),
        content: Text(
            'Sharing works both ways — they get your number and you get theirs. '
            'You can undo it later in Privacy.',
            style: AppText.small().copyWith(height: 1.45)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text('No thanks', style: AppText.bodyStrong())),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text('Share it',
                  style: AppText.bodyStrong(AppColors.primary))),
        ],
      ),
    );
    if (accept == null || !mounted) return;
    final err = await TicketService.respondToNumberRequest(requestId,
        accept: accept);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: err == null ? null : AppColors.danger,
        content: Text(err ??
            (accept ? 'Numbers shared.' : 'Declined — nothing was shared.'))));
  }

  Widget _row(_Notif n) {
    // Rows with a subject show a chevron and deep-link on tap; all rows are
    // still tappable so a tap always clears the unread dot (no page opens for
    // display-only ones like broadcasts).
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
    return GestureDetector(
        behavior: HitTestBehavior.opaque, onTap: () => _open(n), child: content);
  }

  void _openChat(_Notif n) {
    final senderId = n.data?['sender_id'] as String?;
    if (senderId == null) return;
    // Unread state already cleared by _open() before we got here.
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

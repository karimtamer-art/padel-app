import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/screen_bar.dart';
import 'package:padel_clay/frontend/widgets/auto_refresh.dart';
import 'package:padel_clay/backend/services/dm_service.dart';
import 'package:padel_clay/backend/services/ticket_service.dart';
import 'dm_chat_screen.dart';
import 'match_ticket_screen.dart';

/// One place for ALL your messages: the automatic match tickets (a group
/// thread per match) followed by every 1-on-1 conversation. Rows are
/// newest-activity-first with an unread count; tapping opens the thread.
///
/// Tickets always sort above DMs — they are time-critical in a way a DM
/// isn't, since the match is happening whether you read it or not.
class MessagesInboxScreen extends StatefulWidget {
  const MessagesInboxScreen({super.key});
  @override
  State<MessagesInboxScreen> createState() => _MessagesInboxScreenState();
}

class _MessagesInboxScreenState extends State<MessagesInboxScreen> with AutoRefresh<MessagesInboxScreen> {
  List<Map<String, dynamic>> _rows = [];
  List<Map<String, dynamic>> _tickets = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Future<void> onAutoRefresh() => _load();

  Future<void> _load() async {
    // Independently, so a database without the tickets delta still shows DMs.
    final results = await Future.wait([
      TicketService.inbox(),
      DmService.inbox(),
    ]);
    if (!mounted) return;
    setState(() {
      _tickets = results[0];
      _rows = results[1];
      _loading = false;
    });
  }

  Future<void> _openTicket(Map<String, dynamic> t) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MatchTicketScreen(
        ticketId: t['ticket_id'] as String,
        isOpen: t['is_open'] == true,
        matchType: (t['match_type'] as String?) ?? 'casual',
        scheduledAt: DateTime.tryParse('${t['scheduled_at']}'),
        venue: t['venue'] as String?,
        court: t['court'] as String?,
      ),
    ));
    if (mounted) _load();
  }

  Future<void> _open(Map<String, dynamic> r) async {
    final name = (r['other_name'] as String?)?.trim();
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DMChatScreen(
        otherId: r['other_id'] as String,
        name: (name == null || name.isEmpty) ? 'Player' : name,
        initials: _initials(name),
        username: r['other_username'] as String?,
        avatarUrl: r['other_avatar'] as String?,
      ),
    ));
    // Reading a chat marks it read — refresh so the dot clears.
    if (mounted) _load();
  }

  /// Long-press a DM. Only tickets are excluded — a ticket isn't yours to
  /// delete, it belongs to the match and would reappear on the next message.
  Future<void> _rowMenu(Map<String, dynamic> r) async {
    final name = (r['other_name'] as String?)?.trim();
    final display = (name == null || name.isEmpty) ? 'this player' : name;
    HapticFeedback.selectionClick();
    final delete = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetCtx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
                color: AppColors.line, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: 14),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded,
                color: AppColors.danger),
            title: Text('Delete chat',
                style: AppText.bodyStrong(AppColors.danger)),
            subtitle: Text('Removes it from your Messages only',
                style: AppText.small(AppColors.inkFaint)),
            onTap: () => Navigator.pop(sheetCtx, true),
          ),
          const SizedBox(height: 10),
        ]),
      ),
    );
    if (delete != true || !mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text('Delete this chat?', style: AppText.cardTitle()),
        // Say plainly that it is one-sided. People assume delete means gone
        // everywhere, and finding out otherwise later feels like a betrayal.
        content: Text(
          'It disappears from your Messages. $display keeps their copy, and '
          'the chat comes back if they message you again.',
          style: AppText.body(AppColors.inkSoft).copyWith(height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: Text('Cancel', style: AppText.bodyStrong(AppColors.inkSoft)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dCtx, true),
            child: Text('Delete', style: AppText.bodyStrong(AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final err = await DmService.clearConversation(r['conversation_id'] as String);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating, content: Text(err)));
      return;
    }
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        behavior: SnackBarBehavior.floating, content: Text('Chat deleted.')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(children: [
        ScreenBar(title: 'Messages', onBack: () => Navigator.pop(context)),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
              : RefreshIndicator(
                  color: AppColors.primary,
                  onRefresh: _load,
                  child: (_rows.isEmpty && _tickets.isEmpty) ? _empty() : _list(),
                ),
        ),
      ]),
    );
  }

  Widget _list() => ListView(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.screen, 10, AppSpacing.screen, 40),
        children: [
          if (_tickets.isNotEmpty) ...[
            _explainer(),
            const SizedBox(height: 10),
            for (final t in _tickets) ...[
              _ticketRow(t),
              const SizedBox(height: 10),
            ],
          ],
          if (_rows.isNotEmpty) ...[
            if (_tickets.isNotEmpty) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 8, left: 2),
                child: Text('DIRECT', style: AppText.kicker()),
              ),
            ],
            for (final r in _rows) ...[
              _row(r),
              const SizedBox(height: 10),
            ],
          ],
        ],
      );

  /// Tickets appear without anyone asking for them, so the list says why.
  Widget _explainer() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: AppColors.field, borderRadius: BorderRadius.circular(12)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.confirmation_number_outlined,
              size: 16, color: AppColors.primary),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
                'A ticket opens here automatically whenever you create or '
                'join a match — all four players in one place.',
                style: AppText.small(AppColors.inkSoft)
                    .copyWith(fontSize: 11.5, height: 1.4)),
          ),
        ]),
      );

  Widget _ticketRow(Map<String, dynamic> t) {
    final open = t['is_open'] == true;
    final unread = (t['unread'] as int?) ?? 0;
    final hasUnread = unread > 0;
    final ranked = t['match_type'] == 'ranked';
    final at = DateTime.tryParse('${t['scheduled_at']}')?.toLocal();
    final place = [t['venue'] as String?, t['court'] as String?]
        .where((s) => s != null && s.trim().isNotEmpty)
        .join(' — ');
    final preview = (t['last_text'] as String?)?.trim() ?? '';
    final sender = (t['last_sender'] as String?)?.trim() ?? '';

    return GestureDetector(
      onTap: () => _openTicket(t),
      child: AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: open
                  ? AppColors.wash(AppColors.primary, 0.16)
                  : AppColors.field,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.confirmation_number_outlined,
                size: 20,
                color: open ? AppColors.primary : AppColors.inkFaint),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(ranked ? 'Competitive match' : 'Casual match',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.bodyStrong(AppColors.ink).copyWith(
                              fontSize: 14.5,
                              fontWeight: hasUnread
                                  ? FontWeight.w800
                                  : FontWeight.w700)),
                    ),
                    const SizedBox(width: 6),
                    AppTag(open ? 'TICKET' : 'CLOSED',
                        color: open ? AppColors.primary : AppColors.inkFaint),
                    const Spacer(),
                    Text(_ago(t['last_at'] as String?),
                        style: AppText.tag(hasUnread
                                ? AppColors.primary
                                : AppColors.inkFaint)
                            .copyWith(fontSize: 11)),
                  ]),
                  const SizedBox(height: 3),
                  Text(
                      [
                        if (at != null) _whenShort(at),
                        if (place.isNotEmpty) place,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.small(AppColors.inkFaint)
                          .copyWith(fontSize: 11.5)),
                  const SizedBox(height: 4),
                  Row(children: [
                    Expanded(
                      child: Text(
                          preview.isEmpty
                              ? 'No messages yet — break the ice.'
                              : (sender.isEmpty
                                  ? preview
                                  : '${sender.split(RegExp(r"\s+")).first}: $preview'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.small(hasUnread
                                  ? AppColors.inkSoft
                                  : AppColors.inkFaint)
                              .copyWith(
                                  fontSize: 12.5,
                                  fontWeight: hasUnread
                                      ? FontWeight.w700
                                      : FontWeight.w500)),
                    ),
                    if (hasUnread) ...[
                      const SizedBox(width: 8),
                      Container(
                        constraints: const BoxConstraints(minWidth: 18),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                            color: AppColors.danger,
                            borderRadius: BorderRadius.circular(9)),
                        child: Text(unread > 9 ? '9+' : '$unread',
                            style: AppText.tag(Colors.white)
                                .copyWith(fontSize: 10)),
                      ),
                    ],
                  ]),
                ]),
          ),
        ]),
      ),
    );
  }

  static String _whenShort(DateTime dt) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(dt.year, dt.month, dt.day);
    final diff = that.difference(today).inDays;
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final time = '$h:$m ${dt.hour < 12 ? 'AM' : 'PM'}';
    if (diff == 0) return 'Today, $time';
    if (diff == 1) return 'Tomorrow, $time';
    if (diff == -1) return 'Yesterday, $time';
    if (diff > 1 && diff < 7) return '${days[dt.weekday - 1]}, $time';
    return '${dt.day}/${dt.month}, $time';
  }

  Widget _row(Map<String, dynamic> r) {
    final name = (r['other_name'] as String?)?.trim();
    final display = (name == null || name.isEmpty) ? 'Player' : name;
    final preview = (r['last_text'] as String?)?.trim() ?? '';
    final unread = (r['unread'] as int?) ?? 0;
    final hasUnread = unread > 0;
    return GestureDetector(
      onTap: () => _open(r),
      onLongPress: () => _rowMenu(r),
      child: AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(children: [
          AppAvatar(_initials(name), size: 46, color: AppColors.primary,
              imageUrl: r['other_avatar'] as String?),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(display,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.bodyStrong(AppColors.ink).copyWith(
                            fontSize: 14.5,
                            fontWeight:
                                hasUnread ? FontWeight.w800 : FontWeight.w700)),
                  ),
                  const SizedBox(width: 8),
                  Text(_ago(r['last_at'] as String?),
                      style: AppText.tag(
                              hasUnread ? AppColors.primary : AppColors.inkFaint)
                          .copyWith(fontSize: 11)),
                ]),
                const SizedBox(height: 3),
                Row(children: [
                  Expanded(
                    child: Text(preview.isEmpty ? 'Say hi 👋' : preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.small(hasUnread
                                ? AppColors.inkSoft
                                : AppColors.inkFaint)
                            .copyWith(
                                fontSize: 12.5,
                                fontWeight: hasUnread
                                    ? FontWeight.w700
                                    : FontWeight.w500)),
                  ),
                  if (hasUnread) ...[
                    const SizedBox(width: 8),
                    Container(
                      constraints: const BoxConstraints(minWidth: 18),
                      padding:
                          const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          color: AppColors.danger,
                          borderRadius: BorderRadius.circular(9)),
                      child: Text(unread > 9 ? '9+' : '$unread',
                          style: AppText.tag(Colors.white).copyWith(fontSize: 10)),
                    ),
                  ],
                ]),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _empty() => ListView(
        // ListView so pull-to-refresh still works on the empty state.
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.22),
          Center(
            child: Column(children: [
              const Icon(Icons.forum_outlined, size: 46, color: AppColors.inkFaint),
              const SizedBox(height: 14),
              Text('No messages yet',
                  style: AppText.bodyStrong(AppColors.inkSoft)),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                    'Message a player from a match lobby or your community '
                    'members and it shows up here.',
                    textAlign: TextAlign.center,
                    style: AppText.small(AppColors.inkFaint)),
              ),
            ]),
          ),
        ],
      );

  static String _initials(String? name) {
    final parts = (name ?? '').trim().split(RegExp(r'\s+'))
      ..removeWhere((s) => s.isEmpty);
    if (parts.isEmpty) return 'P';
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }
    return (parts.first.substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }

  static String _ago(String? iso) {
    final dt = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    final d = DateTime.now().difference(dt);
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    if (d.inDays < 7) return '${d.inDays}d';
    return '${d.inDays ~/ 7}w';
  }
}

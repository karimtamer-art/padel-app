import 'package:flutter/material.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/screen_bar.dart';
import 'package:padel_clay/backend/services/dm_service.dart';
import 'dm_chat_screen.dart';

/// One place for ALL your direct messages — every 1-on-1 conversation, not
/// just the ones reached from a match lobby or a community member card. Rows
/// are newest-activity-first with an unread dot; tapping opens the chat.
class MessagesInboxScreen extends StatefulWidget {
  const MessagesInboxScreen({super.key});
  @override
  State<MessagesInboxScreen> createState() => _MessagesInboxScreenState();
}

class _MessagesInboxScreenState extends State<MessagesInboxScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await DmService.inbox();
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  Future<void> _open(Map<String, dynamic> r) async {
    final name = (r['other_name'] as String?)?.trim();
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DMChatScreen(
        otherId: r['other_id'] as String,
        name: (name == null || name.isEmpty) ? 'Player' : name,
        initials: _initials(name),
        username: r['other_username'] as String?,
      ),
    ));
    // Reading a chat marks it read — refresh so the dot clears.
    if (mounted) _load();
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
                  child: _rows.isEmpty ? _empty() : _list(),
                ),
        ),
      ]),
    );
  }

  Widget _list() => ListView.separated(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.screen, 10, AppSpacing.screen, 40),
        itemCount: _rows.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) => _row(_rows[i]),
      );

  Widget _row(Map<String, dynamic> r) {
    final name = (r['other_name'] as String?)?.trim();
    final display = (name == null || name.isEmpty) ? 'Player' : name;
    final preview = (r['last_text'] as String?)?.trim() ?? '';
    final unread = (r['unread'] as int?) ?? 0;
    final hasUnread = unread > 0;
    return GestureDetector(
      onTap: () => _open(r),
      child: AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(children: [
          AppAvatar(_initials(name), size: 46, color: AppColors.primary),
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

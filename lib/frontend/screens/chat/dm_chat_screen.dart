import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/backend/services/dm_service.dart';
import 'package:padel_clay/backend/services/notification_service.dart';
import 'package:padel_clay/frontend/widgets/moderation_sheet.dart';

/// 1-on-1 chat between two players. The conversation is resolved/created on
/// open; messages stream live via Supabase realtime. Reached from the match
/// lobby's contact sheet ("Message in app").
class DMChatScreen extends StatefulWidget {
  final String otherId;
  final String name;
  final String initials;
  final String? username;
  final String? matchId;
  const DMChatScreen({
    super.key,
    required this.otherId,
    required this.name,
    required this.initials,
    this.username,
    this.matchId,
  });

  @override
  State<DMChatScreen> createState() => _DMChatScreenState();
}

class _DMChatScreenState extends State<DMChatScreen> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  String? _convId;
  List<Map<String, dynamic>> _messages = [];
  StreamSubscription<List<Map<String, dynamic>>>? _sub;
  bool _loading = true;

  static const _quickReplies = [
    'On my way 🎾',
    'Running 5 min late',
    'Which court again?',
    'See you there 👊',
  ];

  String? get _uid => Supabase.instance.client.auth.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() => setState(() {}));
    _init();
  }

  Future<void> _init() async {
    final id = await DmService.getOrCreateConversation(widget.otherId,
        matchId: widget.matchId);
    if (!mounted) return;
    if (id == null) {
      setState(() => _loading = false);
      return;
    }
    _convId = id;
    NotificationService.markConversationRead(id);
    _sub = DmService.messageStream(id).listen((rows) {
      if (!mounted) return;
      setState(() {
        _messages = rows;
        _loading = false;
      });
      _scrollToBottom();
      // Reading live — keep the bell from counting these.
      NotificationService.markConversationRead(id);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send(String text) async {
    final t = text.trim();
    if (t.isEmpty || _convId == null) return;
    _ctrl.clear();
    setState(() {});
    final err = await DmService.send(_convId!, t);
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating, content: Text(err)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(children: [
        _header(),
        Expanded(
          child: (_convId == null && !_loading) ? _unavailable() : _messagesArea(),
        ),
        if (_convId != null) ...[
          _quickRepliesRow(),
          _composer(),
        ],
      ]),
    );
  }

  Widget _header() => Container(
        padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + 6, bottom: 12),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.hero, AppColors.hero2]),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            _glassBtn(Icons.arrow_back_ios_new_rounded, () => Navigator.pop(context)),
            const SizedBox(width: 10),
            AppAvatar(widget.initials, size: 38, color: AppColors.gold, ring: 2),
            const SizedBox(width: 11),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.bodyStrong(AppColors.heroInk)
                        .copyWith(fontSize: 15, fontWeight: FontWeight.w800)),
                if (widget.username != null && widget.username!.isNotEmpty)
                  Text('@${widget.username}',
                      style: AppText.tag(AppColors.heroFaint).copyWith(fontSize: 11)),
              ]),
            ),
            // Report / block. Blocking closes the thread, since its messages
            // are hidden from this point on.
            _glassBtn(Icons.more_horiz_rounded, () {
              ModerationSheet.show(
                context,
                userId: widget.otherId,
                userName: widget.name,
                onBlocked: () => Navigator.of(context).pop(),
              );
            }),
          ]),
        ),
      );

  Widget _glassBtn(IconData icon, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, size: 16, color: AppColors.heroInk),
        ),
      );

  Widget _messagesArea() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      itemCount: _messages.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Center(
              child: Text('Coordinate your match · be on time 🎾',
                  style: AppText.small(AppColors.inkFaint).copyWith(fontSize: 11)),
            ),
          );
        }
        final m = _messages[i - 1];
        return _bubble(m, m['sender_id'] == _uid);
      },
    );
  }

  Widget _bubble(Map<String, dynamic> m, bool mine) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints:
                BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
            // Long-press to report the specific message — reporting the whole
            // person is in the header menu. No point offering it on your own.
            child: GestureDetector(
              onLongPress: mine
                  ? null
                  : () => ModerationSheet.show(
                        context,
                        userId: widget.otherId,
                        userName: widget.name,
                        targetType: 'dm_message',
                        targetId: m['id'] as String?,
                        onBlocked: () => Navigator.of(context).pop(),
                      ),
              child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
              decoration: BoxDecoration(
                color: mine ? AppColors.primary : AppColors.surface,
                border: mine ? null : Border.all(color: AppColors.line),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(mine ? 16 : 4),
                  bottomRight: Radius.circular(mine ? 4 : 16),
                ),
              ),
                child: Text(m['text'] as String? ?? '',
                    style: AppText.body(mine ? AppColors.primaryInk : AppColors.ink)
                        .copyWith(fontSize: 13.5, height: 1.4)),
              ),
            ),
          ),
          const SizedBox(height: 3),
          Text(_fmtTime(m['sent_at'] as String?),
              style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 10, letterSpacing: 0)),
        ],
      ),
    );
  }

  Widget _quickRepliesRow() => SizedBox(
        height: 42,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          itemCount: _quickReplies.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (_, i) => Center(
            child: GestureDetector(
              onTap: () => _send(_quickReplies[i]),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: AppColors.line)),
                child: Text(_quickReplies[i],
                    style: AppText.bodyStrong(AppColors.inkSoft).copyWith(fontSize: 12.5)),
              ),
            ),
          ),
        ),
      );

  Widget _composer() {
    final hasText = _ctrl.text.trim().isNotEmpty;
    return Container(
      decoration: const BoxDecoration(
          color: AppColors.bg,
          border: Border(top: BorderSide(color: AppColors.lineSoft))),
      padding: EdgeInsets.fromLTRB(14, 8, 14, 24 + MediaQuery.of(context).padding.bottom),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
                color: AppColors.field,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: AppColors.line)),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _ctrl,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: _send,
              style: AppText.body(AppColors.ink).copyWith(fontSize: 14),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                hintText: 'Message…',
                hintStyle: AppText.body(AppColors.inkFaint).copyWith(fontSize: 14),
              ),
            ),
          ),
        ),
        const SizedBox(width: 9),
        GestureDetector(
          onTap: hasText ? () => _send(_ctrl.text) : null,
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: hasText ? AppColors.primary : AppColors.line,
                shape: BoxShape.circle),
            child: Icon(Icons.arrow_upward_rounded,
                size: 20, color: hasText ? AppColors.primaryInk : AppColors.inkFaint),
          ),
        ),
      ]),
    );
  }

  Widget _unavailable() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text("Couldn't open this chat. Please try again.",
              textAlign: TextAlign.center,
              style: AppText.body(AppColors.inkSoft)),
        ),
      );

  static String _fmtTime(String? iso) {
    final dt = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m ${dt.hour < 12 ? 'AM' : 'PM'}';
  }
}

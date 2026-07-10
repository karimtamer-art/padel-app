import 'package:flutter/material.dart';
import '../../../backend/services/community_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/common.dart';

/// Member ↔ organizer 1:1 thread (community_messages). Organizers read/reply in
/// the console; this is the player side.
class MessageOrganizerScreen extends StatefulWidget {
  final String communityId;
  final String organizerName;
  const MessageOrganizerScreen(
      {super.key, required this.communityId, required this.organizerName});

  @override
  State<MessageOrganizerScreen> createState() => _MessageOrganizerScreenState();
}

class _MessageOrganizerScreenState extends State<MessageOrganizerScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<CommunityMessage> _messages = [];
  bool _loading = true, _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final msgs = await CommunityService.myThread(widget.communityId);
    if (!mounted) return;
    setState(() {
      _messages = msgs;
      _loading = false;
    });
    _toBottom();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final err = await CommunityService.sendMessage(widget.communityId, text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (err != null) {
      AppToast.show(context, err, kind: ToastKind.error);
      return;
    }
    _input.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        titleSpacing: 0,
        title: Row(children: [
          AppAvatar(_initials(widget.organizerName), size: 34, color: AppColors.gold),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.organizerName,
                      style: AppText.bodyStrong(), maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text('Organizer · usually replies within a day',
                      style: AppText.small(AppColors.inkFaint)),
                ]),
          ),
        ]),
      ),
      body: Column(children: [
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
              : _messages.isEmpty
                  ? _empty()
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                      itemCount: _messages.length,
                      itemBuilder: (_, i) => _bubble(_messages[i]),
                    ),
        ),
        _composer(),
      ]),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.chat_bubble_outline_rounded, size: 40, color: AppColors.inkFaint),
            const SizedBox(height: 12),
            Text('Say hi to ${widget.organizerName}',
                style: AppText.bodyStrong(), textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text('Ask about events, levels, or joining a session.',
                style: AppText.small(), textAlign: TextAlign.center),
          ]),
        ),
      );

  Widget _bubble(CommunityMessage m) {
    final mine = m.fromMe;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.74),
        decoration: BoxDecoration(
          color: mine ? AppColors.primary : AppColors.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(mine ? 14 : 4),
            bottomRight: Radius.circular(mine ? 4 : 14),
          ),
          border: mine ? null : Border.all(color: AppColors.line),
        ),
        child: Text(m.body,
            style: AppText.body(mine ? AppColors.primaryInk : AppColors.ink)),
      ),
    );
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: const BoxDecoration(
            color: AppColors.surface,
            border: Border(top: BorderSide(color: AppColors.line))),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _input,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              style: AppText.body(),
              decoration: InputDecoration(
                hintText: 'Message…',
                hintStyle: AppText.small(AppColors.inkFaint),
                filled: true,
                fillColor: AppColors.field,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _sending ? null : _send,
            child: Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                  color: AppColors.primary, shape: BoxShape.circle),
              child: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.primaryInk))
                  : const Icon(Icons.send_rounded, size: 20, color: AppColors.primaryInk),
            ),
          ),
        ]),
      ),
    );
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}

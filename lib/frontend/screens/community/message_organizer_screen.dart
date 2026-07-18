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
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.7, -1),
                radius: 0.9,
                colors: [AppColors.primary.withValues(alpha: 0.05), Colors.transparent],
              ),
            ),
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
                : _messages.isEmpty
                    ? _empty()
                    : ListView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                        children: [
                          _introPill(),
                          const SizedBox(height: 14),
                          for (var i = 0; i < _messages.length; i++) _bubble(i),
                        ],
                      ),
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

  Widget _introPill() => Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
              color: AppColors.field,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: AppColors.lineSoft)),
          child: Text('Chatting with ${widget.organizerName}, the organizer',
              style: AppText.small(AppColors.inkFaint).copyWith(fontSize: 11.5)),
        ),
      );

  static String _fmt(DateTime? at) {
    if (at == null) return '';
    final t = at.toLocal();
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  // Grouped bubbles by side (me vs organizer): tighten inner corners mid-run,
  // timestamp on the last bubble only.
  Widget _bubble(int i) {
    final m = _messages[i];
    final me = m.fromMe;
    bool same(CommunityMessage? a, CommunityMessage? b) => a != null && b != null && a.fromMe == b.fromMe;
    final first = !same(i > 0 ? _messages[i - 1] : null, m);
    final last = !same(i + 1 < _messages.length ? _messages[i + 1] : null, m);

    const r = Radius.circular(18);
    const tight = Radius.circular(6);
    final radius = me
        ? BorderRadius.only(
            topLeft: r, bottomLeft: r,
            topRight: first ? r : tight, bottomRight: last ? r : tight)
        : BorderRadius.only(
            topRight: r, bottomRight: r,
            topLeft: first ? r : tight, bottomLeft: last ? r : tight);
    final time = _fmt(m.at);

    return Padding(
      padding: EdgeInsets.only(top: first ? 9 : 3),
      child: Align(
        alignment: me ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.76),
          decoration: BoxDecoration(
            color: me ? AppColors.primary : AppColors.surface,
            borderRadius: radius,
            border: me ? null : Border.all(color: AppColors.lineSoft),
            boxShadow: me
                ? null
                : const [BoxShadow(color: Color.fromRGBO(40, 30, 15, 0.05), blurRadius: 2, offset: Offset(0, 1))],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(m.body,
                style: AppText.body(me ? AppColors.primaryInk : AppColors.ink)
                    .copyWith(height: 1.35)),
            if (last && time.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(time,
                  style: AppText.small(me ? AppColors.primaryInk.withValues(alpha: 0.7) : AppColors.inkFaint)
                      .copyWith(fontSize: 10)),
            ],
          ]),
        ),
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

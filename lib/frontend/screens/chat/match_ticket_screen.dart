import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/backend/services/ticket_service.dart';
import 'package:padel_clay/frontend/widgets/moderation_sheet.dart';

/// The automatic group thread for one match: all four players, a greeting
/// explaining what it is for, and everyone's phone number.
///
/// The greeting is BUILT from the match, never stored as a message, so it
/// always reflects the current court and time.
///
/// Numbers come from `ticket_roster` and are blank once the ticket closes —
/// the thread tells players that up front so they can save what they need.
class MatchTicketScreen extends StatefulWidget {
  final String ticketId;

  /// Everything needed to draw the hero before the roster lands, so opening
  /// the thread never flashes an empty header.
  final bool isOpen;
  final String matchType;
  final DateTime? scheduledAt;
  final String? venue;
  final String? court;

  const MatchTicketScreen({
    super.key,
    required this.ticketId,
    required this.isOpen,
    required this.matchType,
    this.scheduledAt,
    this.venue,
    this.court,
  });

  @override
  State<MatchTicketScreen> createState() => _MatchTicketScreenState();
}

class _MatchTicketScreenState extends State<MatchTicketScreen> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  StreamSubscription<List<Map<String, dynamic>>>? _sub;

  List<Map<String, dynamic>> _messages = [];
  List<Map<String, dynamic>> _roster = [];
  bool _loading = true;
  int _tab = 0; // 0 = chat, 1 = players

  /// Posted straight away — the point is to get the first message out of the
  /// way, since nobody wants to be the one who speaks first.
  static const _iceBreakers = [
    "I'll bring the balls 🎾",
    'Who needs a ride?',
    'See you there!',
  ];

  String? get _uid => Supabase.instance.client.auth.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() => setState(() {}));
    _init();
  }

  Future<void> _init() async {
    TicketService.markRead(widget.ticketId);
    final roster = await TicketService.roster(widget.ticketId);
    if (mounted) setState(() => _roster = roster);

    _sub = TicketService.messageStream(widget.ticketId).listen((rows) {
      if (!mounted) return;
      setState(() {
        _messages = rows;
        _loading = false;
      });
      _scrollToBottom();
      // Reading live — don't let the badge count what's on screen.
      TicketService.markRead(widget.ticketId);
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
    if (t.isEmpty) return;
    _ctrl.clear();
    setState(() {});
    final err = await TicketService.send(widget.ticketId, t);
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.danger,
          content: Text(err)));
    }
  }

  // ── roster helpers ──────────────────────────────────────────────────────

  List<Map<String, dynamic>> get _myTeam {
    final meTeam = _me?['team'];
    if (meTeam == null) return const [];
    return _roster.where((p) => p['team'] == meTeam).toList();
  }

  List<Map<String, dynamic>> get _theirTeam {
    final meTeam = _me?['team'];
    if (meTeam == null) return _roster;
    return _roster.where((p) => p['team'] != meTeam).toList();
  }

  Map<String, dynamic>? get _me {
    for (final p in _roster) {
      if (p['is_me'] == true) return p;
    }
    return null;
  }

  static String _nameOf(Map<String, dynamic> p) =>
      ((p['name'] as String?)?.trim().isNotEmpty ?? false)
          ? (p['name'] as String).trim()
          : 'Player';

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'))
      ..removeWhere((s) => s.isEmpty);
    if (parts.isEmpty) return 'P';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }

  static String _firstName(String name) => name.trim().split(RegExp(r'\s+')).first;

  /// "You & Ahmed" — the pair label under each side of the VS.
  String _pairLabel(List<Map<String, dynamic>> team, {required bool mine}) {
    if (team.isEmpty) return mine ? 'You' : 'Opponents';
    final names = <String>[];
    for (final p in team) {
      names.add(p['is_me'] == true ? 'You' : _firstName(_nameOf(p)));
    }
    return names.join(' & ');
  }

  String get _matchLine {
    final t = widget.matchType == 'ranked' ? 'Competitive' : 'Casual';
    return '$t · Doubles';
  }

  String get _whenLine {
    final at = widget.scheduledAt?.toLocal();
    final place = [widget.venue, widget.court]
        .where((s) => s != null && s.trim().isNotEmpty)
        .join(' — ');
    final when = at == null ? '' : _fmtWhen(at);
    if (when.isEmpty) return place;
    return place.isEmpty ? when : '$when · $place';
  }

  static String _fmtWhen(DateTime dt) {
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
    if (diff > 1 && diff < 7) return '${days[dt.weekday - 1]}, $time';
    return '${dt.day}/${dt.month}, $time';
  }

  /// "in 3h" — only while the match is still ahead of us.
  String? get _countdown {
    final at = widget.scheduledAt;
    if (at == null || !widget.isOpen) return null;
    final d = at.difference(DateTime.now());
    if (d.isNegative) return null;
    if (d.inMinutes < 60) return 'in ${d.inMinutes}m';
    if (d.inHours < 24) return 'in ${d.inHours}h';
    return 'in ${d.inDays}d';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(children: [
        _hero(),
        Expanded(child: _tab == 0 ? _chatTab() : _playersTab()),
        if (_tab == 0) (widget.isOpen ? _composer() : _lockedNotice()),
      ]),
    );
  }

  // ── hero ────────────────────────────────────────────────────────────────

  Widget _hero() => Container(
        padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + 8, bottom: 12),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.hero, AppColors.hero2],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              _glassBtn(Icons.arrow_back_ios_new_rounded,
                  () => Navigator.pop(context)),
              const SizedBox(width: 10),
              Text('MATCH TICKET',
                  style: AppText.kicker(AppColors.heroFaint)
                      .copyWith(fontSize: 9.5, letterSpacing: 1.3)),
              const SizedBox(width: 7),
              _chip(widget.isOpen ? 'OPEN' : 'CLOSED',
                  widget.isOpen ? AppColors.success : AppColors.heroFaint),
              const Spacer(),
              if (_countdown != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(999)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.schedule_rounded,
                        size: 12, color: AppColors.heroInk),
                    const SizedBox(width: 5),
                    Text(_countdown!,
                        style: AppText.tag(AppColors.heroInk)
                            .copyWith(fontSize: 10.5)),
                  ]),
                ),
            ]),
            const SizedBox(height: 14),
            _matchUp(),
            const SizedBox(height: 13),
            Text(_matchLine,
                style: AppText.bodyStrong(AppColors.heroInk)
                    .copyWith(fontSize: 15.5, fontWeight: FontWeight.w900)),
            if (_whenLine.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(_whenLine,
                  style: AppText.small(AppColors.heroFaint)
                      .copyWith(fontSize: 12, height: 1.35)),
            ],
            const SizedBox(height: 10),
            _hint(Icons.info_outline_rounded,
                'Tap a team to see player info & numbers'),
            const SizedBox(height: 4),
            _hint(
                Icons.lock_outline_rounded,
                widget.isOpen
                    ? 'This ticket closes after the match ends'
                    : 'This ticket closed after the match ended'),
            const SizedBox(height: 13),
            _segmented(),
          ]),
        ),
      );

  Widget _hint(IconData icon, String text) => Row(children: [
        Icon(icon, size: 12, color: AppColors.heroFaint),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text,
              style: AppText.small(AppColors.heroFaint)
                  .copyWith(fontSize: 10.5, height: 1.3)),
        ),
      ]);

  Widget _chip(String label, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
            color: AppColors.wash(c, 0.22),
            borderRadius: BorderRadius.circular(999)),
        child: Text(label,
            style: AppText.tag(c == AppColors.heroFaint ? AppColors.heroInk : c)
                .copyWith(fontSize: 8.5, letterSpacing: 0.7)),
      );

  /// Two tappable team groups either side of VS. Tapping either jumps to the
  /// Players tab, which is where the numbers live.
  Widget _matchUp() {
    if (_roster.isEmpty) return const SizedBox(height: 58);
    return Row(children: [
      Expanded(child: _teamGroup(_myTeam, mine: true)),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Text('VS',
            style: AppText.tag(AppColors.heroFaint)
                .copyWith(fontSize: 11, fontWeight: FontWeight.w900)),
      ),
      Expanded(child: _teamGroup(_theirTeam, mine: false)),
    ]);
  }

  Widget _teamGroup(List<Map<String, dynamic>> team, {required bool mine}) {
    return GestureDetector(
      onTap: () => setState(() => _tab = 1),
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment:
            mine ? CrossAxisAlignment.start : CrossAxisAlignment.end,
        children: [
          SizedBox(
            height: 38,
            child: Stack(children: [
              for (int i = 0; i < team.length && i < 2; i++)
                Positioned(
                  left: mine ? i * 27.0 : null,
                  right: mine ? null : i * 27.0,
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.hero, width: 2),
                    ),
                    child: AppAvatar(_initials(_nameOf(team[i])),
                        size: 34,
                        color: mine
                            ? AppColors.primary
                            : AppColors.heroInk.withValues(alpha: 0.18)),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 6),
          Text(_pairLabel(team, mine: mine),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.bodyStrong(AppColors.heroInk)
                  .copyWith(fontSize: 12.5, fontWeight: FontWeight.w800)),
          Text(mine ? 'Your team' : 'Opponents',
              style: AppText.tag(AppColors.heroFaint).copyWith(fontSize: 9)),
        ],
      ),
    );
  }

  Widget _segmented() => Container(
        height: 36,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(999)),
        child: Row(children: [
          _segBtn('Chat ${_messages.length}', 0),
          _segBtn('Players ${_roster.length}', 1),
        ]),
      );

  Widget _segBtn(String label, int i) {
    final on = _tab == i;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _tab = i),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: on ? AppColors.heroInk : Colors.transparent,
              borderRadius: BorderRadius.circular(999)),
          child: Text(label,
              style: AppText.bodyStrong(
                      on ? AppColors.hero : AppColors.heroFaint)
                  .copyWith(fontSize: 12.5)),
        ),
      ),
    );
  }

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

  // ── chat tab ────────────────────────────────────────────────────────────

  Widget _chatTab() {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.primary));
    }
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
      children: [
        _greetingCard(),
        if (_messages.isEmpty) ...[
          const SizedBox(height: 16),
          _emptyState(),
        ] else ...[
          const SizedBox(height: 14),
          for (final m in _messages) _bubble(m),
        ],
      ],
    );
  }

  /// Generated from the match every time it renders — so it always shows the
  /// current court and time, even if the host moved the booking.
  Widget _greetingCard() => Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.wash(AppColors.primary, 0.12),
              AppColors.surface,
            ],
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.wash(AppColors.primary, 0.35)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(11)),
              child: const Icon(Icons.confirmation_number_outlined,
                  size: 19, color: AppColors.primaryInk),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("You're in. Let's play.",
                        style: AppText.cardTitle().copyWith(fontSize: 15.5)),
                    Text('AUTOMATIC · PADEL RIVALS',
                        style: AppText.tag(AppColors.primary)
                            .copyWith(fontSize: 8.5, letterSpacing: 1)),
                  ]),
            ),
          ]),
          const SizedBox(height: 13),
          _greetLine(Icons.groups_outlined,
              'All four of you are in here — sort the ride, the balls, who pays the court.'),
          _greetLine(Icons.call_outlined,
              'Numbers are shared in Players — call or WhatsApp if someone goes quiet.'),
          _greetLine(Icons.lock_outline_rounded,
              'This ticket closes once the match ends — save any number you want to keep.'),
          const SizedBox(height: 13),
          AppButton("See everyone's number",
              full: true,
              height: 44,
              icon: Icons.contact_phone_outlined,
              onPressed: () => setState(() => _tab = 1)),
        ]),
      );

  Widget _greetLine(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 15, color: AppColors.primary),
          const SizedBox(width: 9),
          Expanded(
            child: Text(text,
                style: AppText.small(AppColors.inkSoft)
                    .copyWith(fontSize: 12, height: 1.45)),
          ),
        ]),
      );

  Widget _emptyState() => Column(children: [
        Text('No messages yet — break the ice.',
            style: AppText.small(AppColors.inkFaint).copyWith(fontSize: 12)),
        const SizedBox(height: 10),
        if (widget.isOpen)
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in _iceBreakers)
                GestureDetector(
                  onTap: () => _send(s),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
                    decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: AppColors.line)),
                    child: Text(s,
                        style: AppText.bodyStrong(AppColors.inkSoft)
                            .copyWith(fontSize: 12.5)),
                  ),
                ),
            ],
          ),
      ]);

  Widget _bubble(Map<String, dynamic> m) {
    final mine = m['sender_id'] == _uid;
    final sender = _roster.firstWhere(
      (p) => p['player_id'] == m['sender_id'],
      orElse: () => const <String, dynamic>{},
    );
    final name = sender.isEmpty ? 'Player' : _nameOf(sender);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment:
            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // In a group thread you have to know who is talking.
          if (!mine) ...[
            Row(children: [
              AppAvatar(_initials(name), size: 22, color: AppColors.gold),
              const SizedBox(width: 6),
              Text(_firstName(name),
                  style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 10)),
            ]),
            const SizedBox(height: 4),
          ],
          ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.76),
            // Long-press to report. Blocking here hides their messages but
            // leaves the roster alone — you are still playing this match.
            child: GestureDetector(
              onLongPress: mine
                  ? null
                  : () => ModerationSheet.show(
                        context,
                        userId: m['sender_id'] as String,
                        userName: name,
                        targetType: 'ticket_message',
                        targetId: m['id'] as String?,
                      ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
              decoration: BoxDecoration(
                color: mine ? AppColors.primary : AppColors.surface,
                border: mine ? null : Border.all(color: AppColors.lineSoft),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(mine ? 16 : 5),
                  bottomRight: Radius.circular(mine ? 5 : 16),
                ),
              ),
                child: Text(m['text'] as String? ?? '',
                    style: AppText.body(
                            mine ? AppColors.primaryInk : AppColors.ink)
                        .copyWith(fontSize: 13.5, height: 1.4)),
              ),
            ),
          ),
          const SizedBox(height: 3),
          Text(_fmtTime(m['sent_at'] as String?),
              style: AppText.tag(AppColors.inkFaint)
                  .copyWith(fontSize: 10, letterSpacing: 0)),
        ],
      ),
    );
  }

  // ── players tab ─────────────────────────────────────────────────────────

  Widget _playersTab() => ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 30),
        children: [
          Text('YOUR TEAM', style: AppText.kicker(AppColors.primary)),
          const SizedBox(height: 8),
          for (final p in _myTeam) _playerCard(p),
          const SizedBox(height: 18),
          Row(children: [
            Text('OPPONENTS', style: AppText.kicker()),
            const SizedBox(width: 7),
            Expanded(
              child: Text('keep for next time',
                  style: AppText.small(AppColors.inkFaint)
                      .copyWith(fontSize: 10.5)),
            ),
          ]),
          const SizedBox(height: 8),
          for (final p in _theirTeam) _playerCard(p),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
                color: AppColors.field,
                borderRadius: BorderRadius.circular(12)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.lock_outline_rounded,
                  size: 15, color: AppColors.inkFaint),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                    'Numbers are shared with these four players only, and '
                    'hidden again when the ticket closes.',
                    style: AppText.small(AppColors.inkFaint)
                        .copyWith(fontSize: 11.5, height: 1.4)),
              ),
            ]),
          ),
        ],
      );

  Widget _playerCard(Map<String, dynamic> p) {
    final me = p['is_me'] == true;
    final name = _nameOf(p);
    final phone = (p['phone'] as String?)?.trim() ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        child: Row(children: [
          AppAvatar(_initials(name),
              size: 38, color: me ? AppColors.primary : AppColors.gold, ring: 2),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(me ? 'You' : name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.bodyStrong().copyWith(fontSize: 14)),
                    ),
                    if (p['is_host'] == true) ...[
                      const SizedBox(width: 6),
                      const AppTag('HOST', color: AppColors.gold),
                    ],
                  ]),
                  const SizedBox(height: 2),
                  Text(
                      phone.isNotEmpty
                          ? phone
                          : (widget.isOpen
                              ? 'No number on file'
                              : 'Hidden — ticket closed'),
                      style: AppText.small(phone.isNotEmpty
                              ? AppColors.inkSoft
                              : AppColors.inkFaint)
                          .copyWith(
                              fontSize: 12.5,
                              fontFeatures: const [FontFeature.tabularFigures()])),
                ]),
          ),
          // Nothing to do on your own row — you have your own number.
          if (!me) ...[
            if (phone.isNotEmpty) ...[
              const SizedBox(width: 8),
              _roundBtn(Icons.copy_rounded, filled: false, onTap: () {
                Clipboard.setData(ClipboardData(text: phone));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    behavior: SnackBarBehavior.floating,
                    content: Text('Number copied')));
              }),
              const SizedBox(width: 7),
              _roundBtn(Icons.call_rounded, filled: true, onTap: () => _call(phone)),
            ],
            const SizedBox(width: 4),
            // Report/block the player themselves, not one message.
            GestureDetector(
              onTap: () => ModerationSheet.show(
                context,
                userId: p['player_id'] as String,
                userName: name,
                onBlocked: () => setState(() {}),
              ),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Icon(Icons.more_vert_rounded,
                    size: 18, color: AppColors.inkFaint),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _roundBtn(IconData icon,
          {required bool filled, required VoidCallback onTap}) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: filled ? AppColors.primary : Colors.transparent,
            shape: BoxShape.circle,
            border: filled ? null : Border.all(color: AppColors.line, width: 1.5),
          ),
          child: Icon(icon,
              size: 16,
              color: filled ? AppColors.primaryInk : AppColors.inkSoft),
        ),
      );

  Future<void> _call(String phone) async {
    final digits = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    final uri = Uri.parse('tel:$digits');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text("Couldn't open the dialler")));
    }
  }

  // ── composer ────────────────────────────────────────────────────────────

  Widget _composer() {
    final hasText = _ctrl.text.trim().isNotEmpty;
    return Container(
      decoration: const BoxDecoration(
          color: AppColors.bg,
          border: Border(top: BorderSide(color: AppColors.lineSoft))),
      padding: EdgeInsets.fromLTRB(
          14, 8, 14, 24 + MediaQuery.of(context).padding.bottom),
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
                hintText: 'Message all ${_roster.isEmpty ? 4 : _roster.length} players…',
                hintStyle:
                    AppText.body(AppColors.inkFaint).copyWith(fontSize: 14),
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
                size: 20,
                color: hasText ? AppColors.primaryInk : AppColors.inkFaint),
          ),
        ),
      ]),
    );
  }

  Widget _lockedNotice() => Container(
        width: double.infinity,
        decoration: const BoxDecoration(
            color: AppColors.bg,
            border: Border(top: BorderSide(color: AppColors.lineSoft))),
        padding: EdgeInsets.fromLTRB(
            18, 14, 18, 22 + MediaQuery.of(context).padding.bottom),
        child: Row(children: [
          const Icon(Icons.lock_outline_rounded,
              size: 16, color: AppColors.inkFaint),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
                'This ticket has closed. You can still read it, but numbers '
                'are hidden and nobody can post.',
                style: AppText.small(AppColors.inkFaint)
                    .copyWith(fontSize: 11.5, height: 1.4)),
          ),
        ]),
      );

  static String _fmtTime(String? iso) {
    final dt = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m ${dt.hour < 12 ? 'AM' : 'PM'}';
  }
}

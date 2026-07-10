import 'package:flutter/material.dart';
import '../../../backend/services/community_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_text.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/common.dart';
import '../tournaments/tournament_detail_screen.dart';
import 'message_organizer_screen.dart';

/// A member's view of an organizer's community — hero, Events / Feed / Members,
/// join/leave, RSVP, and a message-organizer entry. Opened as a full overlay.
class CommunityHubScreen extends StatefulWidget {
  final String communityId;
  const CommunityHubScreen({super.key, required this.communityId});

  @override
  State<CommunityHubScreen> createState() => _CommunityHubScreenState();
}

class _CommunityHubScreenState extends State<CommunityHubScreen> {
  Community? _c;
  List<CommunityEvent> _events = [];
  List<Announcement> _feed = [];
  List<MemberLite> _members = [];
  bool _loading = true, _busy = false;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = await CommunityService.fetchCommunity(widget.communityId);
    if (!mounted) return;
    if (c == null) {
      setState(() => _loading = false);
      return;
    }
    final results = await Future.wait([
      CommunityService.events(c.organizerId),
      CommunityService.feed(c.id),
      CommunityService.members(c.id),
    ]);
    if (!mounted) return;
    setState(() {
      _c = c;
      _events = results[0] as List<CommunityEvent>;
      _feed = results[1] as List<Announcement>;
      _members = results[2] as List<MemberLite>;
      _loading = false;
    });
  }

  Future<void> _toggleJoin() async {
    final c = _c;
    if (c == null || _busy) return;
    setState(() => _busy = true);
    final err = c.isMember
        ? await CommunityService.leave(c.id)
        : await CommunityService.join(c.id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      AppToast.show(context, err, kind: ToastKind.error);
      return;
    }
    AppToast.show(context, c.isMember ? 'Left ${c.name}' : 'Joined ${c.name}',
        kind: ToastKind.success);
    _load();
  }

  Future<void> _rsvp(Announcement a) async {
    final going = await CommunityService.toggleRsvp(a.id);
    if (!mounted) return;
    setState(() {
      _feed = _feed
          .map((x) => x.id == a.id
              ? Announcement(
                  id: x.id,
                  title: x.title,
                  body: x.body,
                  pinned: x.pinned,
                  iGoing: going,
                  going: x.going + (going ? 1 : -1),
                  createdAt: x.createdAt)
              : x)
          .toList();
    });
  }

  void _message() {
    final c = _c;
    if (c == null) return;
    if (!c.isMember) {
      AppToast.show(context, 'Join the community to message the organizer',
          kind: ToastKind.info);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MessageOrganizerScreen(
            communityId: c.id, organizerName: c.organizerName),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
            : _c == null
                ? _notFound()
                : Column(children: [
                    _topBar(),
                    Expanded(
                      child: RefreshIndicator(
                        color: AppColors.primary,
                        onRefresh: _load,
                        child: ListView(
                          padding: const EdgeInsets.only(bottom: 24),
                          children: [
                            _hero(_c!),
                            _tabs(),
                            _tabBody(),
                          ],
                        ),
                      ),
                    ),
                  ]),
      ),
    );
  }

  Widget _notFound() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.groups_2_outlined, size: 44, color: AppColors.inkFaint),
          const SizedBox(height: 12),
          Text('Community not found', style: AppText.bodyStrong()),
          const SizedBox(height: 12),
          AppButton('Back', variant: AppBtnVariant.outline,
              onPressed: () => Navigator.pop(context)),
        ]),
      );

  Widget _topBar() => Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 14, 4),
        child: Row(children: [
          IconButton(
              icon: const Icon(Icons.arrow_back_rounded, color: AppColors.ink),
              onPressed: () => Navigator.pop(context)),
          Expanded(child: Text('Community', style: AppText.barTitle())),
        ]),
      );

  Widget _hero(Community c) {
    return Container(
      margin: AppSpacing.screenH,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: AppRadius.cardR,
        gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.hero, AppColors.hero2]),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: AppColors.gold.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(14)),
            child: const Icon(Icons.groups_2_rounded, size: 26, color: AppColors.gold),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                    child: Text(c.name,
                        style: AppText.cardTitle(AppColors.heroInk),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis)),
                if (c.verified) ...[
                  const SizedBox(width: 5),
                  const Icon(Icons.verified_rounded, size: 15, color: AppColors.gold),
                ],
              ]),
              const SizedBox(height: 2),
              Text(
                  [
                    if (c.handle != null) '@${c.handle}',
                    if (c.city != null) c.city!,
                    '${c.memberCount} member${c.memberCount == 1 ? '' : 's'}',
                  ].join(' · '),
                  style: AppText.small(AppColors.heroFaint)),
            ]),
          ),
        ]),
        if (c.about != null) ...[
          const SizedBox(height: 12),
          Text(c.about!, style: AppText.body(AppColors.heroFaint)),
        ],
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: AppButton(
              c.isMember ? 'Joined' : 'Join community',
              icon: c.isMember ? Icons.check_rounded : Icons.add_rounded,
              variant: c.isMember ? AppBtnVariant.ghost : AppBtnVariant.solid,
              onPressed: _busy ? null : _toggleJoin,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: AppButton('Message',
                icon: Icons.chat_bubble_outline_rounded,
                variant: AppBtnVariant.accent,
                onPressed: _message),
          ),
        ]),
      ]),
    );
  }

  Widget _tabs() {
    Widget seg(int i, String label) {
      final on = _tab == i;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _tab = i),
          child: Container(
            margin: const EdgeInsets.all(3),
            padding: const EdgeInsets.symmetric(vertical: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: on ? AppColors.surface : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
                boxShadow: on ? kCardShadow : null),
            child: Text(label,
                style: on
                    ? AppText.bodyStrong(AppColors.ink)
                    : AppText.body(AppColors.inkSoft)),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(AppSpacing.screen, 16, AppSpacing.screen, 6),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
          color: AppColors.field, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [seg(0, 'Events'), seg(1, 'Feed'), seg(2, 'Members')]),
    );
  }

  Widget _tabBody() {
    switch (_tab) {
      case 1:
        return _feedTab();
      case 2:
        return _membersTab();
      default:
        return _eventsTab();
    }
  }

  Widget _pad(Widget child) =>
      Padding(padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 8, AppSpacing.screen, 0), child: child);

  Widget _empty(IconData icon, String text) => _pad(Padding(
        padding: const EdgeInsets.symmetric(vertical: 30),
        child: Center(
          child: Column(children: [
            Icon(icon, size: 38, color: AppColors.inkFaint),
            const SizedBox(height: 10),
            Text(text, style: AppText.small(), textAlign: TextAlign.center),
          ]),
        ),
      ));

  Widget _eventsTab() {
    if (_events.isEmpty) {
      return _empty(Icons.emoji_events_outlined, 'No events yet. Check back soon.');
    }
    return Column(
      children: _events
          .map((e) => _pad(Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: AppCard(
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => TournamentDetailScreen(tournamentId: e.id))),
                  child: Row(children: [
                    Container(
                      width: 42,
                      height: 42,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          color: AppColors.gold.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(11)),
                      child: const Icon(Icons.emoji_events_outlined,
                          size: 21, color: AppColors.gold),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(e.name,
                                style: AppText.bodyStrong(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 3),
                            Text(_eventMeta(e), style: AppText.small()),
                          ]),
                    ),
                    AppTag(_statusLabel(e.status),
                        color: e.status == 'open' ? AppColors.success : AppColors.inkSoft),
                  ]),
                ),
              )))
          .toList(),
    );
  }

  Widget _feedTab() {
    if (_feed.isEmpty) {
      return _empty(Icons.campaign_outlined, 'No announcements yet.');
    }
    return Column(
      children: _feed
          .map((a) => _pad(Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: AppCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      if (a.pinned) ...[
                        const Icon(Icons.push_pin_rounded, size: 14, color: AppColors.gold),
                        const SizedBox(width: 5),
                      ],
                      Expanded(child: Text(a.title, style: AppText.bodyStrong())),
                    ]),
                    if (a.body != null) ...[
                      const SizedBox(height: 5),
                      Text(a.body!, style: AppText.body(AppColors.inkSoft)),
                    ],
                    const SizedBox(height: 10),
                    Row(children: [
                      GestureDetector(
                        onTap: () => _rsvp(a),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: a.iGoing
                                ? AppColors.accent
                                : AppColors.field,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(a.iGoing ? Icons.check_rounded : Icons.add_rounded,
                                size: 15,
                                color: a.iGoing ? AppColors.accentInk : AppColors.inkSoft),
                            const SizedBox(width: 5),
                            Text(a.iGoing ? 'Going' : 'RSVP',
                                style: AppText.small(
                                    a.iGoing ? AppColors.accentInk : AppColors.inkSoft)),
                          ]),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text('${a.going} going', style: AppText.small()),
                      const Spacer(),
                      Text(_ago(a.createdAt), style: AppText.small(AppColors.inkFaint)),
                    ]),
                  ]),
                ),
              )))
          .toList(),
    );
  }

  Widget _membersTab() {
    final c = _c!;
    return Column(children: [
      _pad(Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: AppCard(
          color: AppColors.surfaceAlt,
          child: Row(children: [
            AppAvatar(_initials(c.organizerName), size: 42, color: AppColors.gold),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c.organizerName, style: AppText.bodyStrong()),
                Text('Organizer', style: AppText.small(AppColors.gold)),
              ]),
            ),
            AppButton('Message',
                variant: AppBtnVariant.ghost, height: 34, onPressed: _message),
          ]),
        ),
      )),
      if (_members.isEmpty)
        _empty(Icons.groups_outlined, 'No members yet. Be the first to join!')
      else
        _pad(Wrap(
          spacing: 10,
          runSpacing: 12,
          children: _members
              .map((m) => SizedBox(
                    width: 64,
                    child: Column(children: [
                      AppAvatar(m.initials, size: 46, color: AppColors.accent),
                      const SizedBox(height: 5),
                      Text(m.name.split(' ').first,
                          style: AppText.small(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ]),
                  ))
              .toList(),
        )),
    ]);
  }

  // helpers
  String _eventMeta(CommunityEvent e) {
    final parts = <String>[];
    if (e.startDate != null) {
      final d = DateTime.tryParse(e.startDate!);
      if (d != null) {
        const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
        parts.add('${m[d.month - 1]} ${d.day}');
      }
    }
    if ((e.entryFee ?? 0) > 0) parts.add('EGP ${e.entryFee}');
    return parts.isEmpty ? 'Tournament' : parts.join(' · ');
  }

  static String _statusLabel(String s) =>
      s.isEmpty ? 'Open' : s[0].toUpperCase() + s.substring(1);

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  static String _ago(DateTime? t) {
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    if (d.inDays < 7) return '${d.inDays}d';
    return '${(d.inDays / 7).floor()}w';
  }
}

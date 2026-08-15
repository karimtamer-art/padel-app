import 'dart:async';
import 'package:flutter/material.dart';
import '../../../backend/services/community_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_text.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/common.dart';
import '../tournaments/tournament_detail_screen.dart';
import '../chat/dm_chat_screen.dart';
import 'message_organizer_screen.dart';
import '../../../backend/models/ranking_scale.dart';

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
  List<Map<String, dynamic>> _channels = [];
  Map<String, int> _channelUnread = {}; // channelId → unread count (badges)
  bool _loading = true, _busy = false;
  int _tab = 0;
  String _memberQuery = '';
  final _memberSearch = TextEditingController();

  // Tab order: Events(0) · Chat(1) · Feed(2) · Members(3).
  static const _chatTabIndex = 1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _memberSearch.dispose();
    super.dispose();
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
      CommunityService.channelList(c.id),
      CommunityService.channelUnreads(c.id),
    ]);
    if (!mounted) return;
    setState(() {
      _c = c;
      _events = results[0] as List<CommunityEvent>;
      _feed = results[1] as List<Announcement>;
      _members = results[2] as List<MemberLite>;
      _channels = results[3] as List<Map<String, dynamic>>;
      _channelUnread = results[4] as Map<String, int>;
      _loading = false;
    });
  }

  Future<void> _refreshChannels() async {
    final c = _c;
    if (c == null) return;
    final results = await Future.wait([
      CommunityService.channelList(c.id),
      CommunityService.channelUnreads(c.id),
    ]);
    if (mounted) {
      setState(() {
        _channels = results[0] as List<Map<String, dynamic>>;
        _channelUnread = results[1] as Map<String, int>;
      });
    }
  }

  Future<void> _openChannel(Map<String, dynamic> ch) async {
    final c = _c;
    if (c == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CommunityChannelScreen(
          communityId: c.id,
          channelId: ch['id'] as String,
          channelName: ch['name'] as String? ?? 'channel',
          kind: ch['kind'] as String? ?? 'community',
          state: ch['state'] as String? ?? 'active',
          post: ch['post'] as String? ?? 'all',
          canPost: ch['can_post'] == true,
          organizerId: c.organizerId,
        ),
      ),
    );
    // They've seen this channel — clear its badge, then refresh previews +
    // per-channel unread counts (which also shrinks the Home card total).
    await CommunityService.markChannelRead(ch['id'] as String);
    _refreshChannels();
  }

  Future<void> _toggleJoin() async {
    final c = _c;
    if (c == null || _busy) return;
    setState(() => _busy = true);
    final result = c.isMember
        ? await CommunityService.leave(c.id)
        : await CommunityService.join(c.id);
    if (!mounted) return;
    setState(() => _busy = false);
    // Approval-required community: join() files a request instead of joining.
    if (!c.isMember && result == 'requested') {
      AppToast.show(context, 'Request sent — the organizer will approve you',
          kind: ToastKind.info);
      return;
    }
    if (result != null) {
      AppToast.show(context, result, kind: ToastKind.error);
      return;
    }
    AppToast.show(context, c.isMember ? 'Left ${c.name}' : 'Joined ${c.name}',
        kind: ToastKind.success);
    _load();
  }

  Future<void> _requestMatch() async {
    final c = _c;
    if (c == null) return;
    if (!c.isMember) {
      AppToast.show(context, 'Join the community to request a match',
          kind: ToastKind.info);
      return;
    }
    final noteC = TextEditingController();
    final send = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          decoration: const BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
          child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Request a match', style: AppText.cardTitle().copyWith(fontSize: 17)),
            const SizedBox(height: 6),
            Text('Tell ${c.organizerName.split(' ').first} what you\'re looking for — '
                'level, timing, or a partner.',
                style: AppText.small()),
            const SizedBox(height: 14),
            TextField(
              controller: noteC,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: 'e.g. Looking for a Sat-morning game around level 3.5',
                filled: true,
                fillColor: AppColors.field,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 16),
            AppButton('Send request', full: true, height: 50,
                onPressed: () => Navigator.pop(ctx, true)),
          ]),
        ),
      ),
    );
    final note = noteC.text.trim();
    noteC.dispose();
    if (send != true || !mounted) return;
    final err = await CommunityService.createMatchRequest(c.id, note);
    if (!mounted) return;
    AppToast.show(context, err ?? 'Match request sent to the organizer',
        kind: err == null ? ToastKind.success : ToastKind.error);
  }

  Future<void> _rsvp(Announcement a) async {
    final going = await CommunityService.toggleRsvp(a.id);
    if (!mounted) return;
    setState(() {
      _feed = _feed
          .map((x) => x.id == a.id
              ? x.copyWith(iGoing: going, going: x.going + (going ? 1 : -1))
              : x)
          .toList();
    });
  }

  Future<void> _like(Announcement a) async {
    final liked = await CommunityService.toggleLike(a.id);
    if (!mounted) return;
    setState(() {
      _feed = _feed
          .map((x) => x.id == a.id
              ? x.copyWith(iLiked: liked, likes: x.likes + (liked ? 1 : -1))
              : x)
          .toList();
    });
  }

  Future<void> _openComments(Announcement a) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CommentsSheet(
          announcementId: a.id, canPost: _c?.isMember ?? false),
    );
    // Refresh so the comment count reflects any new posts.
    final c = _c;
    if (c == null) return;
    final feed = await CommunityService.feed(c.id);
    if (mounted) setState(() => _feed = feed);
  }

  Widget _iconStat(IconData icon, String label, Color color, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 5),
          Text(label, style: AppText.small(color)),
        ]),
      );

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
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _c == null
              ? SafeArea(child: _notFound())
              : Column(children: [
                  // Full-bleed green header (extends under the status bar).
                  _hero(_c!),
                  _tabs(),
                  Expanded(
                    child: RefreshIndicator(
                      color: AppColors.primary,
                      onRefresh: _load,
                      child: ListView(
                        padding: const EdgeInsets.only(bottom: 24),
                        children: [_tabBody()],
                      ),
                    ),
                  ),
                ]),
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

  Widget _glassBtn(IconData icon, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: 0.22)),
          child: Icon(icon, size: 19, color: AppColors.heroInk),
        ),
      );

  Widget _memberStack() {
    final show = _members.take(5).toList();
    if (show.isEmpty) return const SizedBox.shrink();
    const d = 30.0, step = 20.0;
    return SizedBox(
      width: d + (show.length - 1) * step,
      height: d,
      child: Stack(children: [
        for (int i = 0; i < show.length; i++)
          Positioned(
            left: i * step,
            child: Container(
              width: d,
              height: d,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.field,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.hero, width: 2),
              ),
              child: Text(show[i].initials,
                  style: AppText.small(AppColors.inkSoft)
                      .copyWith(fontSize: 10, fontWeight: FontWeight.w800)),
            ),
          ),
      ]),
    );
  }

  Widget _heroButton({
    required String label,
    required IconData icon,
    required VoidCallback? onTap,
    required bool cream,
  }) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          height: 50,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: cream ? AppColors.surface : Colors.transparent,
            borderRadius: AppRadius.btnR,
            border: cream ? null : Border.all(color: AppColors.primary, width: 1.5),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 18, color: cream ? AppColors.ink : AppColors.primary),
            const SizedBox(width: 8),
            Text(label,
                style: AppText.bodyStrong(cream ? AppColors.ink : AppColors.primary)
                    .copyWith(fontSize: 14.5)),
          ]),
        ),
      );

  Widget _hero(Community c) {
    final top = MediaQuery.of(context).padding.top;
    final loc = [
      if (c.city != null && c.city!.isNotEmpty) c.city!,
      if (c.handle != null) '@${c.handle}',
    ].join(' · ');
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.hero, AppColors.hero2]),
      ),
      child: Stack(children: [
        // Warm gold splash across the top of the green.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(1.05, -0.85),
                radius: 1.7,
                colors: [
                  AppColors.gold.withValues(alpha: 0.36),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.72],
              ),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(18, top + 10, 18, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Back button.
        Row(children: [
          _glassBtn(Icons.arrow_back_rounded, () => Navigator.pop(context)),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Container(
            width: 56,
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: AppColors.gold,
                borderRadius: BorderRadius.circular(15)),
            child: const Icon(Icons.groups_2_rounded, size: 28, color: Colors.white),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                    child: Text(c.name,
                        style: AppText.cardTitle(AppColors.heroInk).copyWith(fontSize: 21),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 6),
                const Icon(Icons.verified_rounded, size: 17, color: AppColors.gold),
              ]),
              if (loc.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(children: [
                  const Icon(Icons.location_on_outlined, size: 13, color: AppColors.heroFaint),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(loc,
                        style: AppText.small(AppColors.heroFaint),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                ]),
              ],
            ]),
          ),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          _memberStack(),
          if (_members.isNotEmpty) const SizedBox(width: 11),
          Text('${c.memberCount} member${c.memberCount == 1 ? '' : 's'}',
              style: AppText.bodyStrong(AppColors.heroInk).copyWith(fontSize: 13.5)),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: _heroButton(
              label: c.isMember
                  ? 'Joined'
                  : (c.approvalRequired ? 'Request to join' : 'Join community'),
              icon: c.isMember ? Icons.check_rounded : Icons.add_rounded,
              cream: true,
              onTap: _busy ? null : _toggleJoin,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _heroButton(
              label: 'Message',
              icon: Icons.chat_bubble_outline_rounded,
              cream: false,
              onTap: _message,
            ),
          ),
        ]),
      ]),
        ),
      ]),
    );
  }

  Widget _tabs() {
    Widget seg(int i, String label) {
      final on = _tab == i;
      return Expanded(
        child: GestureDetector(
          onTap: () {
            setState(() => _tab = i);
            // Refresh per-channel unread badges; each channel clears when opened.
            if (i == _chatTabIndex) _refreshChannels();
          },
          child: Container(
            margin: const EdgeInsets.all(3),
            padding: const EdgeInsets.symmetric(vertical: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: on ? AppColors.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
                boxShadow: on ? kCardShadow : null),
            child: Text(label,
                style: on
                    ? AppText.bodyStrong(AppColors.primaryInk)
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
      child: Row(children: [
        seg(0, 'Events'),
        seg(1, 'Chat'),
        seg(2, 'Feed'),
        seg(3, 'Members'),
      ]),
    );
  }

  Widget _tabBody() {
    switch (_tab) {
      case 1:
        return _channelsTab();
      case 2:
        return _feedTab();
      case 3:
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
    final c = _c!;
    return Column(children: [
      if (c.isMember)
        _pad(Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: AppButton('Request a match',
              icon: Icons.sports_tennis_rounded,
              full: true,
              variant: AppBtnVariant.outline,
              onPressed: _requestMatch),
        )),
      if (_events.isEmpty)
        _empty(Icons.emoji_events_outlined, 'No events yet. Check back soon.')
      else
        ..._events
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
              ))),
    ]);
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
                    if (a.imageUrl != null) ...[
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.network(
                          a.imageUrl!,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                          loadingBuilder: (ctx, child, prog) => prog == null
                              ? child
                              : Container(
                                  height: 180,
                                  alignment: Alignment.center,
                                  color: AppColors.field,
                                  child: const CircularProgressIndicator(strokeWidth: 2),
                                ),
                        ),
                      ),
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
                    const Divider(height: 18, color: AppColors.lineSoft),
                    Row(children: [
                      _iconStat(
                          a.iLiked ? Icons.star_rounded : Icons.star_border_rounded,
                          '${a.likes}',
                          a.iLiked ? AppColors.gold : AppColors.inkSoft,
                          () => _like(a)),
                      const SizedBox(width: 18),
                      _iconStat(Icons.chat_bubble_outline_rounded, '${a.comments}',
                          AppColors.inkSoft, () => _openComments(a)),
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
        _membersDirectory(),
    ]);
  }

  Widget _membersDirectory() {
    final q = _memberQuery.trim().toLowerCase();
    final found = q.isEmpty
        ? _members
        : _members.where((m) => m.name.toLowerCase().contains(q)).toList();
    final total = _members.length;
    final countText = q.isEmpty
        ? '$total MEMBER${total == 1 ? '' : 'S'}'
        : '${found.length} OF $total MEMBERS';

    return _pad(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // search bar
      Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.field,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: AppColors.line),
        ),
        child: Row(children: [
          const Icon(Icons.search_rounded, size: 16, color: AppColors.inkFaint),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _memberSearch,
              onChanged: (v) => setState(() => _memberQuery = v),
              style: AppText.body().copyWith(fontSize: 13),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: 'Search members',
                hintStyle: AppText.body(AppColors.inkFaint).copyWith(fontSize: 13),
              ),
            ),
          ),
          if (_memberQuery.isNotEmpty)
            GestureDetector(
              onTap: () {
                _memberSearch.clear();
                setState(() => _memberQuery = '');
              },
              child: const Icon(Icons.close_rounded, size: 15, color: AppColors.inkFaint),
            ),
        ]),
      ),
      const SizedBox(height: 12),
      Text(countText,
          style: AppText.tag(AppColors.inkFaint)
              .copyWith(fontSize: 11, letterSpacing: 1)),
      const SizedBox(height: 10),
      if (found.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: Text('No member matches “$_memberQuery”.',
                style: AppText.small(AppColors.inkFaint)),
          ),
        )
      else
        GridView.count(
          crossAxisCount: 4,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.72,
          children: [for (final m in found) _memberCell(m)],
        ),
      const SizedBox(height: 90),
    ]));
  }

  Widget _memberCell(MemberLite m) {
    final tint = m.tier != null ? AppColors.tier(m.tier!) : AppColors.accent;
    return GestureDetector(
      onTap: () => _openMemberProfile(m),
      behavior: HitTestBehavior.opaque,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        AppAvatar(m.initials, size: 48, color: tint, imageUrl: m.avatarUrl),
        const SizedBox(height: 6),
        Text(m.name.split(' ').first,
            style: AppText.small(AppColors.ink)
                .copyWith(fontSize: 10.5, fontWeight: FontWeight.w700),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        if (m.tier != null)
          Text(m.tier!,
              style: AppText.small(AppColors.inkFaint).copyWith(fontSize: 10.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
      ]),
    );
  }

  void _openMemberProfile(MemberLite m) {
    showDialog<void>(
      context: context,
      barrierColor: const Color(0x70120C06),
      builder: (_) => _MemberProfileSheet(
        communityId: widget.communityId,
        member: m,
        communityName: _c?.name ?? 'the community',
        onMessage: () {
          Navigator.of(context).pop(); // close popup
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => DMChatScreen(
              otherId: m.id,
              name: m.name,
              initials: m.initials,
              avatarUrl: m.avatarUrl,
            ),
          ));
        },
      ),
    );
  }

  // ── Chat tab: channel list ──────────────────────────────────────
  Widget _channelsTab() {
    final community =
        _channels.where((c) => (c['kind'] ?? 'community') == 'community').toList();
    final events =
        _channels.where((c) => (c['kind'] ?? 'community') != 'community').toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _pad(Text(
          'Talk to the community. Events get their own channel automatically — it closes when the event ends.',
          style: AppText.small(AppColors.inkSoft).copyWith(height: 1.4))),
      const SizedBox(height: 12),
      _pad(_groupLabel('Community channels')),
      const SizedBox(height: 8),
      if (community.isEmpty)
        _empty(Icons.forum_outlined, 'No channels yet.')
      else
        ...community.map((ch) => _pad(Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: _channelRow(ch),
            ))),
      if (events.isNotEmpty) ...[
        const SizedBox(height: 6),
        _pad(_groupLabel('Event channels')),
        const SizedBox(height: 8),
        ...events.map((ch) => _pad(Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: _channelRow(ch),
            ))),
      ],
    ]);
  }

  Widget _groupLabel(String s) => Text(s.toUpperCase(),
      style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 10, letterSpacing: 1.2));

  Widget _channelRow(Map<String, dynamic> ch) {
    final name = ch['name'] as String? ?? 'channel';
    final kind = ch['kind'] as String? ?? 'community';
    final isEvent = kind != 'community';
    final state = ch['state'] as String? ?? 'active';
    final archived = state == 'archived';
    final custom = ch['is_custom'] == true;
    final going = (ch['going'] as num?)?.toInt() ?? 0;
    final preview = (ch['preview'] as String?)?.trim();
    final unread = _channelUnread[ch['id']] ?? 0;
    final hasUnread = unread > 0;

    final iconColor = kind == 'match' ? AppColors.primary : AppColors.gold;
    final leading = isEvent
        ? Icon(kind == 'match' ? Icons.schedule_rounded : Icons.emoji_events_rounded,
            size: 17, color: iconColor)
        : Text('#', style: AppText.bodyStrong(AppColors.inkSoft).copyWith(fontSize: 17));
    final leadingBg = isEvent ? iconColor.withValues(alpha: 0.14) : AppColors.field;

    final sub = (preview != null && preview.isNotEmpty)
        ? preview
        : (isEvent && going > 0 ? '$going going' : 'No messages yet');

    return Opacity(
      opacity: archived ? 0.6 : 1,
      child: AppCard(
        onTap: () => _openChannel(ch),
        padding: const EdgeInsets.all(11),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: leadingBg, borderRadius: BorderRadius.circular(10)),
            child: leading,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                    child: Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.bodyStrong().copyWith(fontSize: 14))),
                if (isEvent && state == 'active') ...[
                  const SizedBox(width: 6),
                  const AppTag('Live', color: AppColors.success),
                ] else if (isEvent && archived) ...[
                  const SizedBox(width: 6),
                  const AppTag('Archived', color: AppColors.inkFaint),
                ] else if (custom) ...[
                  const SizedBox(width: 6),
                  const AppTag('New', color: AppColors.primary),
                ],
              ]),
              const SizedBox(height: 2),
              Text(sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.small(
                          hasUnread ? AppColors.inkSoft : AppColors.inkFaint)
                      .copyWith(
                          fontSize: 11.5,
                          fontWeight:
                              hasUnread ? FontWeight.w700 : FontWeight.w500)),
            ]),
          ),
          const SizedBox(width: 6),
          if (hasUnread)
            Container(
              constraints: const BoxConstraints(minWidth: 20),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: AppColors.danger,
                  borderRadius: BorderRadius.circular(10)),
              child: Text(unread > 99 ? '99+' : '$unread',
                  style: AppText.tag(Colors.white)
                      .copyWith(fontSize: 10.5, fontWeight: FontWeight.w800)),
            )
          else
            const Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.inkFaint),
        ]),
      ),
    );
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

// ── Comments on an announcement ─────────────────────────────────────────────
class _CommentsSheet extends StatefulWidget {
  final String announcementId;
  final bool canPost;
  const _CommentsSheet({required this.announcementId, required this.canPost});
  @override
  State<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<_CommentsSheet> {
  final _input = TextEditingController();
  List<CommentLite> _comments = [];
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final rows = await CommunityService.comments(widget.announcementId);
    if (mounted) setState(() { _comments = rows; _loading = false; });
  }

  Future<void> _send() async {
    final body = _input.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    final err = await CommunityService.addComment(widget.announcementId, body);
    if (!mounted) return;
    setState(() => _sending = false);
    if (err != null) {
      AppToast.show(context, err, kind: ToastKind.error);
      return;
    }
    _input.clear();
    _load();
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

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8),
        decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 40, height: 4,
              margin: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                  color: AppColors.line, borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 10),
            child: Row(children: [
              Text('Comments', style: AppText.cardTitle().copyWith(fontSize: 17)),
              const Spacer(),
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: const Icon(Icons.close_rounded, color: AppColors.inkSoft),
              ),
            ]),
          ),
          const Divider(height: 1, color: AppColors.lineSoft),
          Flexible(
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.all(28),
                    child: Center(child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.primary)))
                : _comments.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(28),
                        child: Text('No comments yet. Be the first.',
                            style: AppText.small(), textAlign: TextAlign.center))
                    : ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.all(16),
                        itemCount: _comments.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 14),
                        itemBuilder: (_, i) {
                          final c = _comments[i];
                          return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            AppAvatar(_initials(c.name), size: 34,
                                imageUrl: c.avatarUrl),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Row(children: [
                                  Text(c.name, style: AppText.bodyStrong().copyWith(fontSize: 13)),
                                  const SizedBox(width: 6),
                                  Text(_ago(c.at), style: AppText.small(AppColors.inkFaint)),
                                ]),
                                const SizedBox(height: 2),
                                Text(c.body, style: AppText.body(AppColors.inkSoft)),
                              ]),
                            ),
                          ]);
                        },
                      ),
          ),
          if (widget.canPost) ...[
            const Divider(height: 1, color: AppColors.lineSoft),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: 'Add a comment…',
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
                    width: 44, height: 44,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                        color: AppColors.primary, shape: BoxShape.circle),
                    child: const Icon(Icons.arrow_upward_rounded,
                        color: AppColors.primaryInk, size: 20),
                  ),
                ),
              ]),
            ),
          ],
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

// ── A single community channel's chat ────────────────────────────────────────
class CommunityChannelScreen extends StatefulWidget {
  final String communityId, channelId, channelName;
  final String kind; // community | tournament | match
  final String state; // active | grace | archived
  final String post; // all | registered | org
  final bool canPost; // server-computed for this viewer
  final String? organizerId; // to flag the organizer's messages
  const CommunityChannelScreen({
    super.key,
    required this.communityId,
    required this.channelId,
    required this.channelName,
    this.kind = 'community',
    this.state = 'active',
    this.post = 'all',
    required this.canPost,
    this.organizerId,
  });

  bool get isEvent => kind != 'community';
  bool get archived => state == 'archived';

  @override
  State<CommunityChannelScreen> createState() => _CommunityChannelScreenState();
}

class _CommunityChannelScreenState extends State<CommunityChannelScreen> {
  List<Map<String, dynamic>> _msgs = [];
  bool _loading = true, _sending = false;
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  // sender_id → display name, seeded by _load and reused by the live stream.
  final Map<String, String> _names = {};
  StreamSubscription<List<Map<String, dynamic>>>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _subscribe();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final m = await CommunityService.channelMessages(widget.channelId);
    if (!mounted) return;
    for (final msg in m) {
      final sid = msg['sender_id'] as String?;
      if (sid != null) _names[sid] = msg['senderName'] as String? ?? 'Player';
    }
    setState(() {
      _msgs = m;
      _loading = false;
    });
    _scrollToBottom(force: true);
  }

  // Live updates: new posts (from anyone) arrive here without a manual refresh.
  // Requires community_chat in the supabase_realtime publication; if it isn't,
  // the stream simply never emits and send()'s _load() keeps things working.
  void _subscribe() {
    _sub = CommunityService.channelStream(widget.channelId).listen((rows) async {
      final decorated =
          await CommunityService.decorateChannelRows(rows, _names);
      if (!mounted) return;
      final grew = decorated.length > _msgs.length;
      setState(() {
        _msgs = decorated;
        _loading = false;
      });
      if (grew) _scrollToBottom();
    });
  }

  /// Jump to the newest message. [force] always scrolls; otherwise only when the
  /// user is already near the bottom (don't yank them out of reading history).
  void _scrollToBottom({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if (force || _scroll.position.pixels >= max - 120) _scroll.jumpTo(max);
    });
  }

  Future<void> _send() async {
    final body = _ctrl.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    final err = await CommunityService.sendChannelMessage(
        widget.communityId, widget.channelId, body);
    if (!mounted) return;
    setState(() => _sending = false);
    if (err != null) {
      AppToast.show(context, err, kind: ToastKind.error);
      return;
    }
    _ctrl.clear();
    // The live stream echoes the new row back; _load() is a fallback for when
    // realtime isn't enabled yet so the sender still sees their own message.
    await _load();
  }

  static String _time(dynamic iso) {
    final dt = DateTime.tryParse(iso as String? ?? '')?.toLocal();
    if (dt == null) return '';
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m ${dt.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(children: [
        // Header.
        Container(
          padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 4),
          decoration: const BoxDecoration(
              color: AppColors.surface,
              border: Border(bottom: BorderSide(color: AppColors.lineSoft))),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 16, 12),
            child: Row(children: [
              IconButton(
                  icon: const Icon(Icons.arrow_back_rounded, color: AppColors.ink),
                  onPressed: () => Navigator.pop(context)),
              Builder(builder: (_) {
                final iconColor =
                    widget.kind == 'match' ? AppColors.primary : AppColors.gold;
                return Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: widget.isEvent
                          ? iconColor.withValues(alpha: 0.14)
                          : AppColors.field,
                      borderRadius: BorderRadius.circular(9)),
                  child: widget.isEvent
                      ? Icon(
                          widget.kind == 'match'
                              ? Icons.schedule_rounded
                              : Icons.emoji_events_rounded,
                          size: 16,
                          color: iconColor)
                      : Text('#',
                          style: AppText.bodyStrong(AppColors.inkSoft)
                              .copyWith(fontSize: 16)),
                );
              }),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(
                      child: Text(widget.channelName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.cardTitle().copyWith(fontSize: 16)),
                    ),
                    if (widget.isEvent && widget.state == 'active') ...[
                      const SizedBox(width: 6),
                      const AppTag('Live', color: AppColors.success),
                    ] else if (widget.archived) ...[
                      const SizedBox(width: 6),
                      const AppTag('Archived', color: AppColors.inkFaint),
                    ],
                  ]),
                  Text(
                      !widget.isEvent
                          ? 'Community channel'
                          : widget.state == 'active'
                              ? 'Event channel · live'
                              : widget.state == 'grace'
                                  ? 'Closing soon'
                                  : 'Archived',
                      style: AppText.small(AppColors.inkFaint).copyWith(fontSize: 11)),
                ]),
              ),
            ]),
          ),
        ),
        // Thread — subtle accent tint anchored top-right.
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0.7, -1),
                radius: 0.9,
                colors: [
                  (widget.kind == 'match' ? AppColors.primary : AppColors.gold)
                      .withValues(alpha: 0.05),
                  Colors.transparent,
                ],
              ),
            ),
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
                : ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                    children: [
                      if (_eventBanner() != null) ...[_eventBanner()!, const SizedBox(height: 12)],
                      if (_msgs.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Center(
                            child: Text('No messages yet. Say hello!',
                                style: AppText.small(), textAlign: TextAlign.center),
                          ),
                        )
                      else
                        for (var i = 0; i < _msgs.length; i++) _groupedBubble(i),
                    ],
                  ),
          ),
        ),
        // Composer.
        _composer(),
      ]),
    );
  }

  static const _avatarPalette = [
    Color(0xFF3F7896), Color(0xFFB07E22), Color(0xFF2F6B57),
    Color(0xFF8A4B2B), Color(0xFF6E5AA0), Color(0xFF907A52),
  ];
  Color _avatarColor(String seed) =>
      _avatarPalette[seed.hashCode.abs() % _avatarPalette.length];

  String _msgInitials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  // "Yara A." — first name + last initial.
  String _msgName(String full) {
    final parts = full.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return 'Player';
    if (parts.length == 1) return parts.first;
    return '${parts.first} ${parts.last[0]}.';
  }

  bool _sameAuthor(Map<String, dynamic>? a, Map<String, dynamic>? b) =>
      a != null && b != null &&
      (a['fromMe'] == true) == (b['fromMe'] == true) &&
      a['sender_id'] == b['sender_id'];

  // Grouped messaging bubble: consecutive messages from one author tuck together
  // — name once (first bubble), avatar + timestamp once (last bubble), inner
  // corners tightened.
  Widget _groupedBubble(int i) {
    final m = _msgs[i];
    final me = m['fromMe'] == true;
    final org = !me && widget.organizerId != null && m['sender_id'] == widget.organizerId;
    final first = !_sameAuthor(i > 0 ? _msgs[i - 1] : null, m);
    final last = !_sameAuthor(i + 1 < _msgs.length ? _msgs[i + 1] : null, m);
    final full = m['senderName'] as String? ?? 'Player';
    final body = m['body'] as String? ?? '';
    final time = _time(m['created_at']);

    const r = Radius.circular(18);
    const tight = Radius.circular(6);
    // Outer edge always round; the side nearest the avatar tightens mid-run.
    final radius = me
        ? BorderRadius.only(
            topLeft: r, bottomLeft: r,
            topRight: first ? r : tight, bottomRight: last ? r : tight)
        : BorderRadius.only(
            topRight: r, bottomRight: r,
            topLeft: first ? r : tight, bottomLeft: last ? r : tight);

    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      decoration: BoxDecoration(
        color: me
            ? AppColors.primary
            : (org ? AppColors.gold.withValues(alpha: 0.12) : AppColors.surface),
        borderRadius: radius,
        border: me
            ? null
            : Border.all(color: org ? AppColors.gold.withValues(alpha: 0.30) : AppColors.lineSoft),
        boxShadow: me
            ? null
            : const [BoxShadow(color: Color.fromRGBO(40, 30, 15, 0.05), blurRadius: 2, offset: Offset(0, 1))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(body,
            style: AppText.body(me ? AppColors.primaryInk : AppColors.ink)
                .copyWith(fontSize: 14, height: 1.35)),
        if (last) ...[
          const SizedBox(height: 2),
          Text(time,
              style: AppText.small(me ? AppColors.primaryInk.withValues(alpha: 0.7) : AppColors.inkFaint)
                  .copyWith(fontSize: 10)),
        ],
      ]),
    );

    // Fixed 30px slot keeps the column aligned; avatar only on the last bubble.
    final avatarSlot = SizedBox(
      width: 30,
      child: last
          ? AppAvatar(_msgInitials(full), size: 30, ring: 1.5,
              color: me ? AppColors.gold : _avatarColor(m['sender_id'] as String? ?? full))
          : null,
    );

    final column = Column(
      crossAxisAlignment: me ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (first)
          Padding(
            padding: const EdgeInsets.only(left: 4, right: 4, bottom: 3),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(
                child: Text(me ? 'You' : _msgName(full),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: AppText.bodyStrong().copyWith(fontSize: 12)),
              ),
              if (org) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                      color: AppColors.gold.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(999)),
                  child: Text('ORGANIZER',
                      style: AppText.tag(AppColors.gold).copyWith(fontSize: 8.5, letterSpacing: 0.4)),
                ),
              ],
            ]),
          ),
        bubble,
      ],
    );

    return Padding(
      padding: EdgeInsets.only(top: first ? 9 : 3),
      child: Row(
        mainAxisAlignment: me ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: me
            ? [Flexible(child: column), const SizedBox(width: 7), avatarSlot]
            : [avatarSlot, const SizedBox(width: 7), Flexible(child: column)],
      ),
    );
  }

  static String _permText(String post) => switch (post) {
        'registered' => 'Registered players and the organizer can post.',
        'org' => 'Only the organizer can post here.',
        _ => 'Any community member can post here.',
      };

  Widget? _eventBanner() {
    if (!widget.isEvent) return null;
    final (Color bg, Color color, IconData icon, String text) = switch (widget.state) {
      'grace' => (
          AppColors.gold.withValues(alpha: 0.14),
          AppColors.gold,
          Icons.schedule_rounded,
          'This event has ended. The channel closes in 24h — share your photos & say thanks!'
        ),
      'archived' => (
          AppColors.field,
          AppColors.inkSoft,
          Icons.lock_outline_rounded,
          'This channel is archived. Read-only history — removed after 30 days.'
        ),
      _ => (
          AppColors.primary.withValues(alpha: 0.10),
          AppColors.gold,
          Icons.confirmation_number_outlined,
          'Channel opened for this event. ${_permText(widget.post)}'
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 9),
        Expanded(
          child: Text(text,
              style: AppText.small(color).copyWith(fontSize: 11.5, height: 1.35, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }

  Widget _composer() {
    final bottom = MediaQuery.of(context).padding.bottom;
    if (!widget.canPost) {
      final reason = widget.archived
          ? 'Posting is closed'
          : widget.post == 'org'
              ? 'Only the organizer can post here'
              : widget.post == 'registered'
                  ? 'Only registered players can post here'
                  : 'Join the community to post here';
      return Container(
        width: double.infinity,
        decoration: const BoxDecoration(
            color: AppColors.surface,
            border: Border(top: BorderSide(color: AppColors.lineSoft))),
        padding: EdgeInsets.fromLTRB(16, 14, 16, 14 + bottom),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.lock_outline_rounded, size: 14, color: AppColors.inkFaint),
          const SizedBox(width: 8),
          Text(reason, style: AppText.small(AppColors.inkFaint)),
        ]),
      );
    }
    return Container(
      decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.lineSoft))),
      padding: EdgeInsets.fromLTRB(14, 10, 14, 14 + bottom),
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
              onSubmitted: (_) => _send(),
              style: AppText.body(AppColors.ink).copyWith(fontSize: 14),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                hintText: 'Message #${widget.channelName}…',
                hintStyle: AppText.body(AppColors.inkFaint).copyWith(fontSize: 14),
              ),
            ),
          ),
        ),
        const SizedBox(width: 9),
        GestureDetector(
          onTap: _sending ? null : _send,
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
            child: const Icon(Icons.arrow_upward_rounded, color: AppColors.primaryInk, size: 20),
          ),
        ),
      ]),
    );
  }
}

// ── Member mini-profile popup ───────────────────────────────────────────────
class _MemberProfileSheet extends StatefulWidget {
  final String communityId;
  final MemberLite member;
  final String communityName;
  final VoidCallback onMessage;
  const _MemberProfileSheet({
    required this.communityId,
    required this.member,
    required this.communityName,
    required this.onMessage,
  });
  @override
  State<_MemberProfileSheet> createState() => _MemberProfileSheetState();
}

class _MemberProfileSheetState extends State<_MemberProfileSheet> {
  Map<String, dynamic>? _card;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final card =
        await CommunityService.memberCard(widget.communityId, widget.member.id);
    if (!mounted) return;
    setState(() {
      _card = card;
      _loading = false;
    });
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  String _sinceLabel() {
    final d = DateTime.tryParse('${_card?['joined']}')?.toLocal();
    if (d == null) return 'Member';
    return 'Member since ${_months[d.month - 1]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.member;
    final tint = m.tier != null ? AppColors.tier(m.tier!) : AppColors.accent;
    final played = (_card?['played'] as num?)?.toInt() ?? 0;
    final wins = (_card?['wins'] as num?)?.toInt() ?? 0;
    final winRate = played > 0 ? '${(wins / played * 100).round()}%' : '—';
    final unranked = m.tier == 'Unranked';
    final level = (_card?['level'] as num?)?.toDouble();
    final rank = (_card?['rank'] as num?)?.toInt();
    final city = (_card?['city'] as String?)?.trim();
    final hand = (_card?['hand'] as String?)?.trim();
    final side = (_card?['side'] as String?)?.trim();

    String cap(String s) =>
        s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();
    final handSide = [
      if (hand != null && hand.isNotEmpty) cap(hand),
      if (side != null && side.isNotEmpty) '${cap(side)} side',
    ].join(' · ');

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 26),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // header
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [tint.withValues(alpha: 0.13), AppColors.surface],
              ),
            ),
            child: Column(children: [
              AppAvatar(m.initials, size: 72, color: tint, ring: 2.5,
                  imageUrl: m.avatarUrl),
              const SizedBox(height: 9),
              Text(m.name,
                  style: AppText.stat(18, AppColors.ink), textAlign: TextAlign.center),
              const SizedBox(height: 3),
              Text(
                  [if (city != null && city.isNotEmpty) city, _sinceLabel()].join(' · '),
                  style: AppText.small(AppColors.inkSoft).copyWith(fontSize: 11.5)),
              const SizedBox(height: 9),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (m.tier != null) AppTag(m.tier!, color: tint),
                if (rank != null) ...[
                  const SizedBox(width: 7),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: AppColors.line),
                    ),
                    child: Text('Rank #$rank',
                        style: AppText.small(AppColors.inkSoft)
                            .copyWith(fontSize: 11, fontWeight: FontWeight.w700)),
                  ),
                ],
              ]),
            ]),
          ),
          // stats strip
          Container(
            decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppColors.lineSoft))),
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Row(children: [
                    _stat(unranked || level == null
                        ? '—'
                        : RankingScale.fmtQuarter(level), 'Level'),
                    _divider(),
                    _stat('$played', 'Played'),
                    _divider(),
                    _stat(winRate, 'Win rate'),
                  ]),
          ),
          // footer
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppColors.lineSoft))),
            child: Column(children: [
              if (handSide.isNotEmpty) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(handSide,
                      style: AppText.small(AppColors.inkSoft).copyWith(fontSize: 11.5)),
                ),
                const SizedBox(height: 10),
              ],
              AppButton('Message privately',
                  full: true,
                  height: 48,
                  icon: Icons.chat_bubble_outline_rounded,
                  onPressed: widget.onMessage),
              const SizedBox(height: 8),
              AppButton('Close',
                  full: true,
                  height: 46,
                  variant: AppBtnVariant.ghost,
                  onPressed: () => Navigator.of(context).pop()),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _stat(String value, String label) => Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 4),
          child: Column(children: [
            Text(value, style: AppText.stat(15, AppColors.ink)),
            const SizedBox(height: 2),
            Text(label.toUpperCase(),
                style: AppText.tag(AppColors.inkFaint)
                    .copyWith(fontSize: 9.5, letterSpacing: 0.7)),
          ]),
        ),
      );

  Widget _divider() =>
      Container(width: 1, height: 40, color: AppColors.lineSoft);
}

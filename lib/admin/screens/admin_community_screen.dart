// ============================================================================
// admin_community_screen.dart — the Organizer's Community console.
// Create/edit the community, post announcements, see members, and read + reply
// to member messages (the inbox). Member↔organizer chat lives in
// community_messages (organizers are console-only). Uses admin_kit.
// ============================================================================
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../../backend/services/community_service.dart';
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';
import '../widgets/organizer_payout_card.dart';

class AdminCommunityScreen extends StatefulWidget {
  const AdminCommunityScreen({super.key});
  @override
  State<AdminCommunityScreen> createState() => _AdminCommunityScreenState();
}

class _AdminCommunityScreenState extends State<AdminCommunityScreen> {
  Community? _c;
  List<InboxItem> _inbox = [];
  List<MemberLite> _members = [];
  List<Map<String, dynamic>> _channels = [];
  String _eventPost = 'registered';
  Map<String, dynamic> _stats = {};
  bool _loading = true;

  int _s(String k) => (_stats[k] as num?)?.toInt() ?? 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final c = await CommunityService.myCommunity();
    if (!mounted) return;
    if (c == null) {
      setState(() {
        _c = null;
        _loading = false;
      });
      return;
    }
    final results = await Future.wait([
      CommunityService.typedInbox(),
      CommunityService.members(c.id),
      CommunityService.organizerStats(),
      CommunityService.channelList(c.id),
      CommunityService.channelSettings(),
    ]);
    if (!mounted) return;
    final settings = results[4] as Map<String, dynamic>;
    setState(() {
      _c = c;
      _inbox = results[0] as List<InboxItem>;
      _members = results[1] as List<MemberLite>;
      _stats = results[2] as Map<String, dynamic>;
      _channels = results[3] as List<Map<String, dynamic>>;
      _eventPost = (settings['channel_event_post'] as String?) ?? 'registered';
      _loading = false;
    });
  }

  // ── Channels management ─────────────────────────────────────────
  static String _postLabel(String p) => switch (p) {
        'org' => 'Organizer only',
        'registered' => 'Players only',
        _ => 'All members',
      };

  Future<void> _createChannel() async {
    final nameC = TextEditingController();
    String post = 'all';
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        return _SheetShell(
          title: 'New channel',
          busy: false,
          cta: 'Create channel',
          onSave: () => Navigator.pop(ctx, true),
          children: [
            TextField(
              controller: nameC,
              autofocus: true,
              decoration: const InputDecoration(
                  hintText: 'channel-name', prefixText: '# '),
            ),
            const SizedBox(height: 14),
            Text('WHO CAN POST', style: AdminText.kicker()),
            const SizedBox(height: 8),
            Row(children: [
              for (final p in const ['all', 'registered', 'org'])
                Expanded(
                  child: GestureDetector(
                    onTap: () => setSheet(() => post = p),
                    child: Container(
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: post == p ? AdminColors.primary : AdminColors.surface3,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Text(_postLabel(p),
                          textAlign: TextAlign.center,
                          style: AdminText.sans(11, FontWeight.w700,
                              post == p ? Colors.white : AdminColors.inkSoft)),
                    ),
                  ),
                ),
            ]),
          ],
        );
      }),
    );
    if (ok != true) return;
    final err = await CommunityService.createChannel(nameC.text, post);
    nameC.dispose();
    if (!mounted) return;
    if (err != null) {
      adminToast(context, err);
      return;
    }
    _load();
  }

  Future<void> _channelActions(Map<String, dynamic> ch) async {
    final id = ch['id'] as String;
    final isCustom = ch['is_custom'] == true;
    final isEvent = (ch['kind'] as String? ?? 'community') != 'community';
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: AdminColors.surface, borderRadius: BorderRadius.circular(18)),
        child: SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('#${ch['name']}',
                    style: AdminText.sans(15, FontWeight.w800, AdminColors.ink)),
              ),
            ),
            for (final p in const ['all', 'registered', 'org'])
              ListTile(
                leading: Icon(
                    (ch['post'] as String?) == p
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: AdminColors.primary),
                title: Text('Post: ${_postLabel(p)}', style: AdminText.strong()),
                onTap: () => Navigator.pop(ctx, 'post:$p'),
              ),
            if (isCustom && !isEvent)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: AdminColors.danger),
                title: Text('Delete channel', style: AdminText.strong()),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
    if (action == null) return;
    String? err;
    if (action == 'delete') {
      err = await CommunityService.deleteChannel(id);
    } else if (action.startsWith('post:')) {
      err = await CommunityService.setChannelPost(id, action.substring(5));
    }
    if (!mounted) return;
    if (err != null) {
      adminToast(context, err);
      return;
    }
    _load();
  }

  Future<void> _setEventPost(String p) async {
    setState(() => _eventPost = p);
    final err = await CommunityService.setChannelSettings(p, false);
    if (!mounted) return;
    if (err != null) adminToast(context, err);
  }

  Widget _channelManageRow(Map<String, dynamic> ch) {
    final name = ch['name'] as String? ?? 'channel';
    final isEvent = (ch['kind'] as String? ?? 'community') != 'community';
    final post = ch['post'] as String? ?? 'all';
    final state = ch['state'] as String? ?? 'active';
    return AdminCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      onTap: () => _channelActions(ch),
      child: Row(children: [
        Icon(isEvent ? Icons.emoji_events_outlined : Icons.tag_rounded,
            size: 18, color: isEvent ? AdminColors.gold : AdminColors.inkSoft),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: AdminText.strong()),
            Text(
                _postLabel(post) +
                    (isEvent && state != 'active' ? ' · $state' : ''),
                style: AdminText.small()),
          ]),
        ),
        const Icon(Icons.chevron_right_rounded, size: 20, color: AdminColors.inkFaint),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AdminColors.primary));
    }
    if (_c == null) return _createGate();
    final c = _c!;
    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(AdminUI.screen), children: [
        KpiGrid([
          StatCard(icon: Icons.groups_outlined, tone: AdminColors.gold,
              label: 'Members', value: '${c.memberCount}', foot: "in ${c.name}"),
          StatCard(icon: Icons.forum_outlined, tone: AdminColors.primary,
              label: 'Inbox', value: '${_inbox.length}',
              foot: _s('inbox_unread') > 0 ? '${_s('inbox_unread')} unanswered' : 'all answered'),
          StatCard(icon: Icons.sports_tennis_outlined, tone: AdminColors.info,
              label: 'Events this week', value: '${_s('events_week')}', foot: 'you\'re running'),
          StatCard(icon: Icons.check_circle_outline, tone: AdminColors.green,
              label: 'Matches made', value: '${_s('matches_made')}', foot: 'all-time'),
        ]),
        const SizedBox(height: 16),
        _summary(c),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: AdminButton('Post announcement',
                icon: Icons.campaign_outlined,
                variant: AdminBtn.primary,
                onPressed: _postAnnouncement),
          ),
          const SizedBox(width: 10),
          AdminButton('Edit',
              icon: Icons.edit_outlined,
              variant: AdminBtn.ghost,
              onPressed: () => _editCommunity(c)),
        ]),
        const SizedBox(height: 12),
        AdminCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(children: [
            const Icon(Icons.verified_user_outlined, size: 18, color: AdminColors.inkSoft),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Require approval to join', style: AdminText.strong()),
                Text('New members arrive as join requests in your inbox',
                    style: AdminText.small()),
              ]),
            ),
            Switch(
              value: c.approvalRequired,
              activeThumbColor: AdminColors.primary,
              onChanged: _toggleApproval,
            ),
          ]),
        ),
        const SizedBox(height: 16),
        const OrganizerPayoutCard(),
        const SizedBox(height: 2),
        Row(children: [
          Expanded(child: Text('CHANNELS', style: AdminText.kicker())),
          GestureDetector(
            onTap: _createChannel,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.add_rounded, size: 16, color: AdminColors.primary),
              const SizedBox(width: 3),
              Text('New',
                  style: AdminText.sans(12.5, FontWeight.w800, AdminColors.primary)),
            ]),
          ),
        ]),
        const SizedBox(height: 8),
        AdminCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Event channels · who can post', style: AdminText.strong()),
            Text('Applied to new tournament channels', style: AdminText.small()),
            const SizedBox(height: 10),
            Row(children: [
              for (final p in const ['all', 'registered', 'org']) ...[
                Expanded(
                  child: GestureDetector(
                    onTap: () => _setEventPost(p),
                    child: Container(
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _eventPost == p ? AdminColors.primary : AdminColors.surface3,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Text(_postLabel(p),
                          textAlign: TextAlign.center,
                          style: AdminText.sans(11, FontWeight.w700,
                              _eventPost == p ? Colors.white : AdminColors.inkSoft)),
                    ),
                  ),
                ),
              ],
            ]),
          ]),
        ),
        const SizedBox(height: 10),
        if (_channels.isEmpty)
          _emptyCard(Icons.tag_rounded, 'No channels yet.')
        else
          for (final ch in _channels) ...[_channelManageRow(ch), const SizedBox(height: 8)],
        const SizedBox(height: 18),
        Text('INBOX', style: AdminText.kicker()),
        const SizedBox(height: 8),
        if (_inbox.isEmpty)
          _emptyCard(Icons.forum_outlined, 'No messages yet.')
        else
          for (final t in _inbox) ...[_inboxRow(t), const SizedBox(height: 8)],
        const SizedBox(height: 18),
        Text('MEMBERS · ${c.memberCount}', style: AdminText.kicker()),
        const SizedBox(height: 8),
        if (c.memberCount > 0) ...[
          _tierBars(c.memberCount),
          const SizedBox(height: 10),
        ],
        if (_members.isEmpty)
          _emptyCard(Icons.groups_outlined, 'No members yet.')
        else
          AdminCard(
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: _members
                  .map((m) => SizedBox(
                        width: 62,
                        child: Column(children: [
                          AdminAvatar(m.initials, size: 44, color: AdminColors.green),
                          const SizedBox(height: 5),
                          Text(m.name.split(' ').first,
                              style: AdminText.small(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ]),
                      ))
                  .toList(),
            ),
          ),
      ]),
    );
  }

  Widget _tierBars(int total) {
    final rows = <List<Object>>[
      ['Bronze–Silver', _s('tier_bronze'), const Color(0xFF9E7B4F)],
      ['Gold', _s('tier_gold'), AdminColors.gold],
      ['Elite', _s('tier_elite'), AdminColors.primary],
    ];
    return AdminCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          Row(children: [
            Expanded(child: Text(rows[i][0] as String, style: AdminText.small())),
            Text('${rows[i][1]}',
                style: AdminText.sans(12.5, FontWeight.w800, AdminColors.ink)),
          ]),
          const SizedBox(height: 5),
          AdminProgress((rows[i][1] as int) / (total == 0 ? 1 : total),
              color: rows[i][2] as Color),
        ],
      ]),
    );
  }

  Widget _summary(Community c) => AdminCard(
        onTap: c.handle != null
            ? () {
                Clipboard.setData(ClipboardData(text: '@${c.handle}'));
                adminToast(context, 'Join code copied — share it with members');
              }
            : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 50,
              height: 50,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: AdminColors.gold.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(13)),
              child: const Icon(Icons.groups_2_rounded, size: 25, color: AdminColors.gold),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                      child: Text(c.name,
                          style: AdminText.cardTitle(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis)),
                  if (c.verified) ...[
                    const SizedBox(width: 5),
                    const Icon(Icons.verified_rounded, size: 15, color: AdminColors.gold),
                  ],
                ]),
                const SizedBox(height: 2),
                Text(
                    [
                      if (c.city != null) c.city!,
                      '${c.memberCount} member${c.memberCount == 1 ? '' : 's'}',
                    ].join(' · '),
                    style: AdminText.small()),
              ]),
            ),
          ]),
          if (c.handle != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                  color: AdminColors.wash(AdminColors.primary, 0.10),
                  borderRadius: BorderRadius.circular(11)),
              child: Row(children: [
                const Icon(Icons.key_rounded, size: 16, color: AdminColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('JOIN CODE', style: AdminText.kicker()),
                    Text('@${c.handle}',
                        style: AdminText.sans(15, FontWeight.w800, AdminColors.ink)),
                  ]),
                ),
                const Icon(Icons.copy_rounded, size: 16, color: AdminColors.primary),
              ]),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text('Add a handle to give members a join code.',
                  style: AdminText.small()),
            ),
        ]),
      );

  Widget _inboxRow(InboxItem it) {
    final isMsg = it.kind == 'message';
    final tag = it.kind == 'join'
        ? ('Join request', AdminColors.gold)
        : it.kind == 'match'
            ? ('Match request', AdminColors.info)
            : ('Message', AdminColors.inkSoft);
    return AdminCard(
      onTap: isMsg ? () => _openMessage(it) : null,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(children: [
        AdminAvatar(it.initials, size: 42, color: tag.$2),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(it.memberName, style: AdminText.strong())),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                    color: tag.$2.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999)),
                child: Text(tag.$1,
                    style: AdminText.sans(10.5, FontWeight.w700, tag.$2)),
              ),
            ]),
            const SizedBox(height: 2),
            Text(it.preview ?? '',
                style: AdminText.small(), maxLines: 2, overflow: TextOverflow.ellipsis),
            if (it.actionable) ...[
              const SizedBox(height: 8),
              Row(children: [
                AdminButton(it.kind == 'join' ? 'Approve' : 'On it',
                    icon: Icons.check_rounded,
                    variant: AdminBtn.primary,
                    onPressed: () => _act(it, true)),
                if (it.kind == 'join') ...[
                  const SizedBox(width: 8),
                  AdminButton('Decline',
                      variant: AdminBtn.ghost, onPressed: () => _act(it, false)),
                ],
              ]),
            ],
          ]),
        ),
      ]),
    );
  }

  Future<void> _toggleApproval(bool v) async {
    final err = await CommunityService.setApproval(v);
    if (!mounted) return;
    if (err != null) {
      adminToast(context, err, ok: false);
    } else {
      _load();
    }
  }

  Future<void> _act(InboxItem it, bool approve) async {
    if (it.id == null) return;
    final err = it.kind == 'join'
        ? await CommunityService.approveJoin(it.id!, approve)
        : await CommunityService.resolveMatchRequest(it.id!);
    if (!mounted) return;
    if (err != null) {
      adminToast(context, err, ok: false);
      return;
    }
    adminToast(context,
        it.kind == 'join' ? (approve ? 'Member approved' : 'Declined') : 'Marked handled');
    _load();
  }

  Future<void> _openMessage(InboxItem it) async {
    final thread = InboxThread(
        memberId: it.memberId, memberName: it.memberName, avatarUrl: it.avatarUrl);
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _CommunityThreadScreen(communityId: _c!.id, thread: thread)));
    _load();
  }

  Widget _emptyCard(IconData icon, String text) => AdminCard(
        child: Row(children: [
          Icon(icon, size: 18, color: AdminColors.inkFaint),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: AdminText.small())),
        ]),
      );

  // ── Create gate (no community yet) ───────────────────────────────────────
  Widget _createGate() {
    return ListView(padding: const EdgeInsets.all(AdminUI.screen), children: [
      const SizedBox(height: 20),
      Center(
        child: Container(
          width: 64,
          height: 64,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: AdminColors.gold.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(18)),
          child: const Icon(Icons.groups_2_rounded, size: 32, color: AdminColors.gold),
        ),
      ),
      const SizedBox(height: 16),
      Center(child: Text('Start your community', style: AdminText.h2())),
      const SizedBox(height: 6),
      Center(
        child: SizedBox(
          width: 280,
          child: Text(
              'Give your players a home — announcements, events and a direct line to you.',
              style: AdminText.small(),
              textAlign: TextAlign.center),
        ),
      ),
      const SizedBox(height: 20),
      AdminButton('Create community',
          icon: Icons.add, variant: AdminBtn.primary, full: true, onPressed: () => _editCommunity(null)),
    ]);
  }

  // ── Actions ──────────────────────────────────────────────────────────────
  Future<void> _editCommunity(Community? existing) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CommunityForm(existing: existing),
    );
    if (saved == true) _load();
  }

  Future<void> _postAnnouncement() async {
    final posted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _AnnouncementForm(),
    );
    if (posted == true && mounted) {
      adminToast(context, 'Announcement posted to your members');
    }
  }

}

// ── Community create/edit form ─────────────────────────────────────────────
class _CommunityForm extends StatefulWidget {
  final Community? existing;
  const _CommunityForm({this.existing});
  @override
  State<_CommunityForm> createState() => _CommunityFormState();
}

class _CommunityFormState extends State<_CommunityForm> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _handle = TextEditingController(text: widget.existing?.handle ?? '');
  late final _city = TextEditingController(text: widget.existing?.city ?? '');
  late final _about = TextEditingController(text: widget.existing?.about ?? '');
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _handle.dispose();
    _city.dispose();
    _about.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) return;
    setState(() => _busy = true);
    final err = await CommunityService.upsertMyCommunity(
      name: _name.text.trim(),
      handle: _handle.text.trim(),
      city: _city.text.trim(),
      about: _about.text.trim(),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      adminToast(context, err, ok: false);
      return;
    }
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return _sheet(
      title: widget.existing == null ? 'Create community' : 'Edit community',
      busy: _busy,
      cta: widget.existing == null ? 'Create' : 'Save',
      onSave: _save,
      children: [
        _label('Name'),
        _field(_name, "e.g. Youssef's Padel Circle"),
        const SizedBox(height: 12),
        _label('Handle'),
        _field(_handle, 'e.g. alexpadel', prefix: Icons.alternate_email),
        const SizedBox(height: 12),
        _label('City'),
        _field(_city, 'e.g. Alexandria'),
        const SizedBox(height: 12),
        _label('About'),
        _field(_about, 'What is your community about?', lines: 3),
      ],
    );
  }
}

// ── Announcement form ──────────────────────────────────────────────────────
class _AnnouncementForm extends StatefulWidget {
  const _AnnouncementForm();
  @override
  State<_AnnouncementForm> createState() => _AnnouncementFormState();
}

class _AnnouncementFormState extends State<_AnnouncementForm> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  bool _pinned = false, _busy = false;
  Uint8List? _imgBytes;
  String _imgExt = 'jpg';

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    // Had no try at all: a denied permission or an unreadable file threw an
    // unhandled async error, which in release is indistinguishable from the
    // button being dead.
    try {
      final f = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (f == null) return;
      final bytes = await f.readAsBytes();
      if (!mounted) return;
      setState(() {
        _imgBytes = bytes;
        _imgExt = f.name.contains('.') ? f.name.split('.').last.toLowerCase() : 'jpg';
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not open your photos. If access is turned off, '
              'you can enable it in Settings.')));
    }
  }

  Future<void> _post() async {
    if (_title.text.trim().isEmpty) return;
    setState(() => _busy = true);
    String? imageUrl;
    if (_imgBytes != null) {
      imageUrl = await CommunityService.uploadPostImage(_imgBytes!, _imgExt);
      if (imageUrl == null) {
        if (!mounted) return;
        setState(() => _busy = false);
        adminToast(context, "Couldn't upload the photo — try again", ok: false);
        return;
      }
    }
    final err = await CommunityService.postAnnouncement(
      title: _title.text.trim(),
      body: _body.text.trim(),
      pinned: _pinned,
      imageUrl: imageUrl,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      adminToast(context, err, ok: false);
      return;
    }
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return _sheet(
      title: 'Post announcement',
      sub: 'Notifies every member (push + in-app)',
      busy: _busy,
      cta: 'Post',
      onSave: _post,
      children: [
        _label('Title'),
        _field(_title, 'e.g. June social ladder is live'),
        const SizedBox(height: 12),
        _label('Message'),
        _field(_body, 'Add the details players need…', lines: 4),
        const SizedBox(height: 12),
        _label('Photo (optional)'),
        _imagePickerBox(),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: () => setState(() => _pinned = !_pinned),
          child: Row(children: [
            Icon(_pinned ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                size: 20, color: _pinned ? AdminColors.primary : AdminColors.inkFaint),
            const SizedBox(width: 8),
            Text('Pin to the top of the feed', style: AdminText.body()),
          ]),
        ),
      ],
    );
  }

  Widget _imagePickerBox() {
    if (_imgBytes != null) {
      return Stack(children: [
        ClipRRect(
          borderRadius: AdminUI.fieldR,
          child: Image.memory(_imgBytes!,
              width: double.infinity, height: 170, fit: BoxFit.cover),
        ),
        Positioned(
          top: 8,
          right: 8,
          child: GestureDetector(
            onTap: () => setState(() => _imgBytes = null),
            child: Container(
              padding: const EdgeInsets.all(5),
              decoration: const BoxDecoration(
                  color: Colors.black54, shape: BoxShape.circle),
              child: const Icon(Icons.close_rounded, size: 18, color: Colors.white),
            ),
          ),
        ),
      ]);
    }
    return GestureDetector(
      onTap: _pickImage,
      child: Container(
        height: 92,
        decoration: BoxDecoration(
          color: AdminColors.surfaceAlt,
          borderRadius: AdminUI.fieldR,
          border: Border.all(color: AdminColors.line),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.add_photo_alternate_outlined,
                size: 24, color: AdminColors.inkSoft),
            const SizedBox(height: 5),
            Text('Add a photo', style: AdminText.small()),
          ],
        ),
      ),
    );
  }
}

// ── Organizer thread view (reply to a member) ──────────────────────────────
class _CommunityThreadScreen extends StatefulWidget {
  final String communityId;
  final InboxThread thread;
  const _CommunityThreadScreen({required this.communityId, required this.thread});
  @override
  State<_CommunityThreadScreen> createState() => _CommunityThreadScreenState();
}

class _CommunityThreadScreenState extends State<_CommunityThreadScreen> {
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
    final msgs =
        await CommunityService.threadWith(widget.communityId, widget.thread.memberId);
    if (!mounted) return;
    setState(() {
      _messages = msgs;
      _loading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final err = await CommunityService.reply(widget.thread.memberId, text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (err != null) {
      adminToast(context, err, ok: false);
      return;
    }
    _input.clear();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AdminColors.canvas,
      appBar: AppBar(
        backgroundColor: AdminColors.surface,
        elevation: 0,
        foregroundColor: AdminColors.ink,
        title: Row(children: [
          AdminAvatar(widget.thread.initials, size: 32, color: AdminColors.info),
          const SizedBox(width: 10),
          Text(widget.thread.memberName, style: AdminText.h2()),
        ]),
      ),
      body: Column(children: [
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: AdminColors.primary))
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(14),
                  itemCount: _messages.length,
                  itemBuilder: (_, i) => _bubble(_messages[i]),
                ),
        ),
        _composer(),
      ]),
    );
  }

  Widget _bubble(CommunityMessage m) {
    final mine = m.fromMe; // organizer's own messages
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.74),
        decoration: BoxDecoration(
          color: mine ? AdminColors.primary : AdminColors.surface,
          borderRadius: BorderRadius.circular(13),
          border: mine ? null : Border.all(color: AdminColors.line),
        ),
        child: Text(m.body,
            style: AdminText.body(mine ? AdminColors.primaryInk : AdminColors.ink)),
      ),
    );
  }

  Widget _composer() => SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          decoration: const BoxDecoration(
              color: AdminColors.surface,
              border: Border(top: BorderSide(color: AdminColors.line))),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                style: AdminText.body(),
                decoration: InputDecoration(
                  hintText: 'Reply…',
                  hintStyle: AdminText.small(AdminColors.inkFaint),
                  filled: true,
                  fillColor: AdminColors.surfaceAlt,
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
                    color: AdminColors.primary, shape: BoxShape.circle),
                child: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AdminColors.primaryInk))
                    : const Icon(Icons.send_rounded, size: 20, color: AdminColors.primaryInk),
              ),
            ),
          ]),
        ),
      );
}

// ── shared sheet scaffolding ───────────────────────────────────────────────
Widget _sheet({
  required String title,
  String? sub,
  required bool busy,
  required String cta,
  required VoidCallback onSave,
  required List<Widget> children,
}) =>
    _SheetShell(title: title, sub: sub, busy: busy, cta: cta, onSave: onSave, children: children);

class _SheetShell extends StatelessWidget {
  final String title;
  final String? sub;
  final bool busy;
  final String cta;
  final VoidCallback onSave;
  final List<Widget> children;
  const _SheetShell(
      {required this.title,
      this.sub,
      required this.busy,
      required this.cta,
      required this.onSave,
      required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
            color: AdminColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 12, 8),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: AdminText.h2()),
                  if (sub != null) ...[
                    const SizedBox(height: 2),
                    Text(sub!, style: AdminText.small()),
                  ],
                ]),
              ),
              IconButton(
                  icon: const Icon(Icons.close_rounded, color: AdminColors.inkSoft),
                  onPressed: () => Navigator.pop(context)),
            ]),
          ),
          const Divider(height: 1, color: AdminColors.lineSoft),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 22),
            decoration: const BoxDecoration(
                color: AdminColors.surfaceAlt,
                border: Border(top: BorderSide(color: AdminColors.lineSoft))),
            child: AdminButton(busy ? 'Saving…' : cta,
                variant: AdminBtn.primary, full: true, onPressed: busy ? null : onSave),
          ),
        ]),
      ),
    );
  }
}

Widget _label(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(t, style: AdminText.strong(AdminColors.inkSoft)));

Widget _field(TextEditingController c, String hint, {IconData? prefix, int lines = 1}) =>
    TextField(
      controller: c,
      maxLines: lines,
      style: AdminText.body(),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: AdminText.small(AdminColors.inkFaint),
        prefixIcon: prefix == null ? null : Icon(prefix, size: 18, color: AdminColors.inkFaint),
        filled: true,
        fillColor: AdminColors.surfaceAlt,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
            borderRadius: AdminUI.fieldR, borderSide: const BorderSide(color: AdminColors.line)),
        enabledBorder: OutlineInputBorder(
            borderRadius: AdminUI.fieldR, borderSide: const BorderSide(color: AdminColors.line)),
        focusedBorder: OutlineInputBorder(
            borderRadius: AdminUI.fieldR, borderSide: const BorderSide(color: AdminColors.primary)),
      ),
    );

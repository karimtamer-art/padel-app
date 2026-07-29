import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';
import '../data/admin_service.dart';
import '../../backend/services/community_service.dart';

class AdminBroadcastsScreen extends StatefulWidget {
  /// When set (organizer console), the screen shows ONLY this organizer's own
  /// broadcasts and sends to their community, not platform-wide.
  final String? organizerId;
  const AdminBroadcastsScreen({super.key, this.organizerId});
  @override
  State<AdminBroadcastsScreen> createState() => _AdminBroadcastsScreenState();
}

class _AdminBroadcastsScreenState extends State<AdminBroadcastsScreen> {
  List<Map<String, dynamic>> _broadcasts = [];
  bool _loading = true;

  bool get _isOrganizer => widget.organizerId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = _isOrganizer
          ? await AdminService.organizerBroadcastsList()
          : await AdminService.fetchBroadcasts();
      if (mounted) setState(() { _broadcasts = data; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  static String _fmtDate(String? iso) {
    if (iso == null) return '—';
    try {
      final dt = DateTime.parse(iso).toLocal();
      const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
      return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
    } catch (_) {
      return iso.substring(0, 10);
    }
  }

  static Color _targetColor(String? t) {
    switch (t) {
      case 'all': return AdminColors.primary;
      case 'ranked': return AdminColors.green;
      case 'unranked': return AdminColors.warn;
      default: return AdminColors.inkSoft;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AdminColors.primary));
    }

    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
        children: [
          AdminSection(
            'Broadcasts',
            sub: '${_broadcasts.length} sent',
            action: AdminButton('New', icon: Icons.add_rounded, height: 34, onPressed: _compose),
          ),
          if (_broadcasts.isEmpty)
            _emptyState()
          else
            for (final b in _broadcasts) _card(b),
        ],
      ),
    );
  }

  Widget _card(Map<String, dynamic> b) {
    final target = b['segment'] as String? ?? 'all';
    final tc = _isOrganizer ? AdminColors.gold : _targetColor(target);
    final badge = _isOrganizer
        ? '${(b['recipients'] as num?)?.toInt() ?? 0} reached'
        : 'To: ${target[0].toUpperCase()}${target.substring(1)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AdminCard(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AdminColors.wash(tc, 0.14),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(badge, style: AdminText.sans(11, FontWeight.w700, tc)),
            ),
            const Spacer(),
            Text(_fmtDate(b['sent_at'] as String? ?? b['created_at'] as String?),
                style: AdminText.mono(10.5, FontWeight.w500, AdminColors.inkFaint)),
          ]),
          const SizedBox(height: 10),
          Text(b['title'] as String? ?? '(no title)', style: AdminText.strong()),
          const SizedBox(height: 4),
          Text(b['body'] as String? ?? '',
              style: AdminText.small(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
          if ((b['image_url'] as String?)?.isNotEmpty ?? false) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                b['image_url'] as String,
                width: double.infinity,
                height: 150,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  void _compose() {
    if (_isOrganizer) {
      _composeOrganizer();
      return;
    }
    final titleC = TextEditingController();
    final bodyC = TextEditingController();
    String segment = 'all';

    adminSheet(
      context,
      title: 'New broadcast',
      sub: 'Pushed instantly to the chosen audience',
      heightFactor: 0.72,
      footer: AdminButton(
        'Send broadcast',
        full: true,
        height: 50,
        icon: Icons.send_rounded,
        onPressed: () async {
          if (titleC.text.trim().isEmpty || bodyC.text.trim().isEmpty) return;
          Navigator.pop(context);
          try {
            final uid = Supabase.instance.client.auth.currentUser?.id ?? '';
            await AdminService.createBroadcast(
              title: titleC.text.trim(),
              body: bodyC.text.trim(),
              segment: segment,
              adminId: uid,
            );
            await _load();
            if (mounted) adminToast(context, 'Broadcast sent');
          } catch (_) {
            if (mounted) adminToast(context, 'Failed to send', ok: false);
          }
        },
      ),
      body: StatefulBuilder(builder: (c, setSheet) {
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Title', style: AdminText.strong(AdminColors.inkSoft)),
          const SizedBox(height: 7),
          _field(titleC, hint: 'e.g. Weekend tournament now open'),
          const SizedBox(height: 14),
          Text('Message', style: AdminText.strong(AdminColors.inkSoft)),
          const SizedBox(height: 7),
          _field(bodyC, hint: 'What do you want players to know?', maxLines: 4),
          const SizedBox(height: 16),
          Text('Audience', style: AdminText.strong(AdminColors.inkSoft)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            for (final t in const ['all', 'ranked', 'unranked'])
              GestureDetector(
                onTap: () => setSheet(() => segment = t),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: segment == t ? AdminColors.primary : AdminColors.surface,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: segment == t ? AdminColors.primary : AdminColors.line),
                  ),
                  child: Text(
                    t[0].toUpperCase() + t.substring(1),
                    style: AdminText.sans(12.5, FontWeight.w700,
                        segment == t ? AdminColors.primaryInk : AdminColors.inkSoft),
                  ),
                ),
              ),
          ]),
        ]);
      }),
    );
  }

  void _composeOrganizer() {
    final titleC = TextEditingController();
    final bodyC = TextEditingController();
    Uint8List? imgBytes;
    String imgExt = 'jpg';
    adminSheet(
      context,
      title: 'Post to your community',
      sub: 'Pushes to members & entrants + a likeable post in their feed',
      heightFactor: 0.82,
      footer: AdminButton(
        'Post',
        full: true,
        height: 50,
        icon: Icons.send_rounded,
        color: AdminColors.gold,
        onPressed: () async {
          if (titleC.text.trim().isEmpty) return;
          Navigator.pop(context);
          String? imageUrl;
          if (imgBytes != null) {
            imageUrl = await CommunityService.uploadPostImage(imgBytes!, imgExt);
            if (imageUrl == null) {
              if (mounted) {
                adminToast(context, "Couldn't upload the photo — try again",
                    ok: false);
              }
              return;
            }
          }
          final err = await AdminService.organizerBroadcast(
              title: titleC.text.trim(),
              body: bodyC.text.trim(),
              imageUrl: imageUrl);
          if (!mounted) return;
          if (err != null) {
            adminToast(context, err, ok: false);
            return;
          }
          await _load();
          if (mounted) adminToast(context, 'Posted to your community');
        },
      ),
      body: StatefulBuilder(builder: (c, setSheet) {
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
                color: AdminColors.wash(AdminColors.gold, 0.12),
                borderRadius: AdminUI.fieldR),
            child: Row(children: [
              const Icon(Icons.groups_outlined, size: 17, color: AdminColors.gold),
              const SizedBox(width: 9),
              Expanded(
                  child: Text(
                      'Notifies members & event entrants, and appears in your '
                      'community feed where members like & comment',
                      style: AdminText.small(AdminColors.ink))),
            ]),
          ),
          const SizedBox(height: 14),
          Text('Title', style: AdminText.strong(AdminColors.inkSoft)),
          const SizedBox(height: 7),
          _field(titleC, hint: 'e.g. New tournament this weekend'),
          const SizedBox(height: 14),
          Text('Message', style: AdminText.strong(AdminColors.inkSoft)),
          const SizedBox(height: 7),
          _field(bodyC, hint: 'What do you want them to know?', maxLines: 4),
          const SizedBox(height: 14),
          Text('Photo (optional)', style: AdminText.strong(AdminColors.inkSoft)),
          const SizedBox(height: 7),
          _photoBox(
            imgBytes,
            onPick: () async {
              final f = await ImagePicker().pickImage(source: ImageSource.gallery);
              if (f == null) return;
              final b = await f.readAsBytes();
              setSheet(() {
                imgBytes = b;
                imgExt = f.name.contains('.')
                    ? f.name.split('.').last.toLowerCase()
                    : 'jpg';
              });
            },
            onClear: () => setSheet(() => imgBytes = null),
          ),
        ]);
      }),
    );
  }

  Widget _photoBox(Uint8List? bytes,
      {required VoidCallback onPick, required VoidCallback onClear}) {
    if (bytes != null) {
      return Stack(children: [
        ClipRRect(
          borderRadius: AdminUI.fieldR,
          child: Image.memory(bytes,
              width: double.infinity, height: 170, fit: BoxFit.cover),
        ),
        Positioned(
          top: 8,
          right: 8,
          child: GestureDetector(
            onTap: onClear,
            child: Container(
              padding: const EdgeInsets.all(5),
              decoration:
                  const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
              child: const Icon(Icons.close_rounded, size: 18, color: Colors.white),
            ),
          ),
        ),
      ]);
    }
    return GestureDetector(
      onTap: onPick,
      child: Container(
        height: 92,
        decoration: BoxDecoration(
          color: AdminColors.surfaceAlt,
          borderRadius: AdminUI.fieldR,
          border: Border.all(color: AdminColors.line),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.add_photo_alternate_outlined,
              size: 24, color: AdminColors.inkSoft),
          const SizedBox(height: 5),
          Text('Add a photo', style: AdminText.small()),
        ]),
      ),
    );
  }

  Widget _field(TextEditingController c, {String? hint, int maxLines = 1}) =>
      TextField(
        controller: c,
        maxLines: maxLines,
        style: AdminText.body(),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: AdminText.body(AdminColors.inkFaint),
          filled: true,
          fillColor: AdminColors.surfaceAlt,
          contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
          enabledBorder: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide: const BorderSide(color: AdminColors.line)),
          focusedBorder: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide: const BorderSide(color: AdminColors.primary, width: 1.6)),
        ),
      );

  Widget _emptyState() => Padding(
        padding: const EdgeInsets.only(top: 60),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 56, height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: AdminColors.surfaceAlt, borderRadius: BorderRadius.circular(16)),
            child: const Icon(Icons.notifications_outlined, size: 26, color: AdminColors.inkFaint),
          ),
          const SizedBox(height: 14),
          Text('No broadcasts yet', style: AdminText.h2()),
          const SizedBox(height: 6),
          Text(
              _isOrganizer
                  ? 'Tap + New to message your community.'
                  : 'Tap + New to send a message to all players.',
              style: AdminText.small()),
        ]),
      );
}

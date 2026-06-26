import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';
import '../data/admin_service.dart';

class AdminBroadcastsScreen extends StatefulWidget {
  const AdminBroadcastsScreen({super.key});
  @override
  State<AdminBroadcastsScreen> createState() => _AdminBroadcastsScreenState();
}

class _AdminBroadcastsScreenState extends State<AdminBroadcastsScreen> {
  List<Map<String, dynamic>> _broadcasts = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await AdminService.fetchBroadcasts();
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
    final tc = _targetColor(target);
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
              child: Text('To: ${target[0].toUpperCase()}${target.substring(1)}',
                  style: AdminText.sans(11, FontWeight.w700, tc)),
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
        ]),
      ),
    );
  }

  void _compose() {
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
          Text('Tap + New to send a message to all players.',
              style: AdminText.small()),
        ]),
      );
}

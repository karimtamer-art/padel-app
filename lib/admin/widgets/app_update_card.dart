import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/admin_colors.dart';
import '../data/admin_service.dart';
import '../../app_version.dart';
import 'admin_kit.dart';

/// The half of the update prompt a store cannot answer.
///
/// **Nothing here needs touching at release time.** "A new version is out" is
/// asked of the stores themselves — Play's in-app update service on Android,
/// Apple's public lookup on iOS — so shipping a release is all it takes for
/// players to be nudged. See `AppUpdateService`.
///
/// What is left is the judgement no store can make: **minimum build**, which
/// locks anyone below it out of the app entirely. Reserve it for a build that
/// is genuinely broken against the server. Plus two bits of copy: the message
/// shown on both screens, and a store link override for the day a listing
/// moves — editable here precisely because fixing it must not require shipping
/// the very release nobody can install.
class AppUpdateCard extends StatefulWidget {
  const AppUpdateCard({super.key});

  @override
  State<AppUpdateCard> createState() => _AppUpdateCardState();
}

/// One platform's row, and the keys it reads/writes. Mirrors
/// `AppUpdateService.keysFor` in the player app — change one, change both.
class _Platform {
  final String key; // 'android' | 'ios'
  final String label;
  final String source; // how "a new version exists" is detected there
  final IconData icon;
  const _Platform(this.key, this.label, this.source, this.icon);

  String get minKey => 'update_min_build_$key';
  String get storeKey => 'store_url_$key';
}

const _platforms = <_Platform>[
  _Platform('android', 'Android · Play Store', 'Play tells the app itself',
      Icons.android_rounded),
  _Platform('ios', 'iPhone · App Store', 'Read from the App Store listing',
      Icons.phone_iphone_rounded),
];

const _messageKey = 'update_message';

class _AppUpdateCardState extends State<AppUpdateCard> {
  final Map<String, String> _s = {}; // every key above, '' when unset
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final keys = <String>[
      _messageKey,
      for (final p in _platforms) ...[p.minKey, p.storeKey],
    ];
    final values = await Future.wait(keys.map(AdminService.getSetting));
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < keys.length; i++) {
        _s[keys[i]] = (values[i] ?? '').trim();
      }
      _loading = false;
    });
  }

  String _v(String key) => _s[key] ?? '';

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      AdminSection('App update',
          sub: 'Ships automatically · this console is $appVersionLong'),
      AdminCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Row(children: [
              const Icon(Icons.auto_awesome_rounded,
                  size: 15, color: AdminColors.green),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                    'Players are told about a new version as soon as the store '
                    'has it. Nothing to set here when you release.',
                    style: AdminText.small(AdminColors.inkSoft)),
              ),
            ]),
          ),
          for (final p in _platforms) ...[
            const Divider(height: 13, color: AdminColors.lineSoft),
            _row(p),
          ],
        ]),
      ),
      const SizedBox(height: 14),
    ]);
  }

  Widget _row(_Platform p) {
    final min = _v(p.minKey);
    final sub = min.isEmpty
        ? '${p.source} · nobody is blocked'
        : '${p.source} · blocks below build $min';
    return InkWell(
      onTap: _loading ? null : () => _edit(p),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: AdminColors.wash(AdminColors.primary, 0.12),
                borderRadius: BorderRadius.circular(9)),
            child: Icon(p.icon, size: 19, color: AdminColors.primary),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.label, style: AdminText.strong()),
              const SizedBox(height: 3),
              Text(_loading ? 'Loading…' : sub,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AdminText.small(
                      min.isEmpty ? AdminColors.inkSoft : AdminColors.warn)),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded,
              size: 20, color: AdminColors.inkFaint),
        ]),
      ),
    );
  }

  Future<void> _edit(_Platform p) async {
    final min = TextEditingController(text: _v(p.minKey));
    final store = TextEditingController(text: _v(p.storeKey));
    final message = TextEditingController(text: _v(_messageKey));

    final saved = await adminSheet<bool>(
      context,
      title: p.label,
      sub: p.source,
      heightFactor: 0.82,
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _field('MINIMUM BUILD', min,
            hint: 'blank = nobody is blocked',
            digits: true,
            danger: true,
            note: 'Below this the app will not open at all — it shows an update '
                'screen with no way past. Only for a build that is genuinely '
                'broken, and never above a build that is actually live on this '
                'store. Everything else about updating is automatic; this is '
                'the one number nobody can work out for you.'),
        _field('STORE LINK', store,
            hint: p.key == 'android'
                ? 'https://play.google.com/store/apps/details?id=…'
                : 'https://apps.apple.com/app/id…',
            note: "Blank uses the app's own listing, which is what you want "
                'unless it has moved.'),
        _field('MESSAGE (OPTIONAL)', message,
            hint: "What's new in this version",
            lines: 3,
            note: 'Shared by both platforms and by both screens. Blank uses the '
                'default wording. Clear it when the release it describes is '
                'old — it is not tied to a version.'),
      ]),
      footer: Builder(
        builder: (ctx) => AdminButton('Save',
            full: true,
            height: 48,
            icon: Icons.check_rounded,
            onPressed: () => Navigator.pop(ctx, true)),
      ),
    );
    if (saved != true || !mounted) return;

    final next = <String, String>{
      p.minKey: _digits(min.text),
      p.storeKey: store.text.trim(),
      _messageKey: message.text.trim(),
    };

    // The mistake that costs everybody the app: a minimum above what is
    // actually on the store. Nothing here can check that against Play or
    // Apple, so say the number out loud and make it a deliberate answer.
    final minBuild = int.tryParse(next[p.minKey]!);
    if (minBuild != null && minBuild != int.tryParse(_v(p.minKey))) {
      final go = await _confirmLockout(p, minBuild);
      if (go != true || !mounted) return;
    }

    String? err;
    for (final e in next.entries) {
      err ??= await AdminService.setSetting(e.key, e.value);
    }
    if (!mounted) return;
    if (err != null) {
      adminToast(context, err, ok: false);
      return;
    }
    setState(() => _s.addAll(next));
    adminToast(context, 'Update settings saved');
  }

  Future<bool?> _confirmLockout(_Platform p, int minBuild) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AdminColors.surface,
          title: Text('Block builds below $minBuild?', style: AdminText.h2()),
          content: Text(
            'Every ${p.label.split(' · ').first} player on a build below '
            '$minBuild will be locked out of the app until they update — they '
            'will not be able to sign in at all. This console is build '
            '$kAppBuild. If $minBuild is not actually live on the store yet, '
            'nobody will be able to get in.',
            style: AdminText.body(AdminColors.inkSoft),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child:
                    Text('Cancel', style: AdminText.strong(AdminColors.inkSoft))),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('Block anyway',
                    style: AdminText.strong(AdminColors.danger))),
          ],
        ),
      );

  static String _digits(String raw) =>
      raw.replaceAll(RegExp(r'[^0-9]'), '').replaceFirst(RegExp(r'^0+(?=.)'), '');

  Widget _field(String label, TextEditingController ctrl,
      {String hint = '',
      String note = '',
      bool digits = false,
      bool danger = false,
      int lines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: AdminText.kicker(
                danger ? AdminColors.danger : AdminColors.inkFaint)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
              color: AdminColors.surfaceAlt,
              borderRadius: AdminUI.fieldR,
              border: Border.all(
                  color: danger
                      ? AdminColors.wash(AdminColors.danger, 0.35)
                      : AdminColors.line)),
          child: TextField(
            controller: ctrl,
            maxLines: lines,
            keyboardType: digits ? TextInputType.number : TextInputType.text,
            inputFormatters:
                digits ? [FilteringTextInputFormatter.digitsOnly] : null,
            style: digits
                ? AdminText.mono(14, FontWeight.w700, AdminColors.ink)
                : AdminText.sans(13.5, FontWeight.w600, AdminColors.ink),
            decoration: InputDecoration.collapsed(hintText: hint),
          ),
        ),
        if (note.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(note,
              style: AdminText.small(
                  danger ? AdminColors.danger : AdminColors.inkFaint)),
        ],
      ]),
    );
  }
}

import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../theme/admin_colors.dart';
import '../data/admin_service.dart';
import '../widgets/admin_kit.dart';

/// Sponsors / partners console — what players see on the "Our Partners" page.
///
/// Display only. Sponsorship money that actually changes hands is recorded in
/// Reports → money in (category "Sponsorship"); nothing here touches the P&L,
/// on purpose, so a deal is never counted twice.
class AdminSponsorsScreen extends StatefulWidget {
  const AdminSponsorsScreen({super.key});
  @override
  State<AdminSponsorsScreen> createState() => _AdminSponsorsScreenState();
}

class _AdminSponsorsScreenState extends State<AdminSponsorsScreen> {
  List<Map<String, dynamic>> _sponsors = [];
  bool _loading = true;

  static final ImagePicker _picker = ImagePicker();

  /// Tier id → (label, colour). Order matters: it's the order players see, and
  /// the ids mirror `sponsors_tier_chk` in the migration.
  static const _tiers = <(String, String, Color)>[
    ('title', 'Title Partner', AdminColors.primary),
    ('gold', 'Gold Partner', AdminColors.gold),
    ('silver', 'Silver Partner', AdminColors.inkSoft),
    ('partner', 'Partner', AdminColors.green),
  ];

  static (String, String, Color) _tierSpec(String? id) =>
      _tiers.firstWhere((t) => t.$1 == id, orElse: () => _tiers.last);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_loading) setState(() => _loading = true);
    final rows = await AdminService.fetchSponsors();
    if (!mounted) return;
    setState(() {
      _sponsors = rows;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final total = _sponsors.length;
    final live = _sponsors.where((s) => s['is_active'] != false).length;
    final title = _sponsors.where((s) => s['tier'] == 'title').length;
    final noLogo = _sponsors
        .where((s) => (s['logo_url'] as String?)?.trim().isNotEmpty != true)
        .length;

    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
        children: [
          KpiGrid([
            StatCard(
                icon: Icons.handshake_outlined,
                tone: AdminColors.primary,
                label: 'Partners',
                value: '$total'),
            StatCard(
                icon: Icons.visibility_outlined,
                tone: AdminColors.green,
                label: 'Live in app',
                value: '$live'),
            StatCard(
                icon: Icons.workspace_premium_outlined,
                tone: AdminColors.gold,
                label: 'Title partners',
                value: '$title'),
            StatCard(
                icon: Icons.image_not_supported_outlined,
                tone: noLogo > 0 ? AdminColors.warn : AdminColors.inkFaint,
                label: 'Missing logo',
                value: '$noLogo'),
          ]),
          const SizedBox(height: 16),
          AdminSection(
            'Sponsors',
            sub: 'Shown to players on Home → Our Partners',
            action: AdminButton('Add',
                icon: Icons.add_rounded, height: 34, onPressed: () => _form(null)),
          ),
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AdminColors.primary),
              ),
            )
          else if (_sponsors.isEmpty)
            _emptyState()
          else ...[
            for (final s in _sponsors) _card(s),
            const SizedBox(height: 8),
            _moneyNote(),
          ],
        ],
      ),
    );
  }

  Widget _emptyState() => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: AdminCard(
          child: Column(children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: AdminColors.wash(AdminColors.primary, 0.12),
                  borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.handshake_outlined,
                  size: 24, color: AdminColors.primary),
            ),
            const SizedBox(height: 12),
            Text('No partners yet', style: AdminText.cardTitle()),
            const SizedBox(height: 3),
            Text(
                'Add one and it appears on the players\' Our Partners page. '
                'The whole section stays hidden while this is empty.',
                textAlign: TextAlign.center,
                style: AdminText.small()),
          ]),
        ),
      );

  Widget _moneyNote() => AdminCard(
        color: AdminColors.surfaceAlt,
        padding: const EdgeInsets.all(13),
        child: Row(children: [
          const Icon(Icons.info_outline_rounded,
              size: 17, color: AdminColors.inkSoft),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
                'This page is the shop window only. Record what a sponsor '
                'actually paid in Reports → money in, category "Sponsorship".',
                style: AdminText.small().copyWith(height: 1.45)),
          ),
        ]),
      );

  Widget _card(Map<String, dynamic> row) {
    final active = row['is_active'] != false;
    final spec = _tierSpec(row['tier'] as String?);
    final logo = (row['logo_url'] as String?)?.trim();
    final site = (row['website_url'] as String?)?.trim();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Opacity(
        opacity: active ? 1 : 0.72,
        child: AdminCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              _logo(row, spec.$3),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text((row['name'] as String?) ?? '—',
                          style: AdminText.cardTitle().copyWith(fontSize: 15),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 3),
                      Text((row['tagline'] as String?)?.trim().isNotEmpty == true
                              ? row['tagline'] as String
                              : spec.$2,
                          style: AdminText.small(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ]),
              ),
              const SizedBox(width: 8),
              StatusBadge(active ? 'active' : 'hidden', dot: true),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 6, runSpacing: 6, children: [
              _tag(Icons.workspace_premium_outlined, spec.$2, spec.$3),
              _tag(Icons.sort_rounded, 'Order ${row['sort_order'] ?? 0}', null),
              if (site != null && site.isNotEmpty)
                _tag(Icons.link_rounded, _host(site), null),
            ]),
            if (logo == null || logo.isEmpty) ...[
              const SizedBox(height: 10),
              Row(children: [
                const Icon(Icons.warning_amber_rounded,
                    size: 13, color: AdminColors.warn),
                const SizedBox(width: 5),
                Expanded(
                  child: Text('No logo — players see the initials instead',
                      style:
                          AdminText.sans(11.5, FontWeight.w600, AdminColors.warn)),
                ),
              ]),
            ],
            const Divider(height: 22, color: AdminColors.lineSoft),
            Row(children: [
              Expanded(
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  _pill(active ? 'Hide from app' : 'Show in app',
                      () => _toggleActive(row)),
                ]),
              ),
              const SizedBox(width: 8),
              _iconBtn(Icons.edit_outlined, () => _form(row)),
              const SizedBox(width: 8),
              _iconBtn(Icons.delete_outline_rounded, () => _remove(row)),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _logo(Map<String, dynamic> row, Color tone) {
    final url = (row['logo_url'] as String?)?.trim();
    final name = ((row['name'] as String?) ?? '?').trim();
    final parts = name.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    final initials = parts.isEmpty
        ? '?'
        : parts.length == 1
            ? parts.first[0].toUpperCase()
            : (parts.first[0] + parts[1][0]).toUpperCase();
    final fallback = Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
          color: AdminColors.wash(tone, 0.14),
          borderRadius: BorderRadius.circular(11)),
      child: Text(initials, style: AdminText.sans(15, FontWeight.w800, tone)),
    );
    if (url == null || url.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(11),
      child: Image.network(url,
          width: 44,
          height: 44,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => fallback),
    );
  }

  /// Bare host for the link chip — the full URL never fits.
  static String _host(String url) {
    final u = Uri.tryParse(
        url.startsWith('http') ? url : 'https://$url');
    final h = u?.host ?? url;
    return h.startsWith('www.') ? h.substring(4) : h;
  }

  Widget _tag(IconData icon, String text, Color? tone) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: AdminColors.surfaceAlt,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AdminColors.lineSoft)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 11, color: tone ?? AdminColors.inkSoft),
          const SizedBox(width: 4),
          Text(text,
              style: AdminText.sans(
                  11, FontWeight.w600, tone ?? AdminColors.inkSoft)),
        ]),
      );

  Widget _pill(String label, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
              color: AdminColors.surfaceAlt,
              borderRadius: BorderRadius.circular(9)),
          child: Text(label,
              style: AdminText.sans(12.5, FontWeight.w700, AdminColors.ink)),
        ),
      );

  Widget _iconBtn(IconData icon, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: AdminColors.surface,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: AdminColors.line)),
          child: Icon(icon, size: 15, color: AdminColors.ink),
        ),
      );

  Future<void> _toggleActive(Map<String, dynamic> row) async {
    final show = row['is_active'] == false;
    await AdminService.setSponsorActive(row['id'] as String, show);
    await _load();
    if (mounted) {
      adminToast(context, show ? 'Now live in the app' : 'Hidden from players');
    }
  }

  void _remove(Map<String, dynamic> row) {
    final name = (row['name'] as String?) ?? 'This partner';
    adminSheet(
      context,
      title: 'Remove partner?',
      sub: name,
      heightFactor: 0.4,
      footer: Row(children: [
        Expanded(
          child: AdminButton(
            'Remove',
            height: 48,
            variant: AdminBtn.danger,
            icon: Icons.delete_outline_rounded,
            onPressed: () async {
              Navigator.pop(context);
              await AdminService.deleteSponsor(row['id'] as String);
              await _load();
              if (!mounted) return;
              adminToast(context, '"$name" removed');
            },
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: AdminButton('Cancel',
              height: 48,
              variant: AdminBtn.ghost,
              onPressed: () => Navigator.pop(context)),
        ),
      ]),
      body: Text(
        'This deletes "$name" for good. To take it off the page for now '
        'without losing the details, use "Hide from app" instead.',
        style: AdminText.body().copyWith(height: 1.6),
      ),
    );
  }

  // ── Add / edit ───────────────────────────────────────────────────────────

  void _form(Map<String, dynamic>? row) {
    final isNew = row == null;
    final nameCt = TextEditingController(text: row?['name'] ?? '');
    final taglineCt = TextEditingController(text: row?['tagline'] ?? '');
    final blurbCt = TextEditingController(text: row?['blurb'] ?? '');
    final siteCt = TextEditingController(text: row?['website_url'] ?? '');
    final orderCt =
        TextEditingController(text: '${(row?['sort_order'] as num?)?.toInt() ?? 0}');
    final tier = ValueNotifier<String>((row?['tier'] as String?) ?? 'partner');
    final logo = ValueNotifier<String?>(row?['logo_url'] as String?);
    final active = ValueNotifier<bool>(row?['is_active'] != false);
    final busy = ValueNotifier<bool>(false);

    adminSheet(
      context,
      title: isNew ? 'Add partner' : 'Edit partner',
      sub: isNew
          ? 'Appears on the players\' Our Partners page'
          : ((row['name'] as String?) ?? ''),
      heightFactor: 0.92,
      footer: ValueListenableBuilder<bool>(
        valueListenable: busy,
        builder: (_, isBusy, __) => AdminButton(
          isNew ? 'Add partner' : 'Save changes',
          full: true,
          height: 50,
          icon: Icons.check_rounded,
          onPressed: isBusy
              ? null
              : () async {
                  if (nameCt.text.trim().isEmpty) {
                    adminToast(context, 'Give the partner a name', ok: false);
                    return;
                  }
                  Navigator.pop(context);
                  final err = await AdminService.saveSponsor(
                    id: isNew ? null : row['id'] as String,
                    name: nameCt.text,
                    tagline: taglineCt.text,
                    blurb: blurbCt.text,
                    logoUrl: logo.value,
                    websiteUrl: siteCt.text,
                    tier: tier.value,
                    isActive: active.value,
                    sortOrder: int.tryParse(orderCt.text.trim()) ?? 0,
                  );
                  await _load();
                  if (!mounted) return;
                  adminToast(
                      context,
                      err ?? (isNew ? 'Partner added' : 'Partner updated'),
                      ok: err == null);
                },
        ),
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ValueListenableBuilder<String?>(
          valueListenable: logo,
          builder: (ctx, url, __) => ValueListenableBuilder<bool>(
            valueListenable: busy,
            builder: (_, isBusy, ___) =>
                _logoPicker(ctx, url, isBusy, logo, busy),
          ),
        ),
        const SizedBox(height: 18),
        _field('Name', nameCt, hint: 'e.g. Head Egypt'),
        const SizedBox(height: 14),
        _field('Tagline', taglineCt,
            hint: 'One line shown under the name (optional)'),
        const SizedBox(height: 14),
        _field('About', blurbCt,
            maxLines: 4,
            hint: 'Longer copy, shown when a player taps the partner (optional)'),
        const SizedBox(height: 14),
        _field('Website', siteCt, hint: 'e.g. head.com — https:// is added for you'),
        const SizedBox(height: 18),
        Text('Tier', style: AdminText.strong(AdminColors.inkSoft)),
        const SizedBox(height: 8),
        ValueListenableBuilder<String>(
          valueListenable: tier,
          builder: (_, current, __) => Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in _tiers)
                _tierChip(t, selected: t.$1 == current, onTap: () => tier.value = t.$1),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
            'Title partners get a full-width feature card at the top of the '
            'page; the rest are listed under "Supported by".',
            style: AdminText.small(AdminColors.inkFaint)),
        const SizedBox(height: 16),
        _field('Sort order', orderCt,
            hint: 'Lower shows first, within the tier'),
        const SizedBox(height: 16),
        ValueListenableBuilder<bool>(
          valueListenable: active,
          builder: (_, on, __) => _check(
              'Live in the app', on, () => active.value = !on),
        ),
      ]),
    );
  }

  Widget _tierChip((String, String, Color) t,
          {required bool selected, required VoidCallback onTap}) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? AdminColors.wash(t.$3, 0.16) : AdminColors.surfaceAlt,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: selected ? t.$3 : AdminColors.line,
                width: selected ? 1.6 : 1),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.workspace_premium_outlined,
                size: 13, color: selected ? t.$3 : AdminColors.inkFaint),
            const SizedBox(width: 6),
            Text(t.$2,
                style: AdminText.sans(12.5, FontWeight.w700,
                    selected ? t.$3 : AdminColors.inkSoft)),
          ]),
        ),
      );

  Widget _logoPicker(BuildContext ctx, String? url, bool busy,
      ValueNotifier<String?> logo, ValueNotifier<bool> busyFlag) {
    return Row(children: [
      Container(
        width: 76,
        height: 76,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AdminColors.surfaceAlt,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AdminColors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AdminColors.primary))
            : (url == null || url.isEmpty)
                ? const Icon(Icons.image_outlined,
                    size: 24, color: AdminColors.inkFaint)
                : Image.network(url,
                    width: 76,
                    height: 76,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(
                        Icons.broken_image_outlined,
                        size: 24,
                        color: AdminColors.inkFaint)),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Logo', style: AdminText.strong(AdminColors.inkSoft)),
          const SizedBox(height: 3),
          Text('Square works best. Without one, players see the initials.',
              style: AdminText.small(AdminColors.inkFaint)),
          const SizedBox(height: 9),
          Row(children: [
            AdminButton(url == null ? 'Upload' : 'Replace',
                height: 34,
                variant: AdminBtn.soft,
                icon: Icons.upload_rounded,
                onPressed: busy ? null : () => _pickLogo(logo, busyFlag)),
            if (url != null) ...[
              const SizedBox(width: 8),
              AdminButton('Remove',
                  height: 34,
                  variant: AdminBtn.danger,
                  onPressed: busy ? null : () => logo.value = null),
            ],
          ]),
        ]),
      ),
    ]);
  }

  Future<void> _pickLogo(
      ValueNotifier<String?> logo, ValueNotifier<bool> busy) async {
    final f = await _picker.pickImage(source: ImageSource.gallery);
    if (f == null) return;
    busy.value = true;
    try {
      final Uint8List bytes = await f.readAsBytes();
      final ext =
          f.name.contains('.') ? f.name.split('.').last.toLowerCase() : 'jpg';
      logo.value = await AdminService.uploadSponsorLogo(bytes, ext);
    } catch (e) {
      if (mounted) adminToast(context, "Couldn't upload that image", ok: false);
    } finally {
      busy.value = false;
    }
  }

  Widget _check(String label, bool on, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Row(children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: on ? AdminColors.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                  color: on ? AdminColors.primary : AdminColors.line, width: 1.6),
            ),
            alignment: Alignment.center,
            child: on
                ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
                : null,
          ),
          const SizedBox(width: 10),
          Text(label, style: AdminText.body()),
        ]),
      );

  Widget _field(String label, TextEditingController c,
      {String? hint, int maxLines = 1}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: AdminText.strong(AdminColors.inkSoft)),
      const SizedBox(height: 7),
      TextField(
        controller: c,
        style: AdminText.body(),
        maxLines: maxLines,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: AdminColors.surfaceAlt,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
          enabledBorder: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide: const BorderSide(color: AdminColors.line)),
          focusedBorder: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide:
                  const BorderSide(color: AdminColors.primary, width: 1.6)),
        ),
      ),
      if (hint != null) ...[
        const SizedBox(height: 5),
        Text(hint, style: AdminText.small(AdminColors.inkFaint))
      ],
    ]);
  }
}

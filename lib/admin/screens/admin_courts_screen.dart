import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/admin_colors.dart';
import '../data/admin_service.dart';
import '../widgets/admin_kit.dart';

class AdminCourtsScreen extends StatefulWidget {
  /// When set, the screen is scoped to one organizer's own courts (they add
  /// their own, private to their community). When null, it's the super-admin
  /// view of ALL courts, with the publish toggle.
  final String? organizerId;
  const AdminCourtsScreen({super.key, this.organizerId});
  @override
  State<AdminCourtsScreen> createState() => _AdminCourtsScreenState();
}

class _AdminCourtsScreenState extends State<AdminCourtsScreen> {
  List<Map<String, dynamic>> _courts = [];
  bool _loading = true;

  bool get _isOrganizer => widget.organizerId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_loading) setState(() => _loading = true);
    final data = await AdminService.fetchCourts(ownerId: widget.organizerId);
    if (!mounted) return;
    setState(() {
      _courts = data;
      _loading = false;
    });
  }

  static String _status(Map row) {
    if (row['in_maintenance'] == true) return 'maintenance';
    if (row['is_active'] != true) return 'hidden';
    return 'active';
  }

  static String _egp(dynamic n) =>
      n == null ? '—' : 'EGP ${(n as num).toInt()}';

  @override
  Widget build(BuildContext context) {
    final total = _courts.length;
    final active = _courts.where((c) => _status(c) == 'active').length;
    final maint = _courts.where((c) => c['in_maintenance'] == true).length;
    final indoor = _courts.where((c) => c['indoor'] == true).length;

    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
        children: [
          KpiGrid([
            StatCard(icon: Icons.grid_view_rounded, tone: AdminColors.primary, label: 'Total courts', value: '$total'),
            StatCard(icon: Icons.check_circle_outline_rounded, tone: AdminColors.green, label: 'Active', value: '$active'),
            StatCard(icon: Icons.build_outlined, tone: AdminColors.warn, label: 'Maintenance', value: '$maint'),
            StatCard(icon: Icons.home_outlined, tone: AdminColors.info, label: 'Indoor', value: '$indoor'),
          ]),
          const SizedBox(height: 16),
          AdminSection(
            _isOrganizer ? 'Your Courts' : 'Courts',
            sub: _isOrganizer
                ? 'Private to your community until published'
                : '$total court${total != 1 ? 's' : ''}',
            action: AdminButton('Add', icon: Icons.add_rounded, height: 34, onPressed: _add),
          ),
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: CircularProgressIndicator(strokeWidth: 2, color: AdminColors.primary),
              ),
            )
          else if (_courts.isEmpty)
            Container(
              margin: const EdgeInsets.only(top: 24),
              padding: const EdgeInsets.all(28),
              alignment: Alignment.center,
              child: Text('No courts yet — tap Add to create one',
                  style: AdminText.small(AdminColors.inkFaint)),
            )
          else
            for (final c in _courts) _card(c),
        ],
      ),
    );
  }

  Widget _card(Map<String, dynamic> row) {
    final status = _status(row);
    final maint = status == 'maintenance';
    final hidden = status == 'hidden';
    final iconTone = maint
        ? AdminColors.warn
        : hidden
            ? AdminColors.inkFaint
            : AdminColors.primary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Opacity(
        opacity: (maint || hidden) ? 0.82 : 1,
        child: AdminCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: AdminColors.wash(iconTone, 0.14),
                    borderRadius: BorderRadius.circular(10)),
                child: Icon(
                    maint ? Icons.build_outlined : Icons.sports_tennis_rounded,
                    size: 19,
                    color: iconTone),
              ),
              const Spacer(),
              _visibilityPill(row),
              const SizedBox(width: 6),
              StatusBadge(status, dot: true),
            ]),
            const SizedBox(height: 12),
            Text(row['venue_name'] ?? '—',
                style: AdminText.cardTitle().copyWith(fontSize: 15)),
            const SizedBox(height: 2),
            Text(
              '${row['name'] ?? ''}${(row['area'] as String?)?.isNotEmpty == true ? ' · ${row['area']}' : ''} · ${row['indoor'] == true ? 'Indoor' : 'Outdoor'}',
              style: AdminText.small(),
            ),
            // Which community this court belongs to (admin view of organizer courts).
            if (!_isOrganizer && (row['owner_label'] as String?)?.isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Row(children: [
                const Icon(Icons.groups_2_rounded, size: 13, color: AdminColors.gold),
                const SizedBox(width: 5),
                Expanded(
                  child: Text('${row['owner_label']} community',
                      style: AdminText.sans(12, FontWeight.w700, AdminColors.gold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
              ]),
            ],
            const SizedBox(height: 12),
            Wrap(spacing: 6, runSpacing: 6, children: [
              _tag(Icons.payments_outlined, '${_egp(row['price_per_hour'])}/hr'),
              if ((row['city'] as String?)?.isNotEmpty == true)
                _tag(Icons.place_outlined, row['city'] as String),
            ]),
            const Divider(height: 22, color: AdminColors.lineSoft),
            Row(children: [
              Expanded(
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  _pill(maint ? 'Reactivate' : 'Maintenance', () => _toggleMaintenance(row)),
                  _pill(hidden ? 'Show venue' : 'Hide venue', () => _toggleActive(row)),
                  if (!_isOrganizer)
                    _pill(row['is_public'] != false ? 'Make private' : 'Publish to all',
                        () => _togglePublic(row)),
                ]),
              ),
              const SizedBox(width: 8),
              _iconBtn(Icons.edit_outlined, () => _edit(row)),
              const SizedBox(width: 8),
              _iconBtn(Icons.delete_outline_rounded, () => _remove(row)),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _pill(String label, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
              color: AdminColors.surfaceAlt, borderRadius: BorderRadius.circular(9)),
          child: Text(label,
              style: AdminText.sans(12.5, FontWeight.w700, AdminColors.ink)),
        ),
      );

  Future<void> _toggleActive(Map<String, dynamic> row) async {
    final show = row['is_active'] != true; // currently hidden → show
    await AdminService.organizerSetCourtActive(row['id'] as String, show);
    await _load();
    if (mounted) {
      adminToast(context, show ? 'Court shown as a venue' : 'Court hidden');
    }
  }

  Widget _visibilityPill(Map row) {
    final isPublic = row['is_public'] != false; // null/absent → public (default)
    final tone = isPublic ? AdminColors.green : AdminColors.gold;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
          color: AdminColors.wash(tone, 0.14),
          borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(isPublic ? Icons.public_rounded : Icons.groups_2_rounded,
            size: 11, color: tone),
        const SizedBox(width: 4),
        Text(isPublic ? 'Public' : 'Community',
            style: AdminText.sans(10.5, FontWeight.w700, tone)),
      ]),
    );
  }

  Future<void> _togglePublic(Map<String, dynamic> row) async {
    final makePublic = row['is_public'] == false; // currently private → publish
    await AdminService.setCourtPublic(row['id'] as String, makePublic);
    await _load();
    if (mounted) {
      adminToast(context,
          makePublic ? 'Court published to all players' : 'Court set to community-only');
    }
  }

  Widget _tag(IconData? icon, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: AdminColors.surfaceAlt,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AdminColors.lineSoft)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: AdminColors.inkSoft),
            const SizedBox(width: 4)
          ],
          Text(text, style: AdminText.sans(11, FontWeight.w600, AdminColors.inkSoft)),
        ]),
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

  Future<void> _toggleMaintenance(Map<String, dynamic> row) async {
    final current = row['in_maintenance'] == true;
    final id = row['id'] as String;
    if (_isOrganizer) {
      await AdminService.organizerSetCourtMaintenance(id, !current);
    } else {
      await Supabase.instance.client
          .from('courts')
          .update({'in_maintenance': !current})
          .eq('id', id);
    }
    await _load();
  }

  void _remove(Map<String, dynamic> row) {
    final name = (row['venue_name'] as String?) ?? 'Court';
    adminSheet(
      context,
      title: 'Remove court?',
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
              final id = row['id'] as String;
              String? err;
              if (_isOrganizer) {
                err = await AdminService.organizerDeleteCourt(id);
              } else {
                await AdminService.deleteCourt(id);
              }
              await _load();
              if (!mounted) return;
              adminToast(context, err ?? '"$name" removed', ok: err == null);
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
        'This will hide "$name" from the venue list when players create a match.',
        style: AdminText.body().copyWith(height: 1.6),
      ),
    );
  }

  void _add() => _form(null);
  void _edit(Map<String, dynamic> row) => _form(row);

  void _form(Map<String, dynamic>? row) {
    final isNew = row == null;
    final venueCt = TextEditingController(text: row?['venue_name'] ?? '');
    final nameCt = TextEditingController(text: row?['name'] ?? '');
    final areaCt = TextEditingController(text: row?['area'] ?? '');
    final cityCt = TextEditingController(text: row?['city'] ?? '');
    final priceCt =
        TextEditingController(text: row?['price_per_hour']?.toString() ?? '');
    final indoor = ValueNotifier<bool>(row?['indoor'] == true);

    adminSheet(
      context,
      title: isNew ? 'Add court' : 'Edit court',
      sub: isNew
          ? (_isOrganizer
              ? 'New court — private to your community'
              : 'New court — visible in the app')
          : ((row['venue_name'] as String?) ?? ''),
      heightFactor: 0.9,
      footer: ValueListenableBuilder<bool>(
        valueListenable: indoor,
        builder: (_, v, __) => AdminButton(
          isNew ? 'Add court' : 'Save changes',
          full: true,
          height: 50,
          icon: Icons.check_rounded,
          onPressed: () async {
            if (venueCt.text.trim().isEmpty) return;
            Navigator.pop(context);
            String? err;
            if (_isOrganizer) {
              // Organizers write via a SECURITY DEFINER RPC (RLS blocks direct
              // writes); it stamps owner + community-only visibility.
              err = await AdminService.organizerSaveCourt(
                id: isNew ? null : row['id'] as String,
                venue: venueCt.text.trim(),
                name: nameCt.text.trim(),
                area: areaCt.text.trim(),
                city: cityCt.text.trim(),
                price: num.tryParse(priceCt.text),
                indoor: v,
              );
            } else if (isNew) {
              try {
                await Supabase.instance.client.from('courts').insert({
                  'venue_name': venueCt.text.trim(),
                  'name': nameCt.text.trim().isEmpty ? 'Court' : nameCt.text.trim(),
                  'area': areaCt.text.trim(),
                  'city': cityCt.text.trim().isEmpty ? null : cityCt.text.trim(),
                  'price_per_hour': num.tryParse(priceCt.text),
                  'indoor': v,
                  'is_active': true, // new courts are shown; hide via the card
                  'in_maintenance': false,
                });
              } catch (e) {
                err = e.toString();
              }
            } else {
              try {
                await Supabase.instance.client.from('courts').update({
                  'venue_name': venueCt.text.trim(),
                  'name': nameCt.text.trim().isEmpty ? 'Court' : nameCt.text.trim(),
                  'area': areaCt.text.trim(),
                  'city': cityCt.text.trim().isEmpty ? null : cityCt.text.trim(),
                  'price_per_hour': num.tryParse(priceCt.text),
                  'indoor': v,
                  // is_active is left untouched on edit — the card's Hide/Show
                  // venue toggle controls it.
                }).eq('id', row['id'] as String);
              } catch (e) {
                err = e.toString();
              }
            }
            await _load();
            if (!mounted) return;
            adminToast(context, err ?? (isNew ? 'Court added' : 'Court updated'),
                ok: err == null);
          },
        ),
      ),
      body: ValueListenableBuilder<bool>(
        valueListenable: indoor,
        builder: (_, v, __) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _field('Venue / club name', venueCt, hint: 'e.g. Gezira Sporting Club'),
            const SizedBox(height: 14),
            _field('Court name', nameCt, hint: 'e.g. Court 1'),
            const SizedBox(height: 14),
            _field('Area', areaCt, hint: 'e.g. Zamalek'),
            const SizedBox(height: 14),
            _field('City', cityCt, hint: 'e.g. Cairo'),
            const SizedBox(height: 14),
            _field('Price / hour', priceCt, prefix: 'EGP'),
            const SizedBox(height: 16),
            _check('Indoor court', v, () => indoor.value = !v),
          ],
        ),
      ),
    );
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
      {String? hint, String? prefix}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: AdminText.strong(AdminColors.inkSoft)),
      const SizedBox(height: 7),
      TextField(
        controller: c,
        keyboardType:
            prefix != null ? TextInputType.number : TextInputType.text,
        style: AdminText.body(),
        decoration: InputDecoration(
          isDense: true,
          prefixText: prefix != null ? '$prefix ' : null,
          prefixStyle:
              AdminText.mono(12, FontWeight.w700, AdminColors.inkFaint),
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

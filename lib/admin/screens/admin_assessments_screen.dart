import 'package:flutter/cupertino.dart'
    show CupertinoDatePicker, CupertinoDatePickerMode, CupertinoButton;
import 'package:flutter/material.dart';
import '../theme/admin_colors.dart';
import '../data/admin_service.dart';
import '../widgets/admin_kit.dart';

/// Assessment centers console — the venues players can book an in-person
/// level assessment at, and the time slots they book.
///
/// A slot is one seat. Players book through `book_assessment_slot`, which
/// closes it for everyone else; the console publishes slots, deletes open
/// ones, and releases a booking (which tells the player). Nothing here sets a
/// rating — the result of an assessment goes through the existing rating tools.
class AdminAssessmentsScreen extends StatefulWidget {
  const AdminAssessmentsScreen({super.key});
  @override
  State<AdminAssessmentsScreen> createState() => _AdminAssessmentsScreenState();
}

class _AdminAssessmentsScreenState extends State<AdminAssessmentsScreen> {
  List<Map<String, dynamic>> _centers = [];
  List<Map<String, dynamic>> _slots = []; // today onwards, ascending
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_loading) setState(() => _loading = true);
    final r = await Future.wait([
      AdminService.fetchAssessmentCenters(),
      AdminService.fetchAssessmentSlots(),
    ]);
    if (!mounted) return;
    setState(() {
      _centers = r[0];
      _slots = r[1];
      _loading = false;
    });
  }

  static DateTime _start(Map<String, dynamic> s) =>
      DateTime.parse(s['starts_at'] as String).toLocal();
  static bool _booked(Map<String, dynamic> s) => s['booked_by'] != null;
  bool _future(Map<String, dynamic> s) => _start(s).isAfter(DateTime.now());

  List<Map<String, dynamic>> _slotsOf(String centerId) =>
      _slots.where((s) => s['center_id'] == centerId).toList();

  String _centerName(String? id) =>
      (_centers.firstWhere((c) => c['id'] == id,
          orElse: () => const {})['name'] as String?) ??
      'Center';

  @override
  Widget build(BuildContext context) {
    final upcoming = _slots.where(_future).toList();
    final open = upcoming.where((s) => !_booked(s)).length;
    final bookings = upcoming.where(_booked).toList();
    final now = DateTime.now();
    final today = _slots.where((s) {
      final d = _start(s);
      return _booked(s) &&
          d.year == now.year &&
          d.month == now.month &&
          d.day == now.day;
    }).length;

    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
        children: [
          KpiGrid([
            StatCard(
                icon: Icons.fact_check_outlined,
                tone: AdminColors.primary,
                label: 'Centers',
                value: '${_centers.length}'),
            StatCard(
                icon: Icons.event_available_outlined,
                tone: AdminColors.green,
                label: 'Open slots',
                value: '$open'),
            StatCard(
                icon: Icons.how_to_reg_outlined,
                tone: AdminColors.info,
                label: 'Upcoming bookings',
                value: '${bookings.length}'),
            StatCard(
                icon: Icons.today_outlined,
                tone: AdminColors.gold,
                label: 'Booked today',
                value: '$today'),
          ]),
          const SizedBox(height: 16),
          if (bookings.isNotEmpty) ...[
            const AdminSection('Upcoming bookings',
                sub: 'Who is coming, soonest first'),
            AdminCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: Column(children: [
                for (var i = 0; i < bookings.length; i++) ...[
                  if (i > 0) const Divider(height: 1, color: AdminColors.lineSoft),
                  _bookingRow(bookings[i], showCenter: true),
                ],
              ]),
            ),
            const SizedBox(height: 18),
          ],
          AdminSection(
            'Centers',
            sub: 'Shown to players on Home → Get your level assessed',
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
          else if (_centers.isEmpty)
            _emptyState()
          else
            for (final c in _centers) _card(c),
        ],
      ),
    );
  }

  Widget _emptyState() => AdminCard(
        child: Column(children: [
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: AdminColors.wash(AdminColors.primary, 0.12),
                borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.fact_check_outlined,
                size: 24, color: AdminColors.primary),
          ),
          const SizedBox(height: 12),
          Text('No assessment centers yet', style: AdminText.cardTitle()),
          const SizedBox(height: 3),
          Text(
              'Add a center, then publish time slots. Players see it on Home '
              'as soon as it is live — the row stays hidden while this is empty.',
              textAlign: TextAlign.center,
              style: AdminText.small()),
        ]),
      );

  Widget _card(Map<String, dynamic> c) {
    final active = c['is_active'] != false;
    final slots = _slotsOf(c['id'] as String).where(_future).toList();
    final open = slots.where((s) => !_booked(s)).length;
    final booked = slots.length - open;
    final price = c['price_egp'] as num?;
    final area = (c['area'] as String?)?.trim();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Opacity(
        opacity: active ? 1 : 0.72,
        child: AdminCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text((c['name'] as String?) ?? '—',
                      style: AdminText.cardTitle().copyWith(fontSize: 15),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  if (area != null && area.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(area, style: AdminText.small()),
                  ],
                ]),
              ),
              const SizedBox(width: 8),
              StatusBadge(active ? 'active' : 'hidden', dot: true),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 6, runSpacing: 6, children: [
              _tag(Icons.event_available_outlined, '$open open', AdminColors.green),
              _tag(Icons.how_to_reg_outlined, '$booked booked', AdminColors.info),
              if (price != null) _tag(Icons.payments_outlined, _price(price), null),
              _tag(Icons.sort_rounded, 'Order ${c['sort_order'] ?? 0}', null),
            ]),
            const Divider(height: 22, color: AdminColors.lineSoft),
            Row(children: [
              Expanded(
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  _pill('Add slots', () => _addSlots(c), primary: true),
                  _pill('Slots (${slots.length})', () => _slotsSheet(c)),
                  _pill(active ? 'Hide' : 'Show', () => _toggleActive(c)),
                ]),
              ),
              const SizedBox(width: 8),
              _iconBtn(Icons.edit_outlined, () => _form(c)),
              const SizedBox(width: 8),
              _iconBtn(Icons.delete_outline_rounded, () => _remove(c)),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _bookingRow(Map<String, dynamic> s,
      {bool showCenter = false, Future<void> Function()? onChanged}) {
    final p = s['profiles'] as Map<String, dynamic>?;
    final name = (p?['name'] as String?)?.trim();
    final phone = (p?['phone'] as String?)?.trim();
    final d = _start(s);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name?.isNotEmpty == true ? name! : 'Player',
                style: AdminText.strong()),
            const SizedBox(height: 2),
            Text(
                [
                  if (showCenter) _centerName(s['center_id'] as String?),
                  '${_day(d)} · ${_time(d)}',
                  if (phone != null && phone.isNotEmpty) phone,
                ].join(' · '),
                style: AdminText.small()),
          ]),
        ),
        const SizedBox(width: 8),
        if (_future(s))
          AdminButton('Release',
              height: 30,
              variant: AdminBtn.danger,
              onPressed: () => _release(s, onChanged)),
      ]),
    );
  }

  // ── Slots sheet ──────────────────────────────────────────────────────────

  void _slotsSheet(Map<String, dynamic> c) {
    adminSheet(
      context,
      title: 'Slots',
      sub: (c['name'] as String?) ?? '',
      heightFactor: 0.85,
      footer: AdminButton('Add slots',
          full: true,
          height: 48,
          icon: Icons.add_rounded,
          onPressed: () {
            Navigator.pop(context);
            _addSlots(c);
          }),
      body: StatefulBuilder(builder: (ctx, setSheet) {
        final slots = _slotsOf(c['id'] as String);
        if (slots.isEmpty) {
          return Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Text('No slots from today on. Add some below.',
                style: AdminText.small()),
          );
        }
        Future<void> refresh() async {
          await _load();
          if (ctx.mounted) setSheet(() {});
        }

        final byDay = <DateTime, List<Map<String, dynamic>>>{};
        for (final s in slots) {
          final d = _start(s);
          byDay.putIfAbsent(DateTime(d.year, d.month, d.day), () => []).add(s);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final e in byDay.entries) ...[
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 4),
              child: Text(_day(e.key).toUpperCase(),
                  style: AdminText.sans(11, FontWeight.w800, AdminColors.inkSoft)),
            ),
            for (final s in e.value)
              _booked(s)
                  ? _bookingRow(s, onChanged: refresh)
                  : _openRow(s, refresh),
            const Divider(height: 14, color: AdminColors.lineSoft),
          ],
        ]);
      }),
    );
  }

  Widget _openRow(Map<String, dynamic> s, Future<void> Function() refresh) {
    final d = _start(s);
    final past = !_future(s);
    final dur = (s['duration_min'] as num?)?.toInt() ?? 60;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Expanded(
          child: Text('${_time(d)} – ${_time(d.add(Duration(minutes: dur)))}',
              style: AdminText.strong()),
        ),
        StatusBadge(past ? 'completed' : 'open'),
        const SizedBox(width: 8),
        _iconBtn(Icons.delete_outline_rounded, () async {
          final ok = await AdminService.deleteOpenAssessmentSlot(s['id'] as String);
          await refresh();
          if (!mounted) return;
          adminToast(context, ok ? 'Slot removed' : 'Someone just booked it — release it instead',
              ok: ok);
        }),
      ]),
    );
  }

  Future<void> _release(
      Map<String, dynamic> s, Future<void> Function()? onChanged) async {
    final p = s['profiles'] as Map<String, dynamic>?;
    final name = (p?['name'] as String?) ?? 'the player';
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: AdminColors.surface,
        title: Text('Release this booking?', style: AdminText.h2()),
        content: Text(
            '$name loses this slot and gets a notification asking them to '
            'book another time. The slot opens up for everyone again.',
            style: AdminText.body().copyWith(height: 1.5)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: Text('Keep', style: AdminText.strong())),
          TextButton(
              onPressed: () => Navigator.pop(d, true),
              child: Text('Release', style: AdminText.strong(AdminColors.danger))),
        ],
      ),
    );
    if (ok != true) return;
    final err = await AdminService.releaseAssessmentSlot(s['id'] as String);
    if (onChanged != null) {
      await onChanged();
    } else {
      await _load();
    }
    if (!mounted) return;
    adminToast(context, err ?? 'Booking released — $name was notified',
        ok: err == null);
  }

  // ── Add slots ────────────────────────────────────────────────────────────

  void _addSlots(Map<String, dynamic> c) {
    final now = DateTime.now();
    final date = ValueNotifier<DateTime>(DateTime(now.year, now.month, now.day));
    final from = ValueNotifier<TimeOfDay>(const TimeOfDay(hour: 17, minute: 0));
    final to = ValueNotifier<TimeOfDay>(const TimeOfDay(hour: 21, minute: 0));
    final dur = ValueNotifier<int>(60);
    final days = ValueNotifier<int>(1);
    final busy = ValueNotifier<bool>(false);
    final all = Listenable.merge([date, from, to, dur, days, busy]);

    List<DateTime> starts() {
      final out = <DateTime>[];
      for (var i = 0; i < days.value; i++) {
        final d = date.value.add(Duration(days: i));
        var t = DateTime(d.year, d.month, d.day, from.value.hour, from.value.minute);
        final end = DateTime(d.year, d.month, d.day, to.value.hour, to.value.minute);
        while (!t.add(Duration(minutes: dur.value)).isAfter(end)) {
          if (t.isAfter(DateTime.now())) out.add(t);
          t = t.add(Duration(minutes: dur.value));
        }
      }
      return out;
    }

    adminSheet(
      context,
      title: 'Add slots',
      sub: (c['name'] as String?) ?? '',
      heightFactor: 0.9,
      footer: AnimatedBuilder(
        animation: all,
        builder: (_, __) {
          final n = starts().length;
          return AdminButton(
            n == 0 ? 'No slots in that window' : 'Publish $n slot${n == 1 ? '' : 's'}',
            full: true,
            height: 50,
            icon: Icons.check_rounded,
            onPressed: (n == 0 || busy.value)
                ? null
                : () async {
                    busy.value = true;
                    String msg;
                    var ok = true;
                    try {
                      final added = await AdminService.addAssessmentSlots(
                          c['id'] as String, starts(), dur.value);
                      final skipped = n - added;
                      msg = 'Published $added slot${added == 1 ? '' : 's'}'
                          '${skipped > 0 ? ' · $skipped already existed' : ''}';
                    } catch (e) {
                      debugPrint('[AdminAssessments] addSlots: $e');
                      msg = "Couldn't publish those slots";
                      ok = false;
                    }
                    if (!mounted) return;
                    Navigator.pop(context);
                    await _load();
                    if (!mounted) return;
                    adminToast(context, msg, ok: ok);
                  },
          );
        },
      ),
      body: AnimatedBuilder(
        animation: all,
        builder: (ctx, _) {
          final n = starts().length;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _pickerRow('Date', _day(date.value), Icons.calendar_today_outlined,
                () async {
              final d = await _pickDate(date.value);
              if (d != null) date.value = d;
            }),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: _pickerRow('From', _tod(from.value), Icons.schedule_rounded,
                    () async {
                  final t = await _pickTime(from.value);
                  if (t != null) from.value = t;
                }),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _pickerRow('Until', _tod(to.value), Icons.schedule_rounded,
                    () async {
                  final t = await _pickTime(to.value);
                  if (t != null) to.value = t;
                }),
              ),
            ]),
            const SizedBox(height: 18),
            Text('Each slot lasts', style: AdminText.strong(AdminColors.inkSoft)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final m in const [30, 45, 60, 90, 120])
                _chip(m < 60 || m % 60 != 0 ? '$m min' : '${m ~/ 60} h',
                    dur.value == m, () => dur.value = m),
            ]),
            const SizedBox(height: 18),
            Text('Repeat', style: AdminText.strong(AdminColors.inkSoft)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final d in const [1, 3, 7, 14])
                _chip(d == 1 ? 'Just this day' : 'Daily for $d days',
                    days.value == d, () => days.value = d),
            ]),
            const SizedBox(height: 18),
            AdminCard(
              color: AdminColors.surfaceAlt,
              padding: const EdgeInsets.all(13),
              child: Row(children: [
                const Icon(Icons.info_outline_rounded,
                    size: 17, color: AdminColors.inkSoft),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                      n == 0
                          ? 'Nothing fits between those times (past times are skipped).'
                          : '$n slot${n == 1 ? '' : 's'}, one player each. '
                              'A slot closes the moment someone books it. '
                              'Times already published here are skipped.',
                      style: AdminText.small().copyWith(height: 1.45)),
                ),
              ]),
            ),
          ]);
        },
      ),
    );
  }

  Future<DateTime?> _pickDate(DateTime initial) async {
    final now = DateTime.now();
    final min = DateTime(now.year, now.month, now.day);
    var temp = initial.isBefore(min) ? min : initial;
    return showModalBottomSheet<DateTime>(
      context: context,
      backgroundColor: AdminColors.surface,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: 280,
          child: Column(children: [
            _pickerBar('Pick a date', () => Navigator.pop(ctx, temp)),
            Expanded(
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.date,
                initialDateTime: temp,
                minimumDate: min,
                maximumDate: min.add(const Duration(days: 365)),
                onDateTimeChanged: (d) => temp = DateTime(d.year, d.month, d.day),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Future<TimeOfDay?> _pickTime(TimeOfDay initial) async {
    var temp = DateTime(2020, 1, 1, initial.hour, initial.minute - initial.minute % 5);
    return showModalBottomSheet<TimeOfDay>(
      context: context,
      backgroundColor: AdminColors.surface,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: 280,
          child: Column(children: [
            _pickerBar('Pick a time',
                () => Navigator.pop(ctx, TimeOfDay.fromDateTime(temp))),
            Expanded(
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.time,
                minuteInterval: 5,
                use24hFormat: false,
                initialDateTime: temp,
                onDateTimeChanged: (d) => temp = d,
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _pickerBar(String title, VoidCallback onDone) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 8, 0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title, style: AdminText.strong()),
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: onDone,
              child: Text('Done', style: AdminText.strong(AdminColors.primary)),
            ),
          ],
        ),
      );

  Widget _pickerRow(String label, String value, IconData icon, VoidCallback onTap) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: AdminText.strong(AdminColors.inkSoft)),
        const SizedBox(height: 7),
        GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
            decoration: BoxDecoration(
              color: AdminColors.surfaceAlt,
              borderRadius: AdminUI.fieldR,
              border: Border.all(color: AdminColors.line),
            ),
            child: Row(children: [
              Icon(icon, size: 15, color: AdminColors.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(value, style: AdminText.body())),
            ]),
          ),
        ),
      ]);

  Widget _chip(String label, bool selected, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            color: selected
                ? AdminColors.wash(AdminColors.primary, 0.14)
                : AdminColors.surfaceAlt,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: selected ? AdminColors.primary : AdminColors.line,
                width: selected ? 1.6 : 1),
          ),
          child: Text(label,
              style: AdminText.sans(12.5, FontWeight.w700,
                  selected ? AdminColors.primary : AdminColors.inkSoft)),
        ),
      );

  // ── Center add / edit / hide / delete ────────────────────────────────────

  Future<void> _toggleActive(Map<String, dynamic> c) async {
    final show = c['is_active'] == false;
    await AdminService.setAssessmentCenterActive(c['id'] as String, show);
    await _load();
    if (mounted) {
      adminToast(context, show ? 'Now live in the app' : 'Hidden from players');
    }
  }

  void _remove(Map<String, dynamic> c) {
    final name = (c['name'] as String?) ?? 'This center';
    final booked = _slotsOf(c['id'] as String)
        .where((s) => _future(s) && _booked(s))
        .length;
    adminSheet(
      context,
      title: 'Delete center?',
      sub: name,
      heightFactor: 0.42,
      footer: Row(children: [
        Expanded(
          child: AdminButton(
            'Delete',
            height: 48,
            variant: AdminBtn.danger,
            icon: Icons.delete_outline_rounded,
            onPressed: booked > 0
                ? null
                : () async {
                    Navigator.pop(context);
                    await AdminService.deleteAssessmentCenter(c['id'] as String);
                    await _load();
                    if (!mounted) return;
                    adminToast(context, '"$name" deleted');
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
        booked > 0
            ? '"$name" has $booked upcoming booking${booked == 1 ? '' : 's'}. '
                'Release ${booked == 1 ? 'it' : 'them'} first (so the players are '
                'told), or use "Hide" to stop new bookings.'
            : 'This deletes "$name" and all of its slots for good. To take it '
                'off the app for now, use "Hide" instead.',
        style: AdminText.body().copyWith(height: 1.6),
      ),
    );
  }

  void _form(Map<String, dynamic>? row) {
    final isNew = row == null;
    final nameCt = TextEditingController(text: row?['name'] ?? '');
    final areaCt = TextEditingController(text: row?['area'] ?? '');
    final addressCt = TextEditingController(text: row?['address'] ?? '');
    final mapCt = TextEditingController(text: row?['map_url'] ?? '');
    final phoneCt = TextEditingController(text: row?['phone'] ?? '');
    final descCt = TextEditingController(text: row?['description'] ?? '');
    final priceCt = TextEditingController(
        text: row?['price_egp'] == null ? '' : _num(row!['price_egp'] as num));
    final orderCt = TextEditingController(
        text: '${(row?['sort_order'] as num?)?.toInt() ?? 0}');
    final active = ValueNotifier<bool>(row?['is_active'] != false);

    adminSheet(
      context,
      title: isNew ? 'Add center' : 'Edit center',
      sub: isNew
          ? 'Players book assessment slots here'
          : ((row['name'] as String?) ?? ''),
      heightFactor: 0.92,
      footer: AdminButton(
        isNew ? 'Add center' : 'Save changes',
        full: true,
        height: 50,
        icon: Icons.check_rounded,
        onPressed: () async {
          if (nameCt.text.trim().isEmpty) {
            adminToast(context, 'Give the center a name', ok: false);
            return;
          }
          final priceTxt = priceCt.text.trim();
          final price = priceTxt.isEmpty ? null : num.tryParse(priceTxt);
          if (priceTxt.isNotEmpty && (price == null || price < 0)) {
            adminToast(context, 'Price must be a number (or leave it empty)',
                ok: false);
            return;
          }
          Navigator.pop(context);
          final err = await AdminService.saveAssessmentCenter(
            id: isNew ? null : row['id'] as String,
            name: nameCt.text,
            area: areaCt.text,
            address: addressCt.text,
            mapUrl: mapCt.text,
            phone: phoneCt.text,
            description: descCt.text,
            priceEgp: price,
            isActive: active.value,
            sortOrder: int.tryParse(orderCt.text.trim()) ?? 0,
          );
          await _load();
          if (!mounted) return;
          adminToast(context,
              err ?? (isNew ? 'Center added — now add slots' : 'Center updated'),
              ok: err == null);
        },
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _field('Name', nameCt, hint: 'e.g. Padel Rivals Academy — New Cairo'),
        const SizedBox(height: 14),
        _field('Area', areaCt, hint: 'Short, shown under the name (optional)'),
        const SizedBox(height: 14),
        _field('Address', addressCt, maxLines: 2, hint: 'Optional'),
        const SizedBox(height: 14),
        _field('Map link', mapCt,
            hint: 'Paste a Google Maps link — players get a Directions button'),
        const SizedBox(height: 14),
        _field('Center phone', phoneCt,
            hint: 'Shown to players so they can call the center (optional)'),
        const SizedBox(height: 14),
        _field('About', descCt,
            maxLines: 3,
            hint: 'What happens at the assessment, what to bring (optional)'),
        const SizedBox(height: 14),
        _field('Price (EGP)', priceCt,
            keyboard: const TextInputType.numberWithOptions(decimal: true),
            hint: 'Paid at the center — nothing is charged in the app. '
                'Leave empty to hide.'),
        const SizedBox(height: 14),
        _field('Sort order', orderCt,
            keyboard: TextInputType.number, hint: 'Lower shows first'),
        const SizedBox(height: 16),
        ValueListenableBuilder<bool>(
          valueListenable: active,
          builder: (_, on, __) =>
              _check('Live in the app', on, () => active.value = !on),
        ),
      ]),
    );
  }

  // ── Small widgets ────────────────────────────────────────────────────────

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

  Widget _pill(String label, VoidCallback onTap, {bool primary = false}) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
              color: primary
                  ? AdminColors.wash(AdminColors.primary, 0.14)
                  : AdminColors.surfaceAlt,
              borderRadius: BorderRadius.circular(9)),
          child: Text(label,
              style: AdminText.sans(12.5, FontWeight.w700,
                  primary ? AdminColors.primary : AdminColors.ink)),
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
      {String? hint, int maxLines = 1, TextInputType? keyboard}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: AdminText.strong(AdminColors.inkSoft)),
      const SizedBox(height: 7),
      TextField(
        controller: c,
        style: AdminText.body(),
        maxLines: maxLines,
        keyboardType: keyboard,
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

  // ── Formatting ───────────────────────────────────────────────────────────

  static const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _mo = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  static String _day(DateTime d) =>
      '${_wd[d.weekday - 1]} ${d.day} ${_mo[d.month - 1]}';

  static String _time(DateTime d) =>
      _tod(TimeOfDay(hour: d.hour, minute: d.minute));

  static String _tod(TimeOfDay t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  static String _num(num p) =>
      p == p.roundToDouble() ? '${p.toInt()}' : p.toStringAsFixed(2);
  static String _price(num p) => 'EGP ${_num(p)}';
}

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/screen_bar.dart';
import 'package:padel_clay/frontend/widgets/padel_refresh.dart';
import 'package:padel_clay/frontend/widgets/auto_refresh.dart';
import 'package:padel_clay/frontend/widgets/app_toast.dart';
import 'package:padel_clay/backend/services/assessment_service.dart';

/// Level assessment — in-person centers and their open time slots.
///
/// Each slot is one seat: booking it removes it from everyone else's list
/// (the server does the closing, see book_assessment_slot). A player holds at
/// most one upcoming booking; cancelling it reopens the slot.
class AssessmentCentersScreen extends StatefulWidget {
  const AssessmentCentersScreen({super.key});

  @override
  State<AssessmentCentersScreen> createState() =>
      _AssessmentCentersScreenState();
}

class _AssessmentCentersScreenState extends State<AssessmentCentersScreen>
    with AutoRefresh<AssessmentCentersScreen> {
  AssessmentOverview _data = AssessmentOverview.empty;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Future<void> onAutoRefresh() => _load();

  Future<void> _load() async {
    final d = await AssessmentService.overview();
    if (!mounted) return;
    markRefreshed();
    setState(() {
      _data = d;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final mine = _data.myBooking;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: ScreenBar(
        title: 'Level Assessment',
        onBack: () => Navigator.pop(context),
      ),
      body: PadelRefresh(
        onRefresh: _load,
        padding: EdgeInsets.fromLTRB(AppSpacing.screen, 16, AppSpacing.screen,
            MediaQuery.of(context).padding.bottom + 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _hero(),
            if (_loading) ...[
              const SizedBox(height: 28),
              const Center(
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.primary),
              ),
            ] else ...[
              if (mine != null) ...[
                const SizedBox(height: 22),
                _label('Your assessment'),
                _myBookingCard(mine),
              ],
              const SizedBox(height: 22),
              _label('Centers'),
              if (_data.centers.isEmpty)
                _empty()
              else
                for (final c in _data.centers) ...[
                  _centerCard(c),
                  const SizedBox(height: AppSpacing.gap),
                ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 0, 2, 12),
        child: Text(text.toUpperCase(), style: AppText.kicker()),
      );

  Widget _hero() => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.card),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.hero, AppColors.hero2],
          ),
        ),
        child: Row(children: [
          Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.fact_check_outlined,
                size: 24, color: AppColors.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Get your level checked',
                  style: AppText.cardTitle(AppColors.heroInk)
                      .copyWith(fontSize: 16)),
              const SizedBox(height: 4),
              Text(
                  'Pick a center and a time. Each slot is for one player — '
                  'once you book it, it\'s yours.',
                  style: AppText.small(AppColors.heroFaint)
                      .copyWith(height: 1.4)),
            ]),
          ),
        ]),
      );

  Widget _empty() => AppCard(
        child: Column(children: [
          const Icon(Icons.event_busy_outlined,
              size: 28, color: AppColors.inkFaint),
          const SizedBox(height: 10),
          Text('No assessment centers yet', style: AppText.bodyStrong()),
          const SizedBox(height: 4),
          Text('Check back soon — new centers and times are added here.',
              textAlign: TextAlign.center, style: AppText.small()),
        ]),
      );

  // ── Your booking ─────────────────────────────────────────────────────────

  Widget _myBookingCard(AssessmentSlot s) {
    final c = _data.centerOf(s.centerId);
    return AppCard(
      borderColor: AppColors.success.withValues(alpha: 0.55),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const AppTag('Booked', color: AppColors.success),
          const Spacer(),
          Text(_relativeDay(s.startsAt), style: AppText.small()),
        ]),
        const SizedBox(height: 10),
        Text(c?.name ?? 'Assessment center',
            style: AppText.cardTitle().copyWith(fontSize: 16)),
        const SizedBox(height: 4),
        Text('${_dayLabel(s.startsAt)} · ${_time(s.startsAt)} – ${_time(s.endsAt)}',
            style: AppText.bodyStrong(AppColors.primary)),
        if (c?.address != null) ...[
          const SizedBox(height: 6),
          Text(c!.address!, style: AppText.small()),
        ],
        if (c?.priceEgp != null) ...[
          const SizedBox(height: 6),
          Text('${_price(c!.priceEgp!)} · pay at the center',
              style: AppText.small(AppColors.inkSoft)),
        ],
        const SizedBox(height: 14),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (c?.mapUrl != null)
            AppButton('Directions',
                variant: AppBtnVariant.ghost,
                icon: Icons.directions_outlined,
                height: 36,
                onPressed: () => _openMap(c!)),
          if (c?.phone != null)
            AppButton('Call',
                variant: AppBtnVariant.ghost,
                icon: Icons.call_outlined,
                height: 36,
                onPressed: () => _call(c!.phone!)),
          AppButton('Cancel booking',
              variant: AppBtnVariant.outline,
              height: 36,
              onPressed: _busy ? null : () => _confirmCancel(s, c)),
        ]),
      ]),
    );
  }

  // ── Centers + slots ──────────────────────────────────────────────────────

  Widget _centerCard(AssessmentCenter c) {
    final slots = _data.slotsFor(c.id);
    // Group by calendar day, keeping the server's ascending order.
    final byDay = <DateTime, List<AssessmentSlot>>{};
    for (final s in slots) {
      final d = DateTime(s.startsAt.year, s.startsAt.month, s.startsAt.day);
      byDay.putIfAbsent(d, () => []).add(s);
    }

    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.name, style: AppText.cardTitle().copyWith(fontSize: 16)),
              if (c.area != null || c.address != null) ...[
                const SizedBox(height: 3),
                Text(c.area ?? c.address!,
                    style: AppText.small(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ]),
          ),
          if (c.priceEgp != null) ...[
            const SizedBox(width: 8),
            AppTag(_price(c.priceEgp!), color: AppColors.accent),
          ],
        ]),
        if (c.description != null) ...[
          const SizedBox(height: 8),
          Text(c.description!,
              style: AppText.small().copyWith(height: 1.4)),
        ],
        if (c.mapUrl != null || c.phone != null) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 14, runSpacing: 6, children: [
            if (c.mapUrl != null)
              _linkRow(Icons.directions_outlined, 'Directions',
                  () => _openMap(c)),
            if (c.phone != null)
              _linkRow(Icons.call_outlined, c.phone!, () => _call(c.phone!)),
          ]),
        ],
        const SizedBox(height: 14),
        if (byDay.isEmpty)
          Text('No open slots right now — check back soon.',
              style: AppText.small(AppColors.inkFaint))
        else
          for (final e in byDay.entries) ...[
            Text(_dayLabel(e.key),
                style: AppText.bodyStrong(AppColors.inkSoft)
                    .copyWith(fontSize: 12.5)),
            const SizedBox(height: 7),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final s in e.value) _slotChip(c, s),
            ]),
            const SizedBox(height: 12),
          ],
      ]),
    );
  }

  Widget _linkRow(IconData icon, String text, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: AppColors.primary),
          const SizedBox(width: 5),
          Text(text, style: AppText.bodyStrong(AppColors.primary)
              .copyWith(fontSize: 12.5)),
        ]),
      );

  Widget _slotChip(AssessmentCenter c, AssessmentSlot s) => GestureDetector(
        onTap: _busy ? null : () => _confirmBook(c, s),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            color: AppColors.field,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.line),
          ),
          child: Text(_time(s.startsAt),
              style: AppText.bodyStrong().copyWith(fontSize: 13)),
        ),
      );

  // ── Actions ──────────────────────────────────────────────────────────────

  Future<void> _confirmBook(AssessmentCenter c, AssessmentSlot s) async {
    if (_data.myBooking != null) {
      AppToast.show(context,
          'You already have an assessment booked. Cancel it first to pick another time.',
          kind: ToastKind.info);
      return;
    }
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Book this slot?', style: AppText.cardTitle()),
              const SizedBox(height: 12),
              Text(c.name, style: AppText.bodyStrong()),
              const SizedBox(height: 3),
              Text(
                  '${_dayLabel(s.startsAt)} · ${_time(s.startsAt)} – ${_time(s.endsAt)}',
                  style: AppText.bodyStrong(AppColors.primary)),
              if (c.address != null) ...[
                const SizedBox(height: 6),
                Text(c.address!, style: AppText.small()),
              ],
              const SizedBox(height: 10),
              Text(
                  c.priceEgp != null
                      ? '${_price(c.priceEgp!)}, paid at the center. You can cancel any time before it starts.'
                      : 'You can cancel any time before it starts.',
                  style: AppText.small().copyWith(height: 1.4)),
              const SizedBox(height: 18),
              AppButton('Book slot',
                  full: true,
                  height: 48,
                  icon: Icons.check_rounded,
                  onPressed: () => Navigator.pop(ctx, true)),
              const SizedBox(height: 8),
              AppButton('Not now',
                  full: true,
                  height: 44,
                  variant: AppBtnVariant.ghost,
                  onPressed: () => Navigator.pop(ctx, false)),
            ],
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    final err = await AssessmentService.book(s.id);
    if (!mounted) return;
    setState(() => _busy = false);
    AppToast.show(context, err ?? 'Booked — see you there!',
        kind: err == null ? ToastKind.success : ToastKind.error);
    await _load();
  }

  Future<void> _confirmCancel(AssessmentSlot s, AssessmentCenter? c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Cancel your assessment?', style: AppText.bodyStrong()),
        content: Text(
            'Your slot at ${c?.name ?? 'the center'} on ${_dayLabel(s.startsAt)} '
            'at ${_time(s.startsAt)} opens up for other players straight away.',
            style: AppText.small().copyWith(height: 1.45)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: Text('Keep it', style: AppText.bodyStrong())),
          TextButton(
              onPressed: () => Navigator.pop(d, true),
              child: Text('Cancel booking',
                  style: AppText.bodyStrong(AppColors.danger))),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    final err = await AssessmentService.cancel(s.id);
    if (!mounted) return;
    setState(() => _busy = false);
    AppToast.show(context, err ?? 'Booking cancelled',
        kind: err == null ? ToastKind.success : ToastKind.error);
    await _load();
  }

  Future<void> _openMap(AssessmentCenter c) async {
    final raw = c.mapUrl!;
    final uri = Uri.tryParse(raw.startsWith('http') ? raw : 'https://$raw');
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _call(String phone) async {
    final digits = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (digits.isEmpty) return;
    await launchUrl(Uri.parse('tel:$digits'));
  }

  // ── Formatting (no intl in pubspec, on purpose) ─────────────────────────

  static const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _mo = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  static String _dayLabel(DateTime d) {
    final rel = _relativeDay(d);
    final base = '${_wd[d.weekday - 1]} ${d.day} ${_mo[d.month - 1]}';
    return rel.isEmpty ? base : '$rel · $base';
  }

  static String _relativeDay(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = DateTime(d.year, d.month, d.day).difference(today).inDays;
    return switch (diff) { 0 => 'Today', 1 => 'Tomorrow', _ => '' };
  }

  static String _time(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final mm = d.minute.toString().padLeft(2, '0');
    return '$h:$mm ${d.hour < 12 ? 'AM' : 'PM'}';
  }

  static String _price(num p) =>
      'EGP ${p == p.roundToDouble() ? p.toInt() : p.toStringAsFixed(2)}';
}

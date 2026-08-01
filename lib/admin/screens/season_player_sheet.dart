import 'package:flutter/material.dart';

import '../../backend/services/season_service.dart';
import '../data/admin_service.dart';
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';

// ── Shared season formatting (also used by the console screen) ───────────────

IconData seasonRuleIcon(String name) => switch (name) {
      'crown' => Icons.workspace_premium_rounded,
      'medal' => Icons.military_tech_rounded,
      'trophy' => Icons.emoji_events_rounded,
      'star' => Icons.star_rounded,
      'shield' => Icons.shield_rounded,
      'bolt' => Icons.bolt_rounded,
      'fire' => Icons.local_fire_department_rounded,
      'check' => Icons.check_circle_rounded,
      'dash' => Icons.remove_rounded,
      _ => Icons.star_rounded,
    };

Color seasonBracketTone(String key) => switch (key) {
      'gold' => AdminColors.gold,
      'silver' => AdminColors.silver,
      'primary' => AdminColors.primary,
      'bronzegold' => AdminColors.bronze,
      _ => AdminColors.inkSoft,
    };

String seasonThousands(int n) {
  final s = n.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return '${n < 0 ? '-' : ''}$b';
}

String seasonDay(DateTime? d, {bool withYear = false}) {
  if (d == null) return '—';
  const m = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  final l = d.toLocal();
  return '${l.day} ${m[l.month - 1]}${withYear ? ' ${l.year}' : ''}';
}

/// Open the per-player season sheet. Resolves once it closes — the caller
/// should reload, since points may have changed.
Future<void> showSeasonPlayerSheet(
  BuildContext context, {
  required String seasonId,
  required String playerId,
  required String playerName,
}) {
  return adminSheet<void>(
    context,
    title: playerName,
    sub: 'Everything this player has done this season',
    heightFactor: 0.93,
    body: SeasonPlayerSheet(seasonId: seasonId, playerId: playerId),
  );
}

/// Full per-player detail: profile, rating, standing, points breakdown and the
/// ledger — with every entry voidable and the player's rating/status editable.
class SeasonPlayerSheet extends StatefulWidget {
  final String seasonId, playerId;
  const SeasonPlayerSheet(
      {super.key, required this.seasonId, required this.playerId});

  @override
  State<SeasonPlayerSheet> createState() => _SeasonPlayerSheetState();
}

class _SeasonPlayerSheetState extends State<SeasonPlayerSheet> {
  SeasonPlayer? _p;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SeasonService.playerDetail(widget.seasonId, widget.playerId);
    if (!mounted) return;
    setState(() {
      _p = p;
      _loading = false;
    });
  }

  Future<void> _run(Future<String?> Function() action, String okMessage) async {
    if (_busy) return;
    setState(() => _busy = true);
    final err = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    adminToast(context, err ?? okMessage, ok: err == null);
    if (err == null) await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(40),
        child: Center(
            child: CircularProgressIndicator(
                strokeWidth: 2, color: AdminColors.primary)),
      );
    }
    final p = _p;
    if (p == null || p.error != null) {
      return Padding(
        padding: const EdgeInsets.all(30),
        child: Center(
          child: Text(p?.error ?? 'Could not load this player.',
              textAlign: TextAlign.center, style: AdminText.small()),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _identity(p),
      const SizedBox(height: 14),
      _standing(p),
      const SizedBox(height: 14),
      _stats(p),
      const SizedBox(height: 18),
      _actions(p),
      const SizedBox(height: 20),
      _breakdown(p),
      const SizedBox(height: 18),
      _ledger(p),
    ]);
  }

  // ── who they are ──────────────────────────────────────────────────
  Widget _identity(SeasonPlayer p) {
    final tone = AdminColors.tier(p.tier);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminAvatar(p.initials, size: 52, color: tone, imageUrl: p.avatarUrl),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(
              child: Text(p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AdminText.h2()),
            ),
            const SizedBox(width: 8),
            StatusBadge(p.status),
          ]),
          if (p.username != null && p.username!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text('@${p.username}',
                style: AdminText.small(AdminColors.inkFaint)),
          ],
          const SizedBox(height: 7),
          Wrap(spacing: 12, runSpacing: 4, children: [
            if (p.city != null && p.city!.isNotEmpty)
              _meta(Icons.place_outlined, p.city!),
            if (p.phone != null && p.phone!.isNotEmpty)
              _meta(Icons.phone_outlined, p.phone!),
            if (p.email != null && p.email!.isNotEmpty)
              _meta(Icons.mail_outline_rounded, p.email!),
            _meta(Icons.event_outlined,
                'Joined ${seasonDay(p.joined, withYear: true)}'),
            _meta(Icons.schedule_rounded,
                'Seen ${seasonDay(p.lastSeen, withYear: true)}'),
          ]),
        ]),
      ),
    ]);
  }

  Widget _meta(IconData ic, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ic, size: 13, color: AdminColors.inkFaint),
          const SizedBox(width: 5),
          Text(text, style: AdminText.small(AdminColors.inkSoft)),
        ],
      );

  // ── where they stand ──────────────────────────────────────────────
  Widget _standing(SeasonPlayer p) {
    final b = p.bracket;
    final tone = b == null ? AdminColors.inkFaint : seasonBracketTone(b.colorKey);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: AdminColors.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: tone, width: 3)),
      ),
      child: Row(children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(p.seasonName.toUpperCase(), style: AdminText.kicker()),
          const SizedBox(height: 4),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(p.rank == null ? '—' : '#${p.rank}',
                style: AdminText.sans(28, FontWeight.w800, AdminColors.ink,
                    ls: -1, height: 1)),
            const SizedBox(width: 8),
            if (p.trend != 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(children: [
                  Icon(
                      p.trend > 0
                          ? Icons.arrow_upward_rounded
                          : Icons.arrow_downward_rounded,
                      size: 13,
                      color: p.trend > 0
                          ? AdminColors.green
                          : AdminColors.danger),
                  Text('${p.trend.abs()}',
                      style: AdminText.mono(
                          11,
                          FontWeight.w800,
                          p.trend > 0
                              ? AdminColors.green
                              : AdminColors.danger)),
                ]),
              ),
          ]),
        ]),
        const Spacer(),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${seasonThousands(p.pts)} pts',
              style: AdminText.sans(18, FontWeight.w800, AdminColors.ink)),
          const SizedBox(height: 5),
          if (b != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                  color: AdminColors.wash(tone, 0.14),
                  borderRadius: BorderRadius.circular(999)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(seasonRuleIcon(b.icon), size: 12, color: tone),
                const SizedBox(width: 5),
                Text(b.short,
                    style: AdminText.sans(11, FontWeight.w700, tone)),
              ]),
            )
          else
            Text('No reward bracket',
                style: AdminText.small(AdminColors.inkFaint)),
        ]),
      ]),
    );
  }

  // ── the numbers ───────────────────────────────────────────────────
  Widget _stats(SeasonPlayer p) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _stat('Matches counted', '${p.played}'),
          _stat('Season record', '${p.wins}W · ${p.losses}L'),
          _stat('Rating', p.rating.toStringAsFixed(2),
              foot: p.isProvisional ? 'Provisional' : null),
          _stat('Reliability', '${p.reliability}%'),
          _stat('Rated matches', '${p.competitiveMatches}'),
          if (p.isAnchor) _stat('Anchor', 'Yes'),
          if (p.voidedCount > 0)
            _stat('Voided entries', '${p.voidedCount}',
                tone: AdminColors.danger),
        ],
      );

  Widget _stat(String label, String value, {String? foot, Color? tone}) =>
      Container(
        width: 108,
        padding: const EdgeInsets.fromLTRB(11, 9, 11, 10),
        decoration: BoxDecoration(
            color: AdminColors.surfaceAlt,
            borderRadius: BorderRadius.circular(11)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AdminText.kicker()),
          const SizedBox(height: 5),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AdminText.sans(
                  15, FontWeight.w800, tone ?? AdminColors.ink)),
          if (foot != null)
            Text(foot, style: AdminText.small(AdminColors.inkFaint)),
        ]),
      );

  // ── edit anything ─────────────────────────────────────────────────
  Widget _actions(SeasonPlayer p) => Wrap(spacing: 8, runSpacing: 8, children: [
        AdminButton('Adjust points',
            icon: Icons.tune_rounded,
            height: 36,
            onPressed: _busy ? null : () => _adjust(p)),
        AdminButton('Edit rating',
            icon: Icons.speed_rounded,
            variant: AdminBtn.ghost,
            height: 36,
            onPressed: _busy ? null : () => _editRating(p)),
        AdminButton(
            p.status == 'banned' ? 'Unban player' : 'Player status',
            icon: Icons.shield_outlined,
            variant: p.status == 'active' ? AdminBtn.ghost : AdminBtn.danger,
            height: 36,
            onPressed: _busy ? null : () => _setStatus(p)),
      ]);

  // ── where the points came from ────────────────────────────────────
  Widget _breakdown(SeasonPlayer p) {
    if (p.breakdown.isEmpty) {
      return Text('No points earned yet this season.',
          style: AdminText.small(AdminColors.inkFaint));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const AdminSection('Where the points came from',
          sub: 'Voided entries are excluded'),
      for (final b in p.breakdown)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
              color: AdminColors.surfaceAlt,
              borderRadius: BorderRadius.circular(11)),
          child: Row(children: [
            Icon(seasonRuleIcon(b.icon), size: 16, color: AdminColors.primary),
            const SizedBox(width: 11),
            Expanded(child: Text(b.label, style: AdminText.strong())),
            Text('×${b.count}',
                style: AdminText.mono(12, FontWeight.w600, AdminColors.inkFaint)),
            const SizedBox(width: 12),
            SizedBox(
              width: 62,
              child: Text(
                  '${b.pts >= 0 ? '+' : ''}${seasonThousands(b.pts)}',
                  textAlign: TextAlign.right,
                  style: AdminText.mono(13, FontWeight.w800,
                      b.pts >= 0 ? AdminColors.ink : AdminColors.danger)),
            ),
          ]),
        ),
    ]);
  }

  // ── the ledger ────────────────────────────────────────────────────
  Widget _ledger(SeasonPlayer p) {
    if (p.ledger.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminSection('Points ledger',
          sub: '${p.ledger.length} most recent · tap the slash to void an entry'),
      for (final e in p.ledger) _ledgerRow(e),
    ]);
  }

  Widget _ledgerRow(SeasonLedgerEntry e) {
    final muted = e.voided;
    final sub = <String>[
      e.source,
      seasonDay(e.at),
      if (e.by != null && e.by!.isNotEmpty) 'by ${e.by}',
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 9, 6, 9),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: muted
            ? AdminColors.wash(AdminColors.danger, 0.07)
            : AdminColors.surfaceAlt,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(children: [
        Icon(seasonRuleIcon(e.icon),
            size: 16,
            color: muted ? AdminColors.inkFaint : AdminColors.inkSoft),
        const SizedBox(width: 11),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AdminText.strong(
                    muted ? AdminColors.inkFaint : AdminColors.ink)),
            const SizedBox(height: 2),
            Text(sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AdminText.small(AdminColors.inkFaint)),
            if (e.reason != null && e.reason!.isNotEmpty)
              Text('“${e.reason}”',
                  maxLines: 2,
                  style: AdminText.small(AdminColors.inkSoft)),
            if (muted)
              Text(
                  e.voidReason == null || e.voidReason!.isEmpty
                      ? 'Voided — does not count'
                      : 'Voided — ${e.voidReason}',
                  maxLines: 2,
                  style: AdminText.small(AdminColors.danger)),
          ]),
        ),
        const SizedBox(width: 8),
        Text('${e.pts >= 0 ? '+' : ''}${e.pts}',
            style: AdminText.mono(
                13,
                FontWeight.w800,
                muted
                    ? AdminColors.inkFaint
                    : (e.pts >= 0 ? AdminColors.ink : AdminColors.danger))),
        IconButton(
          icon: Icon(
              muted ? Icons.restore_rounded : Icons.block_flipped,
              size: 17,
              color: muted ? AdminColors.green : AdminColors.inkSoft),
          tooltip: muted ? 'Let it count again' : 'Void this entry',
          onPressed: _busy ? null : () => _toggleVoid(e),
        ),
      ]),
    );
  }

  // ── dialogs ───────────────────────────────────────────────────────

  Future<void> _toggleVoid(SeasonLedgerEntry e) async {
    if (e.voided) {
      await _run(() => SeasonService.voidPoints(e.id, false),
          '${e.label} counts again');
      return;
    }
    final reason = TextEditingController();
    final ok = await _dialog(
      title: 'Void ${e.label.toLowerCase()}?',
      body: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(
          'The ${e.pts >= 0 ? '+' : ''}${e.pts} pts stop counting and the '
          'standings re-sort. The entry stays in the ledger and the player is '
          'told — you can restore it at any time.',
          style: AdminText.small(AdminColors.inkSoft).copyWith(height: 1.4),
        ),
        const SizedBox(height: 14),
        _input(reason, 'Reason (shown to the player)', maxLines: 2),
      ]),
      confirm: 'Void entry',
      danger: true,
    );
    if (ok != true) return;
    await _run(
      () => SeasonService.voidPoints(e.id, true, reason: reason.text.trim()),
      '${e.label} voided',
    );
  }

  Future<void> _adjust(SeasonPlayer p) async {
    final delta = TextEditingController(text: '0');
    final reason = TextEditingController();
    final ok = await _dialog(
      title: 'Adjust season points',
      body: StatefulBuilder(
        builder: (ctx, setInner) {
          final d = int.tryParse(delta.text.trim()) ?? 0;
          return Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(
                child: Text('${seasonThousands(p.pts)} pts',
                    style: AdminText.sans(
                        15, FontWeight.w800, AdminColors.inkSoft)),
              ),
              const Icon(Icons.arrow_forward_rounded,
                  size: 16, color: AdminColors.inkFaint),
              Expanded(
                child: Text('${seasonThousands(p.pts + d)} pts',
                    textAlign: TextAlign.right,
                    style: AdminText.sans(
                        15, FontWeight.w800, AdminColors.primary)),
              ),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final v in const [-50, -20, 20, 50, 120, 250])
                GestureDetector(
                  onTap: () => setInner(() => delta.text = '$v'),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: d == v
                          ? AdminColors.primary
                          : AdminColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                          color:
                              d == v ? AdminColors.primary : AdminColors.line),
                    ),
                    child: Text(v > 0 ? '+$v' : '$v',
                        style: AdminText.mono(
                            11.5,
                            FontWeight.w800,
                            d == v
                                ? AdminColors.primaryInk
                                : AdminColors.inkSoft)),
                  ),
                ),
            ]),
            const SizedBox(height: 12),
            _input(delta, 'Adjustment (pts)',
                number: true, onChanged: (_) => setInner(() {})),
            const SizedBox(height: 12),
            _input(reason, 'Reason (logged + shown to the player)', maxLines: 2),
          ]);
        },
      ),
      confirm: 'Apply',
    );
    if (ok != true) return;
    final v = int.tryParse(delta.text.trim()) ?? 0;
    if (v == 0) {
      if (mounted) adminToast(context, 'Enter an adjustment', ok: false);
      return;
    }
    await _run(
      () => SeasonService.adjustPoints(
          seasonId: widget.seasonId,
          playerId: p.id,
          delta: v,
          reason: reason.text.trim()),
      '${p.name} ${v > 0 ? '+' : ''}$v pts',
    );
  }

  Future<void> _editRating(SeasonPlayer p) async {
    final rating = TextEditingController(text: p.rating.toStringAsFixed(2));
    var anchor = p.isAnchor;
    final ok = await _dialog(
      title: 'Edit rating',
      body: StatefulBuilder(
        builder: (ctx, setInner) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Sets the player\'s 0.00–7.00 rating directly and logs it to the '
              'audit trail. This does NOT change season points — the ladder and '
              'the rating are separate.',
              style: AdminText.small(AdminColors.inkSoft).copyWith(height: 1.4),
            ),
            const SizedBox(height: 14),
            _input(rating, 'Rating (0.00 – 7.00)', number: true),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () => setInner(() => anchor = !anchor),
              child: Row(children: [
                Icon(
                    anchor
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                    size: 20,
                    color:
                        anchor ? AdminColors.primary : AdminColors.inkFaint),
                const SizedBox(width: 9),
                Expanded(
                  child: Text('Anchor player (rating barely moves)',
                      style: AdminText.small(AdminColors.ink)),
                ),
              ]),
            ),
          ],
        ),
      ),
      confirm: 'Save rating',
    );
    if (ok != true) return;
    final v = double.tryParse(rating.text.trim());
    if (v == null) {
      if (mounted) adminToast(context, 'Enter a rating', ok: false);
      return;
    }
    await _run(
      () => AdminService.setRating(p.id,
          rating: v,
          sigma: anchor ? 0.30 : 0.50,
          isAnchor: anchor,
          notes: 'Set from the season console'),
      'Rating set to ${v.toStringAsFixed(2)}',
    );
  }

  Future<void> _setStatus(SeasonPlayer p) async {
    const options = [
      ['active', 'Active', 'Full access'],
      ['flagged', 'Flagged', 'Watch list — still plays'],
      ['banned', 'Banned', 'Locked out of the app'],
    ];
    var picked = p.status;
    final ok = await _dialog(
      title: 'Player status',
      body: StatefulBuilder(
        builder: (ctx, setInner) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final o in options)
              GestureDetector(
                onTap: () => setInner(() => picked = o[0]),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                  decoration: BoxDecoration(
                    color: AdminColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(
                        color: picked == o[0]
                            ? AdminColors.primary
                            : AdminColors.line,
                        width: picked == o[0] ? 1.6 : 1),
                  ),
                  child: Row(children: [
                    Icon(
                        picked == o[0]
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 18,
                        color: picked == o[0]
                            ? AdminColors.primary
                            : AdminColors.inkFaint),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(o[1], style: AdminText.strong()),
                            Text(o[2],
                                style: AdminText.small(AdminColors.inkFaint)),
                          ]),
                    ),
                  ]),
                ),
              ),
          ],
        ),
      ),
      confirm: 'Save status',
      danger: true,
    );
    if (ok != true || picked == p.status) return;
    await _run(() => AdminService.setPlayerStatus(p.id, picked),
        'Status set to $picked');
  }

  Future<bool?> _dialog({
    required String title,
    required Widget body,
    required String confirm,
    bool danger = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AdminColors.surface,
        title: Text(title, style: AdminText.h2()),
        content: SingleChildScrollView(child: body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child:
                  Text('Cancel', style: AdminText.strong(AdminColors.inkSoft))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(confirm,
                  style: AdminText.strong(
                      danger ? AdminColors.danger : AdminColors.primary))),
        ],
      ),
    );
  }

  Widget _input(TextEditingController c, String label,
      {int maxLines = 1, bool number = false, ValueChanged<String>? onChanged}) {
    return TextField(
      controller: c,
      maxLines: maxLines,
      onChanged: onChanged,
      keyboardType: number
          ? const TextInputType.numberWithOptions(signed: true, decimal: true)
          : TextInputType.text,
      style: AdminText.body(),
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        labelStyle: AdminText.small(AdminColors.inkSoft),
        filled: true,
        fillColor: AdminColors.surfaceAlt,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        enabledBorder: OutlineInputBorder(
            borderRadius: AdminUI.fieldR,
            borderSide: const BorderSide(color: AdminColors.line)),
        focusedBorder: OutlineInputBorder(
            borderRadius: AdminUI.fieldR,
            borderSide:
                const BorderSide(color: AdminColors.primary, width: 1.6)),
      ),
    );
  }
}

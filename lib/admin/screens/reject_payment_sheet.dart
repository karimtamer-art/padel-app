import 'package:flutter/material.dart';

import '../data/admin_service.dart';
import '../../backend/models/tournament_payment.dart';
import '../../backend/services/region_service.dart' show money;
import '../../frontend/theme/tournament_tokens.dart';
import '../../frontend/widgets/tournament_kit.dart';
import '../widgets/admin_kit.dart' show adminToast;

/// "Reject payment?": reason, did money arrive, and hold their spot. Replaces the
/// old one-tap reject. True when the entry was rejected.
Future<bool> showRejectPaymentSheet(
  BuildContext context, {
  required Map<String, dynamic> entry,
  required int fee,
}) async {
  final done = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: TColors.cream,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
    builder: (_) => RejectPaymentSheet(entry: entry, fee: fee),
  );
  return done == true;
}

class RejectPaymentSheet extends StatefulWidget {
  final Map<String, dynamic> entry;
  final int fee;
  const RejectPaymentSheet({super.key, required this.entry, required this.fee});

  @override
  State<RejectPaymentSheet> createState() => _RejectPaymentSheetState();
}

class _RejectPaymentSheetState extends State<RejectPaymentSheet> {
  final _note = TextEditingController();
  String? _reason;
  bool? _money;
  bool _hold = true;
  bool _busy = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  String get _pair {
    final a = (widget.entry['player_name'] as String?)?.trim();
    final b = (widget.entry['partner_name'] as String?)?.trim();
    final first = a == null || a.isEmpty ? 'Player' : a;
    return b == null || b.isEmpty ? first : '$first / $b';
  }

  int get _claimed =>
      (widget.entry['paid_amount'] as num?)?.toInt() ?? widget.fee * 2;

  bool get _ready =>
      !_busy &&
      _reason != null &&
      _money != null &&
      (_reason != 'Other' || _note.text.trim().isNotEmpty);

  Future<void> _submit() async {
    setState(() => _busy = true);
    final err = await AdminService.rejectTournamentEntry(
      widget.entry['id'] as String,
      reason: _reason!,
      note: _note.text,
      moneyReceived: _money!,
      holdHours: _hold ? 24 : 0,
    );
    if (!mounted) return;
    if (err != null) {
      setState(() => _busy = false);
      adminToast(context, err, ok: false);
      return;
    }
    Navigator.of(context).pop(true);
  }

  Widget _label(String s) => Text(s,
      style: tStyle(12, FontWeight.w700, color: TColors.muted, letterSpacing: 1));

  Widget _reasonButton(String reason) {
    final on = _reason == reason;
    return Semantics(
      button: true,
      selected: on,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _reason = reason),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: on ? TColors.accentTint : TColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: on ? TColors.accentPressed : TColors.border,
                width: on ? 2 : 1),
          ),
          child: Text(reason == 'Other' ? 'Other…' : reason,
              style: tStyle(14, on ? FontWeight.w700 : FontWeight.w500,
                  color: on ? TColors.accentDeep : TColors.text)),
        ),
      ),
    );
  }

  Widget _moneyOption(bool value, String title, String sub) {
    final on = _money == value;
    return Semantics(
      button: true,
      selected: on,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _money = value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: on ? TColors.sunken : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: on ? TColors.green : TColors.faint, width: 2),
              ),
              child: on
                  ? Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                          color: TColors.green, shape: BoxShape.circle))
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: tStyle(14, FontWeight.w600)),
                Text(sub, style: tStyle(12, FontWeight.w400, color: TColors.muted)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 5,
                  decoration: BoxDecoration(
                      color: TColors.grabber, borderRadius: BorderRadius.circular(3)),
                ),
              ),
              const SizedBox(height: 14),
              Text('Reject payment?', style: tStyle(22, FontWeight.w800)),
              const SizedBox(height: 2),
              Text('$_pair · ${money(_claimed)} claimed',
                  style: tStyle(14, FontWeight.w400, color: TColors.text2)),
              const SizedBox(height: 14),
              _label('REASON · SHOWN TO THE PLAYERS'),
              const SizedBox(height: 8),
              // Rows, not a grid: a reason can wrap to two lines on a narrow phone.
              for (var i = 0; i < kRejectReasons.length; i += 2) ...[
                if (i > 0) const SizedBox(height: 8),
                IntrinsicHeight(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(child: _reasonButton(kRejectReasons[i])),
                    const SizedBox(width: 8),
                    Expanded(child: _reasonButton(kRejectReasons[i + 1])),
                  ]),
                ),
              ],
              const SizedBox(height: 8),
              Text(_reason == 'Other' ? 'Note (required)' : 'Note (optional)',
                  style: tStyle(12, FontWeight.w400, color: TColors.muted)),
              const SizedBox(height: 4),
              TextField(
                controller: _note,
                minLines: 2,
                maxLines: 3,
                onChanged: (_) => setState(() {}),
                style: tStyle(14, FontWeight.w400),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: TColors.surface,
                  hintText: 'Shown to the players',
                  hintStyle: tStyle(14, FontWeight.w400, color: TColors.faint),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: TColors.border)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: TColors.green)),
                ),
              ),
              const SizedBox(height: 14),
              _label('DID ANY MONEY ARRIVE?'),
              const SizedBox(height: 4),
              _moneyOption(true, 'Yes, part or all of it',
                  "Logged as received · flagged for refund if they don't fix it"),
              const SizedBox(height: 4),
              _moneyOption(false, 'No, nothing arrived', 'No refund needed'),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: TColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: TColors.border),
                ),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Hold their spot for 24 h', style: tStyle(14, FontWeight.w600)),
                      Text('They can send new proof without re-registering',
                          style: tStyle(12, FontWeight.w400, color: TColors.muted)),
                    ]),
                  ),
                  const SizedBox(width: 10),
                  Switch(
                    value: _hold,
                    activeTrackColor: TColors.green,
                    activeThumbColor: TColors.white,
                    onChanged: (v) => setState(() => _hold = v),
                  ),
                ]),
              ),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: TButton('Cancel',
                      full: true,
                      style: TButtonStyle.outlineQuiet,
                      onPressed: _busy ? null : () => Navigator.of(context).pop(false)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Material(
                    color: _ready
                        ? TColors.accentPressed
                        : TColors.accentPressed.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(TRadius.button),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: _ready ? _submit : null,
                      child: SizedBox(
                        height: 50,
                        child: Center(
                          child: Text(_busy ? 'Rejecting…' : 'Reject & notify',
                              style: tStyle(15, FontWeight.w700, color: TColors.white)),
                        ),
                      ),
                    ),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

/// Warns before a draw that leaves pairs out. True to go ahead. [onVerify] offers
/// a way to go and check them instead.
Future<bool> confirmUnverifiedPairs(
  BuildContext context, {
  required String tournamentId,
  VoidCallback? onVerify,
}) async {
  final n = await AdminService.unverifiedPairCount(tournamentId);
  if (n == 0 || !context.mounted) return true;
  final answer = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      backgroundColor: TColors.surface,
      title: Text(n == 1 ? '1 pair still pending' : '$n pairs still pending',
          style: tStyle(20, FontWeight.w800)),
      content: Text(
          "They won't be included in the draw until their payment is verified.",
          style: tStyle(14, FontWeight.w400, color: TColors.text2, height: 1.4)),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text('Cancel', style: tStyle(14, FontWeight.w600, color: TColors.muted))),
        if (onVerify != null)
          TextButton(
              onPressed: () => Navigator.pop(c, 'verify'),
              child: Text('Verify them',
                  style: tStyle(14, FontWeight.w700, color: TColors.green))),
        TextButton(
            onPressed: () => Navigator.pop(c, 'go'),
            child: Text('Generate anyway',
                style: tStyle(14, FontWeight.w700, color: TColors.accentPressed))),
      ],
    ),
  );
  if (answer == 'verify') onVerify?.call();
  return answer == 'go';
}

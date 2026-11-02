import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:padel_clay/backend/models/tournament_payment.dart';
import 'package:padel_clay/backend/services/region_service.dart' show money;
import 'package:padel_clay/frontend/theme/tournament_tokens.dart';
import 'package:padel_clay/frontend/widgets/app_toast.dart';
import 'package:padel_clay/frontend/widgets/tournament_kit.dart';

// Payment status, from design-reference/payment/*.dc.html.

/// Opens WhatsApp with a message ready.
///
/// TODO(contact): tournaments have no organiser phone or WhatsApp field, so this
/// opens WhatsApp's own contact picker. Point it at the number once there is one.
Future<void> openOrganiserChat(BuildContext context, String tournamentName) =>
    openWhatsApp(context,
        'Hi, I have a question about my payment for $tournamentName on Padel Rivals.');

Future<void> openWhatsApp(BuildContext context, String text) async {
  try {
    await launchUrl(
      Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}'),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    if (context.mounted) {
      AppToast.show(context, "Couldn't open WhatsApp", kind: ToastKind.error);
    }
  }
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _clock(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
}

/// "Tue 3 Nov, 5:00 PM".
String paymentDayTime(DateTime d) =>
    '${_days[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}, ${_clock(d)}';

/// "Today, 2:14 PM", or the date when it wasn't today.
String _sentLabel(DateTime d, DateTime now) =>
    d.year == now.year && d.month == now.month && d.day == now.day
        ? 'Today, ${_clock(d)}'
        : paymentDayTime(d);

// ── Timeline ────────────────────────────────────────────────────────────────

class _Step {
  final String title, sub;
  const _Step(this.title, this.sub);
}

/// Transfer sent ✓ → Organiser verifies (current) → You're confirmed.
class PaymentTimeline extends StatelessWidget {
  final String sentSub;
  final String confirmedSub;
  const PaymentTimeline(
      {super.key, required this.sentSub, required this.confirmedSub});

  @override
  Widget build(BuildContext context) {
    final steps = [
      _Step('Transfer sent', sentSub),
      const _Step('Organiser verifies', 'An organiser checks every transfer by hand'),
      _Step("You're confirmed", confirmedSub),
    ];
    Widget marker(int i) => switch (i) {
          0 => Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                  color: TColors.winnerCheck, shape: BoxShape.circle),
              child: const Icon(Icons.check_rounded, size: 15, color: TColors.white),
            ),
          1 => Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: TColors.accent, width: 2.5)),
              child: Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                    color: TColors.accent, shape: BoxShape.circle),
              ),
            ),
          _ => Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: TColors.borderDashed, width: 2)),
            ),
        };
    return Column(children: [
      for (var i = 0; i < steps.length; i++)
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Column(children: [
              marker(i),
              if (i < steps.length - 1)
                Expanded(
                  child: Container(
                    width: 2,
                    constraints: const BoxConstraints(minHeight: 14),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    color: TColors.border,
                  ),
                ),
            ]),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(
                    top: 2, bottom: i < steps.length - 1 ? 12 : 0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(steps[i].title,
                      style: tStyle(15, FontWeight.w700,
                          color: switch (i) {
                            0 => TColors.text,
                            1 => TColors.accentPressed,
                            _ => TColors.muted,
                          })),
                  Text(steps[i].sub,
                      style: tStyle(13, FontWeight.w400, color: TColors.muted)),
                ]),
              ),
            ),
          ]),
        ),
    ]);
  }
}

// ── Submitted page ──────────────────────────────────────────────────────────

enum PaymentCase { both, ownShare, partnerShare, newProof }

/// Full screen, straight after paying. Replaces the old snackbar.
class PaymentSubmittedScreen extends StatelessWidget {
  final PaymentCase kind;
  final String tournamentName;
  final int amount;
  final String from;
  final String to;
  final String? partnerFirstName;
  const PaymentSubmittedScreen({
    super.key,
    required this.kind,
    required this.tournamentName,
    required this.amount,
    required this.from,
    required this.to,
    this.partnerFirstName,
  });

  String get _title =>
      kind == PaymentCase.newProof ? 'New proof sent for review' : 'Payment sent for review';

  String get _partner => partnerFirstName ?? 'your partner';

  String get _after => switch (kind) {
        PaymentCase.both || PaymentCase.newProof =>
          'is held while an organiser checks your transfer.',
        PaymentCase.ownShare =>
          'is held while an organiser checks your transfer. $_partner still needs to pay their share.',
        PaymentCase.partnerShare =>
          'is held while an organiser checks your share.',
      };

  String get _cover => switch (kind) {
        PaymentCase.both => 'both of you',
        PaymentCase.ownShare || PaymentCase.partnerShare => 'your share',
        PaymentCase.newProof =>
          partnerFirstName == null ? 'your entry' : 'you and $partnerFirstName',
      };

  @override
  Widget build(BuildContext context) {
    Widget row(String label, Widget value, {bool last = false}) => Container(
          padding: EdgeInsets.symmetric(vertical: last ? 10 : 12),
          decoration: BoxDecoration(
              border: last
                  ? null
                  : const Border(bottom: BorderSide(color: TColors.divider))),
          child: Row(children: [
            Text(label, style: tStyle(14, FontWeight.w400, color: TColors.muted)),
            const SizedBox(width: 12),
            Expanded(child: Align(alignment: Alignment.centerRight, child: value)),
          ]),
        );
    Widget strong(String s, FontWeight w) => Text(s,
        textAlign: TextAlign.right, style: tStyle(15, w));

    return Scaffold(
      backgroundColor: TColors.cream,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, c) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 28, 22, 20),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: c.maxHeight - 48),
              child: IntrinsicHeight(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Center(
                    // The design has a green tick here. Nothing is verified yet,
                    // so this is the same clock the pending state uses.
                    child: Container(
                      width: 76,
                      height: 76,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                          color: TColors.accentSoft, shape: BoxShape.circle),
                      child: const Icon(Icons.schedule_rounded,
                          size: 36, color: TColors.accent),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(_title,
                      textAlign: TextAlign.center,
                      style: tStyle(26, FontWeight.w800)),
                  const SizedBox(height: 12),
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 300),
                      child: Text.rich(
                        TextSpan(children: [
                          const TextSpan(text: 'Your spot in '),
                          TextSpan(
                              text: tournamentName,
                              style: tStyle(15, FontWeight.w700,
                                  color: TColors.text2, height: 1.4)),
                          TextSpan(text: ' $_after'),
                        ]),
                        textAlign: TextAlign.center,
                        style: tStyle(15, FontWeight.w400,
                            color: TColors.text2, height: 1.4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    decoration: BoxDecoration(
                      color: TColors.surface,
                      border: Border.all(color: TColors.border),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(children: [
                      row('Amount', strong('${money(amount)} · $_cover', FontWeight.w700)),
                      row('From', strong(from, FontWeight.w600)),
                      row('To', strong(to, FontWeight.w600)),
                      row(
                          'Screenshot',
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.image_outlined,
                                size: 16, color: TColors.statusGreenText),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text('Uploaded',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: tStyle(14, FontWeight.w600,
                                      color: TColors.statusGreenText)),
                            ),
                          ]),
                          last: true),
                    ]),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: TColors.surface,
                      border: Border.all(color: TColors.border),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: PaymentTimeline(
                      sentSub: 'Just now',
                      confirmedSub: partnerFirstName == null
                          ? "We'll notify you"
                          : "We'll notify you and $partnerFirstName",
                    ),
                  ),
                  const Spacer(),
                  const SizedBox(height: 20),
                  TButton('Back to tournament',
                      full: true,
                      height: 52,
                      fontSize: 16,
                      radius: 16,
                      style: TButtonStyle.green,
                      onPressed: () => Navigator.of(context).pop()),
                  const SizedBox(height: 10),
                  TButton('Message the organiser',
                      full: true,
                      height: 48,
                      radius: 16,
                      style: TButtonStyle.outlineQuiet,
                      icon: Icons.chat_bubble_outline_rounded,
                      onPressed: () => openOrganiserChat(context, tournamentName)),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Detail screen cards ─────────────────────────────────────────────────────

Widget _iconCircle(IconData icon, Color bg, Color fg, {double size = 40}) => Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Icon(icon, size: size / 2, color: fg),
    );

/// The bottom bar's leading icon, by phase.
Widget paymentBarIcon(EntryPayment p) => switch (p.phase) {
      PaymentPhase.free || PaymentPhase.confirmed => _iconCircle(
          Icons.check_rounded, TColors.statusGreenBg, TColors.statusGreenText),
      PaymentPhase.actionNeeded || PaymentPhase.released => _iconCircle(
          Icons.warning_amber_rounded, TColors.accentSoft, TColors.accentPressed),
      _ => _iconCircle(Icons.schedule_rounded, TColors.accentSoft, TColors.accent),
    };

/// Colour of the bottom bar's second line.
Color paymentBarSubColor(EntryPayment p) => switch (p.phase) {
      PaymentPhase.confirmed => TColors.statusGreenText,
      PaymentPhase.actionNeeded || PaymentPhase.released => TColors.accentPressed,
      _ => TColors.muted,
    };

class _SquareIconButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _SquareIconButton(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        child: Material(
          color: TColors.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: TColors.accentTintBorder)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(icon, size: 18, color: TColors.accentPressed)),
          ),
        ),
      );
}

/// A note that the draw went ahead without this pair.
Widget _notInDraw() => Text(
      "The draw is out and your pair isn't in it. Message the organiser.",
      style: tStyle(13, FontWeight.w600, color: TColors.accentDeep, height: 1.4),
    );

/// Terracotta tint and clock: spot held, payment under review.
class PaymentPendingCard extends StatelessWidget {
  final EntryPayment payment;
  final String tournamentName;
  final String? drawLabel;
  final bool drawIsOut;
  final VoidCallback? onReplace;
  const PaymentPendingCard({
    super.key,
    required this.payment,
    required this.tournamentName,
    this.drawLabel,
    this.drawIsOut = false,
    this.onReplace,
  });

  @override
  Widget build(BuildContext context) {
    final sent = payment.sentAt;
    final other = payment.otherFirstName;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TColors.accentTint,
        border: Border.all(color: TColors.accentTintBorder),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          _iconCircle(Icons.schedule_rounded, TColors.accentSoft, TColors.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Payment under review',
                  style: tStyle(17, FontWeight.w800, color: TColors.accentDeep)),
              Text(payment.reviewLine,
                  style: tStyle(13, FontWeight.w400, color: TColors.accentDeep)),
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: TColors.surface, borderRadius: BorderRadius.circular(14)),
          child: PaymentTimeline(
            sentSub: sent == null ? 'Sent' : _sentLabel(sent, payment.now),
            confirmedSub: drawLabel != null
                ? 'Before the draw on $drawLabel'
                : other == null
                    ? "We'll notify you"
                    : "We'll notify you and $other",
          ),
        ),
        if (drawIsOut) ...[const SizedBox(height: 12), _notInDraw()],
        const SizedBox(height: 14),
        Row(children: [
          if (onReplace != null) ...[
            Expanded(
              child: TButton('Replace screenshot',
                  height: 44,
                  fontSize: 14,
                  radius: 12,
                  style: TButtonStyle.outlineAccent,
                  icon: Icons.upload_rounded,
                  onPressed: onReplace),
            ),
            const SizedBox(width: 8),
          ] else
            const Spacer(),
          _SquareIconButton(
              icon: Icons.chat_bubble_outline_rounded,
              label: 'Message the organiser',
              onTap: () => openOrganiserChat(context, tournamentName)),
        ]),
      ]),
    );
  }
}

/// One row per player: Verified / Being checked / Not paid yet.
class PaymentSplitCard extends StatelessWidget {
  final EntryPayment payment;
  final String tournamentName;
  final bool drawIsOut;
  final VoidCallback? onReplace;
  const PaymentSplitCard({
    super.key,
    required this.payment,
    required this.tournamentName,
    this.drawIsOut = false,
    this.onReplace,
  });

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    return parts.take(2).map((p) => p.isEmpty ? '' : p[0].toUpperCase()).join();
  }

  Widget _chip(ShareStatus s) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: switch (s) {
            ShareStatus.verified => TColors.statusGreenBg,
            ShareStatus.beingChecked => TColors.accentSoft,
            ShareStatus.notPaid => TColors.neutralChip,
          },
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (s == ShareStatus.verified) ...[
            const Icon(Icons.check_rounded, size: 12, color: TColors.statusGreenText),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              switch (s) {
                ShareStatus.verified => 'Verified',
                ShareStatus.beingChecked => 'Being checked',
                ShareStatus.notPaid => 'Not paid yet',
              },
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tStyle(12, FontWeight.w700,
                  color: switch (s) {
                    ShareStatus.verified => TColors.statusGreenText,
                    ShareStatus.beingChecked => TColors.accentDeep,
                    ShareStatus.notPaid => TColors.text2,
                  }),
            ),
          ),
        ]),
      );

  Widget _row(BuildContext context, PaymentShare s) {
    final first = s.name.split(' ').first;
    final Widget? action = !s.isMe && s.status == ShareStatus.notPaid
        ? TButton('Remind',
            height: 36,
            fontSize: 13,
            radius: 10,
            horizontalPadding: 12,
            style: TButtonStyle.green,
            icon: Icons.chat_bubble_outline_rounded,
            onPressed: () => openWhatsApp(
                context,
                'Hi $first, your ${money(s.amount)} share for $tournamentName '
                "isn't paid yet. Open Padel Rivals to pay it, so we're in the draw."))
        : s.isMe && s.status == ShareStatus.beingChecked && onReplace != null
            ? TButton('Replace',
                height: 36,
                fontSize: 13,
                radius: 10,
                horizontalPadding: 12,
                style: TButtonStyle.outlineAccent,
                onPressed: onReplace)
            : null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: TColors.divider))),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: s.isMe ? TColors.green : TColors.avatar,
              shape: BoxShape.circle),
          child: Text(s.isMe ? 'You' : _initials(s.name),
              style: tStyle(13, FontWeight.w700,
                  color: s.isMe ? TColors.white : TColors.text2)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${s.isMe ? 'You' : s.name} · ${money(s.amount)}',
                style: tStyle(15, FontWeight.w700)),
            const SizedBox(height: 4),
            _chip(s.status),
          ]),
        ),
        if (action != null) ...[const SizedBox(width: 8), action],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final done = payment.verifiedShares;
    final total = payment.shares.length;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: TColors.surface,
        border: Border.all(color: TColors.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          color: TColors.sunkenSoft,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('$done of $total shares paid', style: tStyle(17, FontWeight.w800)),
            const SizedBox(height: 4),
            Text('Your pair is confirmed once both shares are verified.',
                style: tStyle(13, FontWeight.w400, color: TColors.text2)),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: total == 0 ? 0 : done / total,
                minHeight: 8,
                backgroundColor: TColors.barTrack,
                color: TColors.winnerCheck,
              ),
            ),
          ]),
        ),
        for (final s in payment.shares) _row(context, s),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: drawIsOut
              ? _notInDraw()
              : Text("Unpaid pairs aren't included in the draw.",
                  style: tStyle(13, FontWeight.w400, color: TColors.muted)),
        ),
      ]),
    );
  }
}

/// Green: an organiser has verified the payment.
class PaymentConfirmedCard extends StatelessWidget {
  final EntryPayment payment;
  final String pair;
  final bool drawIsOut;
  const PaymentConfirmedCard(
      {super.key, required this.payment, required this.pair, this.drawIsOut = false});

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: TColors.statusGreenBg,
            border: Border.all(color: TColors.statusGreenBorder),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(children: [
            _iconCircle(Icons.check_rounded, TColors.winnerCheck, TColors.white, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text("You're confirmed",
                    style: tStyle(17, FontWeight.w800, color: TColors.statusGreenText)),
                Text('Payment of ${money(payment.total)} verified · $pair',
                    style: tStyle(13, FontWeight.w400, color: TColors.statusGreenText)),
              ]),
            ),
          ]),
        ),
        if (!drawIsOut) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: TColors.surface,
              border: Border.all(color: TColors.border),
              borderRadius: BorderRadius.circular(TRadius.matchCard),
            ),
            child: Row(children: [
              _iconCircle(Icons.notifications_none_rounded, TColors.sunken, TColors.green),
              const SizedBox(width: 12),
              Expanded(
                child: Text("We'll notify you when the draw is out.",
                    style: tStyle(14, FontWeight.w400, color: TColors.text2)),
              ),
            ]),
          ),
        ],
      ]);
}

/// 2px deep terracotta. Rejected with a hold, or released once the hold is gone.
class PaymentRejectedCard extends StatelessWidget {
  final EntryPayment payment;
  final String tournamentName;
  final VoidCallback? onSendProof;
  const PaymentRejectedCard({
    super.key,
    required this.payment,
    required this.tournamentName,
    this.onSendProof,
  });

  @override
  Widget build(BuildContext context) {
    final released = payment.phase == PaymentPhase.released;
    final hold = payment.holdUntil;
    final sub = released
        ? 'Your spot was released. Register again below if spots are left.'
        : hold != null
            ? 'Your spot is held until ${paymentDayTime(hold)}'
            : null;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TColors.surface,
        border: Border.all(color: TColors.accentPressed, width: 2),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          _iconCircle(Icons.warning_amber_rounded, TColors.accentSoft, TColors.accentPressed),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text("We couldn't verify your payment",
                  style: tStyle(17, FontWeight.w800, color: TColors.accentDeep)),
              if (sub != null)
                Text(sub,
                    style: tStyle(13, FontWeight.w400, color: TColors.accentDeep)),
            ]),
          ),
        ]),
        if (payment.reason != null) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
                color: TColors.accentTint, borderRadius: BorderRadius.circular(14)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('REASON FROM THE ORGANISER',
                  style: tStyle(12, FontWeight.w700,
                      color: TColors.accentPressed, letterSpacing: 1)),
              const SizedBox(height: 4),
              Text(payment.reason!, style: tStyle(15, FontWeight.w400, height: 1.4)),
            ]),
          ),
        ],
        if (!released && !payment.canSendProof) ...[
          const SizedBox(height: 12),
          Text(
              'Your share is verified. ${payment.otherFirstName ?? 'Your partner'} needs to send new proof.',
              style: tStyle(13, FontWeight.w600, color: TColors.accentDeep, height: 1.4)),
        ],
        const SizedBox(height: 14),
        if (onSendProof != null && !released) ...[
          TButton('Send new proof',
              full: true,
              height: 50,
              icon: Icons.upload_rounded,
              onPressed: onSendProof),
          const SizedBox(height: 8),
        ],
        TButton('Message the organiser',
            full: true,
            height: 46,
            fontSize: 14,
            style: TButtonStyle.outlineQuiet,
            icon: Icons.chat_bubble_outline_rounded,
            onPressed: () => openOrganiserChat(context, tournamentName)),
      ]),
    );
  }
}

// ── List cards ──────────────────────────────────────────────────────────────

/// Replaces the plain REGISTERED chip on the green card header.
class PaymentChip extends StatelessWidget {
  final EntryPayment payment;
  const PaymentChip(this.payment, {super.key});

  @override
  Widget build(BuildContext context) {
    final label = payment.chipLabel;
    if (label == null) return const SizedBox.shrink();
    final (Color bg, Color fg) = switch (payment.phase) {
      PaymentPhase.actionNeeded => (TColors.accentSoft, TColors.accentDeep),
      PaymentPhase.confirmed => (TColors.statusGreenBg, TColors.statusGreenText),
      _ => (TColors.white.withValues(alpha: 0.14), TColors.white),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(9)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (payment.phase == PaymentPhase.confirmed) ...[
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
                color: TColors.statusGreenDot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
        ],
        Text(label,
            style: tStyle(11, FontWeight.w700, color: fg, letterSpacing: 0.8)),
      ]),
    );
  }
}

/// The line under a list card's header: status and a link.
class PaymentCardFooter extends StatelessWidget {
  final EntryPayment payment;
  final String pair;
  const PaymentCardFooter(this.payment, {super.key, required this.pair});

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg, IconData icon) = switch (payment.phase) {
      PaymentPhase.actionNeeded || PaymentPhase.released =>
        (TColors.accentTint, TColors.accentPressed, Icons.warning_amber_rounded),
      PaymentPhase.confirmed || PaymentPhase.free =>
        (TColors.surface, TColors.statusGreenText, Icons.check_rounded),
      _ => (TColors.surface, TColors.text2, Icons.schedule_rounded),
    };
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(children: [
        Icon(icon, size: 18, color: fg),
        const SizedBox(width: 10),
        Expanded(
          child: Text(payment.cardLine(pair),
              style: tStyle(14, FontWeight.w600, color: fg)),
        ),
        const SizedBox(width: 8),
        Text('${payment.cardLink} →', style: tStyle(14, FontWeight.w700, color: fg)),
      ]),
    );
  }
}

/// The status row at the top of the Manage sheet.
class PaymentManageRow extends StatelessWidget {
  final EntryPayment payment;
  final String pair;
  const PaymentManageRow(this.payment, {super.key, required this.pair});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          paymentBarIcon(payment),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(payment.barTitle(pair), style: tStyle(15, FontWeight.w700)),
              Text(payment.barSub,
                  style: tStyle(13, FontWeight.w400, color: paymentBarSubColor(payment))),
            ]),
          ),
        ]),
      );
}

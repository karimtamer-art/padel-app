/// Why an order was rejected or cancelled.
///
/// Rejecting used to just set `status = 'cancelled'`, and every cancellation
/// sent the player the same line — "was cancelled, contact support if this is
/// unexpected" — which told them nothing and pushed the work onto support.
/// A transfer we never received and an item that sold out are completely
/// different problems for the player, and only one of them owes them money.
///
/// [playerLine] is the sentence the player reads, so it is written to be read
/// by the person whose order just died: plain, specific, no blame.
///
/// NOTE: the notification body is composed by the `notify_order_status`
/// trigger in Postgres, which carries its own copy of these sentences (a
/// trigger cannot call into Dart). If you change the wording here, change
/// `_order_cancel_text()` in supabase/migration_player_app.sql too.
class CancelReason {
  final String code;

  /// What the admin picks from in the console.
  final String adminLabel;

  /// What the player is told. Empty for [other] — the note carries it.
  final String playerLine;

  /// True when we are holding money that has to go back. Only actually
  /// surfaced for orders paid by InstaPay — nothing was collected on a
  /// cash-on-delivery order, so there is nothing to refund.
  final bool refunds;

  /// Payment-verification reasons make no sense for a cash order.
  final bool paymentOnly;

  /// [other] is useless without a written explanation.
  final bool noteRequired;

  const CancelReason(
    this.code,
    this.adminLabel,
    this.playerLine, {
    this.refunds = false,
    this.paymentOnly = false,
    this.noteRequired = false,
  });

  static const all = <CancelReason>[
    CancelReason(
      'payment_not_received',
      'Transfer not received',
      "We couldn't find your transfer in our account.",
      paymentOnly: true,
    ),
    CancelReason(
      'payment_wrong_amount',
      'Wrong amount transferred',
      "The amount transferred didn't match this order's total.",
      refunds: true,
      paymentOnly: true,
    ),
    CancelReason(
      'payment_unverifiable',
      "Screenshot doesn't show a completed transfer",
      "The screenshot didn't show a completed transfer we could match to this order.",
      paymentOnly: true,
    ),
    CancelReason(
      'out_of_stock',
      'Item out of stock',
      'An item in this order sold out before we could confirm it.',
      refunds: true,
    ),
    CancelReason(
      'address_issue',
      'Address unusable',
      "We couldn't deliver to the address on this order.",
      refunds: true,
    ),
    CancelReason(
      'duplicate',
      'Duplicate order',
      'This looked like a duplicate of another order you placed.',
      refunds: true,
    ),
    CancelReason(
      'customer_request',
      'Customer asked to cancel',
      'Cancelled at your request.',
      refunds: true,
    ),
    CancelReason(
      'other',
      'Other',
      '',
      noteRequired: true,
    ),
  ];

  /// The reasons worth offering for this order. Payment-verification reasons
  /// are hidden on cash orders, where no transfer exists to be wrong.
  static List<CancelReason> forOrder({required bool instapay}) =>
      all.where((r) => instapay || !r.paymentOnly).toList();

  static CancelReason? byCode(String? code) {
    if (code == null || code.isEmpty) return null;
    for (final r in all) {
      if (r.code == code) return r;
    }
    return null;
  }

  /// What to show the player on the order itself: the reason, then the
  /// admin's note if they left one, then the refund line where we owe money.
  ///
  /// [instapay] gates the refund sentence — on a cash order the player never
  /// paid, so promising a refund would be nonsense.
  static String playerExplanation(
    String? code,
    String? note, {
    required bool instapay,
  }) {
    final r = byCode(code);
    final parts = <String>[
      if (r != null && r.playerLine.isNotEmpty) r.playerLine,
      if (note != null && note.trim().isNotEmpty) note.trim(),
      if (r != null && r.refunds && instapay)
        'We will transfer your payment back to the InstaPay account you sent it from.',
    ];
    // Nothing recorded — old orders cancelled before reasons existed.
    if (parts.isEmpty) return 'Contact support if this is unexpected.';
    return parts.join('\n\n');
  }
}

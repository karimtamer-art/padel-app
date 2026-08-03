import 'package:flutter_test/flutter_test.dart';
import 'package:padel_clay/backend/models/order_cancel_reason.dart';

/// The refund sentence is a promise about money, so it must appear when we
/// are holding the player's cash and never when we are not.
void main() {
  const refundLine =
      'We will transfer your payment back to the InstaPay account you sent it from.';

  group('playerExplanation', () {
    test('leads with the reason', () {
      final s = CancelReason.playerExplanation('out_of_stock', null,
          instapay: false);
      expect(s, contains('sold out'));
    });

    test('promises a refund when we hold InstaPay money', () {
      final s = CancelReason.playerExplanation('out_of_stock', null,
          instapay: true);
      expect(s, contains(refundLine));
    });

    test('promises nothing on a cash order — they never paid', () {
      final s = CancelReason.playerExplanation('out_of_stock', null,
          instapay: false);
      expect(s, isNot(contains(refundLine)));
    });

    test('no refund when the transfer never arrived', () {
      final s = CancelReason.playerExplanation('payment_not_received', null,
          instapay: true);
      expect(s, isNot(contains(refundLine)));
      expect(s, contains("couldn't find your transfer"));
    });

    test('no refund when the screenshot was unusable', () {
      final s = CancelReason.playerExplanation('payment_unverifiable', null,
          instapay: true);
      expect(s, isNot(contains(refundLine)));
    });

    test('includes the admin note', () {
      final s = CancelReason.playerExplanation(
          'out_of_stock', '  The blue grip is back in stock Monday.  ',
          instapay: false);
      expect(s, contains('The blue grip is back in stock Monday.'));
      // Trimmed, not padded into the output.
      expect(s, isNot(contains('  The blue')));
    });

    test('"other" carries only the note', () {
      final s = CancelReason.playerExplanation('other', 'Store closed for Eid.',
          instapay: false);
      expect(s, 'Store closed for Eid.');
    });

    test('falls back for orders cancelled before reasons existed', () {
      expect(CancelReason.playerExplanation(null, null, instapay: false),
          'Contact support if this is unexpected.');
      expect(CancelReason.playerExplanation('', '', instapay: true),
          'Contact support if this is unexpected.');
    });

    test('an unknown code degrades to the fallback, not a crash', () {
      expect(CancelReason.playerExplanation('nonsense_code', null,
          instapay: true),
          'Contact support if this is unexpected.');
    });
  });

  group('forOrder', () {
    test('hides payment reasons on a cash order', () {
      final codes = CancelReason.forOrder(instapay: false).map((r) => r.code);
      expect(codes, isNot(contains('payment_not_received')));
      expect(codes, contains('out_of_stock'));
    });

    test('offers payment reasons on an InstaPay order', () {
      final codes = CancelReason.forOrder(instapay: true).map((r) => r.code);
      expect(codes, contains('payment_not_received'));
    });
  });

  test('every reason has an admin label, and only "other" needs a note', () {
    for (final r in CancelReason.all) {
      expect(r.adminLabel, isNotEmpty, reason: r.code);
      // A reason with no sentence of its own must demand a written one.
      if (r.playerLine.isEmpty) expect(r.noteRequired, isTrue, reason: r.code);
    }
  });
}

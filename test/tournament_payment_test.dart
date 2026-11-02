import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:padel_clay/backend/models/tournament_payment.dart';
import 'package:padel_clay/frontend/screens/tournaments/payment_status.dart';

const me = 'me', omar = 'omar';
final now = DateTime(2026, 11, 2, 16, 14);

Map<String, dynamic> entry(String status,
        {String mode = 'both',
        bool payer = false,
        bool partner = false,
        String? partnerSender,
        String playerId = me,
        String partnerId = omar,
        DateTime? hold,
        DateTime? resubmitted}) =>
    {
      'player_id': playerId,
      'player_name': playerId == me ? 'Nour Salem' : 'Omar Hany',
      'partner_id': partnerId,
      'partner_name': partnerId == me ? 'Nour Salem' : 'Omar Hany',
      'status': status,
      'fee_mode': mode,
      'payer_paid': payer,
      'partner_paid': partner,
      'partner_instapay_sender': partnerSender,
      'instapay_sender': 'nour.salem@instapay',
      'paid_amount': mode == 'split' ? 500 : 1000,
      'registered_at':
          now.subtract(const Duration(hours: 2)).toUtc().toIso8601String(),
      'hold_until': hold?.toUtc().toIso8601String(),
      'proof_resubmitted_at': resubmitted?.toUtc().toIso8601String(),
    };

EntryPayment pay(Map<String, dynamic> e, {Map<String, dynamic>? rejection, String uid = me}) =>
    EntryPayment.of(e, uid: uid, fee: 500, rejection: rejection, now: now)!;

void _noTickBeforeVerified(EntryPayment p) {
  expect(p.isSettled, isFalse);
  expect(p.barTitle('You & Omar'), isNot(contains("You're in")));
  expect(p.cardLine('You & Omar'), isNot(contains("You're in")));
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(const Size(360, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ));
  await tester.pump();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  group('pending, paying for both', () {
    final p = pay(entry('pending'));

    test('under review, and never looks confirmed', () {
      expect(p.phase, PaymentPhase.underReview);
      _noTickBeforeVerified(p);
      expect(p.barTitle('You & Omar'), 'Spot held · You & Omar');
      expect(p.barSub, 'Payment under review');
      expect(p.chipLabel, 'PAYMENT PENDING');
      expect(p.cardLine('x'), 'Under review · sent 2 h ago');
      expect(p.cardLink, 'View');
    });

    test('amounts say who they cover', () {
      expect(p.amountLine, 'EGP 1,000 · both of you');
      expect(p.reviewLine, 'EGP 1,000 · sent 2 h ago from nour.salem');
    });

    test('can replace the screenshot', () => expect(p.canSendProof, isTrue));

    test('the partner sees the same state', () {
      final q = pay(entry('pending'), uid: omar);
      expect(q.phase, PaymentPhase.underReview);
      expect(q.otherFirstName, 'Nour');
      expect(q.canSendProof, isTrue);
    });

    testWidgets('card: review line, timeline and Replace, with no confirmed step done',
        (tester) async {
      await _pump(
          tester,
          PaymentPendingCard(
              payment: p, tournamentName: 'Open D', onReplace: () {}));
      expect(find.text('Payment under review'), findsOneWidget);
      expect(find.text('Organiser verifies'), findsOneWidget);
      expect(find.text('Replace screenshot'), findsOneWidget);
      expect(find.text('Today, 2:14 PM'), findsOneWidget);
    });

    testWidgets('a draw without this pair is said out loud', (tester) async {
      await _pump(
          tester,
          PaymentPendingCard(
              payment: p, tournamentName: 'Open D', drawIsOut: true));
      expect(find.textContaining("your pair isn't in it"), findsOneWidget);
    });
  });

  group('split', () {
    test('0 verified, partner not paid', () {
      final p = pay(entry('pending', mode: 'split'));
      expect(p.phase, PaymentPhase.split);
      _noTickBeforeVerified(p);
      expect(p.verifiedShares, 0);
      expect(p.shares.map((s) => s.status),
          [ShareStatus.beingChecked, ShareStatus.notPaid]);
      expect(p.barTitle('You & Omar'), 'Spot held · You & Omar');
      expect(p.barSub, 'Your EGP 500 is being checked');
      expect(p.amountLine, 'EGP 500 · your share');
      expect(p.canSendProof, isTrue);
    });

    test('0 verified, both sent', () {
      final p = pay(entry('pending', mode: 'split', partnerSender: 'omar@instapay'));
      expect(p.shares.last.status, ShareStatus.beingChecked);
      expect(p.barSub, 'Both shares are being checked');
    });

    test('1 verified, waiting for the partner', () {
      final p = pay(entry('pending', mode: 'split', payer: true));
      _noTickBeforeVerified(p);
      expect(p.verifiedShares, 1);
      expect(p.barTitle('You & Omar'), "Waiting for Omar's share");
      expect(p.barSub, 'Your EGP 500 is verified');
      expect(p.canSendProof, isFalse, reason: 'nothing of mine left to prove');
    });

    test('1 verified, as the partner who still owes', () {
      final p = pay(entry('pending', mode: 'split', payer: true), uid: omar);
      expect(p.verifiedShares, 1);
      expect(p.barSub, "Your EGP 500 share isn't paid yet");
      expect(p.cardLink, 'Pay');
      expect(p.canSendProof, isTrue);
    });

    test('2 verified is confirmed', () {
      final p = pay(entry('paid', mode: 'split', payer: true, partner: true));
      expect(p.phase, PaymentPhase.confirmed);
      expect(p.total, 1000);
    });

    testWidgets('card: a row per player, Remind on the unpaid share', (tester) async {
      final p = pay(entry('pending', mode: 'split', payer: true));
      await _pump(tester, PaymentSplitCard(payment: p, tournamentName: 'Open D'));
      expect(find.text('1 of 2 shares paid'), findsOneWidget);
      expect(find.text('Verified'), findsOneWidget);
      expect(find.text('Not paid yet'), findsOneWidget);
      expect(find.text('Remind'), findsOneWidget);
      expect(find.text("Unpaid pairs aren't included in the draw."), findsOneWidget);
    });

    testWidgets('no Remind for your own unpaid share', (tester) async {
      final p = pay(entry('pending', mode: 'split', payer: true), uid: omar);
      await _pump(tester, PaymentSplitCard(payment: p, tournamentName: 'Open D'));
      expect(find.text('Remind'), findsNothing);
    });
  });

  group('confirmed', () {
    final p = pay(entry('paid', payer: true, partner: true));

    test('the only state that says you\'re in', () {
      expect(p.isSettled, isTrue);
      expect(p.barTitle('You & Omar'), "You're in · You & Omar");
      expect(p.barSub, 'Paid · confirmed');
      expect(p.chipLabel, 'CONFIRMED');
      expect(p.canSendProof, isFalse);
    });

    testWidgets('card', (tester) async {
      await _pump(tester, PaymentConfirmedCard(payment: p, pair: 'You & Omar'));
      expect(find.text("You're confirmed"), findsOneWidget);
      expect(find.text('Payment of EGP 1,000 verified · You & Omar'), findsOneWidget);
      expect(find.text("We'll notify you when the draw is out."), findsOneWidget);
    });

    test('added by the organiser: settled, but no payment is claimed', () {
      final q = pay(entry('registered'));
      expect(q.isSettled, isTrue);
      expect(q.byOrganiser, isTrue);
      expect(q.barSub, 'Registered by the organiser');
    });
  });

  group('rejected with a hold', () {
    final hold = DateTime(2026, 11, 3, 17);
    final p = pay(entry('rejected', hold: hold),
        rejection: {'reason': "Amount doesn't match", 'note': 'We received EGP 500.'});

    test('action needed, not unregistered', () {
      expect(p.phase, PaymentPhase.actionNeeded);
      _noTickBeforeVerified(p);
      expect(p.barTitle('x'), 'Action needed');
      expect(p.barSub, 'Payment not verified');
      expect(p.chipLabel, 'ACTION NEEDED');
      expect(p.cardLink, 'Fix');
      expect(p.holdUntil, hold);
      expect(p.reason, "Amount doesn't match. We received EGP 500.");
      expect(p.canSendProof, isTrue);
    });

    testWidgets('card: reason, hold and both buttons', (tester) async {
      await _pump(
          tester,
          PaymentRejectedCard(
              payment: p, tournamentName: 'Open D', onSendProof: () {}));
      expect(find.text("We couldn't verify your payment"), findsOneWidget);
      expect(find.text('Your spot is held until Tue 3 Nov, 5:00 PM'), findsOneWidget);
      expect(find.text('REASON FROM THE ORGANISER'), findsOneWidget);
      expect(find.text('Send new proof'), findsOneWidget);
      expect(find.text('Message the organiser'), findsOneWidget);
    });

    test('Other shows the note alone', () {
      final q = pay(entry('rejected', hold: hold),
          rejection: {'reason': 'Other', 'note': 'Wrong account.'});
      expect(q.reason, 'Wrong account.');
    });

    test('split, my share already verified: nothing for me to send', () {
      final q = pay(entry('rejected', mode: 'split', payer: true, hold: hold),
          rejection: {'reason': 'Transfer not received'});
      expect(q.canSendProof, isFalse);
    });
  });

  group('hold expired', () {
    test('a lapsed hold reads as released before the server gets to it', () {
      final p = pay(entry('rejected', hold: now.subtract(const Duration(minutes: 1))),
          rejection: {'reason': 'Screenshot unclear'});
      expect(p.phase, PaymentPhase.released);
      expect(p.canSendProof, isFalse);
      expect(p.holdUntil, isNull);
      expect(p.chipLabel, isNull);
    });

    test('withdrawn with a reason is released', () {
      final p = pay(entry('withdrawn'), rejection: {'reason': 'Screenshot unclear'});
      expect(p.phase, PaymentPhase.released);
      expect(p.reason, 'Screenshot unclear');
    });

    test('withdrawn by choice has nothing to say', () {
      expect(EntryPayment.of(entry('withdrawn'), uid: me, fee: 500, now: now), isNull);
    });

    testWidgets('card: says the spot went, offers no proof button', (tester) async {
      final p = pay(entry('withdrawn'), rejection: {'reason': 'Screenshot unclear'});
      await _pump(tester, PaymentRejectedCard(payment: p, tournamentName: 'Open D'));
      expect(find.textContaining('Your spot was released'), findsOneWidget);
      expect(find.text('Screenshot unclear'), findsOneWidget);
      expect(find.text('Send new proof'), findsNothing);
    });
  });

  group('resubmitted', () {
    final p = pay(entry('pending', resubmitted: now.subtract(const Duration(minutes: 5))));

    test('back under review, timed from the new proof', () {
      expect(p.phase, PaymentPhase.underReview);
      expect(p.resubmitted, isTrue);
      expect(p.sentAgo, '5 min ago');
      _noTickBeforeVerified(p);
    });
  });

  group('submitted page', () {
    Future<void> open(WidgetTester tester, PaymentCase kind, int amount) async {
      await tester.binding.setSurfaceSize(const Size(360, 780));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: PaymentSubmittedScreen(
          kind: kind,
          tournamentName: 'Open D',
          amount: amount,
          from: 'nour.salem@instapay',
          to: 'padelrivals@instapay',
          partnerFirstName: 'Omar',
        ),
      ));
      await tester.pump();
    }

    testWidgets('paying for both', (tester) async {
      await open(tester, PaymentCase.both, 1000);
      expect(find.text('Payment sent for review'), findsOneWidget);
      expect(find.text('EGP 1,000 · both of you'), findsOneWidget);
      expect(find.text('Uploaded'), findsOneWidget);
      expect(find.text('Back to tournament'), findsOneWidget);
      expect(find.text('Message the organiser'), findsOneWidget);
      expect(find.byIcon(Icons.schedule_rounded), findsOneWidget,
          reason: 'a clock, not a tick: nothing is verified yet');
    });

    testWidgets('own share', (tester) async {
      await open(tester, PaymentCase.ownShare, 500);
      expect(find.text('EGP 500 · your share'), findsOneWidget);
      expect(find.textContaining('Omar still needs to pay'), findsOneWidget);
    });

    testWidgets('partner\'s share', (tester) async {
      await open(tester, PaymentCase.partnerShare, 500);
      expect(find.text('EGP 500 · your share'), findsOneWidget);
      expect(find.textContaining('checks your share'), findsOneWidget);
    });

    testWidgets('new proof', (tester) async {
      await open(tester, PaymentCase.newProof, 1000);
      expect(find.text('New proof sent for review'), findsOneWidget);
    });
  });

  group('the SQL behind it', () {
    final sql = File('supabase/migration_player_app.sql')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');

    test('the reasons match, in the same words', () {
      for (final r in kRejectReasons) {
        expect(sql, contains("'${r.replaceAll("'", "''")}'"), reason: r);
      }
    });

    test('rpcs are signed-in only', () {
      for (final f in [
        'reject_tournament_entry(uuid, text, text, boolean, int)',
        'resubmit_payment_proof(uuid, text, text)',
      ]) {
        expect(sql, contains('revoke all on function public.$f from public, anon;'));
        expect(sql, contains('grant execute on function public.$f to authenticated;'));
      }
    });

    test('helpers are closed to every client role', () {
      for (final f in [
        '_release_expired_holds(uuid)',
        '_entry_reject_cleanup()',
        '_cairo_label(timestamptz)',
      ]) {
        expect(sql,
            contains('revoke all on function public.$f from public, anon, authenticated;'));
      }
    });

    test('the reason is not on the table everyone can read', () {
      expect(sql, isNot(contains('add column if not exists reject_note')));
      expect(sql, contains('revoke all on public.tournament_entry_rejections'));
    });

    test('nothing tells a partner their entry is paid', () {
      expect(sql, isNot(contains('your entry is paid')));
    });

    test('players cannot write their own entry', () {
      expect(sql, contains('drop policy if exists "withdraw self"'));
      expect(sql, isNot(contains('create policy "withdraw self"')));
      expect(sql, isNot(contains('create policy "register self"')));
    });
  });
}

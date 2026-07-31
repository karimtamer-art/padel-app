import 'package:flutter_test/flutter_test.dart';
import 'package:padel_clay/backend/services/tournament_service.dart';

/// Registration closes exactly three ways: 1 hour before the start time, when
/// capacity fills, or when the organizer closes it by hand. These mirror the
/// SQL rules in `tournament_reg_deadline` / `register_for_tournament` — if you
/// change one, change both.
///
/// The clock is pinned via `asOf` so nothing here depends on when it runs.
void main() {
  // A same-day tournament: Wed 5 Aug 2026, first ball at 6:30 PM.
  Map<String, dynamic> sameDay({int capacity = 16}) => {
        'status': 'auto',
        'start_date': '2026-08-05',
        'start_time': '6:30 PM',
        'capacity': capacity,
      };

  String statusAt(Map<String, dynamic> t, DateTime now, [int entries = 0]) =>
      TournamentService.tournamentStatus(t, entries, asOf: now);

  group('same-day registration window', () {
    test('open in the morning of the tournament day', () {
      // The old rule treated start-midnight as both "started" and "ended", so a
      // same-day event read as completed from 00:00 on the day it was played.
      expect(statusAt(sameDay(), DateTime(2026, 8, 5, 9, 0)), 'open');
    });

    test('open right up to the 1-hour mark', () {
      expect(statusAt(sameDay(), DateTime(2026, 8, 5, 17, 29)), 'open');
    });

    test('closed exactly on the 1-hour mark', () {
      expect(statusAt(sameDay(), DateTime(2026, 8, 5, 17, 30)), 'closed');
    });

    test('closed inside the final hour', () {
      expect(statusAt(sameDay(), DateTime(2026, 8, 5, 18, 0)), 'closed');
    });

    test('live once the start time passes', () {
      expect(statusAt(sameDay(), DateTime(2026, 8, 5, 18, 31)), 'live');
    });

    test('still live late that evening, not completed', () {
      expect(statusAt(sameDay(), DateTime(2026, 8, 5, 23, 30)), 'live');
    });

    test('completed once the day is over', () {
      expect(statusAt(sameDay(), DateTime(2026, 8, 6, 9, 0)), 'completed');
    });
  });

  group('the other two ways to close', () {
    test('full when capacity is reached', () {
      expect(statusAt(sameDay(capacity: 8), DateTime(2026, 8, 1, 9, 0), 8),
          'full');
    });

    test('not full while spots remain', () {
      expect(statusAt(sameDay(capacity: 8), DateTime(2026, 8, 1, 9, 0), 7),
          'open');
    });

    test('organizer close beats an otherwise-open event', () {
      final t = {...sameDay(), 'registration_closed': true};
      expect(statusAt(t, DateTime(2026, 8, 1, 9, 0)), 'closed');
    });

    test('organizer close outranks the full label', () {
      final t = {...sameDay(capacity: 4), 'registration_closed': true};
      expect(statusAt(t, DateTime(2026, 8, 1, 9, 0), 4), 'closed');
    });

    test('registration_closed false behaves as normal', () {
      final t = {...sameDay(), 'registration_closed': false};
      expect(statusAt(t, DateTime(2026, 8, 1, 9, 0)), 'open');
    });
  });

  group('guards that must keep working', () {
    test('cancelled and postponed still come from the status column', () {
      expect(
          statusAt({...sameDay(), 'status': 'cancelled'},
              DateTime(2026, 8, 1, 9, 0)),
          'cancelled');
      expect(
          statusAt({...sameDay(), 'status': 'postponed'},
              DateTime(2026, 8, 1, 9, 0)),
          'postponed');
    });

    test('upcoming until the registration-opens day', () {
      final t = {...sameDay(), 'registration_opens': '2026-08-03'};
      expect(statusAt(t, DateTime(2026, 8, 1, 9, 0)), 'upcoming');
      expect(statusAt(t, DateTime(2026, 8, 3, 9, 0)), 'open');
    });

    test('legacy row with no start_time keeps the midnight cutoff', () {
      final t = sameDay()..remove('start_time');
      expect(statusAt(t, DateTime(2026, 8, 4, 23, 0)), 'open');
      expect(statusAt(t, DateTime(2026, 8, 5, 9, 0)), 'live');
    });

    test('a multi-day event stays live between its dates', () {
      final t = {...sameDay(), 'end_date': '2026-08-07'};
      expect(statusAt(t, DateTime(2026, 8, 6, 12, 0)), 'live');
      expect(statusAt(t, DateTime(2026, 8, 7, 23, 0)), 'live');
      expect(statusAt(t, DateTime(2026, 8, 8, 1, 0)), 'completed');
    });
  });

  group('time parsing', () {
    test('12-hour clock maps to the right instant', () {
      expect(
          TournamentService.tournamentStart(
              {'start_date': '2026-08-05', 'start_time': '6:30 PM'}),
          DateTime(2026, 8, 5, 18, 30));
    });

    test('midday and midnight do not flip', () {
      expect(
          TournamentService.tournamentStart(
              {'start_date': '2026-08-05', 'start_time': '12:00 PM'}),
          DateTime(2026, 8, 5, 12, 0));
      expect(
          TournamentService.tournamentStart(
              {'start_date': '2026-08-05', 'start_time': '12:00 AM'}),
          DateTime(2026, 8, 5, 0, 0));
    });

    test('24-hour clock also parses', () {
      expect(
          TournamentService.tournamentStart(
              {'start_date': '2026-08-05', 'start_time': '18:30'}),
          DateTime(2026, 8, 5, 18, 30));
    });

    test('deadline is one hour before start', () {
      expect(
          TournamentService.registrationDeadline(
              {'start_date': '2026-08-05', 'start_time': '6:30 PM'}),
          DateTime(2026, 8, 5, 17, 30));
    });

    test('junk time falls back to midnight instead of throwing', () {
      expect(
          TournamentService.tournamentStart(
              {'start_date': '2026-08-05', 'start_time': 'whenever'}),
          DateTime(2026, 8, 5));
    });
  });
}

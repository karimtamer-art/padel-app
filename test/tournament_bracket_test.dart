import 'package:flutter_test/flutter_test.dart';
import 'package:padel_clay/backend/models/tournament_bracket.dart';

Map<String, dynamic> entry(String id, {String? player, String? partner}) => {
      'id': id,
      'player_id': player ?? 'p-$id',
      'partner_id': partner ?? 'q-$id',
      'player_name': 'Player $id',
      'partner_name': 'Partner $id',
    };

Map<String, dynamic> row(String bracket, int round, int slot, Object? e1,
        Object? e2, {String? winner, String? score, String? status}) =>
    {
      'id': '$bracket-$round-$slot',
      'bracket': bracket,
      'round': round,
      'slot': slot,
      'e1': e1,
      'e2': e2,
      'winner_entry': winner,
      'score': score,
      'result_status': status ?? 'open',
    };

/// What generate_draw writes for [n] pairs: round 1 only.
List<Map<String, dynamic>> freshDraw(int n) => [
      for (var i = 0; i < n; i++)
        row('wb', 1, i, entry('a$i'), entry('b$i')),
    ];

void main() {
  group('round names come from the draw size, not rounds so far', () {
    test('16 pairs just drawn: round 1 is not the Final', () {
      final b = buildWinners(freshDraw(8), doubleElim: false);
      expect(b.rounds.map((r) => r.label),
          ['R16', 'Quarters', 'Semis', 'Final']);
      expect(b.rounds[0].slots.first.code, 'R16 1');
    });

    test('8 pairs: every round exists from day one, with its match count', () {
      final b = buildWinners(freshDraw(4), doubleElim: false);
      expect(b.rounds.map((r) => r.label), ['Quarters', 'Semis', 'Final']);
      expect(b.rounds.map((r) => r.slots.length), [4, 2, 1]);
    });

    test('2 pairs: a single Final', () {
      final b = buildWinners(freshDraw(1), doubleElim: false);
      expect(b.rounds.single.label, 'Final');
      expect(b.rounds.single.slots.single.code, 'Final');
    });
  });

  group('the row after the final', () {
    test('is the champion, not a match', () {
      final a = entry('a'), x = entry('x');
      final rows = [
        row('wb', 1, 0, a, x, winner: 'a', score: '6-1,6-1'),
        // _advance_winner always inserts a next round.
        row('wb', 2, 0, a, null),
      ];
      final b = buildWinners(rows, doubleElim: false);
      expect(b.rounds.length, 1);
      expect(b.champion?['id'], 'a');
    });
  });

  group('feeders and routing', () {
    test('an unplayed match names where its pairs come from', () {
      final b = buildWinners(freshDraw(4), doubleElim: false);
      final sf2 = b.rounds[1].slots[1];
      expect(sf2.code, 'SF 2');
      expect(sf2.e1Placeholder, 'Winner of QF 3');
      expect(sf2.e2Placeholder, 'Winner of QF 4');
    });

    test('knockout never mentions a losers bracket', () {
      final b = buildWinners(freshDraw(4), doubleElim: false);
      expect(b.rounds[0].slots[2].next, 'Winner → SF 2');
      expect(b.rounds[2].slots[0].next, isNull);
    });

    test('double elimination does', () {
      final b = buildWinners(freshDraw(4), doubleElim: true);
      expect(b.rounds[0].slots[0].next,
          'Winner → SF 1 · Loser → Losers bracket');
    });
  });

  test('double elimination calls its last winners round the WB Final', () {
    final b = buildWinners(freshDraw(2), doubleElim: true);
    expect(b.rounds.map((r) => r.label), ['Semis', 'WB Final']);
    expect(b.rounds.last.slots.single.code, 'WB Final');
    expect(b.rounds.first.slots.first.next,
        'Winner → WB Final · Loser → Losers bracket');
  });

  group('byes', () {
    test('are not matches, and do not count towards progress', () {
      final a = entry('a');
      final rows = [
        row('wb', 1, 0, a, null, winner: 'a'),
        row('wb', 1, 1, entry('b'), entry('c')),
      ];
      final b = buildWinners(rows, doubleElim: false);
      expect(b.rounds[0].slots[0].state, SlotState.bye);
      expect(b.rounds[0].total, 1);
      expect(b.rounds[0].done, 0);
    });
  });

  group('progress', () {
    test('current round is the first unfinished one', () {
      final rows = [
        row('wb', 1, 0, entry('a'), entry('b'), winner: 'a'),
        row('wb', 1, 1, entry('c'), entry('d'), winner: 'c'),
        row('wb', 2, 0, entry('a'), entry('c')),
      ];
      final b = buildWinners(rows, doubleElim: false);
      expect(currentRoundIndex(b.rounds), 1);
      expect(roundProgress(b.rounds, 0), '2 of 2 done');
      expect(roundProgress(b.rounds, 1), '0 of 1 done');
    });

    test('future rounds read Up next, then Waiting', () {
      final b = buildWinners(freshDraw(8), doubleElim: false);
      expect(roundProgress(b.rounds, 0), '0 of 8 done');
      expect(roundProgress(b.rounds, 1), 'Up next');
      expect(roundProgress(b.rounds, 2), 'Waiting');
    });
  });

  group('optional fields', () {
    Map<String, dynamic> withInfo({String? court, String? status}) => {
          ...row('wb', 1, 0, entry('a'), entry('b'), status: status),
          'court': court,
        };
    BracketSlot slotOf(Map<String, dynamic> r) =>
        buildWinners([r], doubleElim: false).rounds.single.slots.single;

    test('no court: the title is just the match', () {
      expect(slotOf(withInfo()).title, 'FINAL');
      expect(slotOf(withInfo(court: '  ')).title, 'FINAL');
    });

    test('a court number gets the word, a name is kept as typed', () {
      expect(slotOf(withInfo(court: '3')).title, 'FINAL · COURT 3');
      expect(slotOf(withInfo(court: 'Centre court')).title,
          'FINAL · CENTRE COURT');
    });

    test('live is its own state, and a decided match stops being live', () {
      expect(slotOf(withInfo(status: 'live')).state, SlotState.live);
      final done = {...withInfo(status: 'live'), 'winner_entry': 'a'};
      expect(slotOf(done).state, SlotState.done);
    });
  });

  group('typed scores', () {
    test('written from the winner\'s side', () {
      expect(orientedSets('6-3, 6-4', entry1Won: false),
          [(a: 3, b: 6), (a: 4, b: 6)]);
    });

    test('written from the loser\'s side', () {
      expect(orientedSets('3-6, 4-6', entry1Won: false),
          [(a: 3, b: 6), (a: 4, b: 6)]);
    });

    test('three sets with a match tie-break', () {
      expect(orientedSets('6-4,3-6,10-8', entry1Won: true),
          [(a: 6, b: 4), (a: 3, b: 6), (a: 10, b: 8)]);
    });

    test('undecided keeps the typed order', () {
      expect(orientedSets('6-4', entry1Won: null), [(a: 6, b: 4)]);
    });

    test('the console accepts blank or sets, and nothing else', () {
      expect(isReadableScore(''), isTrue);
      expect(isReadableScore(null), isTrue);
      expect(isReadableScore('6-4, 6-3'), isTrue);
      expect(isReadableScore('6-4,3-6,10-8'), isTrue);
      expect(isReadableScore('6-4 6'), isFalse);
      expect(isReadableScore('walkover'), isFalse);
    });

    test('anything else is not sets', () {
      expect(orientedSets('walkover', entry1Won: true), isNull);
      expect(orientedSets('6-4 6', entry1Won: true), isNull);
      expect(orientedSets('', entry1Won: true), isNull);
      expect(orientedSets(null, entry1Won: true), isNull);
    });
  });

  group('losers bracket', () {
    test('origin names the match a pair lost', () {
      final a = entry('a'), b = entry('b');
      final w = buildWinners([
        row('wb', 1, 0, a, b, winner: 'a'),
        row('wb', 1, 1, entry('c'), entry('d')),
      ], doubleElim: true);
      expect(originOf(b, w), 'Lost SF 1');
      expect(originOf(a, w), isNull);
    });

    test('hides the survivor\'s row once nobody else can drop down', () {
      final x = entry('x');
      final rows = [
        row('wb', 1, 0, entry('a'), entry('b'), winner: 'a'),
        row('lb', 1, 0, x, entry('y'), winner: 'x'),
        row('lb', 2, 0, x, null),
      ];
      expect(buildLosers(rows).map((r) => r.label), ['Round 1']);
    });

    test('keeps a half-filled row while the winners bracket is still running',
        () {
      final x = entry('x');
      final rows = [
        row('wb', 1, 0, entry('a'), entry('b')),
        row('lb', 1, 0, x, entry('y'), winner: 'x'),
        row('lb', 2, 0, x, null),
      ];
      expect(buildLosers(rows).map((r) => r.label), ['Round 1', 'Round 2']);
    });
  });

  group('who can act', () {
    test('free-label draws are the players\' to report', () {
      final me = entry('a', player: 'me');
      final s = buildGroups([
        row('Group A', 1, 0, me, entry('b')),
      ]).single.slots.single;
      expect(s.canAct('me'), isTrue);
      expect(s.canAct('stranger'), isFalse);
    });

    test('generate_draw brackets are the organiser\'s', () {
      final me = entry('a', player: 'me');
      final s = buildWinners([row('wb', 1, 0, me, entry('b'))],
              doubleElim: false)
          .rounds
          .single
          .slots
          .single;
      expect(s.canAct('me'), isFalse);
    });

    test('a partner counts as being in the match', () {
      final s = buildGroups([
        row('Group A', 1, 0, entry('a', partner: 'me'), entry('b')),
      ]).single.slots.single;
      expect(s.involves('me'), isTrue);
    });
  });

  group('next match', () {
    test('prefers a match that is ready over one still waiting', () {
      final me = entry('a', player: 'me');
      final rounds = [
        BracketRound('x', 'x', [
          BracketSlot(side: 'x', roundId: 'x', roundLabel: 'x', code: 'w', e1: me),
          BracketSlot(
              row: row('x', 1, 0, me, entry('b')),
              side: 'x',
              roundId: 'x',
              roundLabel: 'x',
              code: 'r',
              e1: me,
              e2: entry('b')),
        ]),
      ];
      expect(nextMatchFor('me', rounds)?.code, 'r');
    });

    test('none once everything is decided', () {
      final me = entry('a', player: 'me');
      final rounds = buildGroups([
        row('Group A', 1, 0, me, entry('b'), winner: 'a'),
      ]);
      expect(nextMatchFor('me', rounds), isNull);
    });
  });

  group('standings come from the server', () {
    Map<String, dynamic> line(String grp, int pos, String entry,
            {int won = 0, bool qualifies = false}) =>
        {
          'grp': grp, 'pos': pos, 'entry_id': entry, 'played': 1, 'won': won,
          'lost': 1 - won, 'sets_won': 2, 'sets_lost': 0, 'qualifies': qualifies,
        };

    test('in the order it sent, not recomputed', () {
      final group = buildGroups([
        row('Group A', 1, 0, entry('a'), entry('b'), winner: 'a'),
      ]).single;
      // The loser first, as a server tie-break could rank them. We don't argue.
      final lines = standingsFromServer([
        line('Group A', 2, 'a', won: 1),
        line('Group A', 1, 'b', qualifies: true),
      ], group);
      expect(lines.map((l) => l.entry['id']), ['b', 'a']);
      expect(lines.first.qualifies, isTrue);
      expect(lines.last.qualifies, isFalse);
    });

    test('only this group\'s lines', () {
      final group = buildGroups([
        row('Group A', 1, 0, entry('a'), entry('b')),
      ]).single;
      final lines = standingsFromServer([
        line('Group A', 1, 'a'),
        line('Group B', 1, 'x'),
      ], group);
      expect(lines.single.entry['id'], 'a');
    });
  });

  group('grand final', () {
    final a = entry('a'), b = entry('b');
    final wbFinal = row('wb', 1, 0, a, b, winner: 'a');

    test('none until the server opens one', () {
      expect(buildGrandFinal([wbFinal]), isNull);
    });

    test('the winners final does not crown a double-elim champion', () {
      expect(buildWinners([wbFinal], doubleElim: true).champion, isNull);
    });

    test('an event finished before grand finals keeps its champion', () {
      expect(
          buildWinners([wbFinal], doubleElim: true, finished: true).champion?['id'],
          'a');
    });

    test('its winner is the champion, whoever won the winners final', () {
      final rows = [wbFinal, row('gf', 2, 0, a, b, winner: 'b')];
      expect(buildWinners(rows, doubleElim: true).champion?['id'], 'b');
      expect(buildGrandFinal(rows)!.slots.single.code, 'Grand final');
    });

    test('players cannot report it: the organiser records it', () {
      final me = entry('m', player: 'me');
      final gf = buildGrandFinal([row('gf', 2, 0, me, b)])!.slots.single;
      expect(gf.involves('me'), isTrue);
      expect(gf.canAct('me'), isFalse);
    });

    test('it is a round the next-match logic can find', () {
      final me = entry('m', player: 'me');
      final gf = buildGrandFinal([row('gf', 2, 0, me, b)])!;
      expect(nextMatchFor('me', [gf])?.side, 'gf');
    });
  });

  group('losers round names', () {
    test('the last round of a standard bracket is the LB Final', () {
      final rows = [
        for (var i = 0; i < 4; i++) row('wb', 1, i, entry('w$i'), entry('x$i')),
        row('lb', 1, 0, entry('a'), entry('b')),
        row('lb', 4, 0, entry('c'), entry('d')),
      ];
      final rounds = buildLosers(rows);
      expect(rounds.map((r) => r.label), ['Round 1', 'LB Final']);
      expect(rounds.last.slots.single.code, 'LB Final');
      expect(rounds.last.slots.single.next, 'Loser is out');
    });

    test('an older event that ran past that keeps plain numbers', () {
      final rows = [
        row('wb', 1, 0, entry('w'), entry('x')),
        row('wb', 1, 1, entry('y'), entry('z')),
        row('lb', 5, 0, entry('a'), entry('b')),
      ];
      expect(buildLosers(rows).single.label, 'Round 5');
    });
  });

  group('console date and time fields', () {
    test('12-hour and 24-hour times', () {
      expect(composeLocalDateTime('2026-11-06', '5:00 PM'),
          DateTime(2026, 11, 6, 17));
      expect(composeLocalDateTime('2026-11-06', '12:30 AM'),
          DateTime(2026, 11, 6, 0, 30));
      expect(composeLocalDateTime('2026-11-06', '12:30 PM'),
          DateTime(2026, 11, 6, 12, 30));
      expect(composeLocalDateTime('2026-11-06', '17:05'),
          DateTime(2026, 11, 6, 17, 5));
    });

    test('blank or unreadable is no moment', () {
      expect(composeLocalDateTime('', '5:00 PM'), isNull);
      expect(composeLocalDateTime('2026-11-06', ''), isNull);
      expect(composeLocalDateTime('soon', 'later'), isNull);
    });

    test('round trips, and blank when unset', () {
      final at = DateTime(2026, 11, 6, 17, 5);
      final s = splitLocalDateTime(at);
      expect(s.date, '2026-11-06');
      expect(s.time, '5:05 PM');
      expect(composeLocalDateTime(s.date, s.time), at);
      expect(splitLocalDateTime(null).date, '');
    });
  });

  group('free-label rounds', () {
    test('play in order, whatever the alphabet says', () {
      final rounds = buildFreeKnockout([
        row('Final', 3, 0, null, null),
        row('Semifinal', 2, 0, null, null),
        row('Quarterfinal', 1, 0, null, null),
        row('Round of 16', 1, 0, null, null),
        row('Group A', 1, 0, null, null),
      ]);
      expect(rounds.map((r) => r.label), ['R16', 'Quarters', 'Semis', 'Final']);
    });
  });
}

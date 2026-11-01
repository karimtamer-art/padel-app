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

  group('standings', () {
    test('wins, then set difference, then head-to-head', () {
      final a = entry('a'), b = entry('b'), c = entry('c');
      final group = buildGroups([
        // a and b both end on one win; a's is the more emphatic.
        row('Group A', 1, 0, a, c, winner: 'a', score: '6-0,6-0'),
        row('Group A', 1, 1, b, a, winner: 'b', score: '6-4,4-6,10-8'),
        row('Group A', 1, 2, c, b, winner: 'c', score: '6-4,6-4'),
      ]).single;
      final lines = standingsFor(group);
      // Everyone is on one win; set difference decides.
      expect(lines.map((l) => l.id), ['a', 'c', 'b']);
      expect(lines.first.setsWon, 3);
      expect(lines.first.setsLost, 2);
      expect(lines.first.played, 2);
    });

    test('head-to-head breaks a tie on wins and sets', () {
      final a = entry('a'), b = entry('b');
      final group = buildGroups([
        row('Group A', 1, 0, a, b, winner: 'b'), // no score: sets stay level
      ]).single;
      expect(standingsFor(group).first.id, 'b');
    });

    test('pairs with no results are still listed', () {
      final group = buildGroups([
        row('Group A', 1, 0, entry('a'), entry('b')),
      ]).single;
      expect(standingsFor(group).length, 2);
    });
  });

  test('advance count comes from the format, default 2', () {
    expect(advanceCountFrom(null), 2);
    expect(advanceCountFrom({'stages': []}), 2);
    expect(
        advanceCountFrom({
          'stages': [
            {
              'kind': 'groups',
              'cfg': {'groups': 4, 'advance': 3}
            }
          ]
        }),
        3);
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

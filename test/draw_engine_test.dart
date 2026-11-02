import 'package:flutter_test/flutter_test.dart';
import 'package:padel_clay/backend/models/draw_engine.dart';

// Build a fetchBracket-shaped match row.
Map<String, dynamic> row(String id, String bracket, String e1, String e2,
        {String? winner}) =>
    {
      'id': id,
      'bracket': bracket,
      'round': 1,
      'slot': 0,
      'winner_entry': winner,
      'e1': {'id': e1, 'player_name': e1.toUpperCase(), 'partner_name': null},
      'e2': {'id': e2, 'player_name': e2.toUpperCase(), 'partner_name': null},
    };

void main() {
  group('parseGroups', () {
    test('splits rows by Group label and ignores knockout rows', () {
      final rows = [
        row('m1', 'Group A', 'a', 'b'),
        row('m2', 'Group A', 'a', 'c'),
        row('m3', 'Group B', 'd', 'e'),
        row('m4', 'Semifinal', 'a', 'd'), // knockout — ignored
      ];
      final groups = parseGroups(rows);
      expect(groups.length, 2);
      expect(groups[0].label, 'Group A');
      expect(groups[1].label, 'Group B');
      expect(groups[0].pairs.map((p) => p.entryId).toSet(), {'a', 'b', 'c'});
      expect(groups[0].fixtures.length, 2);
    });

    test('hasKnockout detects non-group rows', () {
      expect(hasKnockout([row('m1', 'Group A', 'a', 'b')]), isFalse);
      expect(hasKnockout([row('m1', 'Final', 'a', 'b')]), isTrue);
    });
  });

  group('standingsFromServer', () {
    const a = DrawPair('a', 'A'), b = DrawPair('b', 'B');
    const g = DrawGroup(label: 'Group A', pairs: [a, b], fixtures: []);
    Map<String, dynamic> line(String grp, int pos, String entry, {bool q = false}) => {
          'grp': grp, 'pos': pos, 'entry_id': entry, 'played': 1, 'won': 1,
          'lost': 0, 'sets_won': 2, 'sets_lost': 1, 'qualifies': q,
        };

    test('keeps the server order and its qualifiers', () {
      final st = standingsFromServer(
          [line('Group A', 2, 'a'), line('Group A', 1, 'b', q: true)], g);
      expect(st.map((r) => r.pair.entryId), ['b', 'a']);
      expect(st.first.qualifies, isTrue);
      expect(st.first.setsWon, 2);
    });

    test('ignores other groups and pairs it does not know', () {
      final st = standingsFromServer(
          [line('Group B', 1, 'a'), line('Group A', 1, 'zzz')], g);
      expect(st, isEmpty);
    });
  });

  test('DrawPair.initials derives from the lead name', () {
    expect(const DrawPair('x', 'A. Hassan / R. Samir').initials, 'AH');
    expect(const DrawPair('x', 'Karim / Youssef').initials, 'K');
  });

  group('parseRoundRobin', () {
    test('collects all pairs and fixtures from Round robin rows', () {
      final rows = [
        row('m1', 'Round robin', 'a', 'b', winner: 'a'),
        row('m2', 'Round robin', 'a', 'c'),
        row('m3', 'Round robin', 'b', 'c'),
      ];
      final g = parseRoundRobin(rows)!;
      expect(g.pairs.map((p) => p.entryId).toSet(), {'a', 'b', 'c'});
      expect(g.fixtures.length, 3);
    });

    test('null when there are no round-robin rows', () {
      expect(parseRoundRobin([row('m1', 'Group A', 'a', 'b')]), isNull);
    });
  });

  group('parseBracket', () {
    Map<String, dynamic> ko(String id, String label, int round, int slot,
            String? e1, String? e2, {String? winner}) =>
        {
          'id': id,
          'bracket': label,
          'round': round,
          'slot': slot,
          'winner_entry': winner,
          'e1': e1 == null ? null : {'id': e1, 'player_name': e1.toUpperCase()},
          'e2': e2 == null ? null : {'id': e2, 'player_name': e2.toUpperCase()},
        };

    test('4-pair bracket has round 1 (2 matches) + a TBD final', () {
      final rows = [
        ko('m1', 'Semifinal', 1, 0, 'a', 'b'),
        ko('m2', 'Semifinal', 1, 1, 'c', 'd'),
      ];
      final bd = parseBracket(rows);
      expect(bd.rounds.length, 2);
      expect(bd.rounds[0].length, 2);
      expect(bd.rounds[1].length, 1);
      expect(bd.rounds[1].first.isTbd, isTrue);
      expect(bd.champion, isNull);
    });

    test('a bye slot marks the empty side and is not TBD', () {
      final rows = [ko('m1', 'Final', 1, 0, 'a', null, winner: 'a')];
      final bd = parseBracket(rows);
      final m = bd.rounds.first.first;
      expect(m.bBye, isTrue);
      expect(m.isTbd, isFalse);
      expect(m.decided, isTrue);
    });

    test('champion resolves when the final is decided', () {
      final rows = [
        ko('m1', 'Semifinal', 1, 0, 'a', 'b', winner: 'a'),
        ko('m2', 'Semifinal', 1, 1, 'c', 'd', winner: 'c'),
        ko('m3', 'Final', 2, 0, 'a', 'c', winner: 'c'),
      ];
      final bd = parseBracket(rows);
      expect(bd.rounds.length, 2);
      expect(bd.champion?.entryId, 'c');
    });
  });
}

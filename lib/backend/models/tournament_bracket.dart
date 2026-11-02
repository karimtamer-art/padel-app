// ============================================================================
// tournament_bracket.dart — what the player-facing bracket screens derive from
// `TournamentService.fetchBracket` rows. Pure Dart so it can be unit-tested, and
// read-only: nothing here decides a result (the server does).
//
// Three facts about the rows shape this file:
//  * A draw only writes round 1. Later rounds appear as winners advance, so the
//    size of the draw comes from round 1, never from "rounds that exist so far".
//  * `_advance_winner` always inserts a next round, so the winner of the final
//    gets a row of their own one round past it. That is the champion, not a
//    match, and it must not be shown as one.
//  * `score` is free text a player typed ("6-4, 6-3"), written from whichever
//    side they were on. Set columns are oriented using the known winner.
// ============================================================================
import 'draw_engine.dart' show roundsForSize;

typedef BracketRow = Map<String, dynamic>;

/// True for a draw built by `generate_draw` (`wb`/`lb`/`gf`), which the organiser
/// records. Format Builder and manual draws use free-text labels instead, and
/// players submit those results themselves.
bool isLegacyBracketLabel(String? b) => const {'wb', 'lb', 'gf'}.contains(b);

bool isGroupLabel(String? b) =>
    b != null && (b.startsWith('Group ') || b == 'Round robin');

bool isLegacyDraw(List<BracketRow> rows) =>
    rows.any((r) => isLegacyBracketLabel(r['bracket'] as String?));

bool entryHasPlayer(BracketRow? e, String? uid) =>
    e != null && uid != null && (e['player_id'] == uid || e['partner_id'] == uid);

BracketRow? _entry(BracketRow? m, String key) {
  final v = m?[key];
  return v is Map ? Map<String, dynamic>.from(v) : null;
}

// ── Scores ──────────────────────────────────────────────────────────────────

/// One set, in (entry1, entry2) order.
typedef SetScore = ({int a, int b});

/// Splits a typed score into sets, or null if it isn't recognisably sets.
List<({int x, int y})>? _parseSets(String? score) {
  final s = score?.trim() ?? '';
  if (s.isEmpty) return null;
  final re = RegExp(r'(\d+)\s*[-–—:]\s*(\d+)');
  final found = re.allMatches(s).toList();
  if (found.isEmpty) return null;
  // Leftover digits ("6-4 6") mean we'd be guessing; show the raw text instead.
  if (s.replaceAll(re, '').contains(RegExp(r'\d'))) return null;
  return [
    for (final m in found)
      (x: int.parse(m.group(1)!), y: int.parse(m.group(2)!)),
  ];
}

/// Sets oriented to (entry1, entry2). Whichever side of the typed score won more
/// sets is the winner's side, so "6-3, 6-4" and "3-6, 4-6" both read correctly.
/// A level or undecided score keeps the order it was typed in. Null if the score
/// can't be read as sets.
List<SetScore>? orientedSets(String? score, {required bool? entry1Won}) {
  final sets = _parseSets(score);
  if (sets == null) return null;
  final firstWins = sets.where((s) => s.x > s.y).length;
  final secondWins = sets.where((s) => s.y > s.x).length;
  var firstIsEntry1 = true;
  if (entry1Won != null && firstWins != secondWins) {
    firstIsEntry1 = (firstWins > secondWins) == entry1Won;
  }
  return [
    for (final s in sets)
      firstIsEntry1 ? (a: s.x, b: s.y) : (a: s.y, b: s.x),
  ];
}

/// Empty (the score is optional) or readable as sets, the same as the player flow's
/// "6-4, 6-3". Anything else would count as no sets at all in the standings, without
/// saying so.
bool isReadableScore(String? score) =>
    (score?.trim() ?? '').isEmpty || _parseSets(score) != null;

// ── Slots and rounds ────────────────────────────────────────────────────────

enum SlotState { done, bye, ready, live, pending, disputed, waiting }

/// One position in a round. [row] is null for a match the server hasn't created
/// yet (a later round, drawn so the whole bracket is visible from day one).
class BracketSlot {
  final BracketRow? row;
  final String side; // 'wb', 'lb' or the free-text label
  final String roundId;
  final String roundLabel; // "Semis"
  final String code; // "SF 1"
  final BracketRow? e1;
  final BracketRow? e2;

  /// What to show for an empty side, e.g. "Winner of SF 2".
  final String? e1Placeholder;
  final String? e2Placeholder;

  /// "Winner → SF 1 · Loser → Losers bracket", when the data knows it.
  final String? next;

  const BracketSlot({
    this.row,
    required this.side,
    required this.roundId,
    required this.roundLabel,
    required this.code,
    this.e1,
    this.e2,
    this.e1Placeholder,
    this.e2Placeholder,
    this.next,
  });

  String? get winner => row?['winner_entry'] as String?;
  String? get score => row?['score'] as String?;

  /// "SF 1 · COURT 3", or just the code until a court is set. A bare number gets
  /// the word; anything else ("Centre court") is shown as the organiser typed it.
  String get title {
    final court = (row?['court'] as String?)?.trim() ?? '';
    final name = code.toUpperCase();
    if (court.isEmpty) return name;
    final where = RegExp(r'^\d+$').hasMatch(court) ? 'COURT $court' : court.toUpperCase();
    return '$name · $where';
  }

  bool get bothSet => e1 != null && e2 != null;

  bool? get entry1Won =>
      winner == null ? null : (e1 != null && e1!['id'] == winner);

  SlotState get state {
    if (winner != null) return bothSet ? SlotState.done : SlotState.bye;
    if (!bothSet) return SlotState.waiting;
    return switch (row?['result_status'] as String?) {
      'live' => SlotState.live,
      'pending' => SlotState.pending,
      'disputed' => SlotState.disputed,
      _ => SlotState.ready,
    };
  }

  /// Decided by being played (a bye isn't a match anyone played).
  bool get decided => winner != null;
  bool get isRealMatch => state != SlotState.bye;

  bool involves(String? uid) =>
      entryHasPlayer(e1, uid) || entryHasPlayer(e2, uid);

  /// Players enter results for free-label draws. `generate_draw` brackets are
  /// recorded by the organiser, which is what the server enforces too.
  bool canAct(String? uid) =>
      row != null &&
      bothSet &&
      winner == null &&
      involves(uid) &&
      !isLegacyBracketLabel(row!['bracket'] as String?);

  List<SetScore>? get sets => orientedSets(score, entry1Won: entry1Won);
}

class BracketRound {
  final String id;
  final String label;
  final List<BracketSlot> slots;
  const BracketRound(this.id, this.label, this.slots);

  int get total => slots.where((s) => s.isRealMatch).length;
  int get done => slots.where((s) => s.isRealMatch && s.decided).length;
  bool get finished => done == total;
  bool get hasPairs => slots.any((s) => s.isRealMatch && s.bothSet);
}

/// "4 of 4 done" / "1 of 2 done" / "Up next" / "Waiting" for a round tile.
String roundProgress(List<BracketRound> rounds, int i) {
  final r = rounds[i];
  if (r.done > 0 || r.hasPairs) return '${r.done} of ${r.total} done';
  final before = i == 0 ? null : rounds[i - 1];
  return (before == null || before.hasPairs) ? 'Up next' : 'Waiting';
}

/// The first round with an unfinished match; the last round when all are done.
int currentRoundIndex(List<BracketRound> rounds) {
  for (var i = 0; i < rounds.length; i++) {
    if (!rounds[i].finished) return i;
  }
  return rounds.isEmpty ? 0 : rounds.length - 1;
}

// ── Knockout ────────────────────────────────────────────────────────────────

String _roundLabel(int round, int total, int size) {
  final fromEnd = total - round;
  if (fromEnd == 0) return 'Final';
  if (fromEnd == 1) return 'Semis';
  if (fromEnd == 2) return 'Quarters';
  return 'R${size >> (round - 1)}';
}

String _slotCode(String label, int slot) => switch (label) {
      'Final' => 'Final',
      'WB Final' => 'WB Final',
      'Semis' => 'SF ${slot + 1}',
      'Quarters' => 'QF ${slot + 1}',
      _ => '$label ${slot + 1}',
    };

class KnockoutBracket {
  final List<BracketRound> rounds;
  final BracketRow? champion;
  const KnockoutBracket(this.rounds, this.champion);
  bool get isEmpty => rounds.isEmpty;
}

/// The whole winners bracket from `wb` rows, future rounds included.
///
/// In double elimination the winners final doesn't decide the title, so
/// [champion] waits for the grand final. [finished] covers events completed before
/// grand finals existed, whose winners-final winner was their champion.
KnockoutBracket buildWinners(List<BracketRow> rows,
    {required bool doubleElim, bool finished = false}) {
  final wb = rows.where((r) => r['bracket'] == 'wb').toList();
  if (wb.isEmpty) return const KnockoutBracket([], null);

  int roundOf(BracketRow r) => (r['round'] as num).toInt();
  int slotOf(BracketRow r) => (r['slot'] as num).toInt();

  final firstRound = wb.map(roundOf).reduce((a, b) => a < b ? a : b);
  final firstCount = wb.where((r) => roundOf(r) == firstRound).length;
  final size = firstCount * 2;
  final total = roundsForSize(size);

  final at = <(int, int), BracketRow>{
    for (final r in wb) (roundOf(r) - firstRound + 1, slotOf(r)): r,
  };
  final labels = [
    for (var round = 1; round <= total; round++)
      // In double elimination the Final is the grand final.
      doubleElim && round == total ? 'WB Final' : _roundLabel(round, total, size),
  ];

  final rounds = <BracketRound>[];
  for (var round = 1; round <= total; round++) {
    final label = labels[round - 1];
    final count = size >> round;
    final slots = <BracketSlot>[];
    for (var i = 0; i < count; i++) {
      final row = at[(round, i)];
      String? feeder(int fromSlot) {
        if (round == 1) return null;
        final prev = labels[round - 2];
        return 'Winner of ${_slotCode(prev, fromSlot)}';
      }

      final String? next;
      if (round < total) {
        final to = _slotCode(labels[round], i ~/ 2);
        next = doubleElim
            ? 'Winner → $to · Loser → Losers bracket'
            : 'Winner → $to';
      } else {
        // Silent about the winner: it's a grand final or the title depending on
        // whether the server has grand finals yet, and this reads true for both.
        next = doubleElim ? 'Loser → Losers bracket' : null;
      }
      slots.add(BracketSlot(
        row: row,
        side: 'wb',
        roundId: 'wb$round',
        roundLabel: label,
        code: _slotCode(label, i),
        e1: _entry(row, 'e1'),
        e2: _entry(row, 'e2'),
        e1Placeholder: feeder(i * 2),
        e2Placeholder: feeder(i * 2 + 1),
        next: next,
      ));
    }
    rounds.add(BracketRound('wb$round', label, slots));
  }

  // The champion: the grand final's winner, or the winners final's where that is
  // the end of the event.
  BracketRow? champion;
  BracketRow? winnerOf(BracketRow? m) {
    final w = m?['winner_entry'] as String?;
    if (w == null) return null;
    final a = _entry(m, 'e1');
    return a != null && a['id'] == w ? a : _entry(m, 'e2');
  }

  final gf = rows.where((r) => r['bracket'] == 'gf').toList();
  if (gf.isNotEmpty) {
    champion = winnerOf(gf.first);
  } else if (!doubleElim || finished) {
    champion = winnerOf(at[(total, 0)]);
  }
  return KnockoutBracket(rounds, champion);
}

/// The one grand-final round, once the server has opened it.
BracketRound? buildGrandFinal(List<BracketRow> rows) {
  final gf = rows.where((r) => r['bracket'] == 'gf').toList();
  if (gf.isEmpty) return null;
  return BracketRound('gf', 'Grand final', [
    BracketSlot(
      row: gf.first,
      side: 'gf',
      roundId: 'gf',
      roundLabel: 'Grand final',
      code: 'Grand final',
      e1: _entry(gf.first, 'e1'),
      e2: _entry(gf.first, 'e2'),
      next: 'One match decides the title',
    ),
  ]);
}

/// The losers bracket: the rounds that exist so far. A draw of 2^k has 2(k-1) of
/// them, the last being the LB Final. Events drawn before fixed routing can run
/// past that, and then simply keep their numbers.
List<BracketRound> buildLosers(List<BracketRow> rows) {
  final lb = rows.where((r) => r['bracket'] == 'lb').toList();
  if (lb.isEmpty) return const [];

  final byRound = <int, List<BracketRow>>{};
  for (final r in lb) {
    byRound.putIfAbsent((r['round'] as num).toInt(), () => []).add(r);
  }
  final keys = byRound.keys.toList()..sort();

  // Once the winners bracket is over nobody else can drop down, so a lone pair
  // alone in the last round is the row `_advance_winner` made for the survivor.
  final winnersOver = rows
      .where((r) => r['bracket'] == 'wb')
      .every((r) => r['winner_entry'] != null);
  if (winnersOver && keys.length > 1) {
    final last = byRound[keys.last]!;
    final before = byRound[keys[keys.length - 2]]!;
    if (last.length == 1 &&
        before.length == 1 &&
        last.first['winner_entry'] == null &&
        (last.first['e1'] == null || last.first['e2'] == null)) {
      keys.removeLast();
    }
  }

  final firstRoundWb = rows.where((r) => r['bracket'] == 'wb' && r['round'] == 1).length;
  final lastLb = 2 * (roundsForSize(firstRoundWb * 2) - 1);
  final standard = keys.isNotEmpty && keys.last <= lastLb;
  String labelOf(int k) => standard && k == lastLb ? 'LB Final' : 'Round $k';

  return [
    for (final k in keys)
      BracketRound('lb$k', labelOf(k), [
        for (final r in (byRound[k]!
          ..sort((a, b) =>
              (a['slot'] as num).toInt().compareTo((b['slot'] as num).toInt()))))
          BracketSlot(
            row: r,
            side: 'lb',
            roundId: 'lb$k',
            roundLabel: labelOf(k),
            code: labelOf(k) == 'LB Final'
                ? 'LB Final'
                : 'Losers R$k · ${(r['slot'] as num).toInt() + 1}',
            e1: _entry(r, 'e1'),
            e2: _entry(r, 'e2'),
            next: labelOf(k) == 'LB Final'
                ? 'Loser is out'
                : 'Loser is out · Winner → Losers R${k + 1}',
          ),
      ]),
  ];
}

/// "Lost QF 2": the winners-bracket match that sent this pair down.
String? originOf(BracketRow? entry, KnockoutBracket winners) {
  if (entry == null) return null;
  final id = entry['id'];
  for (final r in winners.rounds) {
    for (final s in r.slots) {
      if (s.winner != null &&
          s.winner != id &&
          (s.e1?['id'] == id || s.e2?['id'] == id)) {
        return 'Lost ${s.code}';
      }
    }
  }
  return null;
}

// ── Groups and free-label knockouts ─────────────────────────────────────────

/// Free-label knockout rounds in playing order.
int _labelOrder(String label) {
  final l = label.toLowerCase();
  if (l.startsWith('round of ')) {
    // Round of 32 comes before Round of 16.
    return 100 - (int.tryParse(l.substring(9).trim()) ?? 0).clamp(0, 99);
  }
  if (l.startsWith('quarter')) return 200;
  if (l.startsWith('semi')) return 300;
  if (l.startsWith('final')) return 400;
  return 0; // anything organiser-named goes first, alphabetically
}

String _shortLabel(String label) {
  final l = label.toLowerCase();
  if (l.startsWith('quarter')) return 'Quarters';
  if (l.startsWith('semi')) return 'Semis';
  if (l.startsWith('final')) return 'Final';
  if (l.startsWith('round of ')) return 'R${l.substring(9).trim()}';
  return label;
}

String _labelCode(String label, int slot, int count) {
  final short = _shortLabel(label);
  if (short == 'Final' && count == 1) return 'Final';
  return _slotCode(short, slot);
}

List<BracketRound> _labelledRounds(Iterable<String> labels, List<BracketRow> rows) => [
      for (final label in labels)
        () {
          final own = rows.where((r) => r['bracket'] == label).toList()
            ..sort((a, b) => (a['slot'] as num)
                .toInt()
                .compareTo((b['slot'] as num).toInt()));
          return BracketRound(label, _shortLabel(label), [
            for (var i = 0; i < own.length; i++)
              BracketSlot(
                row: own[i],
                side: label,
                roundId: label,
                roundLabel: _shortLabel(label),
                code: isGroupLabel(label)
                    ? 'Match ${i + 1}'
                    : _labelCode(label, i, own.length),
                e1: _entry(own[i], 'e1'),
                e2: _entry(own[i], 'e2'),
              ),
          ]);
        }(),
    ];

/// Group-stage rounds, one per label ("Group A", "Round robin").
List<BracketRound> buildGroups(List<BracketRow> rows) {
  final labels = rows
      .map((r) => r['bracket'] as String?)
      .whereType<String>()
      .where(isGroupLabel)
      .toSet()
      .toList()
    ..sort();
  return _labelledRounds(labels, rows);
}

/// Free-label knockout rounds ("Quarterfinal", "Semifinal"…).
List<BracketRound> buildFreeKnockout(List<BracketRow> rows) {
  final labels = rows
      .map((r) => r['bracket'] as String?)
      .whereType<String>()
      .where((l) => !isGroupLabel(l) && !isLegacyBracketLabel(l))
      .toSet()
      .toList()
    ..sort((a, b) {
      final c = _labelOrder(a).compareTo(_labelOrder(b));
      return c != 0 ? c : a.compareTo(b);
    });
  return _labelledRounds(labels, rows);
}

/// One line of a group's standings, in the order the server ranked them. The
/// server is the only place pairs are ranked: `advance_stage` promotes on the same
/// ranking, so a line above the cut is a pair that advances.
class StandingLine {
  final BracketRow entry;
  final int played, won, lost, setsWon, setsLost;
  final bool qualifies;
  const StandingLine(this.entry, this.played, this.won, this.lost, this.setsWon,
      this.setsLost, this.qualifies);
}

/// The `tournament_standings` lines for [group], with each pair's entry resolved
/// from the group's own matches.
List<StandingLine> standingsFromServer(
    List<Map<String, dynamic>> rows, BracketRound group) {
  final entries = <String, BracketRow>{};
  for (final s in group.slots) {
    for (final e in [s.e1, s.e2]) {
      if (e != null) entries[e['id'] as String] = e;
    }
  }
  final own = rows.where((r) => r['grp'] == group.id).toList()
    ..sort((a, b) => (a['pos'] as num).compareTo(b['pos'] as num));
  return [
    for (final r in own)
      if (entries[r['entry_id']] case final e?)
        StandingLine(
          e,
          (r['played'] as num).toInt(),
          (r['won'] as num).toInt(),
          (r['lost'] as num).toInt(),
          (r['sets_won'] as num).toInt(),
          (r['sets_lost'] as num).toInt(),
          r['qualifies'] == true,
        ),
  ];
}

/// False only when the saved format ends with this stage, so nobody "advances".
bool hasLaterStage(Map<String, dynamic>? spec) {
  final stages = spec?['stages'];
  return stages is! List || stages.length != 1;
}

// ── The player's position ───────────────────────────────────────────────────

/// The match the player should look at next, or null if they have none.
BracketSlot? nextMatchFor(String? uid, Iterable<BracketRound> rounds) {
  if (uid == null) return null;
  BracketSlot? waiting;
  for (final r in rounds) {
    for (final s in r.slots) {
      if (s.decided || !s.involves(uid)) continue;
      if (s.bothSet) return s;
      waiting ??= s;
    }
  }
  return waiting;
}

/// The other side of [slot] from the player's point of view: their entry, or the
/// placeholder ("Winner of SF 2") while it's undecided.
BracketRow? opponentEntry(BracketSlot slot, String? uid) =>
    entryHasPlayer(slot.e1, uid) ? slot.e2 : slot.e1;

String? opponentPlaceholder(BracketSlot slot, String? uid) =>
    entryHasPlayer(slot.e1, uid) ? slot.e2Placeholder : slot.e1Placeholder;

// ── Console: date + time fields <-> a moment ────────────────────────────────

/// A local moment from the console's date ('2026-11-06') and time ('5:00 PM' or
/// '17:00') fields. Null when either is blank or unreadable.
DateTime? composeLocalDateTime(String date, String time) {
  final d = DateTime.tryParse(date.trim());
  final m = RegExp(r'^(\d{1,2}):(\d{2})\s*(AM|PM)?$', caseSensitive: false)
      .firstMatch(time.trim());
  if (d == null || m == null) return null;
  var hour = int.parse(m.group(1)!);
  final minute = int.parse(m.group(2)!);
  final ap = m.group(3)?.toUpperCase();
  if (ap == 'PM' && hour < 12) hour += 12;
  if (ap == 'AM' && hour == 12) hour = 0;
  return DateTime(d.year, d.month, d.day, hour, minute);
}

/// The reverse, for filling the fields: blank when there's no moment.
({String date, String time}) splitLocalDateTime(DateTime? at) {
  if (at == null) return (date: '', time: '');
  final l = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  return (
    date: '${l.year}-${two(l.month)}-${two(l.day)}',
    time: '$h:${two(l.minute)} ${l.hour < 12 ? 'AM' : 'PM'}',
  );
}

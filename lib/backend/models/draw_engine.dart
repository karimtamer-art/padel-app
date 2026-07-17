// ============================================================================
// draw_engine.dart — pure helpers for the tournament draw boards. Adapted from
// the draw-config design handoff (draw-views.jsx). No Flutter imports so it's
// unit-testable. Pass 1 covers the Groups → Knockout group stage; the bracket /
// round-robin views land in Pass 2.
//
// Ranking is wins-first to match the server's qualifier logic (advance_stage
// takes top-N per group by win count), so the highlighted qualifiers on screen
// are exactly who the backend advances.
// ============================================================================

/// A registered pair as it appears in the draw ("A. Hassan / R. Samir").
class DrawPair {
  final String entryId;
  final String name;
  const DrawPair(this.entryId, this.name);

  String get lead => name.split(' / ').first.trim();

  /// Initials for the avatar chip (from the lead player's name).
  String get initials {
    final cleaned = lead.replaceAll(RegExp(r'[^A-Za-z ]'), ' ').trim();
    final parts = cleaned.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}

/// One head-to-head fixture inside a group. [id] is the tournament_matches id.
class DrawFixture {
  final String id;
  final DrawPair a, b;
  final String? winnerId; // entry id of the winner, or null if unplayed
  const DrawFixture({required this.id, required this.a, required this.b, this.winnerId});
  bool get decided => winnerId != null;
}

/// A group ("Group A") with its pairs and fixtures.
class DrawGroup {
  final String label;
  final List<DrawPair> pairs;
  final List<DrawFixture> fixtures;
  const DrawGroup({required this.label, required this.pairs, required this.fixtures});

  bool get complete => fixtures.isNotEmpty && fixtures.every((f) => f.decided);
  int get playedCount => fixtures.where((f) => f.decided).length;
}

/// A live standings line for one pair in a group.
class StandingRow {
  final DrawPair pair;
  final int played, won, lost;
  const StandingRow(this.pair, this.played, this.won, this.lost);
  int get points => won * 2;
  int get diff => won - lost;
}

/// Standings for a group, ranked wins → win-diff → name. Wins-first mirrors the
/// server (advance_stage), so "top N advance" highlights the real qualifiers.
List<StandingRow> standingsOf(DrawGroup g) {
  final played = <String, int>{};
  final won = <String, int>{};
  final lost = <String, int>{};
  for (final p in g.pairs) {
    played[p.entryId] = 0;
    won[p.entryId] = 0;
    lost[p.entryId] = 0;
  }
  for (final f in g.fixtures) {
    final w = f.winnerId;
    if (w == null) continue;
    played[f.a.entryId] = (played[f.a.entryId] ?? 0) + 1;
    played[f.b.entryId] = (played[f.b.entryId] ?? 0) + 1;
    if (w == f.a.entryId) {
      won[f.a.entryId] = (won[f.a.entryId] ?? 0) + 1;
      lost[f.b.entryId] = (lost[f.b.entryId] ?? 0) + 1;
    } else if (w == f.b.entryId) {
      won[f.b.entryId] = (won[f.b.entryId] ?? 0) + 1;
      lost[f.a.entryId] = (lost[f.a.entryId] ?? 0) + 1;
    }
  }
  final rows = [
    for (final p in g.pairs)
      StandingRow(p, played[p.entryId]!, won[p.entryId]!, lost[p.entryId]!)
  ];
  rows.sort((x, y) {
    final w = y.won.compareTo(x.won);
    if (w != 0) return w;
    final d = y.diff.compareTo(x.diff);
    if (d != 0) return d;
    return x.pair.name.toLowerCase().compareTo(y.pair.name.toLowerCase());
  });
  return rows;
}

/// Parse fetchBracket rows into groups. Only rows whose `bracket` label starts
/// with "Group " (the group stage) are used; knockout rounds are ignored here.
/// Each row carries e1/e2 maps with {id, player_name, partner_name}.
List<DrawGroup> parseGroups(List<Map<String, dynamic>> matchRows) {
  final byLabel = <String, List<Map<String, dynamic>>>{};
  for (final m in matchRows) {
    final label = (m['bracket'] as String?) ?? '';
    if (!label.startsWith('Group ')) continue;
    byLabel.putIfAbsent(label, () => []).add(m);
  }
  final labels = byLabel.keys.toList()..sort();
  final groups = <DrawGroup>[];
  for (final label in labels) {
    final pairs = <String, DrawPair>{};
    final fixtures = <DrawFixture>[];
    for (final m in byLabel[label]!) {
      final a = pairOf(m['e1']);
      final b = pairOf(m['e2']);
      if (a != null) pairs[a.entryId] = a;
      if (b != null) pairs[b.entryId] = b;
      if (a != null && b != null) {
        fixtures.add(DrawFixture(
          id: m['id'] as String,
          a: a,
          b: b,
          winnerId: m['winner_entry'] as String?,
        ));
      }
    }
    groups.add(DrawGroup(
        label: label, pairs: pairs.values.toList(), fixtures: fixtures));
  }
  return groups;
}

/// Are there any knockout-stage matches yet (non-group rows)?
bool hasKnockout(List<Map<String, dynamic>> matchRows) =>
    matchRows.any((m) => !((m['bracket'] as String?) ?? '').startsWith('Group '));

/// Parse the round-robin matches (bracket 'Round robin') into a single group
/// so [standingsOf] can rank the whole field. null if there are none.
DrawGroup? parseRoundRobin(List<Map<String, dynamic>> matchRows) {
  final rr = matchRows
      .where((m) => ((m['bracket'] as String?) ?? '') == 'Round robin')
      .toList();
  if (rr.isEmpty) return null;
  final pairs = <String, DrawPair>{};
  final fixtures = <DrawFixture>[];
  for (final m in rr) {
    final a = pairOf(m['e1']);
    final b = pairOf(m['e2']);
    if (a != null) pairs[a.entryId] = a;
    if (b != null) pairs[b.entryId] = b;
    if (a != null && b != null) {
      fixtures.add(DrawFixture(
          id: m['id'] as String, a: a, b: b, winnerId: m['winner_entry'] as String?));
    }
  }
  return DrawGroup(label: 'Round robin', pairs: pairs.values.toList(), fixtures: fixtures);
}

/// One knockout-bracket slot. Empty (a==b==null) = a TBD future match; a bye is
/// a slot whose opposite side is null (the present side auto-advances).
class BracketMatch {
  final String? id;
  final DrawPair? a, b;
  final String? winnerId;
  final bool aBye, bBye;
  const BracketMatch({this.id, this.a, this.b, this.winnerId, this.aBye = false, this.bBye = false});
  bool get bothKnown => a != null && b != null;
  bool get decided => winnerId != null;
  bool get isTbd => a == null && b == null && !aBye && !bBye;
}

/// A parsed single-elimination bracket: [rounds] holds round 1..N (real matches
/// where they exist, TBD placeholders for future rounds), and the champion once
/// the final is decided.
class BracketData {
  final List<List<BracketMatch>> rounds;
  final DrawPair? champion;
  const BracketData(this.rounds, this.champion);
  bool get isEmpty => rounds.isEmpty;
}

int roundsForSize(int drawSize) {
  var r = 0, n = drawSize;
  while (n > 1) {
    n ~/= 2;
    r++;
  }
  return r;
}

BracketMatch _bracketMatchOf(Map<String, dynamic> m) {
  final a = pairOf(m['e1']);
  final b = pairOf(m['e2']);
  return BracketMatch(
    id: m['id'] as String?,
    a: a,
    b: b,
    winnerId: m['winner_entry'] as String?,
    aBye: a == null,
    bBye: b == null,
  );
}

/// Parse knockout matches (any non-group, non-round-robin label) into a full
/// bracket tree — real rounds plus TBD placeholders for rounds not yet seeded —
/// so the whole bracket is visible from the start.
BracketData parseBracket(List<Map<String, dynamic>> matchRows) {
  final ko = matchRows.where((m) {
    final l = (m['bracket'] as String?) ?? '';
    return l.isNotEmpty && !l.startsWith('Group ') && l != 'Round robin';
  }).toList();
  if (ko.isEmpty) return const BracketData([], null);

  final byRound = <int, List<Map<String, dynamic>>>{};
  for (final m in ko) {
    final r = (m['round'] as num?)?.toInt() ?? 1;
    byRound.putIfAbsent(r, () => []).add(m);
  }
  final minRound = byRound.keys.reduce((a, b) => a < b ? a : b);
  final firstCount = byRound[minRound]!.length; // matches in the first round
  final drawSize = firstCount * 2;
  final total = roundsForSize(drawSize);

  final rounds = <List<BracketMatch>>[];
  for (var idx = 0; idx < total; idx++) {
    final roundNo = minRound + idx;
    final existing = byRound[roundNo];
    if (existing != null && existing.isNotEmpty) {
      existing.sort((a, b) => ((a['slot'] as num?) ?? 0).compareTo((b['slot'] as num?) ?? 0));
      rounds.add([for (final m in existing) _bracketMatchOf(m)]);
    } else {
      final count = drawSize ~/ (1 << (idx + 1));
      rounds.add([for (var i = 0; i < count; i++) const BracketMatch()]);
    }
  }

  DrawPair? champ;
  if (rounds.isNotEmpty && rounds.last.length == 1) {
    final f = rounds.last.first;
    if (f.winnerId != null) champ = f.winnerId == f.a?.entryId ? f.a : f.b;
  }
  return BracketData(rounds, champ);
}

/// Build a [DrawPair] from a fetchBracket entry map ({id, player_name,
/// partner_name}); null if the entry is absent (a bye/empty slot).
DrawPair? pairOf(dynamic e) {
  if (e is! Map) return null;
  final id = e['id'] as String?;
  if (id == null) return null;
  final player = (e['player_name'] as String?)?.trim();
  final partner = (e['partner_name'] as String?)?.trim();
  final name = [
    if (player != null && player.isNotEmpty) player,
    if (partner != null && partner.isNotEmpty) partner,
  ].join(' / ');
  return DrawPair(id, name.isEmpty ? 'Pair' : name);
}

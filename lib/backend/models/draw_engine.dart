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

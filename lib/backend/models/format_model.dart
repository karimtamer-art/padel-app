// ============================================================================
// format_model.dart — tournament Format Builder model + advancement engine.
// Pure logic (only material for Icon/Color) so it's unit-testable and reused by
// the live-draw generator. Adapted from the v9 design handoff.
// ============================================================================
import 'package:flutter/material.dart';

enum StageKind { groups, knockout, doubleElim, roundRobin, swiss, ladder, consolation }

String stageKindToString(StageKind k) => k.name;
StageKind stageKindFromString(String? s) =>
    StageKind.values.firstWhere((k) => k.name == s, orElse: () => StageKind.knockout);

class StageMeta {
  final String label, blurb;
  final IconData icon;
  final Color tone;
  const StageMeta(this.label, this.icon, this.tone, this.blurb);
}

const Map<StageKind, StageMeta> kStageMeta = {
  StageKind.groups: StageMeta('Groups / Pools', Icons.groups_outlined, Color(0xFF3F7896), 'Split entrants into pools; top N of each advance.'),
  StageKind.knockout: StageMeta('Knockout bracket', Icons.emoji_events_outlined, Color(0xFFC2502A), 'Single-elimination bracket to a final.'),
  StageKind.doubleElim: StageMeta('Double elim', Icons.swap_horiz_rounded, Color(0xFF8A4B2B), 'Winners + losers bracket, second chance.'),
  StageKind.roundRobin: StageMeta('Round robin', Icons.grid_view_rounded, Color(0xFF2F6B57), 'Everyone plays everyone; ranked by record.'),
  StageKind.swiss: StageMeta('Swiss', Icons.layers_outlined, Color(0xFF6E5AA0), 'Fixed rounds, paired by standings, no elimination.'),
  StageKind.ladder: StageMeta('Ladder', Icons.trending_up_rounded, Color(0xFFB07E22), 'Ongoing challenge ranking players climb.'),
  StageKind.consolation: StageMeta('Consolation / Plate', Icons.military_tech_outlined, Color(0xFF907A52), 'Secondary bracket for early losers.'),
};

/// One stage of a format. `cfg` holds kind-specific numbers.
class Stage {
  final String id;
  StageKind kind;
  String name;
  Map<String, int> cfg;
  bool thirdPlace;
  Stage({required this.id, required this.kind, required this.name, required this.cfg, this.thirdPlace = true});

  int get groups => cfg['groups'] ?? 4;
  int get perGroup => cfg['perGroup'] ?? 4;
  int get advance => cfg['advance'] ?? 2;
  int get seeds => cfg['seeds'] ?? 8;
  int get players => cfg['players'] ?? 6;
  int get legs => cfg['legs'] ?? 1;
  int get rounds => cfg['rounds'] ?? 5;
  int get window => cfg['window'] ?? 3;

  static int _seq = 100;
  factory Stage.of(StageKind k) {
    final id = 'S${++_seq}';
    final name = kStageMeta[k]!.label;
    switch (k) {
      case StageKind.groups: return Stage(id: id, kind: k, name: name, cfg: {'groups': 4, 'perGroup': 4, 'advance': 2});
      case StageKind.knockout: return Stage(id: id, kind: k, name: name, cfg: {'seeds': 8});
      case StageKind.doubleElim: return Stage(id: id, kind: k, name: name, cfg: {'seeds': 8});
      case StageKind.roundRobin: return Stage(id: id, kind: k, name: name, cfg: {'players': 6, 'legs': 1, 'advance': 2});
      case StageKind.swiss: return Stage(id: id, kind: k, name: name, cfg: {'rounds': 5, 'advance': 8});
      case StageKind.ladder: return Stage(id: id, kind: k, name: name, cfg: {'players': 20, 'window': 3});
      case StageKind.consolation: return Stage(id: id, kind: k, name: name, cfg: {'seeds': 8});
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'name': name,
        'cfg': cfg,
        'thirdPlace': thirdPlace,
      };

  factory Stage.fromJson(Map<String, dynamic> j) {
    final cfg = <String, int>{};
    final raw = j['cfg'];
    if (raw is Map) {
      raw.forEach((k, v) {
        if (v is num) cfg[k.toString()] = v.toInt();
      });
    }
    return Stage(
      id: (j['id'] as String?) ?? 'S${++_seq}',
      kind: stageKindFromString(j['kind'] as String?),
      name: (j['name'] as String?) ?? 'Stage',
      cfg: cfg,
      thirdPlace: j['thirdPlace'] as bool? ?? true,
    );
  }

  String get summary {
    switch (kind) {
      case StageKind.groups: return '$groups groups · top $advance advance';
      case StageKind.knockout: return '$seeds seeds${thirdPlace ? ' · 3rd-place match' : ''}';
      case StageKind.doubleElim: return '$seeds seeds · winners + losers';
      case StageKind.roundRobin: return '$players players · top $advance advance';
      case StageKind.swiss: return '$rounds rounds · top $advance advance';
      case StageKind.ladder: return '$players players · ±$window challenge window';
      case StageKind.consolation: return '$seeds early-round losers';
    }
  }
}

/// Serialisable wrapper stored on a tournament (tournaments.format_spec) or a
/// reusable saved_formats row.
class FormatSpec {
  final String name;
  final List<Stage> stages;
  final int entrants, courts;
  const FormatSpec({required this.name, required this.stages, this.entrants = 16, this.courts = 3});

  Map<String, dynamic> toJson() => {
        'name': name,
        'entrants': entrants,
        'courts': courts,
        'stages': stages.map((s) => s.toJson()).toList(),
      };

  factory FormatSpec.fromJson(Map<String, dynamic> j) => FormatSpec(
        name: (j['name'] as String?) ?? 'Custom format',
        entrants: (j['entrants'] as num?)?.toInt() ?? 16,
        courts: (j['courts'] as num?)?.toInt() ?? 3,
        stages: [
          for (final s in (j['stages'] as List?) ?? const [])
            Stage.fromJson(Map<String, dynamic>.from(s as Map))
        ],
      );
}

// ── math helpers ─────────────────────────────────────────────────────────
int nextPow2(int n) {
  var p = 2;
  while (p < n) {
    p *= 2;
  }
  return p;
}
bool isPow2(int n) => n >= 2 && (n & (n - 1)) == 0;

/// Split [total] as evenly as possible into [g] pools (e.g. 17,4 → [5,4,4,4]).
List<int> groupSizes(int total, int g) {
  if (g <= 0) return [];
  final base = total ~/ g, rem = total % g;
  return List.generate(g, (i) => base + (i < rem ? 1 : 0));
}

/// What a stage is configured to take in. null = flexible (any count).
int? capacity(Stage s) {
  switch (s.kind) {
    case StageKind.roundRobin:
    case StageKind.ladder:
      return s.players;
    case StageKind.knockout:
    case StageKind.doubleElim:
    case StageKind.consolation:
      return s.seeds;
    case StageKind.groups:
    case StageKind.swiss:
      return null;
  }
}

/// How many advance out of a stage.
int produces(Stage s) {
  switch (s.kind) {
    case StageKind.groups: return s.groups * s.advance;
    case StageKind.roundRobin:
    case StageKind.swiss:
      return s.advance;
    case StageKind.ladder: return s.players;
    default: return 1; // knockout / double / consolation → 1 champion
  }
}

/// Matches played inside a stage given how many entered it.
int matchCount(Stage s, int incoming) {
  switch (s.kind) {
    case StageKind.groups:
      return groupSizes(incoming, s.groups).fold(0, (t, n) => t + n * (n - 1) ~/ 2);
    case StageKind.roundRobin:
      return (s.players * (s.players - 1) ~/ 2) * s.legs;
    case StageKind.swiss:
      return s.rounds * ((incoming == 0 ? s.advance * 2 : incoming) ~/ 2);
    case StageKind.knockout:
      return ((s.seeds == 0 ? incoming : s.seeds) - 1).clamp(0, 1 << 20) + (s.thirdPlace ? 1 : 0);
    case StageKind.doubleElim:
      return (2 * ((s.seeds == 0 ? incoming : s.seeds) - 1) + 1).clamp(0, 1 << 20);
    case StageKind.consolation:
      return ((s.seeds == 0 ? 4 : s.seeds) - 1).clamp(0, 1 << 20);
    case StageKind.ladder:
      return 0;
  }
}

class FormatWarning {
  final String? stageId;
  final String sev; // 'error' | 'warn'
  final String text;
  final int? fix;      // reconcile stage capacity to this count
  final int? fixPow2;  // round bracket seeds to this power of two
  const FormatWarning({this.stageId, required this.sev, required this.text, this.fix, this.fixPow2});
  bool get fixable => fix != null || fixPow2 != null;
}

class StageFlow {
  final Stage stage;
  final int inCount, outCount, matches;
  const StageFlow(this.stage, this.inCount, this.outCount, this.matches);
}

class FormatAnalysis {
  final List<StageFlow> flow;
  final List<FormatWarning> warnings;
  final int totalMatches;
  final double wallClockHours; // est. run time across courts
  const FormatAnalysis(this.flow, this.warnings, this.totalMatches, this.wallClockHours);
  bool get ok => warnings.isEmpty && flow.isNotEmpty;
  int get errors => warnings.where((w) => w.sev == 'error').length;
}

/// Trace players through the whole format and surface real-world problems.
FormatAnalysis analyzeFormat(List<Stage> stages, int entrants, int courts) {
  final flow = <StageFlow>[];
  final warnings = <FormatWarning>[];
  var total = 0;

  for (var i = 0; i < stages.length; i++) {
    final s = stages[i];
    final cap = capacity(s);
    final expected = i == 0 ? entrants : flow[i - 1].outCount;

    if (cap != null && cap != expected) {
      warnings.add(FormatWarning(
        stageId: s.id, sev: cap < expected ? 'error' : 'warn',
        text: i == 0
            ? 'Stage 1 (${s.name}) is set for $cap but you have $entrants registered.'
            : 'Stage ${i + 1} (${s.name}) expects $expected from the previous stage but is set for $cap.',
        fix: expected,
      ));
    }
    if ((s.kind == StageKind.knockout || s.kind == StageKind.doubleElim) && !isPow2(s.seeds)) {
      warnings.add(FormatWarning(stageId: s.id, sev: 'warn',
        text: '${s.name}: ${s.seeds} isn\'t a power of two — ${nextPow2(s.seeds) - s.seeds} byes in round 1.',
        fixPow2: nextPow2(s.seeds)));
    }
    if (s.kind == StageKind.groups) {
      final sz = groupSizes(expected, s.groups);
      final minSize = sz.reduce((a, b) => a < b ? a : b);
      if (minSize < 2) {
        warnings.add(FormatWarning(stageId: s.id, sev: 'error', text: '${s.name}: $expected pairs can\'t fill ${s.groups} groups — reduce the number of groups.'));
      } else if (s.advance >= minSize) {
        warnings.add(FormatWarning(stageId: s.id, sev: 'error', text: '${s.name}: advancing ${s.advance} from a group of $minSize leaves nothing to play for.'));
      } else if (expected % s.groups != 0) {
        warnings.add(FormatWarning(stageId: s.id, sev: 'warn', text: '${s.name}: $expected pairs split unevenly — groups of ${sz.join('/')}. That\'s fine, just uneven.'));
      }
    }
    final m = matchCount(s, expected);
    total += m;
    flow.add(StageFlow(s, expected, produces(s), m));
  }

  if (flow.isNotEmpty) {
    final finalOut = flow.last.outCount;
    if (finalOut > 1 && stages.last.kind != StageKind.ladder) {
      warnings.add(FormatWarning(sev: 'warn', text: 'Format ends with $finalOut players still in — add a final knockout stage to crown one winner.'));
    }
  }
  const hoursPerMatch = 0.75;
  final wall = courts > 0 ? (total / courts).ceil() * hoursPerMatch : 0.0;
  return FormatAnalysis(flow, warnings, total, wall);
}

/// Auto-size a stage's intake to match what feeds it. Groups & swiss are
/// flexible so they're returned unchanged (they accept any count).
Stage wireStage(Stage s, int expected) {
  switch (s.kind) {
    case StageKind.knockout:
    case StageKind.doubleElim:
    case StageKind.consolation:
      s.cfg['seeds'] = nextPow2(expected);
      break;
    case StageKind.roundRobin:
    case StageKind.ladder:
      s.cfg['players'] = expected;
      break;
    case StageKind.groups:
    case StageKind.swiss:
      break;
  }
  return s;
}

/// Apply a warning's fix to the matching stage in [stages].
void applyFix(List<Stage> stages, FormatWarning w) {
  final s = stages.firstWhere((x) => x.id == w.stageId, orElse: () => stages.first);
  if (w.fixPow2 != null) { s.cfg['seeds'] = w.fixPow2!; return; }
  if (w.fix != null) wireStage(s, w.fix!);
}

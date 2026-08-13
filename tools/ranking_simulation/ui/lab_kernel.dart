/// The Ranking Lab's compute kernel.
///
/// This is the ONLY thing the lab UI talks to: one function, JSON in, JSON out.
/// It is compiled to JavaScript by dart2js (see `build.dart`) so the browser
/// runs the *same* `engines.dart` / `sim.dart` the batch study and the golden
/// tests run — the lab cannot drift from the study because there is only one
/// copy of the maths.
///
/// NOTHING HERE TOUCHES PRODUCTION. No Supabase client, no `lib/` import, no
/// network, no disk. Every player, rating and match below is invented in
/// memory and dies when the tab closes.
library;

import 'dart:convert';
import 'dart:math' as math;

import '../engines.dart';
import '../metrics.dart';
import '../runner.dart';
import '../sim.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Engine construction
// ─────────────────────────────────────────────────────────────────────────────

const kEngineCatalog = <Map<String, dynamic>>[
  {
    'id': 'v2',
    'label': 'V2 · Current (production)',
    'short': 'V2',
    'kind': 'current',
    'blurb': 'Exact mirror of the live _settle_rating / RatingEngine maths.',
    'locked': true,
  },
  {
    'id': 'v3',
    'label': 'V3 · Candidate',
    'short': 'V3',
    'kind': 'hybrid',
    'blurb': 'The proposed fix: centred prior, staged placement K, no placement '
        'reliability discount, capped margin. Not production-approved.',
  },
  {
    'id': 'tuned',
    'label': 'C · Tuned Hybrid (study)',
    'short': 'C',
    'kind': 'hybrid',
    'blurb': "The study's fully-tuned configuration, including the parts V3 "
        'deliberately leaves out (steeper curve, adaptive + diversity sigma).',
  },
  {
    'id': 'aggressive',
    'label': 'B · Aggressive placement only',
    'short': 'B',
    'kind': 'hybrid',
    'blurb': 'Placement changes only; identical to V2 once established.',
  },
  // ── V3 placement variants (tuning experiment; none is a proposal) ──
  {
    'id': 'v3a',
    'label': 'V3-A · Current candidate',
    'short': 'V3-A',
    'kind': 'hybrid',
    'variant': true,
    'blurb': 'Identical to V3. Stage K 0.80 / 0.50 / 0.30, placement sigma '
        'decay 0.88. The baseline the other variants are read against.',
  },
  {
    'id': 'v3b',
    'label': 'V3-B · Sustained correction',
    'short': 'V3-B',
    'kind': 'hybrid',
    'variant': true,
    'blurb': 'Stage K 0.80 / 0.60 / 0.40 — late placement keeps more power. '
        'Sigma decay unchanged.',
  },
  {
    'id': 'v3c',
    'label': 'V3-C · Balanced correction',
    'short': 'V3-C',
    'kind': 'hybrid',
    'variant': true,
    'blurb': 'Stage K 0.70 / 0.60 / 0.45 — less of the budget spent in the '
        'first three matches. Sigma decay unchanged.',
  },
  {
    'id': 'v3d',
    'label': 'V3-D · Slower sigma',
    'short': 'V3-D',
    'kind': 'hybrid',
    'variant': true,
    'blurb': "Candidate K, placement sigma decay 0.95 instead of 0.88. Tests "
        'whether the engine gets confident before it has finished correcting.',
  },
  {
    'id': 'v3e',
    'label': 'V3-E · Sustained K + slower sigma',
    'short': 'V3-E',
    'kind': 'hybrid',
    'variant': true,
    'blurb': "B's schedule and D's decay together. Both raise K, so this is "
        'the variant most at risk of overshooting.',
  },
  {
    'id': 'v3f',
    'label': 'V3-F · Continuous confidence',
    'short': 'V3-F',
    'kind': 'hybrid',
    'variant': true,
    'blurb': 'V3-E plus the post-placement sigma decay slowed to 0.97. The only '
        'variant that changes anything outside placement — it removes the '
        'confidence cliff at match 10.',
  },
  {
    'id': 'v3f5',
    'label': 'V3-F5 · 5-match placement',
    'short': 'V3-F5',
    'kind': 'hybrid',
    'variant': true,
    'blurb': 'V3-F with visible placement cut to 5 matches and the stages '
        'retuned for it (K 1.15 / 0.90 / 0.70). Revealed on match count alone, '
        'so the player is ranked while still openly low-confidence.',
  },
  {
    'id': 'trueskill',
    'label': 'D · TrueSkill',
    'short': 'TS',
    'kind': 'trueskill',
    'blurb': 'Gaussian factor-graph comparison engine. Not a migration proposal.',
  },
  {
    'id': 'trueskill_set',
    'label': 'D2 · TrueSkill per-set',
    'short': 'TS/set',
    'kind': 'trueskill',
    'blurb': 'TrueSkill updated once per set instead of once per match.',
  },
  {
    'id': 'glicko',
    'label': 'E · Glicko-2',
    'short': 'G2',
    'kind': 'glicko',
    'blurb': 'Glicko-2 with a doubles virtual-opponent adaptation.',
  },
];

SelfDeclared _declaredFrom(String? s) => switch (s) {
      'beginner' => SelfDeclared.beginner,
      'intermediate' => SelfDeclared.intermediate,
      'advanced' => SelfDeclared.advanced,
      'competitive' => SelfDeclared.competitive,
      _ => SelfDeclared.unknown,
    };

String _declaredName(SelfDeclared d) => d.name;

double _d(Object? v, double fallback) =>
    v is num ? v.toDouble() : (v is String ? (double.tryParse(v) ?? fallback) : fallback);
int _i(Object? v, int fallback) =>
    v is num ? v.toInt() : (v is String ? (int.tryParse(v) ?? fallback) : fallback);
bool _b(Object? v, bool fallback) => v is bool ? v : fallback;

/// Applies a JSON patch onto a [HybridConfig]. Unknown keys are ignored so an
/// older saved scenario still loads.
HybridConfig _patch(HybridConfig base, Map<String, dynamic>? o) {
  if (o == null || o.isEmpty) return base;
  Map<SelfDeclared, double>? declared;
  final dp = o['declaredPriors'];
  if (dp is Map) {
    declared = {
      for (final e in dp.entries)
        _declaredFrom(e.key.toString()): _d(e.value, 3.3),
    };
  }
  return base.copyWith(
    prior: o.containsKey('prior') ? _d(o['prior'], base.prior) : null,
    sigma0: o.containsKey('sigma0') ? _d(o['sigma0'], base.sigma0) : null,
    useDeclaredPrior: o.containsKey('useDeclaredPrior')
        ? _b(o['useDeclaredPrior'], base.useDeclaredPrior)
        : null,
    declaredPriors: declared,
    placementMatches: o.containsKey('placementMatches')
        ? _i(o['placementMatches'], base.placementMatches)
        : null,
    stageEnds: o['stageEnds'] is List
        ? [for (final v in o['stageEnds'] as List) _i(v, 0)]
        : null,
    stageK: o['stageK'] is List
        ? [for (final v in o['stageK'] as List) _d(v, 0.5)]
        : null,
    placementRelFloor: o.containsKey('placementRelFloor')
        ? _d(o['placementRelFloor'], base.placementRelFloor)
        : null,
    placementSigmaDecay: o.containsKey('placementSigmaDecay')
        ? _d(o['placementSigmaDecay'], base.placementSigmaDecay)
        : null,
    relRampMatches: o.containsKey('relRampMatches')
        ? _i(o['relRampMatches'], base.relRampMatches)
        : null,
    kMin: o.containsKey('kMin') ? _d(o['kMin'], base.kMin) : null,
    kMax: o.containsKey('kMax') ? _d(o['kMax'], base.kMax) : null,
    sigmaDecay:
        o.containsKey('sigmaDecay') ? _d(o['sigmaDecay'], base.sigmaDecay) : null,
    relFloor: o.containsKey('relFloor') ? _d(o['relFloor'], base.relFloor) : null,
    postStageEnds: o['postStageEnds'] is List
        ? [for (final v in o['postStageEnds'] as List) _i(v, 0)]
        : null,
    postStageDecay: o['postStageDecay'] is List
        ? [for (final v in o['postStageDecay'] as List) _d(v, 0.95)]
        : null,
    curveScale:
        o.containsKey('curveScale') ? _d(o['curveScale'], base.curveScale) : null,
    resultWeight: o.containsKey('resultWeight')
        ? _d(o['resultWeight'], base.resultWeight)
        : null,
    marginCap: o.containsKey('marginCap') ? _d(o['marginCap'], base.marginCap) : null,
    lambdaImbalance: o.containsKey('lambdaImbalance')
        ? _d(o['lambdaImbalance'], base.lambdaImbalance)
        : null,
    adaptiveSigma: o.containsKey('adaptiveSigma')
        ? _b(o['adaptiveSigma'], base.adaptiveSigma)
        : null,
    surpriseRef:
        o.containsKey('surpriseRef') ? _d(o['surpriseRef'], base.surpriseRef) : null,
    diversitySigma: o.containsKey('diversitySigma')
        ? _b(o['diversitySigma'], base.diversitySigma)
        : null,
    decayHighInfo: o.containsKey('decayHighInfo')
        ? _d(o['decayHighInfo'], base.decayHighInfo)
        : null,
    decayMedInfo:
        o.containsKey('decayMedInfo') ? _d(o['decayMedInfo'], base.decayMedInfo) : null,
    decayLowInfo:
        o.containsKey('decayLowInfo') ? _d(o['decayLowInfo'], base.decayLowInfo) : null,
    internalMin:
        o.containsKey('internalMin') ? _d(o['internalMin'], base.internalMin) : null,
    internalMax:
        o.containsKey('internalMax') ? _d(o['internalMax'], base.internalMax) : null,
    ratingInactivityDecay: o.containsKey('ratingInactivityDecay')
        ? _b(o['ratingInactivityDecay'], base.ratingInactivityDecay)
        : null,
    idleSigmaPerWeek: o.containsKey('idleSigmaPerWeek')
        ? _d(o['idleSigmaPerWeek'], base.idleSigmaPerWeek)
        : null,
    idleSigmaCap:
        o.containsKey('idleSigmaCap') ? _d(o['idleSigmaCap'], base.idleSigmaCap) : null,
    idleRatingPerWeek: o.containsKey('idleRatingPerWeek')
        ? _d(o['idleRatingPerWeek'], base.idleRatingPerWeek)
        : null,
    displayMinMatches: o.containsKey('displayMinMatches')
        ? _i(o['displayMinMatches'], base.displayMinMatches)
        : null,
    displayMaxSigma: o.containsKey('displayMaxSigma')
        ? _d(o['displayMaxSigma'], base.displayMaxSigma)
        : null,
    displayMinPartners: o.containsKey('displayMinPartners')
        ? _i(o['displayMinPartners'], base.displayMinPartners)
        : null,
  );
}

Map<String, dynamic> _cfgJson(HybridConfig c) => {
      'prior': c.prior,
      'sigma0': c.sigma0,
      'useDeclaredPrior': c.useDeclaredPrior,
      'declaredPriors': {
        for (final e in (c.declaredPriors.isEmpty ? kDeclaredPriors : c.declaredPriors)
            .entries)
          _declaredName(e.key): e.value,
      },
      'placementMatches': c.placementMatches,
      'stageEnds': c.stageEnds,
      'stageK': c.stageK,
      'placementRelFloor': c.placementRelFloor,
      'placementSigmaDecay': c.placementSigmaDecay,
      'relRampMatches': c.relRampMatches,
      'kMin': c.kMin,
      'kMax': c.kMax,
      'sigmaDecay': c.sigmaDecay,
      'relFloor': c.relFloor,
      'postStageEnds': c.postStageEnds,
      'postStageDecay': c.postStageDecay,
      'curveScale': c.curveScale,
      'resultWeight': c.resultWeight,
      'marginCap': c.marginCap,
      'lambdaImbalance': c.lambdaImbalance,
      'adaptiveSigma': c.adaptiveSigma,
      'surpriseRef': c.surpriseRef,
      'diversitySigma': c.diversitySigma,
      'decayHighInfo': c.decayHighInfo,
      'decayMedInfo': c.decayMedInfo,
      'decayLowInfo': c.decayLowInfo,
      'internalMin': c.internalMin,
      'internalMax': c.internalMax,
      'ratingInactivityDecay': c.ratingInactivityDecay,
      'idleSigmaPerWeek': c.idleSigmaPerWeek,
      'idleSigmaCap': c.idleSigmaCap,
      'idleRatingPerWeek': c.idleRatingPerWeek,
      'displayMinMatches': c.displayMinMatches,
      'displayMaxSigma': c.displayMaxSigma,
      'displayMinPartners': c.displayMinPartners,
    };

HybridConfig _baseFor(String id) => switch (id) {
      'v3' => kV3Config,
      'v3a' => kV3A,
      'v3b' => kV3B,
      'v3c' => kV3C,
      'v3d' => kV3D,
      'v3e' => kV3E,
      'v3f' => kV3F,
      'v3f5' => kV3F5,
      'tuned' => kTunedConfig,
      'aggressive' => const HybridConfig(
          prior: 3.3,
          sigma0: 0.95,
          placementMatches: 10,
          stageEnds: [3, 7, 10],
          stageK: [0.70, 0.45, 0.28],
          placementRelFloor: 0.85,
          placementSigmaDecay: 0.88,
          curveScale: 1.0,
          resultWeight: 0.7,
          marginCap: 0.5,
          sigmaDecay: 0.92,
          relFloor: 0.5,
          internalMin: 0.0,
          internalMax: 7.0,
          ratingInactivityDecay: true,
        ),
      _ => kV3Config,
    };

/// [spec] = {id, cfg?} where cfg is a partial override of the engine's preset.
RankingEngine buildEngine(Map<String, dynamic> spec) {
  final id = (spec['id'] ?? 'v3').toString();
  final cfg = (spec['cfg'] as Map?)?.cast<String, dynamic>();
  final label = kEngineCatalog.firstWhere((e) => e['id'] == id,
      orElse: () => kEngineCatalog[1])['label'] as String;

  switch (id) {
    case 'v2':
      // Production's own maths is never edited. What CAN move is the prior (so
      // the prior experiment can isolate it) and the two match-count
      // thresholds, so a comparison against an engine with a placement phase
      // can be made at the same number of matches instead of being rigged by a
      // difference nobody chose.
      return CurrentEngine(
        startPrior: _d(cfg?['prior'], CurrentEngine.prior),
        boostWindow: _i(cfg?['boostWindow'], CurrentEngine.boostWindowDefault),
        provisionalAt: _i(cfg?['provisionalAt'], CurrentEngine.provisionalAtDefault),
      );
    case 'trueskill':
      return TrueSkillEngine(name: label);
    case 'trueskill_set':
      return TrueSkillEngine(name: label, perSet: true);
    case 'glicko':
      return Glicko2Engine(name: label);
    default:
      return HybridEngine(label, _patch(_baseFor(id), cfg));
  }
}

List<Map<String, dynamic>> _engineSpecs(Object? raw) {
  if (raw is! List || raw.isEmpty) {
    return [
      {'id': 'v2'},
      {'id': 'v3'},
    ];
  }
  return [
    for (final e in raw)
      if (e is Map) e.cast<String, dynamic>() else {'id': e.toString()},
  ];
}

String _labelFor(String id) => (kEngineCatalog.firstWhere((e) => e['id'] == id,
    orElse: () => const {'label': '?'})['label'] as String);

/// The catalog label, except that an engine whose thresholds have been moved
/// off production's own values must stop being called "production".
String _labelOf(String id, RankingEngine e) =>
    (e is CurrentEngine && !e.isProductionExact)
        ? _labelFor(id).replaceAll('(production)', '(adapted)')
        : _labelFor(id);

String _shortOf(String id) => (kEngineCatalog.firstWhere((e) => e['id'] == id,
    orElse: () => const {'short': '?'})['short'] as String);

World _world(Object? raw) => switch (raw?.toString()) {
      'A' => worldA,
      'B' => worldB,
      'C' => worldC,
      'E' => worldE,
      'D-flat' => worldDFlat,
      'D-steep' => worldDSteep,
      _ => worldD,
    };

// ─────────────────────────────────────────────────────────────────────────────
// Scoreline parsing — the same shape production stores
// (`score_team_a = '6-4,3-6,6-2'`, team-A perspective, a match tie-break
// counting as a single game).
// ─────────────────────────────────────────────────────────────────────────────

/// Returns {sets, gamesA, gamesB, aWon} or {error}.
Map<String, dynamic> parseScore(String raw) {
  final txt = raw.trim();
  if (txt.isEmpty) return {'error': 'Enter a score, e.g. 6-4,6-3'};
  final sets = <List<int>>[];
  for (final chunk in txt.split(',')) {
    final part = chunk.trim();
    if (part.isEmpty) continue;
    final bits = part.split(RegExp(r'[-–:]'));
    if (bits.length != 2) return {'error': 'Cannot read set "$part"'};
    final a = int.tryParse(bits[0].trim());
    final b = int.tryParse(bits[1].trim());
    if (a == null || b == null) return {'error': 'Cannot read set "$part"'};
    if (a < 0 || b < 0 || a > 99 || b > 99) return {'error': 'Set "$part" out of range'};
    if (a == b) return {'error': 'Set "$part" has no winner'};
    sets.add([a, b]);
  }
  if (sets.isEmpty) return {'error': 'Enter at least one set'};
  var sa = 0, sb = 0, ga = 0, gb = 0;
  for (final s in sets) {
    // Mirrors production `parseSetGames` / the SQL parser: a championship or
    // super tie-break set (either side ≥ 10, e.g. '10-8') is worth ONE game to
    // its winner, so a match tie-break cannot dwarf the games ratio.
    if (s[0] >= 10 || s[1] >= 10) {
      if (s[0] > s[1]) {
        ga += 1;
      } else {
        gb += 1;
      }
    } else {
      ga += s[0];
      gb += s[1];
    }
    if (s[0] > s[1]) {
      sa++;
    } else {
      sb++;
    }
  }
  if (sa == sb) return {'error': 'Sets are level — that is not a finished match'};
  return {
    'sets': sets,
    'gamesA': ga,
    'gamesB': gb,
    'aWon': sa > sb,
    'setsA': sa,
    'setsB': sb,
  };
}

String _fmtScore(List<List<int>> sets) => sets.map((s) => '${s[0]}-${s[1]}').join(', ');

// ─────────────────────────────────────────────────────────────────────────────
// Story / solo session — one focus player, stepped by hand
// ─────────────────────────────────────────────────────────────────────────────

class _Lineup {
  final int partner, opp1, opp2;
  const _Lineup(this.partner, this.opp1, this.opp2);
}

/// A pool of supporting players. In `established` mode they are pinned at their
/// true level (calibrated reference players) so the focus player's movement is
/// the only thing changing; in `fresh` mode they are brand new too, which is
/// what launch week actually looks like.
class PoolSpec {
  final List<double> skills;
  final bool established;
  const PoolSpec(this.skills, this.established);
}

class StorySession {
  final int seed;
  final double trueSkill;
  final String name;
  final World world;
  final PoolSpec pool;
  final List<Map<String, dynamic>> specs;
  final Map<String, RankingEngine> engines = {};
  final Rng rng;

  /// Focus player is id 0; pool players are 1..n.
  int played = 0;
  final List<Map<String, dynamic>> log = [];
  final Map<String, List<double>> ratingTrack = {};
  final Map<String, List<double>> sigmaTrack = {};
  int wins = 0, losses = 0;
  final Set<int> partnersSeen = {}, oppsSeen = {};

  StorySession({
    required this.seed,
    required this.trueSkill,
    required this.name,
    required this.world,
    required this.pool,
    required this.specs,
    required this.rng,
  });

  String keyOf(int i) => '${specs[i]['id']}#$i';
}

StorySession? _story;

PoolSpec makePool_(Rng rng, double focusSkill, int n, bool established) {
  final skills = <double>[];
  for (var i = 0; i < n; i++) {
    // centred on the focus player's true level — this is "people mostly play
    // others around their own standard", not a global draw
    skills.add(clampD(focusSkill + rng.gauss() * 0.9, 0.4, 6.9));
  }
  return PoolSpec(skills, established);
}

void _registerAll(StorySession s) {
  for (var i = 0; i < s.specs.length; i++) {
    final e = buildEngine(s.specs[i]);
    final key = s.keyOf(i);
    s.engines[key] = e;
    for (var p = 0; p <= s.pool.skills.length; p++) {
      e.register(p, declared: _declaredFrom(s.specs[i]['declared']?.toString()));
    }
    // optional hand-set starting point for the focus player (smurf / overrated)
    final sr = s.specs[i]['startRating'];
    final ss = s.specs[i]['startSigma'];
    if (sr != null || ss != null) {
      e.seed(0, _d(sr, e.estimate(0)), _d(ss, e.sigmaOf(0)));
    }
    if (s.pool.established) {
      for (var p = 1; p <= s.pool.skills.length; p++) {
        e.markAnchor(p, s.pool.skills[p - 1], 0.25);
      }
    }
    s.ratingTrack[key] = [e.estimate(0)];
    s.sigmaTrack[key] = [e.sigmaOf(0)];
  }
}

/// Picks a partner and two opponents. Deliberately chosen from TRUE skill, not
/// from any engine's rating: every engine in the comparison must see the same
/// match or the head-to-head is meaningless.
_Lineup _autoLineup(StorySession s) {
  final n = s.pool.skills.length;
  final used = <int>{};
  int pick(double target) {
    var best = 1, bestD = double.infinity;
    for (var t = 0; t < 40; t++) {
      final c = 1 + s.rng.nextInt(n);
      if (used.contains(c)) continue;
      final d = (s.pool.skills[c - 1] - target).abs();
      if (d < bestD) {
        bestD = d;
        best = c;
      }
    }
    used.add(best);
    return best;
  }

  final partner = pick(s.trueSkill + s.rng.gauss() * 0.5);
  final pairStrength = s.world.teamStrength(s.trueSkill, s.pool.skills[partner - 1]);
  final o1 = pick(pairStrength + s.rng.gauss() * 0.35);
  final o2 = pick(pairStrength + s.rng.gauss() * 0.35);
  return _Lineup(partner, o1, o2);
}

Map<String, dynamic> _storyState(StorySession s) {
  final engines = <Map<String, dynamic>>[];
  for (var i = 0; i < s.specs.length; i++) {
    final key = s.keyOf(i);
    final e = s.engines[key]!;
    final placement = e.placementLength;   // 0 means "this engine has no placement phase"
    final (gateMatches, gateSigma, gatePartners) = e.displayGate;
    engines.add({
      'key': key,
      'id': s.specs[i]['id'],
      'label': _labelOf(s.specs[i]['id'].toString(), e),
      'short': _shortOf(s.specs[i]['id'].toString()),
      'rating': e.estimate(0),
      'publicRating': e.publicRating(0),
      'sigma': e.sigmaOf(0),
      'matches': e.matchesOf(0),
      'displayReady': e.displayReady(0),
      // A player is only "in placement" on an engine that HAS one. Production
      // does not, so V2 is never in placement — it is merely not yet settled.
      'hasPlacement': placement > 0,
      'inPlacement': placement > 0 && e.matchesOf(0) < placement,
      // true when the thresholds have been moved off production's own values,
      // so the UI can stop calling it "production" the moment it stops being so
      'adapted': e is CurrentEngine && !e.isProductionExact,
      'boostWindow': e is CurrentEngine ? e.boostWindow : null,
      'placementMatches': placement,
      'gateMatches': gateMatches,
      'gateSigma': gateSigma,
      'gatePartners': gatePartners,
      'error': e.estimate(0) - s.trueSkill,
      'ratingTrack': s.ratingTrack[key],
      'sigmaTrack': s.sigmaTrack[key],
    });
  }
  return {
    'seed': s.seed,
    'name': s.name,
    'trueSkill': s.trueSkill,
    'played': s.played,
    'wins': s.wins,
    'losses': s.losses,
    'partners': s.partnersSeen.length,
    'opponents': s.oppsSeen.length,
    'poolEstablished': s.pool.established,
    'world': s.world.name,
    'engines': engines,
    'log': s.log,
  };
}

/// Plays exactly one match. [req] may pin the lineup, force the winner, or give
/// an explicit scoreline; anything absent is simulated from true skill.
///
/// [lean] skips the per-player explanation traces, the match log and the state
/// snapshot — everything the sweep does not read. The SIMULATION is untouched:
/// same lineup draw, same RNG call order, same update. There is deliberately
/// only one play path, so a sweep cannot quietly diverge from the Story tab.
Map<String, dynamic> _storyPlay(StorySession s, Map<String, dynamic> req,
    {bool lean = false}) {
  final n = s.pool.skills.length;
  int clampId(Object? v, int fallback) {
    final id = _i(v, fallback);
    return id >= 1 && id <= n ? id : fallback;
  }

  final auto = _autoLineup(s);
  final partner = clampId(req['partner'], auto.partner);
  var o1 = clampId(req['opp1'], auto.opp1);
  var o2 = clampId(req['opp2'], auto.opp2);
  if (o2 == o1) o2 = o1 == n ? (n > 1 ? o1 - 1 : o1) : o1 + 1;

  final eff = <double>[
    s.trueSkill,
    ...s.pool.skills,
  ];
  // per-match form noise, exactly as the batch worlds apply it
  if (s.world.formSigma > 0) {
    for (var i = 0; i < eff.length; i++) {
      eff[i] = clampD(eff[i] + s.rng.gauss() * s.world.formSigma, 0, 7);
    }
  }

  MatchObs m;
  String source;
  final manualScore = req['score']?.toString().trim();
  if (manualScore != null && manualScore.isNotEmpty) {
    final p = parseScore(manualScore);
    if (p['error'] != null) return {'error': p['error']};
    m = MatchObs(
      a1: 0,
      a2: partner,
      b1: o1,
      b2: o2,
      gamesA: p['gamesA'] as int,
      gamesB: p['gamesB'] as int,
      sets: (p['sets'] as List).cast<List<int>>(),
      aWon: p['aWon'] as bool,
    );
    source = 'typed score';
  } else {
    m = s.world.play(s.rng, 0, partner, o1, o2, eff);
    final forced = req['winner']?.toString();
    if (forced == 'A' || forced == 'B') {
      final wantA = forced == 'A';
      if (m.aWon != wantA) {
        // Keep the generated scoreline but flip whose it is, so an overridden
        // upset still carries a realistic margin instead of a made-up one.
        m = MatchObs(
          a1: 0,
          a2: partner,
          b1: o1,
          b2: o2,
          gamesA: m.gamesB,
          gamesB: m.gamesA,
          sets: [for (final st in m.sets) [st[1], st[0]]],
          aWon: wantA,
        );
        source = 'forced ${wantA ? "win" : "loss"}';
      } else {
        source = 'simulated';
      }
    } else {
      source = 'simulated';
    }
  }

  final trueP = s.world.trueMatchProb(
    s.world.teamStrength(eff[0], eff[partner]),
    s.world.teamStrength(eff[o1], eff[o2]),
  );

  final perEngine = <Map<String, dynamic>>[];
  for (var i = 0; i < s.specs.length; i++) {
    final key = s.keyOf(i);
    final e = s.engines[key]!;
    final expA = e.predictA(m);
    if (lean) {
      e.update(m);
      s.ratingTrack[key]!.add(e.estimate(0));
      s.sigmaTrack[key]!.add(e.sigmaOf(0));
      perEngine.add({
        'key': key,
        'expectedA': expA,
        'rating': e.estimate(0),
        'sigma': e.sigmaOf(0),
        'displayReady': e.displayReady(0),
      });
      continue;
    }
    final buf = <MoveTrace>[];
    e.trace = buf;
    e.update(m);
    e.trace = null;
    final mine = buf.where((t) => t.id == 0).toList();
    s.ratingTrack[key]!.add(e.estimate(0));
    s.sigmaTrack[key]!.add(e.sigmaOf(0));
    perEngine.add({
      'key': key,
      'short': _shortOf(s.specs[i]['id'].toString()),
      'label': _labelOf(s.specs[i]['id'].toString(), e),
      'expectedA': expA,
      'focus': mine.isEmpty ? null : mine.first.toJson(),
      'others': [
        for (final t in buf.where((t) => t.id != 0))
          {...t.toJson(), 'trueSkill': s.pool.skills[t.id - 1]},
      ],
      'rating': e.estimate(0),
      'sigma': e.sigmaOf(0),
      'error': e.estimate(0) - s.trueSkill,
      'displayReady': e.displayReady(0),
    });
  }

  s.played++;
  if (m.aWon) {
    s.wins++;
  } else {
    s.losses++;
  }
  s.partnersSeen.add(partner);
  s.oppsSeen.addAll([o1, o2]);

  final entry = {
    'n': s.played,
    'partner': {'id': partner, 'skill': s.pool.skills[partner - 1]},
    'opp1': {'id': o1, 'skill': s.pool.skills[o1 - 1]},
    'opp2': {'id': o2, 'skill': s.pool.skills[o2 - 1]},
    'score': _fmtScore(m.sets),
    'gamesA': m.gamesA,
    'gamesB': m.gamesB,
    'won': m.aWon,
    'source': source,
    'trueWinProb': trueP,
    'engines': perEngine,
  };
  if (lean) return {'match': entry};
  s.log.add(entry);
  return {'match': entry, 'state': _storyState(s)};
}

// ─────────────────────────────────────────────────────────────────────────────
// Solo runs (Compare tab) — same machinery, no session, N matches at once
// ─────────────────────────────────────────────────────────────────────────────

Map<String, dynamic> _soloRun(Map<String, dynamic> req) {
  final seed = _i(req['seed'], 482901);
  final trueSkill = _d(req['trueSkill'], 5.5);
  final matches = _i(req['matches'], 10).clamp(1, 400);
  final world = _world(req['world']);
  final established = (req['pool']?.toString() ?? 'established') == 'established';
  final specs = _engineSpecs(req['engines']);

  final rng = Rng(seed * 7919 + 13);
  final s = StorySession(
    seed: seed,
    trueSkill: trueSkill,
    name: req['name']?.toString() ?? 'Player',
    world: world,
    pool: makePool_(rng, trueSkill, 40, established),
    specs: specs,
    rng: rng,
  );
  _registerAll(s);
  for (var i = 0; i < matches; i++) {
    _storyPlay(s, const {});
  }

  return {
    'seed': seed,
    'trueSkill': trueSkill,
    'matches': matches,
    'series': [
      for (var i = 0; i < specs.length; i++)
        {
          'key': s.keyOf(i),
          'id': specs[i]['id'],
          'short': _shortOf(specs[i]['id'].toString()),
          'label': _labelFor(specs[i]['id'].toString()),
          'ratings': s.ratingTrack[s.keyOf(i)],
          'sigmas': s.sigmaTrack[s.keyOf(i)],
          'final': s.engines[s.keyOf(i)]!.estimate(0),
          'error': s.engines[s.keyOf(i)]!.estimate(0) - trueSkill,
          'displayReady': s.engines[s.keyOf(i)]!.displayReady(0),
          'sigma': s.engines[s.keyOf(i)]!.sigmaOf(0),
        },
    ],
    'wins': s.wins,
    'losses': s.losses,
  };
}

/// Averages [_soloRun] over several seeds — one seed is an anecdote.
Map<String, dynamic> _soloAverage(Map<String, dynamic> req) {
  final reps = _i(req['reps'], 1).clamp(1, 200);
  final baseSeed = _i(req['seed'], 482901);
  final matches = _i(req['matches'], 10).clamp(1, 400);
  final specs = _engineSpecs(req['engines']);

  final sums = List.generate(specs.length, (_) => List<double>.filled(matches + 1, 0));
  final absErr = List.generate(specs.length, (_) => List<double>.filled(matches + 1, 0));
  final finals = List.generate(specs.length, (_) => <double>[]);
  Map<String, dynamic>? first;

  for (var r = 0; r < reps; r++) {
    final run = _soloRun({...req, 'seed': baseSeed + r * 101});
    first ??= run;
    final series = run['series'] as List;
    for (var i = 0; i < series.length; i++) {
      final track = (series[i] as Map)['ratings'] as List;
      for (var t = 0; t <= matches && t < track.length; t++) {
        sums[i][t] += (track[t] as num).toDouble();
        absErr[i][t] += ((track[t] as num).toDouble() - _d(req['trueSkill'], 5.5)).abs();
      }
      finals[i].add(((series[i] as Map)['final'] as num).toDouble());
    }
  }

  final series = (first!['series'] as List).cast<Map>();
  return {
    'seed': baseSeed,
    'reps': reps,
    'trueSkill': _d(req['trueSkill'], 5.5),
    'matches': matches,
    'series': [
      for (var i = 0; i < series.length; i++)
        {
          'id': series[i]['id'],
          'short': series[i]['short'],
          'label': series[i]['label'],
          'ratings': [for (final v in sums[i]) v / reps],
          'absError': [for (final v in absErr[i]) v / reps],
          'final': mean(finals[i]),
          'finalSd': reps > 1 ? sd(finals[i]) : 0.0,
          'error': mean(finals[i]) - _d(req['trueSkill'], 5.5),
        },
    ],
    'sample': reps == 1 ? first : null,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// V3 PLACEMENT SWEEP
//
// One question: starting everyone at the population centre, can placement move
// a mis-seeded player far enough, fast enough, in BOTH directions?
//
// Fairness is structural, not promised: every engine in a run lives inside ONE
// StorySession, so they see the same partner, the same opponents, the same
// scoreline and the same result. There is no per-engine matchmaking anywhere in
// this file — the lineup is drawn from TRUE skill, which no engine can see.
// ─────────────────────────────────────────────────────────────────────────────

/// Accumulates one (true skill × engine) cell across seeds.
class _SweepAcc {
  final int horizons;
  final List<List<double>> rating; // [horizon][rep]
  final List<List<double>> sigma;
  final List<int> shown;           // [horizon] count of display-ready reps
  final List<double> half50 = [], half75 = [];
  int never50 = 0, never75 = 0, misSeeded = 0;
  final List<double> overshoot = [];
  final List<double> wobble = [], drift = [];
  double brierSum = 0;
  int brierN = 0;
  double start = 0;
  // Mean win probability the engine gave the focus team during placement.
  // Against the TRUE win rate this is the per-match surprise driving the
  // rating — and the thing that makes one direction faster than the other.
  double expSum = 0;
  int expN = 0;

  _SweepAcc(this.horizons)
      : rating = List.generate(horizons, (_) => <double>[]),
        sigma = List.generate(horizons, (_) => <double>[]),
        shown = List<int>.filled(horizons, 0);
}

Map<String, dynamic> _v3Sweep(Map<String, dynamic> req) {
  final skills = <double>[];
  final rawSkills = req['skills'];
  if (rawSkills is List && rawSkills.isNotEmpty) {
    for (final v in rawSkills) {
      skills.add(clampD(_d(v, 3.3), 0, 7));
    }
  } else {
    for (var v = 0.5; v <= 6.51; v += 0.5) {
      skills.add(round2_(v));
    }
  }
  final reps = _i(req['reps'], 50).clamp(1, 200);
  final baseSeed = _i(req['seed'], 482901);
  final specs = _engineSpecs(req['engines']);
  final established = (req['pool']?.toString() ?? 'established') == 'established';
  final world = _world(req['world']);

  final horizons = <int>{
    for (final v in (req['horizons'] is List ? req['horizons'] as List : const [10]))
      _i(v, 10).clamp(1, 200),
  }.toList()
    ..sort();
  if (horizons.isEmpty) horizons.add(10);
  final maxH = horizons.last;
  // The engine is "confidently wrong" when the truth sits this many sigma away.
  // Development diagnostic only — not a production metric.
  final confSigma = _d(req['confSigma'], 3.0);
  final confMinErr = _d(req['confMinErr'], 0.75);

  final cells = <List<_SweepAcc>>[]; // [skill][engine]
  final context = <Map<String, dynamic>>[]; // [skill], engine-independent
  var starts = List<double>.filled(specs.length, 0);

  for (final trueSkill in skills) {
    final acc = [for (var i = 0; i < specs.length; i++) _SweepAcc(horizons.length)];
    var wins = 0.0, losses = 0.0, partner = 0.0, o1 = 0.0, o2 = 0.0;
    var teamStr = 0.0, oppStr = 0.0, ctxN = 0;

    for (var r = 0; r < reps; r++) {
      final seed = baseSeed + r * 101;
      final rng = Rng(seed * 7919 + 13);
      final s = StorySession(
        seed: seed,
        trueSkill: trueSkill,
        name: 'sweep',
        world: world,
        pool: makePool_(rng, trueSkill, 40, established),
        specs: specs,
        rng: rng,
      );
      _registerAll(s);
      for (var i = 0; i < specs.length; i++) {
        starts[i] = s.engines[s.keyOf(i)]!.estimate(0);
        acc[i].start = starts[i];
      }

      var hi = 0;
      for (var n = 1; n <= maxH; n++) {
        final played = _storyPlay(s, const {}, lean: true);
        final match = played['match'] as Map;
        // Match environment, counted over the placement window only — this is
        // what decides whether a weak player had winnable matches at all.
        if (n <= 10) {
          partner += ((match['partner'] as Map)['skill'] as num).toDouble();
          o1 += ((match['opp1'] as Map)['skill'] as num).toDouble();
          o2 += ((match['opp2'] as Map)['skill'] as num).toDouble();
          teamStr += world.teamStrength(
              trueSkill, ((match['partner'] as Map)['skill'] as num).toDouble());
          oppStr += world.teamStrength(
              ((match['opp1'] as Map)['skill'] as num).toDouble(),
              ((match['opp2'] as Map)['skill'] as num).toDouble());
          if (match['won'] == true) {
            wins++;
          } else {
            losses++;
          }
          ctxN++;
        }
        final per = (match['engines'] as List).cast<Map>();
        for (var i = 0; i < specs.length; i++) {
          // Calibration over the whole run: was the engine's stated win
          // probability honest? Pooled here rather than per horizon.
          final p = (per[i]['expectedA'] as num).toDouble();
          final outcome = match['won'] == true ? 1.0 : 0.0;
          acc[i].brierSum += (p - outcome) * (p - outcome);
          acc[i].brierN++;
          if (n <= 10) {
            acc[i].expSum += p;
            acc[i].expN++;
          }
        }
        if (hi < horizons.length && n == horizons[hi]) {
          for (var i = 0; i < specs.length; i++) {
            acc[i].rating[hi].add((per[i]['rating'] as num).toDouble());
            acc[i].sigma[hi].add((per[i]['sigma'] as num).toDouble());
            if (per[i]['displayReady'] == true) acc[i].shown[hi]++;
          }
          hi++;
        }
      }

      // Per-rep track statistics: half-life, overshoot, post-placement wobble.
      for (var i = 0; i < specs.length; i++) {
        final track = s.ratingTrack[s.keyOf(i)]!;
        final st = track.first;
        final need = trueSkill - st;
        final e0 = need.abs();
        if (e0 >= 0.5) {
          acc[i].misSeeded++;
          var got50 = false, got75 = false;
          for (var n = 1; n < track.length; n++) {
            final err = (track[n] - trueSkill).abs();
            if (!got50 && err <= 0.5 * e0) {
              acc[i].half50.add(n.toDouble());
              got50 = true;
            }
            if (!got75 && err <= 0.25 * e0) {
              acc[i].half75.add(n.toDouble());
              got75 = true;
              break;
            }
          }
          if (!got50) acc[i].never50++;
          if (!got75) acc[i].never75++;
          // How far PAST the truth it travelled, in the direction of travel.
          final dir = need >= 0 ? 1.0 : -1.0;
          var over = 0.0;
          for (final v in track) {
            final past = dir * (v - trueSkill);
            if (past > over) over = past;
          }
          acc[i].overshoot.add(over);
        }
        if (maxH > 10 && track.length > 11) {
          final tail = track.sublist(10);
          acc[i].wobble.add(sd(tail));
          acc[i].drift.add(track.last - track[10]);
        }
      }
    }

    cells.add(acc);
    context.add({
      'trueSkill': trueSkill,
      'wins': ctxN == 0 ? 0.0 : wins / reps,
      'losses': ctxN == 0 ? 0.0 : losses / reps,
      'partner': ctxN == 0 ? 0.0 : partner / ctxN,
      'opp1': ctxN == 0 ? 0.0 : o1 / ctxN,
      'opp2': ctxN == 0 ? 0.0 : o2 / ctxN,
      'teamStrength': ctxN == 0 ? 0.0 : teamStr / ctxN,
      'oppStrength': ctxN == 0 ? 0.0 : oppStr / ctxN,
    });
  }

  // ── per (skill, engine) rows ──
  final rows = <Map<String, dynamic>>[];
  for (var si = 0; si < skills.length; si++) {
    final trueSkill = skills[si];
    for (var i = 0; i < specs.length; i++) {
      final a = cells[si][i];
      final need = trueSkill - a.start;
      final at = <Map<String, dynamic>>[];
      for (var h = 0; h < horizons.length; h++) {
        final xs = a.rating[h], sg = a.sigma[h];
        final errs = [for (final v in xs) v - trueSkill];
        final abs = [for (final v in errs) v.abs()];
        final m = mean(xs);
        final meanSigma = mean(sg);
        var confWrong = 0;
        for (var k = 0; k < xs.length; k++) {
          final e = (xs[k] - trueSkill).abs();
          if (e >= confMinErr && sg[k] > 0 && e / sg[k] >= confSigma) confWrong++;
        }
        at.add({
          'matches': horizons[h],
          'mean': m,
          'median': median(xs),
          'p10': percentile(xs, 0.10),
          'p25': percentile(xs, 0.25),
          'p75': percentile(xs, 0.75),
          'p90': percentile(xs, 0.90),
          'error': m - trueSkill,
          'medianError': median(errs),
          'mae': mean(abs),
          'sd': xs.length > 1 ? sd(xs) : 0.0,
          'within25': xs.isEmpty ? 0.0 : abs.where((v) => v <= 0.25).length / xs.length,
          'within50': xs.isEmpty ? 0.0 : abs.where((v) => v <= 0.50).length / xs.length,
          'within75': xs.isEmpty ? 0.0 : abs.where((v) => v <= 0.75).length / xs.length,
          'within100': xs.isEmpty ? 0.0 : abs.where((v) => v <= 1.00).length / xs.length,
          'medAbsError': median(abs),
          // Same thresholds the study's `metrics.dart` uses, so "placed too
          // high / too low" means one thing across the whole project.
          'weakTooHigh': trueSkill <= 2.0 && xs.isNotEmpty
              ? xs.where((v) => v > 3.0).length / xs.length
              : null,
          'strongTooLow': trueSkill >= 5.0 && xs.isNotEmpty
              ? xs.where((v) => v < 3.5).length / xs.length
              : null,
          'sigma': meanSigma,
          'shown': xs.isEmpty ? 0.0 : a.shown[h] / xs.length,
          // |error| measured in sigmas: high means the engine is sure AND wrong.
          'confidenceError': meanSigma <= 0 ? 0.0 : mean(abs) / meanSigma,
          'confWrong': xs.isEmpty ? 0.0 : confWrong / xs.length,
          'movement': m - a.start,
          'required': need,
          // Signed on purpose: a variant that moved the WRONG way must not be
          // able to report positive recovery through an abs().
          'recovered': need.abs() < 0.25 ? null : (m - a.start) / need,
        });
      }
      rows.add({
        'trueSkill': trueSkill,
        'id': specs[i]['id'],
        'short': _shortOf(specs[i]['id'].toString()),
        'label': _labelFor(specs[i]['id'].toString()),
        'start': a.start,
        'required': need,
        'at': at,
        'half50': a.half50.isEmpty ? null : median(a.half50),
        'half75': a.half75.isEmpty ? null : median(a.half75),
        'never50': a.misSeeded == 0 ? 0.0 : a.never50 / a.misSeeded,
        'never75': a.misSeeded == 0 ? 0.0 : a.never75 / a.misSeeded,
        'overshoot': a.overshoot.isEmpty ? 0.0 : mean(a.overshoot),
        'overshootPct': a.overshoot.isEmpty
            ? 0.0
            : a.overshoot.where((v) => v > 0.5).length / a.overshoot.length,
        'wobble': a.wobble.isEmpty ? null : mean(a.wobble),
        'drift': a.drift.isEmpty ? null : mean(a.drift),
        'brier': a.brierN == 0 ? 0.0 : a.brierSum / a.brierN,
        'expected': a.expN == 0 ? 0.0 : a.expSum / a.expN,
      });
    }
  }

  // ── per-engine summary across the whole sweep, at each horizon ──
  final summary = <Map<String, dynamic>>[];
  for (var i = 0; i < specs.length; i++) {
    final mine = [for (var si = 0; si < skills.length; si++) rows[si * specs.length + i]];
    final start = (mine.first['start'] as num).toDouble();
    final perH = <Map<String, dynamic>>[];
    for (var h = 0; h < horizons.length; h++) {
      final est = [for (final r in mine) ((r['at'] as List)[h] as Map)['mean'] as double];
      final err = [for (final r in mine) ((r['at'] as List)[h] as Map)['error'] as double];
      final mae = [for (final r in mine) ((r['at'] as List)[h] as Map)['mae'] as double];
      final w50 = [for (final r in mine) ((r['at'] as List)[h] as Map)['within50'] as double];
      final w75 = [for (final r in mine) ((r['at'] as List)[h] as Map)['within75'] as double];
      final w100 = [for (final r in mine) ((r['at'] as List)[h] as Map)['within100'] as double];
      final medAbs = [for (final r in mine) ((r['at'] as List)[h] as Map)['medAbsError'] as double];
      final weakHigh = [
        for (final r in mine)
          if (((r['at'] as List)[h] as Map)['weakTooHigh'] != null)
            ((r['at'] as List)[h] as Map)['weakTooHigh'] as double,
      ];
      final strongLow = [
        for (final r in mine)
          if (((r['at'] as List)[h] as Map)['strongTooLow'] != null)
            ((r['at'] as List)[h] as Map)['strongTooLow'] as double,
      ];
      final cw = [for (final r in mine) ((r['at'] as List)[h] as Map)['confWrong'] as double];

      // Directional recovery, each side of THIS engine's own prior.
      //
      // DISTANCE-WEIGHTED (Σ moved ÷ Σ needed), not the mean of the per-skill
      // percentages. A plain mean is biased here: the skills either side of the
      // prior are not symmetric in how far they need to travel, so a row
      // needing 0.3 counts as much as one needing 2.8 and the tiny-distance
      // rows — which are the noisiest — decide the answer.
      var downMoved = 0.0, downNeed = 0.0, upMoved = 0.0, upNeed = 0.0;
      // Matched-distance pairs: the only comparison that isolates DIRECTION.
      final below = <int>[], above = <int>[];
      for (var si = 0; si < skills.length; si++) {
        final cell = (mine[si]['at'] as List)[h] as Map;
        if (cell['recovered'] == null) continue;
        final moved = cell['movement'] as double;
        final need = cell['required'] as double;
        if (skills[si] < start) {
          downMoved += moved;
          downNeed += need;
          below.add(si);
        } else {
          upMoved += moved;
          upNeed += need;
          above.add(si);
        }
      }
      final pairs = <Map<String, dynamic>>[];
      for (final b in below) {
        final needB = (((mine[b]['at'] as List)[h] as Map)['required'] as double).abs();
        int? best;
        var bestGap = double.infinity;
        for (final a in above) {
          final needA = (((mine[a]['at'] as List)[h] as Map)['required'] as double).abs();
          final gap = (needA - needB).abs();
          if (gap < bestGap) {
            bestGap = gap;
            best = a;
          }
        }
        if (best == null || bestGap > 0.35) continue;
        pairs.add({
          'distance': needB,
          'downSkill': skills[b],
          'downRecovered': ((mine[b]['at'] as List)[h] as Map)['recovered'],
          'upSkill': skills[best],
          'upRecovered': ((mine[best]['at'] as List)[h] as Map)['recovered'],
          'upDistance': (((mine[best]['at'] as List)[h] as Map)['required'] as double).abs(),
        });
      }

      // Compression: how much of the population's real spread survives, and
      // which way the bias tilts across the skill range.
      final spread = sd(skills) <= 0 ? 0.0 : sd(est) / sd(skills);
      final mx = mean(skills), my = mean(err);
      var num_ = 0.0, den = 0.0;
      for (var si = 0; si < skills.length; si++) {
        num_ += (skills[si] - mx) * (err[si] - my);
        den += (skills[si] - mx) * (skills[si] - mx);
      }
      perH.add({
        'matches': horizons[h],
        'mae': mean(mae),
        'bias': mean(err),
        'maxAbsBias': err.map((v) => v.abs()).reduce(math.max),
        'biasSlope': den == 0 ? 0.0 : num_ / den,
        'spreadRecovery': spread,
        'within50': mean(w50),
        'within75': mean(w75),
        'within100': mean(w100),
        'medAbsError': mean(medAbs),
        'weakTooHigh': weakHigh.isEmpty ? null : mean(weakHigh),
        'strongTooLow': strongLow.isEmpty ? null : mean(strongLow),
        'confWrong': mean(cw),
        'downRecovery': downNeed == 0 ? null : downMoved / downNeed,
        'upRecovery': upNeed == 0 ? null : upMoved / upNeed,
        'asymmetry': downNeed == 0 || upNeed == 0
            ? null
            : (upMoved / upNeed) - (downMoved / downNeed),
        'pairs': pairs,
      });
    }
    summary.add({
      'id': specs[i]['id'],
      'short': _shortOf(specs[i]['id'].toString()),
      'label': _labelFor(specs[i]['id'].toString()),
      'start': start,
      'at': perH,
      'brier': mean([for (final r in mine) r['brier'] as double]),
      'overshoot': mean([for (final r in mine) r['overshoot'] as double]),
      'overshootPct': mean([for (final r in mine) r['overshootPct'] as double]),
      'wobble': mine.first['wobble'] == null
          ? null
          : mean([for (final r in mine) (r['wobble'] as num).toDouble()]),
      'drift': mine.first['drift'] == null
          ? null
          : mean([for (final r in mine) (r['drift'] as num).toDouble()]),
    });
  }

  return {
    'seed': baseSeed,
    'reps': reps,
    'pool': established ? 'established' : 'fresh',
    'world': world.name,
    'skills': skills,
    'horizons': horizons,
    'engines': [
      for (var i = 0; i < specs.length; i++)
        {
          'id': specs[i]['id'],
          'short': _shortOf(specs[i]['id'].toString()),
          'label': _labelFor(specs[i]['id'].toString()),
        },
    ],
    'context': context,
    'rows': rows,
    'summary': summary,
  };
}

double round2_(double v) => (v * 100).round() / 100;

// ─────────────────────────────────────────────────────────────────────────────
// Population session
// ─────────────────────────────────────────────────────────────────────────────

class PopEngine {
  final String id, key, label;
  final RankingEngine engine;
  final List<List<double>> rating; // [player][round]
  final List<List<double>> sigma;
  final List<int> wins, losses;
  final List<Set<int>> partners;
  final Calibration calib = Calibration();
  PopEngine(this.id, this.key, this.label, this.engine, int n)
      : rating = List.generate(n, (_) => <double>[]),
        sigma = List.generate(n, (_) => <double>[]),
        wins = List<int>.filled(n, 0),
        losses = List<int>.filled(n, 0),
        partners = List.generate(n, (_) => <int>{});
}

class PopSession {
  final int seed, n, rounds;
  final MatchStream stream;
  final List<PopEngine> engines;
  PopSession(this.seed, this.n, this.rounds, this.stream, this.engines);
}

PopSession? _pop;

Map<String, dynamic> _popRun(Map<String, dynamic> req) {
  final seed = _i(req['seed'], 482901);
  final n = _i(req['players'], 200).clamp(8, 4000);
  final rounds = _i(req['matches'], 20).clamp(1, 120);
  final specs = _engineSpecs(req['engines']);
  final dist = req['dist']?.toString() ?? 'bell';

  final spec = StreamSpec(
    nPlayers: n,
    rounds: rounds,
    world: _world(req['world']),
    dist: dist == 'uniform' ? SkillDist.uniform : SkillDist.bell,
    cluster: _d(req['cluster'], 0.55),
    askOnboarding: _b(req['askOnboarding'], false),
    honesty: _d(req['honesty'], 0.7),
    sandbagRate: _d(req['sandbagRate'], 0.0),
    inflateRate: _d(req['inflateRate'], 0.0),
  );
  final stream = buildStream(seed, spec);

  final pes = <PopEngine>[];
  for (var i = 0; i < specs.length; i++) {
    final e = buildEngine(specs[i]);
    for (final p in stream.players) {
      e.register(p.id, declared: p.declared);
    }
    pes.add(PopEngine(
        specs[i]['id'].toString(), '${specs[i]['id']}#$i',
        _labelFor(specs[i]['id'].toString()), e, n));
  }

  // Score predictions over the SECOND HALF of the run: the first matches say
  // more about the prior than about the engine. A fixed cut-off of 10 collected
  // nothing at all on a 10-match run, which read as perfect calibration.
  final calibFrom = stream.roundCount ~/ 2;

  for (var r = 0; r < stream.roundCount; r++) {
    for (final pe in pes) {
      for (final m in stream.rounds[r]) {
        if (r >= calibFrom) pe.calib.add(pe.engine.predictA(m), m.aWon);
        pe.engine.update(m);
        for (final id in m.all) {
          final onA = m.teamA.contains(id);
          if (onA == m.aWon) {
            pe.wins[id]++;
          } else {
            pe.losses[id]++;
          }
        }
        pe.partners[m.a1].add(m.a2);
        pe.partners[m.a2].add(m.a1);
        pe.partners[m.b1].add(m.b2);
        pe.partners[m.b2].add(m.b1);
      }
      for (var i = 0; i < n; i++) {
        pe.rating[i].add(pe.engine.estimate(i));
        pe.sigma[i].add(pe.engine.sigmaOf(i));
      }
    }
  }

  _pop = PopSession(seed, n, rounds, stream, pes);

  final truth = [for (final p in stream.players) p.baselineSkill];
  return {
    'seed': seed,
    'players': n,
    'rounds': rounds,
    'trueMean': mean(truth),
    'trueSd': sd(truth),
    'engines': [
      for (final pe in pes)
        {
          'key': pe.key,
          'id': pe.id,
          'short': _shortOf(pe.id),
          'label': pe.label,
        },
    ],
    'snapshots': _popSnapshots(_pop!, req['snapAt']),
  };
}

List<Map<String, dynamic>> _popSnapshots(PopSession s, Object? snapAt) {
  final ks = <int>[];
  if (snapAt is List) {
    for (final v in snapAt) {
      final k = _i(v, 0);
      if (k >= 1 && k <= s.rounds) ks.add(k);
    }
  }
  if (ks.isEmpty) {
    for (final k in const [1, 3, 5, 10, 20, 50, 100]) {
      if (k <= s.rounds) ks.add(k);
    }
    if (!ks.contains(s.rounds)) ks.add(s.rounds);
  }
  final rng = Rng(999);
  return [
    for (final pe in s.engines)
      {
        'key': pe.key,
        'at': ks,
        'rows': [
          for (final k in ks)
            () {
              final est = [for (var i = 0; i < s.n; i++) pe.rating[i][k - 1]];
              final snap = snapshot(k, est, s.stream.truthByRound[k - 1], rng);
              return {
                'at': k,
                ...snap.toJson(),
                'displayReadyPct': 100 *
                    [for (var i = 0; i < s.n; i++) i]
                        .where((i) => pe.sigma[i][k - 1] <= 0.60 && k >= 10)
                        .length /
                    s.n,
              };
            }(),
        ],
        'calibration': {
          'ece': pe.calib.ece,
          'brier': pe.calib.meanBrier,
          'logLoss': pe.calib.meanLogLoss,
          'accuracy': pe.calib.accuracy,
          'bins': [
            for (final (pred, obs, n) in pe.calib.curve)
              {'predicted': pred, 'observed': obs, 'n': n},
          ],
        },
      },
  ];
}

/// Scatter / histogram / table for one engine at one match count.
Map<String, dynamic> _popAt(Map<String, dynamic> req) {
  final s = _pop;
  if (s == null) return {'error': 'Generate a population first.'};
  final k = _i(req['at'], s.rounds).clamp(1, s.rounds);
  final key = req['key']?.toString();
  final pe = s.engines.firstWhere((e) => e.key == key, orElse: () => s.engines.first);

  final truth = s.stream.truthByRound[k - 1];
  final est = [for (var i = 0; i < s.n; i++) pe.rating[i][k - 1]];
  final snap = snapshot(k, est, truth, Rng(999));

  // scatter is capped so a 4,000-player run does not ship 4,000 SVG circles
  final step = (s.n / 900).ceil();
  final pts = <List<double>>[];
  for (var i = 0; i < s.n; i += step) {
    pts.add([truth[i], est[i], i.toDouble()]);
  }

  List<double> hist(List<double> xs) {
    final bins = List<double>.filled(29, 0);
    for (final x in xs) {
      final b = ((x - 0.0) / 0.25).floor().clamp(0, 28);
      bins[b] += 1;
    }
    return [for (final b in bins) 100 * b / xs.length];
  }

  return {
    'at': k,
    'key': pe.key,
    'label': pe.label,
    'metrics': snap.toJson(),
    'scatter': pts,
    'histTrue': hist(truth),
    'histEst': hist(est),
    'estMean': mean(est),
    'estSd': sd(est),
    'trueMean': mean(truth),
    'trueSd': sd(truth),
  };
}

Map<String, dynamic> _popPlayer(Map<String, dynamic> req) {
  final s = _pop;
  if (s == null) return {'error': 'Generate a population first.'};
  final id = _i(req['id'], 0).clamp(0, s.n - 1);
  final p = s.stream.players[id];
  return {
    'id': id,
    'trueSkill': p.trueSkill,
    'baselineSkill': p.baselineSkill,
    'declared': _declaredName(p.declared),
    'rounds': s.rounds,
    'engines': [
      for (final pe in s.engines)
        {
          'key': pe.key,
          'short': _shortOf(pe.id),
          'label': pe.label,
          'rating': pe.rating[id],
          'sigma': pe.sigma[id],
          'final': pe.rating[id].last,
          'error': pe.rating[id].last - p.trueSkill,
          'wins': pe.wins[id],
          'losses': pe.losses[id],
          'partners': pe.partners[id].length,
          'displayReady': pe.engine.displayReady(id),
          'publicRating': pe.engine.publicRating(id),
        },
    ],
  };
}

/// The "inspect an individual, not an average" table — worst/best/random picks.
Map<String, dynamic> _popPlayers(Map<String, dynamic> req) {
  final s = _pop;
  if (s == null) return {'error': 'Generate a population first.'};
  final k = _i(req['at'], s.rounds).clamp(1, s.rounds);
  final sort = req['sort']?.toString() ?? 'worst';
  final pe = s.engines.firstWhere((e) => e.key == req['key']?.toString(),
      orElse: () => s.engines.first);
  final truth = s.stream.truthByRound[k - 1];

  final idx = [for (var i = 0; i < s.n; i++) i];
  double err(int i) => pe.rating[i][k - 1] - truth[i];
  switch (sort) {
    case 'worst':
      idx.sort((a, b) => err(b).abs().compareTo(err(a).abs()));
    case 'under':
      idx.sort((a, b) => err(a).compareTo(err(b)));
    case 'over':
      idx.sort((a, b) => err(b).compareTo(err(a)));
    case 'strong':
      idx.sort((a, b) => truth[b].compareTo(truth[a]));
    case 'weak':
      idx.sort((a, b) => truth[a].compareTo(truth[b]));
  }
  final take = idx.take(_i(req['limit'], 25)).toList();
  return {
    'at': k,
    'rows': [
      for (final i in take)
        {
          'id': i,
          'trueSkill': truth[i],
          'engines': [
            for (final e in s.engines)
              {
                'short': _shortOf(e.id),
                'rating': e.rating[i][k - 1],
                'error': e.rating[i][k - 1] - truth[i],
                'sigma': e.sigma[i][k - 1],
              },
          ],
        },
    ],
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Parameter sweeps
// ─────────────────────────────────────────────────────────────────────────────

Map<String, dynamic> _sweep(Map<String, dynamic> req) {
  final what = req['param']?.toString() ?? 'prior';
  final seeds = _i(req['seeds'], 3).clamp(1, 25);
  final baseSeed = _i(req['seed'], 100);
  final n = _i(req['players'], 200).clamp(8, 2000);
  final rounds = _i(req['matches'], 10).clamp(1, 60);
  final values = (req['values'] as List?) ?? const [];
  final baseSpec = (req['engine'] as Map?)?.cast<String, dynamic>() ?? {'id': 'v3'};

  final rows = <Map<String, dynamic>>[];
  for (final v in values) {
    final cfg = <String, dynamic>{...((baseSpec['cfg'] as Map?) ?? {}).cast<String, dynamic>()};
    switch (what) {
      case 'prior':
        cfg['prior'] = _d(v, 3.3);
      case 'placementK':
        cfg['stageK'] = v is List ? v : [_d(v, 0.8), _d(v, 0.8) * 0.625, _d(v, 0.8) * 0.375];
      case 'reliability':
        cfg['placementRelFloor'] = _d(v, 1.0);
      case 'relRamp':
        cfg['relRampMatches'] = _i(v, 0);
      case 'margin':
        // v = [resultWeight, marginCap]
        if (v is List && v.length >= 2) {
          cfg['resultWeight'] = _d(v[0], 0.85);
          cfg['marginCap'] = _d(v[1], 0.5);
        }
      case 'curve':
        cfg['curveScale'] = _d(v, 1.0);
      case 'lambda':
        cfg['lambdaImbalance'] = _d(v, 0.0);
      case 'sigmaDecay':
        cfg['sigmaDecay'] = _d(v, 0.92);
    }

    final maes = <double>[], spreads = <double>[], biases = <double>[];
    final strongLow = <double>[], weakHigh = <double>[], eces = <double>[];
    final spear = <double>[];
    for (var s = 0; s < seeds; s++) {
      final stream = buildStream(
          baseSeed + s,
          StreamSpec(
              nPlayers: n, rounds: rounds, world: _world(req['world']), cluster: 0.55));
      final e = buildEngine({...baseSpec, 'cfg': cfg});
      for (final p in stream.players) {
        e.register(p.id);
      }
      final calib = Calibration();
      for (var r = 0; r < stream.roundCount; r++) {
        for (final m in stream.rounds[r]) {
          if (r >= rounds ~/ 2) calib.add(e.predictA(m), m.aWon);
          e.update(m);
        }
      }
      final est = [for (var i = 0; i < stream.n; i++) e.estimate(i)];
      final snap = snapshot(rounds, est, stream.truthByRound.last, Rng(999));
      maes.add(snap.mae);
      spreads.add(snap.spreadRecovery);
      biases.add(snap.bias);
      strongLow.add(snap.pctStrongStuckLow);
      weakHigh.add(snap.pctWeakStuckHigh);
      spear.add(snap.spearman);
      eces.add(calib.ece);
    }
    rows.add({
      'value': v,
      'mae': mean(maes),
      'spreadRecovery': mean(spreads),
      'bias': mean(biases),
      'pctStrongStuckLow': mean(strongLow),
      'pctWeakStuckHigh': mean(weakHigh),
      'spearman': mean(spear),
      'ece': mean(eces),
    });
  }
  return {'param': what, 'seeds': seeds, 'players': n, 'matches': rounds, 'rows': rows};
}

// ─────────────────────────────────────────────────────────────────────────────
// Doubles / boosting / partner / sigma / inactivity experiments
// ─────────────────────────────────────────────────────────────────────────────

Map<String, dynamic> _doublesPairs(Map<String, dynamic> req) {
  final lambda = _d(req['lambda'], 0.20);
  final world = _world(req['world']);
  final pairs = (req['pairs'] as List?) ??
      const [
        [3.5, 3.5, 3.5, 3.5],
        [5.0, 2.0, 3.5, 3.5],
        [6.0, 1.0, 4.0, 3.0],
        [4.5, 2.5, 3.5, 3.5],
        [5.5, 3.5, 4.5, 4.5],
      ];
  final rng = Rng(_i(req['seed'], 4242));

  final rows = <Map<String, dynamic>>[];
  for (final p in pairs) {
    final a1 = _d((p as List)[0], 3.5), a2 = _d(p[1], 3.5);
    final b1 = _d(p[2], 3.5), b2 = _d(p[3], 3.5);

    // Ground truth: play it out many times rather than trusting a formula.
    var wins = 0;
    const trials = 4000;
    final eff = [a1, a2, b1, b2];
    for (var t = 0; t < trials; t++) {
      if (world.play(rng, 0, 1, 2, 3, eff).aWon) wins++;
    }
    final gapA = (a1 - a2).abs(), gapB = (b1 - b2).abs();
    double model(String kind, double x, double y) {
      final avg = (x + y) / 2, gap = (x - y).abs();
      return switch (kind) {
        'avg' => avg,
        'lambda' => avg - lambda * gap,
        'weakLink' => avg - 0.5 * gap,
        'carry' => avg + 0.2 * gap,
        'max' => x > y ? x : y,
        _ => avg,
      };
    }

    rows.add({
      'pair': [a1, a2, b1, b2],
      'gapA': gapA,
      'gapB': gapB,
      'trueWinPct': 100 * wins / trials,
      'trueStrengthA': world.teamStrength(a1, a2),
      'trueStrengthB': world.teamStrength(b1, b2),
      'models': {
        for (final k in const ['avg', 'lambda', 'weakLink', 'carry', 'max'])
          k: {
            'a': model(k, a1, a2),
            'b': model(k, b1, b2),
            'diff': model(k, a1, a2) - model(k, b1, b2),
          },
      },
    });
  }
  return {'lambda': lambda, 'world': world.name, 'rows': rows};
}

Map<String, dynamic> _boost(Map<String, dynamic> req) {
  final weak = _d(req['weakSkill'], 2.5);
  final strong = _d(req['partnerSkill'], 5.0);
  final matches = _i(req['matches'], 30).clamp(4, 200);
  final specs = _engineSpecs(req['engines']);
  final seed = _i(req['seed'], 482901);
  final gapLimit = req['gapLimit'] == null ? null : _d(req['gapLimit'], 99);

  final out = <Map<String, dynamic>>[];
  for (final spec in specs) {
    final fixed = buildEngine(spec);
    final control = buildEngine(spec);
    final a = scriptedPartnerRun(fixed, seed,
        poolSize: 220,
        burnIn: 14,
        phases: [('fixed', matches, strong)],
        probeSkills: [weak],
        forcedPartnerGapLimit: gapLimit);
    final b = scriptedPartnerRun(control, seed,
        poolSize: 220, burnIn: 14, phases: [('random', matches, null)], probeSkills: [weak]);
    final withStrong = a.estByPhase['fixed']!.first;
    final withRandom = b.estByPhase['random']!.first;
    out.add({
      'id': spec['id'],
      'short': _shortOf(spec['id'].toString()),
      'label': _labelFor(spec['id'].toString()),
      'trueSkill': weak,
      'withStrongPartner': withStrong,
      'withRandomPartners': withRandom,
      'inflation': withStrong - withRandom,
      'errorFixed': withStrong - weak,
      'errorControl': withRandom - weak,
      'sigmaFixed': a.sigmaByPhase['fixed']!.first,
      'sigmaControl': b.sigmaByPhase['random']!.first,
    });
  }
  return {
    'weakSkill': weak,
    'partnerSkill': strong,
    'matches': matches,
    'gapLimit': gapLimit,
    'rows': out,
  };
}

Map<String, dynamic> _partnerPhases(Map<String, dynamic> req) {
  final skill = _d(req['trueSkill'], 3.5);
  final per = _i(req['matches'], 20).clamp(4, 120);
  final strong = _d(req['strongPartner'], 5.0);
  final weak = _d(req['weakPartner'], 2.0);
  final specs = _engineSpecs(req['engines']);
  final seed = _i(req['seed'], 482901);

  return {
    'trueSkill': skill,
    'phases': ['with $strong', 'with $weak', 'random partners'],
    'rows': [
      for (final spec in specs)
        () {
          final e = buildEngine(spec);
          final r = scriptedPartnerRun(e, seed,
              poolSize: 220,
              burnIn: 14,
              phases: [('strong', per, strong), ('weak', per, weak), ('random', per, null)],
              probeSkills: [skill]);
          return {
            'id': spec['id'],
            'short': _shortOf(spec['id'].toString()),
            'label': _labelFor(spec['id'].toString()),
            'strong': r.estByPhase['strong']!.first,
            'weak': r.estByPhase['weak']!.first,
            'random': r.estByPhase['random']!.first,
            'independenceError':
                (r.estByPhase['strong']!.first - r.estByPhase['weak']!.first).abs(),
          };
        }(),
    ],
  };
}

/// Skill genuinely changes mid-career: does the engine notice, and does sigma
/// behave sensibly while it is being proven wrong?
Map<String, dynamic> _skillShift(Map<String, dynamic> req) {
  final before = _d(req['from'], 5.0);
  final after = _d(req['to'], 3.0);
  final pre = _i(req['preMatches'], 25).clamp(4, 200);
  final post = _i(req['postMatches'], 30).clamp(4, 200);
  final specs = _engineSpecs(req['engines']);
  final seed = _i(req['seed'], 482901);

  final rows = <Map<String, dynamic>>[];
  for (final spec in specs) {
    final rng = Rng(seed * 7919 + 13);
    final s = StorySession(
      seed: seed,
      trueSkill: before,
      name: 'shift',
      world: _world(req['world']),
      pool: makePool_(rng, before, 40, true),
      specs: [spec],
      rng: rng,
    );
    _registerAll(s);
    for (var i = 0; i < pre; i++) {
      _storyPlay(s, const {});
    }
    final atShift = s.engines[s.keyOf(0)]!.estimate(0);
    final sigmaAtShift = s.engines[s.keyOf(0)]!.sigmaOf(0);

    // the player's true level changes; the pool does not
    final s2 = StorySession(
      seed: seed,
      trueSkill: after,
      name: 'shift',
      world: s.world,
      pool: s.pool,
      specs: [spec],
      rng: s.rng,
    );
    s2.engines.addAll(s.engines);
    s2.ratingTrack.addAll(s.ratingTrack);
    s2.sigmaTrack.addAll(s.sigmaTrack);
    for (var i = 0; i < post; i++) {
      _storyPlay(s2, const {});
    }
    final e = s.engines[s.keyOf(0)]!;
    rows.add({
      'id': spec['id'],
      'short': _shortOf(spec['id'].toString()),
      'label': _labelFor(spec['id'].toString()),
      'ratings': s2.ratingTrack[s.keyOf(0)],
      'sigmas': s2.sigmaTrack[s.keyOf(0)],
      'atShift': atShift,
      'sigmaAtShift': sigmaAtShift,
      'finalRating': e.estimate(0),
      'finalSigma': e.sigmaOf(0),
      'residualError': e.estimate(0) - after,
      'shiftAt': pre,
    });
  }
  return {'from': before, 'to': after, 'preMatches': pre, 'postMatches': post, 'rows': rows};
}

Map<String, dynamic> _inactivity(Map<String, dynamic> req) {
  final days = _i(req['days'], 90);
  final weeks = (days / 7).round();
  final returnSkill = _d(req['returnSkill'], 5.0);
  final settle = _d(req['settledAt'], 5.0);
  final after = _i(req['matchesAfter'], 15).clamp(1, 120);
  final specs = _engineSpecs(req['engines']);
  final seed = _i(req['seed'], 482901);

  final rows = <Map<String, dynamic>>[];
  for (final spec in specs) {
    final rng = Rng(seed * 7919 + 13);
    final s = StorySession(
      seed: seed,
      trueSkill: settle,
      name: 'idle',
      world: _world(req['world']),
      pool: makePool_(rng, settle, 40, true),
      specs: [spec],
      rng: rng,
    );
    _registerAll(s);
    for (var i = 0; i < 25; i++) {
      _storyPlay(s, const {});
    }
    final e = s.engines[s.keyOf(0)]!;
    final beforeIdle = e.estimate(0), sigBefore = e.sigmaOf(0);
    e.idle(0, weeks);
    final afterIdle = e.estimate(0), sigAfter = e.sigmaOf(0);

    final s2 = StorySession(
      seed: seed,
      trueSkill: returnSkill,
      name: 'idle',
      world: s.world,
      pool: s.pool,
      specs: [spec],
      rng: s.rng,
    );
    s2.engines.addAll(s.engines);
    s2.ratingTrack.addAll(s.ratingTrack);
    s2.sigmaTrack.addAll(s.sigmaTrack);
    for (var i = 0; i < after; i++) {
      _storyPlay(s2, const {});
    }
    rows.add({
      'id': spec['id'],
      'short': _shortOf(spec['id'].toString()),
      'label': _labelFor(spec['id'].toString()),
      'beforeIdle': beforeIdle,
      'afterIdle': afterIdle,
      'lostToDecay': beforeIdle - afterIdle,
      'sigmaBefore': sigBefore,
      'sigmaAfter': sigAfter,
      'ratings': s2.ratingTrack[s.keyOf(0)],
      'sigmas': s2.sigmaTrack[s.keyOf(0)],
      'idleAt': 25,
      'finalRating': e.estimate(0),
      'residualError': e.estimate(0) - returnSkill,
      'recoveryMatches': () {
        final track = s2.ratingTrack[s.keyOf(0)]!;
        for (var i = 26; i < track.length; i++) {
          if ((track[i] - returnSkill).abs() <= 0.25) return i - 25;
        }
        return -1;
      }(),
    });
  }
  return {
    'days': days,
    'weeks': weeks,
    'settledAt': settle,
    'returnSkill': returnSkill,
    'rows': rows,
  };
}

/// Same four players, two different scorelines — how much does the margin move?
Map<String, dynamic> _scoreCompare(Map<String, dynamic> req) {
  final specs = _engineSpecs(req['engines']);
  final a1 = _d(req['a1'], 3.5), a2 = _d(req['a2'], 3.5);
  final b1 = _d(req['b1'], 3.5), b2 = _d(req['b2'], 3.5);
  final scores = (req['scores'] as List?)?.map((e) => e.toString()).toList() ??
      ['7-6,7-6', '6-4,6-4', '6-0,6-0'];
  // Both scorelines are applied to the SAME fresh state, so the only thing that
  // differs between the rows is the margin. Sigma is the knob that matters here
  // — it sets K — and it is exposed rather than a match counter.
  final startSigma = _d(req['sigma'], 0.45);

  final rows = <Map<String, dynamic>>[];
  for (final spec in specs) {
    final per = <Map<String, dynamic>>[];
    for (final sc in scores) {
      final p = parseScore(sc);
      if (p['error'] != null) {
        per.add({'score': sc, 'error': p['error']});
        continue;
      }
      // Everyone but the focus player is a pinned reference player, so the only
      // thing that differs between the two scorelines is the margin itself.
      final fresh = buildEngine(spec);
      for (var i = 0; i < 4; i++) {
        fresh.register(i);
      }
      for (var i = 1; i < 4; i++) {
        fresh.markAnchor(i, [a1, a2, b1, b2][i], startSigma);
      }
      // markAnchor would also pin the focus player's movement, so place them
      // with seed() and give them a matches count via the anchor-free path.
      fresh.seed(0, a1, startSigma);
      final buf = <MoveTrace>[];
      fresh.trace = buf;
      fresh.update(MatchObs(
        a1: 0,
        a2: 1,
        b1: 2,
        b2: 3,
        gamesA: p['gamesA'] as int,
        gamesB: p['gamesB'] as int,
        sets: (p['sets'] as List).cast<List<int>>(),
        aWon: p['aWon'] as bool,
      ));
      fresh.trace = null;
      final t = buf.firstWhere((x) => x.id == 0);
      per.add({'score': sc, 'won': t.won, ...t.toJson()});
    }
    rows.add({
      'id': spec['id'],
      'short': _shortOf(spec['id'].toString()),
      'label': _labelFor(spec['id'].toString()),
      'scores': per,
    });
  }
  return {
    'players': [a1, a2, b1, b2],
    'sigma': startSigma,
    'rows': rows,
  };
}

/// Onboarding self-declaration as a weak prior.
Map<String, dynamic> _declaration(Map<String, dynamic> req) {
  final seeds = _i(req['seeds'], 3).clamp(1, 20);
  final n = _i(req['players'], 300).clamp(8, 2000);
  final rounds = _i(req['matches'], 10).clamp(1, 60);
  final arms = <Map<String, dynamic>>[
    {'label': 'Flat prior 3.3', 'cfg': {'useDeclaredPrior': false}, 'honesty': 1.0},
    {
      'label': 'Declared, honest',
      'cfg': {'useDeclaredPrior': true},
      'honesty': 1.0,
    },
    {
      'label': 'Declared, 70% honest',
      'cfg': {'useDeclaredPrior': true},
      'honesty': 0.7,
    },
    {
      'label': 'Declared, 15% sandbag',
      'cfg': {'useDeclaredPrior': true},
      'honesty': 0.7,
      'sandbag': 0.15,
    },
    {
      'label': 'Declared, 15% inflate',
      'cfg': {'useDeclaredPrior': true},
      'honesty': 0.7,
      'inflate': 0.15,
    },
  ];
  final at = [1, 3, 5, 10, 20, 50].where((k) => k <= rounds).toList();

  return {
    'at': at,
    'rows': [
      for (final arm in arms)
        () {
          final byK = {for (final k in at) k: <double>[]};
          for (var s = 0; s < seeds; s++) {
            final stream = buildStream(
                600 + s,
                StreamSpec(
                  nPlayers: n,
                  rounds: rounds,
                  askOnboarding: true,
                  honesty: _d(arm['honesty'], 0.7),
                  sandbagRate: _d(arm['sandbag'], 0.0),
                  inflateRate: _d(arm['inflate'], 0.0),
                ));
            final e = buildEngine({
              'id': req['engine']?.toString() ?? 'v3',
              'cfg': arm['cfg'],
            });
            for (final p in stream.players) {
              e.register(p.id, declared: p.declared);
            }
            for (var r = 0; r < stream.roundCount; r++) {
              for (final m in stream.rounds[r]) {
                e.update(m);
              }
              final k = r + 1;
              if (byK.containsKey(k)) {
                final est = [for (var i = 0; i < stream.n; i++) e.estimate(i)];
                byK[k]!.add(snapshot(k, est, stream.truthByRound[r], Rng(999)).mae);
              }
            }
          }
          return {
            'label': arm['label'],
            'mae': [for (final k in at) mean(byK[k]!)],
          };
        }(),
    ],
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Replaying REAL match history
//
// The study's main limitation is that it has to guess how decisive a level gap
// really is. Feeding actual (anonymised) production matches through the same
// engines removes the guess entirely, so this path exists from day one.
//
// There is no ground truth in real data — nobody knows a player's "true" level —
// so the truth-based metrics are meaningless here and are NOT reported. What
// can be measured honestly is prediction: before each match, ask the engine who
// wins, then score it against what actually happened. An engine that describes
// these players well predicts them well.
// ─────────────────────────────────────────────────────────────────────────────

/// [req] = {players: [id…], matches: [{a: [id,id], b: [id,id], score: '6-4,6-3'}
/// …], engines: […], warmup: n}. Matches must be in chronological order.
Map<String, dynamic> _replay(Map<String, dynamic> req) {
  final rawPlayers = (req['players'] as List?) ?? const [];
  final rawMatches = (req['matches'] as List?) ?? const [];
  if (rawMatches.isEmpty) return {'error': 'No matches to replay.'};

  // Map arbitrary external ids (uuids, names) onto the dense ints the engines
  // index by, without ever needing to know what they originally were.
  final index = <String, int>{};
  int idOf(Object? raw) => index.putIfAbsent(raw.toString(), () => index.length);
  for (final p in rawPlayers) {
    idOf(p is Map ? p['id'] : p);
  }

  final parsed = <MatchObs>[];
  for (var i = 0; i < rawMatches.length; i++) {
    final m = rawMatches[i];
    if (m is! Map) return {'error': 'Match $i is not an object.'};
    final a = (m['a'] as List?) ?? const [];
    final b = (m['b'] as List?) ?? const [];
    if (a.length < 2 || b.length < 2) {
      return {'error': 'Match $i needs two players on each side.'};
    }
    int ga, gb;
    bool aWon;
    List<List<int>> sets;
    if (m['score'] != null) {
      final p = parseScore(m['score'].toString());
      if (p['error'] != null) return {'error': 'Match $i: ${p['error']}'};
      ga = p['gamesA'] as int;
      gb = p['gamesB'] as int;
      aWon = p['aWon'] as bool;
      sets = (p['sets'] as List).cast<List<int>>();
    } else {
      ga = _i(m['gamesA'], 0);
      gb = _i(m['gamesB'], 0);
      aWon = _b(m['aWon'], ga > gb);
      sets = const [];
    }
    parsed.add(MatchObs(
      a1: idOf(a[0]),
      a2: idOf(a[1]),
      b1: idOf(b[0]),
      b2: idOf(b[1]),
      gamesA: ga,
      gamesB: gb,
      sets: sets,
      aWon: aWon,
    ));
  }

  final warmup = _i(req['warmup'], (parsed.length * 0.3).round());
  final specs = _engineSpecs(req['engines']);
  final rows = <Map<String, dynamic>>[];

  for (final spec in specs) {
    final e = buildEngine(spec);
    for (var i = 0; i < index.length; i++) {
      e.register(i);
    }
    final calib = Calibration();
    for (var i = 0; i < parsed.length; i++) {
      // Scored BEFORE the update, so every prediction is genuinely out of
      // sample — the engine has not yet seen the match it is predicting.
      if (i >= warmup) calib.add(e.predictA(parsed[i]), parsed[i].aWon);
      e.update(parsed[i]);
    }
    final finals = [for (var i = 0; i < index.length; i++) e.estimate(i)];
    rows.add({
      'id': spec['id'],
      'short': _shortOf(spec['id'].toString()),
      'label': _labelFor(spec['id'].toString()),
      'accuracy': calib.accuracy,
      'brier': calib.meanBrier,
      'logLoss': calib.meanLogLoss,
      'ece': calib.ece,
      'scored': calib.total,
      'ratingMean': mean(finals),
      'ratingSd': sd(finals),
      'ratings': {
        for (final entry in index.entries) entry.key: e.estimate(entry.value),
      },
      'displayReady': 100 *
          [for (var i = 0; i < index.length; i++) i]
              .where((i) => e.displayReady(i))
              .length /
          index.length,
    });
  }

  return {
    'players': index.length,
    'matches': parsed.length,
    'warmup': warmup,
    'scored': parsed.length - warmup,
    'rows': rows,
    'note': 'Real history has no ground truth, so accuracy against the actual '
        'results is the measure here, not error against a true skill.',
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Dispatcher
// ─────────────────────────────────────────────────────────────────────────────

Map<String, dynamic> dispatch(Map<String, dynamic> req) {
  final op = req['op']?.toString() ?? '';
  switch (op) {
    case 'meta':
      return {
        'engines': kEngineCatalog,
        'worlds': [
          {'id': 'D', 'label': worldD.name, 'note': '1 level ≈ 87% — the primary world'},
          {'id': 'D-flat', 'label': worldDFlat.name, 'note': '1 level ≈ 78%'},
          {'id': 'D-steep', 'label': worldDSteep.name, 'note': '1 level ≈ 96%'},
          {'id': 'A', 'label': worldA.name, 'note': 'pure average, no carry'},
          {'id': 'B', 'label': worldB.name, 'note': 'stronger partner carries'},
          {'id': 'C', 'label': worldC.name, 'note': 'weaker partner targeted'},
          {'id': 'E', 'label': worldE.name, 'note': 'heavy day-to-day form noise'},
        ],
        'presets': {
          'v2': {'prior': CurrentEngine.prior, 'sigma0': CurrentEngine.sigma0},
          'v3': _cfgJson(kV3Config),
          'v3a': _cfgJson(kV3A),
          'v3b': _cfgJson(kV3B),
          'v3c': _cfgJson(kV3C),
          'v3d': _cfgJson(kV3D),
          'v3e': _cfgJson(kV3E),
          'v3f': _cfgJson(kV3F),
          'v3f5': _cfgJson(kV3F5),
          'tuned': _cfgJson(kTunedConfig),
          'aggressive': _cfgJson(_baseFor('aggressive')),
        },
        'declaredPriors': {
          for (final e in kDeclaredPriors.entries) _declaredName(e.key): e.value,
        },
      };

    case 'story.start':
      {
        final seed = _i(req['seed'], DateTime.now().millisecondsSinceEpoch % 1000000);
        final trueSkill = _d(req['trueSkill'], 5.5);
        final rng = Rng(seed * 7919 + 13);
        _story = StorySession(
          seed: seed,
          trueSkill: trueSkill,
          name: req['name']?.toString() ?? 'Player',
          world: _world(req['world']),
          pool: makePool_(rng, trueSkill, _i(req['poolSize'], 40).clamp(6, 400),
              (req['pool']?.toString() ?? 'established') == 'established'),
          specs: _engineSpecs(req['engines']),
          rng: rng,
        );
        _registerAll(_story!);
        return {'state': _storyState(_story!)};
      }

    case 'story.next':
      {
        final s = _story;
        if (s == null) return {'error': 'Start a story first.'};
        return _storyPlay(s, req);
      }

    case 'story.auto':
      {
        final s = _story;
        if (s == null) return {'error': 'Start a story first.'};
        final n = _i(req['n'], 1).clamp(1, 500);
        for (var i = 0; i < n; i++) {
          final r = _storyPlay(s, const {});
          if (r['error'] != null) return r;
        }
        return {'state': _storyState(s)};
      }

    case 'story.state':
      return _story == null ? {'error': 'No story running.'} : {'state': _storyState(_story!)};

    case 'story.lineup':
      {
        final s = _story;
        if (s == null) return {'error': 'Start a story first.'};
        return {
          'pool': [
            for (var i = 0; i < s.pool.skills.length; i++)
              {'id': i + 1, 'skill': s.pool.skills[i]},
          ],
        };
      }

    case 'solo.run':
      return _soloRun(req);
    case 'solo.average':
      return _soloAverage(req);
    case 'v3.sweep':
      return _v3Sweep(req);

    case 'population.run':
      return _popRun(req);
    case 'population.at':
      return _popAt(req);
    case 'population.player':
      return _popPlayer(req);
    case 'population.players':
      return _popPlayers(req);

    case 'sweep':
      return _sweep(req);
    case 'doubles.pairs':
      return _doublesPairs(req);
    case 'boost':
      return _boost(req);
    case 'partner.phases':
      return _partnerPhases(req);
    case 'skill.shift':
      return _skillShift(req);
    case 'inactivity':
      return _inactivity(req);
    case 'score.compare':
      return _scoreCompare(req);
    case 'declaration':
      return _declaration(req);
    case 'replay.run':
      return _replay(req);
    case 'score.parse':
      return parseScore(req['score']?.toString() ?? '');

    // Used by the build's parity gate. The generator must be bit-identical on
    // the VM and in the browser or a seed stops naming one reproducible run —
    // a different draw means a different match, not a rounding difference.
    case 'rng.probe':
      {
        // Reported as STRINGS so the parity gate compares them exactly. This is
        // the part that must never drift: `nextRaw`/`nextDouble`/`nextInt` are
        // integer and pure-arithmetic, they decide who plays whom and who wins
        // (via `chance`), and one differing bit sends the run elsewhere.
        final exact = <String, List<String>>{};
        // `gauss` needs log and sin, which no platform rounds identically, so it
        // is reported as a NUMBER and checked to a tolerance instead. It only
        // perturbs form noise and matchmaking jitter.
        final gauss = <String, List<double>>{};
        for (final s in const [0, 1, 42, 482901, 999999]) {
          final r = Rng(s);
          exact['$s'] = [
            for (var i = 0; i < 12; i++) r.nextRaw().toString(),
            for (var i = 0; i < 8; i++) r.nextDouble().toStringAsFixed(17),
            for (var i = 0; i < 4; i++) r.nextInt(1000).toString(),
          ];
          gauss['$s'] = [for (var i = 0; i < 4; i++) r.gauss()];
        }
        return {'draws': exact, 'gauss': gauss};
      }

    default:
      return {'error': 'Unknown op "$op"'};
  }
}

/// JSON in, JSON out. Errors come back as `{error: "..."}` rather than throwing
/// across the JS boundary, where a Dart exception is unreadable.
String handleRequest(String raw) {
  try {
    final req = (jsonDecode(raw) as Map).cast<String, dynamic>();
    return jsonEncode(dispatch(req));
  } catch (e, st) {
    return jsonEncode({
      'error': e.toString(),
      'stack': st.toString().split('\n').take(6).join('\n'),
    });
  }
}

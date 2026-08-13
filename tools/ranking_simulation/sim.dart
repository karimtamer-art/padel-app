// ignore_for_file: avoid_print
/// Simulation substrate for the ranking-engine study: deterministic RNG, player
/// populations, "worlds" (ground-truth match-generating models) and matchmakers.
///
/// NOTHING here touches production. The live engine is mirrored read-only in
/// `engines.dart` as ENGINE A.
library;

import 'dart:math' as math;

// ─────────────────────────────────────────────────────────────────────────────
// Deterministic RNG — xoshiro128**, seeded via splitmix32. Reproducible across
// platforms and Dart versions (dart:math Random is not guaranteed to be).
//
// Deliberately 32-bit. The lab UI runs this same file compiled to JavaScript by
// dart2js, where `int` is a double and 64-bit integer maths silently loses the
// low bits — a 64-bit generator would produce a DIFFERENT stream in the browser
// than on the VM, so a seed would no longer name one reproducible run. Every
// step below stays inside 32 bits and multiplies through [_mul32], which is
// exact on both platforms.
// ─────────────────────────────────────────────────────────────────────────────
class Rng {
  int _s0 = 0, _s1 = 0, _s2 = 0, _s3 = 0;
  double? _gaussCache;

  Rng(int seed) {
    var x = (seed == 0 ? 0x9E3779B9 : seed) & 0xFFFFFFFF;
    int mix() {
      x = (x + 0x9E3779B9) & 0xFFFFFFFF;
      var z = x;
      z = _mul32(z ^ (z >>> 16), 0x21F0AAAD);
      z = _mul32(z ^ (z >>> 15), 0x735A2D97);
      return (z ^ (z >>> 15)) & 0xFFFFFFFF;
    }

    _s0 = mix();
    _s1 = mix();
    _s2 = mix();
    _s3 = mix();
  }

  /// (a · b) mod 2³², exact on the VM *and* under dart2js. Split into 16-bit
  /// halves so no intermediate exceeds 2⁵³ (where a JS double stops being an
  /// exact integer); the shifts are done as multiplies because `<<` does not
  /// agree across the two platforms once a result passes 32 bits.
  static int _mul32(int a, int b) {
    final al = a & 0xFFFF, ah = (a >>> 16) & 0xFFFF;
    final bl = b & 0xFFFF, bh = (b >>> 16) & 0xFFFF;
    final mid = (ah * bl + al * bh) & 0xFFFF;
    return (al * bl + mid * 0x10000) & 0xFFFFFFFF;
  }

  int _rotl(int v, int k) => (_mul32(v, 1 << k) | (v >>> (32 - k))) & 0xFFFFFFFF;

  int nextRaw() {
    final result = _mul32(_rotl(_mul32(_s1, 5), 7), 9);
    final t = _mul32(_s1, 1 << 9);
    _s2 ^= _s0;
    _s3 ^= _s1;
    _s1 ^= _s2;
    _s0 ^= _s3;
    _s2 ^= t;
    _s3 = _rotl(_s3, 11);
    return result;
  }

  /// Uniform in [0, 1). Two draws give a full 53-bit mantissa, so the stream is
  /// not visibly quantised when it drives a probability.
  double nextDouble() =>
      ((nextRaw() >>> 5) * 67108864.0 + (nextRaw() >>> 6)) / 9007199254740992.0;

  int nextInt(int n) => (nextRaw() >>> 1) % n;

  bool chance(double p) => nextDouble() < p;

  /// Standard normal (Box–Muller with a cached second variate).
  double gauss() {
    final cached = _gaussCache;
    if (cached != null) {
      _gaussCache = null;
      return cached;
    }
    final u1 = 1.0 - nextDouble();
    final u2 = 1.0 - nextDouble();
    final r = math.sqrt(-2.0 * math.log(u1));
    _gaussCache = r * math.sin(2 * math.pi * u2);
    return r * math.cos(2 * math.pi * u2);
  }

  void shuffle<T>(List<T> list) {
    for (var i = list.length - 1; i > 0; i--) {
      final j = nextInt(i + 1);
      final tmp = list[i];
      list[i] = list[j];
      list[j] = tmp;
    }
  }
}

double clampD(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

// ─────────────────────────────────────────────────────────────────────────────
// Population
// ─────────────────────────────────────────────────────────────────────────────

enum SkillDist {
  /// Many intermediates, fewer beginners, few elite — the realistic shape.
  bell,

  /// Flat 0.5–6.5, for comparison.
  uniform,
}

/// Optional onboarding self-declaration. `unknown` = no question asked.
enum SelfDeclared { unknown, beginner, intermediate, advanced, competitive }

class SimPlayer {
  final int id;

  /// Long-run true skill on the 0–7 scale. May drift (improving/declining).
  double trueSkill;

  /// Baseline before any drift, for reporting.
  final double baselineSkill;

  /// Per-match form noise scale multiplier (world E gives this teeth).
  double drift; // per-match linear drift applied to trueSkill

  SelfDeclared declared;

  /// Simulated inactivity: matches are skipped while this is > 0.
  int idleWeeks = 0;

  SimPlayer(this.id, this.trueSkill, {this.drift = 0.0, this.declared = SelfDeclared.unknown})
      : baselineSkill = trueSkill;
}

List<SimPlayer> makePopulation(Rng rng, int n, SkillDist dist) {
  final out = <SimPlayer>[];
  for (var i = 0; i < n; i++) {
    double s;
    if (dist == SkillDist.bell) {
      // mean 3.3, sd 1.15 → most players 2–4.5, a thin elite tail.
      s = clampD(3.3 + rng.gauss() * 1.15, 0.3, 6.9);
    } else {
      s = 0.5 + rng.nextDouble() * 6.0;
    }
    out.add(SimPlayer(i, s));
  }
  return out;
}

/// Assign a self-declared bracket. [honesty] is the probability the player
/// declares the bracket that actually matches their skill; otherwise they pick
/// a neighbouring (or, with `sandbag`/`inflate`, a deliberately wrong) one.
void assignSelfDeclared(Rng rng, List<SimPlayer> players,
    {double honesty = 0.7, double sandbagRate = 0.0, double inflateRate = 0.0}) {
  SelfDeclared bracketOf(double s) {
    if (s < 2.0) return SelfDeclared.beginner;
    if (s < 3.5) return SelfDeclared.intermediate;
    if (s < 5.0) return SelfDeclared.advanced;
    return SelfDeclared.competitive;
  }

  const order = [
    SelfDeclared.beginner,
    SelfDeclared.intermediate,
    SelfDeclared.advanced,
    SelfDeclared.competitive,
  ];

  for (final p in players) {
    final truth = bracketOf(p.trueSkill);
    if (rng.chance(sandbagRate)) {
      p.declared = SelfDeclared.beginner; // smurf declares low
    } else if (rng.chance(inflateRate)) {
      p.declared = SelfDeclared.competitive; // overrated beginner declares high
    } else if (rng.chance(honesty)) {
      p.declared = truth;
    } else {
      final i = order.indexOf(truth);
      final j = clampD((i + (rng.chance(0.5) ? 1 : -1)).toDouble(), 0, 3).toInt();
      p.declared = order[j];
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Worlds — the ground-truth match-generating models.
//
// A world converts two pairs of TRUE skills into a realistic padel scoreline.
// Crucially the engines never see these parameters; several worlds violate the
// engines' modelling assumptions on purpose (that is the point — an Elo engine
// evaluated only in an Elo world grades its own homework).
// ─────────────────────────────────────────────────────────────────────────────

class World {
  final String name;

  /// Team strength = avg + carry*gap − weakLink*gap²   (gap = |r1 − r2|)
  ///   carry > 0     → the stronger partner drags the pair up (World B)
  ///   weakLink > 0  → the weaker partner is targeted (World C)
  ///   both          → carry helps small gaps, targeting dominates big ones (D)
  final double carry;
  final double weakLink;

  /// Per-match form noise added to each player's effective skill (World E).
  final double formSigma;

  /// Logistic scale for the PER-GAME win probability. Smaller = more decisive
  /// padel. This, not the engine's constant, defines truth in the simulation.
  ///
  /// Calibrated so the DEFAULT world gives a 1.0-level gap ≈ 86% match win rate
  /// and a 0.5-level gap ≈ 71%, which is roughly what a Playtomic-style level
  /// difference means in practice. The engine's own curve is a separate,
  /// tunable assumption — that mismatch is deliberately what E6 measures.
  final double gameScale;

  const World({
    required this.name,
    this.carry = 0.0,
    this.weakLink = 0.0,
    this.formSigma = 0.0,
    this.gameScale = 5.5,
  });

  double teamStrength(double a, double b) {
    final gap = (a - b).abs();
    return (a + b) / 2 + carry * gap - weakLink * gap * gap;
  }

  double perGameProb(double sA, double sB) =>
      1.0 / (1.0 + math.pow(10.0, (sB - sA) / gameScale));

  /// True P(team A wins the match) — analytic, used to describe each world's
  /// decisiveness (e.g. "what does a 1.0 level gap actually mean here?").
  double trueMatchProb(double sA, double sB) {
    final pg = perGameProb(sA, sB);
    final ps = _setWinProb(pg);
    return ps * ps * (3 - 2 * ps); // best of 3
  }

  /// Result of one match.
  MatchObs play(Rng rng, int a1, int a2, int b1, int b2, List<double> effSkill) {
    final sA = teamStrength(effSkill[a1], effSkill[a2]);
    final sB = teamStrength(effSkill[b1], effSkill[b2]);
    final pg = perGameProb(sA, sB);

    var setsA = 0, setsB = 0, gamesA = 0, gamesB = 0;
    final sets = <List<int>>[];
    while (setsA < 2 && setsB < 2) {
      var a = 0, b = 0;
      while (true) {
        if (rng.chance(pg)) {
          a++;
        } else {
          b++;
        }
        if (a >= 6 && a - b >= 2) break;
        if (b >= 6 && b - a >= 2) break;
        if (a == 6 && b == 6) {
          // tie-break: one more "game" to the winner
          if (rng.chance(pg)) {
            a++;
          } else {
            b++;
          }
          break;
        }
      }
      gamesA += a;
      gamesB += b;
      sets.add([a, b]);
      if (a > b) {
        setsA++;
      } else {
        setsB++;
      }
    }
    return MatchObs(
      a1: a1,
      a2: a2,
      b1: b1,
      b2: b2,
      gamesA: gamesA,
      gamesB: gamesB,
      sets: sets,
      aWon: setsA > setsB,
    );
  }

  /// P(win a set to 6, win by 2, tie-break at 6-6) given a per-game prob.
  static double _setWinProb(double p) {
    final q = 1 - p;
    double c(int n, int k) {
      var r = 1.0;
      for (var i = 0; i < k; i++) {
        r = r * (n - i) / (i + 1);
      }
      return r;
    }

    var win = 0.0;
    // 6-0 .. 6-4
    for (var l = 0; l <= 4; l++) {
      win += c(5 + l, l) * math.pow(p, 6) * math.pow(q, l);
    }
    // 7-5: reach 5-5 then win two straight
    final at55 = c(10, 5) * math.pow(p, 5) * math.pow(q, 5);
    win += at55 * p * p;
    // 6-6 → tie-break
    win += at55 * 2 * p * q * p;
    return win.toDouble();
  }
}

const worldA = World(name: 'A · Elo-like (pure average)');
const worldB = World(name: 'B · Strong-player carry', carry: 0.22);
const worldC = World(name: 'C · Weak-link targeting', weakLink: 0.075);
const worldD = World(name: 'D · Mixed doubles reality', carry: 0.20, weakLink: 0.085, formSigma: 0.25);
const worldE = World(name: 'E · Temporary form', formSigma: 0.40);

/// Same as D but with a flatter truth curve — used to test whether the engine's
/// steep 1-level≈91% assumption survives a world that is less decisive.
const worldDFlat = World(
    name: 'D-flat · Mixed, less decisive (1 level ≈ 78%)',
    carry: 0.20,
    weakLink: 0.085,
    formSigma: 0.25,
    gameScale: 8.0);
const worldDSteep = World(
    name: 'D-steep · Mixed, very decisive (1 level ≈ 96%)',
    carry: 0.20,
    weakLink: 0.085,
    formSigma: 0.25,
    gameScale: 3.5);

class MatchObs {
  final int a1, a2, b1, b2;
  final int gamesA, gamesB;
  final List<List<int>> sets;
  final bool aWon;

  const MatchObs({
    required this.a1,
    required this.a2,
    required this.b1,
    required this.b2,
    required this.gamesA,
    required this.gamesB,
    required this.sets,
    required this.aWon,
  });

  List<int> get teamA => [a1, a2];
  List<int> get teamB => [b1, b2];
  List<int> get all => [a1, a2, b1, b2];
}

// ─────────────────────────────────────────────────────────────────────────────
// Matchmaking
//
// Two families:
//  · SocialMatchmaker  — engine-INDEPENDENT. Produces one identical match
//    stream that every engine consumes, which is what makes the head-to-head
//    comparison fair. Models real life: people mostly play others around their
//    own level, with plenty of noise.
//  · Engine-driven      — used ONLY in the matchmaking experiment, where the
//    stream necessarily differs per engine (that is the thing being measured).
// ─────────────────────────────────────────────────────────────────────────────

/// Groups players into fours, clustered by true skill with strength [cluster]
/// (0 = fully random, 1 = strictly by level).
class SocialMatchmaker {
  final double cluster;
  const SocialMatchmaker({this.cluster = 0.55});

  List<MatchObs> round(Rng rng, List<SimPlayer> active, World world, List<double> effSkill) {
    final keyed = active
        .map((p) => _Keyed(p.id, p.trueSkill * cluster + rng.gauss() * (1 - cluster) * 2.0))
        .toList()
      ..sort((x, y) => x.key.compareTo(y.key));

    final out = <MatchObs>[];
    for (var i = 0; i + 3 < keyed.length; i += 4) {
      final g = [keyed[i].id, keyed[i + 1].id, keyed[i + 2].id, keyed[i + 3].id];
      rng.shuffle(g);
      out.add(world.play(rng, g[0], g[1], g[2], g[3], effSkill));
    }
    return out;
  }
}

class _Keyed {
  final int id;
  final double key;
  const _Keyed(this.id, this.key);
}

/// Per-match effective skill (true skill + form noise), rebuilt each round.
List<double> effectiveSkills(Rng rng, List<SimPlayer> players, World world) {
  final n = players.length;
  final out = List<double>.filled(n, 0);
  for (final p in players) {
    out[p.id] = world.formSigma == 0
        ? p.trueSkill
        : clampD(p.trueSkill + rng.gauss() * world.formSigma, 0.0, 7.0);
  }
  return out;
}

/// Applies per-round skill drift (improving / declining players).
void applyDrift(List<SimPlayer> players) {
  for (final p in players) {
    if (p.drift != 0) p.trueSkill = clampD(p.trueSkill + p.drift, 0.2, 7.0);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small stats helpers used by metrics + experiments.
// ─────────────────────────────────────────────────────────────────────────────

double mean(List<double> xs) =>
    xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;

double sd(List<double> xs) {
  if (xs.length < 2) return 0;
  final m = mean(xs);
  var s = 0.0;
  for (final x in xs) {
    s += (x - m) * (x - m);
  }
  return math.sqrt(s / (xs.length - 1));
}

double median(List<double> xs) {
  if (xs.isEmpty) return 0;
  final s = List<double>.from(xs)..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

double percentile(List<double> xs, double p) {
  if (xs.isEmpty) return 0;
  final s = List<double>.from(xs)..sort();
  final idx = clampD((s.length - 1) * p, 0, (s.length - 1).toDouble());
  final lo = idx.floor(), hi = idx.ceil();
  if (lo == hi) return s[lo];
  return s[lo] + (s[hi] - s[lo]) * (idx - lo);
}

/// Spearman rank correlation.
double spearman(List<double> a, List<double> b) {
  final n = a.length;
  if (n < 2) return 0;
  final ra = _ranks(a), rb = _ranks(b);
  final ma = mean(ra), mb = mean(rb);
  var num = 0.0, da = 0.0, db = 0.0;
  for (var i = 0; i < n; i++) {
    final x = ra[i] - ma, y = rb[i] - mb;
    num += x * y;
    da += x * x;
    db += y * y;
  }
  final den = math.sqrt(da * db);
  return den == 0 ? 0 : num / den;
}

List<double> _ranks(List<double> xs) {
  final idx = List<int>.generate(xs.length, (i) => i)
    ..sort((i, j) => xs[i].compareTo(xs[j]));
  final r = List<double>.filled(xs.length, 0);
  var i = 0;
  while (i < idx.length) {
    var j = i;
    while (j + 1 < idx.length && xs[idx[j + 1]] == xs[idx[i]]) {
      j++;
    }
    final avg = (i + j) / 2 + 1;
    for (var k = i; k <= j; k++) {
      r[idx[k]] = avg;
    }
    i = j + 1;
  }
  return r;
}

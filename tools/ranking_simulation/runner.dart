// ignore_for_file: avoid_print
/// Match-stream generation and engine replay.
///
/// The head-to-head comparison depends on every engine seeing the IDENTICAL
/// stream, so streams are built from ground truth (population, world, social
/// matchmaking) and never from any engine's ratings. The one exception is the
/// matchmaking experiment, which by definition has to let each engine pick its
/// own opponents — that runs through [engineDrivenStream] and is reported
/// separately.
library;

import 'dart:math' as math;

import 'engines.dart';
import 'metrics.dart';
import 'sim.dart';

class MatchStream {
  final List<SimPlayer> players;
  final List<List<MatchObs>> rounds;

  /// Ground-truth skill per player at the END of each round (drift-aware).
  final List<List<double>> truthByRound;

  const MatchStream(this.players, this.rounds, this.truthByRound);

  int get n => players.length;
  int get roundCount => rounds.length;
}

class StreamSpec {
  final int nPlayers;
  final int rounds;
  final World world;
  final SkillDist dist;
  final double cluster;

  /// Fraction of players who drift up / down over the run.
  final double improverRate, declinerRate;
  final double driftPerRound;

  /// Onboarding self-declaration behaviour.
  final bool askOnboarding;
  final double honesty, sandbagRate, inflateRate;

  const StreamSpec({
    this.nPlayers = 1000,
    this.rounds = 50,
    this.world = worldD,
    this.dist = SkillDist.bell,
    this.cluster = 0.55,
    this.improverRate = 0.0,
    this.declinerRate = 0.0,
    this.driftPerRound = 0.012,
    this.askOnboarding = false,
    this.honesty = 0.7,
    this.sandbagRate = 0.0,
    this.inflateRate = 0.0,
  });
}

MatchStream buildStream(int seed, StreamSpec spec) {
  final rng = Rng(seed * 7919 + 13);
  final players = makePopulation(rng, spec.nPlayers, spec.dist);

  for (final p in players) {
    if (rng.chance(spec.improverRate)) {
      p.drift = spec.driftPerRound;
    } else if (rng.chance(spec.declinerRate)) {
      p.drift = -spec.driftPerRound;
    }
  }
  if (spec.askOnboarding) {
    assignSelfDeclared(rng, players,
        honesty: spec.honesty, sandbagRate: spec.sandbagRate, inflateRate: spec.inflateRate);
  }

  final mm = SocialMatchmaker(cluster: spec.cluster);
  final rounds = <List<MatchObs>>[];
  final truth = <List<double>>[];
  for (var r = 0; r < spec.rounds; r++) {
    final eff = effectiveSkills(rng, players, spec.world);
    rounds.add(mm.round(rng, players, spec.world, eff));
    applyDrift(players);
    truth.add([for (final p in players) p.trueSkill]);
  }
  return MatchStream(players, rounds, truth);
}

class RunOutput {
  final String engine;
  final Map<int, Snapshot> snapshots;
  final Calibration calib;
  final Agg conv025, conv050;
  final double neverConverged025;
  final double stability;
  final List<double> finalEst;
  final List<double> finalTruth;
  final List<double> finalSigma;
  final List<List<double>> trajectories; // [player][round]
  final double displayReadyRound; // mean round at which the gate opens
  final double displayReadyMae; // MAE at the moment the gate opens

  const RunOutput({
    required this.engine,
    required this.snapshots,
    required this.calib,
    required this.conv025,
    required this.conv050,
    required this.neverConverged025,
    required this.stability,
    required this.finalEst,
    required this.finalTruth,
    required this.finalSigma,
    required this.trajectories,
    required this.displayReadyRound,
    required this.displayReadyMae,
  });
}

const defaultSnapAt = [1, 3, 5, 10, 20, 50];

RunOutput replay(
  RankingEngine e,
  MatchStream s, {
  List<int> snapAt = defaultSnapAt,
  int calibFromRound = 20,
  bool keepTrajectories = false,
  int metricSeed = 999,
}) {
  final rng = Rng(metricSeed);
  for (final p in s.players) {
    e.register(p.id, declared: p.declared);
  }

  final traj = List<List<double>>.generate(s.n, (_) => <double>[]);
  final calib = Calibration();
  final readyRound = List<int>.filled(s.n, -1);
  final readyErr = List<double>.filled(s.n, double.nan);

  for (var r = 0; r < s.roundCount; r++) {
    for (final m in s.rounds[r]) {
      if (r >= calibFromRound) calib.add(e.predictA(m), m.aWon);
      e.update(m);
    }
    for (var i = 0; i < s.n; i++) {
      traj[i].add(e.estimate(i));
      if (readyRound[i] < 0 && e.displayReady(i)) {
        readyRound[i] = r + 1;
        readyErr[i] = (e.estimate(i) - s.truthByRound[r][i]).abs();
      }
    }
  }

  final snaps = <int, Snapshot>{};
  for (final k in snapAt) {
    if (k > s.roundCount) continue;
    final est = [for (var i = 0; i < s.n; i++) traj[i][k - 1]];
    snaps[k] = snapshot(k, est, s.truthByRound[k - 1], rng);
  }

  final finalTruth = s.truthByRound.last;
  final c25 = <double>[], c50 = <double>[], stab = <double>[];
  var never = 0;
  for (var i = 0; i < s.n; i++) {
    final a = convergenceMatches(traj[i], finalTruth[i], 0.25);
    final b = convergenceMatches(traj[i], finalTruth[i], 0.50);
    if (a < 0) {
      never++;
    } else {
      c25.add(a.toDouble());
    }
    if (b >= 0) c50.add(b.toDouble());
    stab.add(stabilityNoise(traj[i], finalTruth[i]));
  }

  final readyRounds = <double>[], readyErrs = <double>[];
  for (var i = 0; i < s.n; i++) {
    if (readyRound[i] > 0) {
      readyRounds.add(readyRound[i].toDouble());
      readyErrs.add(readyErr[i]);
    }
  }

  return RunOutput(
    engine: e.name,
    snapshots: snaps,
    calib: calib,
    conv025: Agg.of(c25.isEmpty ? [double.nan] : c25),
    conv050: Agg.of(c50.isEmpty ? [double.nan] : c50),
    neverConverged025: 100 * never / s.n,
    stability: mean(stab),
    finalEst: [for (var i = 0; i < s.n; i++) traj[i].last],
    finalTruth: finalTruth,
    finalSigma: [for (var i = 0; i < s.n; i++) e.sigmaOf(i)],
    trajectories: keepTrajectories ? traj : const [],
    displayReadyRound: readyRounds.isEmpty ? double.nan : mean(readyRounds),
    displayReadyMae: readyErrs.isEmpty ? double.nan : mean(readyErrs),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Engine-driven matchmaking (matchmaking experiment only).
// ─────────────────────────────────────────────────────────────────────────────

enum MatchmakingMode {
  /// Band around the player's current estimate — what the app does today.
  nearRating,

  /// During placement, deliberately probe stronger/weaker opposition based on
  /// how the previous matches went (adaptive-testing style).
  adaptiveProbe,
}

/// Runs a stream that the engine itself steers. Returns the same RunOutput
/// shape so the two arms are directly comparable.
RunOutput engineDrivenRun(
  RankingEngine e,
  int seed,
  StreamSpec spec,
  MatchmakingMode mode, {
  int placementMatches = 10,
  double probeStep = 0.45,
  List<int> snapAt = defaultSnapAt,
}) {
  final rng = Rng(seed * 7919 + 13);
  final players = makePopulation(rng, spec.nPlayers, spec.dist);
  for (final p in players) {
    e.register(p.id, declared: p.declared);
  }

  final probe = List<double>.filled(spec.nPlayers, 0);
  final traj = List<List<double>>.generate(spec.nPlayers, (_) => <double>[]);
  final calib = Calibration();
  final truthByRound = <List<double>>[];

  for (var r = 0; r < spec.rounds; r++) {
    final eff = effectiveSkills(rng, players, spec.world);

    // sort by the search key, then chunk into fours
    final keys = <_K>[];
    for (final p in players) {
      final est = e.estimate(p.id);
      final inPlacement = e.matchesOf(p.id) < placementMatches;
      final k = mode == MatchmakingMode.adaptiveProbe && inPlacement
          ? est + probe[p.id]
          : est;
      // small jitter so ties don't lock the same fours together forever
      keys.add(_K(p.id, k + rng.gauss() * 0.12));
    }
    keys.sort((a, b) => a.k.compareTo(b.k));

    for (var i = 0; i + 3 < keys.length; i += 4) {
      final g = [keys[i].id, keys[i + 1].id, keys[i + 2].id, keys[i + 3].id];
      rng.shuffle(g);
      final m = spec.world.play(rng, g[0], g[1], g[2], g[3], eff);
      if (r >= 20) calib.add(e.predictA(m), m.aWon);
      e.update(m);

      if (mode == MatchmakingMode.adaptiveProbe) {
        final ratio = m.gamesA / math.max(1, m.gamesA + m.gamesB);
        for (final id in m.all) {
          if (e.matchesOf(id) > placementMatches) {
            probe[id] = 0;
            continue;
          }
          final onA = id == m.a1 || id == m.a2;
          final won = onA == m.aWon;
          final myRatio = onA ? ratio : 1 - ratio;
          if (won && myRatio > 0.62) {
            probe[id] += probeStep; // convincing win → look higher
          } else if (won) {
            probe[id] += probeStep * 0.35;
          } else if (myRatio < 0.38) {
            probe[id] -= probeStep; // heavy loss → look lower
          } else {
            probe[id] = probe[id] * 0.5; // close loss → narrow in
          }
          probe[id] = clampD(probe[id], -2.0, 2.0);
        }
      }
    }

    applyDrift(players);
    truthByRound.add([for (final p in players) p.trueSkill]);
    for (var i = 0; i < spec.nPlayers; i++) {
      traj[i].add(e.estimate(i));
    }
  }

  final mrng = Rng(999);
  final snaps = <int, Snapshot>{};
  for (final k in snapAt) {
    if (k > spec.rounds) continue;
    final est = [for (var i = 0; i < spec.nPlayers; i++) traj[i][k - 1]];
    snaps[k] = snapshot(k, est, truthByRound[k - 1], mrng);
  }
  final finalTruth = truthByRound.last;
  final c25 = <double>[], c50 = <double>[];
  var never = 0;
  for (var i = 0; i < spec.nPlayers; i++) {
    final a = convergenceMatches(traj[i], finalTruth[i], 0.25);
    final b = convergenceMatches(traj[i], finalTruth[i], 0.50);
    if (a < 0) {
      never++;
    } else {
      c25.add(a.toDouble());
    }
    if (b >= 0) c50.add(b.toDouble());
  }

  return RunOutput(
    engine: e.name,
    snapshots: snaps,
    calib: calib,
    conv025: Agg.of(c25.isEmpty ? [double.nan] : c25),
    conv050: Agg.of(c50.isEmpty ? [double.nan] : c50),
    neverConverged025: 100 * never / spec.nPlayers,
    stability: 0,
    finalEst: [for (var i = 0; i < spec.nPlayers; i++) traj[i].last],
    finalTruth: finalTruth,
    finalSigma: [for (var i = 0; i < spec.nPlayers; i++) e.sigmaOf(i)],
    trajectories: const [],
    displayReadyRound: double.nan,
    displayReadyMae: double.nan,
  );
}

class _K {
  final int id;
  final double k;
  const _K(this.id, this.k);
}

// ─────────────────────────────────────────────────────────────────────────────
// Targeted doubles scenarios (partner independence, boosting, diversity).
// ─────────────────────────────────────────────────────────────────────────────

/// A scripted stream: a burn-in of ordinary social play, then scripted phases
/// where designated "probe" players are given specific partners.
class ScriptedResult {
  final Map<String, List<double>> errorByPhase; // phase → per-probe |est−true|
  final Map<String, List<double>> estByPhase;
  final Map<String, List<double>> sigmaByPhase;
  final List<double> probeTrue;
  const ScriptedResult(this.errorByPhase, this.estByPhase, this.sigmaByPhase, this.probeTrue);
}

/// [phases] maps a phase label to (roundCount, partnerSkill?) — a null partner
/// skill means "random partner from the pool".
ScriptedResult scriptedPartnerRun(
  RankingEngine e,
  int seed, {
  int poolSize = 600,
  int burnIn = 30,
  World world = worldD,
  required List<(String, int, double?)> phases,
  required List<double> probeSkills,
  double? forcedPartnerGapLimit,
}) {
  final rng = Rng(seed * 104729 + 7);
  final pool = makePopulation(rng, poolSize, SkillDist.bell);

  // probe players appended after the pool
  final probes = <SimPlayer>[];
  for (var i = 0; i < probeSkills.length; i++) {
    probes.add(SimPlayer(poolSize + i, probeSkills[i]));
  }
  // one dedicated partner per probe, skill assigned per phase — allocate the
  // maximum number of partner slots up front so ids stay stable
  final partners = <SimPlayer>[];
  for (var i = 0; i < probeSkills.length; i++) {
    partners.add(SimPlayer(poolSize + probeSkills.length + i, 3.5));
  }

  final all = [...pool, ...probes, ...partners];
  for (final p in all) {
    e.register(p.id);
  }

  final mm = const SocialMatchmaker(cluster: 0.55);

  // burn-in: everyone plays normally so pool ratings mean something
  for (var r = 0; r < burnIn; r++) {
    final eff = effectiveSkills(rng, all, world);
    for (final m in mm.round(rng, all, world, eff)) {
      e.update(m);
    }
  }

  final errorByPhase = <String, List<double>>{};
  final estByPhase = <String, List<double>>{};
  final sigmaByPhase = <String, List<double>>{};

  for (final (label, roundCount, partnerSkill) in phases) {
    if (partnerSkill != null) {
      for (final p in partners) {
        p.trueSkill = partnerSkill;
      }
    }
    for (var r = 0; r < roundCount; r++) {
      final eff = effectiveSkills(rng, all, world);

      // scripted matches for the probes
      final busy = <int>{};
      for (var i = 0; i < probes.length; i++) {
        final probe = probes[i];
        final partner = partnerSkill == null
            ? pool[rng.nextInt(pool.length)]
            : partners[i];
        if (busy.contains(partner.id)) continue;

        if (forcedPartnerGapLimit != null &&
            (e.estimate(probe.id) - e.estimate(partner.id)).abs() > forcedPartnerGapLimit) {
          continue; // ranked pairing blocked by the gap rule
        }

        // reserve the pair BEFORE choosing opponents so a random partner can't
        // also be drafted as an opponent
        busy.addAll([probe.id, partner.id]);

        // opponents: two pool players whose level is near the pair's strength
        final target = world.teamStrength(probe.trueSkill, partner.trueSkill);
        SimPlayer? pick() {
          SimPlayer? best;
          var bestD = double.infinity;
          for (var t = 0; t < 24; t++) {
            final c = pool[rng.nextInt(pool.length)];
            if (busy.contains(c.id)) continue;
            final d = (c.trueSkill - target).abs();
            if (d < bestD) {
              bestD = d;
              best = c;
            }
          }
          return best;
        }

        final o1 = pick();
        if (o1 == null) continue;
        busy.add(o1.id);
        final o2 = pick();
        if (o2 == null) continue;
        busy.add(o2.id);
        e.update(world.play(rng, probe.id, partner.id, o1.id, o2.id, eff));
      }

      // everyone else plays normally
      final rest = all.where((p) => !busy.contains(p.id)).toList();
      for (final m in mm.round(rng, rest, world, eff)) {
        e.update(m);
      }
    }

    errorByPhase[label] = [for (final p in probes) (e.estimate(p.id) - p.trueSkill).abs()];
    estByPhase[label] = [for (final p in probes) e.estimate(p.id)];
    sigmaByPhase[label] = [for (final p in probes) e.sigmaOf(p.id)];
  }

  return ScriptedResult(
      errorByPhase, estByPhase, sigmaByPhase, [for (final p in probes) p.trueSkill]);
}

// ignore_for_file: avoid_print
/// Evaluation metrics for the ranking study.
library;

import 'dart:math' as math;

import 'sim.dart';

/// Reliability-diagram accumulator over predicted win probabilities.
class Calibration {
  static const bins = [0.5, 0.6, 0.7, 0.8, 0.9, 1.0001];
  final List<int> count = List<int>.filled(bins.length - 1, 0);
  final List<double> predSum = List<double>.filled(bins.length - 1, 0);
  final List<int> wins = List<int>.filled(bins.length - 1, 0);
  int total = 0;
  int correct = 0;
  double logLoss = 0;
  double brier = 0;

  void add(double pA, bool aWon) {
    final p = clampD(pA, 1e-6, 1 - 1e-6);
    total++;
    if ((p >= 0.5) == aWon) correct++;
    logLoss += -(aWon ? math.log(p) : math.log(1 - p));
    final err = (aWon ? 1.0 : 0.0) - p;
    brier += err * err;

    // fold onto the favourite's side
    final pFav = p >= 0.5 ? p : 1 - p;
    final favWon = (p >= 0.5) == aWon;
    for (var i = 0; i < bins.length - 1; i++) {
      if (pFav >= bins[i] && pFav < bins[i + 1]) {
        count[i]++;
        predSum[i] += pFav;
        if (favWon) wins[i]++;
        return;
      }
    }
  }

  double get accuracy => total == 0 ? 0 : correct / total;
  double get meanLogLoss => total == 0 ? 0 : logLoss / total;
  double get meanBrier => total == 0 ? 0 : brier / total;

  /// Expected calibration error — count-weighted |predicted − observed|.
  double get ece {
    if (total == 0) return 0;
    var s = 0.0;
    for (var i = 0; i < count.length; i++) {
      if (count[i] == 0) continue;
      final pred = predSum[i] / count[i];
      final obs = wins[i] / count[i];
      s += count[i] * (pred - obs).abs();
    }
    return s / total;
  }

  List<(double, double, int)> get curve => [
        for (var i = 0; i < count.length; i++)
          if (count[i] > 0) (predSum[i] / count[i], wins[i] / count[i], count[i])
      ];

  void merge(Calibration o) {
    for (var i = 0; i < count.length; i++) {
      count[i] += o.count[i];
      predSum[i] += o.predSum[i];
      wins[i] += o.wins[i];
    }
    total += o.total;
    correct += o.correct;
    logLoss += o.logLoss;
    brier += o.brier;
  }
}

/// True-skill bands used for per-level reporting.
const skillBands = <(String, double, double)>[
  ('1–2', 1.0, 2.0),
  ('2–3', 2.0, 3.0),
  ('3–4', 3.0, 4.0),
  ('4–5', 4.0, 5.0),
  ('5–6', 5.0, 6.0),
  ('6–7', 6.0, 7.0),
];

class Snapshot {
  final int atMatch;
  final double mae, medAE, rmse, spearman, pairwise;
  final double estSd, trueSd;

  /// Elo-family ratings only identify DIFFERENCES — the absolute position of
  /// the whole population is fixed by the prior (and by anchors), never learned.
  /// So error is decomposed: [bias] is the population-wide offset
  /// (mean estimate − mean truth) and [maeCentered] is the error left after
  /// that offset is removed, i.e. how well the engine spreads players out.
  final double bias;
  final double maeCentered;
  final Map<String, double> maeByBand;
  final Map<String, double> meanEstByBand;

  /// Cold-start compression headline numbers.
  final double pctStrongStuckLow; // true ≥ 5.0 but estimated < 3.5
  final double pctWeakStuckHigh; // true ≤ 2.0 but estimated > 3.0

  const Snapshot({
    required this.atMatch,
    required this.mae,
    required this.medAE,
    required this.rmse,
    required this.spearman,
    required this.pairwise,
    required this.estSd,
    required this.trueSd,
    required this.bias,
    required this.maeCentered,
    required this.maeByBand,
    required this.meanEstByBand,
    required this.pctStrongStuckLow,
    required this.pctWeakStuckHigh,
  });

  double get spreadRecovery => trueSd == 0 ? 0 : estSd / trueSd;

  Map<String, dynamic> toJson() => {
        'atMatch': atMatch,
        'mae': mae,
        'medAE': medAE,
        'rmse': rmse,
        'spearman': spearman,
        'pairwise': pairwise,
        'estSd': estSd,
        'trueSd': trueSd,
        'bias': bias,
        'maeCentered': maeCentered,
        'spreadRecovery': spreadRecovery,
        'maeByBand': maeByBand,
        'meanEstByBand': meanEstByBand,
        'pctStrongStuckLow': pctStrongStuckLow,
        'pctWeakStuckHigh': pctWeakStuckHigh,
      };
}

Snapshot snapshot(int atMatch, List<double> est, List<double> truth, Rng rng) {
  final n = est.length;
  final abs = <double>[];
  var sq = 0.0;
  for (var i = 0; i < n; i++) {
    final d = (est[i] - truth[i]).abs();
    abs.add(d);
    sq += d * d;
  }
  final bias = mean(est) - mean(truth);
  final centered = [for (var i = 0; i < n; i++) (est[i] - truth[i] - bias).abs()];

  final byBand = <String, double>{};
  final meanByBand = <String, double>{};
  for (final (label, lo, hi) in skillBands) {
    final es = <double>[], errs = <double>[];
    for (var i = 0; i < n; i++) {
      if (truth[i] >= lo && truth[i] < hi) {
        es.add(est[i]);
        errs.add((est[i] - truth[i]).abs());
      }
    }
    if (errs.isNotEmpty) {
      byBand[label] = mean(errs);
      meanByBand[label] = mean(es);
    }
  }

  // pairwise ranking accuracy over sampled pairs
  var okPairs = 0, totPairs = 0;
  final samples = math.min(40000, n * 20);
  for (var s = 0; s < samples; s++) {
    final i = rng.nextInt(n), j = rng.nextInt(n);
    if (i == j || (truth[i] - truth[j]).abs() < 0.05) continue;
    totPairs++;
    if ((truth[i] > truth[j]) == (est[i] > est[j])) okPairs++;
  }

  var strongTot = 0, strongLow = 0, weakTot = 0, weakHigh = 0;
  for (var i = 0; i < n; i++) {
    if (truth[i] >= 5.0) {
      strongTot++;
      if (est[i] < 3.5) strongLow++;
    }
    if (truth[i] <= 2.0) {
      weakTot++;
      if (est[i] > 3.0) weakHigh++;
    }
  }

  return Snapshot(
    atMatch: atMatch,
    mae: mean(abs),
    medAE: median(abs),
    rmse: math.sqrt(sq / n),
    spearman: spearman(est, truth),
    pairwise: totPairs == 0 ? 0 : okPairs / totPairs,
    estSd: sd(est),
    trueSd: sd(truth),
    bias: bias,
    maeCentered: mean(centered),
    maeByBand: byBand,
    meanEstByBand: meanByBand,
    pctStrongStuckLow: strongTot == 0 ? 0 : 100 * strongLow / strongTot,
    pctWeakStuckHigh: weakTot == 0 ? 0 : 100 * weakHigh / weakTot,
  );
}

/// Matches needed before |est − true| stays inside [tol] for the REST of the
/// run (not merely touches it once). `trajectory[i]` is the estimate after
/// match i+1. Returns -1 if the player never settles inside the tolerance.
int convergenceMatches(List<double> trajectory, double truth, double tol) {
  var firstOk = 0;
  for (var i = trajectory.length - 1; i >= 0; i--) {
    if ((trajectory[i] - truth).abs() > tol) {
      firstOk = i + 1;
      break;
    }
  }
  if (firstOk >= trajectory.length) return -1;
  return firstOk + 1;
}

/// Residual per-match volatility once a player is already accurate — the
/// "my rating bounces for no reason" complaint.
double stabilityNoise(List<double> trajectory, double truth, {int from = 25}) {
  final deltas = <double>[];
  for (var i = math.max(1, from); i < trajectory.length; i++) {
    if ((trajectory[i - 1] - truth).abs() <= 0.4) {
      deltas.add((trajectory[i] - trajectory[i - 1]).abs());
    }
  }
  return deltas.isEmpty ? 0 : mean(deltas);
}

/// Aggregate a list of per-seed values into mean / p10 / p90.
class Agg {
  final double avg, p10, p50, p90;
  const Agg(this.avg, this.p10, this.p50, this.p90);
  factory Agg.of(List<double> xs) => Agg(
        mean(xs),
        percentile(xs, 0.10),
        percentile(xs, 0.50),
        percentile(xs, 0.90),
      );
  Map<String, dynamic> toJson() => {'avg': avg, 'p10': p10, 'p50': p50, 'p90': p90};
  @override
  String toString() =>
      '${avg.toStringAsFixed(3)} [${p10.toStringAsFixed(3)}–${p90.toStringAsFixed(3)}]';
}

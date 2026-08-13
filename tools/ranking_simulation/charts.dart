// ignore_for_file: avoid_print
/// Minimal, dependency-free SVG chart primitives for the study report.
///
/// Colours are emitted as CSS custom properties (`var(--s1)` …) so the report
/// stylesheet owns the light/dark palettes and the SVG never hard-codes a hex
/// that would break in one theme.
library;

import 'dart:math' as math;

String esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String fmt(num v, [int dp = 2]) => v.toStringAsFixed(dp);

class Series {
  final String name;
  final int slot; // 1..6 → var(--s1)…
  final List<double?> ys;
  final bool dashed;

  /// Copies into a genuine `List<double?>`. Callers routinely pass a
  /// `List<double>`, which is a valid subtype but blows up at runtime the
  /// moment anything here needs a null back out of it.
  Series(String name, int slot, List<double?> ys, {bool dashed = false})
      : this._(name, slot, List<double?>.from(ys), dashed);

  const Series._(this.name, this.slot, this.ys, this.dashed);

  String get color => 'var(--s$slot)';
}

/// Nice axis ticks covering [lo, hi].
({double lo, double hi, List<double> ticks}) niceScale(double lo, double hi, {int target = 5}) {
  if (hi <= lo) hi = lo + 1;
  final raw = (hi - lo) / target;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  final step = (norm <= 1 ? 1 : (norm <= 2 ? 2 : (norm <= 5 ? 5 : 10))) * mag;
  final nlo = (lo / step).floor() * step;
  final nhi = (hi / step).ceil() * step;
  final ticks = <double>[];
  for (var t = nlo; t <= nhi + step * 1e-9; t += step) {
    ticks.add(double.parse(t.toStringAsFixed(10)));
  }
  return (lo: nlo, hi: nhi, ticks: ticks);
}

/// Push right-hand direct labels apart so they never overlap.
List<double> _declutter(List<double> ys, double minGap, double top, double bottom) {
  final idx = List<int>.generate(ys.length, (i) => i)..sort((a, b) => ys[a].compareTo(ys[b]));
  final out = List<double>.from(ys);
  var prev = double.negativeInfinity;
  for (final i in idx) {
    var y = math.max(out[i], prev + minGap);
    y = math.min(y, bottom);
    out[i] = y;
    prev = y;
  }
  // if we ran past the bottom, pull the stack back up
  final overflow = out.reduce(math.max) - bottom;
  if (overflow > 0) {
    for (var i = 0; i < out.length; i++) {
      out[i] = math.max(top, out[i] - overflow);
    }
  }
  return out;
}

/// Multi-series line chart with direct end labels and per-point tooltips.
String lineChart({
  required String id,
  required List<double> xs,
  required List<Series> series,
  required String xLabel,
  required String yLabel,
  double? yMin,
  double? yMax,
  bool logX = false,
  String Function(double)? xTickFmt,
  String Function(double)? yTickFmt,
  int dp = 2,
  double height = 340,
}) {
  const w = 760.0;
  final h = height;
  const padL = 62.0, padR = 148.0, padT = 18.0, padB = 44.0;
  final plotW = w - padL - padR, plotH = h - padT - padB;

  var lo = yMin ?? double.infinity, hi = yMax ?? double.negativeInfinity;
  if (yMin == null || yMax == null) {
    for (final s in series) {
      for (final y in s.ys) {
        if (y == null) continue;
        if (yMin == null && y < lo) lo = y;
        if (yMax == null && y > hi) hi = y;
      }
    }
    if (!lo.isFinite) lo = 0;
    if (!hi.isFinite) hi = 1;
  }
  final sc = niceScale(lo, hi);
  final y0 = yMin ?? sc.lo, y1 = yMax ?? sc.hi;
  final yTicks = (yMin != null && yMax != null) ? niceScale(y0, y1).ticks : sc.ticks;

  double tx(double x) {
    if (!logX) {
      final xa = xs.first, xb = xs.last;
      return padL + (x - xa) / (xb - xa) * plotW;
    }
    final la = math.log(xs.first), lb = math.log(xs.last);
    return padL + (math.log(x) - la) / (lb - la) * plotW;
  }

  double ty(double y) => padT + plotH - (y - y0) / (y1 - y0) * plotH;

  final b = StringBuffer();
  b.writeln('<svg class="chart" viewBox="0 0 ${w.toInt()} ${h.toInt()}" role="img" '
      'aria-labelledby="$id-t" preserveAspectRatio="xMidYMid meet">');
  b.writeln('<title id="$id-t">${esc(yLabel)} against ${esc(xLabel)}</title>');

  // grid + y ticks
  for (final t in yTicks) {
    if (t < y0 - 1e-9 || t > y1 + 1e-9) continue;
    final yy = ty(t);
    b.writeln('<line class="grid" x1="$padL" x2="${padL + plotW}" y1="${fmt(yy, 1)}" y2="${fmt(yy, 1)}"/>');
    b.writeln('<text class="tick" x="${padL - 10}" y="${fmt(yy + 4, 1)}" text-anchor="end">'
        '${esc(yTickFmt != null ? yTickFmt(t) : fmt(t, dp))}</text>');
  }
  // x ticks
  for (final x in xs) {
    final xx = tx(x);
    b.writeln('<text class="tick" x="${fmt(xx, 1)}" y="${fmt(padT + plotH + 22, 1)}" '
        'text-anchor="middle">${esc(xTickFmt != null ? xTickFmt(x) : x.toStringAsFixed(0))}</text>');
  }
  b.writeln('<line class="axis" x1="$padL" x2="${padL + plotW}" '
      'y1="${fmt(padT + plotH, 1)}" y2="${fmt(padT + plotH, 1)}"/>');
  b.writeln('<text class="axis-label" x="${padL + plotW / 2}" y="${h - 6}" '
      'text-anchor="middle">${esc(xLabel)}</text>');
  b.writeln('<text class="axis-label" transform="translate(14 ${padT + plotH / 2}) rotate(-90)" '
      'text-anchor="middle">${esc(yLabel)}</text>');

  // lines
  final endYs = <double>[];
  for (final s in series) {
    final pts = <String>[];
    for (var i = 0; i < xs.length; i++) {
      final y = i < s.ys.length ? s.ys[i] : null;
      if (y == null) continue;
      pts.add('${fmt(tx(xs[i]), 1)},${fmt(ty(y.clamp(y0, y1)), 1)}');
    }
    if (pts.isEmpty) {
      endYs.add(padT + plotH);
      continue;
    }
    b.writeln('<polyline class="line${s.dashed ? ' dashed' : ''}" points="${pts.join(' ')}" '
        'stroke="${s.color}"/>');
    for (var i = 0; i < xs.length; i++) {
      final y = i < s.ys.length ? s.ys[i] : null;
      if (y == null) continue;
      b.writeln('<circle class="dot" cx="${fmt(tx(xs[i]), 1)}" '
          'cy="${fmt(ty(y.clamp(y0, y1)), 1)}" r="4" fill="${s.color}">'
          '<title>${esc(s.name)} — ${esc(xLabel)} ${xs[i].toStringAsFixed(0)}: ${fmt(y, dp)}</title>'
          '</circle>');
    }
    final last = s.ys.lastWhere((e) => e != null, orElse: () => null);
    endYs.add(ty((last ?? y0).clamp(y0, y1)));
  }

  // direct labels
  final placed = _declutter(endYs, 15, padT + 6, padT + plotH);
  for (var i = 0; i < series.length; i++) {
    final s = series[i];
    b.writeln('<line class="leader" x1="${padL + plotW + 4}" x2="${padL + plotW + 12}" '
        'y1="${fmt(endYs[i], 1)}" y2="${fmt(placed[i], 1)}" stroke="${s.color}"/>');
    b.writeln('<text class="serieslabel" x="${padL + plotW + 16}" y="${fmt(placed[i] + 4, 1)}" '
        'fill="${s.color}">${esc(s.name)}</text>');
  }
  b.writeln('</svg>');
  return b.toString();
}

/// Small-multiple scatter of true skill (x) against estimated rating (y).
String scatterPanel({
  required String id,
  required String caption,
  required List<List<double>> points, // [ [true, est], … ]
  int slot = 1,
  double lo = 0,
  double hi = 7,
}) {
  const w = 230.0, h = 230.0;
  const pad = 30.0;
  final plot = w - pad - 10;
  double tx(double v) => pad + (v - lo) / (hi - lo) * plot;
  double ty(double v) => h - pad - (v.clamp(lo, hi) - lo) / (hi - lo) * plot;

  final b = StringBuffer();
  b.writeln('<figure class="scatter"><svg class="chart" viewBox="0 0 ${w.toInt()} ${h.toInt()}" '
      'role="img" aria-labelledby="$id-t"><title id="$id-t">${esc(caption)}</title>');
  for (var g = 1; g <= 6; g++) {
    final v = lo + (hi - lo) * g / 7;
    b.writeln('<line class="grid" x1="${fmt(tx(v), 1)}" x2="${fmt(tx(v), 1)}" '
        'y1="${fmt(ty(hi), 1)}" y2="${fmt(ty(lo), 1)}"/>');
    b.writeln('<line class="grid" x1="${fmt(tx(lo), 1)}" x2="${fmt(tx(hi), 1)}" '
        'y1="${fmt(ty(v), 1)}" y2="${fmt(ty(v), 1)}"/>');
  }
  b.writeln('<line class="ideal" x1="${fmt(tx(lo), 1)}" y1="${fmt(ty(lo), 1)}" '
      'x2="${fmt(tx(hi), 1)}" y2="${fmt(ty(hi), 1)}"/>');
  for (final p in points) {
    b.writeln('<circle class="pt" cx="${fmt(tx(p[0]), 1)}" cy="${fmt(ty(p[1]), 1)}" r="2.1" '
        'fill="var(--s$slot)"/>');
  }
  b.writeln('<line class="axis" x1="${fmt(tx(lo), 1)}" y1="${fmt(ty(lo), 1)}" '
      'x2="${fmt(tx(hi), 1)}" y2="${fmt(ty(lo), 1)}"/>');
  b.writeln('<line class="axis" x1="${fmt(tx(lo), 1)}" y1="${fmt(ty(lo), 1)}" '
      'x2="${fmt(tx(lo), 1)}" y2="${fmt(ty(hi), 1)}"/>');
  for (final t in [0, 2, 4, 6]) {
    b.writeln('<text class="tick sm" x="${fmt(tx(t.toDouble()), 1)}" y="${h - pad + 14}" '
        'text-anchor="middle">$t</text>');
    b.writeln('<text class="tick sm" x="${pad - 6}" y="${fmt(ty(t.toDouble()) + 3, 1)}" '
        'text-anchor="end">$t</text>');
  }
  b.writeln('</svg><figcaption>${esc(caption)}</figcaption></figure>');
  return b.toString();
}

/// Overlaid distributions: true skill (outline) vs estimated rating (filled).
String histogram({
  required String id,
  required String caption,
  required List<double> truth,
  required List<double> est,
  int slot = 1,
  double lo = 0,
  double hi = 7,
  int bins = 28,
}) {
  const w = 380.0, h = 210.0;
  const padL = 34.0, padB = 30.0, padT = 12.0, padR = 8.0;
  final plotW = w - padL - padR, plotH = h - padT - padB;
  final bw = (hi - lo) / bins;

  List<int> hist(List<double> xs) {
    final c = List<int>.filled(bins, 0);
    for (final x in xs) {
      final i = ((x - lo) / bw).floor().clamp(0, bins - 1);
      c[i]++;
    }
    return c;
  }

  final ht = hist(truth), he = hist(est);
  final maxC = math.max(ht.reduce(math.max), he.reduce(math.max)).toDouble();

  double bx(int i) => padL + i / bins * plotW;
  double by(int c) => padT + plotH - (c / maxC) * plotH;

  final b = StringBuffer();
  b.writeln('<figure class="hist"><svg class="chart" viewBox="0 0 ${w.toInt()} ${h.toInt()}" '
      'role="img" aria-labelledby="$id-t"><title id="$id-t">${esc(caption)}</title>');
  for (var i = 0; i < bins; i++) {
    if (he[i] == 0) continue;
    b.writeln('<rect class="bar" x="${fmt(bx(i) + 0.8, 1)}" y="${fmt(by(he[i]), 1)}" '
        'width="${fmt(plotW / bins - 1.6, 1)}" height="${fmt(padT + plotH - by(he[i]), 1)}" '
        'rx="2" fill="var(--s$slot)"><title>rating ${fmt(lo + i * bw, 1)}–${fmt(lo + (i + 1) * bw, 1)}: '
        '${he[i]} players</title></rect>');
  }
  final pts = <String>[];
  for (var i = 0; i < bins; i++) {
    pts.add('${fmt(bx(i), 1)},${fmt(by(ht[i]), 1)}');
    pts.add('${fmt(bx(i + 1), 1)},${fmt(by(ht[i]), 1)}');
  }
  b.writeln('<polyline class="truthline" points="${pts.join(' ')}"/>');
  b.writeln('<line class="axis" x1="$padL" x2="${padL + plotW}" '
      'y1="${fmt(padT + plotH, 1)}" y2="${fmt(padT + plotH, 1)}"/>');
  for (final t in [0, 1, 2, 3, 4, 5, 6, 7]) {
    b.writeln('<text class="tick sm" x="${fmt(padL + (t - lo) / (hi - lo) * plotW, 1)}" '
        'y="${h - padB + 16}" text-anchor="middle">$t</text>');
  }
  b.writeln('<text class="axis-label sm" x="${padL + plotW / 2}" y="${h - 4}" '
      'text-anchor="middle">rating / true level</text>');
  b.writeln('</svg><figcaption>${esc(caption)}</figcaption></figure>');
  return b.toString();
}

/// Horizontal grouped bars — one row per category, one bar per group.
String barChart({
  required String id,
  required String title,
  required List<String> rows,
  required List<({String name, int slot, List<double> vs})> groups,
  required String unit,
  double? refLine,
  String refLabel = '',
  int dp = 2,
  double? maxOverride,
}) {
  final n = rows.length;
  final g = groups.length;
  const w = 760.0;
  const padL = 210.0, padR = 74.0, padT = 14.0, padB = 34.0;
  const rowH = 26.0;
  final barH = math.max(7.0, (rowH - 8) / g);
  final h = padT + padB + n * rowH * (g > 2 ? 1.28 : 1.0);
  final rowStep = (h - padT - padB) / n;
  final plotW = w - padL - padR;

  var maxV = maxOverride ?? 0.0;
  if (maxOverride == null) {
    for (final gr in groups) {
      for (final v in gr.vs) {
        if (v.abs() > maxV) maxV = v.abs();
      }
    }
    if (refLine != null && refLine.abs() > maxV) maxV = refLine.abs();
    maxV *= 1.12;
  }
  if (maxV <= 0) maxV = 1;

  final b = StringBuffer();
  b.writeln('<svg class="chart" viewBox="0 0 ${w.toInt()} ${h.toStringAsFixed(0)}" role="img" '
      'aria-labelledby="$id-t"><title id="$id-t">${esc(title)}</title>');
  if (refLine != null) {
    final x = padL + (refLine / maxV) * plotW;
    b.writeln('<line class="ref" x1="${fmt(x, 1)}" x2="${fmt(x, 1)}" y1="$padT" '
        'y2="${fmt(h - padB, 1)}"/>');
    b.writeln('<text class="tick sm" x="${fmt(x, 1)}" y="${fmt(h - padB + 22, 1)}" '
        'text-anchor="middle">${esc(refLabel)}</text>');
  }
  for (var i = 0; i < n; i++) {
    final yTop = padT + i * rowStep;
    b.writeln('<text class="rowlabel" x="${padL - 10}" y="${fmt(yTop + rowStep / 2 + 4, 1)}" '
        'text-anchor="end">${esc(rows[i])}</text>');
    for (var j = 0; j < g; j++) {
      final v = i < groups[j].vs.length ? groups[j].vs[i] : 0.0;
      final len = (v.abs() / maxV) * plotW;
      final y = yTop + (rowStep - g * (barH + 2)) / 2 + j * (barH + 2);
      b.writeln('<rect class="bar" x="$padL" y="${fmt(y, 1)}" width="${fmt(math.max(len, 1), 1)}" '
          'height="${fmt(barH, 1)}" rx="3" fill="var(--s${groups[j].slot})">'
          '<title>${esc(groups[j].name)} — ${esc(rows[i])}: ${fmt(v, dp)}$unit</title></rect>');
      b.writeln('<text class="barval" x="${fmt(padL + math.max(len, 1) + 6, 1)}" '
          'y="${fmt(y + barH - 1, 1)}">${fmt(v, dp)}</text>');
    }
  }
  b.writeln('<line class="axis" x1="$padL" x2="$padL" y1="$padT" y2="${fmt(h - padB, 1)}"/>');
  b.writeln('</svg>');
  return b.toString();
}

/// Reliability diagram: predicted vs observed win rate for the favourite.
String calibrationChart({
  required String id,
  required List<({String name, int slot, List<List<double>> pts})> series,
}) {
  const w = 420.0, h = 340.0;
  const pad = 52.0;
  final plot = w - pad - 24;
  final plotH = h - pad - 24;
  double tx(double v) => pad + (v - 0.5) / 0.5 * plot;
  double ty(double v) => h - pad - (v - 0.5) / 0.5 * plotH;

  final b = StringBuffer();
  b.writeln('<svg class="chart" viewBox="0 0 ${w.toInt()} ${h.toInt()}" role="img" '
      'aria-labelledby="$id-t"><title id="$id-t">Probability calibration</title>');
  for (final t in [0.6, 0.7, 0.8, 0.9, 1.0]) {
    b.writeln('<line class="grid" x1="${fmt(tx(t), 1)}" x2="${fmt(tx(t), 1)}" '
        'y1="${fmt(ty(1.0), 1)}" y2="${fmt(ty(0.5), 1)}"/>');
    b.writeln('<line class="grid" x1="${fmt(tx(0.5), 1)}" x2="${fmt(tx(1.0), 1)}" '
        'y1="${fmt(ty(t), 1)}" y2="${fmt(ty(t), 1)}"/>');
    b.writeln('<text class="tick sm" x="${fmt(tx(t), 1)}" y="${h - pad + 18}" '
        'text-anchor="middle">${(t * 100).round()}%</text>');
    b.writeln('<text class="tick sm" x="${pad - 8}" y="${fmt(ty(t) + 3, 1)}" '
        'text-anchor="end">${(t * 100).round()}%</text>');
  }
  b.writeln('<line class="ideal" x1="${fmt(tx(0.5), 1)}" y1="${fmt(ty(0.5), 1)}" '
      'x2="${fmt(tx(1.0), 1)}" y2="${fmt(ty(1.0), 1)}"/>');
  for (final s in series) {
    final pts = [for (final p in s.pts) '${fmt(tx(p[0]), 1)},${fmt(ty(p[1].clamp(0.5, 1.0)), 1)}'];
    if (pts.isEmpty) continue;
    b.writeln('<polyline class="line" points="${pts.join(' ')}" stroke="var(--s${s.slot})"/>');
    for (final p in s.pts) {
      b.writeln('<circle class="dot" cx="${fmt(tx(p[0]), 1)}" '
          'cy="${fmt(ty(p[1].clamp(0.5, 1.0)), 1)}" r="4" fill="var(--s${s.slot})">'
          '<title>${esc(s.name)} — predicted ${(p[0] * 100).toStringAsFixed(0)}%, '
          'actual ${(p[1] * 100).toStringAsFixed(0)}%</title></circle>');
    }
  }
  b.writeln('<line class="axis" x1="${fmt(tx(0.5), 1)}" y1="${fmt(ty(0.5), 1)}" '
      'x2="${fmt(tx(1.0), 1)}" y2="${fmt(ty(0.5), 1)}"/>');
  b.writeln('<text class="axis-label sm" x="${pad + plot / 2}" y="${h - 8}" '
      'text-anchor="middle">predicted win probability</text>');
  b.writeln('<text class="axis-label sm" transform="translate(13 ${24 + plotH / 2}) rotate(-90)" '
      'text-anchor="middle">observed win rate</text>');
  b.writeln('</svg>');
  return b.toString();
}

/// A legend chip row — identity is never colour-alone.
String legend(List<({String name, int slot})> items) {
  final b = StringBuffer('<ul class="legend">');
  for (final i in items) {
    b.write('<li><span class="swatch" style="background:var(--s${i.slot})"></span>'
        '${esc(i.name)}</li>');
  }
  b.write('</ul>');
  return b.toString();
}

/// Data table — also the accessible fallback for every chart.
String table(List<String> head, List<List<String>> rows, {String? cls, int? emphRow}) {
  final b = StringBuffer('<div class="tablewrap"><table${cls != null ? ' class="$cls"' : ''}>');
  b.write('<thead><tr>');
  for (var i = 0; i < head.length; i++) {
    b.write('<th${i == 0 ? '' : ' class="num"'}>${esc(head[i])}</th>');
  }
  b.write('</tr></thead><tbody>');
  for (var r = 0; r < rows.length; r++) {
    b.write('<tr${emphRow == r ? ' class="emph"' : ''}>');
    for (var i = 0; i < rows[r].length; i++) {
      b.write(i == 0
          ? '<th scope="row">${rows[r][i]}</th>'
          : '<td class="num">${rows[r][i]}</td>');
    }
    b.write('</tr>');
  }
  b.write('</tbody></table></div>');
  return b.toString();
}

// ignore_for_file: avoid_print
/// Builds the Ranking Lab into ONE self-contained HTML file.
///
///   dart run tools/ranking_simulation/ui/build.dart
///   → tools/ranking_simulation/results/ranking_lab.html
///
/// Steps: compile the kernel with dart2js, check the compiled JavaScript agrees
/// with the Dart VM to the last digit, then inline everything (no external
/// requests — the page works offline, from a file:// URL, and inside a strict
/// CSP).
library;

import 'dart:convert';
import 'dart:io';

import 'lab_kernel.dart';

const _dir = 'tools/ranking_simulation/ui';
const _out = 'tools/ranking_simulation/results/ranking_lab.html';

/// Requests exercised by the parity gate. They deliberately cover the RNG, all
/// four engine families, the population path and the metric layer — a 32-bit
/// slip in any of them shows up as a mismatched digit here.
const _parityProbes = <String>[
  // Tier 1 — must be EXACT (see [_firstDifference]).
  '{"op":"rng.probe"}',
  // Tier 2 — compared to a relative 1e-9.
  '{"op":"solo.run","seed":482901,"trueSkill":5.5,"matches":12,'
      '"engines":[{"id":"v2"},{"id":"v3"},{"id":"trueskill"},{"id":"glicko"}]}',
  '{"op":"solo.run","seed":7,"trueSkill":1.5,"matches":8,"pool":"fresh",'
      '"engines":[{"id":"tuned"},{"id":"trueskill_set"}]}',
  '{"op":"population.run","seed":3,"players":120,"matches":8,'
      '"engines":[{"id":"v2"},{"id":"v3"}]}',
  '{"op":"sweep","param":"prior","values":[2.0,3.3],"seeds":2,"players":80,"matches":6}',
  '{"op":"boost","seed":11,"weakSkill":2.5,"partnerSkill":5.0,"matches":10,'
      '"engines":[{"id":"v3"}]}',
  '{"op":"score.compare","scores":["6-0,6-0","7-6,7-6"],"engines":[{"id":"v2"}]}',
];

Future<void> main(List<String> args) async {
  final root = Directory.current.path;
  if (!File('$_dir/lab_main.dart').existsSync()) {
    stderr.writeln('Run this from the repo root ($root looks wrong).');
    exit(1);
  }

  print('· compiling kernel (dart2js)');
  final compile = await Process.run(
    'dart',
    ['compile', 'js', '-O2', '-o', '$_dir/lab_kernel.js', '$_dir/lab_main.dart'],
  );
  if (compile.exitCode != 0) {
    stderr.writeln(compile.stdout);
    stderr.writeln(compile.stderr);
    exit(compile.exitCode);
  }
  final kernel = File('$_dir/lab_kernel.js').readAsStringSync();
  print('  ${(kernel.length / 1024).round()} KB of JavaScript');

  if (!args.contains('--skip-parity')) {
    await _parityCheck();
  }

  final css = File('$_dir/lab.css').readAsStringSync();
  final markup = File('$_dir/lab.html').readAsStringSync();
  final app = File('$_dir/lab.js').readAsStringSync();

  // dart2js emits code that expects a browser-ish `self`; harmless in a page,
  // required when the same bundle is run under node for the parity check.
  final page = StringBuffer()
    ..writeln('<style>$css</style>')
    ..writeln(markup)
    ..writeln('<script>$kernel</script>')
    ..writeln('<script>$app</script>');

  final outFile = File(_out)..createSync(recursive: true);
  outFile.writeAsStringSync(page.toString());
  print('· wrote $_out (${(outFile.lengthSync() / 1024).round()} KB, self-contained)');
}

/// The lab is only trustworthy if the browser build agrees with the VM build.
/// dart2js represents `int` as a double, so anything doing 32-bit arithmetic
/// (the RNG) or relying on integer overflow can diverge silently — which would
/// mean a seed names two different runs depending on where you ran it.
Future<void> _parityCheck() async {
  final node = await Process.run('node', ['--version']);
  if (node.exitCode != 0) {
    print('· parity check SKIPPED (node not found) — run with node installed '
        'before trusting the browser build');
    return;
  }

  final tmp = Directory.systemTemp.createTempSync('ranklab');
  try {
    const sep = '@@RANKLAB-PARITY@@';
    final runner = File('${tmp.path}/parity.js');
    runner.writeAsStringSync([
      'globalThis.self=globalThis;',
      File('$_dir/lab_kernel.js').readAsStringSync(),
      'const probes=${jsonEncode(_parityProbes)};',
      'process.stdout.write(probes.map((p)=>globalThis.rankLab(p)).join("$sep"));',
    ].join('\n'));

    // Decode as UTF-8 explicitly: the default is the system codepage, which on
    // Windows turns every '·' in an engine name into mojibake and reports a
    // difference that does not exist.
    final res = await Process.run('node', [runner.path],
        stdoutEncoding: utf8, stderrEncoding: utf8);
    if (res.exitCode != 0) {
      stderr.writeln(res.stderr);
      throw StateError('node could not run the compiled kernel');
    }
    final fromJs = (res.stdout as String).split(sep);
    final fromVm = [for (final p in _parityProbes) handleRequest(p)];

    var bad = 0;
    for (var i = 0; i < fromVm.length; i++) {
      if (i >= fromJs.length) {
        bad++;
        stderr.writeln('  x probe $i produced no JavaScript output');
        continue;
      }
      // Compare the DECODED structures, not the strings: Dart serialises a
      // whole double as `2.0` and JavaScript as `2`. That is a printing
      // convention rather than a different number, and comparing raw text would
      // fail the build over it while burying any real difference in the noise.
      final diff = _firstDifference(jsonDecode(fromVm[i]), jsonDecode(fromJs[i]), 'root');
      if (diff != null) {
        bad++;
        stderr.writeln('  x probe $i differs between the VM and JavaScript');
        stderr.writeln('    request: ${_parityProbes[i]}');
        stderr.writeln('    $diff');
      }
    }
    if (bad > 0) {
      stderr.writeln('· PARITY FAILED — the browser would show different numbers '
          'from the study and the tests. Not writing the page.');
      exit(2);
    }
    final probe = (jsonDecode(fromVm[0]) as Map)['draws'] as Map;
    final drawCount = probe.values.fold<int>(0, (n, v) => n + (v as List).length);
    print('· parity OK — ${_parityProbes.length} probes agree; $drawCount RNG '
        'draws across ${probe.length} seeds bit-identical');
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

/// Walks two decoded JSON trees and describes the first place they disagree.
///
/// The tolerance is deliberately split in two. Integers, booleans, strings and
/// the RNG probe — which reports its draws AS STRINGS for exactly this reason —
/// must match exactly: those decide which matches happen, who won them, and
/// what the production-mirror engine did, and one differing bit there sends the
/// entire run somewhere else. Ordinary doubles get a relative 1e-9, because
/// `sqrt`, `exp` and `pow` are not bit-identical between the Dart VM and V8.
/// TrueSkill and Glicko lean on all three, so demanding the last bit would fail
/// every build over a difference nobody can observe.
String? _firstDifference(Object? a, Object? b, String path) {
  if (a is Map && b is Map) {
    for (final k in a.keys) {
      if (!b.containsKey(k)) return '$path.$k missing in JavaScript';
      final d = _firstDifference(a[k], b[k], '$path.$k');
      if (d != null) return d;
    }
    for (final k in b.keys) {
      if (!a.containsKey(k)) return '$path.$k missing on the VM';
    }
    return null;
  }
  if (a is List && b is List) {
    if (a.length != b.length) {
      return '$path length ${a.length} on the VM, ${b.length} in JavaScript';
    }
    for (var i = 0; i < a.length; i++) {
      final d = _firstDifference(a[i], b[i], '$path[$i]');
      if (d != null) return d;
    }
    return null;
  }
  if (a is num && b is num) {
    if (a is int && b is int) {
      return a == b ? null : '$path is $a on the VM, $b in JavaScript';
    }
    final x = a.toDouble(), y = b.toDouble();
    if (x == y) return null;
    final scale = x.abs() > y.abs() ? x.abs() : y.abs();
    final rel = scale == 0 ? (x - y).abs() : (x - y).abs() / scale;
    return rel <= 1e-9
        ? null
        : '$path is $a on the VM, $b in JavaScript '
            '(relative ${rel.toStringAsExponential(1)})';
  }
  return a == b ? null : '$path is "$a" on the VM, "$b" in JavaScript';
}

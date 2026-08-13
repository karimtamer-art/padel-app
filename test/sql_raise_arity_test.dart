/// Static check on PL/pgSQL `RAISE` statements across the Supabase SQL.
///
/// **Why this exists.** There is no Postgres in this test environment, so
/// nothing compiles the PL/pgSQL before it is pasted into the SQL editor
/// against a live database. A `RAISE` whose placeholder count doesn't match its
/// argument count is a *compile* error (`42601: too many parameters specified
/// for RAISE`) — it does not fire when the branch runs, it refuses to create
/// the block at all. So a broken RAISE inside a verification block takes down
/// the whole delta, and it takes it down on live, mid-migration.
///
/// That happened on 2026-08-14: a pre-flight check meant to make a dependency
/// failure *clearer* used `%%` (a literal percent) while passing two
/// arguments, and killed the delta it was supposed to protect.
///
/// The rules this encodes, from the PL/pgSQL manual:
///   * `%`  consumes one expression argument
///   * `%%` emits a literal percent and consumes nothing
///   * arguments are the comma-separated expressions after the format string,
///     stopping at `USING`, which introduces named options instead
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One RAISE found in a file.
class _Raise {
  final String file;
  final int line;
  final String text;
  _Raise(this.file, this.line, this.text);
}

/// Strips `--` comments, respecting single-quoted strings and `$$` bodies.
String _stripLineComments(String sql) {
  final out = StringBuffer();
  var inStr = false;
  for (var i = 0; i < sql.length; i++) {
    final c = sql[i];
    if (inStr) {
      out.write(c);
      if (c == "'") {
        // '' inside a string is an escaped quote, not a terminator
        if (i + 1 < sql.length && sql[i + 1] == "'") {
          out.write(sql[++i]);
        } else {
          inStr = false;
        }
      }
      continue;
    }
    if (c == "'") {
      inStr = true;
      out.write(c);
      continue;
    }
    if (c == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
      while (i < sql.length && sql[i] != '\n') {
        i++;
      }
      out.write('\n');
      continue;
    }
    out.write(c);
  }
  return out.toString();
}

/// Every `raise ...;` statement in [sql], comments already removed.
List<_Raise> _findRaises(String file, String sql) {
  final found = <_Raise>[];
  final re = RegExp(r'\braise\s+(exception|notice|warning|info|log|debug)\b',
      caseSensitive: false);
  for (final m in re.allMatches(sql)) {
    // walk to the terminating ';' that is not inside a string
    var i = m.end;
    var inStr = false;
    while (i < sql.length) {
      final c = sql[i];
      if (inStr) {
        if (c == "'") {
          if (i + 1 < sql.length && sql[i + 1] == "'") {
            i++;
          } else {
            inStr = false;
          }
        }
      } else if (c == "'") {
        inStr = true;
      } else if (c == ';') {
        break;
      }
      i++;
    }
    final line = '\n'.allMatches(sql.substring(0, m.start)).length + 1;
    found.add(_Raise(file, line, sql.substring(m.start, i)));
  }
  return found;
}

/// (placeholders, arguments) for one RAISE, or null if it has no format string
/// (e.g. `raise exception using message = ...`, or a bare `raise;`).
(int, int)? _arity(String raise) {
  final firstQuote = raise.indexOf("'");
  if (firstQuote < 0) return null;

  // The format string is one or more adjacent string literals; SQL concatenates
  // literals separated only by whitespace/newlines.
  var i = firstQuote;
  final fmt = StringBuffer();
  while (i < raise.length && raise[i] == "'") {
    i++; // opening quote
    while (i < raise.length) {
      if (raise[i] == "'") {
        if (i + 1 < raise.length && raise[i + 1] == "'") {
          fmt.write("''");
          i += 2;
          continue;
        }
        i++; // closing quote
        break;
      }
      fmt.write(raise[i]);
      i++;
    }
    // skip whitespace to see whether another literal continues the format
    final j = i;
    while (i < raise.length && raise[i].trim().isEmpty) {
      i++;
    }
    if (i >= raise.length || raise[i] != "'") {
      i = j;
      break;
    }
  }

  // placeholders: % not part of %%
  final f = fmt.toString();
  var placeholders = 0;
  for (var k = 0; k < f.length; k++) {
    if (f[k] != '%') continue;
    if (k + 1 < f.length && f[k + 1] == '%') {
      k++; // literal percent, consumes nothing
      continue;
    }
    placeholders++;
  }

  // arguments: top-level commas after the format string, stopping at USING
  final rest = raise.substring(i);
  var depth = 0, args = 0, inStr = false;
  var counting = rest.trimLeft().startsWith(',');
  for (var k = 0; k < rest.length; k++) {
    final c = rest[k];
    if (inStr) {
      if (c == "'") {
        if (k + 1 < rest.length && rest[k + 1] == "'") {
          k++;
        } else {
          inStr = false;
        }
      }
      continue;
    }
    if (c == "'") {
      inStr = true;
      continue;
    }
    if (c == '(') depth++;
    if (c == ')') depth--;
    if (depth == 0) {
      // `using` ends the argument list and starts named options
      if (RegExp(r'^\busing\b', caseSensitive: false)
          .hasMatch(rest.substring(k).trimLeft())
          && (k == 0 || RegExp(r'\s').hasMatch(rest[k - 1]))) {
        break;
      }
      if (c == ',') {
        args++;
        counting = true;
      }
    }
  }
  if (!counting) args = 0;
  return (placeholders, args);
}

void main() {
  final files = <String>[
    'supabase/migration_player_app.sql',
    ...Directory('supabase/changes')
        .listSync()
        .whereType<File>()
        .map((f) => f.path)
        .where((p) => p.endsWith('.sql')),
  ];

  test('every RAISE has as many arguments as it has % placeholders', () {
    final problems = <String>[];
    var checked = 0;

    for (final path in files) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final sql = _stripLineComments(f.readAsStringSync());
      for (final r in _findRaises(path, sql)) {
        final a = _arity(r.text);
        if (a == null) continue;
        checked++;
        final (placeholders, args) = a;
        if (placeholders != args) {
          final snippet = r.text.replaceAll(RegExp(r'\s+'), ' ');
          problems.add('${r.file}:${r.line} — $placeholders placeholder(s) but '
              '$args argument(s):\n    '
              '${snippet.length > 160 ? '${snippet.substring(0, 160)}…' : snippet}');
        }
      }
    }

    expect(checked, greaterThan(10),
        reason: 'the scanner found almost no RAISE statements — it is probably '
            'broken, which would make this test pass vacuously');

    expect(problems, isEmpty,
        reason: 'PL/pgSQL refuses to COMPILE these, so the whole delta fails on '
            'live rather than just the branch:\n\n${problems.join('\n\n')}\n');
  });

  test('the scanner actually catches a mismatch', () {
    // Mutation check — a linter that cannot fail is worse than none. This is
    // the exact shape of the 2026-08-14 bug: %% is a literal percent, so the
    // format string below has ONE placeholder and TWO arguments.
    const bad = r"""raise exception
      'views depend on this: %. Inspect with '
      '`select pg_get_viewdef(''%%'', true)`.',
      v_dep, v_dep;""";
    final a = _arity(bad);
    expect(a, isNotNull);
    expect(a!.$1, 1, reason: '%% must not count as a placeholder');
    expect(a.$2, 2);
    expect(a.$1 == a.$2, isFalse);
  });

  test('the scanner does not flag valid shapes', () {
    for (final ok in <String>[
      r"raise notice 'plain message with no arguments';",
      r"raise exception 'one: %', v_a;",
      r"raise notice 'two: % and %', v_a, v_b;",
      r"raise notice 'literal 100%% done';",
      r"raise notice 'call: %', (select count(*) from public.profiles);",
      r"raise exception 'quoted ''thing'' and %', v_a;",
      r"raise exception 'with hint: %', v_a using hint = 'do the thing, x, y';",
      r"raise notice 'split '  'across literals: %', v_a;",
    ]) {
      final a = _arity(ok);
      expect(a, isNotNull, reason: ok);
      expect(a!.$1, a.$2, reason: 'false positive on: $ok');
    }
  });
}

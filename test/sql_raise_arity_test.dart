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

/// Reads a file with line endings normalised.
///
/// git's autocrlf rewrites checked-out files with CRLF on Windows, and it does
/// not do so uniformly — a file just restored by `git checkout` gets CRLF
/// while one written by the tooling still has LF. Comparing two SQL bodies
/// byte-for-byte then reports a difference that is not there. Everything here
/// compares CONTENT, so line endings are stripped on the way in.
String readSql(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

/// The dollar-quoted body of the function definition starting at [start].
///
/// Not `indexOf('end $$;')` — `language sql` functions close with a bare `$$;`
/// and that scan runs past them into the next function.
String bodyAt(String sql, int start) {
  final open = sql.indexOf(r'$$', start);
  if (open < 0) return '';
  final close = sql.indexOf(r'$$', open + 2);
  return sql.substring(start, close < 0 ? sql.length : close);
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
      final sql = _stripLineComments(readSql(f.path));
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

  // ── grants must follow the definition they name ──────────────────────────
  //
  // Two ways this breaks, both hit on 2026-08-14:
  //
  //  * Removing a superseded `create or replace` definition leaves its GRANT
  //    behind. On a fresh database the grant then runs before anything has
  //    defined the function and fails with "function does not exist".
  //  * Changing a function's SIGNATURE does not replace it — Postgres creates
  //    an OVERLOAD. The old grant then names a signature that should no longer
  //    exist, and PostgREST is left with two candidates for one RPC name,
  //    which it refuses to resolve ("could not choose the best candidate
  //    function"). That breaks the RPC for every client, not just old ones.
  //
  // Neither is visible without a Postgres to run against, so it is checked
  // statically: every granted function must be defined earlier in the file.
  test('every grant execute names a function defined earlier in the file', () {
    final problems = <String>[];
    for (final path in files) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final sql = _stripLineComments(readSql(f.path));

      final defs = <String, List<int>>{};
      for (final m in RegExp(r'create (?:or replace )?function (public\.\w+)\(')
          .allMatches(sql)) {
        defs.putIfAbsent(m.group(1)!, () => []).add(m.start);
      }
      for (final m
          in RegExp(r'grant execute on function (public\.\w+)\(').allMatches(sql)) {
        final name = m.group(1)!;
        final line = '\n'.allMatches(sql.substring(0, m.start)).length + 1;
        final where = defs[name];
        if (where == null) {
          // a delta may grant on a function defined in the canonical migration
          if (path.contains('changes')) continue;
          problems.add('$path:$line — grants $name, which is never defined');
        } else if (m.start < where.reduce((a, b) => a < b ? a : b)) {
          problems.add('$path:$line — grants $name before it is defined '
              '(orphaned by a removed definition?)');
        }
      }
    }
    expect(problems, isEmpty, reason: '\n${problems.join('\n')}\n');
  });

  test('no NEW duplicate function definitions creep in', () {
    // migration_player_app.sql has always grown by appending another
    // `create or replace` when a feature changed a function, so the file
    // carries a number of superseded bodies. They are dead — a later
    // definition wins — right up until someone reorders the file or extracts
    // the wrong copy, at which point a stale body silently becomes live.
    //
    // That bit four times during the V3-F5 work: _settle_rating (twice),
    // apply_rating_decay, join_match, create_match, finalize_tournament and
    // admin_set_rating all had stale copies, one of which still contained the
    // rating decay that had supposedly been removed.
    //
    // Cleaning up all of the remaining ones is its own change. This is a
    // RATCHET: the known set is pinned, so new duplicates fail. Shrinking this
    // list is always welcome; growing it means adding a landmine.
    const knownDuplicates = <String>{
      'public._access_ids',
      'public._finance_core',
      'public.apply_rating_decay',
      'public.cancel_match',
      'public.community_channel_list',
      'public.dm_inbox',
      'public.get_or_create_conversation',
      'public.leave_match',
      'public.mark_community_read',
      'public.mm_accept',
      'public.mm_candidates',
      'public.mm_player_sees_match',
      'public.notify_match_join',
      'public.tg_event_channel',
      'public.ticket_roster'
    };

    final sql = _stripLineComments(
        readSql('supabase/migration_player_app.sql'));
    final counts = <String, int>{};
    for (final m in RegExp(r'create or replace function (public\.\w+)\(')
        .allMatches(sql)) {
      counts.update(m.group(1)!, (v) => v + 1, ifAbsent: () => 1);
    }
    final dupes = counts.entries
        .where((e) => e.value > 1)
        .map((e) => e.key)
        .toSet();

    expect(dupes.difference(knownDuplicates), isEmpty,
        reason: 'new duplicate definition(s) — a later create-or-replace will '
            'shadow the earlier body, which is how a stale copy goes live');
    // and if one gets cleaned up, tighten the list rather than leaving it stale
    expect(knownDuplicates.difference(dupes), isEmpty,
        reason: 'these are no longer duplicated — remove them from '
            'knownDuplicates so the ratchet keeps ratcheting');
  });

  // ── every column the client writes must be granted ───────────────────────
  //
  // migrations/0004 revoked blanket UPDATE on profiles and granted back an
  // explicit list of user-editable columns. That is a good design — it is why
  // a client cannot write `rating` or `is_admin`. Its failure mode is that a
  // column added LATER never joins the list, and the write then fails with a
  // permission error that a fire-and-forget call swallows.
  //
  // That is exactly what happened to notify_push / notify_match /
  // notify_tournament / notify_order, added 2026-07-02: for six weeks a
  // player could not turn push notifications off, and nothing surfaced it.
  //
  // So: find every literal column the Dart writes straight to `profiles`, and
  // require a matching grant.
  test('columns the app writes to profiles are granted to authenticated', () {
    final sql = _stripLineComments(
        readSql('supabase/migration_player_app.sql'));

    final granted = <String>{};
    for (final m in RegExp(
            r'grant\s+update\s*\(([^)]*)\)\s*\n?\s*on public\.profiles\s+to\s+authenticated',
            caseSensitive: false)
        .allMatches(sql)) {
      for (final c in m.group(1)!.split(',')) {
        granted.add(c.trim());
      }
    }
    expect(granted, isNotEmpty,
        reason: 'found no column grants at all — the scanner is broken, which '
            'would make this test pass vacuously');

    // Literal `.from('profiles') … .update({'col': …})` writes in lib/.
    final written = <String, String>{}; // column -> where
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final src = readSql(f.path);
      for (final m
          in RegExp(r"from\('profiles'\)([\s\S]{0,400}?);").allMatches(src)) {
        final chunk = m.group(1)!;
        if (!chunk.contains('.update(')) continue;
        final upd = chunk.substring(chunk.indexOf('.update('));
        for (final k in RegExp(r"'(\w+)'\s*:").allMatches(upd)) {
          written[k.group(1)!] = f.path;
        }
      }
    }

    final ungranted = written.entries
        .where((e) => !granted.contains(e.key))
        .map((e) => '${e.key} (written in ${e.value})')
        .toList();

    expect(ungranted, isEmpty,
        reason: 'these writes will be REFUSED by Postgres, and a '
            'fire-and-forget call will hide it. Either grant the column, or '
            'route the write through a SECURITY DEFINER RPC (which is the '
            'right answer for anything in the ranking block):\n'
            '  ${ungranted.join('\n  ')}\n');
  });

  test('the ranking and privilege columns stay closed to clients', () {
    // The anti-cheat boundary, as a test. Rating changes happen only in
    // Postgres; if one of these ever appears in a client grant, that is the
    // bug — no matter how convenient it looked at the time.
    const mustNeverBeGranted = <String>[
      'rating', 'sigma', 'level', 'tier', 'is_anchor', 'competitive_matches',
      'placement_played', 'placement_revealed', 'is_provisional', 'reliability',
      'is_admin', 'admin_role', 'admin_access', 'admin_scope', 'is_owner',
      'status',
    ];
    final sql = _stripLineComments(
        readSql('supabase/migration_player_app.sql'));
    final granted = <String>{};
    for (final m in RegExp(
            r'grant\s+update\s*\(([^)]*)\)\s*\n?\s*on public\.profiles\s+to\s+authenticated',
            caseSensitive: false)
        .allMatches(sql)) {
      for (final c in m.group(1)!.split(',')) {
        granted.add(c.trim());
      }
    }
    for (final c in mustNeverBeGranted) {
      expect(granted.contains(c), isFalse,
          reason: '$c is writable by a client — that is the anti-cheat '
              'boundary in CLAUDE.md rule #2');
    }
  });

  // ── a delta that verifies must also ship what it verifies ────────────────
  //
  // The player_ratings delta ends by sweeping pg_proc for functions still
  // reading a ranking column off profiles, and aborting if it finds one. On
  // first run it aborted listing 16 functions — correctly, because the
  // rewritten bodies existed only in migration_player_app.sql. The delta
  // created the table, then refused to finish the job it had not shipped.
  //
  // So: every function the canonical migration shows as player_ratings-aware
  // must also be defined in that delta, byte-identical.
  test('the player_ratings delta ships every function it then checks for', () {
    final deltaFile =
        File('supabase/changes/2026-08-15_player_ratings_p1.sql');
    if (!deltaFile.existsSync()) return;
    final delta = readSql(deltaFile.path);
    final mig = readSql('supabase/migration_player_app.sql');

    String? bodyOfLast(String sql, String name) {
      // plain lastIndexOf, not a RegExp — the function name contains a dot and
      // the trailing paren needs escaping, and getting that wrong silently
      // changes what is being searched for
      final needle = 'create or replace function $name(';
      final at = sql.lastIndexOf(needle);
      return at < 0 ? null : bodyAt(sql, at);
    }

    final expected = <String>{};
    for (final m
        in RegExp(r'create or replace function (public\.\w+)\(').allMatches(mig)) {
      final b = bodyAt(mig, m.start);
      if (b.contains('player_ratings') &&
          m.group(1) != 'public._player_ratings_row') {
        expected.add(m.group(1)!);
      }
    }
    expect(expected.length, greaterThan(10),
        reason: 'scanner found almost nothing — it is probably broken');

    final missing = <String>[];
    final drifted = <String>[];
    for (final name in expected) {
      final inDelta = bodyOfLast(delta, name);
      if (inDelta == null) {
        missing.add(name);
        continue;
      }
      if (inDelta != bodyOfLast(mig, name)) drifted.add(name);
    }

    expect(missing, isEmpty,
        reason: 'the delta checks for these but never redefines them, so it '
            'will abort on a real database:\n  ${missing.join('\n  ')}\n');
    expect(drifted, isEmpty,
        reason: 'delta and migration bodies disagree:\n  ${drifted.join('\n  ')}\n');
  });
}

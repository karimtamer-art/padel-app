/// Keeps [OnboardingProfile.isGeneratedUsername] in step with the handles
/// `_unique_username` can actually produce.
///
/// **Why this exists.** The two halves live in different languages and neither
/// one fails loudly when they disagree. `_unique_username` mints
/// `player<6 hex>` for a player who never chose a handle, and the Dart regex is
/// the ONLY thing that later notices and asks them to pick one. When the
/// generator dedupes — `player3f9a1c` taken, so `player3f9a1c1` — a regex
/// anchored at exactly six characters stops matching, and that player keeps the
/// junk handle forever with nothing prompting them. No test failed; no error was
/// logged; they simply never got asked.
///
/// So this mirrors the generator's arithmetic (the truncate-and-append rule
/// from changes/2026-08-20_username_collision.sql) and asserts every handle it
/// can emit is still recognised.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:padel_clay/backend/models/onboarding_models.dart';

/// Dart port of the fallback branch of SQL `_unique_username`, including its
/// dedupe loop. Only the fallback: a name-seeded handle is indistinguishable
/// from a chosen one by design.
String _fallbackHandle(String uuid, {int collisions = 0}) {
  final base = 'player${uuid.replaceAll('-', '').substring(0, 6)}';
  if (collisions == 0) return base;
  final n = collisions.toString();
  // substr(base, 1, 16 - length(n)) || n
  final keep = 16 - n.length;
  return base.substring(0, keep < base.length ? keep : base.length) + n;
}

void main() {
  const uuid = '3f9a1c22-0000-4000-8000-000000000001';

  group('isGeneratedUsername', () {
    test('recognises the un-collided fallback', () {
      expect(_fallbackHandle(uuid), 'player3f9a1c');
      expect(OnboardingProfile.isGeneratedUsername('player3f9a1c'), isTrue);
    });

    test('recognises every deduped form the generator can emit', () {
      // The suffix is decimal and decimal digits are hex digits, which is the
      // reason `{6,}` is sufficient and no second pattern is needed.
      for (var i = 1; i <= 250; i++) {
        final handle = _fallbackHandle(uuid, collisions: i);
        expect(
          OnboardingProfile.isGeneratedUsername(handle),
          isTrue,
          reason: 'collision #$i produced "$handle", which onboarding would '
              'treat as a handle the player chose',
        );
        // Whatever it emits must also survive profiles_username_chk.
        expect(RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(handle), isTrue,
            reason: '"$handle" violates profiles_username_chk');
      }
    });

    test('this is the case that regressed: player<6hex> + one digit', () {
      expect(OnboardingProfile.isGeneratedUsername('player3f9a1c1'), isTrue);
    });

    test('a chosen handle is left alone', () {
      for (final chosen in [
        'karim_h',
        'karim_h1', // the shape a collided TYPED handle now dedupes to
        'karimtamer',
        'player', // too short to be the fallback
        'player_3f9a1c', // underscore is not hex
        'players', // 's' is not hex
        'playerzzzzzz',
        'ahmed99',
      ]) {
        expect(OnboardingProfile.isGeneratedUsername(chosen), isFalse,
            reason: '"$chosen" would be needlessly re-asked at onboarding');
      }
    });

    test('null and blank are not generated handles', () {
      // Blank has its own branch in OnboardingFlow._steps, which asks anyway.
      expect(OnboardingProfile.isGeneratedUsername(null), isFalse);
      expect(OnboardingProfile.isGeneratedUsername('   '), isFalse);
    });

    test('case and surrounding space do not hide a generated handle', () {
      expect(OnboardingProfile.isGeneratedUsername('  PLAYER3F9A1C '), isTrue);
    });
  });

  group('SQL and Dart agree', () {
    test('the migration still strips only what the CHECK forbids', () {
      // Guards the half of the fix that lives in SQL: dropping `_` here is what
      // silently turned a taken `karim_h` into `karimh`.
      final sql = _readMigration();
      expect(
        sql.contains(r"regexp_replace(lower(coalesce(p_seed, '')), '[^a-z0-9_]+', '', 'g')"),
        isTrue,
        reason: '_unique_username must keep underscores in the seed — see '
            'changes/2026-08-20_username_collision.sql',
      );
    });

    test('the migration still routes a punctuation-only seed to the fallback', () {
      final sql = _readMigration();
      expect(
        sql.contains(r"if length(base) < 3 or base !~ '[a-z0-9]' then"),
        isTrue,
        reason: 'a seed with no letters or digits must take the player<hex> '
            'fallback, or onboarding never asks for a real handle',
      );
    });
  });

  group('handleSettled — who still gets asked', () {
    OnboardingProfile p({String? username, bool? chosen}) =>
        OnboardingProfile(username: username, usernameChosen: chosen);

    test('a handle nobody picked is not settled', () {
      // The Google case: _unique_username derived `karimtamer` from the
      // display name and the player was never asked.
      expect(p(username: 'karimtamer', chosen: false).handleSettled, isFalse);
    });

    test('a handle someone picked is settled', () {
      expect(p(username: 'karimtamer', chosen: true).handleSettled, isTrue);
    });

    test('no handle at all is never settled, whatever the flag says', () {
      expect(p(username: null, chosen: true).handleSettled, isFalse);
      expect(p(username: '   ', chosen: true).handleSettled, isFalse);
    });

    test('null means the COLUMN is missing, and reads as settled', () {
      // A database that has not had 2026-08-20_username_chosen.sql run cannot
      // record an answer. Treating null as "not chosen" would route every
      // player on it into onboarding to write a column that does not exist —
      // the write fails, handleSettled stays false, AuthGate sends them back.
      // That is an infinite loop, and it would hit the entire user base.
      expect(p(username: 'karimtamer', chosen: null).handleSettled, isTrue);
    });
  });

  group('toUpsert', () {
    test('claims the handle when the column is known to exist', () {
      final u = const OnboardingProfile(username: 'karim_h', usernameChosen: false)
          .toUpsert('uid-1');
      expect(u['username'], 'karim_h');
      expect(u['username_chosen'], isTrue);
    });

    test('omits the flag entirely when the column was not read', () {
      // Sending an unknown key would 400 the whole upsert and lose every other
      // onboarding answer with it.
      final u = const OnboardingProfile(username: 'karim_h').toUpsert('uid-1');
      expect(u.containsKey('username_chosen'), isFalse);
    });

    test('no handle, no claim', () {
      final u = const OnboardingProfile(usernameChosen: false).toUpsert('uid-1');
      expect(u.containsKey('username_chosen'), isFalse);
    });

    test('lowercases the handle it claims', () {
      final u = const OnboardingProfile(username: '  Karim_H ', usernameChosen: false)
          .toUpsert('uid-1');
      expect(u['username'], 'karim_h');
    });
  });

  group('the SQL half of username_chosen', () {
    test('the column and its grant both ship in the migration', () {
      final sql = _readMigration();
      expect(
          sql.contains('add column if not exists username_chosen boolean not null default false'),
          isTrue);
      // The grant is the half that fails SILENTLY: profiles uses column-level
      // grants, PostgREST refuses an ungranted write without an error, and
      // onboarding would re-ask on every launch forever.
      expect(sql.contains('grant update (username_chosen) on public.profiles to authenticated'),
          isTrue,
          reason: 'a client-written profiles column MUST carry a column grant');
    });

    test('handle_new_user records whether the typed handle survived', () {
      final sql = _readMigration();
      expect(sql.contains('v_typed    boolean := false'), isTrue);
      // Set in the ELSE of the "generate one instead" branch — i.e. only when
      // the metadata handle was used verbatim.
      expect(sql.contains('    v_typed := true;'), isTrue);
      expect(sql.contains('(new.id, v_name, v_username, v_typed,'), isTrue);
    });

    test('the backfill pattern matches the Dart one', () {
      // Both must tolerate the dedupe suffix, or the backfill grandfathers a
      // junk `player3f9a1c1` handle in as chosen and nobody is ever asked.
      final delta = File('supabase/changes/2026-08-20_username_chosen.sql')
          .readAsStringSync();
      expect(delta.contains(r"!~ '^player[0-9a-f]{6,}$'"), isTrue);
      expect(OnboardingProfile.isGeneratedUsername('player3f9a1c1'), isTrue);
    });
  });
}

String? _cached;

/// The canonical migration, read relative to the package root (where
/// `flutter test` runs). Cached so the SQL groups don't re-read a large file.
String _readMigration() =>
    _cached ??= File('supabase/migration_player_app.sql').readAsStringSync();

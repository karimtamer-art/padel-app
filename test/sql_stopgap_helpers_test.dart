import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Supabase grants new public functions to anon and authenticated, so an internal helper
// is callable with the public anon key unless it is revoked from all three. There is no
// Postgres in this environment, so this pins the text of the migration, which gets re-run
// on live: a grant left in it would reopen the helper.
void main() {
  final sql = File('supabase/migration_player_app.sql')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  const closed = {
    '_finance_core': '(date, date)',
    '_advance_winner': '(uuid, text, int, int, uuid)',
    'apply_rating_decay': '()',
    '_award_tournament_season_points': '(uuid)',
    '_award_season_points': '(uuid)',
    '_settle_rating': '(uuid)',
    '_invite_partner': '(uuid, uuid, text)',
    '_seed_season_defaults': '(uuid)',
  };

  for (final e in closed.entries) {
    test('${e.key} stays closed to every client role', () {
      final revoke = 'revoke all on function public.${e.key}${e.value} '
          'from public, anon, authenticated;';
      expect(sql, contains(revoke));
      expect(sql, isNot(contains('grant execute on function public.${e.key}(')));
      expect(
          sql.lastIndexOf('create or replace function public.${e.key}('),
          lessThan(sql.lastIndexOf(revoke)),
          reason: 'the revoke must follow the last definition');
    });
  }
}

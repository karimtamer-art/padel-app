import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Supabase grants new public functions to anon and authenticated by default, so a
// SECURITY DEFINER helper is reachable through PostgREST unless it is revoked. There
// is no Postgres in this environment, so this pins the text of the migration.
void main() {
  final sql = File('supabase/migration_player_app.sql')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  const internal = {
    '_match_set_counts': '(text, boolean)',
    '_stage_standings': '(uuid, int, boolean)',
    '_wb_rounds': '(uuid)',
    '_lb_place': '(uuid, uuid, int, int, boolean)',
    '_advance_in_losers': '(uuid, uuid, int, int)',
    '_drop_from_winners': '(uuid, uuid, int, int)',
    '_open_grand_final': '(uuid)',
  };

  for (final e in internal.entries) {
    test('${e.key} is closed to every client role', () {
      expect(
          sql,
          contains('revoke all on function public.${e.key}${e.value} '
              'from public, anon, authenticated;'));
      expect(sql, isNot(contains('grant execute on function public.${e.key}')));
    });
  }

  test('tournament_standings is the signed-in-only way in', () {
    expect(
        sql,
        contains(
            'revoke all on function public.tournament_standings(uuid) from public, anon;'));
    expect(
        sql,
        contains(
            'grant execute on function public.tournament_standings(uuid) to authenticated;'));
  });

  test('tournament_standings repeats the tournaments read rule', () {
    final start =
        sql.indexOf('create or replace function public.tournament_standings(');
    final body = sql.substring(start, sql.indexOf(r'$$;', sql.indexOf(r'$$', start) + 2));
    expect(body, contains('auth.uid() is not null'));
    expect(body, contains("t.status <> 'cancelled'"));
    expect(body, contains('public._is_admin()'));
    expect(body, contains("t.organizer_id = auth.uid() and public.current_admin_role() = 'organizer'"));
  });

  test('advance_stage ranks with the shared standings, not its own', () {
    final start = sql.indexOf('create or replace function public.advance_stage(');
    final body = sql.substring(start, sql.indexOf(r'end $$;', start));
    expect(body, contains('_stage_standings(p_tournament_id, v_cur_stage, true)'));
    expect(body, contains('_stage_standings(p_tournament_id, v_cur_stage, false)'));
    expect(body, isNot(contains('row_number()')));
  });

  test('admin_set_match_info checks ownership and is not open to anon', () {
    final start =
        sql.indexOf('create or replace function public.admin_set_match_info(');
    final body = sql.substring(start, sql.indexOf(r'end $$;', start));
    expect(body, contains('owns_tournament(m.tournament_id)'));
    expect(
        sql,
        contains(
            'revoke all on function public.admin_set_match_info(uuid, text, boolean) from public, anon;'));
  });
}

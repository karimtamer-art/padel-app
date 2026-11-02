import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// There is no Postgres in the test environment, so this pins the text. The row
// after a final has one side empty; counting it as unfinished blocked finalizing
// on every generate_draw event.
void main() {
  test('finalize_tournament only waits for matches that can be played', () {
    final sql = File('supabase/migration_player_app.sql')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final start =
        sql.indexOf('create or replace function public.finalize_tournament(');
    expect(start, greaterThan(-1));
    final body = sql.substring(start, sql.indexOf(r'end $$;', start));
    final guard = RegExp(
        r'winner_entry is null\s+and entry1 is not null and entry2 is not null\) then\s+'
        r"return 'Finish all current matches");
    expect(guard.hasMatch(body), isTrue);
  });
}

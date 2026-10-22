import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:padel_clay/backend/models/ranking_scale.dart';

// Players see letters, not metals (2026-10-22). The same bands drive the
// website's categories via SQL _web_level_of — if these move, move that too.
void main() {
  test('categoryFor uses the app division bands and Low/Mid/Upper', () {
    expect(RankingScale.categoryFor(0.3), 'D Low');
    expect(RankingScale.categoryFor(1.9), 'D Upper');
    expect(RankingScale.categoryFor(1.95), 'C Low'); // gap → division above
    expect(RankingScale.categoryFor(2.5), 'C Mid');
    expect(RankingScale.categoryFor(3.6), 'B Low');
    expect(RankingScale.categoryFor(4.5), 'B Upper');
    expect(RankingScale.categoryFor(7.0), 'A Upper');
  });

  test('tierKeyLabel turns stored tier keys into letters', () {
    expect(RankingScale.tierKeyLabel('bronze'), 'D');
    expect(RankingScale.tierKeyLabel('Silver'), 'C');
    expect(RankingScale.tierKeyLabel('gold'), 'B');
    expect(RankingScale.tierKeyLabel('elite'), 'A');
    expect(RankingScale.tierKeyLabel('Unranked'), 'Unranked');
  });

  test('the SQL mirror carries the same band edges', () {
    // Cheap guard: the migration's _web_level_of must list the same bands.
    final sql = RegExp(r'_web_level_of\(p numeric\)[\s\S]*?\$\$;')
        .firstMatch(File('supabase/migration_player_app.sql').readAsStringSync())!
        .group(0)!;
    expect(sql, contains('array[0.0, 2.0, 3.5, 5.0]'));
    expect(sql, contains('array[1.9, 3.4, 4.9, 7.0]'));
    for (final d in RankingScale.divisions) {
      expect(sql, contains('${d.min}'));
      expect(sql, contains('${d.max}'));
    }
  });
}

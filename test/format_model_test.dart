import 'package:flutter_test/flutter_test.dart';
import 'package:padel_clay/backend/models/format_model.dart';

void main() {
  group('math helpers', () {
    test('nextPow2 rounds up', () {
      expect(nextPow2(5), 8);
      expect(nextPow2(8), 8);
      expect(nextPow2(9), 16);
      expect(nextPow2(2), 2);
    });
    test('isPow2', () {
      expect(isPow2(8), true);
      expect(isPow2(6), false);
      expect(isPow2(1), false);
    });
    test('groupSizes splits as evenly as possible', () {
      expect(groupSizes(16, 4), [4, 4, 4, 4]);
      expect(groupSizes(17, 4), [5, 4, 4, 4]);
      expect(groupSizes(10, 3), [4, 3, 3]);
    });
  });

  group('stage produces / matchCount', () {
    test('groups produce groups*advance and RR matches', () {
      final g = Stage.of(StageKind.groups); // 4 groups, top 2
      expect(produces(g), 8);
      // 16 pairs → 4 groups of 4 → C(4,2)=6 each → 24
      expect(matchCount(g, 16), 24);
    });
    test('knockout produces one champion; N-1 (+3rd place) matches', () {
      final k = Stage.of(StageKind.knockout)..cfg['seeds'] = 8;
      expect(produces(k), 1);
      expect(matchCount(k, 8), 8); // 7 + 3rd-place
      k.thirdPlace = false;
      expect(matchCount(k, 8), 7);
    });
  });

  group('analyzeFormat', () {
    test('clean Groups→Knockout at 16 has no errors', () {
      final stages = [
        Stage.of(StageKind.groups), // 4x, top2 → 8
        wireStage(Stage.of(StageKind.knockout), 8), // seeds 8
      ];
      final a = analyzeFormat(stages, 16, 3);
      expect(a.errors, 0);
      expect(a.flow.last.outCount, 1);
      expect(a.totalMatches, greaterThan(0));
    });

    test('non-power-of-two knockout warns and is fixable', () {
      final k = Stage.of(StageKind.knockout)..cfg['seeds'] = 6;
      final a = analyzeFormat([k], 6, 2);
      final w = a.warnings.firstWhere((w) => w.fixPow2 != null);
      expect(w.fixPow2, 8);
      applyFix([k], w);
      expect(k.seeds, 8);
    });

    test('too many groups for the field is an error', () {
      final g = Stage.of(StageKind.groups)..cfg['groups'] = 8;
      final a = analyzeFormat([g], 6, 2); // 6 pairs, 8 groups → impossible
      expect(a.errors, greaterThan(0));
    });
  });

  test('FormatSpec JSON round-trips', () {
    final spec = FormatSpec(
      name: 'My format',
      stages: [Stage.of(StageKind.groups), Stage.of(StageKind.knockout)],
      entrants: 24,
      courts: 4,
    );
    final back = FormatSpec.fromJson(spec.toJson());
    expect(back.name, 'My format');
    expect(back.entrants, 24);
    expect(back.courts, 4);
    expect(back.stages.length, 2);
    expect(back.stages.first.kind, StageKind.groups);
    expect(back.stages.first.groups, 4);
  });
}

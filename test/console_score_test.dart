// The console's result entry, driven through the real sheet. Every Supabase request
// is answered locally.
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:padel_clay/admin/screens/draw_sheet.dart';
import 'package:padel_clay/backend/models/draw_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

List<Map<String, dynamic>> _rows = [];
final _saved = <Map<String, dynamic>>[];

Map<String, dynamic> _entry(String id, String name) =>
    {'id': id, 'player_name': name, 'partner_name': null};

Map<String, dynamic> _match(String bracket, {String? winner, String? score}) => {
      'id': 'm1',
      'bracket': bracket,
      'round': 1,
      'slot': 0,
      'winner_entry': winner,
      'score': score,
      'e1': _entry('a', 'Amir One'),
      'e2': _entry('b', 'Basem Two'),
    };

class _FakeBackend extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    Object? body = <Object>[];
    if (request.url.path.endsWith('/tournament_matches')) {
      body = _rows;
    } else if (request.url.path.endsWith('/rpc/set_match_winner')) {
      _saved.add(jsonDecode((request as http.Request).body) as Map<String, dynamic>);
      body = null;
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      200,
      request: request,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
}

Future<void> _open(WidgetTester tester, List<Map<String, dynamic>> rows) async {
  _rows = rows;
  _saved.clear();
  tester.view.physicalSize = const Size(1600, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const MaterialApp(
    home: Scaffold(
      body: DrawSheet(
        tournamentId: 't',
        tournamentName: 'Test Open',
        format: 'group_knockout',
        registeredPairs: 2,
        formatSpec: {
          'stages': [
            {
              'kind': 'groups',
              'cfg': {'groups': 1, 'advance': 2}
            },
            {'kind': 'knockout'},
          ]
        },
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _tapFixture(WidgetTester tester, String separator) async {
  await tester.tap(find.text(separator));
  await tester.pumpAndSettle();
  expect(find.text('Who won?'), findsOneWidget);
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://test.invalid',
      anonKey: 'test',
      httpClient: _FakeBackend(),
      authOptions:
          const FlutterAuthClientOptions(localStorage: EmptyLocalStorage()),
    );
  });

  testWidgets('a group result saves its winner and score', (tester) async {
    await _open(tester, [_match('Group A')]);
    await _tapFixture(tester, 'v');
    await tester.tap(find.text('Basem Two').last);
    await tester.pump();
    await tester.enterText(find.byType(TextField), '6-4, 6-3');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(_saved.single['p_match_id'], 'm1');
    expect(_saved.single['p_winner'], 'b');
    expect(_saved.single['p_score'], '6-4, 6-3');
  });

  testWidgets('the score is optional', (tester) async {
    await _open(tester, [_match('Group A')]);
    await _tapFixture(tester, 'v');
    await tester.tap(find.text('Amir One').last);
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(_saved.single['p_winner'], 'a');
    expect(_saved.single['p_score'], isNull);
  });

  testWidgets('an unreadable score is refused, and nothing is saved',
      (tester) async {
    await _open(tester, [_match('Group A')]);
    await _tapFixture(tester, 'v');
    await tester.tap(find.text('Amir One').last);
    await tester.pump();
    await tester.enterText(find.byType(TextField), '6-4 6');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Write it as sets, e.g. 6-4, 6-3'), findsOneWidget);
    expect(_saved, isEmpty);
  });

  testWidgets('no winner picked: nothing is saved', (tester) async {
    await _open(tester, [_match('Group A')]);
    await _tapFixture(tester, 'v');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Pick the winning pair.'), findsOneWidget);
    expect(_saved, isEmpty);
  });

  testWidgets('an existing result can be edited or cleared', (tester) async {
    await _open(tester, [_match('Group A', winner: 'a', score: '6-1, 6-1')]);
    await _tapFixture(tester, '·');
    expect(find.text('6-1, 6-1'), findsOneWidget);
    await tester.tap(find.text('Clear result'));
    await tester.pumpAndSettle();
    expect(_saved.single['p_winner'], isNull);
    expect(_saved.single['p_score'], isNull);
  });

  testWidgets('cancelling changes nothing', (tester) async {
    await _open(tester, [_match('Group A')]);
    await _tapFixture(tester, 'v');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(_saved, isEmpty);
  });

  test('readable scores', () {
    expect(isReadableScore(''), isTrue);
    expect(isReadableScore(null), isTrue);
    expect(isReadableScore('6-4, 6-3'), isTrue);
    expect(isReadableScore('6-4,3-6,10-8'), isTrue);
    expect(isReadableScore('6-4 6'), isFalse);
    expect(isReadableScore('walkover'), isFalse);
  });
}

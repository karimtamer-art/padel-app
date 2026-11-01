// Regression test for the tournament payment sheet.
//
// With a partner selected the sheet shows "who are you paying for?". That toggle
// was a stretch Row inside a scroll view, which has no height limit, so its layout
// failed and took the InstaPay fields below it down too.
//
// Drives the real screen with every Supabase request answered locally.
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:padel_clay/frontend/screens/tournaments/tournament_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeBackend extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    final oneRow = (request.url.queryParameters['id'] ?? '').startsWith('eq.');
    Object? body = <Object>[];
    if (path.endsWith('/tournaments')) {
      final start = DateTime.now().add(const Duration(days: 5));
      body = [
        {
          'id': 't',
          'name': 'Test Open',
          'venue_name': 'Test Club',
          'status': 'open',
          'start_date': start.toIso8601String().substring(0, 10),
          'capacity': 12,
          'entry_fee': 500,
          'format': 'knockout',
          'best_of': 3,
          'category': 'open',
          'tournament_entries': <Object>[],
        }
      ];
    } else if (path.endsWith('/profiles') && !oneRow) {
      body = [
        {'id': 'p1', 'name': 'Partner Player', 'username': 'partner', 'gender': 'male'}
      ];
    } else if (path.contains('/rpc/')) {
      body = {'handle': 'organizer@instapay', 'link': null};
    }
    final accept = request.headers['Accept'] ?? request.headers['accept'] ?? '';
    if (accept.contains('vnd.pgrst.object') && body is List) {
      body = body.isEmpty ? null : body.first;
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      200,
      request: request,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
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

  testWidgets('with a partner selected, the InstaPay fields are all shown',
      (tester) async {
    // Wide and tall: the test font is far wider than the real one, and the
    // whole sheet should be on screen at once.
    tester.view.physicalSize = const Size(1600, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(
      home: TournamentDetailScreen(tournamentId: 't'),
    ));
    await tester.pumpAndSettle();

    final partner = find.text('Partner Player');
    await tester.ensureVisible(partner);
    await tester.pumpAndSettle();
    await tester.tap(partner);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Register Pair'));
    await tester.pumpAndSettle();

    // The choice only a partner brings...
    expect(find.text('WHO ARE YOU PAYING FOR?'), findsOneWidget);
    expect(find.text('Both of us'), findsOneWidget);
    expect(find.text('Just me'), findsOneWidget);
    // ...and everything that used to vanish below it.
    expect(find.text('organizer@instapay'), findsOneWidget);
    expect(find.text('YOUR INSTAPAY USERNAME'), findsOneWidget);
    expect(find.text('Attach a screenshot'), findsOneWidget);
    expect(find.text("I've sent the transfer"), findsOneWidget);
    for (final f in [
      find.text('organizer@instapay'),
      find.text('YOUR INSTAPAY USERNAME'),
      find.text('Attach a screenshot'),
    ]) {
      expect(tester.getRect(f).height, greaterThan(0));
      expect(tester.getRect(f).isFinite, isTrue);
    }
    expect(tester.takeException(), isNull);
  });
}

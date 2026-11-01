// Dev-only preview of the player-facing tournament screens. NOT part of the
// shipped app — it has its own main(), nothing imports it, and it talks to no
// database: every Supabase request is answered by [_FakeBackend] below.
//
//   flutter run -d chrome -t lib/dev/bracket_demo.dart
//   ...then optionally ?case=3&side=losers to jump straight to a scenario,
//   ?case=compete for the list, &w=360 to test a narrow phone, and &h=1600 to
//   see a long screen without scrolling.
//
// It renders the REAL screens, so the design cannot drift from
// what ships. The sample rows are produced by [_Sim], a port of what the SQL
// does (generate_draw, _advance_winner, record_bracket_winner), so the rows have
// the same shape a real draw has — including only round 1 existing after a draw.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:padel_clay/frontend/screens/tournaments/partner_sheet.dart';
import 'package:padel_clay/frontend/screens/tournaments/tournament_detail_screen.dart';
import 'package:padel_clay/frontend/screens/tournaments/tournaments_screen.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _me = '00000000-0000-4000-8000-000000000001';

String _jwt() {
  String seg(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${seg({'alg': 'none'})}.'
      '${seg({'sub': _me, 'role': 'authenticated', 'exp': 4102444800})}.demo';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: 'https://demo.invalid',
    anonKey: _jwt(),
    httpClient: _FakeBackend(),
    authOptions:
        const FlutterAuthClientOptions(localStorage: EmptyLocalStorage()),
  );
  // Signed in as a made-up player so "You" highlighting and actions render.
  await Supabase.instance.client.auth.recoverSession(jsonEncode({
    'access_token': _jwt(),
    'token_type': 'bearer',
    'expires_at': 4102444800,
    'refresh_token': 'demo',
    'user': {
      'id': _me,
      'aud': 'authenticated',
      'created_at': '2026-01-01T00:00:00Z',
      'app_metadata': <String, dynamic>{},
      'user_metadata': <String, dynamic>{},
    },
  }));
  runApp(const _DemoApp());
}

// ── Sample data ─────────────────────────────────────────────────────────────

const _names = [
  ['Nour Salem', 'Omar Hassan'],
  ['Ahmed Samir', 'Youssef Adel'],
  ['Karim Fouad', 'Tarek Nabil'],
  ['Mostafa Ali', 'Hany Ramzy'],
  ['Mahmoud Saad', 'Ziad Khaled'],
  ['Sherif Magdy', 'Amr Gamal'],
  ['Hossam Wael', 'Nour Ibrahim'],
  ['Seif Ashraf', 'Ramy Lotfy'],
  ['Adham Reda', 'Bassem Farid'],
  ['Mina Sobhy', 'Fady Naguib'],
  ['Khaled Mounir', 'Sameh Yehia'],
  ['Walid Tawfik', 'Ayman Selim'],
  ['Hazem Zaki', 'Ehab Shawky'],
  ['Galal Rizk', 'Tamer Badr'],
  ['Essam Helmy', 'Yasser Sabry'],
  ['Marwan Attia', 'Ibrahim Nader'],
];

List<Map<String, dynamic>> _entries(int n, {bool withMe = true}) => [
      for (var i = withMe ? 0 : 1; i < n + (withMe ? 0 : 1); i++)
        {
          'id': 'e$i',
          'player_id': i == 0 ? _me : 'p$i',
          'player_name': _names[i][0],
          'partner_id': 'q$i',
          'partner_name': _names[i][1],
          'status': 'paid',
          'fee_mode': 'both',
          'payer_paid': true,
          'partner_paid': true,
        }
    ];

/// Port of generate_draw / _advance_winner / record_bracket_winner.
class _Sim {
  final List<Map<String, dynamic>> entries;
  final bool doubleElim;
  final rows = <Map<String, dynamic>>[];
  _Sim(this.entries, {this.doubleElim = false}) {
    final n = entries.length;
    var size = 2;
    while (size < n) {
      size *= 2;
    }
    for (var i = 0; i < size ~/ 2; i++) {
      final other = size - i <= n ? entries[size - i - 1] : null;
      rows.add(_row('wb', 1, i, entries[i], other,
          winner: other == null ? entries[i]['id'] as String : null));
    }
    for (var i = 0; i < size ~/ 2; i++) {
      final w = _at('wb', 1, i)!['winner_entry'];
      if (w != null) _advance('wb', 1, i, _entry(w as String));
    }
  }

  Map<String, dynamic> _entry(String id) =>
      entries.firstWhere((e) => e['id'] == id);

  Map<String, dynamic> _row(String b, int round, int slot,
          Map<String, dynamic>? e1, Map<String, dynamic>? e2,
          {String? winner}) =>
      {
        'id': '$b-$round-$slot',
        'bracket': b,
        'round': round,
        'slot': slot,
        'winner_entry': winner,
        'score': null,
        'result_status': 'open',
        'submitted_winner': null,
        'submitted_by': null,
        'e1': e1,
        'e2': e2,
      };

  Map<String, dynamic>? _at(String b, int round, int slot) {
    for (final r in rows) {
      if (r['bracket'] == b && r['round'] == round && r['slot'] == slot) {
        return r;
      }
    }
    return null;
  }

  void _advance(String b, int round, int slot, Map<String, dynamic> winner) {
    final next = _at(b, round + 1, slot ~/ 2) ??
        (() {
          final r = _row(b, round + 1, slot ~/ 2, null, null);
          rows.add(r);
          return r;
        })();
    next[slot.isEven ? 'e1' : 'e2'] = winner;
  }

  /// Records a result the way record_bracket_winner does.
  void play(String b, int round, int slot, String score, {bool top = true}) {
    final m = _at(b, round, slot)!;
    final w = m[top ? 'e1' : 'e2'] as Map<String, dynamic>;
    final l = m[top ? 'e2' : 'e1'] as Map<String, dynamic>;
    m['winner_entry'] = w['id'];
    m['score'] = score;
    _advance(b, round, slot, w);
    if (!doubleElim || b != 'wb') return;
    final lb = rows.where((r) => r['bracket'] == 'lb').toList();
    final open = lb
        .where((r) =>
            r['winner_entry'] == null && (r['e1'] == null || r['e2'] == null))
        .toList()
      ..sort((x, y) {
        final c = (x['round'] as int).compareTo(y['round'] as int);
        return c != 0 ? c : (x['slot'] as int).compareTo(y['slot'] as int);
      });
    if (open.isNotEmpty) {
      open.first[open.first['e1'] == null ? 'e1' : 'e2'] = l;
    } else {
      final maxRound = lb.fold<int>(1, (a, r) => a > (r['round'] as int) ? a : r['round'] as int);
      final slots = lb.where((r) => r['round'] == maxRound).length;
      rows.add(_row('lb', maxRound, slots, l, null));
    }
  }
}

class _Scenario {
  final String title, note, format;
  final int pairs;
  final List<Map<String, dynamic>> Function() rows;

  /// Opens on Overview as a player who hasn't entered, registration open.
  final bool open;

  /// Lands on the Bracket tab when the scenario opens.
  final bool bracket;
  const _Scenario(this.title, this.note, this.format, this.pairs, this.rows,
      {this.open = false, this.bracket = true});
}

Map<String, dynamic> _custom(String label, int slot, int a, int b,
    {int? winner, String? score}) {
  final es = _entries(8);
  return {
    'id': 'c-$label-$slot',
    'bracket': label,
    'round': 1,
    'slot': slot,
    'winner_entry': winner == null ? null : es[winner]['id'],
    'score': score,
    'result_status': 'open',
    'submitted_winner': null,
    'submitted_by': null,
    'e1': es[a],
    'e2': es[b],
  };
}

final _scenarios = <_Scenario>[
  _Scenario('Knockout · 16 pairs · draw just made',
      'What players see the moment the organiser generates the draw.',
      'knockout', 16, () => _Sim(_entries(16)).rows),
  _Scenario('Knockout · 8 pairs · in progress',
      'Quarterfinals done, one semifinal played.', 'knockout', 8, () {
    final s = _Sim(_entries(8));
    s.play('wb', 1, 0, '6-3,6-4');
    s.play('wb', 1, 1, '4-6,6-3,10-7', top: false);
    s.play('wb', 1, 2, '6-2,6-2');
    s.play('wb', 1, 3, '7-5,6-4');
    s.play('wb', 2, 0, '6-4,3-6,10-8');
    return s.rows;
  }),
  _Scenario('Knockout · 8 pairs · finished',
      'Every match recorded, final included.', 'knockout', 8, () {
    final s = _Sim(_entries(8));
    s.play('wb', 1, 0, '6-3,6-4');
    s.play('wb', 1, 1, '4-6,6-3,10-7', top: false);
    s.play('wb', 1, 2, '6-2,6-2');
    s.play('wb', 1, 3, '7-5,6-4');
    s.play('wb', 2, 0, '6-4,3-6,10-8');
    s.play('wb', 2, 1, '6-1,6-4');
    s.play('wb', 3, 0, '7-6,6-4');
    return s.rows;
  }),
  _Scenario('Double elimination · 8 pairs · in progress',
      'Winners and Losers tabs, with pairs dropping down.', 'double_elim', 8, () {
    final s = _Sim(_entries(8), doubleElim: true);
    s.play('wb', 1, 0, '4-6,6-4,10-6', top: false);
    s.play('wb', 1, 1, '6-3,6-3');
    s.play('wb', 1, 2, '6-4,7-5');
    s.play('wb', 1, 3, '6-2,4-6,10-4');
    s.play('lb', 1, 0, '6-4,6-4');
    return s.rows;
  }),
  _Scenario('Knockout · 6 pairs · byes',
      'Not a power of two, so the top seeds get a bye.', 'knockout', 6,
      () => _Sim(_entries(6)).rows),
  _Scenario('Custom format · groups + semifinal',
      'Format Builder / manual draws: grouped by label, players enter results.',
      'custom', 8, () => [
        _custom('Group A', 0, 0, 1, winner: 0, score: '6-3,6-4'),
        _custom('Group A', 1, 2, 3, winner: 3, score: '2-6,6-7'),
        _custom('Group A', 2, 0, 3),
        _custom('Group B', 0, 4, 5, winner: 5, score: '4-6,4-6'),
        _custom('Group B', 1, 6, 7),
        _custom('Semifinal', 0, 0, 5),
      ]),
  _Scenario('No draw yet', 'Registered, double elimination, before the draw.',
      'double_elim', 8, () => []),
  _Scenario('Overview · registration open',
      'Not entered yet: team section and Choose partner.', 'group_knockout', 4,
      () => [], open: true, bracket: false),
  _Scenario('Overview · registered, before the draw',
      "You're in, with Manage.", 'double_elim', 8, () => [], bracket: false),
];

Map<String, dynamic> _tournament(int i) {
  final s = _scenarios[i];
  final now = DateTime.now();
  String d(int off) =>
      now.add(Duration(days: off)).toIso8601String().substring(0, 10);
  return {
    'id': 't$i',
    'name': 'Rivals Open — Cairo',
    'venue_name': 'Padel Rivals Arena, New Cairo',
    'status': s.open ? 'open' : 'in_progress',
    'start_date': s.open ? d(5) : d(-1),
    'end_date': s.open ? d(5) : d(1),
    'start_time': '5:00 PM',
    'capacity': s.open ? 12 : s.pairs,
    'organizer_id': 'org',
    'entry_fee': 500,
    'prize_pool': 20000,
    'description': 'Sample tournament for the design preview.',
    'min_rating': 0.5,
    'max_rating': 1.9,
    'format_spec': s.format == 'custom'
        ? {
            'stages': [
              {
                'kind': 'groups',
                'cfg': {'groups': 2, 'advance': 2}
              },
              {'kind': 'knockout'},
            ]
          }
        : null,
    'format': s.format,
    'format_note': null,
    'best_of': 3,
    'sponsored': s.open,
    'registration_opens': null,
    'registration_closed': !s.open,
    'category': 'open',
    'tournament_entries': _entries(s.pairs, withMe: !s.open),
  };
}

/// Answers every Supabase request locally; nothing leaves the browser.
class _FakeBackend extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    final q = request.url.queryParameters;
    int idx(String? v) => int.parse((v ?? 'eq.t0').substring(4));
    Object? body = <Object>[];
    if (path.endsWith('/tournaments')) {
      body = q.containsKey('id')
          ? [_tournament(idx(q['id']))]
          : [
              // A live one and an open one, as the list would show them.
              for (var i = 0; i < _scenarios.length; i++)
                if (i == 1 || _scenarios[i].open) _tournament(i),
            ];
    } else if (path.endsWith('/tournament_matches')) {
      body = _scenarios[idx(q['tournament_id'])].rows();
    } else if (path.endsWith('/profiles') && q.containsKey('id') &&
        (q['id'] ?? '').startsWith('eq.')) {
      body = [
        {'gender': 'male'}
      ];
    } else if (path.endsWith('/profiles')) {
      body = [
        for (var i = 1; i < 7; i++)
          {
            'id': 'p$i',
            'name': _names[i][0],
            'username': _names[i][0].split(' ').first.toLowerCase(),
            'gender': 'male',
            'player_ratings': i == 6
                ? null
                : {'rating': 0.8 + i * 0.5, 'level': 0.8 + i * 0.5, 'tier': 'bronze'},
          }
      ];
    } else if (path.contains('/rpc/')) {
      body = null;
    }
    // A single-row request asks for an object rather than a list.
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

// ── Shell ───────────────────────────────────────────────────────────────────

class _DemoApp extends StatelessWidget {
  const _DemoApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Bracket preview',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(scaffoldBackgroundColor: AppColors.bg),
        // Phone-sized frame, so a desktop browser shows what a phone shows.
        builder: (context, child) {
          final mq = MediaQuery.of(context);
          final h = double.tryParse(Uri.base.queryParameters['h'] ?? '') ??
              (mq.size.height < 844 ? mq.size.height : 844.0);
          // Modal sheets take their height from this frame, not the window.
          final w =
              double.tryParse(Uri.base.queryParameters['w'] ?? '') ?? 390.0;
          return ColoredBox(
            color: const Color(0xFF20242B),
            child: Center(
              child: SizedBox(
                width: w,
                height: h,
                child: MediaQuery(
                  data: mq.copyWith(size: Size(w, h)),
                  child: ClipRect(child: child),
                ),
              ),
            ),
          );
        },
        home: const _Picker(),
      );
}

class _Picker extends StatefulWidget {
  const _Picker();
  @override
  State<_Picker> createState() => _PickerState();
}

class _PickerState extends State<_Picker> {
  @override
  void initState() {
    super.initState();
    final q = Uri.base.queryParameters;
    final c = int.tryParse(q['case'] ?? '');
    if (q['case'] == 'compete') {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openCompete());
    } else if (q['case'] == 'partner') {
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => showPartnerSheet(context, feePerPlayer: 600, onShareInvite: () {}));
    } else if (c != null && c >= 0 && c < _scenarios.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _open(c,
          losers: q['side'] == 'losers', scrollBy: double.tryParse(q['y'] ?? '')));
    }
  }

  void _openCompete() => Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const Scaffold(body: TournamentsScreen())));

  Future<void> _open(int i, {bool losers = false, double? scrollBy}) async {
    unawaited(Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => TournamentDetailScreen(tournamentId: 't$i'))));
    // Let the page transition finish first: taps land where the text is NOW.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (_scenarios[i].bracket && await _tapText('Bracket') && losers) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await _tapText('Losers');
    }
    if (scrollBy != null) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      final at = Offset(MediaQuery.of(context).size.width / 2, 400);
      GestureBinding.instance.handlePointerEvent(
          PointerScrollEvent(position: at, scrollDelta: Offset(0, scrollBy)));
    }
  }

  /// Sends a real tap to the first on-screen Text with this exact label, so the
  /// preview lands on the Bracket tab without changing the production screen.
  Future<bool> _tapText(String label) async {
    for (var attempt = 0; attempt < 50; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      RenderBox? box;
      void walk(Element e) {
        final w = e.widget;
        if (box == null && w is Text && w.data == label) {
          final r = e.renderObject;
          if (r is RenderBox && r.attached) box = r;
        }
        if (box == null) e.visitChildren(walk);
      }

      WidgetsBinding.instance.rootElement?.visitChildren(walk);
      if (box == null) continue;
      final p = box!.localToGlobal(box!.size.center(Offset.zero));
      GestureBinding.instance
        ..handlePointerEvent(PointerDownEvent(pointer: 900 + attempt, position: p))
        ..handlePointerEvent(PointerUpEvent(pointer: 900 + attempt, position: p));
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Text('Bracket preview', style: AppText.cardTitle().copyWith(fontSize: 20)),
            const SizedBox(height: 4),
            Text('The real screen with sample data. Nothing here reaches the database.',
                style: AppText.small()),
            const SizedBox(height: 16),
            Card(
              color: AppColors.surface,
              elevation: 0,
              child: ListTile(
                title: Text('Compete (tournament list)',
                    style: AppText.bodyStrong(AppColors.ink).copyWith(fontSize: 14)),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _openCompete,
              ),
            ),
            for (var i = 0; i < _scenarios.length; i++)
              Card(
                color: AppColors.surface,
                elevation: 0,
                child: ListTile(
                  title: Text(_scenarios[i].title,
                      style: AppText.bodyStrong(AppColors.ink).copyWith(fontSize: 14)),
                  subtitle: Text(_scenarios[i].note, style: AppText.small()),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _open(i),
                ),
              ),
          ]),
        ),
      );
}

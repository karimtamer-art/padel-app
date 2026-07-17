import 'package:flutter/material.dart';
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';
import '../data/admin_service.dart';
import 'draw_boards.dart';
import '../../backend/models/draw_engine.dart';
import '../../backend/models/format_model.dart';

// Configurable "Draw & results" for Groups → Knockout, Single elimination and
// Round robin. Setup: configure + Generate (server builds real matches). Draw:
// a live board per format — group standings, a connected knockout bracket, or a
// round-robin crosstab — tapping a result persists via set_match_winner and the
// standings/bracket recompute. Wired to the existing server engine.

enum _Fmt { groupsKo, single, rr }

const List<Color> _groupTones = [
  Color(0xFF3F7896), Color(0xFFC2502A), Color(0xFF2F6B57), Color(0xFF8A4B2B),
  Color(0xFF6E5AA0), Color(0xFF907A52), Color(0xFFB07E22), Color(0xFF3F8B57),
];
Color _tone(int i) => _groupTones[i % _groupTones.length];

String _roundName(int size) {
  switch (size) {
    case 2: return 'Final';
    case 4: return 'Semifinals';
    case 8: return 'Quarterfinals';
    default: return 'Round of $size';
  }
}

Future<void> showDrawSheet(
  BuildContext context, {
  required String tournamentId,
  required String tournamentName,
  required String format,
  required int registeredPairs,
  Map<String, dynamic>? formatSpec,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => DrawSheet(
      tournamentId: tournamentId,
      tournamentName: tournamentName,
      format: format,
      registeredPairs: registeredPairs,
      formatSpec: formatSpec,
    ),
  );
}

class DrawSheet extends StatefulWidget {
  final String tournamentId, tournamentName, format;
  final int registeredPairs;
  final Map<String, dynamic>? formatSpec;
  const DrawSheet({
    super.key,
    required this.tournamentId,
    required this.tournamentName,
    required this.format,
    required this.registeredPairs,
    this.formatSpec,
  });

  @override
  State<DrawSheet> createState() => _DrawSheetState();
}

class _DrawSheetState extends State<DrawSheet> {
  bool _loading = true, _busy = false, _forceSetup = false;
  List<Map<String, dynamic>> _matches = [];
  int _groups = 3, _advance = 2, _view = 0; // view: 0 groups · 1 knockout
  String _seed = 'level'; // level | random
  late final _Fmt _fmt;

  @override
  void initState() {
    super.initState();
    _fmt = _deriveFmt();
    _seedConfigFromSpec();
    _load();
  }

  _Fmt _deriveFmt() {
    switch (widget.format) {
      case 'group_knockout':
        return _Fmt.groupsKo;
      case 'round_robin':
        return _Fmt.rr;
      case 'knockout':
      case 'double_elim':
        return _Fmt.single;
      default:
        switch (_firstStageKind()) {
          case 'groups': return _Fmt.groupsKo;
          case 'roundRobin': return _Fmt.rr;
          default: return _Fmt.single;
        }
    }
  }

  String? _firstStageKind() {
    final stages = widget.formatSpec?['stages'];
    if (stages is List && stages.isNotEmpty && stages.first is Map) {
      return (stages.first as Map)['kind'] as String?;
    }
    return null;
  }

  void _seedConfigFromSpec() {
    final stages = widget.formatSpec?['stages'];
    if (stages is List && stages.isNotEmpty && stages.first is Map) {
      final s = stages.first as Map;
      if (s['kind'] == 'groups' && s['cfg'] is Map) {
        final cfg = s['cfg'] as Map;
        _groups = (cfg['groups'] as num?)?.toInt() ?? _groups;
        _advance = (cfg['advance'] as num?)?.toInt() ?? _advance;
      }
    }
  }

  Future<void> _load() async {
    final rows = await AdminService.fetchBracket(widget.tournamentId);
    if (!mounted) return;
    setState(() {
      _matches = rows;
      _loading = false;
      _view = hasKnockout(rows) ? 1 : 0;
    });
  }

  bool get _hasDraw => _matches.isNotEmpty;
  bool get _setup => !_hasDraw || _forceSetup;
  int get _pairs => widget.registeredPairs;
  List<int> get _sizes => groupSizes(_pairs, _groups);
  int get _minSize => _sizes.isEmpty ? 0 : _sizes.reduce((a, b) => a < b ? a : b);
  bool get _even => _groups > 0 && _pairs % _groups == 0;
  int get _quals => _groups * _advance;

  ({String label, IconData icon, Color tone}) get _meta => switch (_fmt) {
        _Fmt.groupsKo => (label: 'Groups → Knockout', icon: Icons.groups_rounded, tone: _tone(0)),
        _Fmt.single => (label: 'Single elimination', icon: Icons.emoji_events_rounded, tone: _tone(1)),
        _Fmt.rr => (label: 'Round robin', icon: Icons.grid_view_rounded, tone: _tone(2)),
      };

  List<({String sev, String text})> get _warnings {
    final w = <({String sev, String text})>[];
    if (_fmt == _Fmt.groupsKo) {
      if (_pairs < 4) {
        w.add((sev: 'error', text: 'Need at least 4 registered pairs to draw groups — $_pairs so far.'));
      } else if (_minSize < 2) {
        w.add((sev: 'error', text: "$_pairs pairs can't fill $_groups groups — some would have under 2 pairs."));
      } else if (_advance >= _minSize) {
        w.add((sev: 'error', text: 'Advancing $_advance from a group of $_minSize leaves nothing to play for.'));
      } else if (!_even) {
        w.add((sev: 'warn', text: 'Uneven split — groups of ${_sizes.join('/')}. Still valid.'));
      }
    } else if (_fmt == _Fmt.single) {
      if (_pairs < 2) {
        w.add((sev: 'error', text: 'Need at least 2 registered pairs.'));
      } else if (!isPow2(_pairs)) {
        w.add((sev: 'warn', text: '$_pairs pairs → ${nextPow2(_pairs) - _pairs} first-round byes.'));
      }
    } else {
      if (_pairs < 3) w.add((sev: 'error', text: 'Need at least 3 registered pairs for a round robin.'));
    }
    return w;
  }

  bool get _blocked => _warnings.any((w) => w.sev == 'error');

  // ── actions ──────────────────────────────────────────────────────────────
  FormatSpec _buildSpec() {
    switch (_fmt) {
      case _Fmt.groupsKo:
        return FormatSpec(name: 'Groups → Knockout', entrants: _pairs, courts: 3, stages: [
          Stage(id: 'S1', kind: StageKind.groups, name: 'Groups',
              cfg: {'groups': _groups, 'perGroup': 0, 'advance': _advance}),
          Stage(id: 'S2', kind: StageKind.knockout, name: 'Knockout',
              cfg: {'seeds': nextPow2(_quals)}, thirdPlace: false),
        ]);
      case _Fmt.single:
        return FormatSpec(name: 'Single elimination', entrants: _pairs, courts: 3, stages: [
          Stage(id: 'S1', kind: StageKind.knockout, name: 'Knockout',
              cfg: {'seeds': nextPow2(_pairs)}, thirdPlace: false),
        ]);
      case _Fmt.rr:
        return FormatSpec(name: 'Round robin', entrants: _pairs, courts: 3, stages: [
          Stage(id: 'S1', kind: StageKind.roundRobin, name: 'Round robin',
              cfg: {'players': _pairs, 'legs': 1, 'advance': 2}),
        ]);
    }
  }

  Future<void> _generate() async {
    if (_blocked || _busy) return;
    setState(() => _busy = true);
    final err = await AdminService.saveTournamentFormat(widget.tournamentId, _buildSpec()) ??
        await AdminService.generateFromFormat(widget.tournamentId, random: _seed == 'random');
    if (!mounted) return;
    if (err != null) {
      setState(() => _busy = false);
      adminToast(context, err, ok: false);
      return;
    }
    _forceSetup = false;
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
    adminToast(context, 'Draw generated');
  }

  Future<void> _setWinner(String matchId, String? winnerEntry) async {
    if (_busy) return;
    setState(() => _busy = true);
    final err = await AdminService.setMatchWinner(matchId, winnerEntry);
    if (!mounted) return;
    if (err != null) adminToast(context, err, ok: false);
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  void _cycle(DrawFixture f) {
    final next = f.winnerId == f.a.entryId
        ? f.b.entryId
        : f.winnerId == f.b.entryId
            ? null
            : f.a.entryId;
    _setWinner(f.id, next);
  }

  Future<void> _advanceDraw() async {
    if (_busy) return;
    setState(() => _busy = true);
    final err = await AdminService.advanceStage(widget.tournamentId);
    if (!mounted) return;
    if (err != null) {
      adminToast(context, err, ok: false);
      setState(() => _busy = false);
      return;
    }
    await _load();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _view = hasKnockout(_matches) ? 1 : 0;
    });
    adminToast(context, 'Draw advanced');
  }

  // ── build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        height: h * 0.92,
        decoration: const BoxDecoration(
          color: AdminColors.bg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(children: [
          const SizedBox(height: 8),
          Container(width: 42, height: 4,
              decoration: BoxDecoration(color: AdminColors.line, borderRadius: BorderRadius.circular(4))),
          _header(),
          if (!_setup && !_loading) _toolbar(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: AdminColors.primary))
                : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
                    child: _setup ? _setupBody() : _drawBody(),
                  ),
          ),
          _footer(),
        ]),
      ),
    );
  }

  Widget _header() => Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 10, 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Draw & results', style: AdminText.sans(18, FontWeight.w800, AdminColors.ink)),
              const SizedBox(height: 3),
              Text('${widget.tournamentName} · $_pairs pairs · ${_meta.label}',
                  style: AdminText.small(AdminColors.inkSoft)),
            ]),
          ),
          IconButton(
              icon: const Icon(Icons.close_rounded, color: AdminColors.inkSoft),
              onPressed: () => Navigator.pop(context)),
        ]),
      );

  Widget _toolbar() => Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 14, 8),
        child: Row(children: [
          if (_fmt == _Fmt.groupsKo)
            _segToggle()
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(
                  color: AdminColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9)),
              child: Text(_meta.label, style: AdminText.sans(12, FontWeight.w800, AdminColors.primary)),
            ),
          const Spacer(),
          IconButton(
              tooltip: 'Reconfigure',
              icon: const Icon(Icons.settings_outlined, size: 20, color: AdminColors.inkSoft),
              onPressed: () => setState(() => _forceSetup = true)),
        ]),
      );

  Widget _segToggle() {
    Widget seg(String label, IconData ic, int i) {
      final on = _view == i;
      return GestureDetector(
        onTap: () => setState(() => _view = i),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
              color: on ? AdminColors.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(9)),
          child: Row(children: [
            Icon(ic, size: 14, color: on ? AdminColors.primaryInk : AdminColors.inkSoft),
            const SizedBox(width: 6),
            Text(label, style: AdminText.sans(12.5, FontWeight.w800, on ? AdminColors.primaryInk : AdminColors.inkSoft)),
          ]),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
          color: AdminColors.surface,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: AdminColors.line)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        seg('Groups', Icons.groups_rounded, 0),
        seg('Knockout', Icons.emoji_events_rounded, 1),
      ]),
    );
  }

  // ── setup ────────────────────────────────────────────────────────────────
  Widget _setupBody() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('FORMAT', style: AdminText.kicker()),
        const SizedBox(height: 7),
        _lockedFormatCard(),
        const SizedBox(height: 18),
        Text('CONFIGURE', style: AdminText.kicker()),
        const SizedBox(height: 7),
        switch (_fmt) {
          _Fmt.groupsKo => _groupsConfig(),
          _Fmt.single => _singleConfig(),
          _Fmt.rr => _rrConfig(),
        },
        for (final w in _warnings) _warnRow(w.sev, w.text),
        const SizedBox(height: 12),
        _summaryCard(),
        if (_fmt != _Fmt.rr) ...[
          const SizedBox(height: 18),
          Text('SEEDING', style: AdminText.kicker()),
          const SizedBox(height: 7),
          _seedOption('level', Icons.trending_up_rounded, 'Seed by level', 'Top pairs kept apart — fair and predictable.'),
          const SizedBox(height: 9),
          _seedOption('random', Icons.shuffle_rounded, 'Random draw', 'Shuffle everyone in at random.'),
        ],
      ]);

  Widget _groupsConfig() {
    return Container(
      decoration: BoxDecoration(
          color: AdminColors.surface,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: AdminColors.lineSoft)),
      child: Column(children: [
        _cfgRow(
          'Number of groups',
          _even ? '$_groups even groups of ${_sizes.first}' : 'Groups of ${_sizes.join('/')}',
          _Stepper(
            value: _groups,
            min: 2,
            max: _pairs < 4 ? 2 : (_pairs ~/ 2).clamp(2, 99),
            onChanged: (v) => setState(() {
              _groups = v;
              final maxAdv = (_minSize - 1).clamp(1, 99);
              if (_advance > maxAdv) _advance = maxAdv;
            }),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (var i = 0; i < _sizes.length; i++)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(color: _tone(i).withValues(alpha: 0.13), borderRadius: BorderRadius.circular(8)),
                child: Text('Group ${String.fromCharCode(65 + i)} · ${_sizes[i]}',
                    style: AdminText.sans(11.5, FontWeight.w800, _tone(i))),
              ),
          ]),
        ),
        const Divider(height: 1, color: AdminColors.lineSoft),
        _cfgRow(
          'Advance per group',
          'Top $_advance qualify → $_quals into the knockout',
          _Stepper(value: _advance, min: 1, max: (_minSize - 1).clamp(1, 99),
              onChanged: (v) => setState(() => _advance = v)),
        ),
      ]),
    );
  }

  Widget _singleConfig() {
    final size = nextPow2(_pairs);
    return Container(
      decoration: BoxDecoration(
          color: AdminColors.surface,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: AdminColors.lineSoft)),
      child: _cfgRow(
        'Draw size',
        '$_pairs pairs → $size-slot bracket${size > _pairs ? ' · ${size - _pairs} byes' : ''}',
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: AdminColors.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
          child: Text('$size', style: AdminText.mono(14, FontWeight.w800, AdminColors.primary)),
        ),
      ),
    );
  }

  Widget _rrConfig() {
    final total = _pairs < 2 ? 0 : _pairs * (_pairs - 1) ~/ 2;
    return Container(
      decoration: BoxDecoration(
          color: AdminColors.surface,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: AdminColors.lineSoft)),
      child: _cfgRow(
        'Total matches',
        'Everyone plays everyone once',
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: AdminColors.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
          child: Text('$total', style: AdminText.mono(14, FontWeight.w800, AdminColors.primary)),
        ),
      ),
    );
  }

  Widget _summaryCard() {
    final summary = switch (_fmt) {
      _Fmt.groupsKo => '$_groups groups → top $_advance ($_quals) → ${_roundName(nextPow2(_quals))} → champion',
      _Fmt.single => '$_pairs pairs → ${_roundName(nextPow2(_pairs))} → champion',
      _Fmt.rr => '$_pairs pairs · ${_pairs < 2 ? 0 : _pairs * (_pairs - 1) ~/ 2} matches · ranked by standings',
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AdminColors.green.withValues(alpha: 0.09), borderRadius: BorderRadius.circular(11)),
      child: Row(children: [
        const Icon(Icons.check_circle_rounded, size: 15, color: AdminColors.green),
        const SizedBox(width: 8),
        Expanded(child: Text(summary, style: AdminText.sans(12.5, FontWeight.w700, AdminColors.ink))),
      ]),
    );
  }

  Widget _seedOption(String key, IconData ic, String title, String sub) {
    final on = _seed == key;
    return GestureDetector(
      onTap: () => setState(() => _seed = key),
      child: Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
            color: on ? AdminColors.primary.withValues(alpha: 0.07) : AdminColors.surface,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: on ? AdminColors.primary : AdminColors.lineSoft, width: 1.5)),
        child: Row(children: [
          Icon(ic, size: 18, color: on ? AdminColors.primary : AdminColors.inkSoft),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AdminText.sans(13.5, FontWeight.w800, AdminColors.ink)),
              const SizedBox(height: 1),
              Text(sub, style: AdminText.small(AdminColors.inkFaint)),
            ]),
          ),
          Icon(on ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
              size: 19, color: on ? AdminColors.primary : AdminColors.line),
        ]),
      ),
    );
  }

  Widget _lockedFormatCard() => Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
            color: AdminColors.surface,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: AdminColors.lineSoft)),
        child: Row(children: [
          Container(
            width: 38, height: 38, alignment: Alignment.center,
            decoration: BoxDecoration(color: _meta.tone.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
            child: Icon(_meta.icon, size: 19, color: _meta.tone),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_meta.label, style: AdminText.sans(14, FontWeight.w800, AdminColors.ink)),
              const SizedBox(height: 1),
              Text('Set when the tournament was created.', style: AdminText.small(AdminColors.inkFaint)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(color: AdminColors.surface3, borderRadius: BorderRadius.circular(999)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.lock_rounded, size: 12, color: AdminColors.inkSoft),
              const SizedBox(width: 4),
              Text('Fixed', style: AdminText.sans(11, FontWeight.w800, AdminColors.inkSoft)),
            ]),
          ),
        ]),
      );

  Widget _cfgRow(String title, String sub, Widget trailing) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AdminText.sans(14, FontWeight.w800, AdminColors.ink)),
              const SizedBox(height: 2),
              Text(sub, style: AdminText.small(AdminColors.inkFaint)),
            ]),
          ),
          const SizedBox(width: 12),
          trailing,
        ]),
      );

  Widget _warnRow(String sev, String text) {
    final c = sev == 'error' ? AdminColors.danger : AdminColors.warn;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.09), borderRadius: BorderRadius.circular(11)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.info_rounded, size: 15, color: c),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: AdminText.sans(12.5, FontWeight.w600, AdminColors.ink))),
        ]),
      ),
    );
  }

  // ── draw ─────────────────────────────────────────────────────────────────
  Widget _drawBody() {
    switch (_fmt) {
      case _Fmt.rr:
        final g = parseRoundRobin(_matches);
        if (g == null) return _emptyNote('No round-robin matches — regenerate the draw.');
        return Column(children: [
          _hintBar('Tap a cell to set the row pair’s result. Standings update live.'),
          const SizedBox(height: 12),
          CrosstabBoard(group: g, onSet: _setWinner),
        ]);
      case _Fmt.single:
        return _bracketView();
      case _Fmt.groupsKo:
        return _view == 0 ? _groupsBoard() : _bracketView();
    }
  }

  Widget _bracketView() {
    final bd = parseBracket(_matches);
    if (bd.isEmpty) {
      return _emptyNote(_fmt == _Fmt.groupsKo
          ? 'Finish the groups, then Advance to seed the knockout.'
          : 'No bracket yet — regenerate the draw.');
    }
    return Column(children: [
      _hintBar('Tap the winning pair to advance them. Advance the draw for the next round.'),
      const SizedBox(height: 14),
      BracketBoard(data: bd, onPick: _setWinner),
    ]);
  }

  Widget _groupsBoard() {
    final groups = parseGroups(_matches);
    if (groups.isEmpty) return _emptyNote('No group matches yet — regenerate the draw.');
    return Column(children: [
      _hintBar('Tap a fixture to set its winner — standings update live.'),
      const SizedBox(height: 12),
      for (var gi = 0; gi < groups.length; gi++) ...[
        _GroupCard(group: groups[gi], tone: _tone(gi), advance: _advance, onCycle: _cycle),
        if (gi < groups.length - 1) const SizedBox(height: 14),
      ],
    ]);
  }

  Widget _hintBar(String text) => Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(color: AdminColors.info.withValues(alpha: 0.09), borderRadius: BorderRadius.circular(11)),
        child: Row(children: [
          const Icon(Icons.info_rounded, size: 14, color: AdminColors.info),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: AdminText.small(AdminColors.inkSoft))),
        ]),
      );

  Widget _emptyNote(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(child: Text(text, textAlign: TextAlign.center, style: AdminText.small())),
      );

  // ── footer ───────────────────────────────────────────────────────────────
  Widget _footer() {
    Widget? btn;
    if (_setup) {
      btn = AdminButton(
        _hasDraw ? 'Regenerate draw' : 'Generate draw',
        full: true, height: 50, icon: Icons.bolt_rounded,
        onPressed: (_blocked || _busy) ? null : _generate,
      );
    } else if (_fmt == _Fmt.rr) {
      btn = null; // round robin ends in the standings; nothing to advance
    } else if (_fmt == _Fmt.groupsKo && _view == 0) {
      btn = AdminButton('Advance to knockout',
          full: true, height: 50, icon: Icons.arrow_forward_rounded,
          onPressed: _busy ? null : _advanceDraw);
    } else {
      btn = AdminButton('Advance draw',
          full: true, height: 50, icon: Icons.arrow_forward_rounded,
          onPressed: _busy ? null : _advanceDraw);
    }
    if (btn == null) return const SizedBox(height: 8);
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 22),
      decoration: const BoxDecoration(
        color: AdminColors.bg,
        border: Border(top: BorderSide(color: AdminColors.lineSoft)),
      ),
      child: btn,
    );
  }
}

// ── group standings card ─────────────────────────────────────────────────────
class _GroupCard extends StatelessWidget {
  final DrawGroup group;
  final Color tone;
  final int advance;
  final void Function(DrawFixture) onCycle;
  const _GroupCard({required this.group, required this.tone, required this.advance, required this.onCycle});

  @override
  Widget build(BuildContext context) {
    final st = standingsOf(group);
    return Container(
      decoration: BoxDecoration(
          color: AdminColors.surface,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: AdminColors.lineSoft)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          color: tone.withValues(alpha: 0.12),
          child: Row(children: [
            Text(group.label, style: AdminText.sans(13.5, FontWeight.w800, tone)),
            const Spacer(),
            Text('Top $advance advance', style: AdminText.sans(11, FontWeight.w800, tone)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(13, 10, 13, 4),
          child: Column(children: [
            Row(children: [
              const SizedBox(width: 22),
              Expanded(child: Text('PAIR', style: AdminText.kicker())),
              _hCell('P'), _hCell('W'), _hCell('PTS'),
            ]),
            const SizedBox(height: 4),
            for (var i = 0; i < st.length; i++) _stRow(i, st[i]),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(13, 6, 13, 13),
          child: Wrap(spacing: 7, runSpacing: 7, children: [
            for (final f in group.fixtures) _fixturePill(f),
          ]),
        ),
      ]),
    );
  }

  Widget _hCell(String s) => SizedBox(width: 28, child: Center(child: Text(s, style: AdminText.kicker())));

  Widget _stRow(int i, StandingRow r) {
    final qual = i < advance;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(
          width: 22,
          child: Row(children: [
            Container(width: 3, height: 16,
                decoration: BoxDecoration(color: qual ? tone : Colors.transparent, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 5),
            Text('${i + 1}', style: AdminText.mono(11.5, FontWeight.w600, AdminColors.inkSoft)),
          ]),
        ),
        Expanded(
          child: Row(children: [
            Container(
              width: 24, height: 24, alignment: Alignment.center,
              decoration: BoxDecoration(color: tone.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(7)),
              child: Text(r.pair.initials, style: AdminText.mono(9.5, FontWeight.w800, tone)),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(r.pair.lead, maxLines: 1, overflow: TextOverflow.ellipsis, style: AdminText.sans(12.5, FontWeight.w700, AdminColors.ink))),
          ]),
        ),
        SizedBox(width: 28, child: Center(child: Text('${r.played}', style: AdminText.mono(12, FontWeight.w600, AdminColors.inkSoft)))),
        SizedBox(width: 28, child: Center(child: Text('${r.won}', style: AdminText.mono(12, FontWeight.w700, AdminColors.ink)))),
        SizedBox(width: 28, child: Center(child: Text('${r.points}', style: AdminText.mono(12, FontWeight.w800, AdminColors.ink)))),
      ]),
    );
  }

  Widget _fixturePill(DrawFixture f) {
    final w = f.winnerId;
    Widget side(DrawPair p) {
      final won = w == p.entryId;
      final lost = w != null && !won;
      return Text(p.initials,
          style: AdminText.mono(11, FontWeight.w800,
              won ? AdminColors.green : lost ? AdminColors.inkFaint : AdminColors.ink));
    }

    return GestureDetector(
      onTap: () => onCycle(f),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(color: AdminColors.surfaceAlt, borderRadius: BorderRadius.circular(9), border: Border.all(color: AdminColors.line)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          side(f.a),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Text(w == null ? 'v' : '·', style: AdminText.small(AdminColors.inkFaint))),
          side(f.b),
        ]),
      ),
    );
  }
}

// ── stepper ──────────────────────────────────────────────────────────────────
class _Stepper extends StatelessWidget {
  final int value, min, max;
  final ValueChanged<int> onChanged;
  const _Stepper({required this.value, required this.min, required this.max, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget b(IconData ic, bool enabled, VoidCallback onTap) => GestureDetector(
          onTap: enabled ? onTap : null,
          child: Container(
            width: 34, height: 34, alignment: Alignment.center,
            decoration: BoxDecoration(
                color: enabled ? AdminColors.surface : AdminColors.surface3,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: AdminColors.line)),
            child: Icon(ic, size: 15, color: enabled ? AdminColors.ink : AdminColors.inkFaint),
          ),
        );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      b(Icons.remove_rounded, value > min, () => onChanged(value - 1)),
      SizedBox(width: 34, child: Center(child: Text('$value', style: AdminText.mono(15, FontWeight.w800, AdminColors.ink)))),
      b(Icons.add_rounded, value < max, () => onChanged(value + 1)),
    ]);
  }
}

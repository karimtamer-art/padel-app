// ============================================================================
// format_builder_screen.dart — Organizer's Format Builder (console view).
// Compose stages freely, reorder/configure, live sanity bar (entrants + courts
// → matches, run-time, validation with one-tap Fix), preview, save, and
// generate the real draw. Adapted from the v9 handoff to this repo's admin_kit.
// ============================================================================
import 'package:flutter/material.dart';
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';
import '../data/admin_service.dart';
import '../../backend/models/format_model.dart';

const _gold = Color(0xFFB07E22);

const _presets = {
  'Blank canvas': <StageKind>[],
  'Groups → Knockout': [StageKind.groups, StageKind.knockout],
  'Single elimination': [StageKind.knockout],
  'Round robin + final': [StageKind.roundRobin, StageKind.knockout],
  'Swiss → Playoffs': [StageKind.swiss, StageKind.knockout],
};

class FormatBuilderScreen extends StatefulWidget {
  /// When opened for a specific tournament (from its actions) this is fixed.
  /// When opened as a console section (nav) it's null and the organizer picks
  /// which of their tournaments to apply the format to.
  final String? tournamentId;
  final String? organizerId; // scopes the tournament picker (null = all, admin)
  final FormatSpec? initial;
  final int entrants; // registered pairs
  final int courts; // organizer's courts
  final VoidCallback? onSaved;
  const FormatBuilderScreen({
    super.key,
    this.tournamentId,
    this.organizerId,
    this.initial,
    this.entrants = 16,
    this.courts = 3,
    this.onSaved,
  });

  @override
  State<FormatBuilderScreen> createState() => _FormatBuilderScreenState();
}

class _FormatBuilderScreenState extends State<FormatBuilderScreen> {
  late final _name = TextEditingController(
      text: widget.initial?.name ?? 'My custom format');
  late List<Stage> _stages = widget.initial?.stages.isNotEmpty == true
      ? widget.initial!.stages
      : [Stage.of(StageKind.groups), Stage.of(StageKind.knockout)];
  late int _entrants =
      widget.initial?.entrants ?? (widget.entrants < 2 ? 2 : widget.entrants);
  late int _courts = widget.initial?.courts ?? (widget.courts < 1 ? 1 : widget.courts);
  List<Map<String, dynamic>> _saved = [];
  // Standalone mode: pick which tournament to apply the format to.
  late String? _targetId = widget.tournamentId;
  List<Map<String, dynamic>> _tournaments = [];
  bool _busy = false;

  bool get _standalone => widget.tournamentId == null;

  FormatAnalysis get _a => analyzeFormat(_stages, _entrants, _courts);

  @override
  void initState() {
    super.initState();
    _loadSaved();
    if (_standalone) _loadTournaments();
  }

  Future<void> _loadSaved() async {
    final rows = await AdminService.savedFormats();
    if (mounted) setState(() => _saved = rows);
  }

  Future<void> _loadTournaments() async {
    final rows = await AdminService.fetchTournaments(organizerId: widget.organizerId);
    if (mounted) setState(() => _tournaments = rows);
  }

  FormatSpec get _spec => FormatSpec(
      name: _name.text.trim().isEmpty ? 'Custom format' : _name.text.trim(),
      stages: _stages,
      entrants: _entrants,
      courts: _courts);

  void _move(int i, int d) {
    final j = i + d;
    if (j < 0 || j >= _stages.length) return;
    setState(() {
      final t = _stages[i];
      _stages[i] = _stages[j];
      _stages[j] = t;
    });
  }

  void _add(StageKind k) {
    setState(() {
      final expected = _stages.isEmpty ? _entrants : produces(_stages.last);
      _stages = [..._stages, wireStage(Stage.of(k), expected)];
    });
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    // Always keep it in the reusable library; attach to a tournament if chosen.
    await AdminService.saveNamedFormat(_spec);
    String? err;
    if (_targetId != null) {
      err = await AdminService.saveTournamentFormat(_targetId!, _spec);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    adminToast(
        context,
        err ??
            (_targetId != null
                ? 'Format saved & attached'
                : 'Saved to your library'),
        ok: err == null);
    if (err == null) {
      widget.onSaved?.call();
      _loadSaved();
    }
  }

  Future<void> _generate() async {
    if (_targetId == null) {
      adminToast(context, 'Pick a tournament to generate its draw.', ok: false);
      return;
    }
    if (_a.errors > 0) {
      adminToast(context, 'Fix the ${_a.errors} problem(s) first.', ok: false);
      return;
    }
    // Persist the current spec, then build the real matches.
    setState(() => _busy = true);
    await AdminService.saveTournamentFormat(_targetId!, _spec);
    final err = await AdminService.generateFromFormat(_targetId!);
    if (!mounted) return;
    setState(() => _busy = false);
    adminToast(context, err ?? 'Draw generated from format', ok: err == null);
    if (err == null) widget.onSaved?.call();
  }

  @override
  Widget build(BuildContext context) {
    final a = _a;
    return LayoutBuilder(builder: (_, c) {
      final wide = c.maxWidth > 720;
      final canvas = _canvas();
      final side = _side(a);
      return ListView(padding: const EdgeInsets.all(AdminUI.screen), children: [
        _headerRow(),
        if (_standalone) ...[
          const SizedBox(height: 14),
          _targetPicker(),
        ],
        const SizedBox(height: 16),
        _presetsRow(),
        const SizedBox(height: 20),
        _SanityBar(
            entrants: _entrants,
            courts: _courts,
            a: a,
            onEntrants: (v) => setState(() => _entrants = v),
            onCourts: (v) => setState(() => _courts = v),
            onFix: (w) => setState(() => applyFix(_stages, w))),
        const SizedBox(height: 18),
        if (wide)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 3, child: canvas),
            const SizedBox(width: 18),
            Expanded(flex: 2, child: side),
          ])
        else ...[
          canvas,
          const SizedBox(height: 18),
          side
        ],
      ]);
    });
  }

  Widget _targetPicker() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
          color: AdminColors.surfaceAlt,
          borderRadius: AdminUI.fieldR,
          border: Border.all(color: AdminColors.line)),
      child: Row(children: [
        const Icon(Icons.emoji_events_outlined, size: 17, color: AdminColors.inkFaint),
        const SizedBox(width: 8),
        Text('Apply to', style: AdminText.strong(AdminColors.inkSoft)),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              value: _targetId,
              isExpanded: true,
              hint: Text('Library only — pick a tournament to generate',
                  style: AdminText.small(), overflow: TextOverflow.ellipsis),
              dropdownColor: AdminColors.surface,
              items: [
                const DropdownMenuItem<String?>(
                    value: null, child: Text('Library only')),
                for (final t in _tournaments)
                  DropdownMenuItem<String?>(
                    value: t['id'] as String,
                    child: Text((t['name'] as String?) ?? 'Tournament',
                        style: AdminText.body(), overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() => _targetId = v),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _headerRow() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('YOUR EVENTS', style: AdminText.kicker()),
        Text('Format Builder', style: AdminText.h1()),
        const SizedBox(height: 4),
        Text(
            'Build a tournament however you run it. Stack stages, decide how '
            'players move between them, then save or generate the draw.',
            style: AdminText.small()),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: AdminButton(_busy ? 'Working…' : 'Save format',
                icon: Icons.check,
                variant: AdminBtn.ghost,
                full: true,
                onPressed: _busy ? null : _save),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: AdminButton(_busy ? 'Working…' : 'Generate draw',
                icon: Icons.auto_awesome_rounded,
                variant: AdminBtn.primary,
                full: true,
                onPressed: _busy ? null : _generate),
          ),
        ]),
      ]);

  Widget _presetsRow() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('QUICK START — OR BUILD YOUR OWN BELOW', style: AdminText.kicker()),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final e in _presets.entries)
            InkWell(
              onTap: () => setState(() => _stages = e.value.map(Stage.of).toList()),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                decoration: BoxDecoration(
                    color: AdminColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AdminColors.line)),
                child: Text(e.key, style: AdminText.strong()),
              ),
            ),
        ]),
      ]);

  Widget _canvas() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Format name', style: AdminText.strong(AdminColors.inkSoft)),
        const SizedBox(height: 6),
        TextField(
            controller: _name,
            style: AdminText.body(),
            decoration: InputDecoration(
              filled: true,
              fillColor: AdminColors.surfaceAlt,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              border: OutlineInputBorder(
                  borderRadius: AdminUI.fieldR,
                  borderSide: const BorderSide(color: AdminColors.line)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: AdminUI.fieldR,
                  borderSide: const BorderSide(color: AdminColors.line)),
            )),
        const SizedBox(height: 12),
        Text('STAGES · PLAYED IN ORDER, TOP TO BOTTOM', style: AdminText.kicker()),
        const SizedBox(height: 10),
        if (_stages.isEmpty)
          Container(
            padding: const EdgeInsets.all(30),
            alignment: Alignment.center,
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AdminColors.line)),
            child: Text('No stages yet — add one or pick a quick-start.',
                style: AdminText.small()),
          ),
        for (var i = 0; i < _stages.length; i++) ...[
          _StageCard(
              stage: _stages[i],
              index: i,
              first: i == 0,
              last: i == _stages.length - 1,
              onUp: () => _move(i, -1),
              onDown: () => _move(i, 1),
              onEdit: () => _editStage(i),
              onRemove: () => setState(() => _stages.removeAt(i))),
          if (i < _stages.length - 1) const _Connector(),
        ],
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: _pickStage,
          icon: const Icon(Icons.add),
          label: const Text('Add a stage'),
          style: OutlinedButton.styleFrom(
              foregroundColor: AdminColors.ink,
              padding: const EdgeInsets.symmetric(vertical: 14),
              side: const BorderSide(color: AdminColors.line)),
        ),
      ]);

  Widget _side(FormatAnalysis a) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AdminCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Live preview', style: AdminText.cardTitle()),
          const SizedBox(height: 10),
          if (a.flow.isEmpty)
            Text('Add stages to see the flow.', style: AdminText.small())
          else
            for (var i = 0; i < a.flow.length; i++) ...[
              Text('STAGE ${i + 1} · ${a.flow[i].stage.name}', style: AdminText.kicker()),
              const SizedBox(height: 6),
              Text('${a.flow[i].inCount} in → ${a.flow[i].matches} matches → ${a.flow[i].outCount} advance',
                  style: AdminText.small()),
              if (i < a.flow.length - 1)
                const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: Icon(Icons.arrow_downward, size: 14, color: AdminColors.inkFaint)),
            ],
        ])),
        const SizedBox(height: 16),
        AdminCard(
            padding: EdgeInsets.zero,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Your saved formats', style: AdminText.cardTitle())),
          if (_saved.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text('Formats you save appear here to reuse.',
                  style: AdminText.small(AdminColors.inkFaint)),
            )
          else
            for (final f in _saved)
              Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  decoration: const BoxDecoration(
                      border: Border(top: BorderSide(color: AdminColors.lineSoft))),
                  child: Row(children: [
                    Expanded(child: Text(f['name'] as String? ?? 'Format', style: AdminText.small())),
                    AdminButton('Use',
                        variant: AdminBtn.ghost,
                        onPressed: () => _useSaved(f)),
                  ])),
        ])),
      ]);

  void _useSaved(Map<String, dynamic> f) {
    try {
      final spec = FormatSpec.fromJson(Map<String, dynamic>.from(f['spec'] as Map));
      setState(() {
        _name.text = spec.name;
        _stages = spec.stages.isEmpty
            ? [Stage.of(StageKind.knockout)]
            : spec.stages.map((s) => Stage.fromJson(s.toJson())).toList();
      });
    } catch (_) {
      adminToast(context, 'Could not load that format.', ok: false);
    }
  }

  // ── pick / edit sheets ──────────────────────────────────────────
  void _pickStage() => showModalBottomSheet(
        context: context,
        backgroundColor: AdminColors.surface,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (_) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
              padding: const EdgeInsets.all(18),
              child: Row(children: [
                Expanded(child: Text('Add a stage', style: AdminText.h2())),
                IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context))
              ])),
          for (final k in StageKind.values)
            ListTile(
              leading: Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: kStageMeta[k]!.tone.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10)),
                  child: Icon(kStageMeta[k]!.icon, color: kStageMeta[k]!.tone)),
              title: Text(kStageMeta[k]!.label, style: AdminText.strong()),
              subtitle: Text(kStageMeta[k]!.blurb, style: AdminText.small()),
              trailing: const Icon(Icons.add, color: AdminColors.inkFaint),
              onTap: () {
                Navigator.pop(context);
                _add(k);
              },
            ),
          const SizedBox(height: 8),
        ])),
      );

  void _editStage(int i) {
    final s = _stages[i];
    showModalBottomSheet(
      context: context,
      backgroundColor: AdminColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => StatefulBuilder(builder: (_, setSheet) {
        Widget stepper(String label, String key, List<int> opts) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Expanded(child: Text(label, style: AdminText.strong())),
                DropdownButton<int>(
                    value: opts.contains(s.cfg[key]) ? s.cfg[key] : opts.first,
                    dropdownColor: AdminColors.surface,
                    items: opts
                        .map((o) => DropdownMenuItem(value: o, child: Text('$o', style: AdminText.body())))
                        .toList(),
                    onChanged: (v) => setSheet(() => setState(() => s.cfg[key] = v!))),
              ]),
            );
        return Padding(
            padding: EdgeInsets.fromLTRB(18, 18, 18, MediaQuery.of(context).viewInsets.bottom + 24),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(kStageMeta[s.kind]!.label, style: AdminText.h2()),
                  const SizedBox(height: 10),
                  if (s.kind == StageKind.groups) ...[
                    stepper('Number of groups', 'groups', [2, 3, 4, 6, 8]),
                    stepper('Target players per group', 'perGroup', [3, 4, 5, 6]),
                    stepper('Advance per group', 'advance', [1, 2, 3]),
                  ] else if (s.kind == StageKind.knockout ||
                      s.kind == StageKind.doubleElim ||
                      s.kind == StageKind.consolation) ...[
                    stepper('Seeds / draw size', 'seeds', [4, 8, 16, 32, 64]),
                    if (s.kind == StageKind.knockout)
                      SwitchListTile(
                          value: s.thirdPlace,
                          contentPadding: EdgeInsets.zero,
                          title: Text('3rd-place match', style: AdminText.strong()),
                          activeThumbColor: _gold,
                          onChanged: (v) => setSheet(() => setState(() => s.thirdPlace = v))),
                  ] else if (s.kind == StageKind.roundRobin) ...[
                    stepper('Players', 'players', [4, 5, 6, 8, 10]),
                    stepper('Legs', 'legs', [1, 2]),
                    stepper('Advance', 'advance', [1, 2, 3, 4]),
                  ] else if (s.kind == StageKind.swiss) ...[
                    stepper('Rounds', 'rounds', [3, 4, 5, 6, 7]),
                    stepper('Advance to playoffs', 'advance', [4, 8, 16]),
                  ] else if (s.kind == StageKind.ladder) ...[
                    stepper('Players', 'players', [10, 20, 30, 50]),
                    stepper('Challenge window (±ranks)', 'window', [2, 3, 4, 5]),
                  ],
                  const SizedBox(height: 14),
                  AdminButton('Save stage',
                      icon: Icons.check,
                      full: true,
                      variant: AdminBtn.primary,
                      onPressed: () => Navigator.pop(context)),
                ]));
      }),
    );
  }
}

// ── stage card ──────────────────────────────────────────────────────────
class _StageCard extends StatelessWidget {
  final Stage stage;
  final int index;
  final bool first, last;
  final VoidCallback onUp, onDown, onEdit, onRemove;
  const _StageCard(
      {required this.stage,
      required this.index,
      required this.first,
      required this.last,
      required this.onUp,
      required this.onDown,
      required this.onEdit,
      required this.onRemove});
  @override
  Widget build(BuildContext context) {
    final m = kStageMeta[stage.kind]!;
    return Container(
      decoration: BoxDecoration(
          color: AdminColors.surface,
          borderRadius: AdminUI.cardR,
          border: Border(
              left: BorderSide(color: m.tone, width: 3),
              top: const BorderSide(color: AdminColors.line),
              right: const BorderSide(color: AdminColors.line),
              bottom: const BorderSide(color: AdminColors.line))),
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 10),
      child: Column(children: [
        Row(children: [
          Text('${index + 1}', style: AdminText.mono(11, FontWeight.w700, AdminColors.inkFaint)),
          const SizedBox(width: 11),
          Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: m.tone.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(9)),
              child: Icon(m.icon, size: 18, color: m.tone)),
          const SizedBox(width: 11),
          Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(stage.name, style: AdminText.sans(14, FontWeight.w800, AdminColors.ink)),
            Text(stage.summary, style: AdminText.small()),
          ])),
          AdminButton('Edit',
              icon: Icons.settings_outlined, variant: AdminBtn.ghost, onPressed: onEdit),
        ]),
        const Divider(height: 20, color: AdminColors.lineSoft),
        Row(children: [
          IconButton(
              onPressed: first ? null : onUp,
              icon: const Icon(Icons.keyboard_arrow_up),
              iconSize: 20),
          IconButton(
              onPressed: last ? null : onDown,
              icon: const Icon(Icons.keyboard_arrow_down),
              iconSize: 20),
          const Spacer(),
          IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.delete_outline, size: 18, color: AdminColors.danger)),
        ]),
      ]),
    );
  }
}

class _Connector extends StatelessWidget {
  const _Connector();
  @override
  Widget build(BuildContext context) => const SizedBox(
      height: 22,
      child: Center(child: Icon(Icons.arrow_downward, size: 14, color: AdminColors.inkFaint)));
}

// ── sanity bar ──────────────────────────────────────────────────────────
class _SanityBar extends StatelessWidget {
  final int entrants, courts;
  final FormatAnalysis a;
  final ValueChanged<int> onEntrants, onCourts;
  final ValueChanged<FormatWarning> onFix;
  const _SanityBar(
      {required this.entrants,
      required this.courts,
      required this.a,
      required this.onEntrants,
      required this.onCourts,
      required this.onFix});

  @override
  Widget build(BuildContext context) {
    final tone = a.flow.isEmpty
        ? AdminColors.inkFaint
        : a.errors > 0
            ? AdminColors.danger
            : a.warnings.isNotEmpty
                ? AdminColors.warn
                : AdminColors.green;
    final status = a.flow.isEmpty
        ? 'Add stages to check your format'
        : a.errors > 0
            ? '${a.errors} problem${a.errors > 1 ? 's' : ''} to fix'
            : a.warnings.isNotEmpty
                ? '${a.warnings.length} thing${a.warnings.length > 1 ? 's' : ''} to review'
                : 'Format checks out';
    return AdminCard(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(8)),
              child: Icon(
                  a.ok
                      ? Icons.check_circle_outline
                      : a.errors > 0
                          ? Icons.error_outline
                          : Icons.visibility_outlined,
                  size: 15,
                  color: tone)),
          const SizedBox(width: 8),
          Expanded(child: Text(status, style: AdminText.sans(14.5, FontWeight.w800, tone))),
        ]),
        const SizedBox(height: 13),
        Wrap(spacing: 10, runSpacing: 10, children: [
          _stepper('Pairs registered', entrants, 2, 128, onEntrants),
          _stepper('Courts available', courts, 1, 12, onCourts),
          _stat('Total matches', '${a.totalMatches}'),
          _stat('Est. run time', a.wallClockHours > 0 ? '~${a.wallClockHours.toStringAsFixed(1)}h' : '—'),
        ]),
        if (a.warnings.isNotEmpty) ...[
          const SizedBox(height: 14),
          for (final w in a.warnings)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: (w.sev == 'error' ? AdminColors.danger : AdminColors.warn)
                        .withValues(alpha: 0.09),
                    borderRadius: BorderRadius.circular(10)),
                child: Row(children: [
                  Icon(w.sev == 'error' ? Icons.error_outline : Icons.info_outline,
                      size: 15, color: w.sev == 'error' ? AdminColors.danger : AdminColors.warn),
                  const SizedBox(width: 10),
                  Expanded(child: Text(w.text, style: AdminText.small(AdminColors.ink))),
                  if (w.fixable)
                    AdminButton('Fix', variant: AdminBtn.ghost, onPressed: () => onFix(w)),
                ]),
              ),
            ),
        ],
      ]),
    );
  }

  Widget _stepper(String label, int value, int min, int max, ValueChanged<int> on) => Container(
        width: 150,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
            color: AdminColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AdminColors.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(), style: AdminText.kicker()),
          const SizedBox(height: 6),
          Row(children: [
            IconButton(
                iconSize: 15,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                onPressed: () => on((value - 1).clamp(min, max)),
                icon: const Icon(Icons.remove)),
            Expanded(
                child: Text('$value',
                    textAlign: TextAlign.center,
                    style: AdminText.sans(19, FontWeight.w800, AdminColors.ink))),
            IconButton(
                iconSize: 15,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                onPressed: () => on((value + 1).clamp(min, max)),
                icon: const Icon(Icons.add)),
          ]),
        ]),
      );

  Widget _stat(String label, String value) => Container(
        width: 150,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
            color: AdminColors.surfaceAlt,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AdminColors.lineSoft)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(), style: AdminText.kicker()),
          const SizedBox(height: 6),
          Text(value, style: AdminText.sans(19, FontWeight.w800, AdminColors.ink)),
        ]),
      );
}

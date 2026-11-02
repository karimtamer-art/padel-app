import 'package:flutter/material.dart';
import 'package:padel_clay/backend/models/tournament_bracket.dart';
import 'package:padel_clay/backend/services/tournament_service.dart';
import 'package:padel_clay/frontend/theme/tournament_tokens.dart';
import 'package:padel_clay/frontend/widgets/tournament_kit.dart';

/// "You & Omar" for the player's own pair, whichever of the two they are;
/// "A. Samir / Y. Adel" for everyone else's.
String pairNameFor(Map<String, dynamic>? e, String? uid) {
  if (e == null) return 'TBD';
  if (!entryHasPlayer(e, uid)) return TournamentService.pairLabel(e);
  final other = (e['player_id'] == uid ? e['partner_name'] : e['player_name'])
      as String?;
  final first = other?.trim().split(RegExp(r'\s+')).first ?? '';
  return first.isEmpty ? 'You' : 'You & $first';
}

/// Every round a player could have a match in, in playing order.
List<BracketRound> allRoundsOf(List<Map<String, dynamic>> rows,
        {required bool doubleElim}) =>
    isLegacyDraw(rows)
        ? [
            ...buildWinners(rows, doubleElim: doubleElim).rounds,
            ...buildLosers(rows),
            if (buildGrandFinal(rows) case final gf?) gf,
          ]
        : [...buildGroups(rows), ...buildFreeKnockout(rows)];

/// What the bracket tab has selected. Lives on the detail screen so it survives
/// switching tabs, and so the bottom bar's "Details" can jump to a match.
class BracketSelection {
  int side = 0; // 0 winners, 1 losers, 2 grand final
  String? roundId; // null = the current round
  int? stage; // 0 groups, 1 knockout; null = whichever is in play
  String? group; // null = the player's own, else the first

  /// Points the tab at the round [slot] sits in.
  void showSlot(BracketSlot slot) {
    side = switch (slot.side) { 'lb' => 1, 'gf' => 2, _ => 0 };
    if (isGroupLabel(slot.side)) {
      stage = 0;
      group = slot.side;
    } else {
      stage = 1;
      roundId = slot.roundId;
    }
  }
}

class BracketView extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>> entries;
  final String? uid;
  final bool doubleElim;
  final Map<String, dynamic>? formatSpec;

  /// The server's standings; null when they can't be read.
  final List<Map<String, dynamic>>? standings;

  /// The event is over, for events with no grand final to name a champion.
  final bool finished;

  /// "Fri, Nov 6 at 5:00 PM" when a future draw time is set.
  final String? drawAtLabel;
  final BracketSelection selection;
  final VoidCallback onSelectionChanged;
  final Future<void> Function() onRefresh;
  final void Function(Map<String, dynamic> row) onOpenResult;

  const BracketView({
    super.key,
    required this.rows,
    required this.entries,
    required this.uid,
    required this.doubleElim,
    required this.formatSpec,
    required this.standings,
    this.finished = false,
    this.drawAtLabel,
    required this.selection,
    required this.onSelectionChanged,
    required this.onRefresh,
    required this.onOpenResult,
  });

  void _select(void Function() change) {
    change();
    onSelectionChanged();
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> children;
    if (rows.isEmpty) {
      children = _noDraw(context);
    } else if (isLegacyDraw(rows)) {
      final grandFinal = doubleElim ? buildGrandFinal(rows) : null;
      children = selection.side == 2 && grandFinal != null
          ? _grandFinal(grandFinal)
          : selection.side == 1 && doubleElim
              ? _losers()
              : _winners();
    } else {
      children = _freeFormat();
    }
    return RefreshIndicator(
      color: TColors.accent,
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 14),
            children[i],
          ],
        ],
      ),
    );
  }

  // ── No draw yet ───────────────────────────────────────────────────────────

  List<Widget> _noDraw(BuildContext context) => [
        // TODO(notifications): the design adds "We'll notify you the moment your
        // first match is set" and a "Notifications on" pill. Nothing notifies on
        // a draw yet (generate_draw has no notifications insert), so promising it
        // would be untrue. Restore both once the server sends one.
        EmptyStateCard(
          illustration: const GhostBracket(),
          title: "The draw isn't out yet",
          body: drawAtLabel != null
              ? 'Organisers make the draw on $drawAtLabel. Your matches '
                  'will appear here as soon as it is published.'
              : 'Organisers make the draw before play starts. Your matches '
                  'will appear here as soon as it is published.',
        ),
        if (doubleElim) _howDoubleElimWorks(),
        if (entries.isNotEmpty) _registeredPairs(context),
      ];

  Widget _howDoubleElimWorks() {
    Widget card(int lives, String title, String body) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: TColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: TColors.border),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              LivesIndicator(lives, size: 10),
              const SizedBox(height: 6),
              Text(title, style: tStyle(13, FontWeight.w700)),
              const SizedBox(height: 6),
              Text(body,
                  style: tStyle(12, FontWeight.w400,
                      color: TColors.muted, height: 1.3)),
            ]),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('How double elimination works', style: tStyle(16, FontWeight.w800)),
      const SizedBox(height: 10),
      IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          card(2, '2 lives', 'Everyone starts in Winners'),
          const SizedBox(width: 8),
          card(1, 'Lose once', 'Drop to Losers, keep playing'),
          const SizedBox(width: 8),
          card(0, 'Lose twice', "You're out. Min. 2 matches"),
        ]),
      ),
      const SizedBox(height: 8),
      Text(
          'The final is one match, so the Winners champion can lose it and finish second.',
          style: tStyle(12.5, FontWeight.w400, color: TColors.muted, height: 1.35)),
    ]);
  }

  Widget _registeredPairs(BuildContext context) {
    final mine = entries.where((e) => entryHasPlayer(e, uid));
    final others = entries.where((e) => !entryHasPlayer(e, uid));
    final ordered = [...mine, ...others];
    const shown = 5;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TournamentSectionHeader(
        'Registered pairs · ${entries.length}',
        size: 16,
        action: entries.length > shown ? 'See all' : null,
        onAction: () => _showAllPairs(context, ordered),
      ),
      const SizedBox(height: 4),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final e in ordered.take(shown))
          PairChip(pairNameFor(e, uid), you: entryHasPlayer(e, uid)),
        if (ordered.length > shown)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text('+${ordered.length - shown} more',
                style: tStyle(13, FontWeight.w600, color: TColors.muted)),
          ),
      ]),
    ]);
  }

  void _showAllPairs(BuildContext context, List<Map<String, dynamic>> ordered) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TColors.cream,
      shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(TRadius.sheet))),
      builder: (_) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.7),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
            children: [
              Text('Registered pairs · ${ordered.length}',
                  style: tStyle(20, FontWeight.w800)),
              const SizedBox(height: 12),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final e in ordered)
                  PairChip(pairNameFor(e, uid), you: entryHasPlayer(e, uid)),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  // ── Knockout, winners ─────────────────────────────────────────────────────

  Widget _titleRow() => Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text('Knockout', style: tStyle(20, FontWeight.w800)),
            if (doubleElim) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: TColors.paleGreen,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('DOUBLE ELIM',
                    style: tStyle(11, FontWeight.w700,
                        color: TColors.green, letterSpacing: 0.8)),
              ),
            ],
          ]),
          if (doubleElim)
            CreamSegmented(
              compact: true,
              // "Final" arrives with the match itself. Showing it before then
              // would promise one on a server that doesn't open them yet.
              labels: buildGrandFinal(rows) != null
                  ? const ['Winners', 'Losers', 'Final']
                  : const ['Winners', 'Losers'],
              index: selection.side,
              onChanged: (i) => _select(() {
                selection.side = i;
                selection.roundId = null;
              }),
            ),
        ],
      );

  List<Widget> _winners() {
    final winners =
        buildWinners(rows, doubleElim: doubleElim, finished: finished);
    final losers = doubleElim ? buildLosers(rows) : const <BracketRound>[];
    final rounds = winners.rounds;
    final selected = _selectedRound(rounds);
    return [
      _titleRow(),
      _RoundTiles(
        rounds: rounds,
        selected: selected,
        onPick: (r) => _select(() => selection.roundId = r.id),
      ),
      if (winners.champion != null) _championCard(winners.champion!),
      if (_contextBanner(winners, losers) case final banner?) banner,
      for (final s in selected.slots) _slotCard(s),
    ];
  }

  List<Widget> _grandFinal(BracketRound round) {
    final winners = buildWinners(rows, doubleElim: true, finished: finished);
    return [
      _titleRow(),
      if (winners.champion != null) _championCard(winners.champion!),
      _slotCard(round.slots.single),
    ];
  }

  BracketRound _selectedRound(List<BracketRound> rounds) {
    for (final r in rounds) {
      if (r.id == selection.roundId) return r;
    }
    return rounds[currentRoundIndex(rounds)];
  }

  Widget _championCard(Map<String, dynamic> e) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: TColors.green,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(children: [
          const Icon(Icons.emoji_events_outlined,
              size: 22, color: TColors.white),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('CHAMPIONS',
                  style: tStyle(11, FontWeight.w700,
                      color: TColors.onGreenMuted, letterSpacing: 1)),
              Text(pairNameFor(e, uid),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tStyle(16, FontWeight.w700, color: TColors.white)),
            ]),
          ),
        ]),
      );

  /// Where the player stands. Null when they aren't in this draw.
  Widget? _contextBanner(KnockoutBracket winners, List<BracketRound> losers) {
    final all = [
      ...winners.rounds,
      ...losers,
      if (buildGrandFinal(rows) case final gf?) gf,
    ];
    final inDraw = all.any((r) => r.slots.any((s) => s.involves(uid)));
    if (!inDraw) return null;
    final mine = rows
        .expand((r) => [r['e1'], r['e2']])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .firstWhere((e) => entryHasPlayer(e, uid));
    final pair = pairNameFor(mine, uid);
    final verb = pair == 'You' ? "You're" : '$pair are';

    if (winners.champion != null && entryHasPlayer(winners.champion, uid)) {
      return null; // the champions card just above already says so
    }
    final next = nextMatchFor(uid, all);
    // Advancing and dropping down both write the next row straight away, so
    // having none means the pair is out.
    if (next == null) return _banner('$verb out of the tournament.', '');
    final where = next.side == 'lb'
        ? 'the Losers bracket'
        : switch (next.roundLabel) {
            'Grand final' => 'the Grand final',
            'WB Final' => 'the Winners final',
            'Final' => 'the Final',
            'Semis' => 'the Semifinals',
            'Quarters' => 'the Quarterfinals',
            final l => 'the Round of ${l.substring(1)}',
          };
    final opp = opponentEntry(next, uid);
    final waiting =
        opponentPlaceholder(next, uid)?.replaceFirst('Winner of ', '');
    final rest = opp != null
        ? 'Next: vs ${pairNameFor(opp, uid)}.'
        : waiting != null
            ? 'Waiting on $waiting.'
            : 'Waiting for your opponents.';
    return _banner('$verb in $where.', rest);
  }

  Widget _banner(String strong, String rest) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: TColors.accentTint,
          borderRadius: BorderRadius.circular(TRadius.button),
          border: Border.all(color: TColors.accentTintBorder),
        ),
        child: Row(children: [
          const Icon(Icons.emoji_events_outlined,
              size: 20, color: TColors.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(TextSpan(children: [
              TextSpan(
                  text: strong,
                  style:
                      tStyle(14, FontWeight.w700, color: TColors.accentDeep)),
              if (rest.isNotEmpty)
                TextSpan(
                    text: ' $rest',
                    style:
                        tStyle(14, FontWeight.w400, color: TColors.accentDeep)),
            ])),
          ),
        ]),
      );

  // ── Knockout, losers ──────────────────────────────────────────────────────

  List<Widget> _losers() {
    final winners = buildWinners(rows, doubleElim: true, finished: finished);
    final rounds = buildLosers(rows);
    return [
      _titleRow(),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: TColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: TColors.border),
        ),
        child: Row(children: [
          const LivesIndicator(1, size: 12),
          const SizedBox(width: 12),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: tStyle(13, FontWeight.w400,
                    color: TColors.text2, height: 1.35),
                children: [
                  const TextSpan(text: 'Every pair gets two lives. '),
                  TextSpan(
                      text: 'Lose once',
                      style: tStyle(13, FontWeight.w700,
                          color: TColors.text2, height: 1.35)),
                  const TextSpan(text: ' and you play on here. '),
                  TextSpan(
                      text: 'Lose again',
                      style: tStyle(13, FontWeight.w700,
                          color: TColors.text2, height: 1.35)),
                  const TextSpan(text: " and you're out."),
                ],
              ),
            ),
          ),
        ]),
      ),
      if (rounds.isEmpty)
        const EmptyStateCard(
          title: 'Nobody here yet',
          body: 'No one has dropped to the losers bracket yet.',
        )
      else ...[
        _RoundTiles(
          rounds: rounds,
          selected: _selectedRound(rounds),
          onPick: (r) => _select(() => selection.roundId = r.id),
        ),
        for (final s in _selectedRound(rounds).slots)
          _slotCard(s, losersOf: winners),
      ],
    ];
  }

  // ── Groups and free-label knockouts ───────────────────────────────────────

  List<Widget> _freeFormat() {
    final groups = buildGroups(rows);
    final knockout = buildFreeKnockout(rows);
    if (groups.isEmpty) return _freeKnockout(knockout);

    final groupsDone = groups.every((g) => g.finished);
    final stage = selection.stage ?? (knockout.isNotEmpty && groupsDone ? 1 : 0);
    final showStepper = knockout.isNotEmpty || hasLaterStage(formatSpec);
    return [
      if (showStepper) _stageStepper(stage),
      if (stage == 1)
        ...(knockout.isEmpty
            ? [
                const EmptyStateCard(
                  title: 'Knockout comes next',
                  body: 'The draw appears here once the group stage finishes.',
                )
              ]
            : _freeKnockout(knockout))
      else
        ..._groupStage(groups),
    ];
  }

  List<Widget> _freeKnockout(List<BracketRound> rounds) {
    final selected = _selectedRound(rounds);
    return [
      _RoundTiles(
        rounds: rounds,
        selected: selected,
        onPick: (r) => _select(() => selection.roundId = r.id),
      ),
      for (final s in selected.slots) _slotCard(s),
    ];
  }

  Widget _stageStepper(int stage) {
    Widget step(int i, String label) {
      final on = stage == i;
      return Expanded(
        child: Semantics(
          button: true,
          selected: on,
          label: label,
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _select(() {
              selection.stage = i;
              selection.roundId = null;
            }),
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                color: on ? TColors.green : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: on ? TColors.white : Colors.transparent,
                    border: on
                        ? null
                        : Border.all(color: TColors.faint, width: 1.5),
                  ),
                  child: Text('${i + 1}',
                      style: tStyle(12, on ? FontWeight.w800 : FontWeight.w700,
                          color: on ? TColors.green : TColors.text2)),
                ),
                const SizedBox(width: 8),
                Text(label,
                    style: tStyle(14, on ? FontWeight.w700 : FontWeight.w600,
                        color: on ? TColors.white : TColors.text2)),
              ]),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: TColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: TColors.border),
      ),
      child: Row(children: [
        step(0, 'Groups'),
        const SizedBox(width: 4),
        const Icon(Icons.chevron_right_rounded, size: 18, color: TColors.faint),
        const SizedBox(width: 4),
        step(1, 'Knockout'),
      ]),
    );
  }

  List<Widget> _groupStage(List<BracketRound> groups) {
    bool mine(BracketRound g) => g.slots.any((s) => s.involves(uid));
    BracketRound selected = groups.firstWhere(
      (g) => g.id == selection.group,
      orElse: () => groups.firstWhere(mine, orElse: () => groups.first),
    );
    final server = standings;

    // The match needing the player goes first, then the rest as drawn.
    final slots = selected.slots.toList()
      ..sort((a, b) {
        int rank(BracketSlot s) => s.canAct(uid) ? 0 : 1;
        return rank(a).compareTo(rank(b));
      });

    return [
      if (groups.length > 1)
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final g in groups)
            _GroupPill(
              label: mine(g) ? '${g.id} · You' : g.id,
              selected: identical(g, selected),
              onTap: () => _select(() => selection.group = g.id),
            ),
        ]),
      if (server == null)
        const EmptyStateCard(
          title: 'Standings are on their way',
          body: "They'll appear here shortly. The matches below are up to date.",
        )
      else
        _StandingsTable(
          lines: standingsFromServer(server, selected),
          uid: uid,
        ),
      Text('${selected.id} matches', style: tStyle(18, FontWeight.w800)),
      for (final s in slots) _slotCard(s),
    ];
  }

  // ── One match ─────────────────────────────────────────────────────────────

  /// [losersOf] marks a losers-bracket card: lives and "Lost QF 2" under names.
  Widget _slotCard(BracketSlot s, {KnockoutBracket? losersOf}) {
    final state = s.state;
    final sets = s.sets;
    final hasScore = (s.score ?? '').trim().isNotEmpty;
    final unreadableScore = hasScore && sets == null;

    MatchTeam team(Map<String, dynamic>? e, String? placeholder, bool first) {
      final won = s.winner != null && e != null && e['id'] == s.winner;
      final lost = s.winner != null && e != null && !won;
      return MatchTeam(
        name: e != null
            ? pairNameFor(e, uid)
            : state == SlotState.bye
                ? 'Bye'
                : placeholder ?? 'TBD',
        placeholder: e == null,
        you: entryHasPlayer(e, uid),
        winner: won,
        lost: lost,
        sets: sets == null
            ? const []
            : [for (final set in sets) first ? set.a : set.b],
        subtitle: losersOf == null ? null : originOf(e, losersOf),
        lives: losersOf == null || e == null ? null : (lost ? 0 : 1),
      );
    }

    final myTeamSubmitted = entryHasPlayer(s.e1, uid) &&
            entryHasPlayer(s.e1, s.row?['submitted_by'] as String?) ||
        entryHasPlayer(s.e2, uid) &&
            entryHasPlayer(s.e2, s.row?['submitted_by'] as String?);
    final canAct = s.canAct(uid);
    final String? action = !canAct
        ? null
        : switch (state) {
            SlotState.ready || SlotState.live => 'Enter result',
            SlotState.disputed => 'Re-enter result',
            SlotState.pending => myTeamSubmitted ? null : 'Confirm result',
            _ => null,
          };

    final (ChipKind chip, String? chipText) = switch (state) {
      SlotState.done => (ChipKind.finalResult, null),
      SlotState.bye => (ChipKind.bye, null),
      SlotState.waiting => (ChipKind.tbd, null),
      SlotState.pending => (ChipKind.awaitingResult, null),
      SlotState.disputed => (ChipKind.disputed, null),
      SlotState.live => (ChipKind.live, null),
      SlotState.ready => canAct
          ? (ChipKind.awaitingResult, null)
          : (ChipKind.upNext, null),
    };

    String title = s.title;
    if (canAct) title = 'YOUR MATCH · $title';

    String? footer = s.next;
    if (unreadableScore) {
      footer = s.score;
    } else if (state == SlotState.pending && canAct && myTeamSubmitted) {
      footer = 'Waiting for the other team to confirm';
    } else if (state == SlotState.bye) {
      footer = 'Goes straight through to the next round';
    }

    return MatchCard(
      title: title,
      status: chip,
      statusText: chipText,
      team1: team(s.e1, s.e1Placeholder, true),
      team2: team(s.e2, s.e2Placeholder, false),
      footer: footer,
      highlighted: action != null,
      actionLabel: action,
      onAction: action == null ? null : () => onOpenResult(s.row!),
      showSetColumns: state != SlotState.bye && !unreadableScore,
    );
  }
}

/// Equal-width round selector. Long draws (32+) scroll sideways instead of
/// squeezing five tiles onto a phone.
class _RoundTiles extends StatelessWidget {
  final List<BracketRound> rounds;
  final BracketRound selected;
  final ValueChanged<BracketRound> onPick;
  const _RoundTiles(
      {required this.rounds, required this.selected, required this.onPick});

  Widget _tile(int i) {
    final r = rounds[i];
    final on = r.id == selected.id;
    return Semantics(
      button: true,
      selected: on,
      excludeSemantics: true,
      label: '${r.label}, ${roundProgress(rounds, i)}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onPick(r),
        child: Container(
          height: 54,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: on ? TColors.green : TColors.surface,
            borderRadius: BorderRadius.circular(TRadius.button),
            border: Border.all(color: on ? TColors.green : TColors.border),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(r.label,
                  style: tStyle(14, FontWeight.w700,
                      color: on ? TColors.white : TColors.text)),
              const SizedBox(height: 1),
              Text(roundProgress(rounds, i),
                  style: tStyle(12, FontWeight.w500,
                      color: on ? TColors.onGreenMuted : TColors.muted)),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (rounds.length <= 4) {
      return Row(children: [
        for (var i = 0; i < rounds.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(child: _tile(i)),
        ],
      ]);
    }
    return SizedBox(
      height: 54,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: rounds.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) => SizedBox(width: 84, child: _tile(i)),
      ),
    );
  }
}

class _GroupPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _GroupPill(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => TapTarget(
        onTap: onTap,
        label: label,
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: selected ? TColors.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(19),
            border:
                selected ? null : Border.all(color: TColors.borderStrong),
          ),
          child: Center(
            widthFactor: 1,
            child: Text(label,
                style: tStyle(14, selected ? FontWeight.w700 : FontWeight.w600,
                    color: selected ? TColors.white : TColors.text2)),
          ),
        ),
      );
}

class _StandingsTable extends StatelessWidget {
  final List<StandingLine> lines;
  final String? uid;
  const _StandingsTable({required this.lines, required this.uid});

  /// How many lines the server says qualify; 0 hides the cut and the legend.
  int get cut => lines.where((l) => l.qualifies).length;

  static const _num = 26.0;
  static const _sets = 44.0;

  Widget _head(String t, double? w, {TextAlign align = TextAlign.center}) {
    final text = Text(t,
        textAlign: align,
        style: tStyle(12, FontWeight.w700,
            color: TColors.muted, letterSpacing: 0.6));
    return w == null ? Expanded(child: text) : SizedBox(width: w, child: text);
  }

  Widget _cell(String t, double w,
          {FontWeight weight = FontWeight.w400,
          TextAlign align = TextAlign.center}) =>
      SizedBox(
        width: w,
        child: Text(t,
            textAlign: align,
            style: tStyle(14, weight, tabular: true)),
      );

  @override
  Widget build(BuildContext context) => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: TColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: TColors.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            color: TColors.sunkenSoft,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(children: [
              _head('#', 28, align: TextAlign.left),
              _head('PAIR', null, align: TextAlign.left),
              _head('P', _num),
              _head('W', _num),
              _head('L', _num),
              _head('SETS', _sets, align: TextAlign.right),
            ]),
          ),
          for (var i = 0; i < lines.length; i++) ...[
            if (cut > 0 && i == cut)
              const _DashedLine()
            else if (i > 0)
              const Divider(height: 1, thickness: 1, color: TColors.divider),
            _line(i),
          ],
          if (cut > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: TColors.divider))),
              child: Row(children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: TColors.statusGreenBg,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: TColors.statusGreenBorder),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Top $cut advance to the knockout',
                      style: tStyle(12, FontWeight.w400, color: TColors.text2)),
                ),
              ]),
            ),
        ]),
      );

  Widget _line(int i) {
    final l = lines[i];
    final you = entryHasPlayer(l.entry, uid);
    final qualifies = l.qualifies;
    return Container(
      color: you ? TColors.accentTint : null,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(children: [
        SizedBox(
          width: 28,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: qualifies ? TColors.statusGreenBg : TColors.sunken,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text('${i + 1}',
                  style: tStyle(12, FontWeight.w800,
                      color: qualifies
                          ? TColors.statusGreenText
                          : TColors.muted)),
            ),
          ),
        ),
        Expanded(
          child: Text(pairNameFor(l.entry, uid),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tStyle(14, you ? FontWeight.w700 : FontWeight.w500,
                  color: you ? TColors.accentTintText : TColors.text)),
        ),
        _cell('${l.played}', _num),
        _cell('${l.won}', _num, weight: FontWeight.w700),
        _cell('${l.lost}', _num),
        _cell('${l.setsWon}–${l.setsLost}', _sets, align: TextAlign.right),
      ]),
    );
  }
}

class _DashedLine extends StatelessWidget {
  const _DashedLine();
  @override
  Widget build(BuildContext context) => CustomPaint(
        size: const Size(double.infinity, 2),
        painter: _DashedLinePainter(),
      );
}

class _DashedLinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = TColors.borderDashed
      ..strokeWidth = 2;
    for (double x = 0; x < size.width; x += 9) {
      canvas.drawLine(Offset(x, 1), Offset(x + 5, 1), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

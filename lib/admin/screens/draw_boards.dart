import 'package:flutter/material.dart';
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';
import '../../backend/models/draw_engine.dart';

// Pass-2 draw boards: a connected single-elimination bracket and a round-robin
// crosstab. Both are pure presentation over parsed engine data (draw_engine.dart)
// and report taps up via callbacks that persist through set_match_winner.

const List<Color> _tones = [
  Color(0xFF3F7896), Color(0xFFC2502A), Color(0xFF2F6B57), Color(0xFF8A4B2B),
  Color(0xFF6E5AA0), Color(0xFF907A52), Color(0xFFB07E22), Color(0xFF3F8B57),
];
Color _tone(int i) => _tones[i % _tones.length];

// ── Bracket ──────────────────────────────────────────────────────────────────
class BracketBoard extends StatelessWidget {
  final BracketData data;
  // pick a winner for a real match; winnerEntry null clears it.
  final void Function(String matchId, String? winnerEntry) onPick;
  const BracketBoard({super.key, required this.data, required this.onPick});

  static const double _cardW = 152, _cardH = 56, _colGap = 34, _rowGap = 16;
  double get _colW => _cardW + _colGap;
  double get _unit => _cardH + _rowGap; // one round-0 slot

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return const SizedBox.shrink();
    final m0 = data.rounds.first.length; // round-1 match count
    final totalH = m0 * _unit;
    final cols = data.rounds.length + 1; // + champion column
    final totalW = cols * _colW;

    double centerY(int r, int j) => _unit * (1 << r) * (j + 0.5);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: totalW,
        height: totalH,
        child: Stack(children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _ConnectorPainter(
                rounds: data.rounds,
                cardW: _cardW,
                colW: _colW,
                centerY: centerY,
                color: AdminColors.line,
              ),
            ),
          ),
          // round columns
          for (var r = 0; r < data.rounds.length; r++)
            for (var j = 0; j < data.rounds[r].length; j++)
              Positioned(
                left: r * _colW,
                top: centerY(r, j) - _cardH / 2,
                width: _cardW,
                height: _cardH,
                child: _MatchCard(match: data.rounds[r][j], onPick: onPick),
              ),
          // champion node
          Positioned(
            left: (data.rounds.length) * _colW,
            top: centerY(data.rounds.length - 1, 0) - _cardH / 2,
            width: _cardW,
            height: _cardH,
            child: _ChampionNode(champ: data.champion),
          ),
        ]),
      ),
    );
  }
}

class _ConnectorPainter extends CustomPainter {
  final List<List<BracketMatch>> rounds;
  final double cardW, colW;
  final double Function(int r, int j) centerY;
  final Color color;
  _ConnectorPainter({
    required this.rounds,
    required this.cardW,
    required this.colW,
    required this.centerY,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    for (var r = 1; r < rounds.length; r++) {
      for (var j = 0; j < rounds[r].length; j++) {
        final childLeft = r * colW;
        final childY = centerY(r, j);
        for (final fi in [2 * j, 2 * j + 1]) {
          final feederRight = (r - 1) * colW + cardW;
          final feederY = centerY(r - 1, fi);
          final midX = (feederRight + childLeft) / 2;
          final path = Path()
            ..moveTo(feederRight, feederY)
            ..lineTo(midX, feederY)
            ..lineTo(midX, childY)
            ..lineTo(childLeft, childY);
          canvas.drawPath(path, p);
        }
      }
    }
    // final → champion
    if (rounds.isNotEmpty) {
      final last = rounds.length - 1;
      final finRight = last * colW + cardW;
      final finY = centerY(last, 0);
      final champLeft = rounds.length * colW;
      final midX = (finRight + champLeft) / 2;
      canvas.drawPath(
        Path()
          ..moveTo(finRight, finY)
          ..lineTo(midX, finY)
          ..lineTo(champLeft, finY),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ConnectorPainter old) =>
      old.rounds != rounds || old.cardW != cardW || old.colW != colW;
}

class _MatchCard extends StatelessWidget {
  final BracketMatch match;
  final void Function(String matchId, String? winnerEntry) onPick;
  const _MatchCard({required this.match, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AdminColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AdminColors.lineSoft),
      ),
      child: Column(children: [
        Expanded(child: _side(match.a, 'a')),
        const Divider(height: 1, color: AdminColors.lineSoft),
        Expanded(child: _side(match.b, 'b')),
      ]),
    );
  }

  Widget _side(DrawPair? p, String which) {
    final isBye = (which == 'a' ? match.aBye : match.bBye) && p == null;
    if (p == null) {
      return _slot(child: Text(isBye ? 'Bye' : 'TBD', style: AdminText.mono(10.5, FontWeight.w600, AdminColors.inkFaint)));
    }
    final win = match.winnerId == p.entryId;
    final lose = match.winnerId != null && !win;
    final canTap = match.bothKnown && match.id != null;
    return InkWell(
      onTap: canTap ? () => onPick(match.id!, win ? null : p.entryId) : null,
      child: _slot(
        child: Row(children: [
          Container(
            width: 20, height: 20, alignment: Alignment.center,
            decoration: BoxDecoration(
                color: (lose ? AdminColors.inkFaint : AdminColors.primary).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(6)),
            child: Text(p.initials, style: AdminText.mono(8.5, FontWeight.w800, lose ? AdminColors.inkFaint : AdminColors.primary)),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(p.lead,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AdminText.sans(11.5, win ? FontWeight.w800 : FontWeight.w600,
                    lose ? AdminColors.inkFaint : AdminColors.ink)),
          ),
          if (win) const Icon(Icons.check_rounded, size: 13, color: AdminColors.green),
        ]),
      ),
    );
  }

  Widget _slot({required Widget child}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9),
        child: Align(alignment: Alignment.centerLeft, child: child),
      );
}

class _ChampionNode extends StatelessWidget {
  final DrawPair? champ;
  const _ChampionNode({required this.champ});
  @override
  Widget build(BuildContext context) {
    final lit = champ != null;
    return Container(
      decoration: BoxDecoration(
        color: lit ? AdminColors.gold.withValues(alpha: 0.12) : AdminColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: lit ? AdminColors.gold : AdminColors.lineSoft),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 9),
      child: Row(children: [
        Icon(Icons.emoji_events_rounded, size: 18, color: lit ? AdminColors.gold : AdminColors.inkFaint),
        const SizedBox(width: 7),
        Expanded(
          child: Text(lit ? champ!.lead : 'Champion',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AdminText.sans(11.5, FontWeight.w800, lit ? AdminColors.ink : AdminColors.inkFaint)),
        ),
      ]),
    );
  }
}

// ── Round-robin crosstab + standings ────────────────────────────────────────
class CrosstabBoard extends StatelessWidget {
  final DrawGroup group;
  final void Function(String matchId, String? winnerEntry) onSet;
  const CrosstabBoard({super.key, required this.group, required this.onSet});

  @override
  Widget build(BuildContext context) {
    final pairs = group.pairs;
    final toneOf = {for (var i = 0; i < pairs.length; i++) pairs[i].entryId: _tone(i)};
    // fixture lookup by unordered pair key
    final fx = <String, DrawFixture>{};
    for (final f in group.fixtures) {
      fx[_key(f.a.entryId, f.b.entryId)] = f;
    }
    final st = standingsOf(group);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(children: [
          for (var i = -1; i < pairs.length; i++) _matrixRow(i, pairs, toneOf, fx),
        ]),
      ),
      const SizedBox(height: 18),
      Text('STANDINGS', style: AdminText.kicker()),
      const SizedBox(height: 8),
      Container(
        decoration: BoxDecoration(
            color: AdminColors.surface,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: AdminColors.lineSoft)),
        padding: const EdgeInsets.fromLTRB(13, 10, 13, 6),
        child: Column(children: [
          Row(children: [
            const SizedBox(width: 22),
            Expanded(child: Text('PAIR', style: AdminText.kicker())),
            _h('P'), _h('W'), _h('L'), _h('PTS'),
          ]),
          const SizedBox(height: 4),
          for (var i = 0; i < st.length; i++) _stRow(i, st[i], toneOf),
        ]),
      ),
    ]);
  }

  static String _key(String a, String b) => (a.compareTo(b) < 0) ? '$a|$b' : '$b|$a';

  Widget _h(String s) => SizedBox(width: 26, child: Center(child: Text(s, style: AdminText.kicker())));

  Widget _matrixRow(int i, List<DrawPair> pairs, Map<String, Color> toneOf,
      Map<String, DrawFixture> fx) {
    const cell = 34.0, head = 120.0;
    if (i == -1) {
      // header row: corner + column initials
      return Row(children: [
        const SizedBox(width: head, height: cell),
        for (final p in pairs)
          SizedBox(
            width: cell, height: cell,
            child: Center(child: Text(p.initials, style: AdminText.mono(10, FontWeight.w800, toneOf[p.entryId]!))),
          ),
      ]);
    }
    final row = pairs[i];
    return Row(children: [
      SizedBox(
        width: head, height: cell,
        child: Row(children: [
          Container(
            width: 22, height: 22, alignment: Alignment.center,
            decoration: BoxDecoration(
                color: toneOf[row.entryId]!.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(6)),
            child: Text(row.initials, style: AdminText.mono(8.5, FontWeight.w800, toneOf[row.entryId]!)),
          ),
          const SizedBox(width: 7),
          Expanded(child: Text(row.lead, maxLines: 1, overflow: TextOverflow.ellipsis, style: AdminText.sans(11.5, FontWeight.w700, AdminColors.ink))),
        ]),
      ),
      for (var j = 0; j < pairs.length; j++) _matrixCell(row, pairs[j], i == j, fx),
    ]);
  }

  Widget _matrixCell(DrawPair row, DrawPair col, bool diag, Map<String, DrawFixture> fx) {
    const cell = 34.0;
    if (diag) {
      return Container(
        width: cell, height: cell,
        margin: const EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: AdminColors.surface3,
          borderRadius: BorderRadius.circular(6),
        ),
      );
    }
    final f = fx[_key(row.entryId, col.entryId)];
    final w = f?.winnerId;
    final rowWon = w == row.entryId;
    final rowLost = w != null && !rowWon;
    final bg = rowWon
        ? AdminColors.green.withValues(alpha: 0.16)
        : rowLost
            ? AdminColors.danger.withValues(alpha: 0.10)
            : AdminColors.surfaceAlt;
    final label = rowWon ? 'W' : rowLost ? 'L' : '';
    return GestureDetector(
      onTap: f == null
          ? null
          : () {
              final next = w == row.entryId ? col.entryId : w == col.entryId ? null : row.entryId;
              onSet(f.id, next);
            },
      child: Container(
        width: cell, height: cell,
        margin: const EdgeInsets.all(1),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6), border: Border.all(color: AdminColors.line)),
        child: Text(label,
            style: AdminText.mono(11, FontWeight.w800, rowWon ? AdminColors.green : AdminColors.danger)),
      ),
    );
  }

  Widget _stRow(int i, StandingRow r, Map<String, Color> toneOf) {
    final lead = i == 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(
          width: 22,
          child: lead
              ? const Icon(Icons.emoji_events_rounded, size: 14, color: AdminColors.gold)
              : Text('${i + 1}', style: AdminText.mono(11.5, FontWeight.w600, AdminColors.inkSoft)),
        ),
        Expanded(
          child: Row(children: [
            Container(
              width: 24, height: 24, alignment: Alignment.center,
              decoration: BoxDecoration(color: toneOf[r.pair.entryId]!.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(7)),
              child: Text(r.pair.initials, style: AdminText.mono(9.5, FontWeight.w800, toneOf[r.pair.entryId]!)),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(r.pair.lead, maxLines: 1, overflow: TextOverflow.ellipsis, style: AdminText.sans(12.5, FontWeight.w700, AdminColors.ink))),
          ]),
        ),
        SizedBox(width: 26, child: Center(child: Text('${r.played}', style: AdminText.mono(12, FontWeight.w600, AdminColors.inkSoft)))),
        SizedBox(width: 26, child: Center(child: Text('${r.won}', style: AdminText.mono(12, FontWeight.w700, AdminColors.ink)))),
        SizedBox(width: 26, child: Center(child: Text('${r.lost}', style: AdminText.mono(12, FontWeight.w600, AdminColors.inkSoft)))),
        SizedBox(width: 26, child: Center(child: Text('${r.points}', style: AdminText.mono(12, FontWeight.w800, AdminColors.ink)))),
      ]),
    );
  }
}

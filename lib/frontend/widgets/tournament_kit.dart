import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../backend/models/ranking_scale.dart' show RankingScale;
import '../theme/tournament_tokens.dart';

// Shared widgets for the tournament screens. Inline styles in
// design-reference/*.dc.html are the spec for everything in this file.

/// Gives any child a 44x44 minimum hit area and a semantic label, whatever size
/// it draws at.
class TapTarget extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final String? label;
  const TapTarget({super.key, required this.child, this.onTap, this.label});

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        enabled: onTap != null,
        label: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            child: Center(widthFactor: 1, heightFactor: 1, child: child),
          ),
        ),
      );
}

enum TButtonStyle { accent, green, outlineGreen, outlineAccent, sunken, outlineQuiet }

class TButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final TButtonStyle style;
  final IconData? icon;
  final IconData? trailingIcon;
  final double height;
  final bool full;
  final double fontSize;
  final double radius;
  final double horizontalPadding;

  const TButton(
    this.label, {
    super.key,
    this.onPressed,
    this.style = TButtonStyle.accent,
    this.icon,
    this.trailingIcon,
    this.height = 50,
    this.full = false,
    this.fontSize = 15,
    this.radius = TRadius.button,
    this.horizontalPadding = 16,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    final (Color bg, Color fg, Color? line) = switch (style) {
      TButtonStyle.accent => (TColors.accent, TColors.white, null),
      TButtonStyle.green => (TColors.green, TColors.white, null),
      TButtonStyle.outlineGreen => (Colors.transparent, TColors.green, TColors.green),
      TButtonStyle.outlineAccent => (Colors.transparent, TColors.accent, TColors.accent),
      TButtonStyle.sunken => (TColors.sunken, TColors.text, null),
      TButtonStyle.outlineQuiet => (Colors.transparent, TColors.text, TColors.borderDashed),
    };
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: line == null ? BorderSide.none : BorderSide(color: line),
    );
    final button = Opacity(
      opacity: disabled ? 0.5 : 1,
      child: SizedBox(
        height: height,
        width: full ? double.infinity : null,
        child: Material(
          color: bg,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            highlightColor: style == TButtonStyle.accent
                ? TColors.accentPressed
                : null,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              child: Row(
                mainAxisSize: full ? MainAxisSize.max : MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 18, color: fg),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tStyle(fontSize, FontWeight.w700, color: fg)),
                  ),
                  if (trailingIcon != null) ...[
                    const SizedBox(width: 6),
                    Icon(trailingIcon, size: 18, color: fg),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    // Short buttons draw small but still answer to a 44px tap.
    return Semantics(
      button: true,
      enabled: !disabled,
      child: height >= 44
          ? button
          : ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Center(widthFactor: 1, heightFactor: 1, child: button),
            ),
    );
  }
}

/// 44px square button on the green header.
class HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const HeaderIconButton(
      {super.key, required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => TapTarget(
        onTap: onTap,
        label: label,
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: TColors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(TRadius.button),
          ),
          child: Icon(icon, size: 20, color: TColors.white),
        ),
      );
}

/// ── StatusChip ──────────────────────────────────────────────────────────────
enum ChipKind {
  open,
  live,
  finalResult,
  upNext,
  tbd,
  enterResult,
  awaitingResult,
  disputed,
  drawSoon,
  bye,
  neutral,
}

class StatusChip extends StatelessWidget {
  final ChipKind kind;

  /// Overrides the default label ("FULL", "UPCOMING"…) for [ChipKind.neutral]
  /// and friends.
  final String? text;
  const StatusChip(this.kind, {super.key, this.text});

  @override
  Widget build(BuildContext context) {
    final (String label, Color bg, Color fg) = switch (kind) {
      ChipKind.open => ('OPEN', TColors.statusGreenBg, TColors.statusGreenText),
      ChipKind.live => ('LIVE', TColors.statusGreenBg, TColors.statusGreenText),
      ChipKind.finalResult => ('FINAL', TColors.neutralChip, TColors.text2),
      ChipKind.upNext => ('UP NEXT', TColors.accentSoft, TColors.accentTintText),
      ChipKind.tbd => ('TBD', TColors.neutralChip, TColors.text2),
      ChipKind.enterResult => ('ENTER RESULT', TColors.accent, TColors.white),
      ChipKind.awaitingResult => ('AWAITING RESULT', TColors.accent, TColors.white),
      ChipKind.disputed => ('DISPUTED', TColors.accent, TColors.white),
      ChipKind.drawSoon => ('DRAW SOON', TColors.accentSoft, TColors.accentDeep),
      ChipKind.bye => ('BYE', TColors.neutralChip, TColors.text2),
      ChipKind.neutral => ('', TColors.neutralChip, TColors.text2),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(TRadius.chip)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (kind == ChipKind.live) ...[
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
                color: TColors.statusGreenDot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
        ],
        Text(text ?? label,
            style:
                tStyle(11, FontWeight.w700, color: fg, letterSpacing: 0.8)),
      ]),
    );
  }
}

/// ── InfoChip ────────────────────────────────────────────────────────────────
class InfoChip extends StatelessWidget {
  final String text;

  /// Translucent caps variant for the green header.
  final bool onGreen;
  const InfoChip(this.text, {super.key, this.onGreen = false});

  @override
  Widget build(BuildContext context) => Container(
        padding: onGreen
            ? const EdgeInsets.symmetric(horizontal: 9, vertical: 4)
            : const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: onGreen
              ? TColors.white.withValues(alpha: 0.14)
              : TColors.sunken,
          borderRadius: BorderRadius.circular(TRadius.chip),
        ),
        child: Text(onGreen ? text.toUpperCase() : text,
            style: onGreen
                ? tStyle(11, FontWeight.w600,
                    color: TColors.white, letterSpacing: 1)
                : tStyle(12, FontWeight.w600, color: TColors.text2)),
      );
}

/// ── DateTile ────────────────────────────────────────────────────────────────
class DateTile extends StatelessWidget {
  final DateTime? date;

  /// Card version has the weekday and is 58x62; header version is 52x56.
  final bool compact;
  const DateTile(this.date, {super.key, this.compact = false});

  static const _days = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
  static const _months = [
    'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
    'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'
  ];

  @override
  Widget build(BuildContext context) {
    final d = date;
    final small = tStyle(11, FontWeight.w600,
        color: TColors.onGreenMuted, letterSpacing: 1);
    return Container(
      width: compact ? 52 : 58,
      height: compact ? 56 : 62,
      decoration: BoxDecoration(
        color: TColors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(TRadius.button),
        border: Border.all(color: TColors.white.withValues(alpha: 0.18)),
      ),
      child: d == null
          ? Center(child: Text('TBD', style: small))
          : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (!compact) Text(_days[d.weekday - 1], style: small),
              Text('${d.day}',
                  style: tStyle(compact ? 22 : 24, FontWeight.w800,
                      color: TColors.white, height: 1)),
              Text(_months[d.month - 1], style: small),
            ]),
    );
  }
}

/// ── SpotsProgress ───────────────────────────────────────────────────────────
class SpotsProgress extends StatelessWidget {
  final int filled;
  final int capacity;

  /// Prize-card version: 14px text, 10px bar, "X of Y spots filled" first.
  final bool large;
  const SpotsProgress(
      {super.key,
      required this.filled,
      required this.capacity,
      this.large = false});

  @override
  Widget build(BuildContext context) {
    final left = math.max(capacity - filled, 0);
    final strong = large
        ? '$filled of $capacity spots filled'
        : '$left ${left == 1 ? 'spot' : 'spots'} left';
    final soft = large ? '$left left' : '$filled of $capacity filled';
    final fs = large ? 14.0 : 13.0;
    final h = large ? 10.0 : 8.0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(strong, style: tStyle(fs, FontWeight.w600)),
        Text(soft, style: tStyle(fs, FontWeight.w400, color: TColors.muted)),
      ]),
      SizedBox(height: large ? 8 : 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(h / 2),
        child: LinearProgressIndicator(
          value: capacity > 0 ? (filled / capacity).clamp(0.0, 1.0) : 0,
          minHeight: h,
          backgroundColor: TColors.barTrack,
          valueColor: const AlwaysStoppedAnimation(TColors.accent),
        ),
      ),
    ]);
  }
}

/// ── HeaderSegmentedTabs ─────────────────────────────────────────────────────
/// The Overview / Bracket switch, sitting inside the green header.
class HeaderSegmentedTabs extends StatelessWidget {
  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;
  const HeaderSegmentedTabs(
      {super.key,
      required this.labels,
      required this.index,
      required this.onChanged});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.20),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: TColors.white.withValues(alpha: 0.10)),
        ),
        child: Row(children: [
          for (var i = 0; i < labels.length; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Expanded(child: _segment(i)),
          ],
        ]),
      );

  Widget _segment(int i) {
    final on = i == index;
    return Semantics(
      selected: on,
      button: true,
      label: labels[i],
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(i),
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            color: on ? TColors.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            boxShadow: on
                ? [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 6,
                        offset: const Offset(0, 2))
                  ]
                : null,
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (on) ...[
              Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                    color: TColors.accent, shape: BoxShape.circle),
              ),
              const SizedBox(width: 7),
            ],
            Text(labels[i],
                style: tStyle(15, on ? FontWeight.w700 : FontWeight.w600,
                    color: on ? TColors.green : TColors.onGreenTab)),
          ]),
        ),
      ),
    );
  }
}

/// ── CreamSegmented ──────────────────────────────────────────────────────────
/// The lighter in-content toggle (Winners / Losers).
class CreamSegmented extends StatelessWidget {
  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  /// Hugs its labels instead of filling the row.
  final bool compact;
  const CreamSegmented(
      {super.key,
      required this.labels,
      required this.index,
      required this.onChanged,
      this.compact = false});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.all(compact ? 3 : 4),
        decoration: BoxDecoration(
          color: TColors.track,
          borderRadius: BorderRadius.circular(compact ? 12 : 14),
        ),
        child: Row(
          mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
          children: [
            for (var i = 0; i < labels.length; i++)
              compact ? _segment(i) : Expanded(child: _segment(i)),
          ],
        ),
      );

  Widget _segment(int i) {
    final on = i == index;
    return Semantics(
      selected: on,
      button: true,
      label: labels[i],
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(i),
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? TColors.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(labels[i],
              style: tStyle(compact ? 13 : 14,
                  on ? FontWeight.w700 : FontWeight.w600,
                  color: on ? TColors.text : TColors.text2)),
        ),
      ),
    );
  }
}

/// ── StickyActionBar ─────────────────────────────────────────────────────────
class StickyActionBar extends StatelessWidget {
  /// Optional circle/icon before the text.
  final Widget? leading;
  final Widget left;
  final Widget? button;

  /// The price layout: the button takes all the room left of the price.
  final bool expandButton;
  const StickyActionBar({
    super.key,
    this.leading,
    required this.left,
    this.button,
    this.expandButton = false,
  });

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).padding.bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(20, 12, 20, math.max(16, inset + 8)),
      decoration: BoxDecoration(
        color: TColors.surface,
        border: const Border(top: BorderSide(color: TColors.border)),
        boxShadow: [
          BoxShadow(
            color: TColors.text.withValues(alpha: 0.08),
            blurRadius: 24,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: Row(children: [
        if (leading != null) ...[leading!, const SizedBox(width: 12)],
        if (expandButton) left else Expanded(child: left),
        if (button != null) ...[
          const SizedBox(width: 12),
          if (expandButton) Expanded(child: button!) else button!,
        ],
      ]),
    );
  }
}

/// Eyebrow + value, the left side of [StickyActionBar].
class BarLabel extends StatelessWidget {
  final String? eyebrow;
  final String value;
  final String? sub;
  final double valueSize;
  const BarLabel(
      {super.key,
      this.eyebrow,
      required this.value,
      this.sub,
      this.valueSize = 16});

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (eyebrow != null)
            Text(eyebrow!,
                style: tStyle(11, FontWeight.w700,
                    color: TColors.muted, letterSpacing: 1)),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tStyle(valueSize,
                  valueSize > 16 ? FontWeight.w800 : FontWeight.w700)),
          if (sub != null)
            Text(sub!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tStyle(12.5, FontWeight.w400, color: TColors.muted)),
        ],
      );
}

/// ── TournamentSectionHeader ─────────────────────────────────────────────────
/// Named apart from `SectionHeader` in common.dart, which the rest of the app
/// uses and which looks different.
class TournamentSectionHeader extends StatelessWidget {
  final String? eyebrow;
  final String title;
  final double size;
  final String? action;
  final VoidCallback? onAction;
  const TournamentSectionHeader(this.title,
      {super.key, this.eyebrow, this.size = 24, this.action, this.onAction});

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (eyebrow != null) ...[
                Text(eyebrow!,
                    style: tStyle(12, FontWeight.w700,
                        color: TColors.accent, letterSpacing: 1.4)),
                const SizedBox(height: 2),
              ],
              Text(title, style: tStyle(size, FontWeight.w800)),
            ]),
          ),
          if (action != null)
            TapTarget(
              onTap: onAction,
              child: Text(action!,
                  style: tStyle(14, FontWeight.w600, color: TColors.accent)),
            ),
        ],
      );
}

/// ── LivesIndicator ──────────────────────────────────────────────────────────
class LivesIndicator extends StatelessWidget {
  final int lives; // 0, 1 or 2
  final double size;
  const LivesIndicator(this.lives, {super.key, this.size = 8});

  @override
  Widget build(BuildContext context) => Semantics(
        label: '$lives ${lives == 1 ? 'life' : 'lives'} left',
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < 2; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < lives ? TColors.accent : Colors.transparent,
                border: i < lives
                    ? null
                    : Border.all(color: TColors.accent, width: 1.5),
              ),
            ),
          ],
        ]),
      );
}

/// ── EmptyStateCard ──────────────────────────────────────────────────────────
class EmptyStateCard extends StatelessWidget {
  final Widget? illustration;
  final String title;
  final String body;
  final Widget? pill;
  const EmptyStateCard(
      {super.key,
      this.illustration,
      required this.title,
      required this.body,
      this.pill});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: TColors.surface,
          borderRadius: BorderRadius.circular(TRadius.card),
          border: Border.all(color: TColors.border),
        ),
        child: Column(children: [
          if (illustration != null) ...[
            illustration!,
            const SizedBox(height: 14),
          ],
          Text(title,
              textAlign: TextAlign.center,
              style: tStyle(20, FontWeight.w800)),
          const SizedBox(height: 4),
          Text(body,
              textAlign: TextAlign.center,
              style: tStyle(14, FontWeight.w400,
                  color: TColors.muted, height: 1.4)),
          if (pill != null) ...[const SizedBox(height: 14), pill!],
        ]),
      );
}

/// The ghost bracket from the "no draw yet" state.
class GhostBracket extends StatelessWidget {
  const GhostBracket({super.key});
  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(220, 92), painter: _GhostBracketPainter());
}

class _GhostBracketPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final box = Paint()..color = TColors.sunken;
    final line = Paint()
      ..color = TColors.borderDashed
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    void rect(double x, double y, double w, double h, double r, Paint p) =>
        canvas.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromLTWH(x, y, w, h), Radius.circular(r)),
            p);
    for (final y in [4.0, 28.0, 50.0, 74.0]) {
      rect(2, y, 60, 16, 6, box);
    }
    rect(86, 16, 52, 16, 6, box);
    rect(86, 62, 52, 16, 6, box);
    rect(162, 38, 56, 18, 7, Paint()..color = TColors.accentSoft);
    canvas.drawPath(
      Path()
        ..moveTo(62, 12)
        ..relativeLineTo(12, 0)
        ..relativeLineTo(0, 24)
        ..relativeLineTo(-12, 0)
        ..moveTo(62, 58)
        ..relativeLineTo(12, 0)
        ..relativeLineTo(0, 24)
        ..relativeLineTo(-12, 0)
        ..moveTo(74, 24)
        ..relativeLineTo(12, 0)
        ..moveTo(74, 70)
        ..relativeLineTo(12, 0)
        ..moveTo(138, 24)
        ..relativeLineTo(12, 0)
        ..relativeLineTo(0, 46)
        ..relativeLineTo(-12, 0)
        ..moveTo(150, 47)
        ..relativeLineTo(12, 0),
      line,
    );
    canvas.drawLine(
      const Offset(181, 47),
      const Offset(199, 47),
      Paint()
        ..color = TColors.accent
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// ── MatchCard ───────────────────────────────────────────────────────────────
class MatchTeam {
  final String name;

  /// Under the name: where a losers-bracket pair came from ("Lost QF 2").
  final String? subtitle;
  final bool you;
  final bool winner;
  final bool lost;

  /// True for "TBD" / "Winner of SF 2", which are not a pair yet.
  final bool placeholder;
  final List<int> sets;

  /// Double-elim lives; null hides the indicator.
  final int? lives;
  const MatchTeam({
    required this.name,
    this.subtitle,
    this.you = false,
    this.winner = false,
    this.lost = false,
    this.placeholder = false,
    this.sets = const [],
    this.lives,
  });
}

class MatchCard extends StatelessWidget {
  final String title;
  final ChipKind status;
  final String? statusText;
  final MatchTeam team1;
  final MatchTeam team2;
  final String? footer;

  /// 2px terracotta border + tinted header: this match needs the player.
  final bool highlighted;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// True when the match has been played but its score couldn't be split into
  /// sets, so [footer] carries it instead of dashes.
  final bool showSetColumns;

  const MatchCard({
    super.key,
    required this.title,
    required this.status,
    this.statusText,
    required this.team1,
    required this.team2,
    this.footer,
    this.highlighted = false,
    this.actionLabel,
    this.onAction,
    this.showSetColumns = true,
  });

  @override
  Widget build(BuildContext context) => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: TColors.surface,
          borderRadius: BorderRadius.circular(TRadius.matchCard),
          border: highlighted
              ? Border.all(color: TColors.accent, width: 2)
              : Border.all(color: TColors.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: highlighted ? TColors.accentTint : null,
              border: highlighted
                  ? null
                  : const Border(bottom: BorderSide(color: TColors.divider)),
            ),
            child: Row(children: [
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tStyle(12, FontWeight.w700,
                        color: highlighted
                            ? TColors.accentTintText
                            : TColors.muted,
                        letterSpacing: 0.8)),
              ),
              const SizedBox(width: 8),
              StatusChip(status, text: statusText),
            ]),
          ),
          _teamRow(team1, team2),
          _teamRow(team2, team1, topLine: true),
          if (actionLabel != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
              child: TButton(actionLabel!,
                  full: true,
                  height: 48,
                  icon: Icons.edit_outlined,
                  onPressed: onAction),
            )
          else if (footer != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: TColors.divider))),
              child: Text(footer!,
                  style: tStyle(12, FontWeight.w400, color: TColors.muted)),
            ),
        ]),
      );

  Widget _teamRow(MatchTeam t, MatchTeam other, {bool topLine = false}) {
    final color = t.you
        ? TColors.accentTintText
        : t.placeholder
            ? TColors.disabled
            : t.lost
                ? TColors.muted
                : TColors.text;
    final emphasised = t.winner || t.you;
    return Container(
      constraints: BoxConstraints(minHeight: t.subtitle != null ? 52 : 46),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: t.you ? TColors.accentTint : null,
        border: topLine
            ? const Border(top: BorderSide(color: TColors.divider))
            : null,
      ),
      child: Row(children: [
        if (t.lives != null) ...[
          LivesIndicator(t.lives!),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tStyle(15,
                      emphasised ? FontWeight.w700 : FontWeight.w500,
                      color: color)),
              if (t.subtitle != null)
                Text(t.subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tStyle(12, FontWeight.w400, color: TColors.muted)),
            ],
          ),
        ),
        if (t.winner)
          Semantics(
            label: 'Winner',
            child: const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(Icons.check_rounded,
                  size: 18, color: TColors.winnerCheck),
            ),
          ),
        if (showSetColumns) ...[
          const SizedBox(width: 6),
          if (t.sets.isEmpty)
            _setCell('–', won: false)
          else
            for (var i = 0; i < t.sets.length; i++)
              _setCell('${t.sets[i]}',
                  won: i < other.sets.length && t.sets[i] > other.sets[i]),
        ],
      ]),
    );
  }

  Widget _setCell(String v, {required bool won}) => Container(
        width: 26,
        margin: const EdgeInsets.only(left: 2),
        alignment: Alignment.center,
        child: Text(v,
            style: tStyle(15, won ? FontWeight.w800 : FontWeight.w500,
                color: won ? TColors.text : TColors.disabled, tabular: true)),
      );
}

/// Initials for a player name.
String initialsOf(String? name) {
  final parts = (name ?? '')
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .take(2)
      .map((w) => w[0].toUpperCase())
      .join();
  return parts.isEmpty ? 'P' : parts;
}

/// Pair chip used by "Registered pairs".
class PairChip extends StatelessWidget {
  final String label;
  final bool you;
  const PairChip(this.label, {super.key, this.you = false});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: you ? TColors.accentTint : TColors.surface,
          borderRadius: BorderRadius.circular(TRadius.chip),
          border: Border.all(
              color: you ? TColors.accentTintBorder : TColors.border),
        ),
        child: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tStyle(13, you ? FontWeight.w700 : FontWeight.w500,
                color: you ? TColors.accentTintText : TColors.text)),
      );
}

/// "Level D", "Level D–C"; null when the event takes every level.
String? tournamentLevelLabel(double minRating, double? maxRating) {
  final hasMin = minRating > 0;
  final hasMax = maxRating != null && maxRating > 0;
  if (!hasMin && !hasMax) return null;
  final low = RankingScale.divisionFor(hasMin ? minRating : 0).key;
  final high = hasMax ? RankingScale.divisionFor(maxRating).key : null;
  if (high == null) return 'Level $low+';
  return low == high ? 'Level $low' : 'Level $low–$high';
}

/// "Groups + KO", "Knockout"… shared by the list card and the detail header.
String tournamentFormatLabel(Map<String, dynamic>? t) {
  switch (t?['format'] as String?) {
    case 'knockout':
      return 'Knockout';
    case 'double_elim':
      return 'Double elim';
    case 'group_knockout':
      return 'Groups + KO';
    case 'round_robin':
      return 'Round robin';
    case 'custom':
      final note = (t?['format_note'] as String?)?.trim();
      return note != null && note.isNotEmpty ? note : 'Custom';
    default:
      return 'Tournament';
  }
}

/// The status chip for a derived tournament status.
StatusChip tournamentStatusChip(String derived) => switch (derived) {
      'open' => const StatusChip(ChipKind.open),
      'live' => const StatusChip(ChipKind.live),
      'full' => const StatusChip(ChipKind.neutral, text: 'FULL'),
      'closed' => const StatusChip(ChipKind.neutral, text: 'CLOSED'),
      'upcoming' => const StatusChip(ChipKind.neutral, text: 'UPCOMING'),
      'completed' => const StatusChip(ChipKind.neutral, text: 'COMPLETED'),
      'cancelled' => const StatusChip(ChipKind.neutral, text: 'CANCELLED'),
      'postponed' => const StatusChip(ChipKind.neutral, text: 'POSTPONED'),
      _ => StatusChip(ChipKind.neutral, text: derived.toUpperCase()),
    };

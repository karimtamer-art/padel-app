import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../backend/services/season_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_text.dart';
import '../../widgets/common.dart';

// ── Design tokens shared by the card, the board and the reward sheet ─────────

/// Bracket colours, ladder-ordered: gold → silver → clay → bronze → ink.
Color bracketColor(String key) => switch (key) {
      'gold' => AppColors.gold,
      'silver' => const Color(0xFF9BA3AE),
      'primary' => AppColors.primary,
      'bronzegold' => AppColors.bronze,
      _ => AppColors.inkSoft,
    };

IconData seasonIcon(String name) => switch (name) {
      'crown' => Icons.workspace_premium_rounded,
      'medal' => Icons.military_tech_rounded,
      'trophy' => Icons.emoji_events_rounded,
      'star' => Icons.star_rounded,
      'shield' => Icons.shield_rounded,
      'bolt' => Icons.bolt_rounded,
      'fire' => Icons.local_fire_department_rounded,
      'check' => Icons.check_circle_rounded,
      'dash' => Icons.remove_rounded,
      _ => Icons.star_rounded,
    };

String fmtPts(int n) {
  final s = n.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return '${n < 0 ? '-' : ''}$b';
}

bool _stillMotion(BuildContext c) => MediaQuery.of(c).disableAnimations;

// ── Motion primitives ───────────────────────────────────────────────────────

/// `lbShine` — a soft light band sweeping across a surface, forever.
class Sheen extends StatefulWidget {
  final Duration period;
  final double width;
  final double opacity;
  const Sheen({
    super.key,
    this.period = const Duration(milliseconds: 4600),
    this.width = 60,
    this.opacity = 0.16,
  });
  @override
  State<Sheen> createState() => _SheenState();
}

class _SheenState extends State<Sheen> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.period);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_stillMotion(context)) _c.repeat();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, box) => AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final t = Curves.easeInOut.transform(_c.value);
              final x = -widget.width + t * (box.maxWidth + widget.width * 2);
              return Stack(children: [
                Positioned(
                  left: x,
                  top: 0,
                  bottom: 0,
                  width: widget.width,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [
                        Colors.white.withValues(alpha: 0),
                        Colors.white.withValues(alpha: widget.opacity),
                        Colors.white.withValues(alpha: 0),
                      ]),
                    ),
                  ),
                ),
              ]);
            },
          ),
        ),
      ),
    );
  }
}

/// `lbFloat` — a gentle 4px bob (tier pills, the crown).
class Floaty extends StatefulWidget {
  final Widget child;
  final Duration period;
  const Floaty(
      {super.key, required this.child, this.period = const Duration(milliseconds: 3400)});
  @override
  State<Floaty> createState() => _FloatyState();
}

class _FloatyState extends State<Floaty> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.period);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_stillMotion(context)) _c.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, -4 * Curves.easeInOut.transform(_c.value)),
          child: child,
        ),
        child: widget.child,
      );
}

/// `lbRowIn` — fade + 10px rise, staggered by [delay].
class RowIn extends StatelessWidget {
  final Widget child;
  final Duration delay;
  const RowIn({super.key, required this.child, this.delay = Duration.zero});

  @override
  Widget build(BuildContext context) {
    if (_stillMotion(context)) return child;
    return _Delayed(
      delay: delay,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOut,
      builder: (t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 10 * (1 - t)), child: child),
      ),
      child: child,
    );
  }
}

/// `lbPop` — scale 0.6 → 1.08 → 1 with a fade.
class PopIn extends StatelessWidget {
  final Widget child;
  final Duration delay;
  const PopIn({super.key, required this.child, this.delay = Duration.zero});

  @override
  Widget build(BuildContext context) {
    if (_stillMotion(context)) return child;
    return _Delayed(
      delay: delay,
      duration: const Duration(milliseconds: 560),
      curve: Curves.easeOutBack,
      builder: (t, child) => Opacity(
        opacity: t.clamp(0, 1),
        child: Transform.scale(scale: 0.6 + 0.4 * t, child: child),
      ),
      child: child,
    );
  }
}

/// Runs [builder] from 0→1 once, after [delay].
class _Delayed extends StatefulWidget {
  final Duration delay, duration;
  final Curve curve;
  final Widget child;
  final Widget Function(double t, Widget child) builder;
  const _Delayed({
    required this.delay,
    required this.duration,
    required this.curve,
    required this.child,
    required this.builder,
  });
  @override
  State<_Delayed> createState() => _DelayedState();
}

class _DelayedState extends State<_Delayed> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.duration);

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(widget.delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (context, child) =>
            widget.builder(widget.curve.transform(_c.value), child!),
        child: widget.child,
      );
}

/// `lbFill` — a progress bar that grows into place on mount.
class SeasonBar extends StatelessWidget {
  final double value;
  final double height;
  final Color track;
  final List<Color> fill;
  final BorderRadius? radius;
  const SeasonBar(
    this.value, {
    super.key,
    this.height = 5,
    this.track = const Color(0x24FFFFFF),
    this.fill = const [AppColors.primary, AppColors.gold],
    this.radius,
  });

  @override
  Widget build(BuildContext context) {
    final r = radius ?? BorderRadius.circular(height / 2);
    return ClipRRect(
      borderRadius: r,
      child: Container(
        height: height,
        color: track,
        child: Align(
          alignment: Alignment.centerLeft,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: _stillMotion(context) ? value : 0, end: value),
            duration: const Duration(milliseconds: 1150),
            curve: Curves.easeOutCubic,
            builder: (context, t, _) => FractionallySizedBox(
              widthFactor: t.clamp(0, 1),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: r,
                  gradient: LinearGradient(colors: fill),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The JS count-up: 0 → [value] over ~900ms, cubic ease-out.
class CountUp extends StatelessWidget {
  final int value;
  final TextStyle style;
  const CountUp(this.value, {super.key, required this.style});

  @override
  Widget build(BuildContext context) {
    if (_stillMotion(context)) return Text(fmtPts(value), style: style);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value.toDouble()),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => Text(fmtPts(v.round()), style: style),
    );
  }
}

/// The gold wash + sweeping light that sits on every hero surface here.
class _HeroWash extends StatelessWidget {
  final double opacity;
  const _HeroWash({this.opacity = 0.55});
  @override
  Widget build(BuildContext context) => Positioned.fill(
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0.8, -1.25),
                radius: 1.15,
                colors: [
                  AppColors.gold.withValues(alpha: 0.32 * opacity / 0.55),
                  AppColors.gold.withValues(alpha: 0),
                ],
                stops: const [0, 0.62],
              ),
            ),
          ),
        ),
      );
}

/// Avatar with a tier-coloured ring; falls back to initials.
class SeasonAvatar extends StatelessWidget {
  final Standing player;
  final double size;
  final double ring;
  final Color color;
  const SeasonAvatar(this.player,
      {super.key, this.size = 34, this.ring = 1.5, required this.color});

  @override
  Widget build(BuildContext context) {
    final url = player.avatarUrl;
    if (url == null || url.isEmpty) {
      return AppAvatar(player.initials, size: size, color: color, ring: ring);
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color, width: ring),
        image: DecorationImage(image: NetworkImage(url), fit: BoxFit.cover),
      ),
    );
  }
}

// ── Home entry card ─────────────────────────────────────────────────────────

/// The "Season Leaderboard" card that sits under Recent Form on Home.
class SeasonHomeCard extends StatelessWidget {
  final SeasonOverview data;
  final VoidCallback onTap;
  const SeasonHomeCard({super.key, required this.data, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final me = data.me;
    final season = data.season;
    final bracket = me == null ? null : data.bracketFor(me.rank);
    final above = me == null
        ? null
        : _first(data.board.where((r) => r.rank == me.rank - 1));
    // The next bracket up the ladder (the one whose range ends above me).
    final target =
        me == null ? null : _last(data.brackets.where((b) => b.rankTo < me.rank));

    return Padding(
      padding: AppSpacing.screenH,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppRadius.cardR,
            border: Border.all(color: AppColors.line),
            boxShadow: kCardShadow,
          ),
          child: Column(children: [
            // ── top band ──
            Stack(children: [
              Container(
                padding: const EdgeInsets.fromLTRB(16, 15, 16, 18),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AppColors.hero, AppColors.hero2],
                  ),
                ),
                child: Row(children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'SEASON ${season.no} · ${season.daysLeft} DAYS LEFT',
                          style: AppText.tag(AppColors.heroFaint)
                              .copyWith(fontSize: 9.5, letterSpacing: 1.5, fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Text(me == null ? '—' : '#${me.rank}',
                                style: AppText.stat(32, AppColors.heroInk)
                                    .copyWith(letterSpacing: -1.4)),
                            const SizedBox(width: 9),
                            Text(
                              me == null
                                  ? 'Not scored yet'
                                  : '${fmtPts(me.pts)} pts',
                              style: AppText.bodyStrong(AppColors.heroFaint)
                                  .copyWith(fontSize: 12.5),
                            ),
                            if (me != null && me.trend != 0) ...[
                              const SizedBox(width: 9),
                              _TrendChip(me.trend, size: 12),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (bracket != null) ...[
                    const SizedBox(width: 12),
                    Floaty(child: _HeroPill(bracket: bracket)),
                  ],
                ]),
              ),
              const _HeroWash(),
              const Positioned.fill(child: Sheen()),
              // season progress along the bottom edge
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SeasonBar(season.progress,
                    height: 3, radius: BorderRadius.zero),
              ),
            ]),
            // ── foot row ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 13),
              child: Row(children: [
                const Icon(Icons.emoji_events_rounded,
                    size: 16, color: AppColors.gold),
                const SizedBox(width: 10),
                Expanded(
                  child: _footLine(me, above, target, bracket),
                ),
                const Icon(Icons.chevron_right_rounded,
                    size: 18, color: AppColors.primary),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _footLine(Standing? me, Standing? above, SeasonBracket? target,
      SeasonBracket? bracket) {
    final soft = AppText.small(AppColors.inkSoft)
        .copyWith(fontSize: 12.5, height: 1.4);
    final strong = AppText.bodyStrong(AppColors.ink).copyWith(fontSize: 12.5);

    if (me == null) {
      return Text('Play a ranked match to join the season board.', style: soft);
    }
    if (target == null) {
      return Text(
        bracket == null
            ? 'Keep winning to reach a reward bracket.'
            : 'You hold the top spot — ${bracket.prize} on the line.',
        style: soft,
      );
    }
    final gapSpots = me.rank - target.rankTo;
    return RichText(
      text: TextSpan(style: soft, children: [
        if (above != null) ...[
          TextSpan(text: '${fmtPts(above.pts - me.pts)} pts', style: strong),
          TextSpan(text: ' behind ${above.firstName} — '),
        ],
        TextSpan(
            text:
                '$gapSpots spot${gapSpots == 1 ? '' : 's'} from ${target.label}.'),
      ]),
    );
  }
}

/// The translucent tier pill that sits on a hero surface.
class _HeroPill extends StatelessWidget {
  final SeasonBracket bracket;
  final double fontSize;
  const _HeroPill({required this.bracket, this.fontSize = 11});
  @override
  Widget build(BuildContext context) {
    final c = bracketColor(bracket.colorKey);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(seasonIcon(bracket.icon), size: fontSize + 2, color: c),
        const SizedBox(width: 6),
        Text(bracket.short,
            style: AppText.bodyStrong(c)
                .copyWith(fontSize: fontSize, fontWeight: FontWeight.w800)),
      ]),
    );
  }
}

class _TrendChip extends StatelessWidget {
  final int trend;
  final double size;
  final bool muteDown;
  const _TrendChip(this.trend, {this.size = 12, this.muteDown = false});
  @override
  Widget build(BuildContext context) {
    final up = trend >= 0;
    final c = up
        ? AppColors.success
        : (muteDown ? AppColors.inkFaint : AppColors.danger);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(up ? Icons.arrow_drop_up_rounded : Icons.arrow_drop_down_rounded,
          size: size + 6, color: c),
      Text('${trend.abs()}',
          style: AppText.bodyStrong(c)
              .copyWith(fontSize: size - 0.5, fontWeight: FontWeight.w800)),
    ]);
  }
}

// ── Full board ──────────────────────────────────────────────────────────────

class SeasonLeaderboardScreen extends StatefulWidget {
  /// Passed from Home so the board opens already populated.
  final SeasonOverview? initial;
  const SeasonLeaderboardScreen({super.key, this.initial});

  @override
  State<SeasonLeaderboardScreen> createState() =>
      _SeasonLeaderboardScreenState();
}

class _SeasonLeaderboardScreenState extends State<SeasonLeaderboardScreen> {
  SeasonOverview? _data;
  bool _loading = true;
  /// 'all' or a tier name — the board re-ranks 1..n inside the chosen scope.
  String _scope = 'all';

  @override
  void initState() {
    super.initState();
    _data = widget.initial;
    _loading = widget.initial == null;
    _load();
  }

  Future<void> _load() async {
    final d = await SeasonService.overview();
    if (!mounted) return;
    setState(() {
      _data = d ?? _data;
      _loading = false;
    });
  }

  /// Rows for the active scope, re-ranked 1..n (the design replays the list).
  List<Standing> _rows(SeasonOverview d) {
    final all = d.board;
    if (_scope == 'all') return all;
    final filtered = all.where((r) => r.tier == _scope).toList();
    var i = 0;
    return filtered.map((r) => r.copyWith(rank: ++i)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    if (d == null) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: Center(
          child: _loading
              ? const CircularProgressIndicator(color: AppColors.primary)
              : Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.emoji_events_outlined,
                        size: 40, color: AppColors.inkFaint),
                    const SizedBox(height: 12),
                    Text('No season is running right now.',
                        style: AppText.body(AppColors.inkSoft),
                        textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    AppButton('Back', onPressed: () => Navigator.pop(context)),
                  ]),
                ),
        ),
      );
    }

    final rows = _rows(d);
    final me = _first(rows.where((r) => r.me));

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(children: [
        _header(d, rows, me),
        _scopePills(d),
        Expanded(
          child: ListView(
            // Re-keying on scope replays the row cascade, as the design does.
            key: ValueKey(_scope),
            padding: const EdgeInsets.only(top: 20, bottom: 28),
            children: [
              if (rows.isNotEmpty) _Podium(rows.take(3).toList(), d),
              const SizedBox(height: 22),
              if (rows.length > 3) _standings(rows.skip(3).toList(), d),
              if (rows.isEmpty) _emptyBoard(),
              const SizedBox(height: 28),
              const SectionHeader('Season Rewards'),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.screen, 0, AppSpacing.screen, 12),
                child: Text('Paid out after ${d.season.endsLabel}',
                    style: AppText.small(AppColors.inkSoft)),
              ),
              _ladder(d, me),
              _footerNote(d),
            ],
          ),
        ),
        if (me != null) _stickyFooter(me, d),
      ]),
    );
  }

  // ── header ──
  Widget _header(SeasonOverview d, List<Standing> rows, Standing? me) {
    final season = d.season;
    final bracket = me == null ? null : d.bracketFor(me.rank);
    // The bracket immediately above me, and the points needed to enter it.
    final target =
        me == null ? null : _last(d.brackets.where((b) => b.rankTo < me.rank));
    final cutoff = target == null
        ? null
        : _first(rows.where((r) => r.rank == target.rankTo));
    final gap =
        (cutoff == null || me == null) ? 0 : math.max(0, cutoff.pts - me.pts + 1);

    return Stack(children: [
      Container(
        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 6),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.hero, AppColors.hero2],
          ),
        ),
        child: Column(children: [
          // title row
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 6, AppSpacing.screen, 0),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.chevron_left_rounded,
                      size: 22, color: AppColors.heroInk),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('SEASON ${season.no}',
                        style: AppText.tag(AppColors.heroFaint).copyWith(
                            fontSize: 9.5,
                            letterSpacing: 1.8,
                            fontWeight: FontWeight.w800)),
                    Text(season.name,
                        style: AppText.cardTitle(AppColors.heroInk)
                            .copyWith(fontSize: 17, fontWeight: FontWeight.w900)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.schedule_rounded,
                      size: 13, color: AppColors.heroInk),
                  const SizedBox(width: 5),
                  Text('${season.daysLeft}d left',
                      style: AppText.bodyStrong(AppColors.heroInk).copyWith(
                          fontSize: 11, fontWeight: FontWeight.w800)),
                ]),
              ),
            ]),
          ),
          // your position
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 18, AppSpacing.screen, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('YOUR POSITION',
                          style: AppText.tag(AppColors.heroFaint).copyWith(
                              fontSize: 9.5,
                              letterSpacing: 1.4,
                              fontWeight: FontWeight.w800)),
                      const SizedBox(height: 5),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          PopIn(
                            child: Text(me == null ? '—' : '#${me.rank}',
                                style: AppText.stat(52, AppColors.heroInk)
                                    .copyWith(letterSpacing: -2.4, height: 0.85)),
                          ),
                          if (me != null && me.trend != 0) ...[
                            const SizedBox(width: 9),
                            Row(children: [
                              _TrendChip(me.trend, size: 13),
                              Text(' this week',
                                  style: AppText.bodyStrong(me.trend >= 0
                                          ? AppColors.success
                                          : AppColors.danger)
                                      .copyWith(
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w800)),
                            ]),
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        me == null
                            ? 'Win a ranked match to enter the board'
                            : 'of ${rows.length} · ${_scopeLabel(d)}',
                        style: AppText.small(AppColors.heroFaint)
                            .copyWith(fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  CountUp(me?.pts ?? 0,
                      style: AppText.stat(27, AppColors.heroInk)
                          .copyWith(letterSpacing: -0.7, height: 1)),
                  const SizedBox(height: 4),
                  Text('SEASON POINTS',
                      style: AppText.tag(AppColors.heroFaint).copyWith(
                          fontSize: 9,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w800)),
                  if (bracket != null) ...[
                    const SizedBox(height: 10),
                    Floaty(child: _HeroPill(bracket: bracket, fontSize: 10.5)),
                  ],
                ]),
              ],
            ),
          ),
          // progress toward the next bracket
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.screen, 16, AppSpacing.screen, 14),
            child: Column(children: [
              Row(children: [
                Expanded(
                  child: Text(
                    gap > 0
                        ? '$gap pts → ${target!.label}'
                        : (bracket != null
                            ? 'Holding ${bracket.label}'
                            : 'Climb into a reward bracket'),
                    style: AppText.bodyStrong(AppColors.heroInk)
                        .copyWith(fontSize: 10.5),
                  ),
                ),
                Text(
                  'Season ${(season.progress * 100).round()}% · ends ${season.endsLabel}',
                  style: AppText.small(AppColors.heroFaint).copyWith(fontSize: 10.5),
                ),
              ]),
              const SizedBox(height: 7),
              SeasonBar(
                (cutoff == null || me == null || cutoff.pts <= 0)
                    ? 1
                    : (me.pts / cutoff.pts).clamp(0, 1).toDouble(),
              ),
            ]),
          ),
        ]),
      ),
      const Positioned.fill(child: _HeroWash(opacity: 0.6)),
      const Positioned.fill(child: Sheen()),
    ]);
  }

  String _scopeLabel(SeasonOverview d) =>
      _scope == 'all' ? 'All players' : '${_titleCase(_scope)} players';

  static String _titleCase(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  // ── scope pills ──
  Widget _scopePills(SeasonOverview d) {
    final myTier = d.me?.tier;
    final scopes = <List<String>>[
      ['all', 'All players'],
      if (myTier != null) [myTier, '${_titleCase(myTier)} players'],
    ];
    if (scopes.length < 2) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screen, vertical: 12),
      decoration: const BoxDecoration(
        color: AppColors.bg,
        border: Border(bottom: BorderSide(color: AppColors.lineSoft)),
      ),
      child: Row(
        children: [
          for (final s in scopes) ...[
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _scope = s[0]),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _scope == s[0] ? AppColors.primary : AppColors.surface,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                        color: _scope == s[0] ? AppColors.primary : AppColors.line),
                  ),
                  child: Text(
                    s[1],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.bodyStrong(_scope == s[0]
                            ? AppColors.primaryInk
                            : AppColors.inkSoft)
                        .copyWith(fontSize: 11.5, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ),
            if (s != scopes.last) const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }

  // ── standings ──
  Widget _standings(List<Standing> rows, SeasonOverview d) {
    return Padding(
      padding: AppSpacing.screenH,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: AppRadius.cardR,
          border: Border.all(color: AppColors.lineSoft),
          boxShadow: kCardShadow,
        ),
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++)
              RowIn(
                delay: Duration(
                    milliseconds: math.min(500, 40 * i)),
                child: _StandingRow(
                  row: rows[i],
                  bracket: d.bracketFor(rows[i].rank),
                  first: i == 0,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _emptyBoard() => Padding(
        padding: AppSpacing.screenH,
        child: AppCard(
          child: Column(children: [
            const Icon(Icons.leaderboard_outlined,
                size: 34, color: AppColors.inkFaint),
            const SizedBox(height: 10),
            Text('No one has scored in this group yet.',
                style: AppText.body(AppColors.inkSoft), textAlign: TextAlign.center),
          ]),
        ),
      );

  // ── reward ladder ──
  Widget _ladder(SeasonOverview d, Standing? me) {
    final mine = me == null ? null : d.bracketFor(me.rank);
    return Padding(
      padding: AppSpacing.screenH,
      child: Column(children: [
        for (var i = 0; i < d.brackets.length; i++) ...[
          if (i > 0) const SizedBox(height: 9),
          RowIn(
            delay: Duration(milliseconds: 50 * i),
            child: _BracketCard(
              bracket: d.brackets[i],
              isMine: mine != null && mine.id == d.brackets[i].id,
              cleared: me != null && d.brackets[i].rankTo < me.rank,
              onTap: () => _openReward(d, d.brackets[i], mine),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _footerNote(SeasonOverview d) {
    final win = d.rulePts('win');
    final title = d.rulePts('tour_win');
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.screen, 16, AppSpacing.screen, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.field,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(children: [
          const Icon(Icons.bolt_rounded, size: 16, color: AppColors.gold),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              'Every win adds $win pts · a title is worth $title. '
              'Play more, climb faster.',
              style: AppText.small(AppColors.inkSoft)
                  .copyWith(fontSize: 11.5, height: 1.45),
            ),
          ),
        ]),
      ),
    );
  }

  // ── sticky "you" bar ──
  Widget _stickyFooter(Standing me, SeasonOverview d) {
    return _GlowPulse(
      child: Container(
        padding: EdgeInsets.fromLTRB(
            16, 12, 16, 14 + MediaQuery.of(context).padding.bottom),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.lineSoft)),
        ),
        child: _StandingRow(
          row: me,
          bracket: d.bracketFor(me.rank),
          first: true,
          flat: true,
        ),
      ),
    );
  }

  Future<void> _openReward(
      SeasonOverview d, SeasonBracket b, SeasonBracket? mine) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x70231408),
      isScrollControlled: true,
      builder: (_) => _RewardSheet(
        bracket: b,
        season: d.season,
        mine: mine != null && mine.id == b.id,
      ),
    );
  }
}

/// `lbGlow` — the sticky bar pulses a soft primary ring 3× after it appears.
class _GlowPulse extends StatefulWidget {
  final Widget child;
  const _GlowPulse({required this.child});
  @override
  State<_GlowPulse> createState() => _GlowPulseState();
}

class _GlowPulseState extends State<_GlowPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 3));
  int _cycles = 0;

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        _cycles++;
        if (_cycles < 3) {
          _c.forward(from: 0);
        } else {
          _c.value = 0;
        }
      }
    });
    Future<void>.delayed(const Duration(seconds: 1), () {
      if (mounted && !_stillMotion(context)) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final t = Curves.easeOut.transform(_c.value);
          return DecoratedBox(
            decoration: BoxDecoration(
              boxShadow: _c.value == 0
                  ? null
                  : [
                      BoxShadow(
                        color: AppColors.primary.withValues(alpha: 0.28 * (1 - t)),
                        blurRadius: 8 + 22 * t,
                        spreadRadius: 1 + 3 * t,
                      ),
                    ],
            ),
            child: child,
          );
        },
        child: widget.child,
      );
}

// ── Podium ──────────────────────────────────────────────────────────────────

class _Podium extends StatelessWidget {
  final List<Standing> top;
  final SeasonOverview data;
  const _Podium(this.top, this.data);

  @override
  Widget build(BuildContext context) {
    // Visual order 2 · 1 · 3 (the winner stands in the middle, taller).
    final order = <Standing>[
      if (top.length > 1) top[1],
      if (top.isNotEmpty) top[0],
      if (top.length > 2) top[2],
    ];
    const delays = {2: 0, 1: 120, 3: 240};
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 2, AppSpacing.screen, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final r in order)
            Expanded(
              child: PopIn(
                delay: Duration(milliseconds: delays[r.rank] ?? 0),
                child: _PodiumColumn(r, data),
              ),
            ),
        ],
      ),
    );
  }
}

class _PodiumColumn extends StatelessWidget {
  final Standing r;
  final SeasonOverview data;
  const _PodiumColumn(this.r, this.data);

  @override
  Widget build(BuildContext context) {
    final first = r.rank == 1;
    final c = first ? AppColors.gold : AppColors.tier(r.tier);
    final size = first ? 60.0 : 46.0;
    return Padding(
      padding: EdgeInsets.only(bottom: first ? 0 : 12, left: 3, right: 3),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          height: 22,
          child: first
              ? const Floaty(
                  period: Duration(milliseconds: 2800),
                  child: Icon(Icons.workspace_premium_rounded,
                      size: 18, color: AppColors.gold),
                )
              : null,
        ),
        SizedBox(
          height: size + 10,
          width: size + 10,
          child: Stack(alignment: Alignment.center, children: [
            SeasonAvatar(r, size: size, ring: 2, color: c),
            if (first)
              Container(
                width: size + 10,
                height: size + 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: AppColors.gold.withValues(alpha: 0.45), width: 1.5),
                ),
              ),
            Positioned(
              bottom: 0,
              child: Container(
                constraints: const BoxConstraints(minWidth: 20),
                height: 20,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: first ? AppColors.gold : AppColors.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: first ? null : Border.all(color: c, width: 1.5),
                ),
                child: Text('${r.rank}',
                    style: AppText.bodyStrong(first ? Colors.white : c)
                        .copyWith(fontSize: 11, fontWeight: FontWeight.w900)),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        Text(r.me ? 'You' : r.firstName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.bodyStrong(AppColors.ink)
                .copyWith(fontSize: 12.5, fontWeight: FontWeight.w800)),
        const SizedBox(height: 3),
        Text(fmtPts(r.pts),
            style: AppText.small(AppColors.inkSoft)
                .copyWith(fontSize: 11, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

// ── One standings row ───────────────────────────────────────────────────────

class _StandingRow extends StatelessWidget {
  final Standing row;
  final SeasonBracket? bracket;
  final bool first;
  final bool flat;
  const _StandingRow({
    required this.row,
    required this.bracket,
    this.first = false,
    this.flat = false,
  });

  @override
  Widget build(BuildContext context) {
    // Only a real move (2+ places) earns a chip — small drift is noise.
    final move = row.trend.abs() >= 2 ? row.trend : 0;
    final c = bracket == null ? null : bracketColor(bracket!.colorKey);
    return Container(
      decoration: BoxDecoration(
        color: (row.me && !flat)
            ? AppColors.primary.withValues(alpha: 0.08)
            : Colors.transparent,
        border: (first || flat)
            ? null
            : const Border(top: BorderSide(color: AppColors.lineSoft)),
      ),
      child: Stack(children: [
        // your own row gets a 3px clay bar flush to the card's left edge
        if (row.me && !flat)
          const Positioned(
              left: 0, top: 0, bottom: 0, width: 3, child: ColoredBox(color: AppColors.primary)),
        Padding(
          padding: flat
              ? const EdgeInsets.symmetric(horizontal: 2)
              : const EdgeInsets.fromLTRB(15, 12, 15, 12),
          child: Row(children: [
        SizedBox(
          width: 20,
          child: Text('${row.rank}',
              textAlign: TextAlign.right,
              style: AppText.bodyStrong(
                      row.me ? AppColors.primary : AppColors.inkSoft)
                  .copyWith(
                      fontSize: 13,
                      fontWeight: row.me ? FontWeight.w900 : FontWeight.w700)),
        ),
        const SizedBox(width: 12),
        SeasonAvatar(row,
            size: 34,
            color: row.me ? AppColors.primary : AppColors.tier(row.tier)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Flexible(
                  child: Text(row.me ? 'You' : row.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.bodyStrong(AppColors.ink).copyWith(
                          fontSize: 13.5, fontWeight: FontWeight.w800)),
                ),
                if (move != 0) ...[
                  const SizedBox(width: 5),
                  _TrendChip(move, size: 11, muteDown: true),
                ],
              ]),
              const SizedBox(height: 2),
              Text(
                '${bracket?.short ?? 'Unranked'} · ${_titleCase(row.tier)}',
                style: AppText.small(AppColors.inkSoft).copyWith(fontSize: 11),
              ),
            ],
          ),
        ),
        if (bracket != null) ...[
          const SizedBox(width: 8),
          Opacity(
            opacity: 0.85,
            child: Icon(seasonIcon(bracket!.icon), size: 15, color: c),
          ),
        ],
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 42),
          child: Text(fmtPts(row.pts),
              textAlign: TextAlign.right,
              style: AppText.bodyStrong(AppColors.ink)
                  .copyWith(fontSize: 13.5, fontWeight: FontWeight.w800)),
        ),
          ]),
        ),
      ]),
    );
  }

  static String _titleCase(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}

// ── Reward bracket card ─────────────────────────────────────────────────────

class _BracketCard extends StatelessWidget {
  final SeasonBracket bracket;
  final bool isMine, cleared;
  final VoidCallback onTap;
  const _BracketCard({
    required this.bracket,
    required this.isMine,
    required this.cleared,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = bracketColor(bracket.colorKey);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        clipBehavior: Clip.antiAlias,
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
              color: isMine ? c : AppColors.lineSoft, width: isMine ? 1.5 : 1),
          gradient: isMine
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.alphaBlend(c.withValues(alpha: 0.14), AppColors.surface),
                    AppColors.surface,
                  ],
                  stops: const [0, 0.65],
                )
              : null,
          color: isMine ? null : AppColors.surface,
          boxShadow: isMine
              ? [
                  BoxShadow(
                      color: c.withValues(alpha: 0.28),
                      blurRadius: 18,
                      offset: const Offset(0, 6))
                ]
              : null,
        ),
        child: Stack(children: [
          if (isMine) const Positioned.fill(child: Sheen(opacity: 0.22)),
          Row(children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: cleared ? AppColors.field : c.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(seasonIcon(bracket.icon),
                  size: 18, color: cleared ? AppColors.inkFaint : c),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Flexible(
                        child: Text(bracket.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.bodyStrong(
                                    cleared ? AppColors.inkSoft : AppColors.ink)
                                .copyWith(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w800)),
                      ),
                      const SizedBox(width: 7),
                      Text(bracket.rangeLabel,
                          style: AppText.small(AppColors.inkSoft)
                              .copyWith(fontSize: 11)),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(bracket.prize,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.bodyStrong(cleared ? AppColors.inkSoft : c)
                          .copyWith(fontSize: 12.5)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (isMine)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: c, borderRadius: BorderRadius.circular(7)),
                child: Text('YOU',
                    style: AppText.tag(Colors.white).copyWith(
                        fontSize: 9.5,
                        letterSpacing: 0.6,
                        fontWeight: FontWeight.w900)),
              )
            else
              const Icon(Icons.chevron_right_rounded,
                  size: 17, color: AppColors.inkFaint),
          ]),
        ]),
      ),
    );
  }
}

// ── Reward detail sheet ─────────────────────────────────────────────────────

class _RewardSheet extends StatelessWidget {
  final SeasonBracket bracket;
  final Season season;
  final bool mine;
  const _RewardSheet(
      {required this.bracket, required this.season, required this.mine});

  @override
  Widget build(BuildContext context) {
    final c = bracketColor(bracket.colorKey);
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: EdgeInsets.fromLTRB(
          20, 10, 20, 28 + MediaQuery.of(context).padding.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 40,
          height: 4,
          margin: const EdgeInsets.only(bottom: 18),
          decoration: BoxDecoration(
              color: AppColors.line, borderRadius: BorderRadius.circular(2)),
        ),
        Row(children: [
          _SparkIcon(icon: seasonIcon(bracket.icon), color: c),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(bracket.label,
                    style: AppText.cardTitle().copyWith(
                        fontSize: 17.5, fontWeight: FontWeight.w900)),
                const SizedBox(height: 3),
                Text(
                  '${bracket.rankFrom == bracket.rankTo ? 'Finish 1st' : 'Finish between #${bracket.rankFrom} and #${bracket.rankTo}'}'
                  ' · Season ${season.no}',
                  style: AppText.small(AppColors.inkSoft).copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
        ]),
        const SizedBox(height: 17),
        Container(
          clipBehavior: Clip.antiAlias,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.alphaBlend(c.withValues(alpha: 0.13), AppColors.field),
                AppColors.field,
              ],
            ),
          ),
          child: Stack(children: [
            const Positioned.fill(child: Sheen(opacity: 0.2)),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('MAIN REWARD',
                  style: AppText.tag(AppColors.inkSoft).copyWith(
                      fontSize: 10,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 5),
              Text(bracket.prize.isEmpty ? '—' : bracket.prize,
                  style: AppText.stat(19, c).copyWith(letterSpacing: -0.3)),
            ]),
          ]),
        ),
        if (bracket.extras.isNotEmpty) const SizedBox(height: 15),
        for (var i = 0; i < bracket.extras.length; i++)
          RowIn(
            delay: Duration(milliseconds: 100 + 70 * i),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(children: [
                Icon(Icons.check_circle_rounded, size: 17, color: c),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(bracket.extras[i],
                      style: AppText.body().copyWith(fontSize: 13)),
                ),
              ]),
            ),
          ),
        const SizedBox(height: 7),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Rewards are issued within 7 days of the season closing on ${season.endsLabel}.',
            style: AppText.small(AppColors.inkSoft)
                .copyWith(fontSize: 11.5, height: 1.5),
          ),
        ),
        const SizedBox(height: 16),
        AppButton(mine ? 'Keep climbing' : 'Got it',
            full: true, onPressed: () => Navigator.pop(context)),
      ]),
    );
  }
}

/// `lbPop` + `lbSpark` — the sheet's reward tile with three stars firing out.
class _SparkIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _SparkIcon({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    const spots = [Offset(30, -8), Offset(-2, -12), Offset(-16, 4)];
    return SizedBox(
      width: 68,
      height: 68,
      child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
        PopIn(
          child: Container(
            width: 50,
            height: 50,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(icon, size: 25, color: color),
          ),
        ),
        if (!_stillMotion(context))
          for (var i = 0; i < spots.length; i++)
            Positioned(
              left: 34 + spots[i].dx,
              top: 34 + spots[i].dy,
              child: _Spark(color: color, delay: Duration(milliseconds: 150 * i)),
            ),
      ]),
    );
  }
}

class _Spark extends StatelessWidget {
  final Color color;
  final Duration delay;
  const _Spark({required this.color, required this.delay});
  @override
  Widget build(BuildContext context) => _Delayed(
        delay: delay,
        duration: const Duration(milliseconds: 1100),
        curve: Curves.easeOut,
        builder: (t, child) => Opacity(
          opacity: (1 - t).clamp(0, 1),
          child: Transform.rotate(
            angle: t * 150 * math.pi / 180,
            child: Transform.scale(scale: 0.4 + 1.1 * t, child: child),
          ),
        ),
        child: Icon(Icons.star_rounded, size: 10, color: color),
      );
}

T? _first<T>(Iterable<T> it) => it.isEmpty ? null : it.first;
T? _last<T>(Iterable<T> it) => it.isEmpty ? null : it.last;

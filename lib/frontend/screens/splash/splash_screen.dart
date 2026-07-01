import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';

/// Padel Rivals — animated splash / loading screen.
///
/// Clay Court system. Mirrors the HTML prototype "Padel Rivals Loading v3":
///   • horizontal lockup (logo tile + PADEL RIVALS, RIVALS in clay)
///   • faint court baseline arc behind the lockup
///   • clay→gold progress line with a bouncing clay ball that rides the head
///   • rotating status copy
///   • "Cairo · Clay Court" editorial footer
///   • graceful fade, then [onDone] fires (hand off to Home).
///
/// Usage:
///   SplashScreen(onDone: () => Navigator.pushReplacement(...));
///
/// Uses the existing brand logo asset (registered via `assets/brand/`):
///   assets/brand/logo.png
class SplashScreen extends StatefulWidget {
  /// Called once the timed load sequence + exit fade complete.
  ///
  /// If null, the splash runs as an indeterminate loader — the progress bar
  /// loops and no hand-off fires — used while real startup work is pending
  /// (the parent swaps the splash out when ready).
  final VoidCallback? onDone;

  /// Total time the loader runs before handing off (excludes exit fade).
  /// Only used in timed mode (`onDone != null`).
  final Duration duration;

  const SplashScreen({
    super.key,
    this.onDone,
    this.duration = const Duration(milliseconds: 2800),
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  // Entrance (fade + rise) for the lockup / loader / footer.
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  )..forward();

  // Drives 0 → 1 loading progress.
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  // Continuous ball hop.
  late final AnimationController _hop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  // Exit fade of the whole splash.
  late final AnimationController _exit = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  );

  static const _steps = <_Step>[
    _Step(0.00, 'Warming up the court'),
    _Step(0.28, 'Loading your rating'),
    _Step(0.60, 'Finding your rivals'),
    _Step(0.90, 'Ready to play'),
  ];

  String _status = _steps.first.label;

  @override
  void initState() {
    super.initState();

    _progress.addListener(() {
      final v = _progress.value;
      String next = _steps.first.label;
      for (final s in _steps) {
        if (v >= s.at) next = s.label;
      }
      if (next != _status) setState(() => _status = next);
    });

    if (widget.onDone != null) {
      // Timed intro: fill once, hold a beat, fade out, then hand off.
      _progress.addStatusListener((s) async {
        if (s == AnimationStatus.completed) {
          await Future<void>.delayed(const Duration(milliseconds: 350));
          if (!mounted) return;
          await _exit.forward();
          if (mounted) widget.onDone!();
        }
      });
      // Small beat after entrance, then run the loader.
      Future<void>.delayed(const Duration(milliseconds: 420), () {
        if (mounted) _progress.forward();
      });
    } else {
      // Indeterminate: loop the fill until the parent swaps us out.
      Future<void>.delayed(const Duration(milliseconds: 420), () {
        if (mounted) _progress.repeat();
      });
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    _progress.dispose();
    _hop.dispose();
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const trackW = 188.0;
    const ballSize = 12.0;

    Widget rise(double delay, Widget child) {
      final a = CurvedAnimation(
        parent: _enter,
        curve: Interval(delay, 1, curve: Curves.easeOutCubic),
      );
      return AnimatedBuilder(
        animation: a,
        builder: (_, c) => Opacity(
          opacity: a.value,
          child: Transform.translate(
              offset: Offset(0, 10 * (1 - a.value)), child: c),
        ),
        child: child,
      );
    }

    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0).animate(_exit),
      // Fill the screen: inside AuthGate this sits in an AnimatedSwitcher, which
      // gives loose constraints — without expand the splash shrinks to its
      // content and floats as a small card on a black background.
      child: SizedBox.expand(
        child: Container(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.24),
              radius: 1.0,
              colors: [AppColors.surface, AppColors.bg, AppColors.bgAlt],
              stops: [0.0, 0.58, 1.0],
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // faint court baseline arc, bottom
              Positioned(
                bottom: -150,
                child: IgnorePointer(
                  child: CustomPaint(
                    size: const Size(520, 300),
                    painter: _CourtArcPainter(),
                  ),
                ),
              ),

              // center column: lockup + loader + status
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  rise(0.0, _lockup()),
                  const SizedBox(height: 42),
                  rise(
                      0.22,
                      SizedBox(
                        width: trackW,
                        child: AnimatedBuilder(
                          animation: Listenable.merge([_progress, _hop]),
                          builder: (_, __) {
                            final p = _progress.value;
                            final hop = -4.0 * (1 - (2 * _hop.value - 1).abs());
                            return SizedBox(
                              height: ballSize + 8,
                              child: Stack(
                                clipBehavior: Clip.none,
                                alignment: Alignment.centerLeft,
                                children: [
                                  // track
                                  Container(
                                    height: 2.5,
                                    decoration: BoxDecoration(
                                      color: AppColors.line,
                                      borderRadius: BorderRadius.circular(99),
                                    ),
                                  ),
                                  // fill
                                  Container(
                                    height: 2.5,
                                    width: trackW * p,
                                    decoration: BoxDecoration(
                                      gradient: const LinearGradient(
                                        colors: [
                                          AppColors.primary,
                                          AppColors.gold
                                        ],
                                      ),
                                      borderRadius: BorderRadius.circular(99),
                                    ),
                                  ),
                                  // ball head
                                  Positioned(
                                    left: (trackW * p) - ballSize / 2,
                                    child: Transform.translate(
                                      offset: Offset(0, hop),
                                      child: Container(
                                        width: ballSize,
                                        height: ballSize,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: AppColors.primary,
                                          boxShadow: [
                                            BoxShadow(
                                              color: AppColors.primary
                                                  .withValues(alpha: 0.5),
                                              blurRadius: 8,
                                              offset: const Offset(0, 3),
                                            ),
                                            BoxShadow(
                                              color: AppColors.primary
                                                  .withValues(alpha: 0.12),
                                              blurRadius: 0,
                                              spreadRadius: 4,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      )),
                  const SizedBox(height: 26),
                  rise(
                      0.36,
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 280),
                        child: Text(
                          _status,
                          key: ValueKey(_status),
                          style: AppText.body(AppColors.inkSoft).copyWith(
                              fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                      )),
                ],
              ),

              // editorial footer
              Positioned(
                bottom: 40,
                child: rise(
                    0.52,
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _hairline(),
                        const SizedBox(width: 10),
                        Text('CAIRO · CLAY COURT',
                            style: AppText.tag(AppColors.inkFaint)
                                .copyWith(fontSize: 8.5, letterSpacing: 2.5)),
                        const SizedBox(width: 10),
                        _hairline(),
                      ],
                    )),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _hairline() =>
      Container(width: 26, height: 1.5, color: AppColors.line);

  Widget _lockup() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 58,
          height: 58,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x383C2A14),
                  blurRadius: 30,
                  offset: Offset(0, 12)),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Image.asset('assets/brand/logo.png', fit: BoxFit.cover),
        ),
        const SizedBox(width: 15),
        RichText(
          text: TextSpan(
            style: AppText.barTitle(AppColors.ink).copyWith(
                fontSize: 27, fontWeight: FontWeight.w900, letterSpacing: 1.5),
            children: const [
              TextSpan(text: 'PADEL '),
              TextSpan(
                  text: 'RIVALS', style: TextStyle(color: AppColors.primary)),
            ],
          ),
        ),
      ],
    );
  }
}

class _Step {
  final double at;
  final String label;
  const _Step(this.at, this.label);
}

/// Whisper-faint court baseline arc + center line.
class _CourtArcPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.line.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // upper half of an ellipse (the baseline curving away)
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawArc(rect, 3.14159, 3.14159, false, paint);

    // center service line fading up
    final cx = size.width / 2;
    final grad = Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          AppColors.line.withValues(alpha: 0.5),
          AppColors.line.withValues(alpha: 0)
        ],
      ).createShader(Rect.fromLTWH(cx - 1, 0, 2, 120))
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(cx, 0), Offset(cx, 120), grad);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

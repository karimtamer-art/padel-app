import 'package:flutter/material.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/widgets/common.dart';

class SuccessScreen extends StatefulWidget {
  final String name;
  final VoidCallback onDone;
  const SuccessScreen({super.key, required this.name, required this.onDone});

  @override
  State<SuccessScreen> createState() => _SuccessScreenState();
}

class _SuccessScreenState extends State<SuccessScreen> with TickerProviderStateMixin {
  late final AnimationController _pop =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 520))..forward();
  late final AnimationController _ring =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();

  @override
  void dispose() {
    _pop.dispose();
    _ring.dispose();
    super.dispose();
  }

  String get _first {
    final t = widget.name.trim();
    if (t.isEmpty) return 'Player';
    return t.split(' ').first;
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Container(
      color: AppColors.bg,
      padding: EdgeInsets.fromLTRB(28, top + 14, 28, MediaQuery.of(context).padding.bottom + 30),
      child: Column(children: [
        const Spacer(),
        // animated check medallion
        SizedBox(
          width: 132,
          height: 132,
          child: Stack(alignment: Alignment.center, children: [
            AnimatedBuilder(
              animation: _ring,
              builder: (_, __) {
                final t = _ring.value;
                return Transform.scale(
                  scale: 0.7 + t * 0.8,
                  child: Opacity(
                    opacity: (0.5 * (1 - t)).clamp(0, 1),
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.primary, width: 2),
                      ),
                    ),
                  ),
                );
              },
            ),
            ScaleTransition(
              scale: CurvedAnimation(parent: _pop, curve: Curves.elasticOut),
              child: Container(
                width: 108,
                height: 108,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AppColors.hero, AppColors.hero2],
                  ),
                  boxShadow: kPopShadow,
                ),
                child: const Icon(Icons.check_rounded, size: 56, color: AppColors.primary),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 30),
        Text("You're Ready To Play",
            textAlign: TextAlign.center,
            style: AppText.stat(32, AppColors.ink).copyWith(letterSpacing: -0.7, height: 1.0)),
        const SizedBox(height: 14),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 290),
          child: Text(
            'Complete your first placement matches and start your ranking journey.',
            textAlign: TextAlign.center,
            style: AppText.body(AppColors.inkSoft).copyWith(fontSize: 15, height: 1.55),
          ),
        ),
        const SizedBox(height: 28),
        // placement card
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppRadius.cardR,
            border: Border.all(color: AppColors.line),
            boxShadow: kCardShadow,
          ),
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.military_tech_outlined, size: 24, color: AppColors.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Placement: 5 matches',
                    style: AppText.bodyStrong().copyWith(fontSize: 14, fontWeight: FontWeight.w800)),
                const SizedBox(height: 1),
                Text("We'll seed your ELO & division after these.",
                    style: AppText.small().copyWith(fontSize: 12)),
              ]),
            ),
          ]),
        ),
        const Spacer(),
        AppButton('Enter Padel, $_first',
            full: true, height: 54, icon: Icons.arrow_forward_rounded, onPressed: widget.onDone),
      ]),
    );
  }
}

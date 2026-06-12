import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';
import '../../../backend/models/ranking_scale.dart';
import 'profile_screen.dart';

/// Standalone demo: a segmented toggle that flips the whole Profile screen
/// between a brand-new account and an established one. Drop it anywhere
/// (e.g. push from a debug menu) to see both dynamic states without signing
/// in/out. Not needed in production — the real selector is the auth flow,
/// which passes the right [PlayerProfile] into `RootScaffold`/`ProfileScreen`.
class DivisionDemoScreen extends StatefulWidget {
  const DivisionDemoScreen({super.key});
  @override
  State<DivisionDemoScreen> createState() => _DivisionDemoScreenState();
}

class _DivisionDemoScreenState extends State<DivisionDemoScreen> {
  bool _fresh = false;

  @override
  Widget build(BuildContext context) {
    final profile = PlayerProfile.fresh; // only fresh state until real ranking data from Supabase
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.line)),
              child: Row(children: [
                _seg('New player', _fresh, () => setState(() => _fresh = true)),
                _seg('Established', !_fresh, () => setState(() => _fresh = false)),
              ]),
            ),
          ),
        ),
        Expanded(
          // Re-key so the ListView resets scroll when the account switches.
          child: ProfileScreen(
            key: ValueKey(_fresh),
            profile: profile,
            onFindMatch: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('→ open Create-a-Match / placement flow')),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _seg(String label, bool on, VoidCallback onTap) => Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: on ? AppColors.surface : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
                boxShadow: on ? _kPopShadowSoft : null),
            child: Text(label,
                style: AppText.bodyStrong(on ? AppColors.primary : AppColors.inkSoft).copyWith(fontSize: 13)),
          ),
        ),
      );
}

const List<BoxShadow> _kPopShadowSoft = [
  BoxShadow(color: Color(0x143C2A14), blurRadius: 8, offset: Offset(0, 2)),
];

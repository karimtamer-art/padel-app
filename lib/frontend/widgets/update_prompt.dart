import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../../backend/models/app_update_models.dart';
import '../../app_version.dart';
import 'common.dart';

/// The two faces of "please update": the dismissible sheet and the screen with
/// no way past it.
///
/// Presentation only. It takes an [UpdateStatus] and an `onUpdate` callback and
/// knows nothing about how either was produced — no Supabase, no Play SDK, no
/// `dart:io`. `UpdateGate` supplies both in the real app; the dev demo
/// (`lib/dev/update_demo.dart`) supplies canned ones, which is the whole reason
/// this is a separate file from the gate.

/// Headline for both surfaces. Apple gives us a version name, Play gives a
/// version code, and the minimum-build rule gives neither — so the plain
/// sentence is a real case, not a fallback for a lazy admin.
String updateVersionLine(UpdateStatus info) => info.version.isEmpty
    ? 'A new version is available'
    : 'Version ${info.version} is available';

/// The dismissible nudge. [onUpdate] runs after the sheet closes.
Future<void> showUpdateSheet(
  BuildContext context,
  UpdateStatus info, {
  required VoidCallback onUpdate,
}) {
  final body = info.message.isNotEmpty
      ? info.message
      : "You're on $kAppVersion. Update to get the latest fixes and features.";
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
                color: AppColors.line, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: 18),
          const UpdateMark(),
          const SizedBox(height: 14),
          Text(updateVersionLine(info),
              textAlign: TextAlign.center,
              style: AppText.cardTitle().copyWith(fontSize: 18)),
          const SizedBox(height: 8),
          Text(body,
              textAlign: TextAlign.center,
              style: AppText.body(AppColors.inkSoft)
                  .copyWith(fontSize: 14, height: 1.5)),
          const SizedBox(height: 20),
          AppButton('Update now',
              full: true,
              height: 52,
              icon: Icons.system_update_alt_rounded, onPressed: () {
            Navigator.pop(ctx);
            onUpdate();
          }),
          const SizedBox(height: 8),
          AppButton('Later',
              full: true,
              height: 48,
              variant: AppBtnVariant.ghost,
              onPressed: () => Navigator.pop(ctx)),
        ]),
      ),
    ),
  );
}

/// The hard block. Deliberately has no way into the app — not even sign-out,
/// which would only leave the same screen behind a different session.
class UpdateRequiredScreen extends StatelessWidget {
  final UpdateStatus info;
  final VoidCallback onUpdate;

  /// For the player who has already updated from the store and come back to a
  /// stale screen.
  final Future<void> Function() onRecheck;

  const UpdateRequiredScreen({
    super.key,
    required this.info,
    required this.onUpdate,
    required this.onRecheck,
  });

  @override
  Widget build(BuildContext context) {
    final body = info.message.isNotEmpty
        ? info.message
        : 'This version of Padel Rivals is no longer supported. Update to keep playing — it only takes a moment.';
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const UpdateMark(big: true),
              const SizedBox(height: 20),
              Text('Time to update',
                  style: AppText.cardTitle().copyWith(fontSize: 21)),
              const SizedBox(height: 8),
              Text(body,
                  textAlign: TextAlign.center,
                  style: AppText.body(AppColors.inkSoft)
                      .copyWith(fontSize: 14.5, height: 1.55)),
              const SizedBox(height: 26),
              AppButton('Update now',
                  full: true,
                  height: 52,
                  icon: Icons.system_update_alt_rounded,
                  onPressed: onUpdate),
              const SizedBox(height: 11),
              AppButton("I've updated",
                  full: true,
                  height: 52,
                  variant: AppBtnVariant.ghost,
                  onPressed: () => onRecheck()),
              const SizedBox(height: 18),
              Text(
                  info.version.isEmpty
                      ? 'You have $appVersionLong'
                      : 'You have $appVersionLong · latest is ${info.version}',
                  style: AppText.small(AppColors.inkFaint)),
            ]),
          ),
        ),
      ),
    );
  }
}

class UpdateMark extends StatelessWidget {
  final bool big;
  const UpdateMark({super.key, this.big = false});

  @override
  Widget build(BuildContext context) {
    final size = big ? 72.0 : 56.0;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
          shape: BoxShape.circle, color: AppColors.wash(AppColors.primary)),
      child: Icon(Icons.rocket_launch_rounded,
          size: big ? 34 : 26, color: AppColors.primary),
    );
  }
}

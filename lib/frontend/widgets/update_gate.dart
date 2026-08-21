import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_colors.dart';
import '../../backend/services/app_update_service.dart';
import 'update_prompt.dart';

export '../../backend/models/app_update_models.dart';
export 'update_prompt.dart';

/// Wraps the whole app and tells an out-of-date build to update.
///
/// Two outcomes:
///
///  * **Nudge** — the STORE says a newer release is published (Play's in-app
///    update service on Android, Apple's lookup on iOS; see
///    [AppUpdateService]). Nobody types anything at release time. A dismissible
///    sheet, shown once per app launch, over the app the player can carry on
///    using.
///  * **Blocking** — this build is below the minimum set in the console
///    (Broadcasts → App update). The gate renders [UpdateRequiredScreen]
///    INSTEAD of the app, so there is no way past it. That one stays a human
///    decision: no store can know an old build talks to the server wrongly.
///
/// The gate is the controller; the screens themselves live in
/// `update_prompt.dart` and drag in no store and no database, so the dev demo
/// can render them — and so they compile for a platform Play's SDK cannot.
///
/// The nudge waits for [appReady] because the only moment it makes sense is
/// with the app actually on screen — popping a sheet over the splash or over
/// half-finished onboarding reads as a bug. The block does not wait: an
/// unusable build is unusable at the sign-in screen too.
///
/// Dismissal is remembered for the process only, not on disk — persisting it
/// would mean a new dependency (`shared_preferences`) and pubspec is kept
/// deliberately small. Once per launch is the cadence most apps use anyway.
class UpdateGate extends StatefulWidget {
  final Widget child;
  const UpdateGate({super.key, required this.child});

  /// Flipped by `AuthGate` once the app itself is on screen; see above.
  static final ValueNotifier<bool> appReady = ValueNotifier<bool>(false);

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> {
  UpdateStatus _info = UpdateStatus.none;
  AppLifecycleListener? _lifecycle;
  bool _nudged = false; // this launch only — see the class doc
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    // Re-check on resume as well as at launch: someone who leaves to the store,
    // updates and comes back should not still be looking at the block.
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    UpdateGate.appReady.addListener(_maybeNudge);
    _check();
  }

  @override
  void dispose() {
    UpdateGate.appReady.removeListener(_maybeNudge);
    _lifecycle?.dispose();
    super.dispose();
  }

  /// A resume normally reads the cached store answer — a release doesn't appear
  /// twice an hour, and asking Play every time someone switches apps is rude.
  /// The exception is a resume while we ARE telling them to update: that is
  /// most likely the trip to the store, so ask again for real.
  Future<void> _onResume() => _check(force: _info.available);

  Future<void> _check({bool force = false}) async {
    if (_checking) return;
    _checking = true;
    try {
      final info = await AppUpdateService.check(force: force);
      if (!mounted) return;
      setState(() => _info = info);
      _maybeNudge();
    } finally {
      _checking = false;
    }
  }

  void _maybeNudge() {
    if (_nudged || !mounted) return;
    if (_info.level != UpdateLevel.optional) return;
    if (!UpdateGate.appReady.value) return;
    _nudged = true;
    // After the frame: this runs from a future or from a notifier that can
    // fire mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showUpdateSheet(context, _info, onUpdate: () => openStore(context, _info));
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_info.blocking) {
      return UpdateRequiredScreen(
        info: _info,
        onUpdate: () => openStore(context, _info),
        // "I've updated" is an explicit claim — go past the store cache.
        onRecheck: () => _check(force: true),
      );
    }
    return widget.child;
  }
}

/// Takes the player to the update.
///
/// On Android that is Play's own installer, running over the app — no trip to
/// the listing, no hunting for the Update button. It falls through to the store
/// page whenever Play declines, which includes every build not installed from
/// Play and the player who backs out of Play's own sheet.
Future<void> openStore(BuildContext context, UpdateStatus info) async {
  if (info.playCanUpdate && await AppUpdateService.startPlayUpdate()) return;
  if (!context.mounted) return;
  final url = info.storeUrl.trim();
  if (url.isEmpty) {
    _toast(context, 'Search for "Padel Rivals" in your app store.');
    return;
  }
  final uri = Uri.tryParse(url);
  if (uri == null) {
    _toast(context, "That store link doesn't look right.");
    return;
  }
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) _toast(context, "Couldn't open the store.");
}

void _toast(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.ink,
        content: Text(msg)));

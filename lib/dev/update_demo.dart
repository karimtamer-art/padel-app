// Dev-only demo for the update prompt. NOT part of the shipped app — it has
// its own main(), nothing imports it, and it talks to no store and no database.
//
//   flutter run -d chrome  -t lib/dev/update_demo.dart
//   flutter run -d <phone> -t lib/dev/update_demo.dart
//
// Why it exists: neither real trigger can be seen on a dev machine. Play's
// in-app update service answers only for builds installed FROM Play, so a
// `flutter run` build always lands on "no update"; Apple's lookup needs an
// iPhone; and the blocking screen only appears once someone has deliberately
// set a minimum build on the live database.
//
// It renders the real widgets from `update_prompt.dart` with the exact
// UpdateStatus values the real check would produce — no copies, so the design
// cannot drift from what ships. It deliberately does NOT import
// AppUpdateService: that pulls in `dart:io` and Play's SDK, which is what would
// stop this running in a browser.
import 'package:flutter/material.dart';
import 'package:padel_clay/app_version.dart';
import 'package:padel_clay/backend/models/app_update_models.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/update_prompt.dart';

void main() => runApp(const UpdateDemoApp());

class UpdateDemoApp extends StatelessWidget {
  const UpdateDemoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Update prompt — demo',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(scaffoldBackgroundColor: AppColors.bg),
        home: const _DemoHome(),
      );
}

/// Each case is exactly what `AppUpdateService.interpret` would hand the UI in
/// that situation — same fields, same emptiness.
class _Case {
  final String title;
  final String when;
  final UpdateStatus status;
  const _Case(this.title, this.when, this.status);
}

const _cases = <_Case>[
  _Case(
    'Nudge · iPhone',
    "Apple's lookup returned 1.4.0 and this build is older. Apple reports a "
        'version NAME, so the sheet can say it.',
    UpdateStatus(
      level: UpdateLevel.optional,
      version: '1.4.0',
      storeUrl: kAppStoreUrl,
    ),
  ),
  _Case(
    'Nudge · Android, Play installs it',
    'Play said an update is available and offered to install it in-app, so '
        '"Update now" hands off to Play instead of opening the listing. Play '
        'reports a version CODE, never a name.',
    UpdateStatus(
      level: UpdateLevel.optional,
      version: 'build 41',
      storeUrl: kPlayStoreUrl,
      playCanUpdate: true,
    ),
  ),
  _Case(
    'Nudge · with a message',
    'Same nudge, but someone wrote a line in the console (Broadcasts → App '
        'update). It replaces the default sentence on both surfaces.',
    UpdateStatus(
      level: UpdateLevel.optional,
      version: '1.4.0',
      message: 'Faster matchmaking, and the lobby now updates while you watch.',
      storeUrl: kAppStoreUrl,
    ),
  ),
  _Case(
    'Block · minimum build',
    'Someone set a minimum build above this one. This replaces the whole app '
        'including sign-in — there is no way past it. The store said nothing, '
        'so there is no version to name.',
    UpdateStatus(level: UpdateLevel.forced, storeUrl: kAppStoreUrl),
  ),
  _Case(
    'Block · with a message',
    'The same block, with the console message explaining why. This is what a '
        '"1.3.x talks to the server wrongly" release day looks like.',
    UpdateStatus(
      level: UpdateLevel.forced,
      version: '1.4.0',
      message: 'Older versions can no longer submit scores. Update to keep '
          'playing — it takes a moment.',
      storeUrl: kAppStoreUrl,
    ),
  ),
];

class _DemoHome extends StatefulWidget {
  const _DemoHome();

  @override
  State<_DemoHome> createState() => _DemoHomeState();
}

class _DemoHomeState extends State<_DemoHome> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Center(
          // These screens are laid out for a phone; a browser window is not
          // one. Pinning the width keeps the demo honest about proportions.
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
              children: [
                Text('Update prompt', style: AppText.bigTitle()),
                const SizedBox(height: 6),
                Text(
                    'What an out-of-date phone sees. This build is '
                    '$appVersionLong.',
                    style: AppText.body(AppColors.inkSoft)),
                const SizedBox(height: 22),
                for (final c in _cases) _caseCard(c),
                const SizedBox(height: 4),
                _detectionNote(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// What this demo cannot show, said plainly rather than faked.
  Widget _detectionNote() => AppCard(
        color: AppColors.surfaceAlt,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.info_outline_rounded,
                size: 16, color: AppColors.inkSoft),
            const SizedBox(width: 7),
            Text('What this demo does not prove',
                style:
                    AppText.bodyStrong(AppColors.inkSoft).copyWith(fontSize: 13)),
          ]),
          const SizedBox(height: 8),
          Text(
              'These are the surfaces, not the detection. Whether a newer '
              'version exists is answered by Play (only for builds installed '
              'from Play) or by Apple (only on an iPhone) — neither can run '
              'here, which is why the cases above are canned. The logic that '
              'reads them is covered by test/app_update_test.dart.',
              style: AppText.body(AppColors.inkSoft)
                  .copyWith(fontSize: 12.5, height: 1.5)),
        ]),
      );

  Widget _caseCard(_Case c) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              AppTag(c.status.blocking ? 'Blocks the app' : 'Dismissible',
                  color:
                      c.status.blocking ? AppColors.danger : AppColors.accent),
            ]),
            const SizedBox(height: 10),
            Text(c.title, style: AppText.cardTitle()),
            const SizedBox(height: 6),
            Text(c.when,
                style: AppText.body(AppColors.inkSoft)
                    .copyWith(fontSize: 13, height: 1.45)),
            const SizedBox(height: 12),
            AppButton('Show it',
                full: true,
                height: 46,
                icon: Icons.play_arrow_rounded,
                onPressed: () => _show(c.status)),
          ]),
        ),
      );

  /// Stands in for `openStore`, which needs Play's SDK. Says what the real
  /// button would do rather than pretending to do it.
  void _wouldUpdate(UpdateStatus status) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.ink,
      content: Text(status.playCanUpdate
          ? "Play's own installer would take over here, without leaving the app."
          : 'Would open ${status.storeUrl}'),
    ));
  }

  void _show(UpdateStatus status) {
    if (status.blocking) {
      // Pushed rather than replacing the tree, so the demo can get back out —
      // the real screen has no exit, which is the point of it.
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Stack(children: [
          UpdateRequiredScreen(
            info: status,
            onUpdate: () => _wouldUpdate(status),
            onRecheck: () async => _wouldUpdate(status),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: IconButton(
                  icon:
                      const Icon(Icons.close_rounded, color: AppColors.inkSoft),
                  tooltip: 'Leave the demo (a real player cannot)',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ),
        ]),
      ));
      return;
    }
    showUpdateSheet(context, status, onUpdate: () => _wouldUpdate(status));
  }
}

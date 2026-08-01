import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:padel_clay/app_version.dart';

/// The version shown in Help & Support is a constant (no package_info_plus),
/// so this guards it against drifting from pubspec.yaml — which is exactly how
/// the footer ended up claiming v1.0.0 while the app shipped 1.1.6.
void main() {
  test('kAppVersion / kAppBuild match pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final line = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true)
        .firstMatch(pubspec);
    expect(line, isNotNull, reason: 'no `version:` line in pubspec.yaml');

    final raw = line!.group(1)!; // e.g. 1.1.6+3
    final parts = raw.split('+');
    final version = parts.first;
    final build = parts.length > 1 ? parts[1] : '';

    expect(kAppVersion, version,
        reason: 'lib/app_version.dart is stale — pubspec says $version');
    expect(kAppBuild, build,
        reason: 'lib/app_version.dart build is stale — pubspec says $build');
  });
}

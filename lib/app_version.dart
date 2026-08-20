/// The app's version, mirrored from `pubspec.yaml`.
///
/// Flutter can't read pubspec at runtime without adding package_info_plus, and
/// the dependency list is deliberately small — so this is a plain constant.
/// It can't quietly drift: `test/app_version_test.dart` parses pubspec.yaml and
/// fails if these two stop matching. Bump both together when releasing.
const String kAppVersion = '1.3.1';

/// The build number after the `+` in pubspec (Play/TestFlight build).
///
/// This must only ever go UP — Play rejects a versionCode it has already seen,
/// and the App Store rejects a duplicate build for a version. Never reset it
/// to 1 when bumping the version name.
const String kAppBuild = '12';

/// "1.3.1 (11)" — version with its build, for support and bug reports.
String get appVersionLong => '$kAppVersion ($kAppBuild)';

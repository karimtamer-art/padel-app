/// The app's version, mirrored from `pubspec.yaml`.
///
/// Flutter can't read pubspec at runtime without adding package_info_plus, and
/// the dependency list is deliberately small — so this is a plain constant.
/// It can't quietly drift: `test/app_version_test.dart` parses pubspec.yaml and
/// fails if these two stop matching. Bump both together when releasing.
const String kAppVersion = '1.1.6';

/// The build number after the `+` in pubspec (Play/TestFlight build).
const String kAppBuild = '3';

/// "1.1.6 (3)" — version with its build, for support and bug reports.
String get appVersionLong => '$kAppVersion ($kAppBuild)';

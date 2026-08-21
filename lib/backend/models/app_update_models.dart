/// The shapes the update prompt is built from, and the store addresses.
///
/// Deliberately free of `dart:io` and of every plugin, so the widgets that
/// render an update prompt don't drag Play's SDK in with them. `AppUpdateService`
/// (which does both) produces these; `update_prompt.dart` consumes them.
library;

/// How badly this build is out of date.
enum UpdateLevel {
  /// Up to date, or we couldn't tell — always the safe default.
  none,

  /// The store has something newer. Dismissible nudge.
  optional,

  /// Older than the minimum we still support. Blocks the app.
  forced,
}

/// The store listings. Both are stable identifiers — the package name is fixed
/// by the signing key, and the Apple ID (App Store Connect → App Information)
/// is assigned once and never changes. Neither is the bundle id. `store_url_<p>`
/// in `app_settings` overrides them, so a wrong link can be fixed without
/// shipping the very release nobody can install.
const String kPlayStoreUrl =
    'https://play.google.com/store/apps/details?id=com.padelegypt.app';

/// No country code and no name slug on purpose: this form resolves for every
/// storefront and opens the App Store app directly on an iPhone.
const String kAppStoreUrl = 'https://apps.apple.com/app/id6786002098';

/// Apple's public lookup endpoint. `id` is the same Apple ID as the listing.
const String kAppleLookupUrl = 'https://itunes.apple.com/lookup?id=6786002098';

/// The answer to "should this phone be told to update?".
class UpdateStatus {
  final UpdateLevel level;

  /// What the store calls the newer release — "1.4.0" on iOS, "build 41" on
  /// Android (Play reports a version CODE, never a name). Empty when the store
  /// didn't say and only the minimum-build rule fired.
  final String version;

  /// Optional line from the console, shared by both surfaces.
  final String message;

  /// Where the Update button goes when Play can't do it in-app.
  final String storeUrl;

  /// Android only: Play offered to install the update from inside the app, so
  /// the button should hand off to it rather than open the listing.
  final bool playCanUpdate;

  const UpdateStatus({
    this.level = UpdateLevel.none,
    this.version = '',
    this.message = '',
    this.storeUrl = '',
    this.playCanUpdate = false,
  });

  static const none = UpdateStatus();

  bool get blocking => level == UpdateLevel.forced;
  bool get available => level != UpdateLevel.none;
}

/// What a store said about the published release. [newer] is the store's own
/// verdict where it has one (Play), or ours from comparing version names
/// (Apple); null fields simply mean that store doesn't report them.
class StoreRelease {
  final bool newer;
  final String? name; // Apple: "1.4.0"
  final int? build; // Play: the versionCode
  final bool playCanUpdate;

  const StoreRelease({
    required this.newer,
    this.name,
    this.build,
    this.playCanUpdate = false,
  });

  static const upToDate = StoreRelease(newer: false);

  /// "1.4.0", "build 41", or '' — whatever this store actually knows.
  String get label => name ?? (build == null ? '' : 'build $build');
}

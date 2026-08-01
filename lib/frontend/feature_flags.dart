/// Build-time feature switches.
///
/// A flag here hides a feature from players WITHOUT removing anything: the
/// screens, services, tables and RPCs all stay in place. Flip the flag back to
/// `true`, ship a build, and the feature returns exactly as it was.
///
/// Staff surfaces are deliberately NOT gated — the admin/organizer console is
/// behind `profiles.is_admin` already, so a hidden feature can still be built
/// and tested there while the public app stays quiet.
class Features {
  Features._();

  /// Player-facing community hub: the Home "Your Community" card, the
  /// join-by-code prompt, and everything they open (hub, channels, feed,
  /// members, organizer DM).
  ///
  /// OFF for the public launch (2026-08-01) — the feature still needs testing.
  /// The organizer console's Community section is unaffected.
  static const bool community = false;
}

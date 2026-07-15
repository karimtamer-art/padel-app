/// Matchmaking band constants — the tunable gatekeeper for who sees, and gets
/// paired with, whom. This is the **reference / display mirror** of the `mm_*`
/// rows in Supabase `app_settings` and the `mm_band_halfwidth()` SQL helper.
///
/// The SQL side is authoritative at runtime (matchmaking is gatekept
/// server-side inside SECURITY DEFINER RPCs, per the anti-cheat boundary). This
/// copy exists so the client can render the search criteria (Level / Range /
/// When) and reason locally. If you change a constant or the band equation,
/// change BOTH this file and the SQL (`mm_band_halfwidth` + the mm_* seed) —
/// same discipline as `RatingEngine` <-> `_settle_rating`.
///
/// Rating scale is 0.00–7.00 (`profiles.rating`). The band is a half-width
/// window centered on a player's rating that widens the longer a search runs.
library;

class MatchmakingConfig {
  MatchmakingConfig._();

  // ── Constants (mirror of app_settings mm_* rows) ─────────────────
  /// Initial half-width of the rating band around a player's rating.
  static const double bandBase = 0.4;

  /// How much the half-width grows per minute a search stays unmatched.
  static const double bandWidenPerMin = 0.05;

  /// Hard cap on the half-width.
  static const double bandMax = 1.5;

  /// A candidate match must be scheduled within this many hours from now.
  static const int timeWindowHours = 12;

  /// Seconds the surfaced "Match found" candidate runs its confirm countdown.
  static const int confirmSeconds = 120;

  /// v1 range proxy: 'city' (same-city). 'km' distance is a later upgrade.
  static const String rangeMode = 'city';

  // ── Derived ──────────────────────────────────────────────────────
  /// Band half-width for a search that has been running [ageMinutes] minutes.
  /// Mirrors `public.mm_band_halfwidth(age_minutes)` in SQL.
  static double halfWidth(double ageMinutes) {
    final a = ageMinutes < 0 ? 0.0 : ageMinutes;
    final w = bandBase + bandWidenPerMin * a;
    return w > bandMax ? bandMax : w;
  }

  /// Whether [searcherRating] falls in the band centered on [centerRating] for
  /// a search of [ageMinutes]. Assumes both sides are placed — placement
  /// players bypass the band (matched only among other placement players).
  static bool inBand(
          double searcherRating, double centerRating, double ageMinutes) =>
      (searcherRating - centerRating).abs() <= halfWidth(ageMinutes);
}

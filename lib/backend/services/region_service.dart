import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A market the app runs in.
///
/// Mirrors a row of the `regions` table (see
/// `supabase/changes/2026-09-26_regions.sql`). Region is **data, not a build
/// flag**: one binary and one store listing serve Egypt and everywhere else,
/// and a row here decides the currency shown, the phone dial code, and whether
/// the Store exists at all.
///
/// Deliberately NOT part of a region: the rating engine. V3-F5 is one global
/// 0.00–7.00 scale, so a player keeps one strength wherever they play. Seasons
/// are region-scoped (one ladder per market) but that lives on
/// `seasons.region_id`, not here.
class Region {
  final String id; // 'EG', 'AE', 'SA' — a readable code, not a uuid
  final String name;
  final String currencyCode;
  final String dialCode;

  /// Whether the Store exists for this region.
  ///
  /// False for every new market, and that is the safe default: cash-on-delivery
  /// and the Egyptian `addresses` shape (governorate / city / area) don't
  /// export, so turning this on is a deliberate act that claims delivery and
  /// payment actually work there.
  final bool commerceEnabled;

  final bool active;
  final int sort;

  const Region({
    required this.id,
    required this.name,
    required this.currencyCode,
    required this.dialCode,
    this.commerceEnabled = false,
    this.active = true,
    this.sort = 0,
  });

  /// Egypt, hardcoded.
  ///
  /// This is the fallback for every path that can't reach the server: offline,
  /// signed out, or a database where `2026-09-26_regions.sql` hasn't run yet.
  /// Egypt is the only market the app has shipped in, so falling back to it
  /// leaves an existing player seeing exactly what they saw before — which is
  /// the whole point of a fallback.
  static const egypt = Region(
    id: 'EG',
    name: 'Egypt',
    currencyCode: 'EGP',
    dialCode: '+20',
    commerceEnabled: true,
  );

  factory Region.fromRow(Map<String, dynamic> r) => Region(
        id: (r['id'] as String?)?.trim().isNotEmpty == true
            ? (r['id'] as String).trim()
            : egypt.id,
        name: (r['name'] as String?)?.trim().isNotEmpty == true
            ? (r['name'] as String).trim()
            : 'Region',
        currencyCode: (r['currency_code'] as String?)?.trim().isNotEmpty == true
            ? (r['currency_code'] as String).trim()
            : egypt.currencyCode,
        dialCode: (r['dial_code'] as String?)?.trim().isNotEmpty == true
            ? (r['dial_code'] as String).trim()
            : egypt.dialCode,
        commerceEnabled: r['commerce_enabled'] as bool? ?? false,
        active: r['active'] as bool? ?? true,
        sort: (r['sort'] as num?)?.toInt() ?? 0,
      );

  /// The flag emoji, derived from [id] rather than stored.
  ///
  /// A two-letter ISO code maps onto the regional-indicator block by a fixed
  /// offset ('A' → U+1F1E6), so 'EG' composes 🇪🇬 with no column and nothing to
  /// keep in sync. Anything that isn't two ASCII letters gets a neutral globe —
  /// the phone-prefix badges render this next to [dialCode], and a broken glyph
  /// there would look like a bug.
  String get flag {
    if (id.length != 2) return '🌍';
    const base = 0x1F1E6; // 🇦
    final up = id.toUpperCase();
    final a = up.codeUnitAt(0), b = up.codeUnitAt(1);
    if (a < 0x41 || a > 0x5A || b < 0x41 || b > 0x5A) return '🌍';
    return String.fromCharCodes([base + (a - 0x41), base + (b - 0x41)]);
  }

  @override
  String toString() => '$name ($id)';
}

/// Resolves and caches the region the signed-in player belongs to.
///
/// [current] is a notifier rather than a plain field for the same reason
/// [ProfileService.currentName] is: money and dial codes are rendered deep in
/// build methods that must repaint when the answer changes, and threading a
/// region down through every constructor would touch most of the app.
///
/// Every failure path answers Egypt — same principle as `AppUpdateService`,
/// where every failure answers "no update". A player locked out of prices
/// because Supabase hiccuped is worse than a player shown the wrong currency.
class RegionService {
  RegionService._();

  static SupabaseClient get _db => Supabase.instance.client;

  static const _cols =
      'id, name, currency_code, dial_code, commerce_enabled, active, sort';

  /// The current player's region. Defaults to Egypt until [load] says otherwise.
  static final ValueNotifier<Region> current =
      ValueNotifier<Region>(Region.egypt);

  /// Synchronous accessor for build methods and formatters.
  static Region get now => current.value;

  static List<Region>? _all;

  /// Every active region, for the onboarding picker. Cached for the process.
  ///
  /// Falls back to `[Region.egypt]` on any failure, including a database where
  /// the regions delta hasn't run — the same fallback
  /// `TournamentService.fetchTournaments` keeps for a pre-migration database.
  static Future<List<Region>> fetchAll() async {
    if (_all != null) return _all!;
    try {
      final res = await _db
          .from('regions')
          .select(_cols)
          .eq('active', true)
          .order('sort', ascending: true);
      final rows = List<Map<String, dynamic>>.from(res as List)
          .map(Region.fromRow)
          .toList();
      if (rows.isEmpty) return _all = const [Region.egypt];
      return _all = rows;
    } catch (_) {
      return _all = const [Region.egypt];
    }
  }

  /// Is the app live in more than one market?
  ///
  /// Synchronous, because onboarding has to decide whether the region step
  /// exists while building its step list. It reads the cache [load] warmed, and
  /// answers false until that has happened — which is the safe direction: the
  /// step is skipped rather than shown with nothing in it.
  ///
  /// This is what stops a one-option question being asked. With only Egypt
  /// active there is nothing to choose, so nobody is prompted.
  static bool get multiRegion => (_all?.length ?? 1) > 1;

  /// Every region the picker can offer. Falls back to Egypt alone.
  static List<Region> get known => _all ?? const [Region.egypt];

  /// Resolves [current] from `profiles.region_id`. Called from `AuthGate`
  /// once the profile is in hand.
  static Future<void> load(String userId) async {
    // Warm the list FIRST and unconditionally. [multiRegion] and [known] are
    // synchronous and onboarding reads them while building its steps, so they
    // must be populated even when the profile read below fails or the player
    // has no region_id yet.
    final all = await fetchAll();
    try {
      final row = await _db
          .from('profiles')
          .select('region_id')
          .eq('id', userId)
          .maybeSingle();
      final id = (row?['region_id'] as String?)?.trim();
      if (id == null || id.isEmpty) {
        current.value = Region.egypt;
        return;
      }
      current.value = all.firstWhere(
        (r) => r.id == id,
        // The player's region exists but is no longer active, or the list
        // couldn't be read. Egypt is wrong here but harmless, and it is better
        // than an empty screen.
        orElse: () => Region.egypt,
      );
    } catch (_) {
      current.value = Region.egypt;
    }
  }

  /// Writes the player's region. Returns an error message, or null on success.
  ///
  /// `profiles` uses column-level grants, so this only works because
  /// `grant update (region_id)` is in the migration. If that grant ever goes
  /// missing the write is refused SILENTLY — hence the read-back.
  static Future<String?> save(String userId, String regionId) async {
    try {
      await _db
          .from('profiles')
          .update({'region_id': regionId}).eq('id', userId);
      await load(userId);
      if (current.value.id != regionId) {
        return 'Could not save your region. Please try again.';
      }
      return null;
    } catch (e) {
      return 'Could not save your region: $e';
    }
  }

  /// Back to Egypt on sign-out, so the next account doesn't inherit the last
  /// one's currency.
  static void reset() {
    current.value = Region.egypt;
    _all = null;
  }
}

/// Formats an amount in the current region's currency — `EGP 1,200`.
///
/// This replaces four byte-identical private `_egp` helpers that had been
/// copy-pasted across the tournaments, tournament-detail and home screens,
/// plus `MockData.egp`, which now delegates here.
///
/// Whole amounts render exactly as they did before this existed, so no display
/// changes for an Egyptian player. Fractions render to 2dp rather than being
/// silently truncated.
String money(num amount, {String? currencyCode}) {
  final code = currencyCode ?? RegionService.now.currencyCode;
  final neg = amount < 0;
  final abs = amount.abs();
  final whole = abs.truncate();
  final digits = whole.toString();

  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }

  final frac = abs - whole;
  final tail = frac == 0
      ? ''
      : '.${(frac * 100).round().toString().padLeft(2, '0')}';

  return '$code ${neg ? '-' : ''}$buf$tail';
}

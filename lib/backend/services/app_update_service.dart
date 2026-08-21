import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, Platform;
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:in_app_update/in_app_update.dart' as play;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../app_version.dart';
import '../models/app_update_models.dart';

export '../models/app_update_models.dart';

/// Tells an old build that a newer one is on the store — asking the STORES,
/// not an admin.
///
/// The two stores are not symmetric and neither is optional:
///
///  * **Android** uses Play's own in-app update service (`in_app_update`).
///    It is the only supported way to ask Google what is published — there is
///    no version API — and it can install the update without leaving the app.
///    It answers only for builds actually installed FROM Play: a `flutter run`
///    or sideloaded build throws, which lands as "no update".
///  * **iOS** uses Apple's public lookup endpoint, which returns the live App
///    Store version NAME. No key, no package. It lags a publish by up to a few
///    hours, which is harmless for a nudge.
///
/// So nothing has to be typed at release time. What is still hand-set in
/// `app_settings` is the part no store can know:
///
///  * `update_min_build_<p>` — "this old build is broken, lock it out". A
///    judgement, not a fact.
///  * `update_message`, `store_url_<p>` — copy, and a link override.
///
/// **Every failure path answers [UpdateStatus.none].** No network, a store that
/// won't answer, a value someone typed wrong — none of them may lock a player
/// out of the app.
class AppUpdateService {
  AppUpdateService._();

  static SupabaseClient get _db => Supabase.instance.client;

  /// Storefronts to ask Apple about, in order. A lookup answers `resultCount:
  /// 0` for a storefront the app isn't sold in, so trying Egypt first and the
  /// default (US) second covers both without pinning us to one country.
  static const List<String> kAppleStorefronts = ['eg', ''];

  /// The stores are asked at most this often. Both calls are cheap, but a
  /// resume-triggered check every time someone switches apps is rude to Play
  /// and pointless — a release doesn't appear twice an hour.
  static const Duration storeTtl = Duration(hours: 6);

  static StoreRelease? _cached;
  static DateTime _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// `android` / `ios`, or null where there is no store to send anyone to
  /// (web, desktop) — the check is skipped entirely there.
  static String? get platformKey {
    if (kIsWeb) return null;
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return null;
  }

  /// The `app_settings` keys this platform reads. Public so the console can
  /// write exactly the same names.
  static List<String> keysFor(String platform) => [
        'update_min_build_$platform',
        'store_url_$platform',
        'update_message',
      ];

  /// Pure decision, so the interesting part is testable without a store.
  static UpdateLevel levelFor({
    required int currentBuild,
    int? minBuild,
    bool storeHasNewer = false,
  }) {
    if (minBuild != null && currentBuild < minBuild) return UpdateLevel.forced;
    if (storeHasNewer) return UpdateLevel.optional;
    return UpdateLevel.none;
  }

  /// Builds the answer from the store's verdict plus the console's settings.
  /// Split out from [check] so the part that decides whether someone gets
  /// locked out is covered by tests.
  static UpdateStatus interpret(
    Map<String, String> settings, {
    required String platform,
    StoreRelease store = StoreRelease.upToDate,
    int? currentBuild,
  }) {
    final current = currentBuild ?? int.tryParse(kAppBuild);
    if (current == null) return UpdateStatus.none;
    final level = levelFor(
      currentBuild: current,
      minBuild: _posInt(settings['update_min_build_$platform']),
      storeHasNewer: store.newer,
    );
    if (level == UpdateLevel.none) return UpdateStatus.none;
    final configured = (settings['store_url_$platform'] ?? '').trim();
    return UpdateStatus(
      level: level,
      version: store.label,
      message: (settings['update_message'] ?? '').trim(),
      storeUrl: configured.isNotEmpty
          ? configured
          : (platform == 'android' ? kPlayStoreUrl : kAppStoreUrl),
      playCanUpdate: store.playCanUpdate,
    );
  }

  /// Asks the store and the console, at launch and on resume.
  static Future<UpdateStatus> check({bool force = false}) async {
    final platform = platformKey;
    if (platform == null) return UpdateStatus.none;
    final results = await Future.wait([
      _settings(platform),
      storeRelease(platform, force: force),
    ]);
    return interpret(
      results[0] as Map<String, String>,
      platform: platform,
      store: results[1] as StoreRelease,
    );
  }

  /// Hands off to Play's own updater. Returns false when Play declined or the
  /// player backed out, so the caller can fall back to opening the listing.
  static Future<bool> startPlayUpdate() async {
    if (platformKey != 'android') return false;
    try {
      final res = await play.InAppUpdate.performImmediateUpdate();
      return res == play.AppUpdateResult.success;
    } catch (e) {
      debugPrint('[AppUpdateService] performImmediateUpdate: $e');
      return false;
    }
  }

  // ── The stores ────────────────────────────────────────────────

  /// Cached for [storeTtl]. Never throws.
  static Future<StoreRelease> storeRelease(String platform,
      {bool force = false}) async {
    if (!force &&
        _cached != null &&
        DateTime.now().difference(_cachedAt) < storeTtl) {
      return _cached!;
    }
    final release = platform == 'android'
        ? await _playRelease()
        : await _appleRelease();
    _cached = release;
    _cachedAt = DateTime.now();
    return release;
  }

  /// Play, via the in-app update service. Throws for anything not installed
  /// from Play (debug, sideload, another store) — which is exactly the case
  /// where we must say nothing.
  static Future<StoreRelease> _playRelease() async {
    try {
      final info = await play.InAppUpdate.checkForUpdate();
      if (info.updateAvailability != play.UpdateAvailability.updateAvailable) {
        return StoreRelease.upToDate;
      }
      return StoreRelease(
        newer: true,
        build: info.availableVersionCode,
        playCanUpdate: info.immediateUpdateAllowed,
      );
    } catch (e) {
      debugPrint('[AppUpdateService] Play check: $e');
      return StoreRelease.upToDate;
    }
  }

  /// Apple's public lookup. Returns the App Store version NAME, so the
  /// comparison here is the one place version names are compared — done
  /// component by component, never as strings.
  static Future<StoreRelease> _appleRelease() async {
    for (final storefront in kAppleStorefronts) {
      final url = storefront.isEmpty
          ? kAppleLookupUrl
          : '$kAppleLookupUrl&country=$storefront';
      final name = await _appleVersion(url);
      if (name == null) continue;
      return StoreRelease(newer: isNewer(name, kAppVersion), name: name);
    }
    return StoreRelease.upToDate;
  }

  static Future<String?> _appleVersion(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final body = await res.transform(utf8.decoder).join();
      final json = jsonDecode(body);
      if (json is! Map) return null;
      final results = json['results'];
      if (results is! List || results.isEmpty) return null; // wrong storefront
      final version = (results.first as Map)['version'];
      return (version is String && version.trim().isNotEmpty)
          ? version.trim()
          : null;
    } catch (e) {
      debugPrint('[AppUpdateService] Apple lookup: $e');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Is [store] a later release than [mine]? Compared component by component,
  /// because "1.10.0" sorts BEFORE "1.9.0" as text. A component that isn't a
  /// number, or a pair we can't tell apart, counts as "not newer" — the safe
  /// direction, since this only ever produces a dismissible nudge.
  static bool isNewer(String store, String mine) {
    final a = _parts(store);
    final b = _parts(mine);
    if (a.isEmpty || b.isEmpty) return false;
    for (var i = 0; i < (a.length > b.length ? a.length : b.length); i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  /// "1.4.0" → [1, 4, 0]. Anything unparseable ends the list rather than
  /// guessing, so "1.4.0-beta" compares as 1.4.0.
  static List<int> _parts(String v) {
    final out = <int>[];
    for (final piece in v.trim().split('.')) {
      final n = int.tryParse(piece.trim());
      if (n == null) break;
      out.add(n);
    }
    return out;
  }

  // ── The console's half ────────────────────────────────────────

  static Future<Map<String, String>> _settings(String platform) async {
    try {
      final rows = await _db
          .from('app_settings')
          .select('key, value')
          .inFilter('key', keysFor(platform));
      return <String, String>{
        for (final r in (rows as List))
          (r as Map)['key'] as String: (r['value'] as String?) ?? '',
      };
    } catch (e) {
      // Offline at launch is the common case. Never block on it.
      debugPrint('[AppUpdateService] settings: $e');
      return const {};
    }
  }

  /// A build number, or null for blank/garbage/zero. A negative or zero
  /// minimum would be meaningless; anything unparseable means "not set".
  static int? _posInt(String? raw) {
    final n = int.tryParse((raw ?? '').trim());
    return (n == null || n <= 0) ? null : n;
  }
}

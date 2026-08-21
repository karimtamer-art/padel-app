import 'package:flutter_test/flutter_test.dart';
import 'package:padel_clay/backend/services/app_update_service.dart';

/// The update gate decides whether a player can open the app at all, so the
/// interesting cases here are the ones where it must NOT block: a store that
/// won't answer, a blank setting, a value typed wrong.
void main() {
  group('levelFor', () {
    test('nothing configured and an up-to-date store asks nobody to update',
        () {
      expect(AppUpdateService.levelFor(currentBuild: 12), UpdateLevel.none);
    });

    test('the store having something newer is a nudge', () {
      expect(
          AppUpdateService.levelFor(currentBuild: 12, storeHasNewer: true),
          UpdateLevel.optional);
    });

    test('below the minimum blocks, and outranks the nudge', () {
      expect(
          AppUpdateService.levelFor(
              currentBuild: 9, minBuild: 12, storeHasNewer: true),
          UpdateLevel.forced);
    });

    test('the minimum blocks even when the store says nothing — a store that '
        "won't answer must not disarm it", () {
      expect(AppUpdateService.levelFor(currentBuild: 9, minBuild: 12),
          UpdateLevel.forced);
    });

    test('exactly the minimum is allowed in', () {
      expect(AppUpdateService.levelFor(currentBuild: 12, minBuild: 12),
          UpdateLevel.none);
    });
  });

  group('isNewer', () {
    test('a later release is newer', () {
      expect(AppUpdateService.isNewer('1.4.0', '1.3.1'), isTrue);
    });

    test('the same release is not', () {
      expect(AppUpdateService.isNewer('1.3.1', '1.3.1'), isFalse);
    });

    test('an older store version is not — a TestFlight build must not be '
        'nagged backwards', () {
      expect(AppUpdateService.isNewer('1.3.1', '1.4.0'), isFalse);
    });

    test('compares component by component, not as text', () {
      // The whole reason version names are not used for the build comparison:
      // "1.10.0" sorts BEFORE "1.9.0" as a string.
      expect(AppUpdateService.isNewer('1.10.0', '1.9.0'), isTrue);
      expect(AppUpdateService.isNewer('1.9.0', '1.10.0'), isFalse);
    });

    test('a missing component counts as zero', () {
      expect(AppUpdateService.isNewer('1.4', '1.4.0'), isFalse);
      expect(AppUpdateService.isNewer('1.4.1', '1.4'), isTrue);
    });

    test('junk is never newer', () {
      for (final pair in [
        ['', '1.3.1'],
        ['latest', '1.3.1'],
        ['1.3.1', ''],
      ]) {
        expect(AppUpdateService.isNewer(pair[0], pair[1]), isFalse,
            reason: '${pair[0]} vs ${pair[1]}');
      }
    });
  });

  group('interpret', () {
    Map<String, String> android({String min = '', String store = '', String message = ''}) => {
          'update_min_build_android': min,
          'store_url_android': store,
          'update_message': message,
        };

    const newer = StoreRelease(newer: true, name: '1.4.0');

    test('an up-to-date store and no settings mean no update', () {
      final info = AppUpdateService.interpret(android(),
          platform: 'android', currentBuild: 12);
      expect(info.level, UpdateLevel.none);
      expect(info.available, isFalse);
    });

    test('a missing row is the same as an empty one', () {
      final info = AppUpdateService.interpret({},
          platform: 'android', store: newer, currentBuild: 12);
      expect(info.level, UpdateLevel.optional);
      expect(info.message, isEmpty);
    });

    test('a version name typed into the minimum-build field is ignored, not '
        'obeyed', () {
      final info = AppUpdateService.interpret(android(min: '1.4.0'),
          platform: 'android', currentBuild: 12);
      expect(info.level, UpdateLevel.none);
    });

    test('zero and negatives are "not set", never a block', () {
      for (final bad in ['0', '-1', ' ', 'null']) {
        final info = AppUpdateService.interpret(android(min: bad),
            platform: 'android', currentBuild: 12);
        expect(info.level, UpdateLevel.none, reason: 'min="$bad"');
      }
    });

    test("carries the store's version, the message and the link through", () {
      final info = AppUpdateService.interpret(
          android(store: 'https://example.test/app', message: 'Faster matchmaking.'),
          platform: 'android',
          store: newer,
          currentBuild: 12);
      expect(info.level, UpdateLevel.optional);
      expect(info.version, '1.4.0');
      expect(info.message, 'Faster matchmaking.');
      expect(info.storeUrl, 'https://example.test/app');
    });

    test('Android falls back to the Play listing when no link is set', () {
      final info = AppUpdateService.interpret(android(),
          platform: 'android', store: newer, currentBuild: 12);
      expect(info.storeUrl, kPlayStoreUrl);
    });

    test('iOS falls back to the App Store listing when no link is set', () {
      final info = AppUpdateService.interpret({},
          platform: 'ios', store: newer, currentBuild: 12);
      expect(info.storeUrl, kAppStoreUrl);
    });

    test('the App Store link and lookup carry the numeric Apple ID, not the '
        'bundle id', () {
      expect(kAppStoreUrl, contains('/id6786002098'));
      expect(kAppleLookupUrl, contains('id=6786002098'));
      expect(kAppStoreUrl, isNot(contains('padelegypt')));
    });

    test('Play offering to install in-app is carried to the button', () {
      final info = AppUpdateService.interpret({},
          platform: 'android',
          store: const StoreRelease(newer: true, build: 41, playCanUpdate: true),
          currentBuild: 12);
      expect(info.playCanUpdate, isTrue);
      expect(info.version, 'build 41'); // Play reports a code, never a name
    });

    test('a block with no store answer still has somewhere to send them', () {
      final info = AppUpdateService.interpret(android(min: '20'),
          platform: 'android', currentBuild: 12);
      expect(info.level, UpdateLevel.forced);
      expect(info.version, isEmpty); // the store said nothing
      expect(info.storeUrl, isNotEmpty);
    });
  });

  test('the console writes exactly the keys the app reads', () {
    expect(AppUpdateService.keysFor('android'), [
      'update_min_build_android',
      'store_url_android',
      'update_message',
    ]);
  });
}

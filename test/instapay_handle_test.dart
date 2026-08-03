import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:padel_clay/frontend/widgets/instapay_field.dart';

/// The `@instapay` suffix is fixed in the UI, so whatever a player types has
/// to reduce to a bare username — including the very habit that prompted
/// this: typing the name AND the suffix.
void main() {
  group('InstapayHandle.username', () {
    test('leaves a bare username alone', () {
      expect(InstapayHandle.username('sara'), 'sara');
    });

    test('strips a typed or pasted suffix', () {
      expect(InstapayHandle.username('sara@instapay'), 'sara');
    });

    test('strips a doubled suffix', () {
      expect(InstapayHandle.username('sara@instapay@instapay'), 'sara');
    });

    test('strips a lone @', () {
      expect(InstapayHandle.username('sara@'), 'sara');
      expect(InstapayHandle.username('@instapay'), '');
    });

    test('drops whitespace', () {
      expect(InstapayHandle.username('  sara ahmed '), 'saraahmed');
    });

    test('handles empty input', () {
      expect(InstapayHandle.username(''), '');
      expect(InstapayHandle.username('   '), '');
    });
  });

  group('InstapayHandle.compose', () {
    test('appends the suffix exactly once', () {
      expect(InstapayHandle.compose('sara'), 'sara@instapay');
      expect(InstapayHandle.compose('sara@instapay'), 'sara@instapay');
    });

    test('stays empty when nothing was entered', () {
      expect(InstapayHandle.compose(''), '');
      expect(InstapayHandle.compose('  '), '');
      // Only a suffix is not a username — this must not become "@instapay".
      expect(InstapayHandle.compose('@instapay'), '');
    });
  });

  group('formatter', () {
    TextEditingValue format(String oldText, String newText) =>
        InstapayHandle.formatters.first.formatEditUpdate(
          TextEditingValue(text: oldText),
          TextEditingValue(
            text: newText,
            selection: TextSelection.collapsed(offset: newText.length),
          ),
        );

    test('passes a clean username through untouched', () {
      final v = format('sar', 'sara');
      expect(v.text, 'sara');
      expect(v.selection.baseOffset, 4);
    });

    test('swallows the @ that starts a suffix', () {
      expect(format('sara', 'sara@').text, 'sara');
    });

    test('reduces a pasted full handle to the username', () {
      final v = format('', 'sara@instapay');
      expect(v.text, 'sara');
      // Caret must land at the end of what survived, not past it.
      expect(v.selection.baseOffset, 4);
    });
  });
}

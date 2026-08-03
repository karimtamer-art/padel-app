import 'package:flutter/services.dart';

/// InstaPay handles are always `<username>@instapay` — the domain never
/// varies. Typing it out every time is pure friction, and people habitually
/// type the username and then the suffix anyway, producing
/// `yourname@instapay@instapay` once the app started appending it.
///
/// So the suffix is shown as fixed, non-editable text next to the field and
/// the player types only their username. [formatters] keeps the field to a
/// username no matter what gets typed or pasted; [compose] builds the full
/// handle to store.
class InstapayHandle {
  InstapayHandle._();

  static const suffix = '@instapay';

  /// The username part of anything a person might enter — handles a pasted
  /// full handle (`sara@instapay`), a stray `@`, and whitespace.
  static String username(String raw) {
    var s = raw.trim();
    final at = s.indexOf('@');
    if (at >= 0) s = s.substring(0, at);
    return s.replaceAll(RegExp(r'\s+'), '');
  }

  /// The full handle to send to the server, or '' when nothing was entered.
  static String compose(String rawUsername) {
    final u = username(rawUsername);
    return u.isEmpty ? '' : '$u$suffix';
  }

  /// Strips anything from the first `@` onward as it is typed, so the fixed
  /// suffix can never be duplicated.
  static final List<TextInputFormatter> formatters = [
    TextInputFormatter.withFunction((old, next) {
      final cleaned = username(next.text);
      if (cleaned == next.text) return next;
      // Stripping only ever shortens the text, so the caret moves left by
      // however much was removed before it.
      final removed = next.text.length - cleaned.length;
      final offset =
          (next.selection.baseOffset - removed).clamp(0, cleaned.length);
      return TextEditingValue(
        text: cleaned,
        selection: TextSelection.collapsed(offset: offset),
      );
    }),
  ];
}

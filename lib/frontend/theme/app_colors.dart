import 'package:flutter/material.dart';

/// Clay Court palette — warm limestone & terracotta.
/// Mirrors the HTML prototype's CSS variables (app/theme.js).
class AppColors {
  AppColors._();

  // Surfaces
  static const bg = Color(0xFFE9DFCD); // app background (limestone)
  static const bgAlt = Color(0xFFE1D5BF);
  static const surface = Color(0xFFFBF6EC); // cards
  static const surfaceAlt = Color(0xFFF3EADB); // insets / placeholders
  static const field = Color(0xFFF3EADB); // input & chip backgrounds

  // Hero (deep-green feature cards)
  static const hero = Color(0xFF21372F);
  static const hero2 = Color(0xFF2B463B); // gradient end
  static const heroInk = Color(0xFFF4EFE2); // text on hero
  static const heroFaint = Color(0x8CF4EFE2); // 55% heroInk

  // Text
  static const ink = Color(0xFF2A2218); // primary
  static const inkSoft = Color(0xFF6E6149); // secondary
  static const inkFaint = Color(0xFFA2937A); // tertiary / placeholder

  // Lines
  static const line = Color(0xFFDBCEB6);
  static const lineSoft = Color(0xFFE7DCC8);

  // Brand
  static const primary = Color(0xFFC2502A); // clay terracotta
  static const primaryPress = Color(0xFFA8431F);
  static const primaryInk = Color(0xFFFDF6EE);
  static const accent = Color(0xFF2F6B57); // pine green
  static const accentInk = Color(0xFFF4EFE2);

  // Semantic
  static const success = Color(0xFF3F8B57);
  static const danger = Color(0xFFC0432F);
  static const warn = Color(0xFFC0832B);

  // Tiers
  static const gold = Color(0xFFB07E22);
  static const silver = Color(0xFF94908A);
  static const bronze = Color(0xFFA66A3C);
  static const platinum = Color(0xFF4E8083);
  static const diamond = Color(0xFF3F7896);

  /// Soft tinted fill (the prototype's `color-mix(... N%, transparent)`).
  static Color wash(Color c, [double opacity = 0.12]) => c.withValues(alpha: opacity);

  /// Map a tier name to its color.
  static Color tier(String name) {
    switch (name.toLowerCase()) {
      case 'gold':
        return gold;
      case 'silver':
        return silver;
      case 'bronze':
        return bronze;
      case 'platinum':
        return platinum;
      case 'diamond':
        return diamond;
      // A player still in placement has no division; the old default painted
      // them gold, i.e. as the second-highest one.
      case 'unranked':
        return inkSoft;
      default:
        return gold;
    }
  }
}

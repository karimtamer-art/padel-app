import 'package:flutter/widgets.dart';

/// Spacing scale — mirrors the prototype's paddings/gaps.
class AppSpacing {
  AppSpacing._();

  static const double screen = 18; // horizontal page padding
  static const double card = 16; // inner card padding
  static const double gap = 12; // between cards
  static const double section = 26; // between home sections

  static const EdgeInsets screenH = EdgeInsets.symmetric(horizontal: screen);
}

/// Corner radii. (Prototype Tweak panel: Round=18 / Sharp=8 / Pill=26.)
class AppRadius {
  AppRadius._();

  static const double card = 18;
  static const double btn = 12;
  static const double chip = 999;

  static BorderRadius get cardR => BorderRadius.circular(card);
  static BorderRadius get btnR => BorderRadius.circular(btn);
  static BorderRadius get chipR => BorderRadius.circular(chip);
}

/// Soft, warm card shadow.
const List<BoxShadow> kCardShadow = [
  BoxShadow(color: Color(0x0D3C2A14), blurRadius: 2, offset: Offset(0, 1)),
  BoxShadow(color: Color(0x0D3C2A14), blurRadius: 20, offset: Offset(0, 8)),
];

const List<BoxShadow> kPopShadow = [
  BoxShadow(color: Color(0x383C2A14), blurRadius: 50, offset: Offset(0, 18)),
];

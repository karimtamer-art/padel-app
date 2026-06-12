import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';

/// Outfit type helpers — mirrors the prototype's type scale.
class AppText {
  AppText._();

  static TextStyle _o(double size, FontWeight w, Color c, double ls,
          {double? height}) =>
      GoogleFonts.outfit(
          fontSize: size,
          fontWeight: w,
          color: c,
          letterSpacing: ls,
          height: height,
          decoration: TextDecoration.none,
          decorationColor: Colors.transparent);

  // Titles
  static TextStyle bigTitle([Color c = AppColors.ink]) =>
      _o(27, FontWeight.w800, c, -0.6);
  static TextStyle barTitle([Color c = AppColors.ink]) =>
      _o(20, FontWeight.w800, c, 1.5);
  static TextStyle cardTitle([Color c = AppColors.ink]) =>
      _o(18, FontWeight.w800, c, -0.3);

  // Body
  static TextStyle body([Color c = AppColors.ink]) =>
      _o(14, FontWeight.w600, c, 0);
  static TextStyle bodyStrong([Color c = AppColors.ink]) =>
      _o(14, FontWeight.w700, c, 0);
  static TextStyle small([Color c = AppColors.inkSoft]) =>
      _o(12, FontWeight.w500, c, 0);

  // Numbers
  static TextStyle stat(double size, [Color c = AppColors.ink]) =>
      _o(size, FontWeight.w900, c, -1, height: 0.95);

  // Labels / kickers
  static TextStyle kicker([Color c = AppColors.inkSoft]) =>
      _o(11, FontWeight.w700, c, 1.4);
  static TextStyle tag([Color c = AppColors.inkSoft]) =>
      _o(10, FontWeight.w700, c, 0.5);
}

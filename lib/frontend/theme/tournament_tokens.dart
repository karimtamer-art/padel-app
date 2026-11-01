import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design tokens for the redesigned tournament screens.
///
/// Deliberately separate from [AppColors]: the two palettes are nearly the same
/// (background #E9DFCD vs #E9E1CF, primary #C2502A vs #BF4D2A), and moving the
/// shared ones would re-tint every other screen in the app.
class TColors {
  TColors._();

  // Brand green
  static const green = Color(0xFF26453A); // headers, dark buttons
  static const deepGreen = Color(0xFF1B302A); // sheet backdrop

  // Surfaces
  static const cream = Color(0xFFE9E1CF); // screen background
  static const surface = Color(0xFFFBF7F0); // cards
  static const sunken = Color(0xFFEFE7D7); // chips, quiet buttons
  static const sunkenSoft = Color(0xFFF3ECDF); // table header
  static const track = Color(0xFFDED3BD); // segmented track
  static const barTrack = Color(0xFFE6DCC8); // progress track
  static const avatar = Color(0xFFE0D3BB); // initials avatar

  // Lines
  static const border = Color(0xFFDCD1BC);
  static const borderStrong = Color(0xFFD6CAB2); // pills, icon buttons
  static const borderDashed = Color(0xFFCDBFA5); // dashed + outlined quiet
  static const divider = Color(0xFFECE3D2); // inside cards
  static const grabber = Color(0xFFC8BBA3);

  // Terracotta
  static const accent = Color(0xFFBF4D2A); // primary CTA
  static const accentPressed = Color(0xFF9A3B1F);
  static const accentTint = Color(0xFFF8EAE2); // "you" rows
  static const accentTintBorder = Color(0xFFEBC9B8);
  static const accentTintText = Color(0xFF9A3B1F);
  static const accentDeep = Color(0xFF6A2C17); // text on soft terracotta
  static const accentSoft = Color(0xFFF3D9CC); // icon tiles

  // Text
  static const text = Color(0xFF2A211A);
  static const text2 = Color(0xFF4A3F33);
  static const muted = Color(0xFF6E6253); // passes 4.5:1 on cream
  static const disabled = Color(0xFF8A7C6A); // TBD, lost-set numbers
  static const faint = Color(0xFFA08F78); // decorative + and chevrons

  // Status
  static const statusGreenBg = Color(0xFFD7EBDD);
  static const statusGreenText = Color(0xFF1E5A38);
  static const statusGreenDot = Color(0xFF2E8B57);
  static const statusGreenBorder = Color(0xFF8FC3A3);
  static const winnerCheck = Color(0xFF2E7D4F);
  static const neutralChip = Color(0xFFE6DCC8);

  // On green
  static const onGreenMuted = Color(0xFFC9D6CE);
  static const onGreenTab = Color(0xFFD5E0D9);
  static const sponsored = Color(0xFFF2C9B6);

  // Pale green (format chip, map)
  static const paleGreen = Color(0xFFD9E2D6);
  static const mapRoad = Color(0xFFC3D0BF);

  static const white = Color(0xFFFFFFFF);
}

/// Radii from the design: chips 10, buttons 14, match cards 18, feature cards 22,
/// sheet tops and the detail header's bottom corners 28.
class TRadius {
  TRadius._();
  static const chip = 10.0;
  static const button = 14.0;
  static const matchCard = 18.0;
  static const card = 22.0;
  static const sheet = 28.0;
}

/// Outfit, at the sizes the design specifies.
TextStyle tStyle(
  double size,
  FontWeight weight, {
  Color color = TColors.text,
  double letterSpacing = 0,
  double? height,
  bool tabular = false,
}) =>
    GoogleFonts.outfit(
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: letterSpacing,
      height: height,
      decoration: TextDecoration.none,
      fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
    );

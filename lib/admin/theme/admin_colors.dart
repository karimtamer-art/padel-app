import 'package:flutter/material.dart';

class AdminColors {
  AdminColors._();

  static const bg = Color(0xFFE7DECC);
  static const canvas = Color(0xFFEFE7D7);
  static const surface = Color(0xFFFBF7EF);
  static const surfaceAlt = Color(0xFFF4EDDF);
  static const surface3 = Color(0xFFECE2CF);

  static const sidebar = Color(0xFF1E332B);
  static const sidebar2 = Color(0xFF182A23);
  static const sidebarInk = Color(0xFFEDE6D6);
  static const sidebarFaint = Color(0xFF9DACA0);

  static const ink = Color(0xFF2A2218);
  static const inkSoft = Color(0xFF6E6149);
  static const inkFaint = Color(0xFFA2937A);

  static const line = Color(0xFFE0D5C0);
  static const lineSoft = Color(0xFFEADFCB);

  static const primary = Color(0xFF2D6BC4);
  static const primaryPress = Color(0xFF245AA8);
  static const primaryInk = Color(0xFFF4F8FF);

  static const success = Color(0xFF3F8B57);
  static const danger = Color(0xFFC0432F);
  static const warn = Color(0xFFB5811F);
  static const info = Color(0xFF3F7896);
  static const green = Color(0xFF2F6B57);

  static const bronze = Color(0xFFA66A3C);
  static const silver = Color(0xFF8C8884);
  static const gold = Color(0xFFB07E22);
  static const elite = Color(0xFF4E8083);

  static const cardShadow = [
    BoxShadow(color: Color(0x0D3C2A14), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x0F3C2A14), blurRadius: 22, offset: Offset(0, 8)),
  ];
  static const popShadow = [
    BoxShadow(color: Color(0x423C2A14), blurRadius: 50, offset: Offset(0, 18)),
  ];

  static Color wash(Color c, [double opacity = 0.12]) =>
      c.withValues(alpha: opacity);

  static Color tier(String metal) {
    switch (metal.toLowerCase()) {
      case 'bronze':
        return bronze;
      case 'silver':
        return silver;
      case 'gold':
        return gold;
      case 'elite':
        return elite;
      default:
        return silver;
    }
  }
}

class AdminUI {
  AdminUI._();
  static const double screen = 16;
  static const double card = 16;
  static const double gap = 12;
  static const double rCard = 16;
  static const double rField = 12;
  static const double rBtn = 11;

  static BorderRadius get cardR => BorderRadius.circular(rCard);
  static BorderRadius get fieldR => BorderRadius.circular(rField);
  static BorderRadius get btnR => BorderRadius.circular(rBtn);
}

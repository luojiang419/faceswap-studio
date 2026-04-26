import 'package:flutter/material.dart';

class StudioTheme {
  static ThemeData light() {
    const scheme = ColorScheme.light(
      primary: Color(0xFF0F9FB8),
      secondary: Color(0xFF14B8A6),
      surface: Color(0xFFF3F7FB),
      error: Color(0xFFB42318),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFFEAF0F6),
      fontFamily: 'Segoe UI',
      textTheme: const TextTheme(
        headlineMedium: TextStyle(fontWeight: FontWeight.w700),
        titleLarge: TextStyle(fontWeight: FontWeight.w700),
      ),
      cardTheme: _cardTheme(const Color(0xF7FFFFFF), const Color(0x1A334155)),
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: Colors.transparent,
        indicatorColor: Color(0x220F9FB8),
        selectedLabelTextStyle: TextStyle(fontWeight: FontWeight.w700),
        selectedIconTheme: IconThemeData(color: Color(0xFF0F172A)),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: Color(0xFF0F172A),
        surfaceTintColor: Colors.transparent,
      ),
    );
  }

  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      primary: Color(0xFF1AC6E4),
      secondary: Color(0xFF2DD4BF),
      surface: Color(0xFF111A23),
      error: Color(0xFFF97066),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFF091018),
      fontFamily: 'Segoe UI',
      textTheme: const TextTheme(
        headlineMedium: TextStyle(fontWeight: FontWeight.w700),
        titleLarge: TextStyle(fontWeight: FontWeight.w700),
      ),
      cardTheme: _cardTheme(const Color(0xD9131D28), const Color(0x1A94A3B8)),
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: Colors.transparent,
        indicatorColor: Color(0x261AC6E4),
        selectedLabelTextStyle: TextStyle(fontWeight: FontWeight.w700),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
      ),
    );
  }

  static CardThemeData _cardTheme(Color color, Color borderColor) {
    return CardThemeData(
      color: color,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: borderColor),
      ),
    );
  }
}

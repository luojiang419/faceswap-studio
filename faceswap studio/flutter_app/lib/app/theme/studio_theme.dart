import 'package:flutter/material.dart';

/// VoxCPM Studio 中性浅色与暖黑深色主题。
class StudioTheme {
  static ThemeData light() => _build(false);
  static ThemeData dark() => _build(true);

  static ThemeData _build(bool dark) {
    final panel = dark ? const Color(0xFF20201E) : Colors.white;
    final soft = dark ? const Color(0xFF282724) : const Color(0xFFF5F5F5);
    final background = dark ? const Color(0xFF171716) : const Color(0xFFFAFAFA);
    final ink = dark ? const Color(0xFFF0EDE7) : const Color(0xFF262626);
    final muted = dark ? const Color(0xFFAAA69D) : const Color(0xFF737373);
    final accent = dark ? const Color(0xFFF6AA75) : const Color(0xFF303030);
    final line = dark ? const Color(0x1FFFFFFF) : const Color(0xFFEBEBEB);
    final scheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: dark ? Brightness.dark : Brightness.light,
        ).copyWith(
          primary: accent,
          onPrimary: dark ? const Color(0xFF171716) : Colors.white,
          secondary: dark ? const Color(0xFFA6B880) : const Color(0xFF52734A),
          surface: panel,
          onSurface: ink,
          onSurfaceVariant: muted,
          surfaceContainerLowest: background,
          surfaceContainerLow: panel,
          surfaceContainer: soft,
          surfaceContainerHigh: soft,
          surfaceContainerHighest: soft,
          outline: dark ? const Color(0xFF55534D) : const Color(0xFFD6D6D6),
          outlineVariant: line,
          primaryContainer: soft,
          onPrimaryContainer: ink,
          secondaryContainer: soft,
          onSecondaryContainer: ink,
          error: dark ? const Color(0xFFFF7D7D) : const Color(0xFFD04D4D),
        );
    final rounded = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      fontFamily: 'Microsoft YaHei UI',
      visualDensity: VisualDensity.compact,
      textTheme: TextTheme(
        headlineMedium: TextStyle(
          color: ink,
          fontSize: 25,
          fontWeight: FontWeight.w700,
        ),
        titleLarge: TextStyle(
          color: ink,
          fontSize: 19,
          fontWeight: FontWeight.w700,
        ),
        titleMedium: TextStyle(
          color: ink,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        bodyMedium: TextStyle(color: ink, fontSize: 13, height: 1.5),
        bodySmall: TextStyle(color: muted, fontSize: 12, height: 1.5),
      ),
      cardTheme: CardThemeData(
        color: panel,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: rounded.copyWith(side: BorderSide(color: line)),
      ),
      dividerTheme: DividerThemeData(color: line, thickness: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: scheme.onPrimary,
          elevation: 0,
          shadowColor: Colors.transparent,
          disabledBackgroundColor: soft,
          disabledForegroundColor: muted.withValues(alpha: 0.55),
          shape: rounded,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          backgroundColor: panel,
          foregroundColor: ink,
          side: BorderSide(color: line),
          shape: rounded,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: ink, shape: rounded),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: ink, shape: rounded),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: soft,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: accent),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: Colors.transparent,
        indicatorColor: soft,
        selectedLabelTextStyle: TextStyle(
          color: ink,
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
        unselectedLabelTextStyle: TextStyle(color: muted, fontSize: 13),
        selectedIconTheme: IconThemeData(color: accent, size: 22),
        unselectedIconTheme: IconThemeData(color: muted, size: 22),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: panel,
        surfaceTintColor: Colors.transparent,
        shape: rounded,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: panel,
        surfaceTintColor: Colors.transparent,
        shape: rounded,
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(backgroundColor: WidgetStatePropertyAll(panel)),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        thumbColor: accent,
        inactiveTrackColor: line,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: accent,
        linearTrackColor: soft,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: soft,
        selectedColor: soft,
        side: BorderSide(color: line),
        shape: rounded,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: panel,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: ink,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: TextStyle(color: panel, fontSize: 12),
      ),
    );
  }
}

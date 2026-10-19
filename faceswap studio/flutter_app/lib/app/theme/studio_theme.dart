import 'package:flutter/material.dart';

/// 浅灰浮雕浅色与暖黑深色主题。
class StudioTheme {
  static ThemeData light() => _build(false);
  static ThemeData dark() => _build(true);

  static ThemeData _build(bool dark) {
    final panel = dark ? const Color(0xFF20201E) : const Color(0xFFFBFCFE);
    final soft = dark ? const Color(0xFF282724) : const Color(0xFFE8ECF1);
    final background = dark ? const Color(0xFF171716) : const Color(0xFFF3F5F8);
    final ink = dark ? const Color(0xFFF0EDE7) : const Color(0xFF333333);
    final muted = dark ? const Color(0xFFAAA69D) : const Color(0xFF595959);
    final disabledInk = dark
        ? muted.withValues(alpha: 0.55)
        : const Color(0xFF6B6B6B);
    final accent = dark ? const Color(0xFFF6AA75) : const Color(0xFF445F83);
    final line = dark ? const Color(0x1FFFFFFF) : const Color(0xFFDFE4EC);
    final selection = dark ? soft : const Color(0xFFE4EAF3);
    final textShadows = dark
        ? null
        : const [
            Shadow(
              color: Color(0x1A303030),
              offset: Offset(0, 0.7),
              blurRadius: 1,
            ),
          ];
    final scheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: dark ? Brightness.dark : Brightness.light,
        ).copyWith(
          primary: accent,
          onPrimary: dark ? const Color(0xFF171716) : const Color(0xFFF7F9FC),
          secondary: dark ? const Color(0xFFA6B880) : const Color(0xFF74839B),
          surface: panel,
          onSurface: ink,
          onSurfaceVariant: muted,
          surfaceContainerLowest: background,
          surfaceContainerLow: panel,
          surfaceContainer: soft,
          surfaceContainerHigh: soft,
          surfaceContainerHighest: soft,
          outline: dark ? const Color(0xFF55534D) : const Color(0xFFBCC6D4),
          outlineVariant: line,
          primaryContainer: selection,
          onPrimaryContainer: ink,
          secondaryContainer: dark ? soft : const Color(0xFFE9EDF4),
          onSecondaryContainer: ink,
          error: dark ? const Color(0xFFFF7D7D) : const Color(0xFFB5514F),
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
          shadows: textShadows,
        ),
        titleLarge: TextStyle(
          color: ink,
          fontSize: 19,
          fontWeight: FontWeight.w700,
          shadows: textShadows,
        ),
        titleMedium: TextStyle(
          color: ink,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          shadows: textShadows,
        ),
        labelLarge: dark
            ? null
            : TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                shadows: textShadows,
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
          backgroundColor: dark ? accent : panel,
          foregroundColor: dark ? scheme.onPrimary : ink,
          elevation: dark ? 0 : 2,
          shadowColor: dark ? Colors.transparent : const Color(0x5560718C),
          surfaceTintColor: Colors.transparent,
          textStyle: dark
              ? null
              : TextStyle(
                  fontFamily: 'Microsoft YaHei UI',
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  shadows: textShadows,
                ),
          disabledBackgroundColor: soft,
          disabledForegroundColor: disabledInk,
          shape: dark
              ? rounded
              : rounded.copyWith(side: BorderSide(color: line)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          backgroundColor: panel,
          foregroundColor: ink,
          disabledForegroundColor: dark ? null : disabledInk,
          textStyle: dark
              ? null
              : TextStyle(
                  fontFamily: 'Microsoft YaHei UI',
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  shadows: textShadows,
                ),
          side: BorderSide(color: line),
          shape: rounded,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: ink,
          disabledForegroundColor: dark ? null : disabledInk,
          shape: rounded,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: ink,
          disabledForegroundColor: dark ? null : disabledInk,
          shape: rounded,
        ),
      ),
      tabBarTheme: dark
          ? null
          : TabBarThemeData(labelColor: ink, unselectedLabelColor: muted),
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
        indicatorColor: selection,
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
        selectedColor: selection,
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

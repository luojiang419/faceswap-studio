import 'package:flutter/material.dart';

/// 页面模块与悬浮入口使用同一套柔和双层投影。
abstract final class StudioDepth {
  static Color borderColor(BuildContext context) {
    final theme = Theme.of(context);
    return theme.colorScheme.onSurface.withValues(
      alpha: theme.brightness == Brightness.dark ? 0.09 : 0.08,
    );
  }

  static List<BoxShadow> shadows(
    BuildContext context, {
    bool floating = false,
    bool subtle = false,
  }) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final strength = subtle ? 0.65 : 1.0;
    return [
      BoxShadow(
        color: (dark ? Colors.black : const Color(0xFF233044)).withValues(
          alpha: (dark ? 0.28 : (floating ? 0.12 : 0.075)) * strength,
        ),
        blurRadius: floating ? 28 : 20,
        spreadRadius: -3,
        offset: Offset(0, floating ? 9 : 5),
      ),
      BoxShadow(
        color: Colors.black.withValues(alpha: (dark ? 0.18 : 0.04) * strength),
        blurRadius: 5,
        offset: const Offset(0, 2),
      ),
    ];
  }
}

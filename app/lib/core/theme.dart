// 普通模式与老年模式主题。老年模式：更大字号、更大点击区域、更高对比度；功能完全相同。
// 字体：使用系统中文字体，不使用 google_fonts 或任何在线字体。

import 'package:flutter/material.dart';

enum DisplayMode { normal, elder }

class LevelColors {
  static Color of(String level, {bool elder = false}) => switch (level) {
        'red' => elder ? const Color(0xFFB00020) : const Color(0xFFD32F2F),
        'yellow' => elder ? const Color(0xFF8A5A00) : const Color(0xFFED8E00),
        'green' => elder ? const Color(0xFF1B5E20) : const Color(0xFF2E7D32),
        _ => elder ? const Color(0xFF37474F) : const Color(0xFF607D8B),
      };

  static String label(String level) => switch (level) {
        'red' => '红色',
        'yellow' => '黄色',
        'green' => '绿色',
        _ => '灰色',
      };

  static IconData icon(String level) => switch (level) {
        'red' => Icons.error,
        'yellow' => Icons.warning_amber_rounded,
        'green' => Icons.check_circle,
        _ => Icons.help,
      };
}

ThemeData buildTheme(DisplayMode mode) {
  final elder = mode == DisplayMode.elder;
  const seed = Color(0xFF00897B); // 青绿色：医疗、平静；旧稿暖橙色不作硬性规范
  final scheme = ColorScheme.fromSeed(
    seedColor: seed,
    contrastLevel: elder ? 1.0 : 0.0,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  final scale = elder ? 1.3 : 1.0;
  final minTap = elder ? 64.0 : 48.0;
  return base.copyWith(
    // 先并入 Material 字号几何（englishLike 含明确字号），否则按比例放大时字号为空会断言失败
    textTheme: base.typography.englishLike
        .merge(base.textTheme)
        .apply(fontSizeFactor: scale, bodyColor: elder ? Colors.black : null, displayColor: elder ? Colors.black : null),
    visualDensity: elder ? VisualDensity.comfortable : VisualDensity.standard,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: Size(minTap * 2, minTap), textStyle: TextStyle(fontSize: 16 * scale, fontWeight: FontWeight.w600)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: Size(minTap * 2, minTap), textStyle: TextStyle(fontSize: 15 * scale), side: elder ? const BorderSide(width: 2) : null),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(minimumSize: Size(minTap, minTap), textStyle: TextStyle(fontSize: 15 * scale))),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(minimumSize: Size(minTap, minTap), iconSize: 24 * scale)),
    listTileTheme: ListTileThemeData(minVerticalPadding: elder ? 14 : 8),
    cardTheme: CardThemeData(elevation: elder ? 0 : 1, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: elder ? const BorderSide(color: Colors.black54, width: 1.5) : BorderSide.none)),
  );
}

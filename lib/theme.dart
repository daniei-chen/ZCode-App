import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'state/session_status.dart';

/// 配色角色表。
///
/// 之所以做成 [ThemeExtension] 而不是一组静态常量：需要**日间 / 夜间两套**，
/// 且要随系统切换实时生效 —— 静态常量做不到这件事。
///
/// 使用方式：`context.zt.textHi`。
/// 纯逻辑里拿不到 context 时用 `ZT.paletteOf(brightness)`。
class ZTPalette extends ThemeExtension<ZTPalette> {
  const ZTPalette({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surfaceHi,
    required this.field,
    required this.hairline,
    required this.accent,
    required this.onAccent,
    required this.live,
    required this.warn,
    required this.danger,
    required this.textHi,
    required this.textLo,
  });

  final Brightness brightness;

  /// 页面底色。
  final Color bg;

  /// 卡片 / 面板底色。
  final Color surface;

  /// 比 surface 高一层（悬停、选中、分区）。
  final Color surfaceHi;

  /// 输入框 / 代码块底色。
  final Color field;

  /// 细分隔线。结构靠它和留白，不靠阴影。
  final Color hairline;

  /// 唯一强调色。**只用在有信息含义处**。
  final Color accent;

  final Color onAccent;

  /// 活跃 / 成功。
  final Color live;

  /// 提醒 / 中间态。
  final Color warn;

  /// 失败 / 危险。
  final Color danger;

  /// 主文本。
  final Color textHi;

  /// 次级文本 / 元信息。
  final Color textLo;

  bool get isDark => brightness == Brightness.dark;

  /// 夜间。
  static const ZTPalette dark = ZTPalette(
    brightness: Brightness.dark,
    // Values mirror the installed ZCode 3.11.2 renderer tokens:
    // --color-background, --color-panel, --color-card and --color-border.
    bg: Color(0xFF161616),
    surface: Color(0xFF202020),
    surfaceHi: Color(0xFF2B2B2B),
    field: Color(0xFF2B2B2B),
    hairline: Color(0xFF373737),
    accent: Color(0xFF4099FF),
    onAccent: Color(0xFF000000),
    live: Color(0xFF46BF72),
    warn: Color(0xFFFF8A30),
    danger: Color(0xFFFF5C5C),
    textHi: Color(0xFFF8F8F8),
    textLo: Color(0xFFADADAD),
  );

  /// 日间。
  ///
  /// 刻意避开纯白底 + 纯黑字（对比过强、刺眼），底色带一点冷灰；
  /// 强调色换成更深的青，否则亮底上会飘。
  static const ZTPalette light = ZTPalette(
    brightness: Brightness.light,
    // Values mirror the installed ZCode 3.11.2 light renderer tokens.
    bg: Color(0xFFF8F8F8),
    surface: Color(0xFFFFFFFF),
    surfaceHi: Color(0xFFF0F0F0),
    field: Color(0xFFFFFFFF),
    hairline: Color(0xFFD9D9D9),
    accent: Color(0xFF0B7FFF),
    onAccent: Color(0xFFFFFFFF),
    live: Color(0xFF1E8A3E),
    // Slightly darker than the renderer token so the app's 3:1 light-mode
    // status contrast gate remains satisfied.
    warn: Color(0xFFC26700),
    danger: Color(0xFFE03131),
    textHi: Color(0xFF262626),
    textLo: Color(0xFF5C5C5C),
  );

  static ZTPalette of(Brightness b) => b == Brightness.dark ? dark : light;

  Color statusColor(SessionStatus? status) => switch (status) {
    SessionStatus.live => live,
    SessionStatus.error => danger,
    SessionStatus.loading || null => accent,
  };

  @override
  ZTPalette copyWith({
    Brightness? brightness,
    Color? bg,
    Color? surface,
    Color? surfaceHi,
    Color? field,
    Color? hairline,
    Color? accent,
    Color? onAccent,
    Color? live,
    Color? warn,
    Color? danger,
    Color? textHi,
    Color? textLo,
  }) => ZTPalette(
    brightness: brightness ?? this.brightness,
    bg: bg ?? this.bg,
    surface: surface ?? this.surface,
    surfaceHi: surfaceHi ?? this.surfaceHi,
    field: field ?? this.field,
    hairline: hairline ?? this.hairline,
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    live: live ?? this.live,
    warn: warn ?? this.warn,
    danger: danger ?? this.danger,
    textHi: textHi ?? this.textHi,
    textLo: textLo ?? this.textLo,
  );

  @override
  ZTPalette lerp(covariant ZTPalette? other, double t) {
    if (other == null) return this;
    return ZTPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceHi: Color.lerp(surfaceHi, other.surfaceHi, t)!,
      field: Color.lerp(field, other.field, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      live: Color.lerp(live, other.live, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      textHi: Color.lerp(textHi, other.textHi, t)!,
      textLo: Color.lerp(textLo, other.textLo, t)!,
    );
  }
}

/// 主题构建。
abstract final class ZT {
  static const ZTPalette dark = ZTPalette.dark;
  static const ZTPalette light = ZTPalette.light;

  /// 纯逻辑里拿不到 context 时用。
  static ZTPalette paletteOf(Brightness b) => ZTPalette.of(b);

  static ThemeData theme(Brightness brightness) {
    final p = ZTPalette.of(brightness);
    final scheme =
        ColorScheme.fromSeed(
          seedColor: p.accent,
          brightness: brightness,
        ).copyWith(
          primary: p.accent,
          onPrimary: p.onAccent,
          secondary: p.accent,
          surface: p.surface,
          error: p.danger,
        );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: p.bg,
      extensions: <ThemeExtension<dynamic>>[p],
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: p.bg,
        foregroundColor: p.textHi,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
          color: p.textHi,
        ),
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: brightness == Brightness.dark
              ? Brightness.light
              : Brightness.dark,
          statusBarBrightness: brightness,
        ),
      ),
      cardTheme: CardThemeData(
        color: p.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        margin: const EdgeInsets.only(bottom: 10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: p.hairline),
        ),
      ),
      dividerTheme: DividerThemeData(color: p.hairline, thickness: 1, space: 1),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: p.hairline),
        ),
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: p.textHi,
        ),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: p.field,
        hintStyle: TextStyle(color: p.textLo.withValues(alpha: 0.55)),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: p.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: p.accent, width: 1.4),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: p.surfaceHi,
        contentTextStyle: TextStyle(fontSize: 13, color: p.textHi),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        extendedTextStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      listTileTheme: ListTileThemeData(iconColor: p.textLo),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: p.accent),
      textTheme: Typography.material2021(
        platform: TargetPlatform.android,
        colorScheme: scheme,
      ).black.apply(bodyColor: p.textHi, displayColor: p.textHi),
    );
  }

  static ThemeData get darkTheme => theme(Brightness.dark);
  static ThemeData get lightTheme => theme(Brightness.light);
}

/// `context.zt.textHi` 这种写法。
extension ZTContext on BuildContext {
  ZTPalette get zt =>
      Theme.of(this).extension<ZTPalette>() ??
      (Theme.of(this).brightness == Brightness.dark
          ? ZTPalette.dark
          : ZTPalette.light);
}

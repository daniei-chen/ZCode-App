import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/state/session_status.dart';
import 'package:zremote/state/theme_mode.dart';
import 'package:zremote/theme.dart';

/// WCAG 相对亮度。
double _luminance(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

/// WCAG 对比度（1~21）。
double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('调色板完整性', () {
    test('两套主题的角色齐全且亮度标注正确', () {
      expect(ZTPalette.dark.brightness, Brightness.dark);
      expect(ZTPalette.light.brightness, Brightness.light);
      expect(ZTPalette.dark.isDark, isTrue);
      expect(ZTPalette.light.isDark, isFalse);
    });

    test('paletteOf / ZT.paletteOf 返回对应主题', () {
      expect(ZTPalette.of(Brightness.dark), same(ZTPalette.dark));
      expect(ZTPalette.of(Brightness.light), same(ZTPalette.light));
      expect(ZT.paletteOf(Brightness.light), same(ZTPalette.light));
    });

    test('copyWith 与 lerp 不丢字段', () {
      final p = ZTPalette.dark.copyWith(accent: const Color(0xFF123456));
      expect(p.accent, const Color(0xFF123456));
      expect(p.bg, ZTPalette.dark.bg);

      final mid = ZTPalette.dark.lerp(ZTPalette.light, 0.5);
      expect(mid.bg, isNot(ZTPalette.dark.bg));
      expect(mid.bg, isNot(ZTPalette.light.bg));
      // t<0.5 保留起点亮度
      expect(
        ZTPalette.dark.lerp(ZTPalette.light, 0.2).brightness,
        Brightness.dark,
      );
      expect(
        ZTPalette.dark.lerp(ZTPalette.light, 0.8).brightness,
        Brightness.light,
      );
    });

    test('lerp(null) 返回自身', () {
      expect(ZTPalette.dark.lerp(null, 0.5), same(ZTPalette.dark));
    });
  });

  group('对比度（可读性硬门槛）', () {
    // 这条测试的价值：日间主题最容易出现"配出来好看但看不清"。
    for (final entry in {'夜间': ZTPalette.dark, '日间': ZTPalette.light}.entries) {
      final name = entry.key;
      final p = entry.value;

      test('$name：主文本对底色 ≥ 7:1（AAA 正文）', () {
        expect(
          _contrast(p.textHi, p.bg),
          greaterThanOrEqualTo(7.0),
          reason: '$name textHi/bg 对比不足',
        );
      });

      test('$name：次文本对底色 ≥ 4.5:1（AA）', () {
        expect(
          _contrast(p.textLo, p.bg),
          greaterThanOrEqualTo(4.5),
          reason: '$name textLo/bg 对比不足',
        );
      });

      test('$name：强调色对底色 ≥ 3:1（非文本 UI 下限）', () {
        expect(_contrast(p.accent, p.bg), greaterThanOrEqualTo(3.0));
      });

      test('$name：状态色对底色 ≥ 3:1', () {
        for (final c in [p.live, p.warn, p.danger]) {
          expect(
            _contrast(c, p.bg),
            greaterThanOrEqualTo(3.0),
            reason: '$name 状态色 $c 对比不足',
          );
        }
      });

      test('$name：强调色上的文字可读', () {
        expect(_contrast(p.onAccent, p.accent), greaterThanOrEqualTo(3.0));
      });

      test('$name：主次文本之间有层次（不糊成一片）', () {
        expect(_contrast(p.textHi, p.textLo), greaterThanOrEqualTo(1.8));
      });
    }

    test('日间比夜间亮（防止两套配错方向）', () {
      expect(
        _luminance(ZTPalette.light.bg),
        greaterThan(_luminance(ZTPalette.dark.bg)),
      );
      expect(
        _luminance(ZTPalette.light.textHi),
        lessThan(_luminance(ZTPalette.dark.textHi)),
      );
    });
  });

  group('主题构建', () {
    test('ThemeData 带上了调色板扩展', () {
      for (final b in Brightness.values) {
        final t = ZT.theme(b);
        expect(t.extension<ZTPalette>(), isNotNull);
        expect(t.brightness, b);
        expect(t.scaffoldBackgroundColor, ZTPalette.of(b).bg);
      }
      expect(ZT.darkTheme.brightness, Brightness.dark);
      expect(ZT.lightTheme.brightness, Brightness.light);
    });

    test('状态色映射跟随主题', () {
      expect(ZTPalette.dark.statusColor(null), ZTPalette.dark.accent);
      expect(ZTPalette.light.statusColor(null), ZTPalette.light.accent);
      expect(
        ZTPalette.light.statusColor(SessionStatus.live),
        ZTPalette.light.live,
      );
      expect(
        ZTPalette.light.statusColor(SessionStatus.error),
        ZTPalette.light.danger,
      );
    });
  });

  group('主题模式', () {
    test('toMaterial 三种取值', () {
      expect(ThemeModeNotifier.toMaterial(kThemeSystem), ThemeMode.system);
      expect(ThemeModeNotifier.toMaterial(kThemeLight), ThemeMode.light);
      expect(ThemeModeNotifier.toMaterial(kThemeDark), ThemeMode.dark);
    });

    test('未知取值回落 system', () {
      expect(ThemeModeNotifier.toMaterial('nonsense'), ThemeMode.system);
    });

    test('resolvePalette 按模式与系统亮度解析', () {
      expect(resolvePalette(kThemeLight, Brightness.dark), ZTPalette.light);
      expect(resolvePalette(kThemeDark, Brightness.light), ZTPalette.dark);
      expect(resolvePalette(kThemeSystem, Brightness.dark), ZTPalette.dark);
      expect(resolvePalette(kThemeSystem, Brightness.light), ZTPalette.light);
    });

    test('themeModeIsDark 与系统亮度解析一致', () {
      expect(themeModeIsDark(kThemeLight, Brightness.dark), isFalse);
      expect(themeModeIsDark(kThemeDark, Brightness.light), isTrue);
      expect(themeModeIsDark(kThemeSystem, Brightness.dark), isTrue);
      expect(themeModeIsDark(kThemeSystem, Brightness.light), isFalse);
    });
  });
}

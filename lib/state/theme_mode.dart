import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../services/device_store.dart';
import '../theme.dart';

/// 与 ZCode 桌面端一致的三种取值。
const kThemeSystem = 'system';
const kThemeLight = 'light';
const kThemeDark = 'dark';

const _nativeThemeChannel = MethodChannel('zremote/theme');

/// 界面主题模式（跟随系统 / 日间 / 夜间）。
///
/// 取值刻意与官方 `setting.themeMode` 对齐，将来同步设置时不用做映射。
class ThemeModeNotifier extends Notifier<String> {
  ThemeModeNotifier({String? initial}) : _initial = initial;

  final String? _initial;

  @override
  String build() {
    final initial = _initial;
    if (initial != null) return _valid(initial) ? initial : kThemeSystem;
    _load();
    return kThemeSystem;
  }

  Future<void> _load() async {
    final value = await DeviceStore.instance.themeModeSetting();
    state = _valid(value) ? value : kThemeSystem;
  }

  static bool _valid(String v) =>
      v == kThemeSystem || v == kThemeLight || v == kThemeDark;

  Future<void> set(String value) async {
    if (!_valid(value)) return;
    await DeviceStore.instance.setThemeModeSetting(value);
    try {
      // Android 12+ uses this persisted application night mode while it is
      // creating the system splash, preventing a light/dark flash on launch.
      await _nativeThemeChannel.invokeMethod<void>('setMode', value);
    } catch (_) {
      // Flutter tests and older platforms do not expose the native channel.
    }
    state = value;
  }

  /// 供 MaterialApp 用的 ThemeMode。
  static ThemeMode toMaterial(String value) => switch (value) {
    kThemeLight => ThemeMode.light,
    kThemeDark => ThemeMode.dark,
    _ => ThemeMode.system,
  };
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, String>(
  ThemeModeNotifier.new,
);

/// 将应用保存的主题模式解析成当前实际生效的亮暗色。
///
/// 原生页面和远程 WebView 都使用这一个解析结果，避免“应用已经切换，
/// WebView 仍按系统亮度显示”的分叉状态。
bool themeModeIsDark(String mode, Brightness platformBrightness) =>
    switch (mode) {
      kThemeDark => true,
      kThemeLight => false,
      _ => platformBrightness == Brightness.dark,
    };

/// 当前实际生效的调色板（供拿不到 context 的逻辑使用）。
ZTPalette resolvePalette(String mode, Brightness platform) =>
    themeModeIsDark(mode, platform) ? ZTPalette.dark : ZTPalette.light;

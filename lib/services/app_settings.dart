import 'package:flutter/services.dart';

abstract final class AppSettings {
  static const MethodChannel _channel = MethodChannel('zremote/app');

  static Future<void> open() async {
    try {
      await _channel.invokeMethod<void>('openAppSettings');
    } catch (_) {}
  }

  static Future<void> openNotifications() async {
    try {
      await _channel.invokeMethod<void>('openNotificationSettings');
    } catch (_) {
      await open();
    }
  }

  /// 系统通知是否开启。**未知按 false**（iter12 W-021）：通道异常/返回空
  /// 时无法确认通知可用，fail-open（原实现）会让设置页与诊断包把"未知"
  /// 显示成"已开启"，用户错过配置引导，通知这个核心价值静默失效；
  /// fail-closed 的代价只是多一次前往系统设置的引导。
  static Future<bool> notificationsEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('areNotificationsEnabled') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 诊断页用：Android 版本 / API / WebView Chromium 版本。
  static Future<Map<String, Object?>> androidInfo() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'androidInfo',
      );
      return {
        for (final e in (raw ?? const {}).entries) '${e.key}': e.value,
      };
    } catch (_) {
      return const {};
    }
  }

  /// 最近任务隐私遮罩开关（FLAG_SECURE）：生物识别开启时置 true，
  /// 切后台瞬间遮蔽应用快照，回前台由原生侧自动恢复。
  static Future<void> setRecentsCover(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setRecentsCover', enabled);
    } catch (_) {}
  }
}

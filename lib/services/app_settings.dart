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

  static Future<bool> notificationsEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('areNotificationsEnabled') ??
          true;
    } catch (_) {
      return true;
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

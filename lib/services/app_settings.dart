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
}

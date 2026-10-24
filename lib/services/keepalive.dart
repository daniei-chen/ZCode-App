import 'package:flutter/services.dart';

import 'app_log.dart';
import 'structured_log.dart';

/// 常驻前台服务的 Dart 侧开关（v1.2.0）。
///
/// 原生侧 `MonitorKeepAliveService`（dataSync 前台服务）只负责把进程保活，
/// 让 WebView 的 `/ws` 中继事件流在后台与锁屏期间存活——完成/审批/报错
/// 通知依赖它。应用每次启动都拉起（幂等：服务已在前台时 startForeground
/// 只是刷新通知）；失败不阻塞启动（旧系统/异常 ROM 下退化为旧行为）。
abstract final class MonitorKeepAlive {
  static const MethodChannel _channel = MethodChannel('zremote/keepalive');

  static bool _started = false;

  static Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      await _channel.invokeMethod<void>('start');
      AppLog.event(LogEvent.keepaliveStarted, level: LogLevel.debug);
    } catch (error) {
      // 常驻失败不是致命错误：应用在前台时通知照常工作。
      AppLog.failure(LogEvent.keepaliveStartFailed, error);
    }
  }

  static Future<void> stop() async {
    _started = false;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }
}

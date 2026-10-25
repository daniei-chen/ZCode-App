import 'package:flutter/services.dart';

import 'app_log.dart';
import 'structured_log.dart';

/// 常驻前台服务的 Dart 侧开关（v1.2.0）。
///
/// 原生侧 `MonitorKeepAliveService`（dataSync 前台服务）只负责把进程保活，
/// 让 WebView 的 `/ws` 中继事件流在后台与锁屏期间存活——完成/审批/报错
/// 通知依赖它。应用每次启动都拉起（幂等：服务已在前台时 startForeground
/// 只是刷新通知）；失败不阻塞启动（旧系统/异常 ROM 下退化为旧行为）。
///
/// v1.2.1 仿 DeepSeek-Harness 的展示形态：常驻通知显示「远程 / 已连接到
/// <当前设备名>」并带「断开连接」动作。[updateDevice] 在设备切换/改名时
/// 推送新名字（原生侧同名去重，无变化不刷新）。
abstract final class MonitorKeepAlive {
  static const MethodChannel _channel = MethodChannel('zremote/keepalive');

  static bool _started = false;
  static String _lastName = '';

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

  /// 把当前设备名同步到常驻通知（原生侧去重，同名调用是空操作）。
  static Future<void> updateDevice(String deviceName) async {
    final name = deviceName.trim();
    if (!_started || name.isEmpty || name == _lastName) return;
    _lastName = name;
    try {
      await _channel.invokeMethod<void>('update', {'name': name});
    } catch (_) {}
  }

  /// 同步连接状态到常驻通知文案（v1.3.0）：
  /// 在线 →「已连接到 <设备名>」，断连 →「连接已断开，恢复后自动继续」。
  /// 设备名与状态一起推（原生侧组合成最终文案并去重）。
  static Future<void> updateStatus({
    required String deviceName,
    required bool connected,
  }) async {
    if (!_started) return;
    try {
      await _channel.invokeMethod<void>('status', {
        'name': deviceName.trim(),
        'connected': connected,
      });
    } catch (_) {}
  }

  static Future<void> stop() async {
    _started = false;
    _lastName = '';
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }
}

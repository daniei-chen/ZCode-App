import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 头无监控引擎的状态外存（v1.4.0）。
///
/// UI 引擎与监控引擎是同进程的两个 Dart isolate——静态内存互不可见，
/// 监控引擎里的日志/状态对 UI 诊断页完全不可见（v1.3.1 的盲区：RL522
/// 写在监控引擎自己的环形缓冲里，导出的诊断包根本不含它）。本仓用
/// SharedPreferences 做跨隔离体共享：监控引擎每次状态迁移写入，诊断页
/// 与诊断包读取。
///
/// 只存枚举名/时间戳/计数——与诊断包的脱敏原则一致，无凭证。
abstract final class MonitorStateStore {
  static const _key = 'zremote.monitor_state_v1';

  static Future<void> writeDevice(String deviceId, String state) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = _readMap(prefs.getString(_key));
      map['devices'][deviceId] = state;
      map['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
      await prefs.setString(_key, jsonEncode(map));
    } catch (_) {}
  }

  static Future<void> removeDevice(String deviceId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = _readMap(prefs.getString(_key));
      if (map['devices'].remove(deviceId) != null) {
        await prefs.setString(_key, jsonEncode(map));
      }
    } catch (_) {}
  }

  /// 诊断页/诊断包读取：设备短 id → 状态枚举名。
  static Future<Map<String, String>> readDevices() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return const {};
      final map = _readMap(raw);
      return {
        for (final e in (map['devices'] as Map).entries)
          e.key as String: '${e.value}',
      };
    } catch (_) {
      return const {};
    }
  }

  static Map<String, dynamic> _readMap(String? raw) {
    if (raw == null || raw.isEmpty) return {'devices': <String, String>{}};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['devices'] is Map) {
        return {
          'devices': decoded['devices'],
          if (decoded['updatedAt'] != null)
            'updatedAt': decoded['updatedAt'],
        };
      }
    } catch (_) {}
    return {'devices': <String, String>{}};
  }
}

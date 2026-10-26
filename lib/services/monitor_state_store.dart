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

  /// 共享的 SharedPreferences 实例（v1.8.0：外置推送游标等跨隔离体状态
  /// 需要直接读写整数/字符串，不值得为每种形态再开一套读写方法）。
  static Future<SharedPreferences> preferences() =>
      SharedPreferences.getInstance();

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

  // ---- 任务摘要（v1.6.0 首页工作台）----
  // 键是 sid（目录设备与导入设备共用同一身份），值是最新的任务状态摘要。
  static const _summaryKey = 'zremote.monitor_summary_v1';

  /// 监控引擎每轮快照后写入：sid → {title, phase, pending, updatedAt}。
  /// phase: running | completed | error；pending=true 表示有等待审批/输入。
  static Future<void> writeSummary(String sid, Map<String, Object?> summary) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = _readMapOf(prefs.getString(_summaryKey));
      map[sid] = summary;
      await prefs.setString(_summaryKey, jsonEncode(map));
    } catch (_) {}
  }

  static Future<Map<String, Map<String, Object?>>> readSummaries() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_summaryKey);
      if (raw == null) return const {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return {
        for (final e in decoded.entries)
          if (e.value is Map)
            '${e.key}': Map<String, Object?>.from(e.value as Map),
      };
    } catch (_) {
      return const {};
    }
  }

  /// 键：sid → agentReady（命令通道就绪态，v1.6.0 诊断用）。
  static const _agentKey = 'zremote.monitor_agent_v1';

  static Future<void> writeAgentReady(String sid, bool ready) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = _readMapOf(prefs.getString(_agentKey));
      map[sid] = ready;
      await prefs.setString(_agentKey, jsonEncode(map));
    } catch (_) {}
  }

  static Future<Map<String, bool>> readAgentReady() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_agentKey);
      if (raw == null) return const {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return {
        for (final e in decoded.entries)
          if (e.value is bool) '${e.key}': e.value as bool,
      };
    } catch (_) {
      return const {};
    }
  }

  static Map<String, dynamic> _readMapOf(String? raw) {
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return {
          for (final e in decoded.entries) '${e.key}': e.value,
        };
      }
    } catch (_) {}
    return <String, dynamic>{}
      ..clear();
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

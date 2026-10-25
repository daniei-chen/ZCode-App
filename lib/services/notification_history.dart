import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 通知历史（v1.3.0）：系统通知的本地留底，错过弹窗也能回看。
///
/// 只在 [NotifierService] 真正投递系统通知前记录一条——应用内浮窗/事件流
/// 不进历史（那两处本来就能回看）。字段与通知规格一一对应，不含任何凭证；
/// `taskId` 用于点击回跳会话。
class NotificationHistoryEntry {
  const NotificationHistoryEntry({
    required this.id,
    required this.at,
    required this.deviceId,
    required this.deviceName,
    required this.type,
    required this.title,
    required this.body,
    required this.payload,
  });

  final int id;
  final DateTime at;
  final String deviceId;
  final String deviceName;
  final String type;
  final String title;
  final String body;

  /// 与系统通知相同的深链载荷：'deviceId' 或 'deviceId|taskId'。
  final String payload;

  Map<String, Object?> toJson() => {
    'id': id,
    'at': at.millisecondsSinceEpoch,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'type': type,
    'title': title,
    'body': body,
    'payload': payload,
  };

  static NotificationHistoryEntry? fromJson(Map<dynamic, dynamic> json) {
    final at = json['at'];
    if (at is! int) return null;
    String field(Object? key) => json[key] is String ? json[key] as String : '';
    return NotificationHistoryEntry(
      id: json['id'] is int ? json['id'] as int : 0,
      at: DateTime.fromMillisecondsSinceEpoch(at),
      deviceId: field('deviceId'),
      deviceName: field('deviceName'),
      type: field('type'),
      title: field('title'),
      body: field('body'),
      payload: field('payload'),
    );
  }
}

abstract final class NotificationHistory {
  static const _key = 'zremote.notif_history_v1';

  /// 有界：最多保留 200 条（约一整天的告警量），新的挤掉旧的。
  static const maxEntries = 200;

  static List<NotificationHistoryEntry> _cache = const [];
  static bool _loaded = false;

  /// 便于测试注入。
  static Future<SharedPreferences> Function() loadPrefs =
      SharedPreferences.getInstance;

  /// 测试专用：模拟新进程（清内存缓存，强制从 prefs 重新加载）。
  @visibleForTesting
  static void resetForTest() {
    _cache = const [];
    _loaded = false;
  }

  static Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await loadPrefs();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _cache = [
        for (final item in decoded)
          if (item is Map)
            ?NotificationHistoryEntry.fromJson(item)
      ];
    } catch (_) {
      _cache = const [];
    }
  }

  static Future<void> record(NotificationHistoryEntry entry) async {
    await _ensureLoaded();
    _cache = [..._cache, entry];
    if (_cache.length > maxEntries) {
      _cache = _cache.sublist(_cache.length - maxEntries);
    }
    await _persist();
  }

  /// 加载完成后的读取入口（异步：确保从 prefs 加载完成再返回）。
  /// 最新的在前。设置"通知历史"页与测试都应使用本方法；
  /// [cachedCount] 仅供诊断快照。
  static Future<List<NotificationHistoryEntry>> load() async {
    await _ensureLoaded();
    return List.of(_cache.reversed);
  }

  @Deprecated('改为 await load()；同步快照在首次加载完成前是空的')
  static List<NotificationHistoryEntry> entries() => List.of(_cache.reversed);

  static Future<void> clear() async {
    _cache = const [];
    await _persist();
  }

  /// 诊断页/测试用：当前缓存条数（未触发加载时为 0）。
  static int get cachedCount => _cache.length;

  static Future<void> _persist() async {
    try {
      final prefs = await loadPrefs();
      await prefs.setString(
        _key,
        jsonEncode([for (final e in _cache) e.toJson()]),
      );
    } catch (_) {
      // 持久化失败不影响通知本身；内存里的历史仍可供本次会话回看。
    }
  }
}

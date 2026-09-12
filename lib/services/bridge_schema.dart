import 'event_observer.dart';

/// Bridge 消息 schema 与尺寸门禁（v1.1.0）。
///
/// `_bridgeAllowed()` 解决"哪个页面可以调用 bridge"；这里解决"页面可以传
/// 什么"：每个 handler 在进入业务逻辑前先过类型与长度校验，超限/类型不符
/// 一律丢弃并计数，绝不进入解析路径。
abstract final class BridgeSchema {
  static const int maxThemeBytes = 256;
  static const int maxViewStateBytes = 64 * 1024;
  static const int maxSeenBytes = 512 * 1024;
  static const int maxEventBytes = 4 * 1024 * 1024;
  static const int maxWsEventBytes = 4 * 1024 * 1024;
  static const int maxStatsKeys = 32;

  /// Dart 侧桥消息丢弃计数（类型不符/超长），诊断页可见。
  static int droppedMessages = 0;

  /// 只接受非空且不超长的字符串；类型不符或超长计入丢弃。
  static String? acceptString(Object? body, {required int maxBytes}) {
    if (body is! String) {
      droppedMessages++;
      return null;
    }
    if (body.isEmpty) return null;
    if (body.length > maxBytes) {
      droppedMessages++;
      return null;
    }
    return body;
  }

  /// 遥测计数只接受 `Map<String, 非负数字>`：未知类型跳过、负数拒绝、
  /// 键数封顶；全部非法时返回 null。
  static Map<String, int>? acceptStats(Object? decoded) {
    if (decoded is! Map) {
      droppedMessages++;
      return null;
    }
    final out = <String, int>{};
    var keys = 0;
    for (final e in decoded.entries) {
      final k = e.key;
      final v = e.value;
      if (k is! String || v is! num) continue;
      if (v < 0) continue;
      out[k] = v.toInt();
      if (++keys >= maxStatsKeys) break;
    }
    return out.isEmpty ? null : out;
  }

  /// 保持事件字节上限与 JS 钩子一致（不同步会被本测试文件锁住）。
  static bool get eventCapMatchesHook => maxEventBytes == kMaxListenBytes;
}

import 'dart:collection';

import 'package:flutter/foundation.dart';

/// 统一日志（v1.1.0）：Release 下只保留必要事件，debug 构建同时输出控制台；
/// 环形缓冲最多 500 条，供诊断页由用户主动导出。
///
/// 硬规则：绝不记录 sid/hash/remoteControlToken、完整 URI（只允许 path）、
/// query、cookie、WebSocket 原文与会话正文。
abstract final class AppLog {
  static const int _maxEntries = 500;
  static final Queue<String> _ring = Queue<String>();

  /// 调试细节：仅 debug 构建记录，Release 下直接丢弃。
  static void debug(String message) {
    if (!kDebugMode) return;
    _add('D', message);
  }

  static void info(String message) => _add('I', message);

  static void warn(String message) => _add('W', message);

  static void error(String message, [Object? cause]) =>
      _add('E', cause == null ? message : '$message: $cause');

  static void _add(String level, String message) {
    final line = '${DateTime.now().toIso8601String()} $level $message';
    _ring.addLast(line);
    while (_ring.length > _maxEntries) {
      _ring.removeFirst();
    }
    debugPrint(line);
  }

  static List<String> snapshot() => List<String>.unmodifiable(_ring);

  static String export() => _ring.join('\n');
}

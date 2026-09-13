import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'structured_log.dart';

/// 统一日志（v1.1.0）。
///
/// 规则：
/// * 只能通过 [event] 写结构化事件（事件码 + 白名单字段），没有自由文本字段；
/// * 每行写入环形缓冲前统一过 [LogRedactor]（第二道防线）；
/// * Release 构建下 [debug] 事件直接丢弃，只保留 [info]/[warn]/[error]；
/// * 环形缓冲最多 500 行，供用户在诊断页主动复制/导出。
///
/// 硬规则（与 docs/PRIVACY.md 一致）：绝不记录 sid/hash/remoteControlToken、
/// 控制链接（含 query）、cookie、WebSocket 原文、会话标题与正文、页面 payload。
abstract final class AppLog {
  static const int _maxEntries = 500;
  static final Queue<String> _ring = Queue<String>();
  static int _droppedInRelease = 0;

  /// 结构化事件。字段值按字段类型再次规范化（route 去 query、device 截短、
  /// reason 变机器标签），保证日志面只含有限、可聚合的信息。
  static void event(
    LogEvent event, {
    Map<LogField, Object?> fields = const {},
    LogLevel level = LogLevel.info,
  }) {
    if (level == LogLevel.debug && !kDebugMode) {
      _droppedInRelease++;
      return;
    }
    final buffer = StringBuffer()
      ..write(event.code)
      ..write(' event=')
      ..write(event.name);
    for (final entry in fields.entries) {
      final value = _normalize(entry.key, entry.value);
      if (value == null) continue;
      buffer
        ..write(' ')
        ..write(entry.key.key)
        ..write('=')
        ..write(value);
    }
    _add(level.marker, buffer.toString());
  }

  static String? _normalize(LogField field, Object? value) {
    if (value == null) return null;
    return switch (field) {
      LogField.route => LogRedactor.route(value.toString()),
      LogField.device => LogRedactor.shortId(value.toString()),
      LogField.reason => LogRedactor.reason(value),
      LogField.error => LogRedactor.errorText(value),
      LogField.generation ||
      LogField.count ||
      LogField.size ||
      LogField.durationMs => value is num ? value.toInt().toString() : null,
      LogField.ok => value is bool ? (value ? 'true' : 'false') : null,
    };
  }

  /// 异常路径的结构化入口：`AppLog.failure(LogEvent.x, error)`。
  /// 异常文本按 [LogField.error] 规则脱敏并截断，不会把整段堆栈写进日志。
  static void failure(
    LogEvent event,
    Object error, {
    LogLevel level = LogLevel.warn,
    Map<LogField, Object?> fields = const {},
  }) => AppLog.event(event, fields: {...fields, LogField.error: error}, level: level);

  /// 调试细节：仅 debug 构建记录，Release 下直接丢弃（并计数以便诊断页自证）。
  static void debug(String message) => _legacy(LogLevel.debug, message);

  static void info(String message) => _legacy(LogLevel.info, message);

  static void warn(String message) => _legacy(LogLevel.warn, message);

  static void error(String message, [Object? cause]) =>
      _legacy(LogLevel.error, cause == null ? message : '$message: $cause');

  /// 兼容入口：结构化改造尚未覆盖的调用点仍走这里，但同样强制脱敏。
  static void _legacy(LogLevel level, String message) {
    if (level == LogLevel.debug && !kDebugMode) {
      _droppedInRelease++;
      return;
    }
    _add(level.marker, message);
  }

  static void _add(String level, String message) {
    final line =
        '${DateTime.now().toUtc().toIso8601String()} $level '
        '${LogRedactor.redact(message)}';
    _ring.addLast(line);
    while (_ring.length > _maxEntries) {
      _ring.removeFirst();
    }
    debugPrint(line);
  }

  /// Release 下被丢弃的 debug 条数（诊断页用来说明"日志不是被删，是没记"）。
  static int get droppedInRelease => _droppedInRelease;

  static List<String> snapshot() => List<String>.unmodifiable(_ring);

  /// 导出（已逐行脱敏，可直接交给用户）。
  static String export() => _ring.join('\n');

  static void clear() => _ring.clear();

  /// 仅在测试中使用：重置环形缓冲与计数。
  @visibleForTesting
  static void resetForTest() {
    _ring.clear();
    _droppedInRelease = 0;
  }
}

enum LogLevel {
  debug('D'),
  info('I'),
  warn('W'),
  error('E');

  const LogLevel(this.marker);

  final String marker;
}

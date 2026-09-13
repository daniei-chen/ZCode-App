import 'dart:convert';

import 'app_log.dart';
import 'bridge_schema.dart';
import 'structured_log.dart';
import 'webview_storage.dart';

/// 诊断包的一段（标题 + 若干键值行）。
class DiagnosticsSection {
  const DiagnosticsSection(this.title, this.rows);

  final String title;
  final List<MapEntry<String, String>> rows;
}

/// 诊断包的输入快照。刻意只收"已归一化"的值：
/// 设备只给短 id、状态只给枚举名、计数只给整数——调用方没有机会塞自由文本。
class DiagnosticsInputs {
  const DiagnosticsInputs({
    required this.generatedAt,
    required this.appVersion,
    required this.buildNumber,
    required this.platform,
    required this.deviceIds,
    required this.statuses,
    required this.settings,
    required this.stats,
    required this.droppedMessages,
    required this.droppedDebugLines,
    required this.logs,
  });

  final DateTime generatedAt;
  final String appVersion;
  final String buildNumber;
  final Map<String, String> platform;
  final List<String> deviceIds;
  final Map<String, String> statuses;
  final Map<String, String> settings;

  /// 设备短 id → (计数键 → 值)。
  final Map<String, Map<String, int>> stats;
  final int droppedMessages;
  final int droppedDebugLines;
  final List<String> logs;
}

/// 脱敏诊断包（PR20 / F19）。
///
/// 用户可以把它整段贴到 Issue 里：内容只有版本、平台枚举、设备**短 id**、状态枚举、
/// 开关布尔值、白名单计数与结构化日志。控制链接、sid/hash、cookie、会话标题与
/// 正文都进不来——调用方无法传入这些字段，且每一行仍会再过一次
/// [LogRedactor.redact] 做兜底（见 `test/diagnostics_bundle_test.dart` 的 canary 用例）。
abstract final class DiagnosticsBundle {
  static const maxLogLines = 200;

  static DiagnosticsInputs capture({
    required String appVersion,
    required String buildNumber,
    required Map<String, Object?> android,
    required List<String> deviceIds,
    required Map<String, String> statuses,
    required Map<String, Map<String, int>> stats,
    required bool biometric,
    required bool notificationsEnabled,
    required bool batteryIgnored,
  }) {
    return DiagnosticsInputs(
      generatedAt: DateTime.now().toUtc(),
      appVersion: appVersion,
      buildNumber: buildNumber,
      platform: {
        'android': '${android['release'] ?? '?'}',
        'sdkInt': '${android['sdkInt'] ?? '?'}',
        'webview': '${android['webViewChrome'] ?? '?'}',
      },
      // 设备标识保持原样传入；截短只发生在渲染层（sections），单点负责。
      deviceIds: deviceIds.toList(growable: false),
      statuses: {
        for (final entry in statuses.entries) entry.key: entry.value,
      },
      settings: {
        'biometric': biometric ? 'on' : 'off',
        'notifications': notificationsEnabled ? 'on' : 'off',
        'batteryUnrestricted': batteryIgnored ? 'on' : 'off',
        'webviewStorage': WebViewStorage.policySummary,
      },
      stats: {
        for (final entry in stats.entries) entry.key: entry.value,
      },
      droppedMessages: BridgeSchema.droppedMessages,
      droppedDebugLines: AppLog.droppedInRelease,
      logs: AppLog.snapshot(),
    );
  }

  static List<DiagnosticsSection> sections(DiagnosticsInputs inputs) {
    final logs = inputs.logs.length > maxLogLines
        ? inputs.logs.sublist(inputs.logs.length - maxLogLines)
        : inputs.logs;
    // 设备标识在渲染层再截一次短 id：即使调用方传进完整 id，诊断包里也只有短 id。
    final deviceCount = inputs.deviceIds.length;
    return [
      DiagnosticsSection('app', [
        MapEntry('version', 'v${inputs.appVersion}+${inputs.buildNumber}'),
        MapEntry('generatedAt', inputs.generatedAt.toIso8601String()),
        MapEntry('deviceCount', '$deviceCount'),
      ]),
      DiagnosticsSection('platform', [
        for (final entry in inputs.platform.entries) MapEntry(entry.key, entry.value),
      ]),
      DiagnosticsSection('settings', [
        for (final entry in inputs.settings.entries) MapEntry(entry.key, entry.value),
      ]),
      DiagnosticsSection('devices', [
        // 遍历原始 id（用于查状态），只把展示用的键截短。
        for (final id in inputs.deviceIds)
          MapEntry(LogRedactor.shortId(id), _statusOf(inputs.statuses, id)),
      ]),
      DiagnosticsSection('observer', [
        MapEntry('bridgeDroppedMessages', '${inputs.droppedMessages}'),
        MapEntry('debugLinesDroppedInRelease', '${inputs.droppedDebugLines}'),
        for (final device in inputs.stats.entries)
          for (final counter in device.value.entries)
            MapEntry('${LogRedactor.shortId(device.key)}.${counter.key}', '${counter.value}'),
      ]),
      DiagnosticsSection('storage', [
        for (final entry in WebViewStorage.inventory.entries)
          MapEntry(entry.key, entry.value),
      ]),
      DiagnosticsSection('logs', [
        for (var i = 0; i < logs.length; i++) MapEntry('$i', logs[i]),
      ]),
    ];
  }

  /// 渲染成可读文本。整段再过一次 [LogRedactor.redact] 作为最后一道防线。
  static String render(DiagnosticsInputs inputs) {
    final buffer = StringBuffer()
      ..writeln('# ZCode App diagnostics bundle')
      ..writeln('# 已脱敏：不含控制链接、sid/hash、cookie、会话标题或正文。');
    for (final section in sections(inputs)) {
      buffer
        ..writeln()
        ..writeln('[${section.title}]');
      for (final row in section.rows) {
        buffer.writeln('${_safe(row.key)} = ${_safe(row.value)}');
      }
    }
    return buffer.toString();
  }

  static String renderJson(DiagnosticsInputs inputs) {
    final payload = {
      'schema': 1,
      'sections': [
        for (final section in sections(inputs))
          {
            'title': section.title,
            'rows': [
              for (final row in section.rows) {'k': _safe(row.key), 'v': _safe(row.value)},
            ],
          },
      ],
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  static String _safe(String value) => LogRedactor.redact(value);

  /// 状态值本身不是敏感信息，但键可能是完整设备 id——两种形态都查一次。
  static String _statusOf(Map<String, String> statuses, String id) =>
      statuses[id] ?? statuses[LogRedactor.shortId(id)] ?? '-';
}

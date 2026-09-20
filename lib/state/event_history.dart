import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/event_observer.dart';
import '../services/structured_log.dart';
import '../services/text_sanitize.dart';

/// 单条事件历史（内存态，升级路线图「待处理中心」）。
///
/// 前台系统通知被抑制、悬浮卡 5 秒被覆盖、`DeviceFeed` 只存最近一条——
/// 错过即永久错过。本表按设备保存**有界**的最近事件，供待处理中心展示
/// "哪台机器哪个会话在等你"。
///
/// 红线：只存类型枚举、taskId、已清洗截断的标题/摘要与本机时间戳（数字）；
/// 不存 URL、正文或任何凭证；页面时钟不可信，时间一律取本机时钟（注入，
/// 测试可控）。
class HistoryEntry {
  const HistoryEntry({
    required this.type,
    required this.atMs,
    this.taskId,
    this.sessionTitle,
    this.summary,
    this.pendingTotal,
  });

  final String type;

  /// 本机时钟毫秒。
  final int atMs;

  final String? taskId;

  final String? sessionTitle;

  final String? summary;

  final int? pendingTotal;
}

class EventHistoryNotifier extends Notifier<Map<String, List<HistoryEntry>>> {
  /// 单设备条目上限（有界，升级路线图要求；新在前）。
  static const int maxEntriesPerDevice = 50;

  static String? _bounded(String? value) {
    if (value == null) return null;
    final clean = TextSanitize.stripBidiControls(value);
    if (clean == null || clean.isEmpty) return null;
    return LogRedactor.clipCodeUnits(clean, 120);
  }

  @override
  Map<String, List<HistoryEntry>> build() => const {};

  void record(
    String deviceId,
    ObservedEvent event, {
    DateTime Function() clock = DateTime.now,
  }) {
    if (deviceId.isEmpty) return;
    final entry = HistoryEntry(
      type: event.type,
      atMs: clock().millisecondsSinceEpoch,
      // taskId 页面可控：与跳转白名单上限对齐（session_jump 要求 ≤128）。
      taskId: event.taskId == null
          ? null
          : LogRedactor.clipCodeUnits(event.taskId!, 128),
      sessionTitle: _bounded(event.sessionTitle),
      summary: _bounded(event.summary),
      pendingTotal: event.pendingTotal,
    );
    final list = state[deviceId] ?? const <HistoryEntry>[];
    final next = <HistoryEntry>[entry, ...list];
    if (next.length > maxEntriesPerDevice) {
      next.removeRange(maxEntriesPerDevice, next.length);
    }
    state = {...state, deviceId: next};
  }

  /// 设备移除/页面销毁时清掉（与其它遥测同生命周期）。
  void forget(String deviceId) {
    if (!state.containsKey(deviceId)) return;
    state = Map.of(state)..remove(deviceId);
  }

  /// 擦除事务（R-04）：事件历史含会话标题与摘要，全量清除。
  void clearAll() {
    if (state.isEmpty) return;
    state = const {};
  }
}

final eventHistoryProvider =
    NotifierProvider<EventHistoryNotifier, Map<String, List<HistoryEntry>>>(
      EventHistoryNotifier.new,
    );

/// 待处理中心用：从历史里找**仍在等待**（权威计数 [pendingKeys] 命中）
/// 的最新一条审批类请求，供"点按跳转会话"复用既有 session_jump。
///
/// 复核 F2：只按"最新的审批类"取会跳到已被 resolved 的旧任务（历史里
/// resolved 不删除请求条目）——必须与 `feed.pendingByTask` 的权威键交叉
/// 校验；无命中时返回 null（调用方只切设备、不跳转）。
HistoryEntry? latestPendingRequest(
  List<HistoryEntry> entries,
  Set<String> pendingKeys,
) {
  for (final e in entries) {
    if ((e.type == 'permission_request' || e.type == 'elicitation_request') &&
        e.taskId != null &&
        pendingKeys.contains(e.taskId)) {
      return e;
    }
  }
  return null;
}

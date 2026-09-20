import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/event_observer.dart';
import '../services/structured_log.dart';
import '../services/text_sanitize.dart';

class DeviceFeed {
  const DeviceFeed({
    this.unread = 0,
    this.pendingByTask = const <String, int>{},
    this.lastSummary,
    this.lastType,
    this.lastTaskId,
    this.lastSessionTitle,
  });

  final int unread;

  /// 仍在等待处理的交互，按 taskId 记账（F11 / R-19）。
  ///
  /// 上游观察面（`pendingInteractionSummary`）没有请求级 id，只有按任务
  /// 聚合的 permission/userInput 计数，所以这里按**计数**降级记账：
  /// 值 = 该任务剩余待处理交互的权威总数。同任务两条审批解决一条
  /// （计数 2→1）红点必须保留，全解决（→0）才落下；设备级红点由本表聚合。
  final Map<String, int> pendingByTask;

  bool get permPending => pendingByTask.isNotEmpty;

  final String? lastSummary;

  /// 最近一条可提醒事件的要素（原通知历史的取数来源，悬浮通知卡用）。
  final String? lastType;

  final String? lastTaskId;

  final String? lastSessionTitle;

  DeviceFeed copyWith({
    int? unread,
    Map<String, int>? pendingByTask,
    String? lastSummary,
    String? lastType,
    String? lastTaskId,
    String? lastSessionTitle,
  }) => DeviceFeed(
    unread: unread ?? this.unread,
    pendingByTask: pendingByTask ?? this.pendingByTask,
    lastSummary: lastSummary ?? this.lastSummary,
    lastType: lastType ?? this.lastType,
    lastTaskId: lastTaskId ?? this.lastTaskId,
    lastSessionTitle: lastSessionTitle ?? this.lastSessionTitle,
  );
}

class EventFeedNotifier extends Notifier<Map<String, DeviceFeed>> {
  @override
  Map<String, DeviceFeed> build() => const {};

  /// 需要用户处理、会点亮红点的交互类型。
  static const _pendingTypes = {'permission_request', 'elicitation_request'};

  /// 无 taskId 的占位键（上游缺 id 时至少保证红点出现）。
  static const _unknownTask = 'unknown';

  /// pendingByTask 条目硬上限（iter12 N-P2-5）：键来自页面上行的 taskId，
  /// 是状态面唯一没有硬上界的表——敌对页面灌唯一 id 可让它无界增长
  /// （EventDedupeGate 只压制 2 分钟窗口内的重复提醒，管不到键的数量）。
  /// 超限按插入序压到 7/8（与 session_index 同策略，留 headroom 避免
  /// 每次插入都触发驱逐）；最近写入的键受保护，不被本轮数据自己挤出。
  static const int maxPendingTasks = 2000;

  /// 会话标题来自页面数据，与通知通道（120+省略号）同上限（安全审计
  /// S-7/N-5）：无界标题会经 `DeviceFeed` 进入悬浮卡 `Text`。
  static String? _boundedTitle(String? value) {
    if (value == null || value.length <= 121) return value;
    // 复核 P3：截断与 LogRedactor 同口径，代理对不切半（emoji 标题尾巴）。
    return '${LogRedactor.clipCodeUnits(value, 120)}…';
  }

  static Map<String, int> _capPending(
    Map<String, int> pending,
    String protectedKey,
  ) {
    if (pending.length <= maxPendingTasks) return pending;
    final target = maxPendingTasks - maxPendingTasks ~/ 8;
    final capped = <String, int>{};
    if (pending.containsKey(protectedKey)) {
      capped[protectedKey] = pending[protectedKey]!;
    }
    for (final entry in pending.entries) {
      if (capped.length >= target) break;
      if (entry.key == protectedKey) continue;
      capped[entry.key] = entry.value;
    }
    return capped;
  }

  void ingest(String deviceId, ObservedEvent event) {
    if (event.type == 'resolved') {
      _ingestResolved(deviceId, event);
      return;
    }
    if (!kNotifiableTypes.contains(event.type)) return;
    final current = state[deviceId] ?? const DeviceFeed();
    final pending = {...current.pendingByTask};
    if (_pendingTypes.contains(event.type)) {
      final total = event.pendingTotal;
      if (total != null && total > 0) {
        // 计数来自权威观察面，直接采信（R-19）。
        pending[_keyOf(event)] = total;
      } else {
        // 观察面给不出计数（显式页面事件）：只保证在场，不猜数量——
        // 已在场的任务不动，等下一条带计数的 differ 事件校准。
        pending.putIfAbsent(_keyOf(event), () => 1);
      }
    }
    state = {
      ...state,
      deviceId: current.copyWith(
        unread: current.unread + 1,
        pendingByTask: _capPending(pending, _keyOf(event)),
        // 摘要与标题来自页面数据，进悬浮卡/通知前剥离 Bidi 控制符（W-021）。
        lastSummary: TextSanitize.stripBidiControls(event.summary) ?? event.type,
        lastType: event.type,
        lastTaskId: event.taskId,
        lastSessionTitle: _boundedTitle(
          TextSanitize.stripBidiControls(event.sessionTitle),
        ),
      ),
    };
  }

  void _ingestResolved(String deviceId, ObservedEvent event) {
    final current = state[deviceId];
    if (current == null) return;
    final pending = {...current.pendingByTask};

    // resolved 只证明"有一项交互解决了"，不代表任务清零：剩余量以
    // pendingTotal 为准（R-19），直接采信——它就是下降后的权威值，
    // 不能与旧值取大。缺计数（如任务整行消失）才按"未知"走旧的逐键清理。
    //
    // 计数是对页面真实状态的事实记账，与通知偏好无关：用户关掉审批提醒时
    // 请求事件不会进入 feed，但带剩余量的 resolved 仍会在这里建立条目。
    // iter14 W-032 起徽标语义分离：未读数与「待批准」独立——本条路径建立的
    // 条目会让设备卡片**常显红点**（即使 unread=0）。这是有意行为：红点表示
    // 页面真实还有东西在等你（作为事实记账），不是未读提醒；若上游协议变化
    // 导致 resolved 剩余量不再可信，此决定随 R-19 复审。
    final total = event.pendingTotal;
    if (total != null && total > 0) {
      final key = _keyOf(event);
      if (pending[key] == total) return;
      pending[key] = total;
      state = {
        ...state,
        deviceId: current.copyWith(pendingByTask: _capPending(pending, key)),
      };
      return;
    }

    final taskId = event.taskId;
    if (taskId == null || taskId.isEmpty) {
      // 无法定位到具体任务时只清理占位项，**绝不**按设备整体清空（F11）。
      if (!pending.containsKey(_unknownTask)) return;
      pending.remove(_unknownTask);
    } else {
      final removed = pending.remove(taskId) != null;
      // 没有匹配 id 时用"占位请求"兜底：上游只给了部分 id 时，无法识别的
      // 那条请求收到 resolved 就落下红点，避免出现永远不灭的红点。
      if (!removed && !pending.containsKey(_unknownTask)) return;
      pending.remove(_unknownTask);
    }
    state = {...state, deviceId: current.copyWith(pendingByTask: pending)};
  }

  static String _keyOf(ObservedEvent event) {
    final taskId = event.taskId;
    return taskId == null || taskId.isEmpty ? _unknownTask : taskId;
  }

  void clear(String deviceId) {
    if (!state.containsKey(deviceId)) return;
    state = Map.of(state)..remove(deviceId);
  }

  /// 仅清未读徽标，保留「等待批准」红点与事件历史（通知中心入口使用）。
  void markRead(String deviceId) {
    final current = state[deviceId];
    if (current == null || current.unread == 0) return;
    state = {...state, deviceId: current.copyWith(unread: 0)};
  }

  void markAllRead(Iterable<String> deviceIds) {
    for (final id in deviceIds) {
      markRead(id);
    }
  }

  void forget(String deviceId) {
    if (!state.containsKey(deviceId)) return;
    state = Map.of(state)..remove(deviceId);
  }

  /// 擦除事务（R-04）：事件摘要含会话标题与审批内容，全量清除。
  void clearAll() {
    if (state.isEmpty) return;
    state = const {};
  }
}

final eventFeedProvider =
    NotifierProvider<EventFeedNotifier, Map<String, DeviceFeed>>(
      EventFeedNotifier.new,
    );

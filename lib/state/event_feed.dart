import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/event_observer.dart';

class DeviceFeed {
  const DeviceFeed({
    this.unread = 0,
    this.pendingTasks = const <String>{},
    this.lastSummary,
    this.lastType,
    this.lastTaskId,
    this.lastSessionTitle,
  });

  final int unread;

  /// 仍在等待处理的交互，按 taskId 记录（F11）。
  ///
  /// 用集合而不是一个设备级布尔：一台设备上两个任务同时等待批准时，
  /// 解决其中一个不能把另一个的红点一起清掉；设备级红点由本集合聚合。
  final Set<String> pendingTasks;

  bool get permPending => pendingTasks.isNotEmpty;

  final String? lastSummary;

  /// 最近一条可提醒事件的要素（原通知历史的取数来源，悬浮通知卡用）。
  final String? lastType;

  final String? lastTaskId;

  final String? lastSessionTitle;

  DeviceFeed copyWith({
    int? unread,
    Set<String>? pendingTasks,
    String? lastSummary,
    String? lastType,
    String? lastTaskId,
    String? lastSessionTitle,
  }) => DeviceFeed(
    unread: unread ?? this.unread,
    pendingTasks: pendingTasks ?? this.pendingTasks,
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

  void ingest(String deviceId, ObservedEvent event) {
    if (event.type == 'resolved') {
      final current = state[deviceId];
      if (current == null) return;
      final taskId = event.taskId;
      if (taskId == null || taskId.isEmpty) {
        // 无法定位到具体任务时只清理占位项，**绝不**按设备整体清空（F11）。
        if (!current.pendingTasks.contains(_unknownTask)) return;
        final next = {...current.pendingTasks}..remove(_unknownTask);
        state = {...state, deviceId: current.copyWith(pendingTasks: next)};
        return;
      }
      final next = {...current.pendingTasks};
      var changed = next.remove(taskId);
      // 没有匹配 id 时用"占位请求"兜底：上游只给了部分 id 时，无法识别的
      // 那条请求收到 resolved 就落下红点，避免出现永远不灭的红点。
      if (!changed) changed = next.remove(_unknownTask);
      if (!changed) return;
      state = {...state, deviceId: current.copyWith(pendingTasks: next)};
      return;
    }
    if (!kNotifiableTypes.contains(event.type)) return;
    final current = state[deviceId] ?? const DeviceFeed();
    final pending = {...current.pendingTasks};
    if (_pendingTypes.contains(event.type)) {
      final key = event.taskId;
      pending.add(key == null || key.isEmpty ? _unknownTask : key);
    }
    state = {
      ...state,
      deviceId: current.copyWith(
        unread: current.unread + 1,
        pendingTasks: pending,
        lastSummary: event.summary ?? event.type,
        lastType: event.type,
        lastTaskId: event.taskId,
        lastSessionTitle: event.sessionTitle,
      ),
    };
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
}

final eventFeedProvider =
    NotifierProvider<EventFeedNotifier, Map<String, DeviceFeed>>(
      EventFeedNotifier.new,
    );

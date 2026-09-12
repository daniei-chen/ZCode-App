import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/event_observer.dart';

class DeviceFeed {
  const DeviceFeed({
    this.unread = 0,
    this.permPending = false,
    this.lastSummary,
    this.lastType,
    this.lastTaskId,
    this.lastSessionTitle,
  });

  final int unread;

  final bool permPending;

  final String? lastSummary;

  /// 最近一条可提醒事件的要素（原通知历史的取数来源，悬浮通知卡用）。
  final String? lastType;

  final String? lastTaskId;

  final String? lastSessionTitle;

  DeviceFeed copyWith({
    int? unread,
    bool? permPending,
    String? lastSummary,
    String? lastType,
    String? lastTaskId,
    String? lastSessionTitle,
  }) => DeviceFeed(
    unread: unread ?? this.unread,
    permPending: permPending ?? this.permPending,
    lastSummary: lastSummary ?? this.lastSummary,
    lastType: lastType ?? this.lastType,
    lastTaskId: lastTaskId ?? this.lastTaskId,
    lastSessionTitle: lastSessionTitle ?? this.lastSessionTitle,
  );
}

class EventFeedNotifier extends Notifier<Map<String, DeviceFeed>> {
  @override
  Map<String, DeviceFeed> build() => const {};

  void ingest(String deviceId, ObservedEvent event) {
    if (event.type == 'resolved') {
      final current = state[deviceId];
      if (current == null) return;
      state = {...state, deviceId: current.copyWith(permPending: false)};
      return;
    }
    if (!kNotifiableTypes.contains(event.type)) return;
    final current = state[deviceId] ?? const DeviceFeed();
    state = {
      ...state,
      deviceId: current.copyWith(
        unread: current.unread + 1,
        permPending: current.permPending || event.type == 'permission_request',
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

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/event_observer.dart';

class DeviceFeed {
  const DeviceFeed({
    this.unread = 0,
    this.permPending = false,
    this.lastSummary,
  });

  final int unread;

  final bool permPending;

  final String? lastSummary;

  DeviceFeed copyWith({int? unread, bool? permPending, String? lastSummary}) =>
      DeviceFeed(
        unread: unread ?? this.unread,
        permPending: permPending ?? this.permPending,
        lastSummary: lastSummary ?? this.lastSummary,
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
    ref
        .read(eventHistoryProvider.notifier)
        .append(deviceId, event, DateTime.now().millisecondsSinceEpoch);
    final current = state[deviceId] ?? const DeviceFeed();
    state = {
      ...state,
      deviceId: current.copyWith(
        unread: current.unread + 1,
        permPending: current.permPending || event.type == 'permission_request',
        lastSummary: event.summary ?? event.type,
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
    ref.read(eventHistoryProvider.notifier).forget(deviceId);
    clear(deviceId);
  }
}

final eventFeedProvider =
    NotifierProvider<EventFeedNotifier, Map<String, DeviceFeed>>(
      EventFeedNotifier.new,
    );

class FeedEvent {
  const FeedEvent({
    required this.type,
    required this.at,
    this.taskId,
    this.sessionTitle,
    this.summary,
  });

  final String type;

  final int at;

  final String? taskId;

  final String? sessionTitle;

  final String? summary;
}

/// 通知中心的事件历史（跨设备时间线），按设备分组存储、新事件在前。
class EventHistoryNotifier extends Notifier<Map<String, List<FeedEvent>>> {
  static const int _maxPerDevice = 50;

  @override
  Map<String, List<FeedEvent>> build() => const {};

  void append(String deviceId, ObservedEvent event, int at) {
    final list = [
      FeedEvent(
        type: event.type,
        at: at,
        taskId: event.taskId,
        sessionTitle: event.sessionTitle,
        summary: event.summary,
      ),
      ...state[deviceId] ?? const <FeedEvent>[],
    ];
    state = {
      ...state,
      deviceId: list.length > _maxPerDevice
          ? list.sublist(0, _maxPerDevice)
          : list,
    };
  }

  void forget(String deviceId) {
    if (!state.containsKey(deviceId)) return;
    state = Map.of(state)..remove(deviceId);
  }
}

final eventHistoryProvider =
    NotifierProvider<EventHistoryNotifier, Map<String, List<FeedEvent>>>(
      EventHistoryNotifier.new,
    );

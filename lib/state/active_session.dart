import 'package:flutter_riverpod/flutter_riverpod.dart';

class ActiveSessionNotifier extends Notifier<Map<String, String?>> {
  @override
  Map<String, String?> build() => const {};

  void report(String deviceId, String? sessionId) {
    if (state[deviceId] == sessionId) return;
    state = {...state, deviceId: sessionId};
  }

  void forget(String deviceId) {
    if (!state.containsKey(deviceId)) return;
    state = Map.of(state)..remove(deviceId);
  }

  /// 擦除事务（R-04）：活动会话 id 属于设备凭证的一部分，全量清除。
  void clearAll() {
    if (state.isEmpty) return;
    state = const {};
  }
}

final activeSessionProvider =
    NotifierProvider<ActiveSessionNotifier, Map<String, String?>>(
      ActiveSessionNotifier.new,
    );

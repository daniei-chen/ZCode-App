import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 单台设备（某一个 WebView generation）的遥测快照（W2 / PR20-F18）。
class ObserverStats {
  const ObserverStats({
    required this.deviceId,
    required this.generation,
    required this.counters,
  });

  final String deviceId;
  final int generation;

  /// 只含白名单计数键与有限非负整数（见 `BridgeSchema.acceptStats`）。
  final Map<String, int> counters;

  @override
  String toString() =>
      'ObserverStats($deviceId gen=$generation ${counters.length} counters)';
}

/// EventObserver 遥测（F18）：按 **设备 + generation** 分别保存。
///
/// 旧实现是单个全局 map 整体替换：两台设备（或多设备轮播）交错上报时，后到的
/// 一台会覆盖另一台的计数，诊断页只剩一台设备的数字。现在：
/// * 每台设备各自一条记录，互不覆盖；
/// * 同一设备只接受 `generation >= 当前` 的上报——旧 generation（页面重建前）
///   迟到的消息不会把新页面的计数写回旧值。
class ObserverStatsNotifier extends Notifier<Map<String, ObserverStats>> {
  @override
  Map<String, ObserverStats> build() => const {};

  void update(String deviceId, int generation, Map<String, int> stats) {
    if (deviceId.isEmpty) return;
    final current = state[deviceId];
    if (current != null && generation < current.generation) return;
    state = {
      ...state,
      deviceId: ObserverStats(
        deviceId: deviceId,
        generation: generation,
        counters: Map<String, int>.unmodifiable(stats),
      ),
    };
  }

  /// 设备被移除/换凭证时清掉它的遥测，避免诊断页显示幽灵计数。
  void forget(String deviceId) {
    if (!state.containsKey(deviceId)) return;
    state = {...state}..remove(deviceId);
  }

  void clear() => state = const {};
}

final observerStatsProvider =
    NotifierProvider<ObserverStatsNotifier, Map<String, ObserverStats>>(
      ObserverStatsNotifier.new,
    );

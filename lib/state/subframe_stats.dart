import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'observer_stats.dart';

/// 单台设备的子 frame 导航取证计数（ADR-002 步骤 1）。
///
/// "官方页是否合法使用 iframe"只能用运行时数据回答：数不到证据，A（阻断
/// 全部子 frame）/B（按 host 白名单）的拍板就只剩猜测。计数只存**类别结果**
/// （allowed = 受信 origin 放行，cancelled = 非受信拦截），不存 URL、host 或
/// 内容——诊断页与诊断包红线（只含数字）。
class SubFrameStats {
  const SubFrameStats({
    required this.total,
    required this.allowed,
    required this.cancelled,
  });

  final int total;
  final int allowed;
  final int cancelled;

  @override
  String toString() =>
      'SubFrameStats(total=$total allowed=$allowed cancelled=$cancelled)';
}

/// 按 **设备** 分桶保存（与 `ObserverStatsNotifier` 同策略）：多设备并行时
/// 互不覆盖；计数跨 WebView generation 累积——页面重建不该清掉取证数据。
class SubFrameStatsNotifier extends Notifier<Map<String, SubFrameStats>> {
  @override
  Map<String, SubFrameStats> build() => const {};

  void record(String deviceId, {required bool trusted}) {
    if (deviceId.isEmpty) return;
    final prev =
        state[deviceId] ?? const SubFrameStats(total: 0, allowed: 0, cancelled: 0);
    state = {
      ...state,
      deviceId: SubFrameStats(
        total: prev.total + 1,
        allowed: prev.allowed + (trusted ? 1 : 0),
        cancelled: prev.cancelled + (trusted ? 0 : 1),
      ),
    };
  }

  /// 设备移除/换凭证时清掉，避免诊断页显示幽灵计数。
  void forget(String deviceId) {
    if (!state.containsKey(deviceId)) return;
    state = {...state}..remove(deviceId);
  }

  void clear() => state = const {};
}

final subFrameStatsProvider =
    NotifierProvider<SubFrameStatsNotifier, Map<String, SubFrameStats>>(
      SubFrameStatsNotifier.new,
    );

/// 合并 JS 观测计数与原生子 frame 取证计数：按设备取**并集**，subFrame 三键
/// 后展开。三键与 `BridgeSchema.statsKeys` 白名单不相交（测试锁定交集为空），
/// JS 侧无法伪造同名键把它们顶掉。诊断包导出走本函数；诊断页渲染遍历两个
/// provider，输出内容须与本函数结果保持等价（iter1 复审 F-3/N-3）。
Map<String, Map<String, int>> mergeObserverAndSubFrameStats(
  Map<String, ObserverStats> observer,
  Map<String, SubFrameStats> subFrames,
) => {
  for (final key in {...observer.keys, ...subFrames.keys})
    key: {
      ...?observer[key]?.counters,
      if (subFrames[key] != null) ...{
        'subFrameTotal': subFrames[key]!.total,
        'subFrameAllowed': subFrames[key]!.allowed,
        'subFrameCancelled': subFrames[key]!.cancelled,
      },
    },
};

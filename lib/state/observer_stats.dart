import 'package:flutter_riverpod/flutter_riverpod.dart';

/// EventObserver 遥测快照（W2）：页面 JS 侧每 15 秒上报的累计计数。
/// 只含数字，不含 URL/内容；供诊断页核对 fetch 白名单命中率与队列健康。
class ObserverStatsNotifier extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() => const {};

  void update(Map<String, int> stats) => state = stats;
}

final observerStatsProvider =
    NotifierProvider<ObserverStatsNotifier, Map<String, int>>(
      ObserverStatsNotifier.new,
    );

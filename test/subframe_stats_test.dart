import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/bridge_schema.dart';
import 'package:zremote/state/observer_stats.dart';
import 'package:zremote/state/subframe_stats.dart';

/// 子 frame 导航取证计数（ADR-002 步骤 1 / C2a）。
///
/// 回退即失败：计数丢失或跨设备串号，ADR-002 的拍板就失去数据来源。
void main() {
  test('按类别累加：total = allowed + cancelled', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(subFrameStatsProvider.notifier);

    notifier.record('d1', trusted: true);
    notifier.record('d1', trusted: false);
    notifier.record('d1', trusted: true);

    final stats = container.read(subFrameStatsProvider)['d1']!;
    expect(stats.total, 3);
    expect(stats.allowed, 2);
    expect(stats.cancelled, 1);
  });

  test('设备互相独立；forget 只清自己（多设备不串号）', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(subFrameStatsProvider.notifier);

    notifier.record('d1', trusted: true);
    notifier.record('d2', trusted: false);
    notifier.forget('d1');

    expect(container.read(subFrameStatsProvider).containsKey('d1'), isFalse);
    expect(container.read(subFrameStatsProvider)['d2']!.total, 1);
    expect(container.read(subFrameStatsProvider)['d2']!.cancelled, 1);
  });

  test('forget 不存在的设备是静默 no-op', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(subFrameStatsProvider.notifier).forget('ghost');
    expect(container.read(subFrameStatsProvider), isEmpty);
  });

  test('空设备 id 不记账（防幽灵行）', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(subFrameStatsProvider.notifier).record('', trusted: true);
    expect(container.read(subFrameStatsProvider), isEmpty);
  });

  test('clear 全清（擦除事务路径）', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(subFrameStatsProvider.notifier);
    notifier.record('d1', trusted: true);
    notifier.record('d2', trusted: false);
    notifier.clear();
    expect(container.read(subFrameStatsProvider), isEmpty);
  });

  test('计数跨多次 record 单调递增，无负数路径', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(subFrameStatsProvider.notifier);
    for (var i = 0; i < 100; i++) {
      notifier.record('d1', trusted: i.isEven);
    }
    final stats = container.read(subFrameStatsProvider)['d1']!;
    expect(stats.total, 100);
    expect(stats.allowed + stats.cancelled, stats.total);
  });

  group('mergeObserverAndSubFrameStats（iter1 复审 F-3）', () {
    ObserverStats observerStats(String device, Map<String, int> counters) =>
        ObserverStats(deviceId: device, generation: 1, counters: counters);

    test('同设备：JS 白名单键全保留，subFrame 三键叠加', () {
      final merged = mergeObserverAndSubFrameStats(
        {
          'd1': observerStats('d1', {'wsEvents': 7, 'fetchHit': 2}),
        },
        {
          'd1': const SubFrameStats(total: 3, allowed: 2, cancelled: 1),
        },
      );
      expect(merged['d1'], {
        'wsEvents': 7,
        'fetchHit': 2,
        'subFrameTotal': 3,
        'subFrameAllowed': 2,
        'subFrameCancelled': 1,
      });
    });

    test('并集：只有一侧的设备也不丢行', () {
      final merged = mergeObserverAndSubFrameStats(
        {
          'd1': observerStats('d1', {'wsEvents': 1}),
        },
        {
          'd2': const SubFrameStats(total: 1, allowed: 0, cancelled: 1),
        },
      );
      expect(merged.keys, containsAll(['d1', 'd2']));
      expect(merged['d1'], {'wsEvents': 1});
      expect(merged['d2'], {
        'subFrameTotal': 1,
        'subFrameAllowed': 0,
        'subFrameCancelled': 1,
      });
    });

    test('两侧皆空 → 空 merged（不产幽灵行）', () {
      expect(mergeObserverAndSubFrameStats({}, {}), isEmpty);
    });

    test('subFrame 三键与 JS 白名单不相交（iter1 复审 N-1：防 JS 伪造同名键被顶掉）', () {
      const subFrameKeys = {'subFrameTotal', 'subFrameAllowed', 'subFrameCancelled'};
      expect(BridgeSchema.statsKeys.intersection(subFrameKeys), isEmpty);
    });
  });
}

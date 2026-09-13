import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/state/observer_stats.dart';

void main() {
  late ProviderContainer container;
  late ObserverStatsNotifier notifier;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
    notifier = container.read(observerStatsProvider.notifier);
  });

  const deviceA = 'aaaaaaaa-1111-2222-3333-444444444444';
  const deviceB = 'bbbbbbbb-1111-2222-3333-444444444444';

  test('两台设备交错上报各留各的（不再互相覆盖，F18）', () {
    notifier.update(deviceA, 1, const {'wsMessages': 5});
    notifier.update(deviceB, 1, const {'wsMessages': 9});
    notifier.update(deviceA, 1, const {'wsMessages': 7});

    final state = container.read(observerStatsProvider);
    expect(state[deviceA]!.counters['wsMessages'], 7);
    expect(state[deviceB]!.counters['wsMessages'], 9, reason: 'B 的计数不得被 A 覆盖');
    expect(state.length, 2);
  });

  test('同一设备旧 generation 的迟到上报被丢弃', () {
    notifier.update(deviceA, 3, const {'wsMessages': 30});
    notifier.update(deviceA, 2, const {'wsMessages': 20});

    final stats = container.read(observerStatsProvider)[deviceA]!;
    expect(stats.generation, 3);
    expect(stats.counters['wsMessages'], 30);
  });

  test('同一设备新 generation 覆盖旧 generation', () {
    notifier.update(deviceA, 1, const {'wsMessages': 1});
    notifier.update(deviceA, 2, const {'wsMessages': 2});

    final stats = container.read(observerStatsProvider)[deviceA]!;
    expect(stats.generation, 2);
    expect(stats.counters['wsMessages'], 2);
  });

  test('同 generation 重复上报取最新值', () {
    notifier.update(deviceA, 1, const {'wsMessages': 1});
    notifier.update(deviceA, 1, const {'wsMessages': 4});
    expect(
      container.read(observerStatsProvider)[deviceA]!.counters['wsMessages'],
      4,
    );
  });

  test('forget 只移除指定设备（设备删除后的幽灵计数清理）', () {
    notifier.update(deviceA, 1, const {'wsMessages': 1});
    notifier.update(deviceB, 1, const {'wsMessages': 2});
    notifier.forget(deviceA);

    final state = container.read(observerStatsProvider);
    expect(state.containsKey(deviceA), isFalse);
    expect(state[deviceB], isNotNull);
    notifier.forget(deviceA); // 幂等
    expect(container.read(observerStatsProvider).length, 1);
  });

  test('clear 清空全部（锁定擦除路径）', () {
    notifier.update(deviceA, 1, const {'wsMessages': 1});
    notifier.update(deviceB, 1, const {'wsMessages': 2});
    notifier.clear();
    expect(container.read(observerStatsProvider), isEmpty);
  });

  test('空 deviceId 被忽略（bridge 消息缺参数时不留脏记录）', () {
    notifier.update('', 1, const {'wsMessages': 1});
    expect(container.read(observerStatsProvider), isEmpty);
  });

  test('计数不可变（页面无法通过共享引用改历史快照）', () {
    notifier.update(deviceA, 1, const {'wsMessages': 1});
    final counters = container.read(observerStatsProvider)[deviceA]!.counters;
    expect(() => counters['wsMessages'] = 99, throwsUnsupportedError);
  });
}

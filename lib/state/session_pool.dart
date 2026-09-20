import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device.dart';
import '../services/app_log.dart';
import '../services/device_store.dart';
import '../services/structured_log.dart';
import '../services/warmup.dart';
import 'bridge_health.dart';
import 'event_history.dart';
import '../services/device_connectivity.dart';
import 'observer_stats.dart';
import 'subframe_stats.dart';

class DeviceListNotifier extends Notifier<List<RemoteDevice>> {
  DeviceListNotifier({List<RemoteDevice>? seed})
    : _seed = seed == null ? null : List<RemoteDevice>.unmodifiable(seed);

  final List<RemoteDevice>? _seed;

  /// 命令串行队列（R-06）。
  ///
  /// 审计复现：磁盘写入已串行化，但各变更方法在 await 之前从**旧 state**
  /// 计算新列表、await 之后再各自发布——并发时后发布者用旧快照覆盖前者的
  /// 结果（rename×replace 丢标签、add×reorder 丢设备、remove×rename 把
  /// 已删记录写回）。这里把"读 state → 计算 → 持久化 → 发布"整段入队，
  /// 同一条命令只能看到前一条命令提交后的状态。
  Future<void> _commands = Future<void>.value();

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _commands.then((_) => action());
    // 队列自身吞异常：一次失败不得阻断后续命令；调用方仍拿到原始错误。
    _commands = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  @override
  List<RemoteDevice> build() {
    final seed = _seed;
    if (seed != null) return seed;
    _load();
    return [];
  }

  Future<void> _load() async {
    await _enqueue(() async {
      final result = await DeviceStore.instance.loadAllWithStatus();
      // provider 已被销毁时不得写 state（Riverpod 会抛 UnmountedRefException）。
      if (!ref.mounted) return;
      state = result.devices;
      ref.read(deviceStoreUnavailableProvider.notifier).set(result.unavailable);
      // 完整性计数随加载更新（iter12 W-018b）：诊断面可见，不再只在日志里。
      ref.read(deviceStoreIntegrityProvider.notifier).report(result);
    });
  }

  /// 供 UI 重试（存储恢复后无需重启应用）。
  Future<void> reload() => _load();

  Future<void> add(RemoteDevice device) => _enqueue(() async {
    await DeviceStore.instance.add(device);
    if (!ref.mounted) return;
    state = [...state, device];
  });

  Future<void> rename(String id, String label) => _enqueue(() async {
    RemoteDevice? target;
    for (final d in state) {
      if (d.id == id) {
        target = d;
        break;
      }
    }
    // 串行后这里看到的是最新 state：设备已被删除时不会"复活"记录（R-06）。
    if (target == null || label.trim().isEmpty) return;
    final updated = target.copyWith(label: label.trim());
    await DeviceStore.instance.update(updated);
    if (!ref.mounted) return;
    state = [
      for (final d in state)
        if (d.id == id) updated else d,
    ];
  });

  Future<void> remove(String id) => _enqueue(() async {
    await DeviceStore.instance.remove(id);
    // 取消待写定时器并清掉内存预热记录：否则延时写入会把已删设备的
    // warmup 又写回存储（F10）。
    await ref.read(warmupMemoryProvider.notifier).forget(id);
    // 遥测与设备同生命周期（PR20/F18）：设备不在了，诊断页不该还显示它的计数。
    ref.read(observerStatsProvider.notifier).forget(id);
    // 子 frame 取证计数同生命周期（ADR-002 步骤 1）。
    ref.read(subFrameStatsProvider.notifier).forget(id);
    // 桥健康同生命周期（iter7 R-6）：否则诊断包仍带已删设备的 bridge 行。
    ref.read(bridgeHealthProvider.notifier).forget(id);
    // 事件历史（待处理中心）同生命周期：设备不在了，历史不残留。
    ref.read(eventHistoryProvider.notifier).forget(id);
    // 连通性探测结果同生命周期（iter8）。
    ref.read(deviceConnectivityProvider.notifier).forget(id);
    if (!ref.mounted) return;
    final removedIndex = state.indexWhere((d) => d.id == id);
    final activeIndex = ref.read(activeTabProvider);
    state = state.where((d) => d.id != id).toList();
    if (removedIndex < 0) return;
    // 选择跟随 deviceId（F10）：删除前方的设备不得让当前会话漂移到别的机器，
    // 删除当前设备时落到确定的后继（或最后一台）。
    if (removedIndex < activeIndex) {
      ref.read(activeTabProvider.notifier).set(activeIndex - 1);
    } else if (removedIndex == activeIndex) {
      final fallback = activeIndex >= state.length
          ? state.length - 1
          : activeIndex;
      ref.read(activeTabProvider.notifier).set(fallback < 0 ? 0 : fallback);
    }
  });

  Future<void> reorder(int oldIndex, int newIndex) => _enqueue(() async {
    if (oldIndex < 0 || oldIndex >= state.length) return;
    // onReorderItem 的 newIndex 已对移除项做过修正，这里不再减一。
    if (newIndex < 0 || newIndex >= state.length) return;
    if (oldIndex == newIndex) return;

    final active = ref.read(activeTabProvider);
    final activeId = active < state.length ? state[active].id : null;

    final reordered = [...state]..removeAt(oldIndex);
    final moved = state[oldIndex];
    reordered.insert(newIndex, moved);

    await DeviceStore.instance.saveOrder([for (final d in reordered) d.id]);
    if (!ref.mounted) return;
    state = reordered;

    if (activeId != null) {
      final i = reordered.indexWhere((d) => d.id == activeId);
      if (i >= 0 && ref.read(activeTabProvider) != i) {
        ref.read(activeTabProvider.notifier).set(i);
      }
    }
  });

  Future<void> replaceLink(String id, RemoteDevice parsed) => _enqueue(() async {
    RemoteDevice? target;
    for (final d in state) {
      if (d.id == id) {
        target = d;
        break;
      }
    }
    if (target == null) return;
    final updated = RemoteDevice(
      id: target.id,
      baseUrl: parsed.baseUrl,
      params: parsed.params,
      label: target.label.isNotEmpty ? target.label : parsed.label,
      createdAt: target.createdAt,
    );
    await DeviceStore.instance.update(updated);
    // 旧链接对应的请求签名可能指向另一台桌面端，不能在新凭证下重放。
    await DeviceStore.instance.setWarmupScript(id, null);
    if (!ref.mounted) return;
    state = [
      for (final d in state)
        if (d.id == id) updated else d,
    ];
  });

  /// 擦除事务（R-04）：磁盘已清空后，内存里的设备对象（持有控制链接
  /// 凭证）必须同步清掉——否则门禁"关了"，Provider 里还留着可用的凭证。
  /// 只清内存态；磁盘由 `DeviceStore.clearAll` 负责，由擦除事务统一编排。
  void clearAll() {
    if (state.isEmpty) return;
    state = const [];
  }
}

final deviceListProvider =
    NotifierProvider<DeviceListNotifier, List<RemoteDevice>>(
      DeviceListNotifier.new,
    );

class ActiveTabNotifier extends Notifier<int> {
  ActiveTabNotifier({this.initialIndex = 0});

  final int initialIndex;

  bool _restoreDone = false;

  bool _jumpedBeforeRestore = false;

  @override
  int build() => initialIndex;

  void set(int index) {
    // v1.0.6 纯 WebView 化后根部只剩设备会话栈：合法索引就是 0..设备数-1。
    final maxIndex = ref.read(deviceListProvider).length - 1;
    if (index < 0 || index > maxIndex) return;
    state = index;
    if (index < ref.read(deviceListProvider).length) {
      _jumpedBeforeRestore = true;
      unawaited(
        DeviceStore.instance
            .setLastDeviceId(ref.read(deviceListProvider)[index].id)
            .catchError((e) {
              AppLog.failure(
                LogEvent.deviceLastUsedPersistFailed,
                e,
                fields: {LogField.reason: 'set_last_device'},
              );
            }),
      );
    }
  }

  Future<void> restoreLast() async {
    if (_restoreDone || _jumpedBeforeRestore) return;
    _restoreDone = true;
    final id = await DeviceStore.instance.lastDeviceId();
    if (!ref.mounted) return;
    if (_jumpedBeforeRestore) return;
    if (id == null) return;
    final index = ref.read(deviceListProvider).indexWhere((d) => d.id == id);
    if (index >= 0) state = index;
  }

  void clampTo(int childCount) {
    if (state >= childCount) state = childCount - 1;
    if (state < 0) state = 0;
  }

  /// 擦除事务（R-04）：设备清空后回到索引 0，避免选择状态指向已不存在的设备。
  void reset() {
    _restoreDone = false;
    _jumpedBeforeRestore = false;
    if (state != 0) state = 0;
  }
}

final activeTabProvider = NotifierProvider<ActiveTabNotifier, int>(
  ActiveTabNotifier.new,
);

class BiometricNotifier extends Notifier<bool> {
  BiometricNotifier({this.initial = false});

  final bool initial;

  @override
  bool build() {
    _load();
    return initial;
  }

  Future<void> _load() async {
    final value = await DeviceStore.instance.biometricEnabled();
    if (!ref.mounted) return;
    state = value;
  }

  Future<void> set(bool value) async {
    await DeviceStore.instance.setBiometricEnabled(value);
    if (!ref.mounted) return;
    state = value;
  }

  /// 重新读取偏好。读取失败返回 false 且**不改变**当前状态——
  /// 调用方据此保持锁定（fail-closed），绝不把"读不到"当成"未启用"。
  Future<bool> reload() async {
    try {
      final value = await DeviceStore.instance.biometricEnabled();
      if (!ref.mounted) return false;
      state = value;
      return true;
    } catch (_) {
      return false;
    }
  }
}

final biometricProvider = NotifierProvider<BiometricNotifier, bool>(
  BiometricNotifier.new,
);

/// 安全偏好读取状态：`true` = 读取失败。
///
/// 读取失败时门禁保持锁定（fail-closed），由锁屏提供"重试"；
/// 只有确实读到 false 才允许直接进入内容。
class SecurityPrefNotifier extends Notifier<bool> {
  SecurityPrefNotifier({this.initial = false});

  final bool initial;

  @override
  bool build() => initial;

  void setUnreadable(bool value) => state = value;
}

final securityPrefUnreadableProvider =
    NotifierProvider<SecurityPrefNotifier, bool>(SecurityPrefNotifier.new);

/// 设备存储是否不可用（secure storage 读取失败）。
///
/// 与"没有设备"严格区分：UI 据此显示可重试的故障状态，而不是引导用户
/// 去接入第一台设备（那会让用户以为数据丢了）。
class DeviceStoreUnavailableNotifier extends Notifier<bool> {
  DeviceStoreUnavailableNotifier({this.initial = false});

  final bool initial;

  @override
  bool build() => initial;

  void set(bool value) => state = value;
}

final deviceStoreUnavailableProvider =
    NotifierProvider<DeviceStoreUnavailableNotifier, bool>(
      DeviceStoreUnavailableNotifier.new,
    );

/// 最近一次设备库加载的完整性结果（iter12 W-018b）。
///
/// 之前 [DeviceLoadResult.repaired]/[skippedRecords] 只进 AppLog、不进任何
/// 状态面——诊断页/诊断包看不到"存储发生过隔离/修复"，故障只剩日志里一条
/// 短 reason。这里把最近一次加载的结果挂到 provider：只含**数字与布尔**，
/// 符合诊断红线；null 表示本轮启动尚未加载过。
class DeviceStoreIntegrity {
  const DeviceStoreIntegrity({
    required this.skippedRecords,
    required this.repaired,
  });

  /// 被隔离（解析失败/键值 id 不符）的记录数。
  final int skippedRecords;

  /// 本次加载是否触发过索引修复/重建。
  final bool repaired;
}

class DeviceStoreIntegrityNotifier extends Notifier<DeviceStoreIntegrity?> {
  @override
  DeviceStoreIntegrity? build() => null;

  void report(DeviceLoadResult result) {
    state = DeviceStoreIntegrity(
      skippedRecords: result.skippedRecords,
      repaired: result.repaired,
    );
  }

  void clear() => state = null;
}

final deviceStoreIntegrityProvider =
    NotifierProvider<DeviceStoreIntegrityNotifier, DeviceStoreIntegrity?>(
      DeviceStoreIntegrityNotifier.new,
    );

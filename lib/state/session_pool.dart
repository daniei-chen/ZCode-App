import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device.dart';
import '../services/device_store.dart';
import '../services/app_log.dart';

class DeviceListNotifier extends Notifier<List<RemoteDevice>> {
  DeviceListNotifier({List<RemoteDevice>? seed})
    : _seed = seed == null ? null : List<RemoteDevice>.unmodifiable(seed);

  final List<RemoteDevice>? _seed;

  @override
  List<RemoteDevice> build() {
    final seed = _seed;
    if (seed != null) return seed;
    _load();
    return [];
  }

  Future<void> _load() async {
    final result = await DeviceStore.instance.loadAllWithStatus();
    // provider 已被销毁时不得写 state（Riverpod 会抛 UnmountedRefException）。
    if (!ref.mounted) return;
    state = result.devices;
    ref.read(deviceStoreUnavailableProvider.notifier).set(result.unavailable);
  }

  /// 供 UI 重试（存储恢复后无需重启应用）。
  Future<void> reload() => _load();

  Future<void> add(RemoteDevice device) async {
    await DeviceStore.instance.add(device);
    state = [...state, device];
  }

  Future<void> rename(String id, String label) async {
    RemoteDevice? target;
    for (final d in state) {
      if (d.id == id) {
        target = d;
        break;
      }
    }
    if (target == null || label.trim().isEmpty) return;
    final updated = target.copyWith(label: label.trim());
    await DeviceStore.instance.update(updated);
    state = [
      for (final d in state)
        if (d.id == id) updated else d,
    ];
  }

  Future<void> remove(String id) async {
    await DeviceStore.instance.remove(id);
    state = state.where((d) => d.id != id).toList();
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
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
    state = reordered;

    if (activeId != null) {
      final i = reordered.indexWhere((d) => d.id == activeId);
      if (i >= 0 && ref.read(activeTabProvider) != i) {
        ref.read(activeTabProvider.notifier).set(i);
      }
    }
  }

  Future<void> replaceLink(String id, RemoteDevice parsed) async {
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
    state = [
      for (final d in state)
        if (d.id == id) updated else d,
    ];
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
              AppLog.warn('[ZR] lastDevice 落盘失败: $e');
            }),
      );
    }
  }

  Future<void> restoreLast() async {
    if (_restoreDone || _jumpedBeforeRestore) return;
    _restoreDone = true;
    final id = await DeviceStore.instance.lastDeviceId();
    if (_jumpedBeforeRestore) return;
    if (id == null) return;
    final index = ref.read(deviceListProvider).indexWhere((d) => d.id == id);
    if (index >= 0) state = index;
  }

  void clampTo(int childCount) {
    if (state >= childCount) state = childCount - 1;
    if (state < 0) state = 0;
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
    state = await DeviceStore.instance.biometricEnabled();
  }

  Future<void> set(bool value) async {
    await DeviceStore.instance.setBiometricEnabled(value);
    state = value;
  }

  /// 重新读取偏好。读取失败返回 false 且**不改变**当前状态——
  /// 调用方据此保持锁定（fail-closed），绝不把"读不到"当成"未启用"。
  Future<bool> reload() async {
    try {
      state = await DeviceStore.instance.biometricEnabled();
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

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'native_channel.dart';
import 'relay_source.dart';
import 'session_pool.dart';

/// 每台设备同一时间只允许一个通道持有 relay 配对（评审证实的硬约束：
/// 同一 device_sid 的两个终端会被桌面端踢掉第二个）。
///
/// 增强层模式（[nativeChannelProvider] 开启）下的仲裁规则：
/// - 非活动设备的 OfficialRemotePage 不挂载 → 原生桥持有配对，经
///   `_ingestNativePayload` 喂 session_index / 事件流 / 通知门控；
/// - 活动设备的页面挂载 → 原生桥让位断开，由页面自己完成配对；
/// - 设备删除 → 走 [RelaySourceNotifier.forget] 全量清理；
/// - 开关关闭 → 不持有任何桥，行为与历史版本一致。
///
/// 生命周期跟随 AppShell（autoDispose）：生物识别锁定卸载 AppShell 时
/// 整体断开，与 main.dart 的安全姿态（锁定下不得有 relay 连接）一致。
class DeviceRelayCoordinator extends Notifier<void> {
  final Set<String> _held = {};
  bool _reconcileScheduled = false;
  RelaySourceNotifier? _source;

  @override
  void build() {
    _source = ref.read(relaySourceProvider.notifier);
    ref.onDispose(_teardown);
    ref.listen(deviceListProvider, (_, _) => _scheduleReconcile());
    ref.listen(activeTabProvider, (_, _) => _scheduleReconcile());
    ref.listen(nativeChannelProvider, (_, _) => _scheduleReconcile());
    // 构建期只注册监听；连接会修改其他 provider 的状态，必须等本
    // provider 构建完成后（微任务）再执行，否则触发 Riverpod 断言。
    _scheduleReconcile();
  }

  void _scheduleReconcile() {
    if (_reconcileScheduled) return;
    _reconcileScheduled = true;
    scheduleMicrotask(() {
      _reconcileScheduled = false;
      _reconcile();
    });
  }

  void _reconcile() {
    final source = _source;
    if (source == null) return;
    final enabled = ref.read(nativeChannelProvider);
    final devices = ref.read(deviceListProvider);
    final active = ref.read(activeTabProvider);
    final activeId =
        active >= 0 && active < devices.length ? devices[active].id : null;

    // 已删除的设备：全量 forget（对齐 webview_sync.forget 的清理范围）。
    final ids = devices.map((d) => d.id).toSet();
    for (final id in _held.where((h) => !ids.contains(h)).toList()) {
      _release(id, forget: true);
    }

    if (!enabled) {
      for (final id in _held.toList()) {
        _release(id);
      }
      return;
    }

    for (final device in devices) {
      final want = device.id != activeId && RelaySourceNotifier.supports(device);
      if (want) {
        if (_held.add(device.id)) {
          unawaited(
            source.connect(device).catchError((e, st) {
              debugPrint('[ZR] 协调器 connect 失败: $e');
            }),
          );
        }
      } else {
        _release(device.id);
      }
    }
  }

  void _release(String deviceId, {bool forget = false}) {
    if (!_held.remove(deviceId)) return;
    final source = _source;
    if (source == null) return;
    unawaited(
      forget
          ? source.forget(deviceId).catchError((_) {})
          : source.disconnect(deviceId).catchError((_) {}),
    );
  }

  void _teardown() {
    final source = _source;
    if (source == null) return;
    for (final id in _held.toList()) {
      _held.remove(id);
      unawaited(source.disconnect(id).catchError((_) {}));
    }
  }
}

final deviceRelayCoordinatorProvider =
    NotifierProvider.autoDispose<DeviceRelayCoordinator, void>(
      DeviceRelayCoordinator.new,
    );

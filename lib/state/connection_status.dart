import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device.dart';
import '../models/device_label.dart';
import '../relay/relay_monitor.dart';
import '../services/keepalive.dart';
import '../services/notifier.dart';
import 'session_pool.dart';

/// 连接状态聚合（v1.3.0，仿 DeepSeek-Harness 的"连接状态"类别）。
///
/// 一台设备两条可能的事件来源：
/// * **WebView 页面**的 relay WebSocket（zrWs open/closed 事件 + 数据帧）；
/// * **原生监控通道**（[RelayMonitorConnection]，v1.3.0 起常驻）。
///
/// 任何一条来源有生命迹象（socket 打开、收到数据、配对成功）设备就算
/// **在线**；两条都沉寂超过 [ConnectionPolicy.grace] 才算**断连**——
/// 页面自动重连的间隙、监控通道的退避重连都不会误报。断连/恢复各发一条
/// IMPORTANCE_LOW 的系统通知（zr_conn_v8），并同步常驻通知文案。
enum LinkSignal { webview, monitor }

/// 每台设备的来源踪迹。
class DeviceLinkTrack {
  DeviceLinkTrack();

  bool webviewOpen = false;
  bool monitorPaired = false;
  DateTime? lastAliveAt;
}

/// 纯判定策略（可单测）。
abstract final class ConnectionPolicy {
  /// 双源沉寂多久判断连。页面心跳约 5s、监控心跳同量级，45s 足以吸收
  /// 一次重连抖动 + 一个轮询周期。
  static const grace = Duration(seconds: 45);

  /// true = 设备在线。
  static bool isLive({
    required bool webviewOpen,
    required bool monitorPaired,
    required DateTime? lastAliveAt,
    required DateTime now,
  }) {
    if (webviewOpen || monitorPaired) return true;
    final at = lastAliveAt;
    if (at == null) return false;
    return now.difference(at) < grace;
  }
}

class ConnectionStatusNotifier extends Notifier<Map<String, DeviceLinkTrack>> {
  final _notifiedDown = <String>{};
  final _lastLive = <String, bool>{};
  Timer? _evaluator;

  @override
  Map<String, DeviceLinkTrack> build() {
    // 定期评估迁移（断连不是事件而是"持续沉寂"，必须靠时钟发现）。
    _evaluator?.cancel();
    _evaluator = Timer.periodic(const Duration(seconds: 15), (_) => _evaluate());
    ref.onDispose(() {
      _evaluator?.cancel();
      _evaluator = null;
    });
    return {};
  }

  // ---- 信号入口 ----

  /// 收到任何生命迹象（数据帧 / 快照 / socket 活动）。
  void markAlive(String deviceId, LinkSignal signal) {
    final track = _track(deviceId);
    track.lastAliveAt = DateTime.now();
    if (signal == LinkSignal.monitor && !track.monitorPaired) {
      // 数据帧本身就是配对成立的证据（只有 paired 状态才会拉快照）。
      track.monitorPaired = true;
    }
    state = Map.of(state);
  }

  /// WebView relay socket 的开/关（zrWs 事件）。
  void reportWebview(String deviceId, {required bool open}) {
    final track = _track(deviceId);
    track.webviewOpen = open;
    if (open) track.lastAliveAt = DateTime.now();
    state = Map.of(state);
  }

  /// 原生监控通道状态迁移。
  void reportMonitor(String deviceId, RelayMonitorState monitorState) {
    final track = _track(deviceId);
    switch (monitorState) {
      case RelayMonitorState.paired:
        track.monitorPaired = true;
        track.lastAliveAt = DateTime.now();
      case RelayMonitorState.waiting:
      case RelayMonitorState.authenticating:
      case RelayMonitorState.connecting:
        track.monitorPaired = false;
      case RelayMonitorState.disconnected:
      case RelayMonitorState.idle:
        track.monitorPaired = false;
    }
    state = Map.of(state);
  }

  /// 设备被删除：清掉踪迹与提醒状态。
  void forget(String deviceId) {
    if (!state.containsKey(deviceId)) return;
    state = Map.of(state)..remove(deviceId);
    _notifiedDown.remove(deviceId);
    _lastLive.remove(deviceId);
  }

  /// 监控通道被拆除（设备删除/失去 sid），只清 monitor 侧标记。
  void forgetMonitor(String deviceId) {
    final track = state[deviceId];
    if (track == null) return;
    track.monitorPaired = false;
    state = Map.of(state);
  }

  /// 诊断/常驻通知文案用：设备当前是否在线。
  bool isLive(String deviceId) {
    final track = state[deviceId];
    if (track == null) return false;
    return ConnectionPolicy.isLive(
      webviewOpen: track.webviewOpen,
      monitorPaired: track.monitorPaired,
      lastAliveAt: track.lastAliveAt,
      now: DateTime.now(),
    );
  }

  /// 常驻通知文案用：null = 还没有任何信号（保持乐观的"已连接"展示，
  /// 避免启动瞬间闪"断开"）。
  bool? liveState(String deviceId) {
    final track = state[deviceId];
    if (track == null) return null;
    return ConnectionPolicy.isLive(
      webviewOpen: track.webviewOpen,
      monitorPaired: track.monitorPaired,
      lastAliveAt: track.lastAliveAt,
      now: DateTime.now(),
    );
  }

  DeviceLinkTrack _track(String deviceId) {
    final existing = state[deviceId];
    if (existing != null) return existing;
    final track = DeviceLinkTrack();
    // build() 返回的是 const 空表：首条踪迹必须走不可变更新，不能原地写。
    state = {...state, deviceId: track};
    return track;
  }

  // ---- 迁移评估与通知 ----

  void _evaluate() {
    final devices = {for (final d in ref.read(deviceListProvider)) d.id: d};
    // 已删除设备的踪迹顺手清掉。
    for (final id in state.keys.toSet()) {
      if (!devices.containsKey(id)) forget(id);
    }
    final now = DateTime.now();
    for (final entry in devices.entries) {
      final track = state[entry.key];
      final live = track != null &&
          ConnectionPolicy.isLive(
            webviewOpen: track.webviewOpen,
            monitorPaired: track.monitorPaired,
            lastAliveAt: track.lastAliveAt,
            now: now,
          );
      final previous = _lastLive[entry.key];
      _lastLive[entry.key] = live;
      if (previous == null || previous == live) continue;
      if (!live) {
        _notifiedDown.add(entry.key);
        _announce(entry.value, false);
      } else if (_notifiedDown.remove(entry.key)) {
        // 只在"播报过断连"之后才播报恢复，避免启动期抖动刷屏。
        _announce(entry.value, true);
      }
    }
  }

  void _announce(RemoteDevice device, bool connected) {
    unawaited(NotifierService.instance.showConnection(device: device, connected: connected));
    _syncKeepAliveText(device, connected);
  }

  /// 常驻通知文案跟随当前设备（远程 / 已连接到 X / 连接已断开）。
  void _syncKeepAliveText(RemoteDevice device, bool connected) {
    final active = ref.read(activeTabProvider);
    final devices = ref.read(deviceListProvider);
    if (active < 0 || active >= devices.length) return;
    if (devices[active].id != device.id) return;
    unawaited(
      MonitorKeepAlive.updateStatus(
        deviceName: device.displayName(l10nZh),
        connected: connected,
      ),
    );
  }
}

final connectionStatusProvider =
    NotifierProvider<ConnectionStatusNotifier, Map<String, DeviceLinkTrack>>(
      ConnectionStatusNotifier.new,
    );

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

  /// 主动让路中（v1.7.2）：页面与监控在做槽位交接，或监控被踢后按设计
  /// 退避。这段时间**不是故障**——不计入断连判定，也不发断连通知，
  /// 否则用户会看到一串假的"连接已断开"（v1.7.1 用户实测）。
  bool handoff = false;

  /// 豁免起点。豁免有上限（[ConnectionPolicy.handoffCap]）：如果另一台
  /// 设备长期占着槽位、或电脑其实已经关机，不能永远装作在线。
  DateTime? handoffSince;

  /// 当前是否仍在豁免窗口内。
  bool handoffActiveAt(DateTime now) {
    if (!handoff) return false;
    final since = handoffSince;
    if (since == null) return true;
    return now.difference(since) < ConnectionPolicy.handoffCap;
  }
}

/// 纯判定策略（可单测）。
abstract final class ConnectionPolicy {
  /// 双源沉寂多久判断连。页面心跳约 5s、监控心跳同量级，45s 足以吸收
  /// 一次重连抖动 + 一个轮询周期。
  static const grace = Duration(seconds: 45);

  /// 交接豁免的时长上限：足够覆盖一次前后台切换 + 让路退避（20s 起，
  /// 指数退避到 120s），但不能无限期——否则另一台手机长期占槽位时，
  /// 本机永远不会报告"电脑离线"。
  static const handoffCap = Duration(minutes: 3);

  /// true = 设备在线。交接/让路期一律视为在线（见 [DeviceLinkTrack.handoff]）。
  static bool isLive({
    required bool webviewOpen,
    required bool monitorPaired,
    required DateTime? lastAliveAt,
    required DateTime now,
    bool handoff = false,
  }) {
    if (webviewOpen || monitorPaired) return true;
    if (handoff) return true;
    final at = lastAliveAt;
    if (at == null) return false;
    return now.difference(at) < grace;
  }
}

class ConnectionStatusNotifier extends Notifier<Map<String, DeviceLinkTrack>> {
  /// 断连/恢复的系统通知只由**头无监控引擎**发出（v1.3.1，进程级唯一）
  /// ——UI 引擎在后台同样在跑评估器，两边都发会双响；且 UI 引擎看不到
  /// 原生监控的状态，单独判断会误报。默认关闭，monitorMain 里打开。
  static bool emitSystemNotifications = false;

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
        track.handoff = false;
        track.handoffSince = null;
      case RelayMonitorState.waiting:
      case RelayMonitorState.authenticating:
      case RelayMonitorState.connecting:
      case RelayMonitorState.authMissing:
        track.monitorPaired = false;
      case RelayMonitorState.yielded:
        // 让路是设计行为（另一终端正持有槽位），不是断线——静默它，
        // 否则每次切前后台都会弹一条假断连。
        track.monitorPaired = false;
        track.handoff = true;
        track.handoffSince ??= DateTime.now();
      case RelayMonitorState.disconnected:
      case RelayMonitorState.idle:
        track.monitorPaired = false;
    }
    state = Map.of(state);
  }

  /// 页面与监控的槽位交接（v1.7.2）：交接窗口内同样不算断连。
  void reportHandoff(String deviceId, {required bool active}) {
    final track = _track(deviceId);
    if (track.handoff == active) return;
    track.handoff = active;
    track.handoffSince = active ? DateTime.now() : null;
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
      handoff: track.handoffActiveAt(DateTime.now()),
    );
  }

  /// 常驻通知文案用。v1.6.2 去乐观化：无任何信号 ≠ 在线——令牌过期时
  /// 页面与监控同时静默，乐观展示会掩盖"其实已经死了"的事实。返回
  /// null（完全无踪迹，比如刚启动）仍按在线处理避免闪断；有踪迹但
  /// 沉寂超宽限则如实报告离线。
  bool? liveState(String deviceId) {
    final track = state[deviceId];
    if (track == null) return null;
    final hasAnySignal =
        track.webviewOpen || track.monitorPaired || track.lastAliveAt != null;
    if (!hasAnySignal) return null;
    return ConnectionPolicy.isLive(
      webviewOpen: track.webviewOpen,
      monitorPaired: track.monitorPaired,
      lastAliveAt: track.lastAliveAt,
      now: DateTime.now(),
      handoff: track.handoffActiveAt(DateTime.now()),
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
            handoff: track.handoffActiveAt(now),
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
    if (emitSystemNotifications) {
      unawaited(
        NotifierService.instance.showConnection(device: device, connected: connected),
      );
    }
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

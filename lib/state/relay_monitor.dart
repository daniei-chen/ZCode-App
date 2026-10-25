import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device.dart';
import '../relay/relay_monitor.dart';
import '../services/app_log.dart';
import '../services/device_store.dart';
import '../services/event_observer.dart';
import '../services/monitor_state_store.dart';
import '../services/notifier.dart';
import '../services/relay_credentials.dart';
import '../services/structured_log.dart';
import 'active_session.dart';
import 'app_lifecycle.dart';
import 'connection_status.dart';
import 'event_feed.dart';
import 'notification_prefs.dart';
import 'session_index.dart';
import 'session_pool.dart';

/// 原生监控通道服务（v1.3.0）。
///
/// 每台有 sid 的设备维护一条 [RelayMonitorConnection]，绕过 WebView 直连
/// 中继拉任务快照。目的只有一个：**WebView 不在时（进程被杀后重启、页面
/// 加载失败、后台被冻结）完成/失败事件仍然有第二条来源**——这是"24 小时
/// 都能收到通知"的兜底链路。
///
/// 事件判定与 WebView 路径共用同一套提取器/差分器/闸门（[StateDiffer]、
/// [EventDedupeGate]、[NotificationGate]），并读取同一批共享状态
/// （可见设备、前台状态、活跃会话），因此两条来源对同一条事件的提醒
/// 决策一致；系统通知 id 也相同（stableId），极端重复也只是替换不堆叠。
class RelayMonitorNotifier extends Notifier<Map<String, RelayMonitorState>> {
  final _connections = <String, RelayMonitorConnection>{};
  final _differs = <String, StateDiffer>{};
  final _gates = <String, EventDedupeGate>{};
  bool _disposed = false;
  Timer? _reloadTimer;

  @override
  Map<String, RelayMonitorState> build() {
    ref.onDispose(() {
      _disposed = true;
      _reloadTimer?.cancel();
      for (final id in _connections.keys.toSet()) {
        _connections.remove(id)?.stop();
      }
      _differs.clear();
      _gates.clear();
    });
    ref.listen(deviceListProvider, (_, next) => _sync(next));
    _sync(ref.read(deviceListProvider));
    // 跨隔离体同步（v1.6.3）：UI 引擎增删设备写的是共享存储，本隔离体的
    // provider 实例不会收到通知——30s 周期重读存储，登录后新设备及时被
    // 监控（此前要重启 app 才生效）。
    _reloadTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (_disposed) return;
      try {
        final result = await DeviceStore.instance.loadAllWithStatus();
        if (_disposed || !result.unavailable) _sync(result.devices);
      } catch (_) {}
    });
    return const {};
  }

  void _sync(List<RemoteDevice> devices) {
    final wanted = {
      for (final device in devices)
        if (device.sid.isNotEmpty) device.id: device,
    };
    for (final id in _connections.keys.toSet()) {
      if (wanted.containsKey(id)) continue;
      _teardown(id);
    }
    for (final entry in wanted.entries) {
      _ensureConnection(entry.value);
    }
  }

  void _teardown(String deviceId) {
    _connections.remove(deviceId)?.stop();
    _differs.remove(deviceId);
    _gates.remove(deviceId);
    state = Map.of(state)..remove(deviceId);
    ref.read(connectionStatusProvider.notifier).forgetMonitor(deviceId);
    unawaited(MonitorStateStore.removeDevice(deviceId));
  }

  void _ensureConnection(RemoteDevice device) {
    if (_connections.containsKey(device.id)) return;
    final connection = RelayMonitorConnection(
      deviceId: device.id,
      deviceSid: device.sid,
      deviceMid: device.params['mid'] ?? '',
      appVersion: device.params['app_version'] ?? '3.16.3',
      tokenProvider: RelayCredentials.loadJwt,
      onState: _onMonitorState,
      onSnapshot: _onSnapshot,
    );
    _connections[device.id] = connection;
    _differs[device.id] = StateDiffer();
    _gates[device.id] = EventDedupeGate();
    unawaited(connection.start());
  }

  /// UI 前台时挂起（头无引擎协调，v1.3.1）：断开全部连接、停轮询，
  /// 事件与提醒完全交给 UI 引擎的 WebView 路径，避免双源重复。
  Future<void> suspend() async {
    for (final id in _connections.keys.toSet()) {
      await _connections.remove(id)?.stop();
    }
    _differs.clear();
    _gates.clear();
    state = const {};
    for (final id in ref.read(deviceListProvider).map((d) => d.id)) {
      ref.read(connectionStatusProvider.notifier).forgetMonitor(id);
    }
  }

  /// UI 离开后恢复：重新读设备表与 JWT（可能已轮换），重建全部连接。
  Future<void> resume() async {
    await suspend();
    _sync(ref.read(deviceListProvider));
  }

  void _onMonitorState(String deviceId, RelayMonitorState monitorState) {
    if (_disposed) return;
    state = Map.of(state)..[deviceId] = monitorState;
    if (monitorState == RelayMonitorState.paired) {
      // 诊断锚点：配对成功意味着 token/mid/握手全链路通（真机排障从这里查起）。
      AppLog.event(
        LogEvent.relayMonitorPaired,
        level: LogLevel.debug,
        fields: {LogField.device: deviceId},
      );
    }
    // 跨隔离体外存（v1.4.0）：UI 引擎的诊断页要能看到监控引擎的状态。
    unawaited(MonitorStateStore.writeDevice(deviceId, monitorState.name));
    ref
        .read(connectionStatusProvider.notifier)
        .reportMonitor(deviceId, monitorState);
  }

  void _onSnapshot(String deviceId, Map<dynamic, dynamic> result) {
    if (_disposed) return;
    ref
        .read(connectionStatusProvider.notifier)
        .markAlive(deviceId, LinkSignal.monitor);
    final devices = ref.read(deviceListProvider);
    final device = devices.where((d) => d.id == deviceId).firstOrNull;
    if (device == null) return;

    // workspace-list-response.result.tasks 与 WebView 侧
    // TaskIndexExtractor 认识的形状一致（docs/RELAY-PROTOCOL-VERIFIED.md §4）。
    final flat =
        TaskIndexExtractor.parseResultTasksRoot({'result': result}) ??
        const <SessionState>[];
    // 会话索引只做**字段级合并**：快照任务不带审批/输入计数，绝不能把
    // WebView 侧已经写入的 pendingInteraction 状态覆盖清零，否则会把
    // "等待审批"差分成"已解决"、提前撤掉审批通知。
    final merged = [
      for (final item in flat)
        _mergeFlat(
          ref.read(sessionIndexProvider)[deviceId]?[item.sessionId],
          item,
        ),
    ];
    ref.read(sessionIndexProvider.notifier).upsertTasks(deviceId, merged);

    // 首页工作台（v1.6.0）：跨隔离体写出本设备当前任务摘要，首页设备卡
    // 直接画"在干什么"。键用 sid（目录设备与导入设备同身份）。
    final sid = device.sid;
    if (sid.isNotEmpty) {
      unawaited(
        MonitorStateStore.writeSummary(sid, summaryOfTasks(merged)),
      );
    }

    final differ = _differs.putIfAbsent(deviceId, StateDiffer.new);
    final gate = _gates.putIfAbsent(deviceId, EventDedupeGate.new);
    // 快照是全量列表：差分前先对齐基线（终态出表即剪掉），避免长期增长。
    differ.pruneOnSnapshot(merged);
    final events = EventParser.dedupe(differ.apply(merged));
    if (events.isEmpty) return;

    final active = ref.read(activeTabProvider);
    final visibleDeviceId = active >= 0 && active < devices.length
        ? devices[active].id
        : null;
    final foreground =
        ref.read(appLifecycleProvider) == AppLifecycleState.resumed;
    final prefs = ref.read(notificationPrefsProvider);
    final feed = ref.read(eventFeedProvider.notifier);
    final index = ref.read(sessionIndexProvider);

    for (final event in events) {
      if (!gate.allow(event)) continue;
      final session = event.taskId == null ? null : index[deviceId]?[event.taskId];
      final enriched = event.copyWith(
        sessionTitle: event.sessionTitle ?? session?.title,
        summary: event.summary ?? session?.preview ?? session?.description,
      );
      if (enriched.type == 'resolved') {
        final taskId = enriched.taskId;
        if (taskId != null) {
          NotifierService.instance.cancelPending(device, taskId);
        }
        feed.ingest(deviceId, enriched);
        continue;
      }
      if (!prefs.enabled(enriched.type)) continue;
      feed.ingest(deviceId, enriched);
      final shouldNotify = NotificationGate.shouldNotify(
        appForeground: foreground,
        visibleDeviceId: visibleDeviceId,
        eventDeviceId: device.id,
        activeSessionId: ref.read(activeSessionProvider)[device.id],
        eventSessionId: enriched.taskId,
      );
      if (!shouldNotify) continue;
      unawaited(NotifierService.instance.notifyFrom(device, enriched));
    }
  }

  /// 快照扁平任务 + 已有完整状态 → 合并状态。
  ///
  /// 扁平字段（title/preview/phase/时间/工作区）以快照为准（来自服务端、
  /// 更新）；交互计数类字段（permissionCount/userInputCount/interactionKind/
  /// toolName/description/pinned）只在已有状态里存在，原样保留。
  static SessionState _mergeFlat(SessionState? prev, SessionState flat) {
    if (prev == null) return flat;
    return SessionState(
      sessionId: flat.sessionId,
      title: flat.title ?? prev.title,
      phase: flat.phase ?? prev.phase,
      sessionEnded: flat.sessionEnded ?? prev.sessionEnded,
      permissionCount: prev.permissionCount,
      userInputCount: prev.userInputCount,
      interactionKind: prev.interactionKind,
      toolName: prev.toolName,
      description: prev.description,
      preview: flat.preview ?? prev.preview,
      lastActivityAt: flat.lastActivityAt ?? prev.lastActivityAt,
      createdAt: flat.createdAt ?? prev.createdAt,
      workspace: flat.workspace ?? prev.workspace,
      workspacePath: flat.workspacePath ?? prev.workspacePath,
      pinned: prev.pinned,
    );
  }
}

/// 任务列表 → 首页摘要（纯函数，可单测）。
///
/// 优先级：等待审批/输入的任务 > 最近活跃的任务；phase 取
/// running/completed/error 三态；pending=true 时首页挂审批红点。
Map<String, Object?> summaryOfTasks(List<SessionState> tasks) {
  SessionState? pendingTask;
  int pendingAt = -1;
  SessionState? latest;
  int latestAt = -1;
  for (final task in tasks) {
    final at = task.lastActivityAt ?? task.createdAt ?? 0;
    if ((task.permissionCount > 0 || task.userInputCount > 0) && at > pendingAt) {
      pendingTask = task;
      pendingAt = at;
    }
    if (at > latestAt) {
      latest = task;
      latestAt = at;
    }
  }
  final chosen = pendingTask ?? latest;
  if (chosen == null) return const {};
  final phase = (pendingTask != null)
      ? 'pending'
      : switch (chosen.phase) {
          'error' => 'error',
          'completedSuccess' || 'completedInterrupted' => 'completed',
          _ => 'running',
        };
  final title = (chosen.title ?? chosen.description ?? chosen.preview ?? '')
      .trim();
  return {
    'title': title.length > 60 ? title.substring(0, 60) : title,
    'phase': phase,
    'pending': pendingTask != null,
    'tool': chosen.toolName ?? '',
    'updatedAt': DateTime.now().millisecondsSinceEpoch,
  };
}

final relayMonitorProvider =
    NotifierProvider<RelayMonitorNotifier, Map<String, RelayMonitorState>>(
      RelayMonitorNotifier.new,
    );

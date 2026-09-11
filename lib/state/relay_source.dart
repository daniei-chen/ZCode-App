import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device.dart';
import '../models/skill.dart';
import '../native/bootstrap/native_bootstrap_state.dart';
import '../relay/agent_rpc.dart';
import '../relay/command_receipt.dart';
import '../relay/service_call_result.dart';
import '../relay/relay_bridge.dart';
import '../relay/relay_channel.dart';
import '../relay/conversation_row.dart';
import '../relay/conversation_attachment.dart';
import '../relay/conversation_subscription.dart';
import '../relay/conversation_update.dart';
import '../relay/relay_link.dart';
import '../relay/relay_socket.dart';
import '../services/link_builder.dart';
import '../services/event_observer.dart';
import '../services/notifier.dart';
import 'active_session.dart';
import 'app_lifecycle.dart';
import 'event_feed.dart';
import 'notification_prefs.dart';
import 'panel_state.dart';
import 'session_index.dart';
import 'session_pool.dart';

/// 原生 relay 通道相对于某台设备的可用状态。
enum RelaySourceKind {
  /// 尚未尝试（或该设备不是 relay 远控设备）。
  idle,

  /// 该设备记录里没有 relay 凭证（例如上游 v3 的纯 WebView 设备）。
  unsupported,

  connecting,
  live,
  failed,
}

const Object _keepReason = Object();

class RelaySourceState {
  const RelaySourceState({
    this.kind = RelaySourceKind.idle,
    this.reason,
    this.taskCount = 0,
    this.lastSyncAt,
    this.workspaceKey,
    this.connectionEpoch = 0,
    this.agentPhase = AgentPhase.notStarted,
    this.agentFailure,
    this.autoRetrying = false,
  });

  final RelaySourceKind kind;

  /// 失败原因（`RelayFailure.reason`）。
  final String? reason;

  /// 最近一次快照的任务条数。
  final int taskCount;

  final int? lastSyncAt;

  final String? workspaceKey;

  /// 每次重建 bridge 递增。带旧 epoch 的结果必须丢弃。
  final int connectionEpoch;

  /// 会话层握手（hello → initialize）状态。传输层 live 不代表这一层就绪。
  final AgentPhase agentPhase;

  /// 握手失败的安全原因（`fault.*` 代码），不含 payload。
  final String? agentFailure;

  /// 传输失败但已排定自动退避重连（kind 仍为 failed，测试/上层兼容）。
  final bool autoRetrying;

  /// 传输层是否在供数。**不等于可发送**，见 [transport] / [agentReady]。
  bool get isLive => kind == RelaySourceKind.live;

  bool get agentReady => agentPhase == AgentPhase.ready;

  TransportPhase get transport => switch (kind) {
    RelaySourceKind.idle => TransportPhase.idle,
    RelaySourceKind.unsupported => TransportPhase.unsupported,
    RelaySourceKind.connecting => TransportPhase.connecting,
    RelaySourceKind.live => TransportPhase.relayReady,
    RelaySourceKind.failed =>
      autoRetrying ? TransportPhase.retrying : TransportPhase.failed,
  };

  WorkspacePhase get workspace {
    if (!isLive) return WorkspacePhase.unknown;
    final key = workspaceKey?.trim();
    if (key != null && key.isNotEmpty) return WorkspacePhase.ready;
    return lastSyncAt == null ? WorkspacePhase.loading : WorkspacePhase.empty;
  }

  /// 传输 + Agent + 工作区三层合成（会话订阅层由 conversation state 补上）。
  NativeBootstrapState get bootstrap => NativeBootstrapState(
    transport: transport,
    agent: agentPhase,
    workspace: workspace,
    connectionEpoch: connectionEpoch,
    lastSuccessAt: lastSyncAt,
    lastFailure: agentFailure != null
        ? NativeLayerFailure(
            layer: NativeLayer.agent,
            method: 'helloConversationV4',
            code: agentFailure,
          )
        : reason != null && kind == RelaySourceKind.failed
        ? NativeLayerFailure(layer: NativeLayer.transport, code: reason)
        : null,
  );

  RelaySourceState copyWith({
    RelaySourceKind? kind,
    Object? reason = _keepReason,
    int? taskCount,
    int? lastSyncAt,
    String? workspaceKey,
    int? connectionEpoch,
    AgentPhase? agentPhase,
    bool? autoRetrying,
    Object? agentFailure = _keepReason,
  }) => RelaySourceState(
    kind: kind ?? this.kind,
    taskCount: taskCount ?? this.taskCount,
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    workspaceKey: workspaceKey ?? this.workspaceKey,
    reason: identical(reason, _keepReason) ? this.reason : reason as String?,
    connectionEpoch: connectionEpoch ?? this.connectionEpoch,
    agentPhase: agentPhase ?? this.agentPhase,
    autoRetrying: autoRetrying ?? this.autoRetrying,
    agentFailure: identical(agentFailure, _keepReason)
        ? this.agentFailure
        : agentFailure as String?,
  );
}

/// 为每台设备维持一条原生 relay 通道，并把任务快照喂给 [sessionIndexProvider]。
///
/// 与 WebView 通道的关系：原生通道优先；WebView 只给不支持原生协议的
/// 旧链接兜底。这样同一份 remote/v4 凭证不会被两个页面同时占用。
class RelaySourceNotifier extends Notifier<Map<String, RelaySourceState>> {
  final Map<String, RelayBridge> _bridges = {};
  final Map<String, StreamSubscription<String>> _payloadSubscriptions = {};
  final Map<String, Timer> _refresh = {};
  final Map<String, Future<void>> _connecting = {};
  final Map<String, Timer> _retry = {};
  final Map<String, RemoteDevice> _devices = {};
  final Map<String, int> _retryAttempts = {};
  final Map<String, int> _connectGeneration = {};
  final Map<String, StateDiffer> _stateDiffers = {};
  final Map<String, String?> _activeSessionIds = {};

  /// 列表刷新间隔。列表不保证主动推送（实测安静时无推送），靠轮询保持新鲜。
  static const Duration refreshInterval = Duration(seconds: 20);

  /// 测试用：替换底层 socket。生产环境保持 null。
  @visibleForTesting
  static RelaySocketFactory? debugSocketFactory;

  @override
  Map<String, RelaySourceState> build() => const {};

  /// 建立一条 [RelayBridge]（拆出来便于测试注入）。
  @visibleForTesting
  static RelayBridge buildBridge(RelayLink link) =>
      RelayBridge(link: link, socketFactory: debugSocketFactory);

  void _set(String deviceId, RelaySourceState s) {
    state = {...state, deviceId: s};
  }

  /// 从设备记录解析 relay 链接；不是 relay 设备时返回 null。
  static RelayLink? linkOf(RemoteDevice device) {
    if (!LinkBuilder.isTrustedDevice(device)) return null;
    return RelayLink.from(baseUrl: device.baseUrl, params: device.params);
  }

  /// 该设备能否走原生通道（需要 deviceSid + passHash）。
  static bool supports(RemoteDevice device) {
    final link = linkOf(device);
    return link != null && link.canAuthenticate;
  }

  RelaySourceState stateOf(String deviceId) =>
      state[deviceId] ?? const RelaySourceState();

  /// Scope shared by desktop-native service calls.
  ///
  /// `workspacePath` alone is not enough for the 3.11.x host when the
  /// workspace was opened through an identity-scoped session.  Keep this in
  /// one place so model, usage and workbench reads cannot silently drift
  /// apart.
  Map<String, dynamic> workspaceScope({
    required String deviceId,
    required String workspacePath,
  }) => {
    'workspacePath': workspacePath,
    'workspaceIdentity': ?_bridges[deviceId]?.workspace?.identity,
  };

  /// 启动某台设备的原生通道（幂等）。
  ///
  /// 失败的 bridge 不会留在 `_bridges` 里阻塞后续重试；并发 connect
  /// 调用共享同一个 Future，避免同时建立两条底层连接。
  Future<void> connect(RemoteDevice device) {
    final id = device.id;
    final previous = _devices[id];
    final sameDevice =
        previous != null &&
        previous.baseUrl == device.baseUrl &&
        mapEquals(previous.params, device.params);
    _devices[id] = device;
    final pending = _connecting[id];
    final current = _bridges[id];
    final link = linkOf(device);
    if (link == null || !link.canAuthenticate) {
      if (current != null || pending != null) {
        return disconnect(id).then((_) {
          _set(id, const RelaySourceState(kind: RelaySourceKind.unsupported));
        });
      }
      _set(id, const RelaySourceState(kind: RelaySourceKind.unsupported));
      return Future<void>.value();
    }
    if (pending != null && sameDevice) return pending;
    if (current != null && current.isReady && sameDevice) {
      return Future<void>.value();
    }

    final generation = (_connectGeneration[id] ?? 0) + 1;
    _connectGeneration[id] = generation;
    final future = _connectInternal(
      device,
      link,
      generation: generation,
      stale: current,
    );
    _connecting[id] = future;
    return future.whenComplete(() {
      if (identical(_connecting[id], future)) _connecting.remove(id);
    });
  }

  Future<void> _connectInternal(
    RemoteDevice device,
    RelayLink link, {
    required int generation,
    RelayBridge? stale,
  }) async {
    final id = device.id;
    if (stale != null) {
      await _payloadSubscriptions.remove(id)?.cancel();
      _bridges.remove(id);
      await stale.stop().catchError((_) {});
      stale.dispose();
    }
    if (_connectGeneration[id] != generation) return;

    final bridge = buildBridge(link);
    _bridges[id] = bridge;
    _stateDiffers[id] = StateDiffer();
    _set(
      id,
      RelaySourceState(
        kind: RelaySourceKind.connecting,
        connectionEpoch: generation,
      ),
    );

    _payloadSubscriptions[id] = bridge.payloads.listen((body) {
      if (_connectGeneration[id] != generation ||
          _bridges[id] != bridge ||
          !state.containsKey(id)) {
        return;
      }
      _ingestNativePayload(id, body);
    });

    bridge.phases.listen((p) {
      if (_connectGeneration[id] != generation || !state.containsKey(id)) {
        return;
      }
      if (p == RelayPhase.failed) {
        // A transport failure invalidates the agent handshake too; the
        // next bridge must redo hello/initialize.
        _set(
          id,
          stateOf(id).copyWith(
            kind: RelaySourceKind.failed,
            agentPhase: AgentPhase.notStarted,
          ),
        );
      } else if (p == RelayPhase.ready &&
          stateOf(id).kind == RelaySourceKind.connecting) {
        _set(id, stateOf(id).copyWith(kind: RelaySourceKind.live));
      }
    });

    bridge.failures.listen((f) {
      if (_connectGeneration[id] != generation ||
          _bridges[id] != bridge ||
          !state.containsKey(id)) {
        return;
      }
      _set(
        id,
        stateOf(id).copyWith(
          kind: RelaySourceKind.failed,
          reason: f.reason,
          agentPhase: AgentPhase.notStarted,
        ),
      );
      if (!f.isTerminal) _scheduleRetry(id);
    });

    bridge.taskSnapshots.listen((tasks) {
      if (_connectGeneration[id] != generation || !state.containsKey(id)) {
        return;
      }
      // 与 WebView 侧走同一个索引层：原生列表是完整快照，直接整体替换。
      ref
          .read(sessionIndexProvider.notifier)
          .replaceTasks(id, tasks, preservePinned: true);
      _set(
        id,
        stateOf(id).copyWith(
          kind: RelaySourceKind.live,
          reason: null,
          taskCount: tasks.length,
          lastSyncAt: DateTime.now().millisecondsSinceEpoch,
          workspaceKey:
              bridge.workspace?.path ??
              bridge.workspace?.workspaceKey ??
              bridge.activeWorkspaceKey,
        ),
      );
    });

    try {
      await bridge.start();
    } catch (e) {
      if (_connectGeneration[id] == generation &&
          identical(_bridges[id], bridge)) {
        await _payloadSubscriptions.remove(id)?.cancel();
        _bridges.remove(id);
      }
      if (_connectGeneration[id] == generation && state.containsKey(id)) {
        _set(
          id,
          stateOf(
            id,
          ).copyWith(kind: RelaySourceKind.failed, reason: e.toString()),
        );
      }
      await bridge.stop().catchError((_) {});
      bridge.dispose();
      if (_connectGeneration[id] == generation) _scheduleRetry(id);
      return;
    }

    if (_connectGeneration[id] != generation ||
        !identical(_bridges[id], bridge)) {
      await bridge.stop().catchError((_) {});
      bridge.dispose();
      return;
    }
    _retryAttempts.remove(id);
    _retry.remove(id)?.cancel();

    // 引导完成后补一次状态：任务快照是在 `_loadWorkspaces` 期间就到的，
    // 那时工作区还没选定，workspaceKey 会是 null。
    _set(
      id,
      stateOf(id).copyWith(
        kind: RelaySourceKind.live,
        workspaceKey:
            bridge.workspace?.path ??
            bridge.workspace?.workspaceKey ??
            bridge.activeWorkspaceKey,
      ),
    );

    _refresh[id]?.cancel();
    _refresh[id] = Timer.periodic(refreshInterval, (_) {
      final b = _bridges[id];
      if (b == null) return;
      unawaited(b.refreshTasks());
    });

    // Bootstrap step 2: complete the agent handshake as part of connecting,
    // so the UI learns "connected but agent not ready" before the user tries
    // to send rather than after.
    await _handshakeAgent(id, bridge, generation);
  }

  /// Run (or reuse) the conversation-layer handshake and record its phase.
  Future<bool> _handshakeAgent(
    String id,
    RelayBridge bridge,
    int generation,
  ) async {
    if (bridge.conversationReady) {
      if (stateOf(id).agentPhase != AgentPhase.ready) {
        _set(id, stateOf(id).copyWith(agentPhase: AgentPhase.ready));
      }
      return true;
    }
    if (stateOf(id).agentPhase != AgentPhase.handshaking) {
      _set(
        id,
        stateOf(
          id,
        ).copyWith(agentPhase: AgentPhase.handshaking, agentFailure: null),
      );
    }
    final ok = await bridge.handshakeConversation();
    if (_connectGeneration[id] != generation ||
        !identical(_bridges[id], bridge) ||
        !state.containsKey(id)) {
      return false;
    }
    _set(
      id,
      stateOf(id).copyWith(
        agentPhase: ok ? AgentPhase.ready : AgentPhase.unavailable,
        agentFailure: ok
            ? null
            : (bridge.lastFaultReason ?? 'handshake_failed'),
      ),
    );
    return ok;
  }

  void _scheduleRetry(String deviceId) {
    if (_retry.containsKey(deviceId)) return;
    final device = _devices[deviceId];
    if (device == null || !supports(device)) return;
    // Surface the scheduled backoff instead of a bare "failed" (P1-3).
    if (state.containsKey(deviceId)) {
      _set(deviceId, stateOf(deviceId).copyWith(autoRetrying: true));
    }
    final attempt = _retryAttempts[deviceId] ?? 0;
    final cappedAttempt = attempt.clamp(0, 6).toInt();
    final seconds = 1 << cappedAttempt;
    _retryAttempts[deviceId] = (attempt + 1).clamp(0, 6).toInt();
    _retry[deviceId] = Timer(Duration(seconds: seconds), () {
      _retry.remove(deviceId);
      unawaited(connect(device));
    });
  }

  /// 重新连接（失败后手动重试）。
  Future<void> reconnect(RemoteDevice device) async {
    await disconnect(device.id);
    await connect(device);
  }

  Future<void> disconnect(String deviceId) async {
    _connectGeneration[deviceId] = (_connectGeneration[deviceId] ?? 0) + 1;
    _retry.remove(deviceId)?.cancel();
    _retryAttempts.remove(deviceId);
    _refresh.remove(deviceId)?.cancel();
    await _payloadSubscriptions.remove(deviceId)?.cancel();
    _stateDiffers.remove(deviceId);
    _activeSessionIds.remove(deviceId);
    final bridge = _bridges.remove(deviceId);
    await bridge?.stop();
    bridge?.dispose();
    if (state.containsKey(deviceId)) {
      // Carry the bumped epoch so listeners can tell this idle state apart
      // from the previous connection and drop anything still in flight.
      _set(
        deviceId,
        RelaySourceState(
          kind: RelaySourceKind.idle,
          connectionEpoch: _connectGeneration[deviceId] ?? 0,
        ),
      );
    }
  }

  /// Current connection epoch for [deviceId]; 0 before the first connect.
  int epochOf(String deviceId) => _connectGeneration[deviceId] ?? 0;

  /// 设备被移除时彻底清理（含 session_index 里的数据）。
  Future<void> forget(String deviceId) async {
    await disconnect(deviceId);
    _devices.remove(deviceId);
    ref.read(sessionIndexProvider.notifier).forget(deviceId);
    if (state.containsKey(deviceId)) {
      state = Map.of(state)..remove(deviceId);
    }
  }

  /// 诊断：当前原生通道数。
  int get liveCount => state.values.where((s) => s.isLive).length;

  /// 把原生 relay 的非帧事件送进已有的事件、面板和任务索引层。
  ///
  /// 这一步让支持原生 Relay 的设备不再依赖 SessionView 才能收到通知、
  /// 面板同步或会话状态变化；解析仍复用 WebView 路径的防御式提取器。
  void _ingestNativePayload(String deviceId, String body) {
    if (body.isEmpty || body.length > 512 * 1024) return;
    ref.read(panelDataProvider.notifier).ingest(deviceId, body);

    dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return;
    }

    final activeSession = ActiveSessionExtractor.parseRoot(root);
    if (activeSession != null) {
      _activeSessionIds[deviceId] = activeSession;
      ref.read(activeSessionProvider.notifier).report(deviceId, activeSession);
    }

    final states = SessionStateExtractor.parseRoot(root);
    final removed = [
      ...SessionStateExtractor.parseRemovedRoot(root),
      ...TaskIndexExtractor.parseRemovedRoot(root),
      ...TaskIndexExtractor.parseArchivedRoot(root),
    ];
    final index = ref.read(sessionIndexProvider.notifier);
    index.upsertAll(deviceId, states);
    index.removeSessions(deviceId, removed);
    final snapshotTasks = TaskIndexExtractor.parseSnapshotRoot(root);
    if (snapshotTasks != null) {
      index.replaceTasks(deviceId, snapshotTasks, preservePinned: true);
    } else {
      index.upsertTasks(deviceId, TaskIndexExtractor.parseRoot(root));
    }
    final resultTasks = TaskIndexExtractor.parseResultTasksRoot(root);
    if (resultTasks != null && resultTasks.isNotEmpty) {
      if (TaskIndexExtractor.isBootstrapResult(root)) {
        index.replaceTasks(deviceId, resultTasks, preservePinned: true);
      } else {
        index.upsertTasks(deviceId, resultTasks);
      }
    }

    final differ = _stateDiffers[deviceId] ??= StateDiffer();
    final events = EventParser.dedupe([
      // Direct parser events are limited to requests for user action. A
      // terminal notification must wait for the complete session state.
      ...EventParser.parseUserActionRoot(root),
      ...differ.apply(
        // Keep the native and WebView paths symmetrical: task-index deltas
        // are the update form used for sessions outside the active view.
        [...states, ...TaskIndexExtractor.parseRoot(root)],
        removed: removed,
      ),
    ]);
    if (events.isEmpty) return;

    final devices = ref.read(deviceListProvider);
    final active = ref.read(activeTabProvider);
    final visibleId = active < devices.length ? devices[active].id : null;
    final appForeground =
        ref.read(appLifecycleProvider) == AppLifecycleState.resumed;
    final prefs = ref.read(notificationPrefsProvider);
    final feed = ref.read(eventFeedProvider.notifier);
    final device = devices.where((d) => d.id == deviceId).firstOrNull;
    for (final event in events) {
      final session = event.taskId == null
          ? null
          : ref.read(sessionIndexProvider)[deviceId]?[event.taskId];
      final enriched = event.copyWith(
        sessionTitle: event.sessionTitle ?? session?.title,
        summary: event.summary ?? session?.preview ?? session?.description,
      );
      if (enriched.type == 'resolved') {
        final taskId = enriched.taskId;
        if (taskId != null && device != null) {
          unawaited(NotifierService.instance.cancelPending(device, taskId));
        }
        feed.ingest(deviceId, enriched);
        continue;
      }
      if (!prefs.enabled(enriched.type)) continue;
      // Keep the native notification center complete. NotificationGate only
      // controls whether the OS-level notification should also be shown.
      feed.ingest(deviceId, enriched);
      final notify = NotificationGate.shouldNotify(
        appForeground: appForeground,
        visibleDeviceId: visibleId,
        eventDeviceId: deviceId,
        activeSessionId: _activeSessionIds[deviceId],
        eventSessionId: enriched.taskId,
      );
      if (!notify) continue;
      if (device != null) {
        unawaited(NotifierService.instance.notifyFrom(device, enriched));
      }
    }
  }

  /// 取某台设备的桥（未连接返回 null）。
  RelayBridge? bridgeOf(String deviceId) => _bridges[deviceId];

  /// 确保会话层已握手（幂等），并把结果记入 [RelaySourceState.agentPhase]。
  ///
  /// 订阅/拉正文的前提。失败返回 false。
  Future<bool> ensureConversation(String deviceId) async {
    final bridge = _bridges[deviceId];
    if (bridge == null) return false;
    return _handshakeAgent(deviceId, bridge, _connectGeneration[deviceId] ?? 0);
  }

  /// 回应一次待处理交互（批准 / 拒绝 / 取消）。
  ///
  /// ⚠️ **写操作**：会真实改变桌面端状态。只应由用户在 UI 上明确触发。
  /// 返回是否已发出（false 表示该设备通道不可用）。
  Future<bool> resolveInteraction({
    required String deviceId,
    required String sessionId,
    required String interactionId,
    String? optionId,
    String? action,
  }) async {
    final bridge = _bridges[deviceId];
    if (bridge == null) return false;
    return bridge.resolveInteraction(
      sessionId: sessionId,
      interactionId: interactionId,
      optionId: optionId,
      action: action,
    );
  }

  /// 订阅一个会话的原生实时更新，并等待桌面端 ack。
  ///
  /// 返回 null 表示未订阅成功（通道不可用 / 握手未完成 / 桌面端未确认）。
  /// 调用方只有在拿到 ack 后才能把会话标为已订阅。
  Future<ConversationSubscriptionAck?> subscribeConversation({
    required String deviceId,
    required String workspacePath,
    required String sessionId,
  }) async {
    final bridge = _bridges[deviceId];
    if (bridge == null || !bridge.conversationReady) return null;
    return bridge.subscribeConversation(
      workspacePath: workspacePath,
      sessionId: sessionId,
    );
  }

  /// Last safe fault code reported by the bridge (e.g. `fault.method_not_found`).
  String? lastFaultReason(String deviceId) =>
      _bridges[deviceId]?.lastFaultReason;

  /// Last parsed command receipt for [deviceId]; carries `reasonCode` for UI.
  CommandReceipt? lastCommandReceipt(String deviceId) =>
      _bridges[deviceId]?.lastCommandReceipt;

  /// Return a refusal only when it belongs to this session. A bridge keeps
  /// the latest receipt for diagnostics, but it must not leak across
  /// conversation error banners.
  CommandReceipt? lastCommandReceiptFor(String deviceId, String sessionId) =>
      _bridges[deviceId]?.receiptFor(sessionId);

  Stream<ConversationUpdate>? conversationUpdates(String deviceId) =>
      _bridges[deviceId]?.conversationUpdates;

  /// 发送用户消息；明确由会话页的发送按钮触发，并等待桌面端回执。
  Future<bool> sendMessage({
    required String deviceId,
    required String sessionId,
    required String text,
    List<ConversationAttachment> attachments = const [],
    String? clientOperationId,
  }) async {
    final bridge = _bridges[deviceId];
    if (bridge == null) return false;
    return bridge.sendConversationMessage(
      sessionId: sessionId,
      text: text,
      attachments: attachments,
      commandId: clientOperationId,
    );
  }

  /// Read the desktop-native session snapshot used by the conversation
  /// controls.  This is a read-only service call; no local WebView state is
  /// substituted when the service is unavailable.
  Future<Object?> fetchConversationSnapshot({
    required String deviceId,
    required String workspacePath,
    required String sessionId,
  }) async {
    if (!await ensureConversation(deviceId)) return null;
    return callServiceExpectValue(deviceId, 'zcode-session', 'readSession', [
      {
        ...workspaceScope(deviceId: deviceId, workspacePath: workspacePath),
        'sessionId': sessionId,
        'runtimePolicy': 'existing-only',
        'messageLimit': 1,
      },
    ]);
  }

  /// Read the verified token usage snapshot for a native session.
  Future<Object?> fetchConversationUsage({
    required String deviceId,
    required String workspacePath,
    required String sessionId,
  }) => callServiceExpectValue(deviceId, 'zcode-agent', 'getTaskTokenUsage', [
    {
      ...workspaceScope(deviceId: deviceId, workspacePath: workspacePath),
      'sessionId': sessionId,
    },
  ]);

  /// Change model and thought level through the official v4 command schema.
  Future<bool> switchModelConfig({
    required String deviceId,
    required String sessionId,
    required String providerId,
    required String modelId,
    required String thoughtLevel,
  }) async {
    final bridge = _bridges[deviceId];
    if (bridge == null || !await ensureConversation(deviceId)) return false;
    return bridge.switchModelConfig(
      sessionId: sessionId,
      providerId: providerId,
      modelId: modelId,
      thoughtLevel: thoughtLevel,
    );
  }

  /// Create a session and submit its first input atomically on the desktop.
  Future<String?> createConversation({
    required String deviceId,
    required String workspacePath,
    required String text,
    String? providerId,
    String? modelId,
    String? thoughtLevel,
    String? clientOperationId,
  }) async {
    final bridge = _bridges[deviceId];
    if (bridge == null || !await ensureConversation(deviceId)) return null;
    // The operation id doubles as the v4 commandId so a retry after a lost
    // receipt is answered with `duplicate` instead of a second session.
    return bridge.createConversation(
      workspaceId: workspacePath,
      text: text,
      providerId: providerId,
      modelId: modelId,
      thoughtLevel: thoughtLevel,
      commandId: clientOperationId,
    );
  }

  /// 停止当前桌面执行。
  Future<bool> stopConversation({
    required String deviceId,
    required String sessionId,
  }) async {
    final bridge = _bridges[deviceId];
    if (bridge == null) return false;
    return bridge.stopConversation(sessionId);
  }

  /// 调用一个 zcode-agent 方法并等它的响应（返回原始 value）。
  ///
  /// 用于设置类面板（技能 / MCP / 钩子 …）。这些方法**不需要会话层握手**。
  Future<Map<String, dynamic>?> callAgentExpectResponse(
    String deviceId,
    String method, [
    List<Object?> args = const [],
  ]) async {
    return callServiceExpectResponse(deviceId, 'zcode-agent', method, args);
  }

  /// 调用任意原生 agent service，并保留失败原因（不再一律吞成 null）。
  ///
  /// [where] 缺省要求响应体是 Map；写方法应传入能识别自己回执形状的谓词。
  Future<ServiceCallResult> callService(
    String deviceId,
    String service,
    String method,
    List<Object?> args, {
    bool Function(AgentResponse response)? where,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final bridge = _bridges[deviceId];
    if (bridge == null) {
      return const ServiceCallResult.failure('bridge_unavailable');
    }
    try {
      final r = await bridge.requestServiceResponse(
        service,
        method,
        args,
        where: where ?? (response) => response.isError || response.value is Map,
        timeout: timeout,
      );
      if (r == null) return const ServiceCallResult.failure('timeout');
      if (r.isError) {
        return ServiceCallResult.failure(r.faultReason ?? 'fault.unknown');
      }
      final v = r.value;
      return ServiceCallResult.success(
        v is Map ? Map<String, dynamic>.from(v) : null,
      );
    } catch (e) {
      return ServiceCallResult.failure('exception:${e.runtimeType}');
    }
  }

  /// 调用一个已核验的写入型 service 方法。
  ///
  /// 少数桌面 service（例如 `skills.setEnabled`）成功时返回 `undefined`
  /// 而不是对象。普通读取调用不能接受这种响应，否则会把成功误判成超时；
  /// 这里仍然保留错误回执，只放宽成功值为空这一点。调用方必须已经有
  /// 明确的用户操作和已核对的参数 schema，不能把它当成通用写入逃逸口。
  Future<ServiceCallResult> callServiceAllowEmpty(
    String deviceId,
    String service,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final bridge = _bridges[deviceId];
    if (bridge == null) {
      return const ServiceCallResult.failure('bridge_unavailable');
    }
    try {
      final r = await bridge.requestServiceResponse(
        service,
        method,
        args,
        // The bridge queues service calls one at a time. This write method's
        // response is otherwise not self-describing when its value is null.
        where: (_) => true,
        timeout: timeout,
      );
      if (r == null) return const ServiceCallResult.failure('timeout');
      if (r.isError) {
        return ServiceCallResult.failure(r.faultReason ?? 'fault.unknown');
      }
      final v = r.value;
      return ServiceCallResult.success(
        v is Map ? Map<String, dynamic>.from(v) : null,
      );
    } catch (e) {
      return ServiceCallResult.failure('exception:${e.runtimeType}');
    }
  }

  /// `zcode-session.setModel` — change **only** the model (verified 2026-09-11).
  ///
  /// Args: `{workspacePath, sessionId, model:{providerId, modelId}}`.
  /// Result: `{sessionId, appliedModelRuntimeRevision, changed}`.
  Future<ServiceCallResult> applySessionModel({
    required String deviceId,
    required String workspacePath,
    required String sessionId,
    required String providerId,
    required String modelId,
    int? expectedRevision,
  }) async {
    if (!await ensureConversation(deviceId)) {
      return const ServiceCallResult.failure('agent_not_ready');
    }
    return callService(deviceId, 'zcode-session', 'setModel', [
      {
        ...workspaceScope(deviceId: deviceId, workspacePath: workspacePath),
        'sessionId': sessionId,
        'model': {'providerId': providerId, 'modelId': modelId},
        'expectedRevision': ?expectedRevision,
        'persistAsWorkspaceLastUsed': true,
      },
    ], where: _isApplyResult);
  }

  /// `zcode-session.setThoughtLevel` — change **only** the thought level.
  ///
  /// Args: `{workspacePath, sessionId, thoughtLevel, expectedRevision?}`.
  Future<ServiceCallResult> applySessionThoughtLevel({
    required String deviceId,
    required String workspacePath,
    required String sessionId,
    required String thoughtLevel,
    int? expectedRevision,
  }) async {
    if (!await ensureConversation(deviceId)) {
      return const ServiceCallResult.failure('agent_not_ready');
    }
    return callService(deviceId, 'zcode-session', 'setThoughtLevel', [
      {
        ...workspaceScope(deviceId: deviceId, workspacePath: workspacePath),
        'sessionId': sessionId,
        'thoughtLevel': thoughtLevel,
        'expectedRevision': ?expectedRevision,
        'persistAsWorkspaceLastUsed': true,
      },
    ], where: _isApplyResult);
  }

  /// Predicate for the verified apply result so a stray Map response (e.g.
  /// a late subscription frame) cannot be mistaken for it.
  static bool _isApplyResult(AgentResponse r) {
    if (r.isError) return true;
    final v = r.value;
    return v is Map && (v.containsKey('changed') || v.containsKey('sessionId'));
  }

  /// 调用任意原生 agent service。
  Future<Object?> callServiceExpectValue(
    String deviceId,
    String service,
    String method, [
    List<Object?> args = const [],
  ]) async {
    final bridge = _bridges[deviceId];
    if (bridge == null) return null;
    try {
      final r = await bridge.requestServiceResponse(
        service,
        method,
        args,
        where: (response) => response.isError || response.value != null,
      );
      if (r == null || r.isError) return null;
      return r.value;
    } catch (_) {
      return null;
    }
  }

  /// 调用任意原生 agent service，并将对象响应限制为 Map。
  Future<Map<String, dynamic>?> callServiceExpectResponse(
    String deviceId,
    String service,
    String method, [
    List<Object?> args = const [],
  ]) async {
    final bridge = _bridges[deviceId];
    if (bridge == null) return null;
    try {
      final r = await bridge.requestServiceResponse(
        service,
        method,
        args,
        // 普通 panel 方法的响应没有可靠的 requestId；single-flight 已经
        // 保证不会与另一条 agent 请求交叉，这里至少排除无响应体的噪声。
        where: (response) => response.isError || response.value is Map,
      );
      if (r == null || r.isError) return null;
      final v = r.value;
      return v is Map ? Map<String, dynamic>.from(v) : null;
    } catch (_) {
      return null;
    }
  }

  /// 拉某个工作区的技能列表。
  Future<List<SkillEntry>?> fetchSkills({
    required String deviceId,
    required String workspacePath,
  }) async {
    final args = [
      {
        ...workspaceScope(deviceId: deviceId, workspacePath: workspacePath),
        // The desktop skill store is provider-scoped.  Omitting this field
        // makes the mobile request look valid but returns no catalogue.
        'provider': 'glm',
      },
    ];
    final res =
        await callServiceExpectResponse(deviceId, 'skills', 'list', args) ??
        await callAgentExpectResponse(deviceId, 'listSkills', args);
    return res == null ? null : SkillEntry.parseResponse(res);
  }

  /// `skills.setEnabled` — verified from the desktop renderer bundle.
  ///
  /// Args: `{workspacePath, workspaceIdentity?, provider, scope?, skillId,
  /// enabled}`. Plugin/built-in skills remain read-only by design.
  Future<ServiceCallResult> setSkillEnabled({
    required String deviceId,
    required String workspacePath,
    required SkillEntry skill,
    required bool enabled,
  }) {
    if (skill.readOnly) {
      return Future.value(const ServiceCallResult.failure('read_only_source'));
    }
    final workspaceIdentity = _bridges[deviceId]?.workspace?.identity;
    final scope = switch (skill.source) {
      'user' || 'workspace' => skill.source,
      _ => null,
    };
    return callServiceAllowEmpty(deviceId, 'skills', 'setEnabled', [
      {
        'workspacePath': workspacePath,
        'workspaceIdentity': ?workspaceIdentity,
        'provider': 'glm',
        'scope': ?scope,
        'skillId': skill.id,
        'enabled': enabled,
      },
    ]);
  }

  /// 拉某个会话的正文行（含工具调用）。
  ///
  /// [beforeRowId] 用于向上翻页：传当前最旧一行的 `rowId`。
  /// 失败或该设备不可用返回 null。
  Future<List<ConversationRow>?> fetchRows({
    required String deviceId,
    required String workspacePath,
    required String sessionId,
    int? beforeRowId,
    int limit = 200,
  }) async {
    final bridge = _bridges[deviceId];
    if (bridge == null) return null;
    if (!await ensureConversation(deviceId)) return null;

    try {
      final response = await bridge.requestAgentResponse(
        'conversationRowsRangeV4',
        [
          {
            ...workspaceScope(deviceId: deviceId, workspacePath: workspacePath),
            'sessionId': sessionId,
            'beforeRowId': ?beforeRowId,
            'limit': limit,
            'connectionId': ?bridge.conversationConnectionId,
            'clientMode': ?bridge.conversationClientMode,
          },
        ],
        where: (r) {
          if (r.isError) return true;
          final value = r.value;
          final rows = ConversationRow.parseResponse(value);
          // An explicit `rows: []` is a valid answer for an empty session;
          // only responses without a rows list are someone else's.
          final hasRowsList = value is Map && value['rows'] is List;
          if (rows == null || (rows.isEmpty && !hasRowsList)) return false;
          if (value is! Map) return true;
          final returnedSession =
              value['sessionId'] ?? value['taskId'] ?? value['conversationId'];
          final returnedWorkspace =
              value['workspacePath'] ??
              value['workspace'] ??
              value['workspaceKey'];
          if (returnedSession != null &&
              returnedSession.toString() != sessionId) {
            return false;
          }
          if (returnedWorkspace != null &&
              returnedWorkspace.toString() != workspacePath) {
            return false;
          }
          return true;
        },
      );
      if (response == null || response.isError) return null;
      return ConversationRow.parseResponse(response.value);
    } catch (_) {
      return null;
    }
  }
}

final relaySourceProvider =
    NotifierProvider<RelaySourceNotifier, Map<String, RelaySourceState>>(
      RelaySourceNotifier.new,
    );

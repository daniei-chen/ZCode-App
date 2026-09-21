import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../state/active_session.dart';
import '../state/app_lifecycle.dart';
import '../state/event_feed.dart';
import '../state/event_history.dart';
import '../state/notification_prefs.dart';
import '../state/session_index.dart';
import '../state/session_pool.dart';
import '../state/session_status.dart';
import 'app_log.dart';
import 'bridge_message_pipeline.dart';
import 'event_observer.dart';
import 'notifier.dart';
import 'structured_log.dart';
import 'warmup.dart';

/// Keeps the official WebView as the source of truth while feeding the
/// app-owned cache and launch surfaces.
///
/// The WebView remains visible when the user opens a device. This helper only
/// listens to the already-loaded page; it never creates a second connection or
/// reimplements the private remote protocol.
class WebViewSyncController {
  WebViewSyncController({required this.device, required this.ref});

  final RemoteDevice device;
  final WidgetRef ref;

  final StateDiffer _stateDiffer = StateDiffer();

  /// 跨消息幂等（F12）：重连重放/同帧多通道不会重复提醒。
  final EventDedupeGate _dedupeGate = EventDedupeGate();
  String? _activeSessionId;

  void ingestMessage(String body, BuildContext context) {
    if (body.isEmpty || body.length > kMaxListenBytes) return;

    // 单次 decode：面板、状态、任务索引与事件提取共用同一 root（评审 A2）。
    final root = BridgeMessagePipeline.decode(body);
    if (root == null) return;

    try {
      _ingestRoot(root, context);
    } catch (e) {
      // 观察面数据来自页面内容。提取层已对数值做有限性/值域过滤，这里是
      // 最后一道兜底：任何未预见的解析/差分异常只丢本帧并留痕，不让一帧
      // 脏数据中断此后所有帧的观察（安全复审 P2）。
      // 节流：持续性故障下每帧都抛会刷穿日志环形缓冲，只记首次与每 50 次
      // 并附累计数，诊断页仍能定位首因与规模。
      _ingestDrops++;
      if (_ingestDrops == 1 || _ingestDrops % 50 == 0) {
        AppLog.failure(
          LogEvent.bridgeMessageDropped,
          e,
          fields: {
            LogField.reason: 'ingest_exception',
            LogField.count: _ingestDrops,
          },
        );
      }
    }
  }

  /// 兜底丢帧累计（见 [ingestMessage] 的节流说明）。
  int _ingestDrops = 0;

  void _ingestRoot(dynamic root, BuildContext context) {
    final frameStatus = RelayLedPolicy.onFrameRoot(root);
    if (frameStatus != null) {
      ref.read(sessionStatusProvider.notifier).report(device.id, frameStatus);
    }

    // 活动会话通道（iter16）：原先这里对每个 relay 帧跑一次
    // ActiveSessionExtractor.parseRoot（深度 6 的整树递归），再写
    // activeSessionProvider——但该 provider 没有任何生产消费方
    // （NotificationGate.shouldNotify 明确忽略 activeSessionId 参数），
    // 纯属观测热路径开销。整树扫描已移除；`_activeSessionId` 仅由
    // 轻量的 zrViewState 通道维护，供门禁参数（当前被忽略）使用。
    final states = SessionStateExtractor.parseRoot(root);
    final removedResult = BridgeMessagePipeline.parseRemoved(root);
    final removed = [
      ...removedResult.sessions,
      ...removedResult.tasks,
      ...removedResult.archived,
    ];
    final index = ref.read(sessionIndexProvider.notifier);
    index.upsertAll(device.id, states);
    index.removeSessions(device.id, removed);

    final taskIndex = TaskIndexExtractor.parseRoot(root);
    final snapshotTasks = TaskIndexExtractor.parseSnapshotRoot(root);
    if (snapshotTasks != null) {
      _stateDiffer.pruneOnSnapshot(snapshotTasks);
      index.replaceTasks(device.id, snapshotTasks, preservePinned: true);
    } else {
      index.upsertTasks(device.id, taskIndex);
    }

    final resultTasks = TaskIndexExtractor.parseResultTasksRoot(root);
    if (resultTasks != null && resultTasks.isNotEmpty) {
      if (TaskIndexExtractor.isBootstrapResult(root)) {
        index.replaceTasks(device.id, resultTasks, preservePinned: true);
      } else {
        index.upsertTasks(device.id, resultTasks);
      }
    }

    final events = EventParser.dedupe([
      // Only explicit user-action requests are safe to consume directly.
      // Completion/failure notifications come from StateDiffer below, where
      // the whole session has entered a terminal state.
      ...EventParser.parseUserActionRoot(root),
      // The official page can publish a flat task delta for sessions that are
      // not currently open. Include that form in the same state differ so a
      // completion/approval in any conversation is monitored, not just the
      // conversation rendered on screen.
      ..._stateDiffer.apply([...states, ...taskIndex], removed: removed),
    ]);
    if (events.isEmpty) return;

    final devices = ref.read(deviceListProvider);
    final active = ref.read(activeTabProvider);
    final visibleDeviceId = active < devices.length ? devices[active].id : null;
    final foreground =
        ref.read(appLifecycleProvider) == AppLifecycleState.resumed;
    final prefs = ref.read(notificationPrefsProvider);
    final feed = ref.read(eventFeedProvider.notifier);
    final history = ref.read(eventHistoryProvider.notifier);

    for (final event in events) {
      // 跨消息幂等（F12）：同一逻辑事件在窗口内重复到达只提醒一次；
      // resolved 会清掉该任务的历史键，保证下一轮新请求照常提醒。
      if (!_dedupeGate.allow(event)) continue;
      final session = event.taskId == null
          ? null
          : ref.read(sessionIndexProvider)[device.id]?[event.taskId];
      final enriched = event.copyWith(
        sessionTitle: event.sessionTitle ?? session?.title,
        summary: event.summary ?? session?.preview ?? session?.description,
      );
      if (enriched.type == 'resolved') {
        final taskId = enriched.taskId;
        // R-19：resolved 只证明"有一项解决了"。该任务还有剩余交互
        // （计数>0）时保留系统通知——撤掉可能撤的是没解决那条的提醒。
        // 缺计数按未知处理，维持旧行为（撤回）。
        if (taskId != null && (enriched.pendingTotal ?? 0) <= 0) {
          NotifierService.instance.cancelPending(device, taskId);
        }
        feed.ingest(device.id, enriched);
        history.record(device.id, enriched); // 待处理中心历史（resolved 也留痕）
        continue;
      }
      if (!prefs.enabled(enriched.type)) continue;

      // The in-app notification center must receive every enabled event,
      // including the session currently on screen. The gate below only
      // suppresses the duplicate system notification in that case.
      feed.ingest(device.id, enriched);
      history.record(device.id, enriched); // 待处理中心历史（与 feed 同一收口）

      final shouldNotify = NotificationGate.shouldNotify(
        appForeground: foreground,
        visibleDeviceId: visibleDeviceId,
        eventDeviceId: device.id,
        activeSessionId: _activeSessionId,
        eventSessionId: enriched.taskId,
      );
      if (!shouldNotify) continue;

      unawaited(
        NotifierService.instance.notifyFrom(
          device,
          enriched,
          l10n: AppLocalizations.of(context),
        ),
      );
    }
  }

  void ingestViewState(String body) {
    final result = MobileViewStateSync.parse(body);
    if (!result.valid) return;
    // 只维护本地字段（当前门禁参数被忽略），不再写 activeSessionProvider：
    // 该 provider 无生产消费方（iter16），保留写入只会多一条没人读的状态面。
    _activeSessionId = result.taskId;
  }

  void ingestWebSocketEvent(String body) {
    try {
      // 共享管线 decode（安全审计 S-2/N-1）：zrWs 与 zrEvents 同为 4 MiB
      // 预算，深度炸弹必须走同一道预扫，不能留下裸 jsonDecode 通道。
      final event = BridgeMessagePipeline.decode(body);
      if (event is Map<String, dynamic>) {
        final status = RelayLedPolicy.onWsEvent(event);
        if (status != null) {
          ref.read(sessionStatusProvider.notifier).report(device.id, status);
        }
      }
    } catch (_) {
      // The official page can emit non-JSON WebSocket diagnostics. They are
      // intentionally ignored rather than allowed to affect connection state.
    }
  }

  void ingestSeen(String body) {
    ref.read(warmupMemoryProvider.notifier).ingestSeen(device.id, body);
  }

  void forget() {
    ref.read(sessionStatusProvider.notifier).forget(device.id);
    ref.read(eventFeedProvider.notifier).forget(device.id);
    ref.read(eventHistoryProvider.notifier).forget(device.id);
    ref.read(sessionIndexProvider.notifier).forget(device.id);
    ref.read(activeSessionProvider.notifier).forget(device.id);
  }
}

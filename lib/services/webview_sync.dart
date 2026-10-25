import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../state/active_session.dart';
import '../state/app_lifecycle.dart';
import '../state/connection_status.dart';
import '../state/device_directory.dart';
import '../state/event_feed.dart';
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

    // 页面还在推数据 = relay 链路活着（连接状态聚合的生命迹象之一）。
    ref.read(connectionStatusProvider.notifier).markAlive(
          device.id,
          LinkSignal.webview,
        );

    final frameStatus = RelayLedPolicy.onFrameRoot(root);
    if (frameStatus != null) {
      ref.read(sessionStatusProvider.notifier).report(device.id, frameStatus);
    }

    final activeSession = ActiveSessionExtractor.parseRoot(root);
    if (activeSession != null) {
      _activeSessionId = activeSession;
      ref.read(activeSessionProvider.notifier).report(device.id, activeSession);
    }

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
      // V2 账号流：协议级失败信封（app-error / workspace-bridge-error），
      // 与 StateDiffer 的终态判断互不替代——信封是即时的、带原因的失败。
      ...EventParser.parseProtocolFailuresRoot(root),
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
        if (taskId != null) {
          NotifierService.instance.cancelPending(device, taskId);
        }
        feed.ingest(device.id, enriched);
        continue;
      }
      if (!prefs.enabled(enriched.type)) continue;

      // The in-app notification center must receive every enabled event,
      // including the session currently on screen. The gate below only
      // suppresses the duplicate system notification in that case.
      feed.ingest(device.id, enriched);

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
    _activeSessionId = result.taskId;
    ref.read(activeSessionProvider.notifier).report(device.id, result.taskId);
  }

  void ingestWebSocketEvent(String body) {
    try {
      final event = jsonDecode(body);
      if (event is Map<String, dynamic>) {
        final status = RelayLedPolicy.onWsEvent(event);
        if (status != null) {
          ref.read(sessionStatusProvider.notifier).report(device.id, status);
        }
        // 终态失败（含 invalid-mobile-connection=令牌失效被拒，v1.6.2）：
        // 页面不再重连，webview 侧信号清零——连接聚合据此如实转离线，
        // 目录的 401 链路随后发"登录已过期"通知。
        if (status == SessionStatus.error) {
          ref
              .read(connectionStatusProvider.notifier)
              .reportWebview(device.id, open: false);
          // 令牌类终态：主动触发一次目录刷新——401 证实后"登录已过期"
          // 通知与首页横幅随之出现，引导用户重登。
          final reason = '${event['r'] ?? ''}';
          if (reason.contains('invalid-mobile-connection') ||
              reason.contains('device-not-owned')) {
            unawaited(ref.read(deviceDirectoryProvider.notifier).refresh());
          }
        }
        // 连接状态聚合（v1.3.0）：页面 relay socket 的开/关是设备在线的
        // 直接信号；断连是否播报由聚合器的沉寂宽限判定，这里只上报事实。
        switch (event['s']) {
          case 'open':
            ref
                .read(connectionStatusProvider.notifier)
                .reportWebview(device.id, open: true);
          case 'closed':
            ref
                .read(connectionStatusProvider.notifier)
                .reportWebview(device.id, open: false);
          case 'ignored':
            // 被白名单忽略的 WS：pathname（无 query，脱敏安全）进日志，
            // 诊断包可判读"relay 实际连接路径 vs 白名单"。
            AppLog.event(
              LogEvent.webviewWsIgnored,
              level: LogLevel.warn,
              fields: {
                LogField.device: LogRedactor.shortId(device.id),
                LogField.route: event['p'] is String ? event['p'] as String : null,
              },
            );
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
    ref.read(sessionIndexProvider.notifier).forget(device.id);
    ref.read(activeSessionProvider.notifier).forget(device.id);
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../state/active_session.dart';
import '../state/app_lifecycle.dart';
import '../state/event_feed.dart';
import '../state/notification_prefs.dart';
import '../state/session_index.dart';
import '../state/session_pool.dart';
import '../state/session_status.dart';
import 'bridge_message_pipeline.dart';
import 'event_observer.dart';
import 'notifier.dart';
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
  String? _activeSessionId;

  void ingestMessage(String body, BuildContext context) {
    if (body.isEmpty || body.length > kMaxListenBytes) return;

    // 单次 decode：面板、状态、任务索引与事件提取共用同一 root（评审 A2）。
    final root = BridgeMessagePipeline.decode(body);
    if (root == null) return;

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

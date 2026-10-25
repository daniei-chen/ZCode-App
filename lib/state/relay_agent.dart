import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/device.dart';
import '../relay/agent_channel.dart';
import '../relay/agent_rpc.dart';
import '../services/device_store.dart';
import '../services/event_observer.dart';
import '../services/notifier.dart';
import '../services/monitor_state_store.dart';
import '../services/relay_credentials.dart';
import 'event_feed.dart';
import 'notification_prefs.dart';
import 'session_index.dart';
import 'session_pool.dart';

/// 头无引擎的 agent 状态层（v1.4.0）：每设备一条命令通道。
///
/// 事件流：订阅推送（会话索引 + 按需订阅的会话快照）经防御性提取器拆出
/// 审批/输入请求（带 interactionId 与 options）→ 系统通知挂"允许/拒绝/
/// 回复"按钮。完成/失败仍由监控连接的快照差分负责（职责不重复）。
class RelayAgentNotifier extends Notifier<Map<String, bool>> {
  final _channels = <String, RelayAgentChannel>{};
  final _sids = <String, String>{};
  final _seenInteractions = <String>{};
  final _optionWaiters = <String, Timer>{};
  bool _disposed = false;

  @override
  Map<String, bool> build() {
    ref.onDispose(() {
      _disposed = true;
      for (final channel in _channels.values) {
        unawaited(channel.stop());
      }
      _channels.clear();
      for (final timer in _optionWaiters.values) {
        timer.cancel();
      }
      _optionWaiters.clear();
    });
    ref.listen(deviceListProvider, (_, next) => _sync(next));
    _sync(ref.read(deviceListProvider));
    return const {};
  }

  void _sync(List<RemoteDevice> devices) {
    final wanted = {
      for (final d in devices)
        if (d.sid.isNotEmpty) d.id: d,
    };
    // sid 表（v1.6.0）：通道就绪态按 sid 写入共享存储，诊断/体检可见。
    _sids
      ..clear()
      ..addAll({
        for (final d in wanted.values) d.id: d.sid,
      });
    for (final id in _channels.keys.toSet()) {
      if (!wanted.containsKey(id)) {
        unawaited(_channels.remove(id)?.stop());
        state = Map.of(state)..remove(id);
      }
    }
    for (final device in wanted.values) {
      if (_channels.containsKey(device.id)) continue;
      final channel = RelayAgentChannel(
        deviceId: device.id,
        deviceSid: device.sid,
        deviceMid: device.params['mid'] ?? '',
        appVersion: device.params['app_version'] ?? '3.16.3',
        tokenProvider: RelayCredentials.loadJwt,
        onEvent: (deviceId, event) => _onEvent(deviceId, event),
      );
      _channels[device.id] = channel;
      unawaited(
        channel.start().whenComplete(() {
          if (_disposed) return;
          state = Map.of(state)..[device.id] = channel.isReady;
          final sid = _sids[device.id];
          if (sid != null) {
            unawaited(MonitorStateStore.writeAgentReady(sid, channel.isReady));
          }
        }),
      );
    }
  }

  /// 命令入口（通知动作分发器调用）。通道未就绪时命令自然失败（false）。
  Future<bool> submitCommand(String deviceId, Map<String, Object?> envelope) =>
      _channels[deviceId]?.submitCommand(envelope) ?? Future.value(false);

  // ---- 事件提取（防御性：认字段不认信封）----

  void _onEvent(String deviceId, Map<dynamic, dynamic> event) {
    if (_disposed) return;
    _walkForPendingInteractions(deviceId, event);
  }

  void _walkForPendingInteractions(String deviceId, dynamic node, {int depth = 0}) {
    if (depth > 8 || node == null) return;
    if (node is Map) {
      final list = node['pendingInteractions'];
      if (list is List) {
        for (final item in list) {
          if (item is Map) _consumeInteraction(deviceId, item);
        }
      }
      final single = node['pendingInteraction'];
      if (single is Map) {
        _consumeInteraction(deviceId, {
          'interactionId': single['interactionId'],
          'payload': single['payload'] ?? single,
        });
      }
      for (final value in node.values) {
        _walkForPendingInteractions(deviceId, value, depth: depth + 1);
      }
    } else if (node is List) {
      for (final value in node) {
        _walkForPendingInteractions(deviceId, value, depth: depth + 1);
      }
    }
  }

  void _consumeInteraction(String deviceId, Map<dynamic, dynamic> item) {
    final interactionId = item['interactionId'];
    if (interactionId is! String || interactionId.isEmpty) return;
    if (!_seenInteractions.add(interactionId)) return;
    final payload = item['payload'];
    if (payload is! Map) return;
    final kind = '${payload['kind']}';
    final sessionId = _firstString(item, const ['sessionId', 'taskId']) ??
        _firstString(payload, const ['sessionId']);

    if (kind == 'permission' || kind == 'userInput') {
      final options = payload['options'];
      String? allow;
      String? deny;
      if (options is List) {
        for (final option in options) {
          if (option is! Map) continue;
          final optionId = option['optionId'];
          final optionKind = '${option['kind']}';
          if (optionId is! String || optionId.isEmpty) continue;
          if (allow == null &&
              (optionKind.contains('allow') || optionKind.contains('approve'))) {
            allow = optionId;
          }
          if (deny == null &&
              (optionKind.contains('reject') || optionKind.contains('deny'))) {
            deny = optionId;
          }
        }
      }
      _notifyInteraction(
        deviceId,
        kind == 'permission' ? 'permission_request' : 'elicitation_request',
        sessionId,
        interactionId,
        allow,
        deny,
        _firstString(payload, const ['summary', 'toolName', 'title']),
      );
    }
  }

  void _notifyInteraction(
    String deviceId,
    String type,
    String? sessionId,
    String interactionId,
    String? allow,
    String? deny,
    String? summary,
  ) {
    if (!ref.read(notificationPrefsProvider).enabled(type)) return;
    final devices = ref.read(deviceListProvider);
    final device = devices.where((d) => d.id == deviceId).firstOrNull;
    if (device == null) return;
    final session = sessionId == null
        ? null
        : ref.read(sessionIndexProvider)[deviceId]?[sessionId];
    ref.read(eventFeedProvider.notifier).ingest(
          deviceId,
          ObservedEvent(type: type, taskId: sessionId),
        );
    unawaited(
      NotifierService.instance.notifyFrom(
        device,
        ObservedEvent(
          type: type,
          taskId: sessionId,
          sessionTitle: session?.title,
          summary: summary ?? session?.preview,
          interactionId: interactionId,
          allowOptionId: allow,
          denyOptionId: deny,
        ),
      ),
    );
  }

  String? _firstString(Map<dynamic, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is String && value.isNotEmpty) return value;
    }
    return null;
  }
}

final relayAgentProvider = NotifierProvider<RelayAgentNotifier, Map<String, bool>>(
  RelayAgentNotifier.new,
);

// ---- 通知动作分发（插件的后台 isolate 回调，v1.4.0）----

/// 通知动作按钮（允许/拒绝/回复）的后台分发入口。由插件在独立 isolate 里
/// 调起——不复用任何引擎状态，自己搭一条一次性 agent 通道执行命令。
@pragma('vm:entry-point')
Future<void> notificationActionDispatcher(
  NotificationResponse response,
) async {
  final actionId = response.actionId ?? '';
  final payload = response.payload ?? '';
  if (payload.isEmpty) return;
  // 段序：deviceId|sessionId|interactionId|allowOptionId|denyOptionId
  final parts = payload.split('|');
  final deviceId = parts.isNotEmpty ? parts[0] : '';
  final sessionId = parts.length > 1 ? parts[1] : '';
  final interactionId = parts.length > 2 ? parts[2] : '';
  final allowOptionId = parts.length > 3 ? parts[3] : '';
  final denyOptionId = parts.length > 4 ? parts[4] : '';
  if (deviceId.isEmpty) return;

  final command = switch (actionId) {
    kAllowActionId when allowOptionId.isNotEmpty => _resolveCommand(
      sessionId: sessionId,
      interactionId: interactionId,
      answer: {'optionId': allowOptionId},
    ),
    kDenyActionId when denyOptionId.isNotEmpty => _resolveCommand(
      sessionId: sessionId,
      interactionId: interactionId,
      answer: {'optionId': denyOptionId},
    ),
    kReplyActionId when (response.input ?? '').trim().isNotEmpty =>
      _sendTextCommand(sessionId: sessionId, text: response.input!.trim()),
    _ => null,
  };
  if (command == null) return;
  await _runOneShotCommand(deviceId, command);
}

Map<String, Object?> _resolveCommand({
  required String sessionId,
  required String interactionId,
  required Map<String, Object?> answer,
}) => AgentWire.commandEnvelope(
  commandId: 'zr-${DateTime.now().millisecondsSinceEpoch}',
  clientId: 'zr-notif',
  type: 'resolveInteraction',
  sessionId: sessionId,
  payload: {'interactionId': interactionId, 'answer': answer},
);

Map<String, Object?> _sendTextCommand({
  required String sessionId,
  required String text,
}) => AgentWire.commandEnvelope(
  commandId: 'zr-${DateTime.now().millisecondsSinceEpoch}',
  clientId: 'zr-notif',
  type: 'sendText',
  sessionId: sessionId,
  payload: {'text': text},
);

/// 独立 isolate 里的一次性命令执行：直连 → 开桥 → 就绪 → 提交 → 关闭。
/// 预算 30s；任何一步失败静默返回（通知按钮没有重试 UI，命令本身在
/// 桌面端幂等（accepted/duplicate/noop 都算成功））。
Future<void> _runOneShotCommand(
  String deviceId,
  Map<String, Object?> envelope,
) async {
  try {
    final devices = await DeviceStore.instance.loadAll();
    final device = devices.where((d) => d.id == deviceId).firstOrNull;
    if (device == null || device.sid.isEmpty) return;
    final token = await RelayCredentials.loadJwt();
    if (token == null || token.isEmpty) return;
    final channel = RelayAgentChannel(
      deviceId: device.id,
      deviceSid: device.sid,
      deviceMid: device.params['mid'] ?? '',
      appVersion: device.params['app_version'] ?? '3.16.3',
      tokenProvider: () async => token,
      onEvent: (_, _) {},
    );
    unawaited(channel.start());
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!channel.isReady && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (channel.isReady) {
      await channel.submitCommand(envelope).timeout(
        const Duration(seconds: 15),
        onTimeout: () => false,
      );
    }
    await channel.stop();
  } catch (_) {
    // 一次性执行：失败即放弃（按钮可再点；命令在桌面端幂等）。
  }
}

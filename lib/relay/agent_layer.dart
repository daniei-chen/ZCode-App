import 'dart:async';
import 'dart:typed_data';

import 'agent_rpc.dart';

/// 挂在监控连接**同一条 socket** 上的 agent 能力层（v1.7.1）。
///
/// v1.4-v1.7.0 的 [RelayAgentChannel] 自持第二条常驻 WS——但官方中继是
/// "单控制端"语义（同一 device_sid 同时只允许一个终端，见
/// docs/RELAY-PROTOCOL-VERIFIED.md §12），两条常驻连接互相 KICK，还把
/// 用户正在看的会话页一起踢成"已被其他设备接管"。v1.7.1 起 agent 层
/// 不再自持连接：监控配对成功后在**同一条 socket** 上走
/// workspace-list → bridge-open → hello → initialize → 订阅链，
/// 快照与命令共用一条连接，app 内每设备永远只有一个终端。
///
/// 本类不拥有 socket：发帧走 [sendJson]（监控连接的发送口），入帧由
/// 监控连接分派给 [handleDataPayload]。断线/被踢时 [reset]，重连配对后
/// 由监控再次触发 [onPaired] 重新引导。
class RelayAgentLayer {
  RelayAgentLayer({
    required this.deviceId,
    required this.deviceSid,
    required this.appVersion,
    required this.sendJson,
    this.onEvent,
    this.onReady,
  });

  final String deviceId;
  final String deviceSid;
  final String appVersion;

  /// 监控连接的 JSON 发送口（同一条 socket）。
  final void Function(Map<String, Object?> message) sendJson;

  /// 订阅推送里提取的会话/交互事件（审批/输入请求等）。
  final void Function(String deviceId, Map<dynamic, dynamic> event)? onEvent;

  /// 就绪态变化（诊断页"命令通道"的数据源）。
  final void Function(String deviceId, bool ready)? onReady;

  bool _ready = false;
  String _workspaceKey = '';
  String _bridgeSessionId = '';
  final int _bridgeGeneration = 1;
  int _messageSeq = 0;
  int _requestSeq = 0;
  String _connectionId = '';
  late final String _clientId = 'zr-${deviceId.hashCode.toRadixString(36)}';
  final _pending = <_PendingCall>[];
  final _fragments = <String, List<Uint8List?>>{};
  final _fragmentTotal = <String, int>{};
  Completer<void>? _bootstrapping;

  bool get isReady => _ready;

  /// 监控配对成功（auth_ack matched）后调用：启动引导链。重复调用安全
  /// （同一连接只会引导一次；重连后监控会先 [reset]）。
  void onPaired() {
    if (_ready || _bootstrapping != null) return;
    final bootstrapping = Completer<void>();
    _bootstrapping = bootstrapping;
    unawaited(
      _bootstrap().whenComplete(() {
        if (identical(_bootstrapping, bootstrapping)) _bootstrapping = null;
        if (!bootstrapping.isCompleted) bootstrapping.complete();
      }),
    );
  }

  /// 断线/被踢/停止：清态、放行挂起调用。下次配对重新引导。
  void reset() {
    _ready = false;
    _workspaceKey = '';
    _bridgeSessionId = '';
    _connectionId = '';
    _fragments.clear();
    _fragmentTotal.clear();
    _bootstrapping = null;
    for (final pending in _pending) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(StateError('agent layer reset'));
      }
    }
    _pending.clear();
    _reportReady(false);
  }

  void _reportReady(bool ready) {
    if (_ready == ready) return;
    _ready = ready;
    try {
      onReady?.call(deviceId, ready);
    } catch (_) {}
  }

  // ---- 引导链（与 v1.4 RelayAgentChannel 逐帧对齐）----

  Future<void> _bootstrap() async {
    final workspace = await _requestWorkspaceList();
    if (workspace == null) return;
    final bridgeOk = await _openBridge(workspace);
    if (!bridgeOk) return;
    await _handshakeAgent(workspace);
  }

  Future<String?> _requestWorkspaceList() async {
    _requestSeq += 1;
    final requestId = 'agent-$_requestSeq';
    final completer = Completer<Map<dynamic, dynamic>?>();
    _pending.add(_PendingCall(
      match: (json) =>
          json is Map && json['requestId'] == requestId ? json : null,
      completer: completer,
    ));
    sendJson({
      'type': 'data',
      'payload': {
        'zcode_type': 'workspace-list-request',
        'requestId': requestId,
      },
      'client_ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
    final result = await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => null,
    ).catchError((_) => null);
    final key = result?['activeWorkspaceKey'];
    if (key is String && key.isNotEmpty) return key;
    return null;
  }

  Future<bool> _openBridge(String workspaceKey) async {
    _bridgeSessionId =
        'zrbridge-$_requestSeq-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    _requestSeq += 1;
    final requestId = 'agent-$_requestSeq';
    final completer = Completer<Map<dynamic, dynamic>?>();
    _pending.add(_PendingCall(
      match: (json) =>
          json is Map && json['requestId'] == requestId ? json : null,
      completer: completer,
    ));
    sendJson({
      'type': 'data',
      'payload': {
        'zcode_type': 'workspace-bridge-open',
        'requestId': requestId,
        'bridgeSessionId': _bridgeSessionId,
        'bridgeGeneration': _bridgeGeneration,
        'workspaceKey': workspaceKey,
      },
      'client_ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
    final ready = await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => null,
    ).catchError((_) => null);
    if (ready == null) return false;
    _workspaceKey = workspaceKey;
    return true;
  }

  Future<void> _handshakeAgent(String workspaceKey) async {
    final hello = await _rpcCall(
      service: 'zcode-agent',
      method: 'helloConversationV4',
      args: const [],
      match: (json) => json is Map && json['clientMode'] is String ? json : null,
    );
    if (hello is! Map) return;
    final clientMode = '${hello['clientMode']}';
    _connectionId = '${hello['connectionId'] ?? ''}';
    final init = await _rpcCall(
      service: 'zcode-agent',
      method: 'initializeConversationV4',
      args: [
        {
          'kind': 'clientHello',
          'protocolVersion': 3,
          'clientId': _clientId,
          'clientKind': clientMode == 'desktop-continuous' ? 'desktop' : 'web',
          'appVersion': appVersion,
          'capabilities': {'workspaceHookReview': true},
        },
      ],
      match: (json) =>
          json is Map && (json['capabilities'] != null || json['ok'] != null)
              ? json
              : null,
    );
    if (init == null) return;
    final sub = await _rpcCall(
      service: 'zcode-agent',
      method: 'subscribeSessionsIndexV4',
      args: [
        {
          'workspacePath': workspaceKey,
          'runtimePolicy': 'existing-only',
          if (_connectionId.isNotEmpty) 'connectionId': _connectionId,
          'clientMode': clientMode,
        },
      ],
      match: (json) => json is Map && json['ack'] is Map ? json : null,
    );
    if (sub != null) {
      _reportReady(true);
    }
  }

  // ---- 入帧分派（由监控连接调用）----

  /// 返回 true 表示该 payload 属于 agent 层（rpc-frame / bridge-ready），
  /// 监控侧不必再消费。workspace-list-response 两边都消费（agent 匹配
  /// 自己的引导请求，监控喂快照）。
  bool handleDataPayload(Map<dynamic, dynamic> payload) {
    final zcodeType = payload['zcode_type'];
    if (zcodeType == 'workspace-list-response') {
      _dispatchPending(payload);
      return false;
    }
    if (zcodeType == 'workspace-bridge-ready') {
      _dispatchPending(payload);
      return true;
    }
    if (zcodeType != 'rpc-frame') return false;
    // rpc 帧：先 ack（不回会被反复重传），再解载荷。
    final messageSeq = payload['messageSeq'];
    if (messageSeq is int) {
      sendJson({
        'type': 'data',
        'payload': AgentWire.ackEnvelope(
          bridgeSessionId: _bridgeSessionId,
          bridgeGeneration: _bridgeGeneration,
          ackMessageSeq: messageSeq,
        ),
        'client_ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      });
    }
    final b64 = payload['dataBase64'];
    if (b64 is! String || b64.isEmpty) return true;
    final Uint8List bytes;
    try {
      bytes = AgentWire.decodePayloadBase64(b64);
    } catch (_) {
      return true;
    }
    final fragmentCount = payload['fragmentCount'];
    final id = payload['logicalFrameId'] ?? messageSeq;
    final logicalId = '$id';
    if (fragmentCount is int && fragmentCount > 1) {
      final index = payload['fragmentIndex'];
      if (index is! int) return true;
      // 有界：异常重放/垃圾帧不该把缓存撑爆；超过 16 个逻辑帧丢最旧的。
      while (_fragments.length > 16) {
        _fragments.remove(_fragments.keys.first);
      }
      var parts = _fragments[logicalId];
      if (parts == null) {
        parts = List<Uint8List?>.filled(fragmentCount, null);
        _fragments[logicalId] = parts;
        _fragmentTotal[logicalId] = fragmentCount;
      }
      if (index < parts.length) parts[index] = bytes;
      if (parts.any((p) => p == null)) return true;
      final whole = <int>[];
      for (final part in parts) {
        whole.addAll(part!);
      }
      _fragments.remove(logicalId);
      _consumeAgentBytes(Uint8List.fromList(whole));
    } else {
      _consumeAgentBytes(bytes);
    }
    return true;
  }

  void _consumeAgentBytes(Uint8List bytes) {
    // 请求方向（04 04）是桌面端回调推送；响应方向（04 02）是调用回执。
    // 统一走响应解码 + 宽松事件分派：匹配不上 pending 的 JSON 作为订阅
    // 事件交给 onEvent（SessionStateExtractor 在上层做字段级提取）。
    final json = AgentWire.tryDecodeResponse(bytes);
    if (json == null) return;
    if (!_dispatchPending(json) && json is Map) {
      try {
        onEvent?.call(deviceId, json);
      } catch (_) {}
    }
  }

  bool _dispatchPending(Object json) {
    for (final pending in List.of(_pending)) {
      Object? matched;
      try {
        matched = pending.match(json);
      } catch (_) {
        matched = null;
      }
      if (matched != null) {
        _pending.remove(pending);
        if (!pending.completer.isCompleted) {
          pending.completer.complete(matched);
        }
        return true;
      }
    }
    return false;
  }

  // ---- rpc 调用与命令 ----

  Future<Object?> _rpcCall({
    required String service,
    required String method,
    required List<Object?> args,
    required Object? Function(Object? json) match,
  }) async {
    _messageSeq += 1;
    final seq = _messageSeq;
    final payload = AgentWire.encodeRequest(
      seq: seq,
      service: service,
      method: method,
      args: args,
    );
    final completer = Completer<Object?>();
    final pending = _PendingCall(match: match, completer: completer);
    _pending.add(pending);
    sendJson({
      'type': 'data',
      'payload': AgentWire.rpcFrameEnvelope(
        bridgeSessionId: _bridgeSessionId,
        bridgeGeneration: _bridgeGeneration,
        messageSeq: seq,
        payload: payload,
      ),
      'client_ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => null,
    ).catchError((_) => null).whenComplete(() => _pending.remove(pending));
  }

  /// 提交一条命令（通知动作等）；层未就绪返回 false，由调用方走一次性
  /// 通道兜底（[RelayAgentChannel]）。
  Future<bool> submitCommand(Map<String, Object?> envelope) async {
    if (!_ready) return false;
    final commandId = '${envelope['commandId']}';
    final result = await _rpcCall(
      service: 'zcode-agent',
      method: 'sendConversationCommandV4',
      args: [
        {'workspacePath': _workspaceKey, 'envelope': envelope},
      ],
      match: (json) => json is Map
          ? (json['commandId'] == commandId || json['status'] is String)
                ? json
                : null
          : null,
    );
    if (result is! Map) return false;
    final status = '${result['status']}';
    return status == 'accepted' || status == 'duplicate' || status == 'noop';
  }
}

class _PendingCall {
  _PendingCall({required this.match, required this.completer});

  final Object? Function(Object? json) match;
  final Completer<Object?> completer;
}

// jsonEncode 在本文件用于调试性字段的序列化保持 import 有效性；发帧统一
// 走监控连接的 sendJson。
// ignore: unused_element
final Object? _jsonKeepalive = null;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'agent_rpc.dart';
import 'relay_monitor.dart';

/// 每设备一条的 agent 命令通道（v1.4.0）——独立于监控连接的第二条 WS：
/// 监控（快照/完成/失败通知）绝不因 agent 层故障受影响，agent 层失败只是
/// "通知栏没有按钮"，安全降级。
///
/// 生命周期：connect → auth_init/ack → workspace-list（取 activeWorkspaceKey）
/// → workspace-bridge-open → rpc 帧循环（收帧必 ack）→ hello → initialize
/// → subscribeSessionsIndex → 事件流入 [onEvent]；命令经 [submitCommand]。
///
/// 事件形状防御：订阅推送的 JSON 结构未经活体验证（PC 无有效令牌），
/// 解析走与 WebView 路径相同的宽松提取器——认字段不认信封，形状不符就
/// 静默丢弃，绝不崩连接。
class RelayAgentChannel {
  RelayAgentChannel({
    required this.deviceId,
    required this.deviceSid,
    required this.deviceMid,
    required this.appVersion,
    required this.tokenProvider,
    required this.onEvent,
    RelaySocket Function()? socketFactory,
  }) : _socketFactory = socketFactory ?? IoRelaySocket.new;

  final String deviceId;
  final String deviceSid;
  final String deviceMid;
  final String appVersion;
  final Future<String?> Function() tokenProvider;
  final RelaySocket Function() _socketFactory;

  /// 从订阅推送里提取的会话/交互事件（sessionId, interactionId, kind, options…）。
  final void Function(String deviceId, Map<dynamic, dynamic> event)?
  onEvent;

  RelaySocket? _socket;
  StreamSubscription<String>? _subscription;
  Timer? _heartbeat;
  Timer? _handshakeWatch;
  bool _running = false;
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

  bool get isReady => _ready;

  // ---- 启停 ----

  Future<void> start() async {
    if (_running) return;
    _running = true;
    unawaited(_run());
  }

  Future<void> stop() async {
    _running = false;
    _ready = false;
    _heartbeat?.cancel();
    _heartbeat = null;
    _handshakeWatch?.cancel();
    _handshakeWatch = null;
    await _subscription?.cancel();
    _subscription = null;
    await _socket?.close();
    _socket = null;
    for (final pending in _pending) {
      pending.completer.completeError(StateError('channel stopped'));
    }
    _pending.clear();
  }

  Future<void> _run() async {
    while (_running) {
      try {
        await _connectOnce();
        // _connectOnce 在连接关闭后返回；退避后重试。
        await Future<void>.delayed(RelayMonitorPolicy.backoff(2));
      } catch (_) {
        await Future<void>.delayed(RelayMonitorPolicy.backoff(2));
      }
    }
  }

  Future<void> _connectOnce() async {
    final jwt = await tokenProvider();
    if (!_running || jwt == null || jwt.isEmpty) {
      // 没有令牌：等一分钟再试（与监控连接同节奏）。
      await Future<void>.delayed(RelayMonitorConnection.authRetryDelay);
      return;
    }
    // V2 令牌链（与监控一致）：JWT 换 60s 短效 relay token。
    final relayToken = await RelayMonitorConnection.exchangeRelayToken(jwt);
    if (!_running || relayToken == null) {
      await Future<void>.delayed(RelayMonitorConnection.authRetryDelay);
      return;
    }
    final socket = _socketFactory();
    await socket.connect(
      RelayMonitorConnection.wsUrlFor(token: relayToken, deviceMid: deviceMid),
      RelayMonitorPolicy.connectTimeout,
    );
    if (!_running) {
      await socket.close();
      return;
    }
    _socket = socket;
    _ready = false;
    _pending.clear();
    _subscription = socket.messages.listen(
      _onText,
      onError: (Object _) => _closeSocket(),
      onDone: _closeSocket,
    );
    _send({
      'type': 'auth_init',
      'device_sid': deviceSid,
      'meta': {
        'platform': 'web',
        'version': appVersion,
        'name': 'mobile-browser',
      },
      'client_ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
    _startHeartbeat();
    // 整个引导链（auth → 桥 → 订阅）的总预算；超时关连接走外层重试。
    _handshakeWatch?.cancel();
    _handshakeWatch = Timer(const Duration(seconds: 30), () {
      if (!_ready) _closeSocket();
    });
  }

  void _closeSocket() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_socket?.close());
    _socket = null;
    _ready = false;
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(RelayMonitorPolicy.heartbeat, (_) {
      _send({
        'type': 'pair_status_query',
        'client_ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      });
    });
  }

  // ---- 中继 JSON 层 ----

  void _send(Map<String, Object?> message) {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.send(jsonEncode(message));
    } catch (_) {
      _closeSocket();
    }
  }

  void _onText(String text) {
    final inbound = RelayMonitorPolicy.parse(text);
    if (inbound == null) return;
    switch (inbound) {
      case RelayAuthAck():
        if (inbound.deviceSid == deviceSid) unawaited(_bootstrap());
      case RelayDataPayload(:final payload):
        _onDataPayload(payload);
      case RelayErrorFrame():
        _closeSocket();
      case RelayPairStatusAck():
      case RelayUnknownFrame():
        break;
    }
  }

  // ---- 引导链 ----

  Future<void> _bootstrap() async {
    // 1) 取工作区列表 → activeWorkspaceKey（权威工作区，V1 实测 §4）。
    final workspace = await _requestWorkspaceList();
    if (workspace == null || !_running) return;
    // 2) 开桥（bridgeSessionId 自生成是被官方接受的）。
    final bridgeOk = await _openBridge(workspace);
    if (!bridgeOk || !_running) return;
    // 3) hello → initialize → 订阅。
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
      isRelayJson: true,
    ));
    _send({
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
    if (result == null) {
      _closeSocket();
      return null;
    }
    final key = result['activeWorkspaceKey'];
    if (key is String && key.isNotEmpty) return key;
    _closeSocket();
    return null;
  }

  Future<bool> _openBridge(String workspaceKey) async {
    _bridgeSessionId = 'zrbridge-$_requestSeq-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    _requestSeq += 1;
    final requestId = 'agent-$_requestSeq';
    final completer = Completer<Map<dynamic, dynamic>?>();
    _pending.add(_PendingCall(
      match: (json) =>
          json is Map && json['requestId'] == requestId ? json : null,
      completer: completer,
      isRelayJson: true,
    ));
    _send({
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
    if (ready == null) {
      _closeSocket();
      return false;
    }
    _workspaceKey = workspaceKey;
    return true;
  }

  Future<void> _handshakeAgent(String workspaceKey) async {
    // helloConversationV4（无参）：响应带 clientMode（web-remote-replayable）。
    final hello = await _rpcCall(
      service: 'zcode-agent',
      method: 'helloConversationV4',
      args: const [],
      match: (json) => json is Map && json['clientMode'] is String ? json : null,
    );
    if (hello is! Map) return;
    final clientMode = '${hello['clientMode']}';
    _connectionId = '${hello['connectionId'] ?? ''}';
    // initializeConversationV4：clientKind 按 clientMode 推导（§8.4.1 修正 1：
    // 'desktop-continuous'→'desktop'，其余（含 web-remote-replayable）→'web'）。
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
      match: (json) => json is Map && (json['capabilities'] != null || json['ok'] != null) ? json : null,
    );
    if (init == null) return;
    // 订阅会话索引：pendingInteraction 出现/消失就是审批/输入事件源。
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
      _ready = true;
      _handshakeWatch?.cancel();
    }
  }

  // ---- rpc-frame 层 ----

  /// 发起一次方法调用；响应按 [match] 内容匹配（桌面端响应 seq 不回显请求
  /// 序号，V1 实测）。超时/断开返回 null，绝不抛。
  Future<Object?> _rpcCall({
    required String service,
    required String method,
    required List<Object?> args,
    required Object? Function(Object? json) match,
  }) async {
    if (_socket == null) return null;
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
    _send({
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

  /// 供外部（通知动作）提交命令；未就绪时返回 false。
  Future<bool> submitCommand(Map<String, Object?> envelope) async {
    if (!_ready) return false;
    final commandId = '${envelope['commandId']}';
    final result = await _rpcCall(
      service: 'zcode-agent',
      method: 'sendConversationCommandV4',
      args: [
        {
          'workspacePath': _workspaceKey,
          'envelope': envelope,
        },
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

  void _onDataPayload(Map<dynamic, dynamic> payload) {
    final zcodeType = payload['zcode_type'];
    if (zcodeType == 'workspace-list-response' ||
        zcodeType == 'workspace-bridge-ready') {
      // JSON 层响应（引导链）：按 requestId 匹配挂起请求。
      _dispatchPending(payload);
      return;
    }
    if (zcodeType != 'rpc-frame') return;
    // rpc 帧：先 ack（不回会被反复重传），再解载荷。
    final messageSeq = payload['messageSeq'];
    if (messageSeq is int) {
      _send({
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
    if (b64 is! String || b64.isEmpty) return;
    final Uint8List bytes;
    try {
      bytes = AgentWire.decodePayloadBase64(b64);
    } catch (_) {
      return;
    }
    final fragmentCount = payload['fragmentCount'];
    final id = payload['logicalFrameId'] ?? messageSeq;
    final logicalId = '$id';
    if (fragmentCount is int && fragmentCount > 1) {
      final index = payload['fragmentIndex'];
      if (index is! int) return;
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
      if (parts.any((p) => p == null)) return;
      final whole = <int>[];
      for (final part in parts) {
        whole.addAll(part!);
      }
      _fragments.remove(logicalId);
      _consumeAgentBytes(Uint8List.fromList(whole));
    } else {
      _consumeAgentBytes(bytes);
    }
  }

  void _consumeAgentBytes(Uint8List bytes) {
    // 请求方向（04 04）是桌面端回调推送；响应方向（04 02）是调用回执。
    // 两者的载荷都是"响应头 + JSON"或事件 JSON——统一走响应解码 + 宽松
    // 事件分派：能解出 JSON 就喂给 pending 匹配器，匹配不上就作为订阅
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
}

class _PendingCall {
  _PendingCall({required this.match, required this.completer, this.isRelayJson = false});

  final Object? Function(Object? json) match;
  final Completer<Object?> completer;
  final bool isRelayJson;
}

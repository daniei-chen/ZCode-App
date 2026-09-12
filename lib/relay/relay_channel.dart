import 'dart:async';
import 'dart:convert';

import 'relay_frame.dart';
import 'relay_link.dart';
import 'relay_payloads.dart';
import 'relay_proof.dart';
import 'relay_socket.dart';

/// 连接阶段。
enum RelayPhase {
  idle,
  connecting,
  authenticating,

  /// 握手完成，且收到过配对状态。
  ready,

  /// 传输降级（缺口/溢出等），仍可尝试恢复。
  degraded,
  failed,
  closed,
}

/// 连接失败原因（与页面里的失败码对齐）。
class RelayFailure {
  const RelayFailure({required this.reason, this.message});

  final String reason;
  final String? message;

  bool get isTerminal => const {
    'session-not-found',
    'session-expired',
    'session-conflict',
    'workspace-closed',
    'desktop-disconnected',
    'invalid-mobile-connection',
  }.contains(reason);

  @override
  String toString() =>
      'RelayFailure($reason${message == null ? '' : ': $message'})';
}

/// 一条已解出的下行负载。
class RelayDownlink {
  const RelayDownlink({
    required this.zcodeType,
    required this.raw,
    this.isFrame = false,
  });

  final String zcodeType;
  final Map<String, dynamic> raw;

  /// 是否是需要交给组装器的 `rpc-frame`。
  final bool isFrame;
}

/// Model B 通道：单条 relay WS，完成 HMAC 握手后承载全部 RPC 与数据帧。
///
/// 与页面实现一致的行为：
/// - 连接 `wss://<origin>/ws?mid=<deviceMid>`
/// - 立即发 `auth_init`（role=terminal）
/// - `auth_challenge{nonce}` → 回 `auth_response{proof}`
/// - `auth_ack` / `pair_status_ack` 后进入 ready
/// - `pair_status_query` 心跳
class RelayChannel {
  RelayChannel({
    required this.link,
    RelaySocketFactory? socketFactory,
    int Function()? clock,
    this.heartbeatInterval = const Duration(seconds: 10),
    this.heartbeatJitter = const Duration(seconds: 2),
    this.onRawMessage,
  }) : _factory = socketFactory ?? const IoRelaySocketFactory(),
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final RelayLink link;
  final RelaySocketFactory _factory;
  final int Function() _clock;
  final Duration heartbeatInterval;
  final Duration heartbeatJitter;

  /// 诊断钩子：收到原始报文时回调（协议对齐排查用）。
  final void Function(String raw)? onRawMessage;

  RelaySocket? _socket;
  RelayPhase _phase = RelayPhase.idle;
  StreamSubscription<String>? _sub;
  Timer? _heartbeat;
  bool _closed = false;

  final _phases = StreamController<RelayPhase>.broadcast();
  final _downlinks = StreamController<RelayDownlink>.broadcast();
  final _failures = StreamController<RelayFailure>.broadcast();
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};

  /// 诊断计数，便于交叉校验时观察链路是否真的在动。
  int framesIn = 0;
  int framesOut = 0;
  int acksOut = 0;
  int authRounds = 0;
  String? pairStatusSummary;

  RelayPhase get phase => _phase;
  bool get isReady =>
      _phase == RelayPhase.ready || _phase == RelayPhase.degraded;

  /// degraded 表示传输仍在但已降级。重连必须重建桥，不能被 [isReady]
  /// 短路——否则降级后的退避重试全部空转（评审 N1）。
  bool get isDegraded => _phase == RelayPhase.degraded;

  Stream<RelayPhase> get phases => _phases.stream;
  Stream<RelayDownlink> get downlinks => _downlinks.stream;
  Stream<RelayFailure> get failures => _failures.stream;

  /// 组装器需要知道当前桥身份，用于丢弃过期帧。
  String? bridgeSessionId;

  void _setPhase(RelayPhase p) {
    if (_phase == p) return;
    _phase = p;
    if (!_phases.isClosed) _phases.add(p);
  }

  void _fail(String reason, [String? message, bool preservePhase = false]) {
    if (_phase != RelayPhase.closed && !preservePhase) {
      _setPhase(RelayPhase.failed);
    }
    _heartbeat?.cancel();
    _heartbeat = null;
    if (!_failures.isClosed) {
      _failures.add(RelayFailure(reason: reason, message: message));
    }
    // 握手未完成时也要让它失败，否则 connect() 会永久挂起。
    final handshake = _handshakeDone;
    if (handshake != null && !handshake.isCompleted) {
      handshake.completeError(StateError('relay $reason'));
    }
    // 未完成的 RPC 全部失败，避免调用方永久挂起。
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('relay $reason'));
    }
    _pending.clear();
  }

  /// 建立连接并完成握手。抛出 [RelayFailure] 表示失败。
  Future<void> connect() async {
    if (_socket != null) await close();
    _closed = false;
    _setPhase(RelayPhase.connecting);

    final uri = _buildUri();

    final socket = await _factory.connect(uri);
    _socket = socket;
    _sub = socket.messages.listen(
      _onMessage,
      onError: (Object e) {
        _fail('relay-unavailable', e.toString());
      },
      onDone: () {
        if (_closed) return;
        _fail('invalid-mobile-connection', 'socket closed');
      },
    );

    final handshake = Completer<void>();
    _handshakeDone = handshake;

    _setPhase(RelayPhase.authenticating);
    _sendControl(
      RelayUplink.authInit(
        deviceSid: link.deviceSid ?? '',
        clientTs: _clock(),
        appVersion: link.appVersion,
      ),
    );

    await handshake.future;
  }

  Completer<void>? _handshakeDone;

  Uri _buildUri() {
    final base = link.wsBase.replace(path: '/ws');
    final mid = link.deviceMid?.trim();
    if (mid == null || mid.isEmpty) return base;
    return base.replace(queryParameters: {...base.queryParameters, 'mid': mid});
  }

  /// 发一条**控制消息**（握手类：`auth_init` / `auth_response` / `pair_status_query`）。
  /// 这类消息是平铺的，不套 `data` 外壳。
  void _sendControl(Map<String, dynamic> payload) {
    final socket = _socket;
    if (socket == null) return;
    framesOut++;
    _sendRaw(socket, jsonEncode(payload));
  }

  /// 发一条**数据负载**。官方实现（`payloadSerializer.prepare`）要求套成
  /// `{"type":"data","payload":<payload>,"client_ts":<ms>}`，且单包 ≤ 1 MiB。
  void sendPayload(Map<String, dynamic> payload) {
    final socket = _socket;
    if (socket == null) return;
    framesOut++;
    _sendRaw(
      socket,
      jsonEncode({'type': 'data', 'payload': payload, 'client_ts': _clock()}),
    );
  }

  void _sendRaw(RelaySocket socket, String raw) {
    final bytes = utf8.encode(raw);
    if (bytes.length > RelayLimits.maxPhysicalFrameBytes) {
      _fail('frame-too-large', 'outbound=${bytes.length}');
      return;
    }
    socket.send(raw);
  }

  void _onMessage(String raw) {
    // Do this before JSON decoding. A giant JSON string must not enter the
    // parser just because its envelope is otherwise syntactically valid.
    if (raw.length > RelayLimits.maxPhysicalFrameBytes * 2) {
      _fail('frame-too-large', 'chars=${raw.length}');
      return;
    }
    final rawBytes = utf8.encode(raw);
    if (rawBytes.length > RelayLimits.maxPhysicalFrameBytes) {
      _fail('frame-too-large', 'bytes=${rawBytes.length}');
      return;
    }
    onRawMessage?.call(raw);
    final env = RelayEnvelope.tryParse(raw);
    if (env == null) return;

    switch (env.type) {
      case 'auth_challenge':
        final ch = RelayHandshake.from(env);
        final nonce = ch?.nonce;
        if (nonce == null || nonce.isEmpty) {
          _fail('unexpected-error', 'auth_challenge without nonce');
          return;
        }
        final sid = link.deviceSid;
        final pass = link.passHash;
        if (sid == null || pass == null) {
          _fail('invalid-mobile-connection', 'missing deviceSid/passHash');
          return;
        }
        authRounds++;
        _sendControl(
          RelayUplink.authResponse(
            deviceSid: sid,
            proof: RelayProof.forTerminal(
              passHash: pass,
              nonce: nonce,
              deviceSid: sid,
            ),
            clientTs: _clock(),
          ),
        );
        return;

      case 'auth_ack':
        _setPhase(RelayPhase.ready);
        _startHeartbeat();
        final c = _handshakeDone;
        if (c != null && !c.isCompleted) c.complete();
        return;

      case 'pair_status_ack':
        final ch = RelayHandshake.from(env);
        pairStatusSummary = ch?.pairStatus?.toString();
        _setPhase(RelayPhase.ready);
        _startHeartbeat();
        final c = _handshakeDone;
        if (c != null && !c.isCompleted) c.complete();
        return;

      case 'error':
        final code = env.field('code') ?? env.field('error');
        _fail(
          code is String && code.isNotEmpty ? code : 'unexpected-error',
          env.field('message')?.toString(),
        );
        return;

      case 'data':
        _onData(env.payload);
        return;
    }
  }

  void _onData(Map<String, dynamic>? payload) {
    if (payload == null) return;
    final type = payload['zcode_type'];
    if (type is! String || type.isEmpty) return;
    framesIn++;

    if (type == ZcodeType.rpcFrame) {
      // 必须回 ack：实测不回时桌面端会按同一 seq 反复重传。
      _ackFrame(payload);
    }

    if (type == ZcodeType.rpcFrame || type == ZcodeType.rpcFrameAck) {
      if (!_downlinks.isClosed) {
        _downlinks.add(
          RelayDownlink(zcodeType: type, raw: payload, isFrame: true),
        );
      }
      return;
    }

    if (ZcodeType.failureTypes.contains(type)) {
      final sid = payload['bridgeSessionId'];
      // 只接受属于当前桥的降级通知，避免旧桥的迟到消息污染状态。
      if (sid is String && bridgeSessionId != null && sid != bridgeSessionId) {
        return;
      }
      if (type == ZcodeType.bridgeDegraded) {
        _setPhase(RelayPhase.degraded);
      }
      final reason = payload['reason'];
      _fail(
        reason is String && reason.isNotEmpty ? reason : type,
        payload['message']?.toString(),
        type == ZcodeType.bridgeDegraded,
      );
      return;
    }

    // RPC 响应配对
    final rid = payload['requestId'];
    if (rid is String) {
      final c = _pending.remove(rid);
      if (c != null && !c.isCompleted) c.complete(payload);
    }

    if (!_downlinks.isClosed) {
      _downlinks.add(RelayDownlink(zcodeType: type, raw: payload));
    }
  }

  /// 回执一帧 `rpc-frame`。
  ///
  /// 官方实现里 ack 的形状是 `{zcode_type:'rpc-frame-ack', ...identity, ackMessageSeq}`
  /// （identity = bridgeSessionId / bridgeGeneration / recoveryId）。
  void _ackFrame(Map<String, dynamic> payload) {
    final seq = payload['messageSeq'] ?? payload['seq'];
    if (seq is! int) return;
    final sid = payload['bridgeSessionId'];
    if (sid is! String || sid.isEmpty) return;
    acksOut++;
    sendPayload({
      'zcode_type': ZcodeType.rpcFrameAck,
      'bridgeSessionId': sid,
      if (payload['bridgeGeneration'] != null)
        'bridgeGeneration': payload['bridgeGeneration'],
      if (payload['recoveryId'] != null) 'recoveryId': payload['recoveryId'],
      'ackMessageSeq': seq,
    });
  }

  void _startHeartbeat() {
    if (_heartbeat != null) return;
    final sid = link.deviceSid;
    if (sid == null) return;
    _heartbeat = Timer.periodic(heartbeatInterval, (_) {
      _sendControl(
        RelayUplink.pairStatusQuery(deviceSid: sid, clientTs: _clock()),
      );
    });
  }

  /// RPC 请求/响应：按 `requestId` 配对，超时抛 [TimeoutException]。
  Future<Map<String, dynamic>> request(
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final rid = payload['requestId'];
    if (rid is! String) {
      throw ArgumentError('payload 缺少 requestId');
    }
    final completer = Completer<Map<String, dynamic>>();
    _pending[rid] = completer;
    sendPayload(payload);
    try {
      return await completer.future.timeout(timeout);
    } finally {
      _pending.remove(rid);
    }
  }

  /// 等待某个类型的下行负载。
  Future<Map<String, dynamic>> awaitType(
    String zcodeType, {
    bool Function(Map<String, dynamic>)? where,
    Duration timeout = const Duration(seconds: 20),
  }) {
    final completer = Completer<Map<String, dynamic>>();
    late StreamSubscription<RelayDownlink> sub;
    sub = downlinks.listen((d) {
      if (d.isFrame || d.zcodeType != zcodeType) return;
      if (where != null && !where(d.raw)) return;
      if (!completer.isCompleted) completer.complete(d.raw);
    });
    return completer.future.timeout(timeout).whenComplete(() => sub.cancel());
  }

  Future<void> close() async {
    _closed = true;
    _heartbeat?.cancel();
    _heartbeat = null;
    await _sub?.cancel();
    _sub = null;
    await _socket?.close();
    _socket = null;
    final handshake = _handshakeDone;
    if (handshake != null && !handshake.isCompleted) {
      handshake.completeError(StateError('relay closed'));
    }
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('relay closed'));
    }
    _pending.clear();
    _setPhase(RelayPhase.closed);
  }

  void dispose() {
    _phases.close();
    _downlinks.close();
    _failures.close();
  }
}

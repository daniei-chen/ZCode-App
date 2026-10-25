/// 原生监控通道（v1.3.0）——绕过 WebView 直连 `wss://zcode.z.ai/ws` 的
/// JSON 层。协议形状来自 2026-10 对官方 3.16.3 页面 bundle 的逆向与
/// `docs/RELAY-PROTOCOL-VERIFIED.md`（V1 实测）的交叉验证：
///
/// * 握手：`auth_init{device_sid}` → `auth_ack{device_sid, pair_status}`。
///   V2 已无 `auth_challenge`/HMAC proof（bundle 中 0 命中），sid 即凭证；
/// * 心跳：`pair_status_query{client_ts}`，官方默认间隔 5s，等待配对超时 30s；
/// * 任务快照：`data{payload:{zcode_type:'workspace-list-request', requestId}}`
///   → `data{payload:{requestId, result:{tasks:[…]}}}`，与 WebView 侧
///   `TaskIndexExtractor` 认识的 `result.tasks` 形状一致，可复用同一提取器；
/// * 二进制 `rpc-frame` 只在打开 workspace 桥之后出现，监控通道不开桥，
///   收到即忽略（v1.4 的审批写路径才需要它）。
///
/// 边界：本层只读。不发任何写命令，不回 ack（无桥则无帧可 ack）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../services/app_log.dart';
import '../services/structured_log.dart';

/// 监控连接的状态机。
enum RelayMonitorState {
  /// 未启动或已停止。
  idle,

  /// TCP/WS 建连中。
  connecting,

  /// 已发 auth_init，等待 auth_ack。
  authenticating,

  /// 账号令牌未捕获（用户还没打开过远控页）——静默等 60s 重读。
  /// 诊断口径：这是"装好后没打开过页面"的专属状态，与网络故障区分。
  authMissing,

  /// 服务端已确认但 pair_status=waiting_terminal（桌面端没在等终端）。
  waiting,

  /// pair_status=matched：可以拉任务快照。
  paired,

  /// 本轮连接已断开（服务停止或重连前的间隙）。
  disconnected,
}

/// 一条从中继收到的已解析消息。
sealed class RelayInbound {
  const RelayInbound();
}

class RelayAuthAck extends RelayInbound {
  const RelayAuthAck({required this.deviceSid, required this.pairStatus});

  final String deviceSid;
  final String pairStatus;
}

class RelayPairStatusAck extends RelayInbound {
  const RelayPairStatusAck({required this.pairStatus});

  final String pairStatus;
}

/// `type:data` 的 payload 原样透传（调用方按 zcode_type 分派）。
class RelayDataPayload extends RelayInbound {
  const RelayDataPayload(this.payload);

  final Map<dynamic, dynamic> payload;
}

class RelayErrorFrame extends RelayInbound {
  const RelayErrorFrame({required this.code, this.message});

  final String code;
  final String? message;
}

class RelayUnknownFrame extends RelayInbound {
  const RelayUnknownFrame(this.type);

  final String type;
}

/// 纯解析/构造策略（可单测，不碰 socket）。
abstract final class RelayMonitorPolicy {
  /// 官方默认心跳间隔（bundle：heartbeatIntervalMs ?? 5e3）。
  static const heartbeat = Duration(seconds: 5);

  /// 快照轮询间隔。审批/完成事件靠快照间的 displayStatus 差分发现，
  /// 15s 是"通知延迟可接受"与"省电"的折中。
  static const poll = Duration(seconds: 15);

  /// WS 建连 + auth_ack 的总预算。
  static const connectTimeout = Duration(seconds: 12);

  /// 对齐官方页面的 waiting 超时（waitingTimeoutMs ?? 3e4）。
  static const waitingTimeout = Duration(seconds: 30);

  /// 重连退避：3s 起，指数翻倍，封顶 120s。
  static const reconnectBase = Duration(seconds: 3);
  static const reconnectCap = Duration(seconds: 120);

  static Duration backoff(int attempt) {
    if (attempt <= 0) return reconnectBase;
    final seconds = reconnectBase.inSeconds * math.pow(2, attempt - 1).toInt();
    return Duration(seconds: math.min(seconds, reconnectCap.inSeconds));
  }

  /// `client_ts` 用秒（V2 页面是 Math.floor(Date.now()/1e3)，V1 的毫秒已废）。
  static Map<String, Object?> authInitMessage({
    required String deviceSid,
    required String appVersion,
    required int nowSeconds,
  }) => {
    'type': 'auth_init',
    'device_sid': deviceSid,
    'meta': {
      // 官方 web 终端自报的形态；中继不据此鉴权，只做遥测。
      'platform': 'web',
      'version': appVersion,
      'name': 'mobile-browser',
    },
    'client_ts': nowSeconds,
  };

  static Map<String, Object?> pairStatusQueryMessage(int nowSeconds) =>
      {'type': 'pair_status_query', 'client_ts': nowSeconds};

  static Map<String, Object?> workspaceListRequest({
    required String requestId,
    required int nowSeconds,
  }) => {
    'type': 'data',
    'payload': <String, Object?>{
      'zcode_type': 'workspace-list-request',
      'requestId': requestId,
    },
    'client_ts': nowSeconds,
  };

  /// 解析一条下行文本。非 JSON / 顶层非对象 → null（调用方静默丢弃）。
  static RelayInbound? parse(String text) {
    if (text.isEmpty || text.length > 4 * 1024 * 1024) return null;
    final dynamic root;
    try {
      root = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (root is! Map) return null;
    final type = root['type'];
    switch (type) {
      case 'auth_ack':
        final sid = root['device_sid'];
        if (sid is! String || sid.isEmpty) return null;
        return RelayAuthAck(
          deviceSid: sid,
          pairStatus: '${root['pair_status'] ?? ''}',
        );
      case 'pair_status_ack':
        return RelayPairStatusAck(pairStatus: '${root['pair_status'] ?? ''}');
      case 'data':
        final payload = root['payload'];
        if (payload is Map) {
          return RelayDataPayload(payload);
        }
        // V1 时代的 data 帧可能没有 payload 外壳；没有就不消费。
        return RelayUnknownFrame('data');
      case 'error':
        return RelayErrorFrame(
          code: '${root['code'] ?? ''}',
          message: root['message'] is String ? root['message'] as String : null,
        );
      default:
        return RelayUnknownFrame('$type');
    }
  }
}

/// socket 抽象：单测注入假实现，生产用 [IoRelaySocket]。
abstract class RelaySocket {
  Future<void> connect(Uri uri, Duration timeout);
  Stream<String> get messages;
  Future<void> send(String text);
  Future<void> close();
}

class IoRelaySocket implements RelaySocket {
  WebSocket? _socket;
  StreamController<String>? _controller;

  @override
  Future<void> connect(Uri uri, Duration timeout) async {
    final socket = await WebSocket.connect(uri.toString()).timeout(timeout);
    _socket = socket;
    final controller = StreamController<String>.broadcast();
    _controller = controller;
    socket.listen(
      (data) {
        if (data is String) {
          controller.add(data);
        } else {
          // 二进制帧属于 rpc-frame 桥层，监控通道不开桥，理论上不该出现；
          // 出现也只忽略，绝不去解（写路径 v1.4 才引入）。
          AppLog.event(
            LogEvent.relayMonitorBinaryIgnored,
            level: LogLevel.debug,
          );
        }
      },
      onError: controller.addError,
      onDone: controller.close,
      cancelOnError: false,
    );
  }

  @override
  Stream<String> get messages =>
      _controller?.stream ?? const Stream<String>.empty();

  @override
  Future<void> send(String text) async {
    final socket = _socket;
    if (socket == null) return;
    socket.add(text);
  }

  @override
  Future<void> close() async {
    _controller?.close();
    _controller = null;
    await _socket?.close();
    _socket = null;
  }
}

/// 单台设备的一条监控连接：连接 → 握手 → 心跳 + 轮询 → 断线退避重连。
///
/// V2 终端连接的完整配方（官方 3.16.3 bundle 实证）：
/// `wss://zcode.z.ai/ws?token=<账号JWT>&mid=<设备mid>`——账号 JWT 由
/// [tokenProvider] 每次建连时现读（页面探针捕获，登录刷新后自然轮换）；
/// 没有 token 时不连（60s 后重试），绝不裸连（服务端以 WRONG_PARAM 拒绝）。
///
/// 所有 UI 无关的状态迁移都通过 [onState] 上报；`workspace-list-response`
/// 的 `result` 对象通过 [onSnapshot] 交给上层（通知管线）。本类不持有
/// 设备名等展示信息，也不直接发通知——那是上层 service 的职责。
class RelayMonitorConnection {
  RelayMonitorConnection({
    required this.deviceId,
    required this.deviceSid,
    required this.deviceMid,
    required this.appVersion,
    required this.tokenProvider,
    this.relayTokenExchange = exchangeRelayToken,
    RelaySocket Function()? socketFactory,
    DateTime Function()? now,
    this.onState,
    this.onSnapshot,
  }) : _socketFactory = socketFactory ?? IoRelaySocket.new,
       _now = now ?? DateTime.now;

  final String deviceId;
  final String deviceSid;

  /// 设备 mid：V2 连接的必带 query 参数（V1 同）。
  final String deviceMid;
  final String appVersion;

  /// 每次建连现读账号 JWT；null/空 = 尚未捕获（用户没打开过远控页）。
  final Future<String?> Function() tokenProvider;

  /// JWT → 短效 relay token（可注入；生产走 HTTP 交换端点）。
  final Future<String?> Function(String jwt) relayTokenExchange;
  final RelaySocket Function() _socketFactory;
  final DateTime Function() _now;

  /// 状态迁移回调（含 disconnected）。回调里不得抛异常。
  final void Function(String deviceId, RelayMonitorState state)? onState;

  /// 快照回调：`result` 即 `workspace-list-response.result`（含 tasks）。
  final void Function(String deviceId, Map<dynamic, dynamic> result)?
  onSnapshot;

  RelayMonitorState _state = RelayMonitorState.idle;
  RelaySocket? _socket;
  StreamSubscription<String>? _subscription;
  Timer? _heartbeat;
  Timer? _poll;
  Timer? _reconnect;
  Timer? _waitingWatch;
  Timer? _authRetry;
  int _attempt = 0;
  bool _running = false;
  int _requestSeq = 0;

  RelayMonitorState get state => _state;

  /// WS 端点基址（query 逐次构建：relay token 每次交换，60s 有效）。
  /// v1.6.3 PC 实测全链验证：POST /api/v1/remote/token {role:'terminal'}
  /// （Bearer JWT）→ token/expires_in (Map) → ws2?token=relay-token&mid=mid
  /// → auth_init → auth_ack matched → 快照。/ws 是 V1 老端点（V2 令牌 401）。
  static final Uri wsBase = Uri.parse('wss://zcode.z.ai/api/v1/remote/ws2');

  /// 短效 relay 令牌交换端点（60s 有效，每次建连前现换）。
  static final Uri tokenExchangeUrl =
      Uri.parse('https://zcode.z.ai/api/v1/remote/token');

  /// 没有 JWT 时的静默重试间隔。
  static const authRetryDelay = Duration(seconds: 60);

  /// JWT → 短效 relay token（POST /api/v1/remote/token {role:'terminal'}，
  /// PC 实测 200：{code:0, data:{token, expires_in:60}}）。失败返回 null。
  static Future<String?> exchangeRelayToken(String jwt) async {
    try {
      final client = HttpClient();
      final request = await client.postUrl(tokenExchangeUrl);
      request.headers.set('Authorization', 'Bearer $jwt');
      request.headers.set('Content-Type', 'application/json');
      request.add(utf8.encode(jsonEncode({'role': 'terminal'})));
      final response = await request.close().timeout(
        RelayMonitorPolicy.connectTimeout,
      );
      final body = await response.transform(utf8.decoder).join();
      client.close();
      if (response.statusCode != 200) return null;
      final root = jsonDecode(body);
      if (root is! Map || root['code'] != 0) return null;
      final data = root['data'];
      if (data is! Map) return null;
      final token = data['token'];
      if (token is! String || token.isEmpty) return null;
      return token;
    } catch (_) {
      return null;
    }
  }

  /// 组装带 token/mid 的连接地址（与官方页面 `searchParams.set` 逐参对齐）。
  static Uri wsUrlFor({required String token, required String deviceMid}) {
    final query = <String, String>{'token': token};
    final mid = deviceMid.trim();
    if (mid.isNotEmpty) query['mid'] = mid;
    return wsBase.replace(queryParameters: query);
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    _attempt = 0;
    await _connect();
  }

  Future<void> stop() async {
    // 状态先落地：stop 必须立即生效，socket/订阅的收尾异步进行。
    _running = false;
    _teardownTimers();
    _setState(RelayMonitorState.idle);
    unawaited(_closeSocket());
  }

  void _setState(RelayMonitorState next) {
    if (_state == next) return;
    _state = next;
    try {
      onState?.call(deviceId, next);
    } catch (_) {}
  }

  void _teardownTimers() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _poll?.cancel();
    _poll = null;
    _reconnect?.cancel();
    _reconnect = null;
    _waitingWatch?.cancel();
    _waitingWatch = null;
    _authRetry?.cancel();
    _authRetry = null;
  }

  Future<void> _closeSocket() async {
    // 先关 socket（远端尽快看到 close），再撤本地订阅；整条链路对调用方
    // 是"发射后不管"——状态机绝不等待它（broadcast 订阅的 cancel 完成时序
    // 在部分事件循环实现下不可靠，不能挡在状态迁移前面）。
    await _socket?.close();
    _socket = null;
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> _connect() async {
    if (!_running) return;
    _teardownTimers();
    // V2 需要账号 JWT（探针实证：无 token 一律 WRONG_PARAM）。未捕获时不
    // 裸连，静默等 60s 后再读——用户打开一次远控页后令牌就有了。
    final jwt = await tokenProvider();
    if (!_running) return;
    if (jwt == null || jwt.isEmpty) {
      _setState(RelayMonitorState.authMissing);
      _authRetry = Timer(authRetryDelay, _connect);
      return;
    }
    // V2 令牌链（PC 实测）：JWT 换 60s 短效 relay token，ws2 只认后者。
    final relayToken = await relayTokenExchange(jwt);
    if (!_running) return;
    if (relayToken == null) {
      // 交换失败（401=JWT 过期 → 提示重登；网络抖动 → 退避重试）。
      _setState(RelayMonitorState.authMissing);
      _authRetry = Timer(authRetryDelay, _connect);
      return;
    }
    _setState(RelayMonitorState.connecting);
    final socket = _socketFactory();
    try {
      await socket.connect(
        wsUrlFor(token: relayToken, deviceMid: deviceMid),
        RelayMonitorPolicy.connectTimeout,
      );
    } catch (e) {
      AppLog.failure(LogEvent.relayMonitorConnectFailed, e, fields: {
        LogField.device: deviceId.substring(
          0,
          deviceId.length.clamp(0, 8),
        ),
      });
      _scheduleReconnect();
      return;
    }
    _socket = socket;
    _subscription = socket.messages.listen(
      _onMessage,
      onError: (Object _) => _onTransportDown(),
      onDone: _onTransportDown,
    );
    _setState(RelayMonitorState.authenticating);
    try {
      await socket.send(
        jsonEncode(
          RelayMonitorPolicy.authInitMessage(
            deviceSid: deviceSid,
            appVersion: appVersion,
            nowSeconds: _now().millisecondsSinceEpoch ~/ 1000,
          ),
        ),
      );
    } catch (_) {
      _onTransportDown();
    }
    // auth_ack 预算：超时按断线处理（对齐官方 handshakeTimer 的兜底语义）。
    _waitingWatch = Timer(RelayMonitorPolicy.connectTimeout, () {
      if (_state == RelayMonitorState.authenticating) _onTransportDown();
    });
  }

  void _scheduleReconnect() {
    if (!_running) return;
    unawaited(_closeSocket());
    _setState(RelayMonitorState.disconnected);
    final delay = RelayMonitorPolicy.backoff(_attempt);
    _attempt += 1;
    _reconnect = Timer(delay, _connect);
  }

  void _onTransportDown() {
    if (!_running) return;
    _scheduleReconnect();
  }

  void _onMessage(String text) {
    final inbound = RelayMonitorPolicy.parse(text);
    if (inbound == null) return;
    switch (inbound) {
      case RelayAuthAck(:final deviceSid, :final pairStatus):
        if (_state != RelayMonitorState.authenticating) return;
        // sid 不匹配的 ack 不是给这条连接的（多终端同 sid 并存时的串扰防护）。
        if (deviceSid != this.deviceSid) return;
        _attempt = 0;
        if (pairStatus == 'matched') {
          _enterPaired();
        } else {
          _enterWaiting();
        }
      case RelayPairStatusAck(:final pairStatus):
        if (_state == RelayMonitorState.waiting && pairStatus == 'matched') {
          _enterPaired();
        }
      case RelayDataPayload(:final payload):
        if (_state != RelayMonitorState.paired) return;
        _consumeDataPayload(payload);
      case RelayErrorFrame():
        // DEVICE_OFFLINE / INTERNAL 官方也按可恢复处理；其余错误码同样只
        // 触发重连——监控通道没有需要向用户呈现的错误语义。
        _onTransportDown();
      case RelayUnknownFrame():
        break;
    }
  }

  void _enterWaiting() {
    _setState(RelayMonitorState.waiting);
    _startHeartbeat();
    // 官方语义：waiting 30s 没等到 matched 就放弃本轮连接。
    _waitingWatch?.cancel();
    _waitingWatch = Timer(RelayMonitorPolicy.waitingTimeout, () {
      if (_state == RelayMonitorState.waiting) _onTransportDown();
    });
  }

  void _enterPaired() {
    _waitingWatch?.cancel();
    _waitingWatch = null;
    _setState(RelayMonitorState.paired);
    _startHeartbeat();
    _poll?.cancel();
    _requestSnapshot();
    _poll = Timer.periodic(RelayMonitorPolicy.poll, (_) => _requestSnapshot());
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(RelayMonitorPolicy.heartbeat, (_) {
      try {
        _socket?.send(
          jsonEncode(
            RelayMonitorPolicy.pairStatusQueryMessage(
              _now().millisecondsSinceEpoch ~/ 1000,
            ),
          ),
        );
      } catch (_) {
        _onTransportDown();
      }
    });
  }

  void _consumeDataPayload(Map<dynamic, dynamic> payload) {
    final result = payload['result'];
    if (result is Map) {
      onSnapshot?.call(deviceId, result);
    }
  }

  Future<void> _requestSnapshot() async {
    _requestSeq += 1;
    try {
      await _socket?.send(
        jsonEncode(
          RelayMonitorPolicy.workspaceListRequest(
            requestId: 'monitor-$_requestSeq',
            nowSeconds: _now().millisecondsSinceEpoch ~/ 1000,
          ),
        ),
      );
    } catch (_) {
      _onTransportDown();
    }
  }
}

/// 供测试使用的内存版快照提取：从 `result` 里取 tasks 列表（原样）。
@visibleForTesting
List<dynamic>? tasksOfResult(Map<dynamic, dynamic> result) {
  final tasks = result['tasks'];
  return tasks is List ? tasks : null;
}

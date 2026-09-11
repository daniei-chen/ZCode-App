import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'agent_rpc.dart';
import 'command_receipt.dart';
import 'conversation_attachment.dart';
import 'conversation_row.dart';
import 'conversation_subscription.dart';
import 'conversation_update.dart';
import 'relay_channel.dart';
import 'relay_frame.dart';
import 'relay_link.dart';
import 'relay_payloads.dart';
import 'relay_socket.dart';
import 'rpc_assembler.dart';
import '../services/event_observer.dart';

/// 一帧的原始信息，用于协议分析与诊断。
class RelayFrameInfo {
  const RelayFrameInfo({
    required this.seq,
    required this.fragmentIndex,
    required this.fragmentCount,
    required this.messageBytes,
    required this.checksum,
    required this.bytes,
    required this.isAck,
  });

  final int? seq;
  final int fragmentIndex;
  final int fragmentCount;
  final int? messageBytes;
  final String? checksum;

  /// 已 base64 解码的原始字节。
  final List<int> bytes;
  final bool isAck;

  bool get isFragment => fragmentCount > 1;
}

/// 原生 relay 通道的编排层。
///
/// 它做三件事，并且**只**做这三件事：
/// 1. 连上 relay 并完成握手（[RelayChannel]）
/// 2. 取工作区列表 → 打开工作区桥
/// 3. 把 `rpc-frame` 重组后的 JSON 文本原样吐到 [payloads]
///
/// 关键设计：吐出的文本与 WebView 钩子 `zrEvents` 送进来的文本**形状完全相同**
/// ——因为两者本就是同一份帧内容。所以上层的 `SessionStateExtractor` /
/// `TaskIndexExtractor` / `PanelDataExtractor` 可以原样复用，不做第二套解析。
/// 这同时让"原生 vs WebView 交叉校验"成为真正的同类比对，而不是两套解析器互相比。
class RelayBridge {
  RelayBridge({
    required this.link,
    RelaySocketFactory? socketFactory,
    int Function()? clock,
    String Function()? idGenerator,
    RpcAssembler? assembler,
    void Function(String raw)? onRawMessage,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       _newId = idGenerator ?? _defaultId,
       _assembler = assembler ?? RpcAssembler(clock: clock) {
    _channel = RelayChannel(
      link: link,
      socketFactory: socketFactory,
      clock: clock,
      onRawMessage: onRawMessage,
    );
  }

  final RelayLink link;
  final int Function() _clock;
  final String Function() _newId;
  final RpcAssembler _assembler;
  late final RelayChannel _channel;

  final _payloads = StreamController<String>.broadcast();
  final _failures = StreamController<RelayFailure>.broadcast();
  final _frames = StreamController<RelayFrameInfo>.broadcast();
  final _taskSnapshots = StreamController<List<SessionState>>.broadcast();
  final _agentMessages = StreamController<AgentRpc>.broadcast();
  final _agentResponses = StreamController<AgentResponse>.broadcast();
  final _conversationRows = StreamController<List<ConversationRow>>.broadcast();
  final _conversationUpdates = StreamController<ConversationUpdate>.broadcast();

  static int _seq = 0;

  static String _defaultId() =>
      'zr-${_seq++}-${DateTime.now().microsecondsSinceEpoch}';

  RelayWorkspace? _workspace;
  String? _bridgeSessionId;
  int _bridgeGeneration = 0;
  String? _activeTaskId;
  String? _activeWorkspaceKey;
  StreamSubscription<RelayDownlink>? _sub;
  StreamSubscription<RelayFailure>? _failSub;
  bool _started = false;
  Future<void>? _startFuture;
  Future<bool>? _conversationHandshake;
  Future<void> _agentQueue = Future<void>.value();
  final _agentStopSignals = StreamController<Object?>.broadcast();

  /// 组装后的 JSON 文本流（与 WebView `zrEvents` 同形）。
  Stream<String> get payloads => _payloads.stream;

  Stream<RelayPhase> get phases => _channel.phases;

  Stream<RelayFailure> get failures => _failures.stream;

  /// 每一帧的原始字节（协议分析用）。
  Stream<RelayFrameInfo> get frames => _frames.stream;

  /// 任务列表快照（来自 `workspace-list-response` / `workspace-list-updated`）。
  ///
  /// 这是**已经解好的 JSON**，与 WebView 侧 `TaskIndexExtractor` 认识的
  /// `result.tasks[]` 形状完全一致，所以直接复用同一个提取器，不做第二套解析。
  Stream<List<SessionState>> get taskSnapshots => _taskSnapshots.stream;

  RelayPhase get phase => _channel.phase;
  bool get isReady => _channel.isReady;

  RelayWorkspace? get workspace => _workspace;
  String? get bridgeSessionId => _bridgeSessionId;

  /// 桌面端当前打开的会话（引导时拿到；视图状态上报要用它）。
  String? get activeTaskId => _activeTaskId;

  /// 桌面端当前打开的工作区。
  String? get activeWorkspaceKey => _activeWorkspaceKey;

  /// 最近一次非帧负载（诊断用，例如 `workspace-list-updated`）。
  final List<String> recentNonFrameTypes = [];

  /// 诊断计数，用于界面显示"链路是否真在动"。
  int get assembledCount => _assembledCount;
  int _assembledCount = 0;

  /// 启动：握手 → 工作区列表 → 打开桥。
  Future<void> start({String? preferredWorkspaceKey, String? preferredTaskId}) {
    final running = _startFuture;
    if (running != null) return running;
    if (_started) return Future<void>.value();
    _started = true;
    final future = _startInternal(
      preferredWorkspaceKey: preferredWorkspaceKey,
      preferredTaskId: preferredTaskId,
    );
    _startFuture = future;
    return future.whenComplete(() {
      if (!identical(_startFuture, future)) return;
      _startFuture = null;
      if (_channel.phase == RelayPhase.failed ||
          _channel.phase == RelayPhase.closed) {
        _started = false;
      }
    });
  }

  Future<void> _startInternal({
    String? preferredWorkspaceKey,
    String? preferredTaskId,
  }) async {
    try {
      _failSub = _channel.failures.listen(_failures.add);
      _sub = _channel.downlinks.listen(_onDownlink);

      await _channel.connect();

      final bootstrap = await _loadWorkspaces();
      _activeWorkspaceKey = bootstrap?.activeWorkspaceKey;
      _activeTaskId = bootstrap?.activeTaskId;
      final target = _pickWorkspace(bootstrap, preferredWorkspaceKey);
      if (target == null) {
        final err = RelayFailure(
          reason: 'workspace-closed',
          message: '没有可用于远控的工作区',
        );
        if (!_failures.isClosed) _failures.add(err);
        throw StateError(err.reason);
      }

      // 保留 bootstrap 中的真实 path；openWorkspace 只需要 key，但 Agent
      // service 的 workspacePath 参数必须优先使用完整本地路径。
      _workspace = target;
      await openWorkspace(
        target.workspaceKey,
        taskId:
            preferredTaskId ??
            bootstrap?.activeTaskId ??
            bootstrap?.viewState?.activeTaskId,
      );

      if (handshakeConversationOnStart) {
        // 不 await：握手失败不应拖住任务列表（它只影响正文/工具调用）。
        unawaited(handshakeConversation());
      }
    } catch (_) {
      _started = false;
      await stop();
      rethrow;
    }
  }

  /// 是否在开桥后做会话层握手（正文/工具调用的前置）。同步发送，不阻塞。
  bool handshakeConversationOnStart = true;

  /// 选工作区。优先级：显式偏好 → 桌面端当前打开的工作区 → 任一可建桥的。
  ///
  /// 远控只允许访问桌面端当前打开的工作区，所以 `activeWorkspaceKey` 是权威来源；
  /// `workspaces` 列表可能压根不存在（实测 response 里就没有），此时直接以
  /// `activeWorkspaceKey` 为目标。
  RelayWorkspace? _pickWorkspace(RelayBootstrap? b, String? preferred) {
    if (b == null) return null;
    final list = b.workspaces;

    RelayWorkspace? byKey(String k) {
      for (final w in list) {
        if (w.workspaceKey == k) return w;
      }
      return null;
    }

    if (preferred != null) {
      final hit = byKey(preferred);
      if (hit != null) {
        if (hit.canBridge) return hit;
      } else {
        return RelayWorkspace(workspaceKey: preferred, path: preferred);
      }
    }

    final active = b.activeWorkspaceKey;
    if (active != null) {
      final hit = byKey(active);
      if (hit != null) {
        if (hit.canBridge) return hit;
      } else {
        return RelayWorkspace(workspaceKey: active, path: active);
      }
    }

    for (final w in list) {
      if (w.canBridge) return w;
    }
    return null;
  }

  /// 取工作区列表（`workspace-list-request` / 也接受主动推送的 `workspace-list-updated`）。
  Future<RelayBootstrap?> _loadWorkspaces() async {
    final reqId = _newId();
    try {
      final res = await _channel.request(
        RelayUplink.workspaceListRequest(requestId: reqId),
        timeout: const Duration(seconds: 20),
      );
      final result = res['result'] ?? res;
      return RelayBootstrap.tryParse(result);
    } catch (_) {
      // 有些实现只推 workspace-list-updated 而不回 response；
      // 这里退化成等一次主动推送。
      try {
        final pushed = await _channel.awaitType(
          ZcodeType.workspaceListUpdated,
          timeout: const Duration(seconds: 8),
        );
        return RelayBootstrap.tryParse(pushed['result']);
      } catch (_) {
        return null;
      }
    }
  }

  /// 重新拉一次工作区列表（列表本身不保证主动推送，靠这个保持新鲜）。
  Future<void> refreshTasks() async {
    if (!_started) return;
    await _loadWorkspaces();
  }

  /// 调用一个服务方法（`platform-request` / `platform-response`）。
  ///
  /// 实测形状：
  /// `{"zcode_type":"platform-request","requestId":"platform-…","method":"…","args":[…]}`。
  Future<Map<String, dynamic>?> invokePlatform(
    String method, [
    List<dynamic> args = const [],
  ]) async {
    final rid = 'platform-${_newId()}';
    try {
      final res = await _channel.request(
        RelayUplink.platformRequest(requestId: rid, method: method, args: args),
        timeout: const Duration(seconds: 20),
      );
      if (res['success'] == false) {
        lastPlatformError = res['error']?.toString();
        return null;
      }
      lastPlatformError = null;
      final result = res['result'];
      return result is Map ? Map<String, dynamic>.from(result) : null;
    } catch (e) {
      lastPlatformError = e.toString();
      return null;
    }
  }

  /// 最近一次服务方法调用的错误（诊断）。
  String? lastPlatformError;

  /// 打开工作区桥并等 `workspace-bridge-ready`。
  ///
  /// 注意：`workspace-bridge-ready` **不回 `requestId`**，官方是按
  /// `bridgeSessionId` 匹配的（页面实现里的匹配谓词就是
  /// `zcode_type==='workspace-bridge-ready' && bridgeSessionId===n`）。
  /// 所以这里发出去后靠 [RelayChannel.awaitType] 等，而不是走 requestId 配对。
  Future<void> openWorkspace(String workspaceKey, {String? taskId}) async {
    final sessionId = _newId();
    _bridgeGeneration++;
    final reqId = _newId();

    final ready = _channel.awaitType(
      ZcodeType.bridgeReady,
      where: (p) => p['bridgeSessionId'] == sessionId,
      timeout: const Duration(seconds: 25),
    );

    _channel.sendPayload(
      RelayUplink.bridgeOpen(
        requestId: reqId,
        bridgeSessionId: sessionId,
        bridgeGeneration: _bridgeGeneration,
        workspaceKey: workspaceKey,
        taskId: taskId,
      ),
    );

    await ready;

    _bridgeSessionId = sessionId;
    _channel.bridgeSessionId = sessionId;
    // 组装器换一条桥时清空，避免旧槽位污染新桥。
    _assembler.reset();

    _workspace = _workspace?.workspaceKey == workspaceKey
        ? _workspace
        : RelayWorkspace(workspaceKey: workspaceKey);
  }

  /// 上报视图状态（原生版 `/mobile-view-state`）。
  void pushViewState({String? taskId}) {
    final key = _workspace?.workspaceKey;
    if (key == null) return;
    _channel.sendPayload(
      RelayUplink.viewStateUpdate(
        activeWorkspaceKey: key,
        activeTaskId: taskId,
        updatedAt: _clock(),
      ),
    );
  }

  /// 从工作区列表负载里抽出任务快照。
  ///
  /// 复用 WebView 侧的 `TaskIndexExtractor`：它找的 `result.tasks[]` 正是
  /// relay 返回的形状，所以两条通道产出同一套 `SessionState`，
  /// 「原生 vs WebView 交叉校验」才是有意义的同类比对。
  void _maybeEmitTasks(RelayDownlink d) {
    if (d.zcodeType != ZcodeType.workspaceListResponse &&
        d.zcodeType != ZcodeType.workspaceListUpdated) {
      return;
    }
    final tasks = TaskIndexExtractor.parseResultTasksRoot(d.raw);
    if (tasks == null) return;
    _lastTaskCount = tasks.length;
    if (!_taskSnapshots.isClosed) _taskSnapshots.add(tasks);
  }

  /// 最近一次任务快照的条数（诊断）。
  int get lastTaskCount => _lastTaskCount;
  int _lastTaskCount = 0;

  void _onDownlink(RelayDownlink d) {
    final timeoutReason = _assembler.takeTimeoutReason();
    if (timeoutReason != null && !_failures.isClosed) {
      _failures.add(
        RelayFailure(
          reason: timeoutReason,
          message: 'stale rpc-frame assembly evicted',
        ),
      );
    }
    if (!d.isFrame) {
      recentNonFrameTypes.add(d.zcodeType);
      if (recentNonFrameTypes.length > 40) recentNonFrameTypes.removeAt(0);
      _maybeEmitTasks(d);
      return;
    }
    final frame = RpcFrame.tryParse(d.raw);
    if (frame == null) return;

    final cs = d.raw['checksum'];
    if (!_frames.isClosed) {
      _frames.add(
        RelayFrameInfo(
          seq: frame.messageSeq ?? frame.seq,
          fragmentIndex: frame.fragmentIndex,
          fragmentCount: frame.fragmentCount,
          messageBytes: frame.messageBytes,
          checksum: cs is Map ? cs['value']?.toString() : null,
          bytes: WireBase64.tryDecode(frame.dataBase64 ?? '') ?? const <int>[],
          isAck: frame.isAck,
        ),
      );
    }

    final outcome = _assembler.accept(frame);
    switch (outcome) {
      case AssemblyMessage(:final bytes):
        _assembledCount++;
        final buf = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

        // 响应帧（04 02 …）优先——头部与请求不同，别混着解。
        // 桌面端的 seq 是它自己的计数器，不回显我们的请求序号，所以这里
        // 不按 seq 配对；等待者通过 agentResponses 按内容匹配。
        final resp = AgentRpcCodec.tryDecodeResponse(buf);
        if (resp != null) {
          if (!_agentResponses.isClosed) _agentResponses.add(resp);
          _handleResponse(resp);
          _maybeEmitRows(resp);
          return;
        }

        // 请求形态（04 04 …）：桌面端主动推的事件订阅回调。
        final rpc = AgentRpcCodec.tryDecode(buf);
        if (rpc != null) {
          lastAgentMessage = rpc;
          if (!_agentMessages.isClosed) _agentMessages.add(rpc);
          final update = ConversationUpdate.fromAgentRpc(rpc);
          if (update != null && !_conversationUpdates.isClosed) {
            lastRows = update.rows;
            _conversationUpdates.add(update);
          }
          return;
        }

        // 其余按 JSON 文本交给上层（任务列表那类）。
        if (!_payloads.isClosed) {
          _payloads.add(utf8.decode(buf, allowMalformed: true));
        }
      case AssemblyAck():
        break;
      case AssemblyDuplicate():
        break;
      case AssemblyIncomplete():
        break;
      case AssemblyFault(:final reason, :final seq, :final expectedSeq):
        if (!_failures.isClosed) {
          _failures.add(
            RelayFailure(
              reason: reason,
              message: 'seq=$seq expected=$expectedSeq',
            ),
          );
        }
    }
  }

  /// 解出的 agentService RPC（桌面端主动推送）。
  Stream<AgentRpc> get agentMessages => _agentMessages.stream;

  /// 解出的 agentService 响应。
  Stream<AgentResponse> get agentResponses => _agentResponses.stream;

  /// 会话正文行（含工具调用）。
  Stream<List<ConversationRow>> get conversationRowsStream =>
      _conversationRows.stream;

  /// 历史响应与实时推送统一后的会话更新流。
  Stream<ConversationUpdate> get conversationUpdates =>
      _conversationUpdates.stream;

  /// 最近一次正文行（诊断）。
  List<ConversationRow>? lastRows;

  void _maybeEmitRows(AgentResponse resp) {
    if (resp.isError) {
      lastFaultReason = resp.faultReason;
      return;
    }
    final update = ConversationUpdate.fromResponse(resp.value);
    if (update == null) return;
    lastRows = update.rows;
    if (!_conversationRows.isClosed) _conversationRows.add(update.rows);
    if (!_conversationUpdates.isClosed) _conversationUpdates.add(update);
  }

  /// 最近一次 `fault.*` 原因（例如 `fault.connection.clientChanged`）。
  String? lastFaultReason;

  /// 最近一条 agent RPC（诊断）。
  AgentRpc? lastAgentMessage;

  void _handleResponse(AgentResponse resp) {
    final v = resp.value;
    if (v is! Map) return;
    final kind = v['kind'];
    if (kind == 'hello') {
      conversationConnectionId = v['connectionId']?.toString();
      conversationClientMode = v['clientMode']?.toString();
      conversationDeliveryProfile = v['deliveryProfile']?.toString();
      conversationCapabilities = v['capabilities'] is Map
          ? Map<String, dynamic>.from(v['capabilities'] as Map)
          : null;
    }
  }

  /// `helloConversationV4` 的结果。
  String? conversationConnectionId;
  String? conversationClientMode;
  String? conversationDeliveryProfile;
  Map<String, dynamic>? conversationCapabilities;

  /// 上行 agent RPC 序号。
  int _agentSeq = 0;

  /// 取下一个序号。
  int nextAgentSeq() => ++_agentSeq;

  /// 发一条 agentService RPC（自动分配序号），返回所用序号。
  ///
  /// 编码后套进 `rpc-frame`（与官方页面完全同形，含 crc32 校验）。
  int sendAgent(AgentRpc rpc) {
    final sid = _bridgeSessionId;
    if (sid == null) return -1;
    final seq = rpc.seq > 0 ? rpc.seq : nextAgentSeq();
    final encoded = AgentRpc(
      kind: rpc.kind,
      seq: seq,
      service: rpc.service,
      method: rpc.method,
      args: rpc.args,
    );
    final bytes = AgentRpcCodec.encode(encoded);
    final crc = Crc32.of(bytes).toRadixString(16).padLeft(8, '0');
    _channel.sendPayload({
      'zcode_type': ZcodeType.rpcFrame,
      'bridgeSessionId': sid,
      'bridgeGeneration': _bridgeGeneration,
      'checksum': {'algorithm': 'crc32', 'value': crc},
      // ⚠️ 必须是**标准 base64 且带填充**：实测官方上行 117 帧中 86 帧含 `=`、
      // 4 帧含 `+/`、0 帧含 `-_`。用 URL-safe 无填充会被判定 rpc-transport-fault。
      'dataBase64': base64.encode(bytes),
      'fragmentCount': 1,
      'fragmentIndex': 0,
      'messageBytes': bytes.length,
      'messageSeq': seq,
      'seq': seq,
    });
    return seq;
  }

  /// 调一个服务方法（序号自动分配），返回序号。
  ///
  /// 设置能力分布在 skills / hooks / memory 等独立 service 中，不能把
  /// 它们伪装成 zcode-agent。统一从这里发出，方便上层按官方边界请求。
  int callService(String service, String method, List<Object?> args) =>
      sendAgent(
        AgentRpc.call(seq: 0, service: service, method: method, args: args),
      );

  /// 调一个 zcode-agent 方法（序号自动分配），返回序号。
  int callAgent(String method, List<Object?> args) =>
      callService('zcode-agent', method, args);

  /// 会话层握手：`helloConversationV4` → `initializeConversationV4`。
  ///
  /// ⚠️ 两个方法都走**二进制 agentService RPC**，不是 `platform-request`。
  ///
  /// `clientKind` 必须**按 hello 回给我们的 `clientMode` 推导**——官方页面的逻辑是
  /// `clientMode === 'desktop-continuous' ? 'desktop' : 'web'`。
  ///
  /// 响应**不能按 seq 配对**：桌面端回的是它自己的计数器，不回显我们的序号。
  /// 这里按 `kind == 'hello'` 的内容匹配。
  Future<bool> handshakeConversation({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (conversationReady) return true;
    final running = _conversationHandshake;
    if (running != null) return running.then((_) => conversationReady);

    final future = _enqueue<bool>(() async {
      conversationReady = false;
      final helloFuture = _awaitAgentResponse(
        (r) =>
            r.isError ||
            (r.value is Map && (r.value as Map)['kind'] == 'hello'),
        timeout,
      );
      if (callAgent('helloConversationV4', const []) < 0) return false;

      final helloResponse = await helloFuture;
      if (helloResponse == null ||
          helloResponse.isError ||
          helloResponse.value is! Map) {
        return false;
      }
      final hello = Map<String, dynamic>.from(helloResponse.value! as Map);

      conversationConnectionId = hello['connectionId']?.toString();
      conversationClientMode = hello['clientMode']?.toString();
      conversationDeliveryProfile = hello['deliveryProfile']?.toString();
      final caps = hello['capabilities'];
      conversationCapabilities = caps is Map
          ? Map<String, dynamic>.from(caps)
          : null;

      final clientKind = conversationClientMode == 'desktop-continuous'
          ? 'desktop'
          : 'web';
      final initFuture = _awaitAgentResponse(_isInitializeAck, timeout);
      if (callAgent('initializeConversationV4', [
            {
              'kind': 'clientHello',
              'protocolVersion': 3,
              'clientId': 'zr-${_newId()}',
              'clientKind': clientKind,
              'appVersion': link.appVersion ?? 'unknown',
              'capabilities': {'workspaceHookReviewUi': true},
            },
          ]) <
          0) {
        return false;
      }
      final initialized = await initFuture;
      if (initialized == null || initialized.isError) return false;
      conversationReady = true;
      return true;
    });
    _conversationHandshake = future;
    try {
      return await future;
    } finally {
      if (identical(_conversationHandshake, future)) {
        _conversationHandshake = null;
      }
    }
  }

  /// 无法通过请求 seq 关联的 agent RPC 采用 single-flight：同一条 bridge
  /// 同时只允许一个“发出请求→等待内容匹配响应”的操作。
  Future<AgentResponse?> requestAgentResponse(
    String method,
    List<Object?> args, {
    bool Function(AgentResponse response)? where,
    Duration timeout = const Duration(seconds: 25),
    bool priority = false,
  }) => requestServiceResponse(
    'zcode-agent',
    method,
    args,
    where: where,
    timeout: timeout,
    priority: priority,
  );

  /// 调用任意官方 agent service 并等待一条内容匹配的响应。
  /// [priority] bypasses the single-flight queue.  Only callers whose
  /// response predicate is self-correlating (a command receipt matched by
  /// its commandId) may use it, so a stop is never queued behind a slow
  /// read (review P1-4); content-matched reads keep the queue.
  Future<AgentResponse?> requestServiceResponse(
    String service,
    String method,
    List<Object?> args, {
    bool Function(AgentResponse response)? where,
    Duration timeout = const Duration(seconds: 25),
    bool priority = false,
  }) {
    Future<AgentResponse?> run() async {
      final future = _awaitAgentResponse(
        where ?? (r) => r.isError || r.value != null,
        timeout,
      );
      if (callService(service, method, args) < 0) return null;
      return future;
    }

    return priority ? run() : _enqueue(run);
  }

  Future<AgentResponse?> _awaitAgentResponse(
    bool Function(AgentResponse response) where,
    Duration timeout,
  ) async {
    // Every waiter owns its subscription so a timeout cancels it; leaving
    // firstWhere listeners attached leaks one predicate per timed-out
    // request for the lifetime of the bridge (review P2-2).
    final completer = Completer<AgentResponse?>();
    final subscription = agentResponses.listen(
      (response) {
        if (!completer.isCompleted && where(response)) {
          completer.complete(response);
        }
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(null);
      },
    );
    // A socket close must abort the waiter immediately. Otherwise a
    // disconnect can leave the single-flight queue occupied until its
    // normal timeout, delaying the next reconnect's handshake.
    final failureSub = failures.listen((_) {
      if (!completer.isCompleted) completer.complete(null);
    });
    final stopSub = _agentStopSignals.stream.listen((_) {
      if (!completer.isCompleted) completer.complete(null);
    });
    try {
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } catch (_) {
      return null;
    } finally {
      await subscription.cancel();
      await failureSub.cancel();
      await stopSub.cancel();
    }
  }

  static bool _isInitializeAck(AgentResponse response) {
    if (response.isError) return true;
    final value = response.value;
    if (value == null) return true;
    if (value is! Map) return false;
    final kind = value['kind']?.toString().toLowerCase();
    return value['initialized'] == true ||
        value['ok'] == true ||
        value['success'] == true ||
        kind == 'initialized' ||
        kind == 'initialize' ||
        kind == 'ready';
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final result = _agentQueue.then((_) => operation());
    _agentQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// 会话层是否握手完成。
  bool conversationReady = false;

  /// 订阅使用的 `connectionId` / `clientMode`（来自 hello）。
  Map<String, dynamic> get _sessionScope => {
    'connectionId': ?conversationConnectionId,
    'clientMode': ?conversationClientMode,
  };

  /// Scope required by the desktop's native service facade.
  ///
  /// The renderer does not call `sendConversationCommandV4` with the raw
  /// envelope.  It wraps it in the active workspace scope first so the host
  /// can select the correct zcode-agent client.  Omitting this wrapper makes
  /// the relay look connected while every write is rejected as an
  /// unavailable native channel.
  Map<String, dynamic> get _workspaceScope {
    final workspace = _workspace;
    final path = workspace?.path?.trim();
    final key = workspace?.workspaceKey.trim();
    final workspacePath = path != null && path.isNotEmpty
        ? path
        : (key != null && key.isNotEmpty ? key : null);
    final identity = workspace?.identity?.trim();
    return {
      'workspacePath': ?workspacePath,
      'workspaceIdentity': identity != null && identity.isNotEmpty
          ? identity
          : null,
      ..._sessionScope,
    };
  }

  Map<String, dynamic> _workspaceScopeFor(String workspacePath) => {
    ..._workspaceScope,
    'workspacePath': workspacePath,
  };

  /// 订阅某工作区下的会话索引，并等待桌面端 ack。
  ///
  /// 走 single-flight 请求槽位：ack 在本次调用内被消费，不会残留到下一个
  /// 等待者手里（旧实现是 fire-and-forget，其迟到 ack 会被后续请求吃掉）。
  Future<bool> subscribeSessionsIndex(
    String workspacePath, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final response = await requestAgentResponse(
      'subscribeSessionsIndexV4',
      [
        {
          ..._workspaceScopeFor(workspacePath),
          'runtimePolicy': 'existing-only',
        },
      ],
      timeout: timeout,
      where: (r) => r.isError || ConversationSubscriptionAck.matches(r.value),
    );
    return response != null && !response.isError;
  }

  /// 订阅某个会话的实时帧，并等待 `{ack:{subscriptionId,mode,logEpoch}}`。
  ///
  /// 返回 null 表示桌面端没有确认订阅（超时 / 错误 / 通道断开）。调用方
  /// 只有拿到非 null 的 ack 才允许把会话标为“已订阅”。
  Future<ConversationSubscriptionAck?> subscribeConversation({
    required String workspacePath,
    required String sessionId,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final response = await requestAgentResponse(
      'subscribeConversationV4',
      [
        {..._workspaceScopeFor(workspacePath), 'sessionId': sessionId},
      ],
      timeout: timeout,
      where: (r) => r.isError || ConversationSubscriptionAck.matches(r.value),
    );
    if (response == null || response.isError) {
      lastFaultReason = response?.faultReason ?? lastFaultReason;
      return null;
    }
    return ConversationSubscriptionAck.tryParse(response.value);
  }

  /// 会话命令的类型。
  ///
  /// 实测命令信封：
  /// `{commandId, clientId, sessionId, baseRevision?, baseLogEpoch?, type, payload, issuedAt}`
  /// ⚠️ CAS 命令（applyFileRewind / forkAssistant / editUserQuery / retryTurn /
  /// setAssistantFeedback）**必须带 baseRevision**；row target 命令须带 baseLogEpoch。
  /// `resolveInteraction` 两者都不需要。
  Map<String, dynamic> _conversationCommandEnvelope({
    required String? sessionId,
    required String type,
    required Map<String, dynamic> payload,
    String? commandId,
  }) {
    _commandSeq++;
    return {
      // A caller-supplied id lets a retry reuse the same commandId so the
      // desktop answers `duplicate` instead of applying the write twice.
      'commandId': commandId ?? 'zr-cmd-${_newId()}-$_commandSeq',
      'clientId': _clientId,
      'sessionId': sessionId,
      'type': type,
      'payload': payload,
      'issuedAt': _clock(),
    };
  }

  /// Send a command and wait for the matching v4 receipt.
  ///
  /// The desktop response counter is independent from the mobile request
  /// counter, so the command id is the only safe correlation key here.
  Future<Map<String, dynamic>?> sendConversationCommandReceipt({
    required String? sessionId,
    required String type,
    Map<String, dynamic> payload = const {},
    Duration timeout = const Duration(seconds: 20),
    String? commandId,
  }) async {
    final command = _conversationCommandEnvelope(
      sessionId: sessionId,
      type: type,
      payload: payload,
      commandId: commandId,
    );
    final id = command['commandId']!.toString();
    final response = await requestAgentResponse(
      'sendConversationCommandV4',
      [
        {..._workspaceScope, 'envelope': command},
      ],
      timeout: timeout,
      priority: true,
      where: (r) {
        if (r.isError) return true;
        final value = r.value;
        return value is Map && value['commandId']?.toString() == id;
      },
    );
    if (response == null || response.isError || response.value is! Map) {
      lastCommandReceipt = null;
      _lastReceiptSessionId = null;
      return null;
    }
    final map = Map<String, dynamic>.from(response.value! as Map);
    lastCommandReceipt = CommandReceipt.tryParse(map);
    _lastReceiptSessionId = sessionId;
    return map;
  }

  /// Which session the [lastCommandReceipt] belongs to; refusal copy must
  /// not cross sessions (review P2-3).
  String? _lastReceiptSessionId;

  /// Typed variant of [sendConversationCommandReceipt].  Returns null when
  /// no receipt arrived or the response was not a recognised receipt shape.
  Future<CommandReceipt?> sendCommand({
    required String? sessionId,
    required String type,
    Map<String, dynamic> payload = const {},
    Duration timeout = const Duration(seconds: 20),
    String? commandId,
  }) async {
    await sendConversationCommandReceipt(
      sessionId: sessionId,
      type: type,
      payload: payload,
      timeout: timeout,
      commandId: commandId,
    );
    return lastCommandReceipt;
  }

  /// The most recent parsed receipt (any command).  UI uses `reasonCode` /
  /// `message` to explain a refusal instead of a generic banner.
  CommandReceipt? lastCommandReceipt;

  /// Receipt for the given session only, or any when [sessionId] is null.
  CommandReceipt? receiptFor(String? sessionId) => sessionId == null
      ? lastCommandReceipt
      : (_lastReceiptSessionId == sessionId ? lastCommandReceipt : null);

  int _commandSeq = 0;
  late final String _clientId = 'zr-client-${_newId()}';

  /// 批准 / 拒绝一次待处理交互。
  ///
  /// [optionId] 来自 `permission` 行的 `options[]`；[action] 用于没有选项的场合
  /// （`accept` / `decline` / `cancel`）。
  ///
  /// ⚠️ 这是**写操作**：会真实改变桌面端状态。UI 必须由用户明确触发，
  /// 不做静默自动批准（见 docs/COMPLIANCE.md）。
  Future<bool> resolveInteraction({
    required String sessionId,
    required String interactionId,
    String? optionId,
    String? action,
  }) async {
    final receipt = await sendConversationCommandReceipt(
      sessionId: sessionId,
      type: 'resolveInteraction',
      payload: {
        'interactionId': interactionId,
        'answer': {'optionId': ?optionId, 'action': ?action},
      },
    );
    return _commandAccepted(receipt);
  }

  /// 中止当前执行，并等待桌面端确认命令已接收。
  Future<bool> stopConversation(String sessionId) async {
    final receipt = await sendConversationCommandReceipt(
      sessionId: sessionId,
      type: 'stop',
      payload: {},
    );
    return _commandAccepted(receipt);
  }

  /// 发送一条用户消息。官方 v4 命令类型是 `sendText`，不是旧版页面里
  /// 使用过的 `sendMessage`。等待桌面端的 command receipt，只有明确收到
  /// `accepted` / `noop` 才告诉上层成功，避免 UI 出现“已发送但桌面端没收到”。
  /// 该命令会真实改变桌面会话，调用方必须由用户明确点击发送触发。
  Future<bool> sendConversationMessage({
    required String sessionId,
    required String text,
    List<ConversationAttachment> attachments = const [],
    String? commandId,
  }) async {
    final refs = <Map<String, dynamic>>[];
    for (final attachment in attachments) {
      if (attachment.bytes.length > 20 * 1024 * 1024) return false;
      final ref = await _uploadAttachment(
        sessionId: sessionId,
        attachment: attachment,
      );
      if (ref == null) return false;
      refs.add(ref);
    }

    final payload = <String, dynamic>{
      'text': text,
      'requestedDelivery': 'startNow',
      'heldQueueDisposition': 'keepQueueAndSend',
      if (refs.isNotEmpty) 'attachments': refs,
    };
    final receipt = await sendConversationCommandReceipt(
      sessionId: sessionId,
      type: 'sendText',
      payload: payload,
      commandId: commandId,
    );
    if (receipt == null) return false;
    if (_commandAccepted(receipt)) return true;
    // Older v4 relay builds returned the result object without the outer
    // receipt status. Accept only the documented input acknowledgement shape.
    return receipt['type'] == 'inputAccepted';
  }

  static bool _commandAccepted(Map<String, dynamic>? receipt) =>
      CommandReceipt.tryParse(receipt)?.isSuccess ?? false;

  Future<Map<String, dynamic>?> _attachmentCall(
    String method,
    Map<String, dynamic> payload,
  ) async {
    final response = await requestAgentResponse(
      method,
      [
        {..._workspaceScope, ...payload},
      ],
      timeout: const Duration(seconds: 30),
      where: (r) => r.isError || r.value is Map,
    );
    if (response == null || response.isError || response.value is! Map) {
      return null;
    }
    return Map<String, dynamic>.from(response.value! as Map);
  }

  /// Upload one user-selected file using attachmentBegin/Chunk/Commit v4.
  /// The file is never read from a path here; callers provide the selected
  /// bytes explicitly, keeping permission and upload scope visible.
  Future<Map<String, dynamic>?> _uploadAttachment({
    required String sessionId,
    required ConversationAttachment attachment,
  }) async {
    final connectionId = conversationConnectionId;
    if (connectionId == null || connectionId.isEmpty) return null;

    const chunkSize = 256 * 1024;
    final bytes = attachment.bytes;
    final totalChunks = (bytes.length + chunkSize - 1) ~/ chunkSize;
    final uploadId = 'zr-upload-${_newId()}';
    final common = <String, dynamic>{
      'connectionId': connectionId,
      'sessionId': sessionId,
      'uploadId': uploadId,
    };
    final begin = await _attachmentCall('attachmentBeginV4', {
      ...common,
      'fileName': attachment.fileName,
      'mime': attachment.mime,
      'totalBytes': bytes.length,
      'totalChunks': totalChunks,
      'checksum': sha256.convert(bytes).toString(),
    });
    if (begin == null) return null;

    final state = begin['state']?.toString();
    if (state == 'committed') return _asAttachmentRef(begin['ref']);
    if (state != 'staging') return null;
    var next = begin['nextChunkIndex'] is num
        ? (begin['nextChunkIndex'] as num).toInt()
        : 0;
    if (next < 0 || next > totalChunks) return null;

    for (var index = next; index < totalChunks; index++) {
      final start = index * chunkSize;
      final end = (start + chunkSize).clamp(0, bytes.length);
      final chunk = bytes.sublist(start, end);
      final result = await _attachmentCall('attachmentChunkV4', {
        ...common,
        'chunkIndex': index,
        'dataBase64': base64.encode(chunk),
      });
      if (result == null) return null;
      final serverNext = result['nextChunkIndex'];
      if (serverNext is! num || serverNext.toInt() != index + 1) return null;
      next = serverNext.toInt();
    }

    final committed = await _attachmentCall('attachmentCommitV4', common);
    return committed == null ? null : _asAttachmentRef(committed['ref']);
  }

  static Map<String, dynamic>? _asAttachmentRef(Object? value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value is String && value.isNotEmpty) return {'ref': value};
    return null;
  }

  /// Create a new native session with its first user input.
  ///
  /// The returned id comes only from the desktop's `createSession` receipt;
  /// this prevents the mobile UI from opening a phantom local conversation.
  Future<String?> createConversation({
    required String workspaceId,
    required String text,
    String? providerId,
    String? modelId,
    String? thoughtLevel,
    String? commandId,
  }) async {
    final config = <String, dynamic>{
      if (providerId != null && providerId.trim().isNotEmpty)
        'provider': providerId,
      if (modelId != null && modelId.trim().isNotEmpty) 'model': modelId,
      if (thoughtLevel != null && thoughtLevel.trim().isNotEmpty)
        'thought': thoughtLevel,
    };
    final receipt = await sendConversationCommandReceipt(
      sessionId: null,
      type: 'createSession',
      commandId: commandId,
      payload: {
        'workspaceId': workspaceId,
        'firstInput': {'text': text},
        'config': config,
      },
    );
    if (receipt == null) return null;
    final result = receipt['result'];
    if (result is Map && result['type']?.toString() == 'createSession') {
      final id = result['sessionId']?.toString();
      if (id != null && id.isNotEmpty) return id;
    }
    final id = receipt['sessionId']?.toString();
    return id == null || id.isEmpty ? null : id;
  }

  /// Change the model/thought pair through the verified v4 command schema.
  Future<bool> switchModelConfig({
    required String sessionId,
    required String providerId,
    required String modelId,
    required String thoughtLevel,
  }) async {
    final receipt = await sendConversationCommandReceipt(
      sessionId: sessionId,
      type: 'switchModelConfig',
      payload: {
        'provider': providerId,
        'model': modelId,
        'thought': thoughtLevel,
      },
    );
    return _commandAccepted(receipt);
  }

  Future<void> stop() async {
    if (!_agentStopSignals.isClosed) _agentStopSignals.add(null);
    await _sub?.cancel();
    await _failSub?.cancel();
    _sub = null;
    _failSub = null;
    await _channel.close();
    _started = false;
    conversationReady = false;
    _conversationHandshake = null;
  }

  void dispose() {
    if (!_agentStopSignals.isClosed) {
      _agentStopSignals.add(null);
      _agentStopSignals.close();
    }
    _channel.dispose();
    _payloads.close();
    _failures.close();
    _frames.close();
    _taskSnapshots.close();
    _agentMessages.close();
    _agentResponses.close();
    _conversationRows.close();
    _conversationUpdates.close();
  }

  /// 便捷：把文本安全解析成 Map（解析失败返回 null）。
  static Map<String, dynamic>? asMap(String text) {
    try {
      final v = jsonDecode(text);
      return v is Map ? Map<String, dynamic>.from(v) : null;
    } catch (_) {
      return null;
    }
  }
}

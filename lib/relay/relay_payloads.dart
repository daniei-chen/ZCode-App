/// relay 上行消息构造与下行消息解析（Model B：单条 WS）。
///
/// 这些 `zcode_type` 字面量取自桌面端/手机页面的协议实现，涉及：
/// 工作区列表、工作区桥、视图状态上报、以及 `rpc-frame` 数据传输。
library;

/// 客户端类型。官方枚举里**已包含 `mobileApp`**，即原生 App 是被预期的形态。
abstract final class ClientKind {
  static const String desktop = 'desktop';
  static const String web = 'web';
  static const String mobileRemote = 'mobileRemote';
  static const String mobileApp = 'mobileApp';
}

/// 会话层服务方法名（通过 `platform-request` 调用）。
abstract final class ConversationMethod {
  /// 取服务端能力（含 `capabilities.binaryFrames`）。
  static const String hello = 'helloConversationV4';

  /// 声明客户端身份与能力。
  static const String initialize = 'initializeConversationV4';

  /// 会话数据帧。
  static const String frame = 'v4/conversation/frame';
}

/// 主题名构造。会话主题形如 `conversation/<sessionId>`。
abstract final class RelayTopic {
  static const String conversationPrefix = 'conversation/';
  static const String sessionsIndexPrefix = 'sessions-index/';

  static String conversation(String sessionId) =>
      '$conversationPrefix$sessionId';

  static String sessionsIndex(String workspaceIdentity) =>
      '$sessionsIndexPrefix$workspaceIdentity';

  /// 从主题里取会话 id；非法返回 null。
  static String? sessionIdOf(String topic) {
    if (!topic.startsWith(conversationPrefix)) return null;
    final id = topic.substring(conversationPrefix.length);
    return id.isEmpty ? null : id;
  }
}

/// 上行/下行的 `zcode_type` 常量。
abstract final class ZcodeType {
  // 工作区列表
  static const String workspaceListRequest = 'workspace-list-request';
  static const String workspaceListResponse = 'workspace-list-response';
  static const String workspaceListUpdated = 'workspace-list-updated';

  // 工作区桥
  static const String bridgeOpen = 'workspace-bridge-open';
  static const String bridgeReady = 'workspace-bridge-ready';
  static const String bridgeError = 'workspace-bridge-error';
  static const String bridgeDegraded = 'bridge-degraded';
  static const String workspaceReconnect = 'workspace-reconnect';

  // 视图状态
  static const String viewStateUpdate = 'mobile-view-state-update';

  // 通用
  static const String appError = 'app-error';

  // 通用 RPC / 会话层
  static const String platformRequest = 'platform-request';
  static const String platformResponse = 'platform-response';

  // 传输
  static const String rpcFrame = 'rpc-frame';
  static const String rpcFrameAck = 'rpc-frame-ack';

  /// 下行里表示"出错了"的类型集合。
  static const Set<String> failureTypes = {
    bridgeError,
    bridgeDegraded,
    appError,
  };
}

/// 上行消息构造。全部是纯函数，便于单测。
abstract final class RelayUplink {
  /// 握手第一步。手机端固定 role=`terminal`。
  static Map<String, dynamic> authInit({
    required String deviceSid,
    required int clientTs,
    String? appVersion,
    String clientKind = ClientKind.mobileApp,
  }) => {
    'type': 'auth_init',
    'role': 'terminal',
    'device_sid': deviceSid,
    'meta': {
      'platform': _platformName,
      'version': appVersion ?? 'unknown',
      'name': clientKind,
    },
    'client_ts': clientTs,
  };

  /// 握手第二步，携带 HMAC proof。
  static Map<String, dynamic> authResponse({
    required String deviceSid,
    required String proof,
    required int clientTs,
  }) => {
    'type': 'auth_response',
    'device_sid': deviceSid,
    'proof': proof,
    'client_ts': clientTs,
  };

  /// 心跳：查询配对状态。
  static Map<String, dynamic> pairStatusQuery({
    required String deviceSid,
    required int clientTs,
  }) => {
    'type': 'pair_status_query',
    'device_sid': deviceSid,
    'client_ts': clientTs,
  };

  /// 请求工作区列表（走 RPC 请求/响应配对）。
  static Map<String, dynamic> workspaceListRequest({
    required String requestId,
  }) => {'zcode_type': ZcodeType.workspaceListRequest, 'requestId': requestId};

  /// 打开工作区桥。
  static Map<String, dynamic> bridgeOpen({
    required String requestId,
    required String bridgeSessionId,
    required int bridgeGeneration,
    required String workspaceKey,
    String? taskId,
    String? recoveryId,
  }) => {
    'zcode_type': ZcodeType.bridgeOpen,
    'requestId': requestId,
    'bridgeSessionId': bridgeSessionId,
    if (bridgeGeneration > 0) 'bridgeGeneration': bridgeGeneration,
    'recoveryId': ?recoveryId,
    'workspaceKey': workspaceKey,
    if (taskId != null && taskId.isNotEmpty) 'taskId': taskId,
  };

  /// 上报视图状态。等价于 WebView 那条 `/mobile-view-state` POST。
  static Map<String, dynamic> viewStateUpdate({
    required String activeWorkspaceKey,
    String? activeTaskId,
    required int updatedAt,
    Map<String, dynamic>? deviceInfo,
  }) => {
    'zcode_type': ZcodeType.viewStateUpdate,
    'viewState': {
      'activeWorkspaceKey': activeWorkspaceKey,
      if (activeTaskId != null && activeTaskId.isNotEmpty)
        'activeTaskId': activeTaskId,
      'updatedAt': updatedAt,
    },
    'deviceInfo': ?deviceInfo,
  };

  /// 请求重连既有工作区桥。
  static Map<String, dynamic> workspaceReconnect({
    required String requestId,
    required String bridgeSessionId,
    required int bridgeGeneration,
    required String workspaceKey,
  }) => {
    'zcode_type': ZcodeType.workspaceReconnect,
    'requestId': requestId,
    'bridgeSessionId': bridgeSessionId,
    'bridgeGeneration': bridgeGeneration,
    'workspaceKey': workspaceKey,
  };

  /// 通用服务方法调用。
  ///
  /// 实测形状（页面里 `requestAppPayload` 的用法）：
  /// ```json
  /// {"zcode_type":"platform-request","requestId":"platform-…",
  ///  "method":"helloConversationV4","args":[]}
  /// ```
  /// 响应为 `{zcode_type:'platform-response', requestId, method, success, result}`。
  static Map<String, dynamic> platformRequest({
    required String requestId,
    required String method,
    List<dynamic> args = const [],
  }) => {
    'zcode_type': ZcodeType.platformRequest,
    'requestId': requestId,
    'method': method,
    'args': args,
  };

  /// `initializeConversationV4` 的入参。
  ///
  /// **关键**：这里**不声明** `binaryFrames`。页面同样只声明
  /// `workspaceHookReviewUi`，因此服务端会推送可被 JSON 解析的帧；
  /// 不初始化就会收到未协商的二进制控制帧（实测 `04 01 06 c8 01 00`）。
  static Map<String, dynamic> clientHello({
    required String clientId,
    required String appVersion,
    String clientKind = ClientKind.mobileApp,
    bool workspaceHookReviewUi = true,
  }) => {
    'kind': 'clientHello',
    'protocolVersion': 3,
    'clientId': clientId,
    'clientKind': clientKind,
    'appVersion': appVersion,
    'capabilities': {'workspaceHookReviewUi': workspaceHookReviewUi},
  };

  /// 订阅某个主题。
  static Map<String, dynamic> subscribe({
    required String topic,
    String? logEpoch,
    int? seq,
    String visibility = 'foreground',
  }) => {
    'topic': topic,
    'base': ?(logEpoch == null && seq == null
        ? null
        : {'logEpoch': ?logEpoch, 'seq': ?seq}),
    'visibility': visibility,
  };

  static const String _platformName = 'android';
}

/// 下行里我们关心的形状。
class RelayWorkspace {
  const RelayWorkspace({
    required this.workspaceKey,
    this.path,
    this.name,
    this.identity,
    this.kind,
    this.remoteSessionId,
  });

  final String workspaceKey;
  final String? path;
  final String? name;
  final String? identity;
  final String? kind;
  final String? remoteSessionId;

  /// 只有 `kind != 'remote'` 或带 identity+remoteSessionId 时才能建桥。
  bool get canBridge =>
      kind != 'remote' || (identity != null && remoteSessionId != null);

  static RelayWorkspace? tryParse(dynamic node) {
    if (node is! Map) return null;
    final key = node['workspaceKey'] ?? node['key'] ?? node['identity'];
    if (key is! String || key.isEmpty) return null;
    String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
    return RelayWorkspace(
      workspaceKey: key,
      path: str(node['path']),
      name: str(node['name']) ?? str(node['displayName']),
      identity: str(node['workspaceIdentity']) ?? str(node['identity']),
      kind: str(node['kind']),
      remoteSessionId: str(node['remoteSessionId']),
    );
  }

  static List<RelayWorkspace> parseList(dynamic node) {
    if (node is! List) return const [];
    final out = <RelayWorkspace>[];
    for (final e in node) {
      final w = tryParse(e);
      if (w != null) out.add(w);
    }
    return out;
  }
}

/// 视图状态（手机在桌面端"正在看哪"）。
class RelayViewState {
  const RelayViewState({
    this.activeWorkspaceKey,
    this.activeTaskId,
    this.updatedAt,
  });

  final String? activeWorkspaceKey;
  final String? activeTaskId;
  final int? updatedAt;

  static RelayViewState? tryParse(dynamic node) {
    if (node is! Map) return null;
    String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
    final at = node['updatedAt'];
    return RelayViewState(
      activeWorkspaceKey: str(node['activeWorkspaceKey']),
      activeTaskId: str(node['activeTaskId']),
      updatedAt: at is int ? at : (at is num ? at.toInt() : null),
    );
  }
}

/// 工作区桥引导的结果。
///
/// 实测 `workspace-list-response` 的 `result` 形状：
/// ```json
/// { "activeTaskId": "sess_…", "activeWorkspaceKey": "D:\\工作\\工作1",
///   "tasks": [ { "taskId":"sess_…", "title":"…", "displayStatus":"running",
///                "workspaceKind":"local", "workspaceLabel":"工作1",
///                "workspacePath":"D:\\工作\\工作1", "provider":"glm",
///                "createdAt":…, "updatedAt":… } ] }
/// ```
/// 注意：**没有独立的 `workspaces` 数组**，工作区要从 `tasks[]` 里归并出来，
/// 当前打开的工作区由顶层 `activeWorkspaceKey` 给出。
class RelayBootstrap {
  const RelayBootstrap({
    this.workspaces = const [],
    this.tasks = const [],
    this.viewState,
    this.activeWorkspaceKey,
    this.activeTaskId,
  });

  final List<RelayWorkspace> workspaces;
  final List<dynamic> tasks;
  final RelayViewState? viewState;

  /// 桌面端当前打开的工作区 —— 远控只允许访问它。
  final String? activeWorkspaceKey;
  final String? activeTaskId;

  static String? _str(Object? v) =>
      v is String && v.trim().isNotEmpty ? v.trim() : null;

  /// 从 `workspace-list-response` / `workspace-list-updated` 的 `result` 解析。
  static RelayBootstrap? tryParse(dynamic node) {
    if (node is! Map) return null;
    final map = Map<String, dynamic>.from(node);

    final tasks = map['tasks'];
    var ws = RelayWorkspace.parseList(map['workspaces']);
    if (ws.isEmpty) ws = _deriveWorkspaces(tasks);

    final vs =
        RelayViewState.tryParse(map['mobileViewState']) ??
        RelayViewState.tryParse(map['initialViewState']);

    final activeKey = _str(map['activeWorkspaceKey']) ?? vs?.activeWorkspaceKey;
    final activeTask = _str(map['activeTaskId']) ?? vs?.activeTaskId;

    if (ws.isEmpty && tasks == null && vs == null && activeKey == null) {
      return null;
    }
    return RelayBootstrap(
      workspaces: ws,
      tasks: tasks is List ? tasks : const [],
      viewState: vs,
      activeWorkspaceKey: activeKey,
      activeTaskId: activeTask,
    );
  }

  /// 从任务列表归并出工作区（按 path → label 去重，保留首次出现顺序）。
  static List<RelayWorkspace> _deriveWorkspaces(dynamic tasks) {
    if (tasks is! List) return const [];
    final seen = <String, RelayWorkspace>{};
    for (final t in tasks) {
      if (t is! Map) continue;
      final path = _str(t['workspacePath']) ?? _str(t['workspaceKey']);
      if (path == null) continue;
      if (seen.containsKey(path)) continue;
      seen[path] = RelayWorkspace(
        workspaceKey: path,
        path: path,
        name: _str(t['workspaceLabel']),
        kind: _str(t['workspaceKind']),
        identity: _str(t['workspaceIdentity']),
        remoteSessionId: _str(t['remoteSessionId']),
      );
    }
    return seen.values.toList(growable: false);
  }
}

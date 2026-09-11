/// Layered readiness for a native Relay device.
///
/// The previous implementation collapsed four independent layers into one
/// `isLive` boolean, which is why the UI could show "已连接" while the desktop
/// had not yet completed the agent handshake or acknowledged the session
/// subscription.  Every boolean the UI needs must be derived from these
/// enums, never inferred from a single flag.
library;

/// Relay WebSocket + bridge lifecycle.
enum TransportPhase {
  idle,
  connecting,
  relayReady,
  failed,
  retrying,
  unsupported,
}

/// `helloConversationV4` → `initializeConversationV4` handshake.
enum AgentPhase { notStarted, handshaking, ready, unavailable }

/// Workspace / task index bootstrap.
enum WorkspacePhase { unknown, loading, ready, empty, error }

/// Per-session subscription (`subscribeConversationV4` ack).
enum ConversationPhase {
  /// No session selected (draft) or not yet attempted.
  none,
  subscribing,

  /// Desktop returned `ack.subscriptionId`.
  acked,
  failed,
}

/// Which layer produced the most recent failure.  Used for actionable copy.
enum NativeLayer { transport, agent, workspace, conversation }

class NativeLayerFailure {
  const NativeLayerFailure({
    required this.layer,
    this.method,
    this.code,
    this.safeMessage,
  });

  final NativeLayer layer;
  final String? method;

  /// Machine code such as `fault.method_not_found` or a receipt reasonCode.
  final String? code;

  /// Sanitised message; never a raw payload.
  final String? safeMessage;

  @override
  String toString() =>
      'NativeLayerFailure(${layer.name}${method == null ? '' : ' $method'}'
      '${code == null ? '' : ' $code'})';
}

class NativeBootstrapState {
  const NativeBootstrapState({
    this.transport = TransportPhase.idle,
    this.agent = AgentPhase.notStarted,
    this.workspace = WorkspacePhase.unknown,
    this.conversation = ConversationPhase.none,
    this.connectionEpoch = 0,
    this.lastSuccessAt,
    this.lastFailure,
    this.subscriptionId,
  });

  final TransportPhase transport;
  final AgentPhase agent;
  final WorkspacePhase workspace;
  final ConversationPhase conversation;

  /// Incremented every time the bridge is rebuilt.  Results carrying an
  /// older epoch must be dropped by consumers.
  final int connectionEpoch;
  final int? lastSuccessAt;
  final NativeLayerFailure? lastFailure;
  final String? subscriptionId;

  bool get relayReady => transport == TransportPhase.relayReady;
  bool get agentReady => agent == AgentPhase.ready;
  bool get workspaceResolved => workspace == WorkspacePhase.ready;
  bool get conversationReady => conversation == ConversationPhase.acked;

  /// Draft mode can create a session as soon as transport + agent +
  /// workspace are ready; there is no subscription yet.
  bool get draftCreateReady => relayReady && agentReady && workspaceResolved;

  /// Sending into an existing session additionally requires the ack.
  bool get canSend => draftCreateReady && conversationReady;

  /// Mirrors the old `isLive` for transport only.  Not sufficient to send.
  bool get transportLive => relayReady;

  /// Copy describing the same device on a new connection epoch: everything
  /// below transport resets because the bridge is new.
  NativeBootstrapState nextEpoch(int epoch) => NativeBootstrapState(
    transport: TransportPhase.connecting,
    connectionEpoch: epoch,
    lastSuccessAt: lastSuccessAt,
  );

  NativeBootstrapState copyWith({
    TransportPhase? transport,
    AgentPhase? agent,
    WorkspacePhase? workspace,
    ConversationPhase? conversation,
    int? connectionEpoch,
    int? lastSuccessAt,
    Object? lastFailure = _keep,
    Object? subscriptionId = _keep,
  }) => NativeBootstrapState(
    transport: transport ?? this.transport,
    agent: agent ?? this.agent,
    workspace: workspace ?? this.workspace,
    conversation: conversation ?? this.conversation,
    connectionEpoch: connectionEpoch ?? this.connectionEpoch,
    lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
    lastFailure: identical(lastFailure, _keep)
        ? this.lastFailure
        : lastFailure as NativeLayerFailure?,
    subscriptionId: identical(subscriptionId, _keep)
        ? this.subscriptionId
        : subscriptionId as String?,
  );

  /// The single most useful status line, from the lowest unready layer.
  NativeStatusKind get status {
    switch (transport) {
      case TransportPhase.unsupported:
        return NativeStatusKind.unsupported;
      case TransportPhase.failed:
        return NativeStatusKind.transportFailed;
      case TransportPhase.idle:
      case TransportPhase.connecting:
        return NativeStatusKind.connecting;
      case TransportPhase.retrying:
        return NativeStatusKind.reconnecting;
      case TransportPhase.relayReady:
        break;
    }
    switch (agent) {
      case AgentPhase.unavailable:
        return NativeStatusKind.agentUnavailable;
      case AgentPhase.notStarted:
      case AgentPhase.handshaking:
        return NativeStatusKind.agentHandshaking;
      case AgentPhase.ready:
        break;
    }
    switch (workspace) {
      case WorkspacePhase.error:
        return NativeStatusKind.workspaceError;
      case WorkspacePhase.empty:
        return NativeStatusKind.workspaceEmpty;
      case WorkspacePhase.unknown:
      case WorkspacePhase.loading:
        return NativeStatusKind.workspaceLoading;
      case WorkspacePhase.ready:
        break;
    }
    switch (conversation) {
      case ConversationPhase.none:
        return NativeStatusKind.draftReady;
      case ConversationPhase.subscribing:
        return NativeStatusKind.sessionSubscribing;
      case ConversationPhase.failed:
        return NativeStatusKind.sessionSubscribeFailed;
      case ConversationPhase.acked:
        return NativeStatusKind.sessionReady;
    }
  }

  @override
  String toString() =>
      'NativeBootstrapState(epoch=$connectionEpoch t=${transport.name} '
      'a=${agent.name} w=${workspace.name} c=${conversation.name})';
}

const Object _keep = Object();

/// One line the UI can show.  Each value maps to a specific layer so the
/// generic "原生通道已连接" copy can never cover an unready layer again.
enum NativeStatusKind {
  connecting,
  reconnecting,
  transportFailed,
  unsupported,
  agentHandshaking,
  agentUnavailable,
  workspaceLoading,
  workspaceEmpty,
  workspaceError,
  draftReady,
  sessionSubscribing,
  sessionSubscribeFailed,
  sessionReady;

  bool get isRetryable =>
      this == transportFailed ||
      this == reconnecting ||
      this == agentUnavailable ||
      this == workspaceError ||
      this == sessionSubscribeFailed;

  /// Chinese copy for the status pill.  Kept here (not in the ARB) so the
  /// mapping from layer to text is testable without a widget tree.
  String get labelZh => switch (this) {
    connecting => '正在连接桌面端',
    reconnecting => '连接中断，正在自动重连',
    transportFailed => '连接失败，可重试',
    unsupported => '设备不支持 native Relay',
    agentHandshaking => '已连接，正在初始化 Agent',
    agentUnavailable => 'Agent 初始化失败，可重试',
    workspaceLoading => '已连接，正在读取工作区',
    workspaceEmpty => '桌面端没有打开的工作区',
    workspaceError => '工作区读取失败，可重试',
    draftReady => '可以开始新对话',
    sessionSubscribing => '正在订阅会话',
    sessionSubscribeFailed => '会话订阅失败，可重试',
    sessionReady => '会话已就绪',
  };
}

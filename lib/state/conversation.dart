import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../native/bootstrap/native_bootstrap_state.dart';
import '../relay/conversation_row.dart';
import 'conversation_reducer.dart';
import '../relay/conversation_update.dart';
import '../relay/conversation_attachment.dart';
import 'relay_source.dart';
import 'conversation_config.dart';

/// 工具分组开关。
///
/// 与官方设置一一对应（`setting.get` 的三个键）：
/// `toolGroupingExploreEnabled` / `toolGroupingTerminalEnabled` /
/// `toolGroupingChangesEnabled`。
///
/// 语义：开关打开时才把**连续的同类工具**并成一组；关闭则逐个显示。
/// 未归类的工具（MCP、Task 等）不受开关影响，始终可并组。
class ConversationGrouping {
  const ConversationGrouping({
    this.explore = true,
    this.terminal = true,
    this.changes = true,
  });

  final bool explore;
  final bool terminal;
  final bool changes;

  static const _exploreTools = {
    'Read',
    'Glob',
    'Grep',
    'WebFetch',
    'WebSearch',
    'web_search',
    'ReadSessionContext',
    'TodoRead',
    'GoalRead',
    'TaskOutput',
  };
  static const _terminalTools = {'Bash', 'Shell', 'Terminal'};
  static const _changesTools = {'Write', 'Edit', 'ApplyPatch', 'NotebookEdit'};

  /// 工具所属分组；未归类返回 null。
  String? categoryOf(String? toolName) {
    if (toolName == null) return null;
    if (_exploreTools.contains(toolName)) return 'explore';
    if (_terminalTools.contains(toolName)) return 'terminal';
    if (_changesTools.contains(toolName)) return 'changes';
    return null;
  }

  /// 该工具是否允许与其同类相邻项并组。
  bool allowsGrouping(String? toolName) => switch (categoryOf(toolName)) {
    'explore' => explore,
    'terminal' => terminal,
    'changes' => changes,
    _ => true,
  };

  static const ConversationGrouping all = ConversationGrouping();
}

/// 一个会话正文的展示块。
///
/// 原始行是「一行一件事」，直接铺开会很碎。这里按语义归并：
/// 连续的文本行合成一段、连续的工具调用并成一组、待办合成一张清单。
sealed class ConversationBlock {
  const ConversationBlock(this.rows);

  final List<ConversationRow> rows;

  int? get firstRowId => rows.isEmpty ? null : rows.first.rowId;

  static List<ConversationBlock> group(
    List<ConversationRow> rows, {
    ConversationGrouping grouping = ConversationGrouping.all,
  }) {
    final out = <ConversationBlock>[];
    for (final row in rows) {
      if (!row.isVisible) continue;
      switch (row.kind) {
        case ConversationRowKind.permission:
          out.add(PermissionBlock([row]));

        case ConversationRowKind.toolCall:
          // 待办类工具单独成块（它是一张清单，不是一次调用）。
          if (row.isTodoCall) {
            final last = out.isEmpty ? null : out.last;
            if (last is TodoBlock) {
              out[out.length - 1] = TodoBlock([...last.rows, row]);
            } else {
              out.add(TodoBlock([row]));
            }
            break;
          }
          final cat = grouping.categoryOf(row.toolName);
          final canMerge = grouping.allowsGrouping(row.toolName);
          final last = out.isEmpty ? null : out.last;
          if (canMerge && last is ToolCallGroup && last.category == cat) {
            // ⚠️ 合并时必须带上 category，否则分组信息在第一次合并后就丢了
            out[out.length - 1] = ToolCallGroup([
              ...last.rows,
              row,
            ], category: cat);
          } else {
            out.add(ToolCallGroup([row], category: cat));
          }

        case ConversationRowKind.reasoning:
          final last = out.isEmpty ? null : out.last;
          if (last is ReasoningBlock) {
            out[out.length - 1] = ReasoningBlock([...last.rows, row]);
          } else {
            out.add(ReasoningBlock([row]));
          }

        case ConversationRowKind.assistantText:
        case ConversationRowKind.userText:
          out.add(TextBlock([row]));

        case ConversationRowKind.hookInvocation:
          out.add(HookBlock([row]));

        case ConversationRowKind.turnHeader:
          out.add(TurnHeaderBlock([row]));

        case ConversationRowKind.timelineMarker:
          out.add(MarkerBlock([row]));

        case ConversationRowKind.unknown:
          break;
      }
    }
    return out;
  }
}

/// 待用户处理的授权 / 提问。**写操作的入口。**
class PermissionBlock extends ConversationBlock {
  const PermissionBlock(super.rows);

  ConversationRow get row => rows.first;

  String get toolName => row.toolName ?? '';

  String get summary => row.permissionSummary;

  List<PermissionOption> get options => row.permissionOptions;

  /// 交互 id。官方用提出该交互的工具调用 id 关联。
  String? get interactionId =>
      row.raw['interactionId']?.toString() ??
      row.raw['toolCallId']?.toString() ??
      row.toolCallId;
}

/// 待办清单（`TodoWrite` 类工具调用的产物）。
class TodoBlock extends ConversationBlock {
  const TodoBlock(super.rows);

  /// 取最后一条：待办工具是"整体覆盖"语义，最后一条最准。
  List<TodoItem> get items => rows.last.todos;

  ({int done, int total}) get progress => ConversationRow.todoProgress(items);
}

/// 时间线标记。实测用于「切换模型」这类事件。
class MarkerBlock extends ConversationBlock {
  const MarkerBlock(super.rows);

  ConversationRow get row => rows.first;

  String? get type => row.marker?.type;

  String? get fromModel => row.marker?.fromModel;

  String? get toModel => row.marker?.toModel;

  bool get isModelChange => type == 'modelChange';
}

/// 轮次边界（一轮的开始 / 结束与文件改动统计）。
class TurnHeaderBlock extends ConversationBlock {
  const TurnHeaderBlock(super.rows);

  ConversationRow get row => rows.first;

  String? get state => row.raw['state']?.toString();

  /// 轮次来源与标题（后台结果 / 目标续跑等会与用户发起不同）。
  String? get origin => row.turnOrigin;

  String? get title => row.turnTitle;

  /// 实际耗时（毫秒）。
  int? get activeMs => row.activeMs;

  /// 文件改动统计（`fileChanges: {additions, deletions, files}`）。
  ({int additions, int deletions, int files})? get fileChanges {
    final fc = row.raw['fileChanges'];
    if (fc is! Map) return null;
    int? n(Object? v) => v is num ? v.toInt() : null;
    final a = n(fc['additions']);
    final d = n(fc['deletions']);
    final f = n(fc['files']);
    if (a == null && d == null && f == null) return null;
    return (additions: a ?? 0, deletions: d ?? 0, files: f ?? 0);
  }
}

/// 助手/用户正文（一段）。/// 助手/用户正文（一段）。
class TextBlock extends ConversationBlock {
  const TextBlock(super.rows);

  /// 是否用户消息（含后台结果等）。
  bool get isUser => rows.first.kind == ConversationRowKind.userText;

  /// 是否**真人**发言。后台结果 / 目标续跑也走 userInput，但来源不同，
  /// UI 上不该长得一样。
  bool get isRealUser => isUser && rows.first.isRealUserInput;

  /// 非真人来源的标记（如 `backgroundResult`），UI 显示为来源说明。
  String? get userOrigin {
    if (!isUser || rows.first.isRealUserInput) return null;
    return rows.first.userInputOrigin;
  }

  String get text =>
      rows.map((r) => r.text ?? '').where((t) => t.isNotEmpty).join('\n\n');
}

/// 思考过程（可折叠）。
class ReasoningBlock extends ConversationBlock {
  const ReasoningBlock(super.rows);

  String get text =>
      rows.map((r) => r.text ?? '').where((t) => t.isNotEmpty).join('\n');

  /// Prefer the server's measured duration.  If an older desktop build does
  /// not include it, derive a conservative duration from row timestamps.
  int? get durationMs {
    final explicit = rows
        .map((r) => r.activeMs)
        .whereType<int>()
        .where((n) => n >= 0)
        .fold<int?>(null, (max, n) => max == null || n > max ? n : max);
    if (explicit != null) return explicit;
    final timestamps = rows.map((r) => r.createdAt).whereType<int>().toList();
    if (timestamps.length < 2) return null;
    timestamps.sort();
    final duration = timestamps.last - timestamps.first;
    return duration >= 0 ? duration : null;
  }
}

/// 连续的工具调用（一组）。
class ToolCallGroup extends ConversationBlock {
  const ToolCallGroup(super.rows, {this.category});

  /// 所属分组（`explore` / `terminal` / `changes`），未归类为 null。
  final String? category;

  /// 组内是否全部成功。
  bool get allOk =>
      rows.every((r) => r.status == null || r.status == 'success');

  bool get anyFailed => rows.any((r) => r.status == 'error');

  /// 涉及的工具名（去重，保持出现顺序）。
  List<String> get toolNames {
    final seen = <String>{};
    final out = <String>[];
    for (final r in rows) {
      final n = r.toolName;
      if (n != null && seen.add(n)) out.add(n);
    }
    return out;
  }

  /// Number of distinct skills reported as loaded by this group.  Do not
  /// infer a skill from a generic tool call; only explicit skill-shaped
  /// fields/names are counted.
  int get skillsLoaded {
    final names = <String>{};
    for (final row in rows) {
      final rawSkill = row.raw['skillName'] ?? row.raw['skill'];
      if (rawSkill is String && rawSkill.trim().isNotEmpty) {
        names.add(rawSkill.trim());
        continue;
      }
      final name = row.toolName?.trim() ?? '';
      if (name.toLowerCase().contains('skill')) names.add(name);
    }
    return names.length;
  }
}

/// 钩子调用。
class HookBlock extends ConversationBlock {
  const HookBlock(super.rows);

  String get label =>
      rows.first.raw['hookName']?.toString() ??
      rows.first.toolName ??
      rows.first.raw['name']?.toString() ??
      '';
}

/// 一个会话正文的状态。
class ConversationState {
  const ConversationState({
    this.loading = false,
    this.loadingOlder = false,
    this.error,
    this.rows = const [],
    this.hasMore = false,
    this.fromNative = false,
    this.grouping = ConversationGrouping.all,
    this.sending = false,
    this.sendingMessage = false,
    this.stopping = false,
    this.subscription = ConversationPhase.none,
    this.subscriptionId,
    this.subscriptionEpoch = 0,
    this.sendPhase = SendPhase.idle,
    this.lastLiveAt,
    this.stopEpoch,
    this.actionError,
    this.runtimeConfig = ConversationRuntimeConfig.empty,
  });

  final bool loading;
  final bool loadingOlder;

  /// 失败原因；非空时 UI 应给出降级入口。
  final String? error;

  /// 升序（旧 → 新）。
  final List<ConversationRow> rows;

  /// 是否可能还有更早的行。
  final bool hasMore;

  /// 是否来自原生通道（false 表示该设备不支持，需要走 WebView）。
  final bool fromNative;

  /// 工具分组开关（来自设置）。
  final ConversationGrouping grouping;

  /// 正在提交一个写操作（批准 / 拒绝）。
  final bool sending;

  /// 正在发送用户消息。
  final bool sendingMessage;

  /// 正在请求停止桌面端执行。
  final bool stopping;

  /// 会话层订阅相位。只有桌面端回了 `ack.subscriptionId` 才是 [ConversationPhase.acked]；
  /// 发出订阅请求本身不算订阅成功。
  final ConversationPhase subscription;

  /// 桌面端 ack 里的 subscriptionId（仅 acked 时非空）。
  final String? subscriptionId;

  /// 订阅所属的连接 epoch。bridge 重建后（epoch 变化）该订阅失效，需要重绑。
  final int subscriptionEpoch;

  /// 兼容旧调用：是否已确认订阅。
  bool get subscribed => subscription == ConversationPhase.acked;

  /// 发送状态机（见 UX 规格 §5.2）。`sendingMessage` 由它推导。
  final SendPhase sendPhase;

  /// 最近一次实时行到达时间（毫秒）。发送后若迟迟没有实时行才做一次 reconcile。
  final int? lastLiveAt;

  /// 已经在哪个连接 epoch 发过 stop；同一 epoch 内只发一次。
  final int? stopEpoch;

  /// 写操作失败原因。
  final String? actionError;

  /// Native session model/thought/context data.  Empty means the desktop has
  /// not returned a verified value yet; the UI must not invent a default.
  final ConversationRuntimeConfig runtimeConfig;

  /// 是否有待用户处理的交互。
  bool get hasPendingAction =>
      rows.any((r) => r.kind.needsUserAction && r.isVisible);

  bool get isEmpty => !loading && rows.isEmpty;

  List<ConversationBlock> get blocks =>
      ConversationBlock.group(rows, grouping: grouping);

  ConversationState copyWith({
    bool? loading,
    bool? loadingOlder,
    String? error,
    bool clearError = false,
    List<ConversationRow>? rows,
    bool? hasMore,
    bool? fromNative,
    ConversationGrouping? grouping,
    bool? sending,
    bool? sendingMessage,
    bool? stopping,
    ConversationPhase? subscription,
    Object? subscriptionId = _keepValue,
    int? subscriptionEpoch,
    SendPhase? sendPhase,
    int? lastLiveAt,
    Object? stopEpoch = _keepValue,
    String? actionError,
    bool clearActionError = false,
    ConversationRuntimeConfig? runtimeConfig,
  }) => ConversationState(
    loading: loading ?? this.loading,
    loadingOlder: loadingOlder ?? this.loadingOlder,
    error: clearError ? null : (error ?? this.error),
    rows: rows ?? this.rows,
    hasMore: hasMore ?? this.hasMore,
    fromNative: fromNative ?? this.fromNative,
    grouping: grouping ?? this.grouping,
    sending: sending ?? this.sending,
    sendingMessage: sendingMessage ?? this.sendingMessage,
    stopping: stopping ?? this.stopping,
    subscription: subscription ?? this.subscription,
    subscriptionId: identical(subscriptionId, _keepValue)
        ? this.subscriptionId
        : subscriptionId as String?,
    subscriptionEpoch: subscriptionEpoch ?? this.subscriptionEpoch,
    sendPhase: sendPhase ?? this.sendPhase,
    lastLiveAt: lastLiveAt ?? this.lastLiveAt,
    stopEpoch: identical(stopEpoch, _keepValue)
        ? this.stopEpoch
        : stopEpoch as int?,
    actionError: clearActionError ? null : (actionError ?? this.actionError),
    runtimeConfig: runtimeConfig ?? this.runtimeConfig,
  );
}

const Object _keepValue = Object();

/// idle → preparing → pendingReceipt → streaming → completed | failed.
enum SendPhase {
  idle,
  preparing,
  pendingReceipt,
  streaming,
  completed,
  failed;

  bool get inFlight => this == preparing || this == pendingReceipt;
}

/// How long to wait for the desktop's live rows after an accepted receipt
/// before pulling once.  Protocol-driven fallback, not a timing guess: it
/// only fires when nothing arrived at all.
const Duration kReconcileAfter = Duration(seconds: 3);

/// 每页拉多少行（官方页面用 200）。
const int kConversationPageSize = 200;

/// 正文状态层。
///
/// 与 `sessionIndexProvider` 一样用 `Map<key, state>`，key 为 `deviceId|sessionId`。
class ConversationNotifier extends Notifier<Map<String, ConversationState>> {
  final Map<String, StreamSubscription<ConversationUpdate>> _subscriptions = {};

  /// Keys that asked for realtime and must be re-attached after the bridge
  /// is rebuilt (connection epoch changes).
  final Set<String> _wantsRealtime = {};
  final Map<String, ({String workspacePath, String sessionId})> _scopes = {};
  final Map<String, Timer> _reconcile = {};
  final Map<String, int> _epochSeen = {};

  @override
  Map<String, ConversationState> build() {
    ref.onDispose(() {
      for (final subscription in _subscriptions.values) {
        unawaited(subscription.cancel());
      }
      _subscriptions.clear();
      for (final t in _reconcile.values) {
        t.cancel();
      }
      _reconcile.clear();
    });
    // P0-REBIND-004: when a device's bridge is rebuilt, the cached stream
    // subscriptions point at a dead bridge.  Drop them and re-attach once
    // the new bridge's agent handshake is done.
    ref.listen<Map<String, RelaySourceState>>(relaySourceProvider, (
      prev,
      next,
    ) {
      for (final entry in next.entries) {
        final deviceId = entry.key;
        final epoch = entry.value.connectionEpoch;
        final seen = _epochSeen[deviceId];
        if (seen != null && seen != epoch) _onEpochChanged(deviceId, epoch);
        _epochSeen[deviceId] = epoch;
        if (entry.value.agentReady) _rebindPending(deviceId, epoch);
      }
    });
    return const {};
  }

  void _onEpochChanged(String deviceId, int epoch) {
    final prefix = '$deviceId|';
    for (final key
        in _subscriptions.keys.where((k) => k.startsWith(prefix)).toList()) {
      unawaited(_subscriptions.remove(key)?.cancel());
    }
    final updated = <String, ConversationState>{};
    for (final entry in state.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      // The old ack and any in-flight stop belong to the dead bridge.
      updated[entry.key] = entry.value.copyWith(
        subscription: ConversationPhase.none,
        subscriptionId: null,
        subscriptionEpoch: epoch,
        stopping: false,
        stopEpoch: null,
      );
    }
    if (updated.isNotEmpty) state = {...state, ...updated};
  }

  void _rebindPending(String deviceId, int epoch) {
    final prefix = '$deviceId|';
    for (final key
        in _wantsRealtime.where((k) => k.startsWith(prefix)).toList()) {
      final st = state[key];
      final scope = _scopes[key];
      if (st == null || scope == null) continue;
      if (st.subscription == ConversationPhase.acked &&
          st.subscriptionEpoch == epoch) {
        continue;
      }
      if (st.subscription == ConversationPhase.subscribing &&
          st.subscriptionEpoch == epoch) {
        continue;
      }
      unawaited(
        _attachRealtime(
          key: key,
          deviceId: deviceId,
          workspacePath: scope.workspacePath,
          sessionId: scope.sessionId,
        ),
      );
    }
  }

  static String keyOf(String deviceId, String sessionId) =>
      '$deviceId|$sessionId';

  ConversationState stateOf(String deviceId, String sessionId) =>
      state[keyOf(deviceId, sessionId)] ?? const ConversationState();

  void _set(String key, ConversationState s) => state = {...state, key: s};

  Future<bool> _attachRealtime({
    required String key,
    required String deviceId,
    required String workspacePath,
    required String sessionId,
  }) async {
    final source = ref.read(relaySourceProvider.notifier);
    final epoch = source.epochOf(deviceId);
    final current = state[key] ?? const ConversationState();
    _wantsRealtime.add(key);
    _scopes[key] = (workspacePath: workspacePath, sessionId: sessionId);
    _epochSeen.putIfAbsent(deviceId, () => epoch);

    // Already acked on this very connection: nothing to do.  A different
    // epoch means the bridge was rebuilt and the old ack is void.
    if (current.subscription == ConversationPhase.acked &&
        current.subscriptionEpoch == epoch &&
        _subscriptions.containsKey(key)) {
      return true;
    }
    if (current.subscription == ConversationPhase.subscribing &&
        current.subscriptionEpoch == epoch) {
      return false;
    }

    if (!await source.ensureConversation(deviceId)) {
      _set(
        key,
        (state[key] ?? current).copyWith(
          subscription: ConversationPhase.failed,
          subscriptionId: null,
          subscriptionEpoch: epoch,
        ),
      );
      return false;
    }

    // Rebind the live stream to the current bridge.  The old subscription
    // (if any) belonged to a bridge that no longer exists.
    if (current.subscriptionEpoch != epoch) {
      await _subscriptions.remove(key)?.cancel();
    }
    if (!_subscriptions.containsKey(key)) {
      final stream = source.conversationUpdates(deviceId);
      if (stream == null) return false;
      _subscriptions[key] = stream.listen((update) {
        if (update.sessionId != null && update.sessionId != sessionId) return;
        if (update.workspacePath != null &&
            update.workspacePath != workspacePath) {
          return;
        }
        _mergeLive(key, update.rows);
      });
    }

    _set(
      key,
      (state[key] ?? current).copyWith(
        subscription: ConversationPhase.subscribing,
        subscriptionId: null,
        subscriptionEpoch: epoch,
      ),
    );
    final ack = await source.subscribeConversation(
      deviceId: deviceId,
      workspacePath: workspacePath,
      sessionId: sessionId,
    );
    // A reconnect while we waited makes this ack meaningless.
    if (source.epochOf(deviceId) != epoch || !ref.mounted) return false;
    if (ack == null) {
      _set(
        key,
        (state[key] ?? current).copyWith(
          subscription: ConversationPhase.failed,
          subscriptionId: null,
          subscriptionEpoch: epoch,
        ),
      );
      return false;
    }
    _set(
      key,
      (state[key] ?? current).copyWith(
        subscription: ConversationPhase.acked,
        subscriptionId: ack.subscriptionId,
        subscriptionEpoch: epoch,
      ),
    );
    return true;
  }

  void _mergeLive(String key, List<ConversationRow> incoming) {
    if (incoming.isEmpty || !state.containsKey(key)) return;
    final current = state[key]!;
    final merged = ConversationReducer.merge(
      current.rows,
      incoming,
      source: RowSource.live,
    );
    // Live rows arriving after an accepted send mean the desktop is
    // streaming; a pending user row that got its official twin is done.
    final turnEnded = incoming.any(_isTerminalTurnHeader);
    // Live rows after an accepted send mean the desktop is streaming —
    // until it closes the turn.  A terminal turnHeader ends the run: the
    // composer returns to send and the per-run stop guard re-arms, so the
    // NEXT execution can be stopped again (P0-1/P0-2).
    final phase = turnEnded
        ? SendPhase.idle
        : switch (current.sendPhase) {
            SendPhase.pendingReceipt ||
            SendPhase.streaming => SendPhase.streaming,
            final p => p,
          };
    _set(
      key,
      current.copyWith(
        rows: merged,
        fromNative: true,
        loading: false,
        sendPhase: phase,
        // P2-4: a refusal banner survives unrelated pushes; the next
        // user action clears it, not an arbitrary row.
        stopEpoch: turnEnded ? null : current.stopEpoch,
        lastLiveAt: DateTime.now().millisecondsSinceEpoch,
        clearError: true,
      ),
    );
  }

  /// `turnHeader` rows carry the desktop's turn state; these values close
  /// the run (verified row vocabulary, RELAY-PROTOCOL-VERIFIED §8.4.3).
  static bool _isTerminalTurnHeader(ConversationRow row) {
    if (row.kind != ConversationRowKind.turnHeader) return false;
    final state = row.raw['state'];
    if (state == null) return false;
    final s = state.toString().toLowerCase();
    return s.startsWith('completed') ||
        s == 'stopped' ||
        s == 'cancelled' ||
        s == 'aborted' ||
        s == 'failed';
  }

  /// 拉取（或刷新）正文。
  Future<void> load({
    required String deviceId,
    required String workspacePath,
    required String sessionId,
    bool refresh = false,
  }) async {
    final key = keyOf(deviceId, sessionId);
    final current = state[key] ?? const ConversationState();
    if (current.loading) return;
    if (!refresh && current.rows.isNotEmpty) {
      await _attachRealtime(
        key: key,
        deviceId: deviceId,
        workspacePath: workspacePath,
        sessionId: sessionId,
      );
      return;
    }

    _set(
      key,
      // Keep existing rows visible during a refresh.  Clearing them made a
      // connected conversation flash an empty screen after every send.
      current.copyWith(loading: true, clearError: true),
    );

    final rows = await ref
        .read(relaySourceProvider.notifier)
        .fetchRows(
          deviceId: deviceId,
          workspacePath: workspacePath,
          sessionId: sessionId,
        );

    if (rows == null) {
      _set(
        key,
        (state[key] ?? current).copyWith(
          error: '该设备的原生通道不可用或未返回正文',
          fromNative: false,
          loading: false,
        ),
      );
      return;
    }

    // Merge, never replace: a refresh must not erase live rows that the
    // range response has not caught up with yet, and an optimistic user row
    // is replaced by its official twin rather than duplicated.
    final latest = state[key] ?? current;
    final merged = ConversationReducer.merge(
      latest.rows,
      rows,
      source: refresh ? RowSource.refresh : RowSource.initial,
    );
    _set(
      key,
      latest.copyWith(
        loading: false,
        rows: merged,
        // 拿满一页就认为还有更早的
        hasMore: rows.length >= kConversationPageSize,
        fromNative: true,
        clearError: true,
        clearActionError: true,
      ),
    );
    await _attachRealtime(
      key: key,
      deviceId: deviceId,
      workspacePath: workspacePath,
      sessionId: sessionId,
    );
  }

  /// 向上翻页：拉更早的一批。
  Future<void> loadOlder({
    required String deviceId,
    required String workspacePath,
    required String sessionId,
  }) async {
    final key = keyOf(deviceId, sessionId);
    final current = state[key] ?? const ConversationState();
    if (current.loadingOlder || current.rows.isEmpty) return;

    final oldest = ConversationRow.oldestRowId(current.rows);
    if (oldest == null) return;

    _set(key, current.copyWith(loadingOlder: true));

    final rows = await ref
        .read(relaySourceProvider.notifier)
        .fetchRows(
          deviceId: deviceId,
          workspacePath: workspacePath,
          sessionId: sessionId,
          beforeRowId: oldest,
        );

    if (rows == null) {
      _set(key, current.copyWith(loadingOlder: false, hasMore: false));
      return;
    }

    final latest = state[key] ?? current;
    _set(
      key,
      latest.copyWith(
        loadingOlder: false,
        rows: ConversationReducer.merge(
          latest.rows,
          rows,
          source: RowSource.older,
        ),
        hasMore: rows.length >= kConversationPageSize,
        fromNative: true,
      ),
    );
  }

  /// 提交一次交互回应（**写操作**）。
  ///
  /// 成功后刷新正文，让 UI 反映最新状态。
  Future<void> resolveInteraction({
    required String deviceId,
    required String workspacePath,
    required String sessionId,
    required String interactionId,
    String? optionId,
    String? action,
  }) async {
    final key = keyOf(deviceId, sessionId);
    final current = state[key] ?? const ConversationState();
    if (current.sending) return;

    _set(key, current.copyWith(sending: true, clearActionError: true));

    final sent = await ref
        .read(relaySourceProvider.notifier)
        .resolveInteraction(
          deviceId: deviceId,
          sessionId: sessionId,
          interactionId: interactionId,
          optionId: optionId,
          action: action,
        );

    if (!sent) {
      _set(
        key,
        (state[key] ?? current).copyWith(
          sending: false,
          actionError: _refusalText(
            deviceId,
            '原生通道不可用，未能提交',
            sessionId: sessionId,
          ),
        ),
      );
      return;
    }

    // The permission row is updated by the live stream; pull once only if
    // nothing arrives.
    _set(key, (state[key] ?? current).copyWith(sending: false));
    _scheduleReconcile(key, deviceId, workspacePath, sessionId);
  }

  /// Receipt-aware failure copy: prefer the desktop's reasonCode.
  String _refusalText(String deviceId, String fallback, {String? sessionId}) {
    final source = ref.read(relaySourceProvider.notifier);
    final receipt = sessionId == null
        ? source.lastCommandReceipt(deviceId)
        : source.lastCommandReceiptFor(deviceId, sessionId);
    if (receipt != null && receipt.isRefusal) {
      return '桌面端拒绝：${receipt.safeLabel}';
    }
    return fallback;
  }

  /// Pull the range once after [kReconcileAfter] unless live rows arrived in
  /// the meantime.  Replaces the old 450/700/400 ms blind refreshes.
  void _scheduleReconcile(
    String key,
    String deviceId,
    String workspacePath,
    String sessionId,
  ) {
    _reconcile.remove(key)?.cancel();
    final since = DateTime.now().millisecondsSinceEpoch;
    _reconcile[key] = Timer(kReconcileAfter, () {
      _reconcile.remove(key);
      if (!ref.mounted) return;
      final st = state[key];
      if (st == null) return;
      final live = st.lastLiveAt;
      if (live != null && live >= since) return;
      unawaited(
        load(
          deviceId: deviceId,
          workspacePath: workspacePath,
          sessionId: sessionId,
          refresh: true,
        ),
      );
    });
  }

  /// 发送一条用户消息（**写操作**）。
  ///
  /// 发送必须由用户点击提交；成功后由会话订阅接收新行，刷新只作为兜底。
  Future<bool> sendMessage({
    required String deviceId,
    required String workspacePath,
    required String sessionId,
    required String text,
    List<ConversationAttachment> attachments = const [],
  }) async {
    final value = text.trim();
    if (value.isEmpty) return false;
    final key = keyOf(deviceId, sessionId);
    final current = state[key] ?? const ConversationState();
    if (current.sendPhase.inFlight || current.stopping) return false;

    final source = ref.read(relaySourceProvider.notifier);
    final operationId = 'zr-send-${_newOperationId()}';
    final optimistic = ConversationReducer.optimisticUserRow(
      clientOperationId: operationId,
      text: value,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    _set(
      key,
      current.copyWith(
        sendingMessage: true,
        sendPhase: SendPhase.preparing,
        rows: ConversationReducer.merge(current.rows, [
          optimistic,
        ], source: RowSource.optimistic),
        clearActionError: true,
      ),
    );
    // 先确保正文订阅已 ack，再发送：没有确认的订阅意味着发送后的行
    // 没有可靠来源，宁可失败保留草稿（review P2-6）。
    final attached = await _attachRealtime(
      key: key,
      deviceId: deviceId,
      workspacePath: workspacePath,
      sessionId: sessionId,
    );
    if (!attached || !ref.mounted) {
      final latest = state[key] ?? current;
      _set(
        key,
        latest.copyWith(
          sendingMessage: false,
          sendPhase: SendPhase.failed,
          rows: latest.rows
              .where((r) => r.raw['clientOperationId'] != operationId)
              .toList(),
          actionError: '会话订阅未确认，未能发送消息',
        ),
      );
      return false;
    }
    _set(
      key,
      (state[key] ?? current).copyWith(sendPhase: SendPhase.pendingReceipt),
    );
    final sent = await source.sendMessage(
      deviceId: deviceId,
      sessionId: sessionId,
      text: value,
      attachments: attachments,
      clientOperationId: operationId,
    );
    if (!ref.mounted) return sent;
    if (!sent) {
      final latest = state[key] ?? current;
      _set(
        key,
        latest.copyWith(
          sendingMessage: false,
          sendPhase: SendPhase.failed,
          // The pending row is withdrawn; the composer restores the draft.
          rows: latest.rows
              .where((r) => r.raw['clientOperationId'] != operationId)
              .toList(),
          actionError: _refusalText(
            deviceId,
            '原生通道不可用，未能发送消息',
            sessionId: sessionId,
          ),
        ),
      );
      return false;
    }

    // Accepted.  Rows come from the subscription; reconcile only if quiet.
    // A new run re-arms the stop guard.
    _set(
      key,
      (state[key] ?? current).copyWith(
        sendingMessage: false,
        sendPhase: SendPhase.streaming,
        stopEpoch: null,
      ),
    );
    _scheduleReconcile(key, deviceId, workspacePath, sessionId);
    return true;
  }

  static int _operationSeq = 0;
  static String _newOperationId() =>
      '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-${++_operationSeq}';

  /// Read the native session snapshot and token usage used by the composer
  /// controls.  This is intentionally independent from conversation rows so
  /// a configuration failure does not hide an otherwise readable transcript.
  Future<void> loadRuntimeConfig({
    required String deviceId,
    required String workspacePath,
    required String sessionId,
    bool refresh = false,
  }) async {
    final key = keyOf(deviceId, sessionId);
    final current = state[key] ?? const ConversationState();
    if (current.runtimeConfig.loading ||
        (!refresh &&
            (current.runtimeConfig.hasModel ||
                current.runtimeConfig.hasContext))) {
      return;
    }
    _set(
      key,
      current.copyWith(
        runtimeConfig: current.runtimeConfig.copyWith(
          loading: true,
          clearError: true,
        ),
      ),
    );

    final source = ref.read(relaySourceProvider.notifier);
    final snapshot = await source.fetchConversationSnapshot(
      deviceId: deviceId,
      workspacePath: workspacePath,
      sessionId: sessionId,
    );
    final usage = await source.fetchConversationUsage(
      deviceId: deviceId,
      workspacePath: workspacePath,
      sessionId: sessionId,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    final parsed = ConversationRuntimeConfig.parse(snapshot, fetchedAt: now);
    final usageParsed = ConversationRuntimeConfig.parse(usage, fetchedAt: now);
    final merged = parsed.mergeUsage(usageParsed);
    if (!ref.mounted) return;
    final latest = state[key] ?? current;
    // A failed refresh keeps the last snapshot visible (stale) instead of
    // blanking the chips; only the error text changes.
    // A partial failure (one read null, the other fine) overlays the new
    // fields on the previous snapshot instead of blanking them (P2-1);
    // only a total failure keeps the old snapshot with an error.
    final next = snapshot == null && usage == null
        ? latest.runtimeConfig.copyWith(loading: false, error: '桌面端暂未返回会话配置')
        : latest.runtimeConfig
              .overlay(merged)
              .copyWith(loading: false, clearError: true);
    _set(key, latest.copyWith(runtimeConfig: next));
  }

  /// Change a verified session model/thought setting through the native
  /// command layer, then re-read the snapshot.  No silent fallback is used.
  Future<void> updateRuntimeConfig({
    required String deviceId,
    required String workspacePath,
    required String sessionId,
    String? providerId,
    String? modelId,
    String? thoughtLevel,
  }) async {
    final key = keyOf(deviceId, sessionId);
    final current = state[key] ?? const ConversationState();
    final config = current.runtimeConfig;
    if (config.loading) return;
    final source = ref.read(relaySourceProvider.notifier);

    final wantsModel =
        modelId != null &&
        (modelId != config.modelId ||
            (providerId != null && providerId != config.providerId));
    final wantsThought =
        thoughtLevel != null && thoughtLevel != config.thoughtLevel;
    if (!wantsModel && !wantsThought) return;

    // Validate against the authoritative snapshot before writing.  A value
    // the desktop never offered is refused locally with a specific reason.
    if (wantsModel && config.catalogState == ConfigFieldState.returned) {
      final target = config.models.cast<ConversationModelOption?>().firstWhere(
        (m) =>
            m!.modelId == modelId &&
            (providerId == null || m.providerId == providerId),
        orElse: () => null,
      );
      if (target == null) {
        _set(key, current.copyWith(actionError: '该模型不在桌面端目录中'));
        return;
      }
      if (!target.enabled) {
        _set(
          key,
          current.copyWith(
            actionError: '该模型不可用：${target.disabledReason ?? 'disabled'}',
          ),
        );
        return;
      }
    }
    if (wantsThought &&
        config.thoughtSelectable &&
        !config.thoughtOptions.any((o) => o.value == thoughtLevel)) {
      _set(key, current.copyWith(actionError: '桌面端未提供该思考级别'));
      return;
    }

    _set(
      key,
      current.copyWith(
        runtimeConfig: config.copyWith(loading: true),
        clearActionError: true,
      ),
    );

    String? failure;
    if (wantsModel) {
      final provider =
          providerId ??
          config.providerId ??
          config.models
              .cast<ConversationModelOption?>()
              .firstWhere((m) => m!.modelId == modelId, orElse: () => null)
              ?.providerId;
      if (provider == null) {
        failure = 'provider_unknown';
      } else {
        final r = await source.applySessionModel(
          deviceId: deviceId,
          workspacePath: workspacePath,
          sessionId: sessionId,
          providerId: provider,
          modelId: modelId,
          expectedRevision: config.revision,
        );
        if (!r.ok) {
          failure = r.isMethodNotFound
              ? await _fallbackSwitch(
                  source,
                  deviceId,
                  sessionId,
                  provider,
                  modelId,
                  thoughtLevel ?? config.thoughtLevel,
                )
              : r.safeLabel;
        }
      }
    }
    if (failure == null && wantsThought) {
      final r = await source.applySessionThoughtLevel(
        deviceId: deviceId,
        workspacePath: workspacePath,
        sessionId: sessionId,
        thoughtLevel: thoughtLevel,
        expectedRevision: config.revision,
      );
      if (!r.ok) {
        final provider = providerId ?? config.providerId;
        final model = modelId ?? config.modelId;
        failure = r.isMethodNotFound && provider != null && model != null
            ? await _fallbackSwitch(
                source,
                deviceId,
                sessionId,
                provider,
                model,
                thoughtLevel,
              )
            : r.safeLabel;
      }
    }

    if (!ref.mounted) return;
    if (failure != null) {
      // Keep the old snapshot; show the desktop's own reason.
      final latest = state[key] ?? current;
      _set(
        key,
        latest.copyWith(
          actionError: '桌面端拒绝了会话配置变更：$failure',
          runtimeConfig: latest.runtimeConfig.copyWith(loading: false),
        ),
      );
      return;
    }
    await loadRuntimeConfig(
      deviceId: deviceId,
      workspacePath: workspacePath,
      sessionId: sessionId,
      refresh: true,
    );
  }

  /// Older desktops without the independent setters: the combined command
  /// requires all three fields.  Returns a failure label or null.
  Future<String?> _fallbackSwitch(
    RelaySourceNotifier source,
    String deviceId,
    String sessionId,
    String provider,
    String model,
    String? thought,
  ) async {
    if (thought == null) return 'thought_level_required_by_desktop';
    final ok = await source.switchModelConfig(
      deviceId: deviceId,
      sessionId: sessionId,
      providerId: provider,
      modelId: model,
      thoughtLevel: thought,
    );
    if (ok) return null;
    final receipt = source.lastCommandReceiptFor(deviceId, sessionId);
    return receipt != null && receipt.isRefusal
        ? receipt.safeLabel
        : 'switchModelConfig_failed';
  }

  /// 请求停止当前会话执行（**写操作**）。
  Future<void> stopConversation({
    required String deviceId,
    required String workspacePath,
    required String sessionId,
  }) async {
    final key = keyOf(deviceId, sessionId);
    final current = state[key] ?? const ConversationState();
    final source = ref.read(relaySourceProvider.notifier);
    final epoch = source.epochOf(deviceId);
    // One stop per RUN, not per connection: a double tap must not write
    // twice, but after the turn ended (guard re-armed in _mergeLive) or a
    // new send started, stopping must work again (P0-2).
    if (current.stopping || current.stopEpoch == epoch) return;

    _set(
      key,
      current.copyWith(
        stopping: true,
        stopEpoch: epoch,
        clearActionError: true,
      ),
    );
    final sent = await source.stopConversation(
      deviceId: deviceId,
      sessionId: sessionId,
    );
    if (!ref.mounted) return;
    if (!sent) {
      _set(
        key,
        (state[key] ?? current).copyWith(
          stopping: false,
          // Allow a retry: the desktop did not accept this one.
          stopEpoch: null,
          actionError: _refusalText(
            deviceId,
            '原生通道不可用，未能停止会话',
            sessionId: sessionId,
          ),
        ),
      );
      return;
    }

    // Accepted (or duplicate).  The turn state arrives on the live stream;
    // reconcile only if it stays quiet.
    _set(key, (state[key] ?? current).copyWith(stopping: false));
    _scheduleReconcile(key, deviceId, workspacePath, sessionId);
  }

  void forget(String deviceId, String sessionId) {
    final key = keyOf(deviceId, sessionId);
    unawaited(_subscriptions.remove(key)?.cancel());
    _reconcile.remove(key)?.cancel();
    _wantsRealtime.remove(key);
    _scopes.remove(key);
    if (!state.containsKey(key)) return;
    state = Map.of(state)..remove(key);
  }

  /// 设备删除时的会话层清理：取消该设备全部订阅、定时器与内部状态。
  ///
  /// 单会话的 [forget] 只处理一行；删设备必须按设备前缀整体回收，否则
  /// 订阅与待重绑集合会残留（评审 P3：设备级缓存无清理入口）。
  void forgetDevice(String deviceId) {
    final prefix = '$deviceId|';
    for (final key in _subscriptions.keys
        .where((k) => k.startsWith(prefix))
        .toList()) {
      unawaited(_subscriptions.remove(key)?.cancel());
    }
    for (final key in _reconcile.keys
        .where((k) => k.startsWith(prefix))
        .toList()) {
      _reconcile.remove(key)?.cancel();
    }
    _wantsRealtime.removeWhere((k) => k.startsWith(prefix));
    _scopes.removeWhere((k, _) => k.startsWith(prefix));
    _epochSeen.remove(deviceId);
    final remaining = Map.of(
      state,
    )..removeWhere((k, _) => k.startsWith(prefix));
    state = remaining;
  }
}

final conversationProvider =
    NotifierProvider<ConversationNotifier, Map<String, ConversationState>>(
      ConversationNotifier.new,
    );

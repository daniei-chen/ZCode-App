import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/mcp_server.dart';
import '../models/resource_list.dart';
import '../relay/service_call_result.dart';
import 'relay_source.dart';

/// MCP 服务器面板状态。
class McpServerState {
  const McpServerState({
    this.loading = false,
    this.error,
    this.items = const [],
    this.loaded = false,
    this.remoteItems = const [],
    this.phase = ResourcePhase.idle,
    this.method,
  });

  final bool loading;
  final String? error;
  final List<McpServerEntry> items;
  final bool loaded;
  final List<McpServerEntry> remoteItems;
  final ResourcePhase phase;
  final String? method;

  List<McpServerEntry> get displayItems => [...items, ...remoteItems];

  McpServerState copyWith({
    bool? loading,
    String? error,
    bool clearError = false,
    List<McpServerEntry>? items,
    bool? loaded,
    List<McpServerEntry>? remoteItems,
    ResourcePhase? phase,
    String? method,
  }) => McpServerState(
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
    items: items ?? this.items,
    loaded: loaded ?? this.loaded,
    remoteItems: remoteItems ?? this.remoteItems,
    phase: phase ?? this.phase,
    method: method ?? this.method,
  );
}

class McpServerNotifier extends Notifier<Map<String, McpServerState>> {
  @override
  Map<String, McpServerState> build() => const {};

  static String keyOf(String deviceId, String workspacePath) =>
      '$deviceId|$workspacePath';

  McpServerState stateOf(String deviceId, String workspacePath) =>
      state[keyOf(deviceId, workspacePath)] ?? const McpServerState();

  void _set(String key, McpServerState value) => state = {...state, key: value};

  Future<void> load({
    required String deviceId,
    required String workspacePath,
    bool refresh = false,
  }) async {
    final key = keyOf(deviceId, workspacePath);
    final current = state[key] ?? const McpServerState();
    if (current.loading) return;
    if (current.loaded && !refresh) return;

    _set(
      key,
      current.copyWith(
        loading: true,
        clearError: true,
        phase: ResourcePhase.loading,
      ),
    );

    // 该接口读取用户目录配置，不需要把 workspacePath 作为参数传入；
    // workspace 仍保留在状态 key 中，避免不同面板上下文互相串数据。
    final relay = ref.read(relaySourceProvider.notifier);
    final localResult =
        await relay.callServiceExpectResponse(
          deviceId,
          'mcp-sync',
          'listLocalUserMcpCandidates',
        ) ??
        await relay.callAgentExpectResponse(
          deviceId,
          'listLocalUserMcpCandidates',
        );
    final localItems = localResult == null
        ? null
        : McpServerEntry.parseResponse(localResult);

    // Remote sync status is a separate read path.  A missing remote status
    // endpoint must not hide the local candidates that were read successfully.
    final names = [
      for (final item in localItems ?? const <McpServerEntry>[]) item.name,
    ];
    // The desktop method requires an explicit `names` array.  A no-argument
    // call is accepted by the transport but crashes inside the host when it
    // evaluates `t.names.map(...)`, which previously made this page look
    // permanently unavailable.
    final remoteResult = await relay.callServiceExpectResponse(
      deviceId,
      'mcp-sync',
      'listRemoteUserMcpStatuses',
      [
        {'names': names},
      ],
    );
    final remoteItems = remoteResult == null
        ? null
        : McpServerEntry.parseResponse(remoteResult, remote: true);

    if (localItems == null && remoteItems == null) {
      _set(
        key,
        current.copyWith(
          loading: false,
          error: '未能读取 MCP 本地候选或远端状态（原生接口未返回）',
          loaded: true,
          phase: ResourcePhase.error,
        ),
      );
      return;
    }

    final local = localItems ?? const <McpServerEntry>[];
    final remote = remoteItems ?? const <McpServerEntry>[];
    _set(
      key,
      McpServerState(
        items: local,
        remoteItems: remote,
        loaded: true,
        phase: local.isEmpty && remote.isEmpty
            ? ResourcePhase.empty
            : ResourcePhase.ready,
        method: remoteItems == null
            ? 'mcp-sync.listLocalUserMcpCandidates'
            : 'mcp-sync.listLocalUserMcpCandidates + listRemoteUserMcpStatuses',
      ),
    );
  }

  /// Toggle a local user-directory MCP entry through the desktop's verified
  /// write API, then reload both local candidates and remote status.
  Future<ServiceCallResult> setEnabled({
    required String deviceId,
    required String workspacePath,
    required String id,
    required bool enabled,
  }) async {
    final key = keyOf(deviceId, workspacePath);
    final current = state[key];
    McpServerEntry? item;
    for (final candidate in current?.items ?? const <McpServerEntry>[]) {
      if (candidate.id == id) {
        item = candidate;
        break;
      }
    }
    if (item == null) {
      return const ServiceCallResult.failure('mcp_not_found');
    }
    final result = await ref
        .read(relaySourceProvider.notifier)
        .callServiceAllowEmpty(deviceId, 'mcp-sync', 'saveMcpToUserDirectory', [
          {'action': 'set-enabled', 'name': item.name, 'enabled': enabled},
        ]);
    if (result.ok) {
      await load(
        deviceId: deviceId,
        workspacePath: workspacePath,
        refresh: true,
      );
    }
    return result;
  }
}

final mcpServerProvider =
    NotifierProvider<McpServerNotifier, Map<String, McpServerState>>(
      McpServerNotifier.new,
    );

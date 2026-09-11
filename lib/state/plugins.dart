import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/plugin_status.dart';
import '../models/resource_list.dart';
import '../relay/service_call_result.dart';
import 'relay_source.dart';

/// 插件 / 插件提供的 MCP 服务状态。
class PluginStatusState {
  const PluginStatusState({
    this.loading = false,
    this.error,
    this.items = const [],
    this.loaded = false,
    this.overview,
    this.phase = ResourcePhase.idle,
    this.method,
  });

  final bool loading;
  final String? error;
  final List<PluginStatusEntry> items;
  final bool loaded;
  final PluginOverview? overview;
  final ResourcePhase phase;
  final String? method;

  /// Packages and registered MCP services are deliberately shown together in
  /// one searchable list, while their group labels keep the scopes distinct.
  List<ResourceEntry> get displayItems => [...?overview?.entries, ...items];

  bool get isEmpty => loaded && displayItems.isEmpty;

  PluginStatusState copyWith({
    bool? loading,
    String? error,
    bool clearError = false,
    List<PluginStatusEntry>? items,
    bool? loaded,
    PluginOverview? overview,
    ResourcePhase? phase,
    String? method,
  }) => PluginStatusState(
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
    items: items ?? this.items,
    loaded: loaded ?? this.loaded,
    overview: overview ?? this.overview,
    phase: phase ?? this.phase,
    method: method ?? this.method,
  );

  /// 已连接数量（页脚摘要用）。
  int get connectedCount => items.where((e) => e.enabled).length;

  int get installedCount => overview?.installed.length ?? 0;

  int get availableCount => overview?.available.length ?? 0;

  int get marketplaceCount => overview?.marketplaces.length ?? 0;
}

class PluginStatusNotifier extends Notifier<Map<String, PluginStatusState>> {
  @override
  Map<String, PluginStatusState> build() => const {};

  static String keyOf(String deviceId, String workspacePath) =>
      '$deviceId|$workspacePath';

  PluginStatusState stateOf(String deviceId, String workspacePath) =>
      state[keyOf(deviceId, workspacePath)] ?? const PluginStatusState();

  void _set(String key, PluginStatusState value) =>
      state = {...state, key: value};

  Future<void> load({
    required String deviceId,
    required String workspacePath,
    bool refresh = false,
  }) async {
    final key = keyOf(deviceId, workspacePath);
    final cur = state[key] ?? const PluginStatusState();
    if (cur.loading) return;
    if (cur.loaded && !refresh) return;

    _set(
      key,
      cur.copyWith(
        loading: true,
        clearError: true,
        phase: ResourcePhase.loading,
      ),
    );

    final relay = ref.read(relaySourceProvider.notifier);
    final args = [
      relay.workspaceScope(deviceId: deviceId, workspacePath: workspacePath),
    ];
    // `plugins.getOverview` is the catalogue used by the desktop settings
    // screen.  Older desktop builds require a workspace argument, so retry
    // that read with the scoped shape before falling back to the legacy
    // plugin-management service.
    var overviewResult = await relay.callService(
      deviceId,
      'plugins',
      'getOverview',
      const [],
    );
    if (!overviewResult.ok) {
      overviewResult = await relay.callService(
        deviceId,
        'plugins',
        'getOverview',
        args,
      );
    }
    final overview = overviewResult.ok
        ? PluginOverview.parseResponse(overviewResult.value)
        : null;

    // The status half is still provided by plugin-management on some
    // releases.  Keep it as a second read so a catalogue response is never
    // mistaken for a service-status response.
    final statusResult = await relay.callService(
      deviceId,
      'plugin-management',
      'getPluginsOverview',
      args,
    );
    final legacy = statusResult.ok
        ? statusResult.value
        : await relay.callAgentExpectResponse(
            deviceId,
            'getPluginsOverview',
            args,
          );
    final items = legacy == null
        ? null
        : PluginStatusEntry.parseResponse(legacy);

    final hasRead = overview != null || items != null;
    if (!hasRead) {
      final code = overviewResult.error ?? statusResult.error;
      _set(
        key,
        cur.copyWith(
          loading: false,
          error: '未能读取插件目录或服务状态（${code ?? '原生接口未返回'}）',
          loaded: true,
          phase: code?.contains('method_not_found') == true
              ? ResourcePhase.unsupported
              : ResourcePhase.error,
        ),
      );
      return;
    }

    final packageItems = overview?.entries ?? const <ResourceEntry>[];
    _set(
      key,
      PluginStatusState(
        items: items ?? const [],
        overview: overview,
        loaded: true,
        phase: packageItems.isEmpty && (items?.isEmpty ?? true)
            ? ResourcePhase.empty
            : ResourcePhase.ready,
        method: overview != null
            ? 'plugins.getOverview'
            : 'plugin-management.getPluginsOverview',
      ),
    );
  }

  /// Toggle an installed plugin through the desktop's verified management
  /// service.  Marketplace entries and MCP status rows are intentionally not
  /// routed through this method.
  Future<ServiceCallResult> setEnabled({
    required String deviceId,
    required String workspacePath,
    required String id,
    required bool enabled,
  }) async {
    final key = keyOf(deviceId, workspacePath);
    final current = state[key];
    PluginPackageEntry? item;
    for (final candidate
        in current?.overview?.installed ?? const <PluginPackageEntry>[]) {
      if (candidate.id == id) {
        item = candidate;
        break;
      }
    }
    if (item == null) {
      return const ServiceCallResult.failure(
        'plugin_not_found_or_not_installed',
      );
    }

    final relay = ref.read(relaySourceProvider.notifier);
    final result = await relay.callServiceAllowEmpty(
      deviceId,
      'plugin-management',
      'setPluginEnabled',
      [
        {
          ...relay.workspaceScope(
            deviceId: deviceId,
            workspacePath: workspacePath,
          ),
          'pluginId': item.id,
          'enabled': enabled,
          'scope': 'user',
        },
      ],
    );
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

final pluginStatusProvider =
    NotifierProvider<PluginStatusNotifier, Map<String, PluginStatusState>>(
      PluginStatusNotifier.new,
    );

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/resource_list.dart';
import 'relay_source.dart';

/// 设置页中由桌面 Agent service 提供的能力。
enum AgentCapability {
  system,
  commands,
  subagents,
  hooks,
  memory,
  indexing,
  outputStyles;

  String get key => name;

  String get service => switch (this) {
    AgentCapability.system => 'system',
    AgentCapability.commands => 'commands',
    AgentCapability.subagents => 'subagents',
    AgentCapability.hooks => 'hooks',
    AgentCapability.memory => 'memory',
    AgentCapability.indexing => 'setting',
    AgentCapability.outputStyles => 'output-style',
  };
}

class AgentCapabilityState {
  const AgentCapabilityState({
    this.loading = false,
    this.error,
    this.items = const [],
    this.loaded = false,
    this.method,
    this.phase = ResourcePhase.idle,
  });

  final bool loading;
  final String? error;
  final List<AgentResourceEntry> items;
  final bool loaded;
  final String? method;
  final ResourcePhase phase;

  AgentCapabilityState copyWith({
    bool? loading,
    String? error,
    bool clearError = false,
    List<AgentResourceEntry>? items,
    bool? loaded,
    String? method,
    ResourcePhase? phase,
  }) => AgentCapabilityState(
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
    items: items ?? this.items,
    loaded: loaded ?? this.loaded,
    method: method ?? this.method,
    phase: phase ?? this.phase,
  );
}

/// Agent 能力统一读取层。
///
/// 所有列表请求都走明确的 service 名称；没有可靠官方读接口时，状态会
/// 显示“接口未提供”，不会用 WebView 数据或本地假数据冒充原生能力。
class AgentCapabilityNotifier
    extends Notifier<Map<String, AgentCapabilityState>> {
  @override
  Map<String, AgentCapabilityState> build() => const {};

  static String keyOf(
    String deviceId,
    String workspacePath,
    AgentCapability capability,
  ) => '$deviceId|$workspacePath|${capability.key}';

  AgentCapabilityState stateOf(
    String deviceId,
    String workspacePath,
    AgentCapability capability,
  ) =>
      state[keyOf(deviceId, workspacePath, capability)] ??
      const AgentCapabilityState();

  void _set(String key, AgentCapabilityState value) =>
      state = {...state, key: value};

  Future<void> load({
    required String deviceId,
    required String workspacePath,
    required AgentCapability capability,
    bool refresh = false,
  }) async {
    final key = keyOf(deviceId, workspacePath, capability);
    final current = state[key] ?? const AgentCapabilityState();
    if (current.loading || (current.loaded && !refresh)) return;
    _set(
      key,
      current.copyWith(
        loading: true,
        clearError: true,
        phase: ResourcePhase.loading,
      ),
    );

    final result = await _read(
      deviceId: deviceId,
      workspacePath: workspacePath,
      capability: capability,
    );
    if (result == null) {
      _set(
        key,
        current.copyWith(
          loading: false,
          loaded: true,
          error: _unavailableMessage(capability),
          phase: ResourcePhase.unsupported,
        ),
      );
      return;
    }

    _set(
      key,
      AgentCapabilityState(
        loading: false,
        loaded: true,
        items: result.items,
        method: result.method,
        phase: result.items.isEmpty ? ResourcePhase.empty : ResourcePhase.ready,
      ),
    );
  }

  Future<({List<AgentResourceEntry> items, String method})?> _read({
    required String deviceId,
    required String workspacePath,
    required AgentCapability capability,
  }) async {
    final source = ref.read(relaySourceProvider.notifier);
    final args = [
      source.workspaceScope(deviceId: deviceId, workspacePath: workspacePath),
    ];

    switch (capability) {
      case AgentCapability.system:
        final info = await source.callServiceExpectValue(
          deviceId,
          'system',
          'info',
        );
        final items = <AgentResourceEntry>[..._systemInfoItems(info)];
        final shells = await source.callServiceExpectValue(
          deviceId,
          'system',
          'listIntegratedTerminalShells',
        );
        final shellItems = AgentResourceEntry.parseResponse(
          shells,
          preferredKeys: const ['shells', 'terminals', 'items', 'entries'],
        );
        if (shellItems != null) items.addAll(shellItems);
        if (items.isEmpty) return null;
        return (
          items: items,
          method: shellItems == null
              ? 'system.info'
              : 'system.info + system.listIntegratedTerminalShells',
        );

      case AgentCapability.commands:
        // 当前协议资料没有列出 commands.list 的稳定响应；先探测已知
        // 候选，失败就明确呈现不可用，不调用会产生文件副作用的生成接口。
        for (final method in const ['list', 'listCommands']) {
          final value = await source.callServiceExpectValue(
            deviceId,
            'commands',
            method,
            args,
          );
          final items = AgentResourceEntry.parseResponse(
            value,
            preferredKeys: const ['commands', 'items', 'entries'],
          );
          if (items != null) return (items: items, method: 'commands.$method');
        }
        return null;

      case AgentCapability.subagents:
        final value = await source.callServiceExpectValue(
          deviceId,
          'subagents',
          'list',
          [
            {
              ...args.single,
              // The desktop registry keeps subagents under the GLM provider.
              'provider': 'glm',
            },
          ],
        );
        final items = AgentResourceEntry.parseResponse(
          value,
          preferredKeys: const ['subagents', 'agents', 'items', 'entries'],
        );
        return items == null ? null : (items: items, method: 'subagents.list');

      case AgentCapability.hooks:
        final value = await source.callServiceExpectValue(
          deviceId,
          'hooks',
          'loadHooks',
          args,
        );
        final items = AgentResourceEntry.parseResponse(
          value,
          preferredKeys: const ['hooks', 'items', 'entries'],
        );
        return items == null ? null : (items: items, method: 'hooks.loadHooks');

      case AgentCapability.memory:
        // The desktop memory panel reads the user memory through the
        // dedicated loadMemory service.  This returns the actual enabled
        // state and a safe summary without exposing the memory body in the
        // mobile list UI.
        final loaded = await source.callServiceExpectValue(
          deviceId,
          'memory',
          'loadMemory',
          [
            {
              ...source.workspaceScope(
                deviceId: deviceId,
                workspacePath: workspacePath,
              ),
              'agentId': 'zcode',
            },
          ],
        );
        final summary = _memorySummaryItems(loaded);
        if (summary != null) {
          return (items: summary, method: 'memory.loadMemory');
        }

        final value = await source.callServiceExpectValue(
          deviceId,
          'memory',
          'listProjectMemories',
          const [],
        );
        final items = AgentResourceEntry.parseResponse(
          value,
          preferredKeys: const ['memories', 'items', 'entries', 'files'],
        );
        if (items != null) {
          return (items: items, method: 'memory.listProjectMemories');
        }

        // 没有项目记忆时只确认目录服务可用；路径是隐私信息，不显示给用户。
        final directory = await source.callServiceExpectValue(
          deviceId,
          'memory',
          'getUserMemoryDirectory',
        );
        if (directory is Map && directory['path'] is String) {
          return (
            items: const [
              AgentResourceEntry(
                id: 'user-memory-directory',
                title: '用户记忆目录',
                description: '原生记忆目录服务已连接；目录路径已隐藏',
              ),
            ],
            method: 'memory.getUserMemoryDirectory',
          );
        }
        return null;

      case AgentCapability.indexing:
        final value = await source.callServiceExpectValue(
          deviceId,
          'setting',
          'get',
        );
        final items = _indexingItems(value);
        return items == null ? null : (items: items, method: 'setting.get');

      case AgentCapability.outputStyles:
        final value = await source.callServiceExpectValue(
          deviceId,
          'output-style',
          'listStyles',
        );
        final items = AgentResourceEntry.parseResponse(
          value,
          preferredKeys: const ['styles', 'items', 'entries'],
        );
        return items == null
            ? null
            : (items: items, method: 'output-style.listStyles');
    }
  }

  static List<AgentResourceEntry>? _indexingItems(Object? value) {
    if (value is! Map) return null;
    const keys = [
      'nativeSearchEnhancementsEnabled',
      'newFoldersAutoIndexEnabled',
      'grepInstantIndexEnabled',
      'indexingEnabled',
    ];
    final items = <AgentResourceEntry>[];
    for (final key in keys) {
      final flag = value[key];
      if (flag is! bool) continue;
      items.add(
        AgentResourceEntry(
          id: key,
          title: key,
          description: '原生设置读取成功；移动端暂不提供未核验的修改动作',
          enabled: flag,
        ),
      );
    }
    return items;
  }

  static List<AgentResourceEntry>? _memorySummaryItems(Object? value) {
    if (value is! Map || value['memory'] is! Map) return null;
    final memory = Map<Object?, Object?>.from(value['memory'] as Map);
    final content = memory['content']?.toString() ?? '';
    final enabled = memory['enabled'] is bool
        ? memory['enabled'] as bool
        : true;
    return [
      AgentResourceEntry(
        id: 'user-memory',
        title: '用户记忆',
        description: enabled
            ? '原生记忆已启用 · ${content.length} 字符'
            : '原生记忆未启用 · ${content.length} 字符',
        enabled: enabled,
      ),
    ];
  }

  /// Keep the diagnostics page useful without exposing arbitrary desktop
  /// payloads such as workspace paths, usernames, or credential metadata.
  static List<AgentResourceEntry> _systemInfoItems(Object? value) {
    if (value is! Map) return const [];
    const allow = {
      'platform',
      'os',
      'arch',
      'architecture',
      'appVersion',
      'desktopVersion',
      'version',
      'runtime',
      'nodeVersion',
    };
    final out = <AgentResourceEntry>[];
    for (final entry in value.entries) {
      if (entry.key is! String || !allow.contains(entry.key)) continue;
      final raw = entry.value;
      if (raw is! String && raw is! num && raw is! bool) continue;
      out.add(
        AgentResourceEntry(
          id: entry.key.toString(),
          title: entry.key.toString(),
          description: raw.toString(),
        ),
      );
    }
    return out;
  }

  static String _unavailableMessage(AgentCapability capability) =>
      switch (capability) {
        AgentCapability.system => '未能读取系统诊断信息（原生通道不可用或接口未返回）',
        AgentCapability.commands =>
          '桌面端未返回 commands.list；为避免误把生成命令接口当列表接口，当前保持原生只读状态',
        AgentCapability.subagents => '未能读取子代理列表（原生通道不可用或接口未返回）',
        AgentCapability.hooks => '未能读取钩子列表（原生通道不可用或接口未返回）',
        AgentCapability.memory => '未能读取记忆列表（原生通道不可用或接口未返回）',
        AgentCapability.indexing => '未能读取索引设置（原生通道不可用或接口未返回）',
        AgentCapability.outputStyles => '未能读取输出样式（原生通道不可用或接口未返回）',
      };
}

final agentCapabilityProvider =
    NotifierProvider<
      AgentCapabilityNotifier,
      Map<String, AgentCapabilityState>
    >(AgentCapabilityNotifier.new);

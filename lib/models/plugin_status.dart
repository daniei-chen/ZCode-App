import 'resource_list.dart';

/// A plugin package returned by `plugins.getOverview`.
///
/// The overview is intentionally a display model: paths, headers, tokens and
/// arbitrary plugin configuration never cross this boundary.  Installed
/// packages expose only the verified enable/disable action; marketplace
/// catalogue rows remain read-only.
class PluginPackageEntry implements ResourceEntry {
  const PluginPackageEntry({
    required this.id,
    required this.name,
    required this.installed,
    String? description,
    this.version,
    this.source,
    this.enabled = true,
    this.status,
  }) : _summary = description;

  @override
  final String id;

  final String name;
  final bool installed;
  final String? _summary;
  final String? version;
  final String? source;
  @override
  final bool enabled;
  final String? status;

  @override
  String get title => name;

  @override
  String? get description {
    final parts = <String>[
      ?_summary,
      if (version != null) 'v$version',
      ?source,
      ?status,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  String? get group => installed ? '已安装' : '可用';

  @override
  bool get readOnly => !installed;

  @override
  Iterable<String> get searchKeywords => [id, ?source, ?status];

  static PluginPackageEntry? tryParse(
    String key,
    dynamic node, {
    required bool installed,
  }) {
    if (node is String) {
      final value = node.trim();
      return value.isEmpty
          ? null
          : PluginPackageEntry(id: value, name: value, installed: installed);
    }
    if (node is! Map) return null;
    final m = Map<String, dynamic>.from(node);
    String? text(List<String> keys) {
      for (final k in keys) {
        final value = m[k];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
      return null;
    }

    final id = text(const ['id', 'pluginId', 'name', 'key']) ?? key;
    final name = text(const ['displayName', 'title', 'name', 'id']) ?? id;
    return PluginPackageEntry(
      id: id,
      name: name,
      installed: installed,
      description: text(const ['description', 'summary', 'detail']),
      version: text(const ['version', 'pluginVersion']),
      source: text(const ['source', 'origin', 'marketplace']),
      enabled: m['enabled'] is bool ? m['enabled'] as bool : true,
      status: text(const ['status', 'state']),
    );
  }
}

/// Safe marketplace summary.  Only the count and display-safe labels are
/// surfaced; marketplace source URLs can contain credentials in some desktop
/// configurations and are therefore not shown here.
class PluginMarketplaceEntry {
  const PluginMarketplaceEntry({required this.id, required this.name});

  final String id;
  final String name;

  static PluginMarketplaceEntry? tryParse(String key, dynamic node) {
    if (node is String) {
      final name = node.trim();
      return name.isEmpty ? null : PluginMarketplaceEntry(id: key, name: name);
    }
    if (node is! Map) return null;
    final m = Map<String, dynamic>.from(node);
    String? text(List<String> keys) {
      for (final k in keys) {
        final value = m[k];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
      return null;
    }

    final id = text(const ['id', 'name', 'key']) ?? key;
    return PluginMarketplaceEntry(
      id: id,
      name: text(const ['displayName', 'title', 'name', 'id']) ?? id,
    );
  }
}

/// The package/catalog half of `plugins.getOverview`.
class PluginOverview {
  const PluginOverview({
    this.installed = const [],
    this.available = const [],
    this.marketplaces = const [],
    this.capabilitySupported,
    this.capabilityReason,
  });

  final List<PluginPackageEntry> installed;
  final List<PluginPackageEntry> available;
  final List<PluginMarketplaceEntry> marketplaces;
  final bool? capabilitySupported;
  final String? capabilityReason;

  List<ResourceEntry> get entries => [...installed, ...available];

  static PluginOverview? parseResponse(dynamic value) {
    if (value is! Map) return null;
    final root = Map<String, dynamic>.from(value);
    final hasOverviewKeys = root.keys.any(
      (key) => const {
        'installedPlugins',
        'availablePlugins',
        'marketplaces',
        'capability',
      }.contains(key),
    );
    if (!hasOverviewKeys) return null;

    final capability = root['capability'];
    final supported = capability is Map && capability['supported'] is bool
        ? capability['supported'] as bool
        : null;
    final reason = capability is Map && capability['reason'] is String
        ? (capability['reason'] as String).trim()
        : null;
    return PluginOverview(
      installed: _packages(root['installedPlugins'], installed: true),
      available: _packages(root['availablePlugins'], installed: false),
      marketplaces: _marketplaces(root['marketplaces']),
      capabilitySupported: supported,
      capabilityReason: reason?.isEmpty == true ? null : reason,
    );
  }

  static List<PluginPackageEntry> _packages(
    dynamic node, {
    required bool installed,
  }) {
    final out = <PluginPackageEntry>[];
    if (node is List) {
      for (final item in node) {
        final key = item is Map
            ? (item['id'] ?? item['name'] ?? '').toString()
            : item.toString();
        if (key.trim().isEmpty) continue;
        final entry = PluginPackageEntry.tryParse(
          key,
          item,
          installed: installed,
        );
        if (entry != null) out.add(entry);
      }
    } else if (node is Map) {
      node.forEach((key, item) {
        final entry = PluginPackageEntry.tryParse(
          key.toString(),
          item,
          installed: installed,
        );
        if (entry != null) out.add(entry);
      });
    }
    return out;
  }

  static List<PluginMarketplaceEntry> _marketplaces(dynamic node) {
    final out = <PluginMarketplaceEntry>[];
    if (node is List) {
      for (final item in node) {
        final key = item is Map
            ? (item['id'] ?? item['name'] ?? '').toString()
            : item.toString();
        if (key.trim().isEmpty) continue;
        final entry = PluginMarketplaceEntry.tryParse(key, item);
        if (entry != null) out.add(entry);
      }
    } else if (node is Map) {
      node.forEach((key, item) {
        final entry = PluginMarketplaceEntry.tryParse(key.toString(), item);
        if (entry != null) out.add(entry);
      });
    }
    return out;
  }
}

/// 插件提供的 MCP 服务状态。
///
/// 真机实测来自 `zcode-agent.getPluginsOverview({workspacePath})`：
/// ```json
/// {"statuses":{
///   "plugin:document-skills:image_search":{
///     "status":"connected","transport":"http","toolCount":1,
///     "updatedAt":"2026-09-10T10:54:50.023Z","protocolEra":"modern"},
///   "plugin:computer-use:computer-use":{
///     "status":"connected","transport":"stdio","toolCount":30}
/// }}
/// ```
/// key 形如 `plugin:<插件名>:<服务名>`。
///
/// 与技能条目模型同样按容错方式解析：字段缺失或改名不至于让界面空白。
class PluginStatusEntry implements ResourceEntry {
  const PluginStatusEntry({
    required this.id,
    required this.serverName,
    this.pluginName,
    this.status,
    this.transport,
    this.toolCount,
    this.protocolEra,
    this.updatedAt,
    this.raw = const {},
  });

  /// 原始 key（`plugin:xxx:yyy`），稳定且唯一。
  @override
  final String id;

  /// 服务名（key 的最后一段）。
  final String serverName;

  /// 插件名（key 的中间段）。
  final String? pluginName;

  /// 连接状态：`connected` / 其他。
  final String? status;

  /// 传输方式：`http` / `stdio`。
  final String? transport;

  /// 该服务提供的工具数。
  final int? toolCount;

  /// 协议代际：`modern` 等。
  final String? protocolEra;

  final String? updatedAt;

  final Map<String, dynamic> raw;

  @override
  String get title => serverName;

  /// 副标题：把最有信息量的几项拼起来，而不是只显示一个词。
  @override
  String? get description {
    final parts = <String>[
      ?pluginName,
      ?transport,
      if (toolCount != null) '$toolCount 个工具',
      ?protocolEra,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// 分组：按插件名分组（同一插件提供的服务聚在一起）。
  @override
  String? get group => pluginName;

  /// 是否已连接。列表的「启用」开关映射到连接状态。
  @override
  bool get enabled => status == 'connected';

  /// 这些由插件注册，不能在应用里改。
  @override
  bool get readOnly => true;

  /// 插件名也参与搜索 —— 按「哪个插件提供的」筛选是常见用法。
  @override
  Iterable<String> get searchKeywords => [?pluginName, ?status, ?transport, id];

  /// 从 `plugin:<插件>:<服务>` 里切出两段。
  static ({String? plugin, String name}) _splitKey(String key) {
    final parts = key.split(':');
    if (parts.length >= 3) {
      return (plugin: parts[1], name: parts.sublist(2).join(':'));
    }
    if (parts.length == 2) return (plugin: null, name: parts[1]);
    return (plugin: null, name: key);
  }

  static PluginStatusEntry? tryParse(String key, dynamic node) {
    if (node is! Map) return null;
    final m = Map<String, dynamic>.from(node);
    final split = _splitKey(key);

    String? s(Object? v) {
      final t = v?.toString().trim();
      return (t == null || t.isEmpty) ? null : t;
    }

    return PluginStatusEntry(
      id: key,
      serverName: s(m['name']) ?? split.name,
      pluginName: s(m['pluginName']) ?? split.plugin,
      status: s(m['status']),
      transport: s(m['transport']),
      toolCount: m['toolCount'] is num ? (m['toolCount'] as num).toInt() : null,
      protocolEra: s(m['protocolEra']),
      updatedAt: s(m['updatedAt']),
      raw: m,
    );
  }

  /// 解析 `getPluginsOverview` 的响应体（`{statuses:{…}}`）。
  ///
  /// 兼容直接给 map 或 list 的情况。
  static List<PluginStatusEntry>? parseResponse(dynamic value) {
    if (value is! Map) return null;

    final statuses = value['statuses'] ?? value['servers'] ?? value['plugins'];
    if (statuses is Map) {
      final out = <PluginStatusEntry>[];
      statuses.forEach((k, v) {
        final e = tryParse(k.toString(), v);
        if (e != null) out.add(e);
      });
      return out;
    }
    if (statuses is List) {
      final out = <PluginStatusEntry>[];
      for (final item in statuses) {
        if (item is! Map) continue;
        final key = item['id']?.toString() ?? item['name']?.toString() ?? '';
        if (key.isEmpty) continue;
        final e = tryParse(key, item);
        if (e != null) out.add(e);
      }
      return out;
    }
    return null;
  }
}

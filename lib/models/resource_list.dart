/// 设置里「资源列表」这类面板的通用模型。
///
/// 官方有 8 个面板是同一套骨架：搜索 + 状态筛选 + 来源分组 + 启用开关 +
/// 增删改 + 导入导出。这里把「数据」与「呈现」的公共部分抽出来，
/// 各面板只提供自己的 [ResourceEntry] 与数据源。
library;

/// The lifecycle of a native resource panel.
///
/// A boolean `loading` plus a nullable error cannot distinguish an empty
/// response from an unsupported method, a permission failure, or a stale
/// list.  The mobile UI uses this enum as the small state machine shared by
/// skills, MCP, plugins and the other settings resources.
enum ResourcePhase {
  idle,
  loading,
  ready,
  empty,
  stale,
  unsupported,
  permissionDenied,
  error,
}

/// 一条资源。
abstract class ResourceEntry {
  /// 稳定 id。
  String get id;

  /// 主标题。
  String get title;

  /// 副标题（描述）。可空。
  String? get description;

  /// 分组名。可空表示落在默认组。
  String? get group;

  /// 是否已启用。
  bool get enabled;

  /// 由插件注册、不可在本页修改的资源。
  bool get readOnly;

  /// 搜索时需要匹配的额外文本（如来源、目录名）。
  Iterable<String> get searchKeywords => const [];
}

/// 来自独立 Agent service 的安全只读列表项。
///
/// 这些服务的响应在不同桌面版本间字段名会小幅变化，因此只保留展示所需
/// 的白名单字段，不把 headers、token、命令正文或完整原始 payload 带进 UI。
class AgentResourceEntry implements ResourceEntry {
  const AgentResourceEntry({
    required this.id,
    required this.title,
    this.description,
    this.group,
    this.enabled = true,
    this.readOnly = true,
    this.keywords = const [],
  });

  @override
  final String id;

  @override
  final String title;

  @override
  final String? description;

  @override
  final String? group;

  @override
  final bool enabled;

  @override
  final bool readOnly;

  final List<String> keywords;

  @override
  Iterable<String> get searchKeywords => keywords;

  /// 把常见的 `{items:[…]}` / `{commands:[…]}` / Map keyed-by-id 响应
  /// 归一化。找不到数组时返回 null，让页面展示真实的接口不可用状态。
  static List<AgentResourceEntry>? parseResponse(
    Object? value, {
    List<String> preferredKeys = const [],
  }) {
    final nodes = _nodes(value, preferredKeys);
    if (nodes == null) return null;
    return nodes.map(_parse).whereType<AgentResourceEntry>().take(256).toList();
  }

  static List<Object?>? _nodes(Object? value, List<String> preferredKeys) {
    if (value is List) return value.cast<Object?>();
    if (value is! Map) return null;

    for (final key in preferredKeys) {
      final candidate = value[key];
      final nodes = _listLike(candidate);
      if (nodes != null) return nodes;
    }
    for (final key in const [
      'items',
      'entries',
      'list',
      'commands',
      'subagents',
      'agents',
      'hooks',
      'memories',
      'skills',
      'data',
    ]) {
      final candidate = value[key];
      final nodes = _listLike(candidate);
      if (nodes != null) return nodes;
    }

    // 有些版本返回 {"name": {...}, "other": {...}}；只接受 map 值全部
    // 是对象的情况，避免把配置字段误当成资源项。
    final mapValues = value.values.toList();
    if (mapValues.isNotEmpty && mapValues.every((v) => v is Map)) {
      return _mapEntries(value);
    }
    return null;
  }

  static List<Object?>? _listLike(Object? candidate) {
    if (candidate is List) return candidate.cast<Object?>();
    if (candidate is Map &&
        candidate.isNotEmpty &&
        candidate.values.every((v) => v is Map)) {
      return _mapEntries(candidate);
    }
    return null;
  }

  static List<Object?> _mapEntries(Map candidate) => [
    for (final entry in candidate.entries)
      if (entry.value is Map)
        {
          ...Map<String, dynamic>.from(entry.value as Map),
          'id': (entry.value as Map)['id'] ?? entry.key.toString(),
        },
  ];

  static AgentResourceEntry? _parse(Object? node) {
    if (node is String) {
      final text = node.trim();
      if (text.isEmpty) return null;
      return AgentResourceEntry(id: text, title: text);
    }
    if (node is! Map) return null;
    String? text(List<String> keys) {
      for (final key in keys) {
        final value = node[key];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
      return null;
    }

    final id = text(const ['id', 'key', 'name', 'command', 'path']);
    final title = text(const [
      'name',
      'title',
      'label',
      'displayName',
      'command',
      'fileName',
      'id',
      'key',
    ]);
    if (id == null && title == null) return null;
    final group = text(const ['source', 'origin', 'scope', 'category', 'type']);
    final description = text(const [
      'description',
      'summary',
      'detail',
      'subtitle',
      'whenToUse',
      'trigger',
      'event',
    ]);
    final enabled = node['enabled'] is bool ? node['enabled'] as bool : true;
    final keywords = <String>[
      for (final key in const ['source', 'origin', 'scope', 'category', 'type'])
        if (node[key] is String && (node[key] as String).trim().isNotEmpty)
          (node[key] as String).trim(),
    ];
    return AgentResourceEntry(
      id: id ?? title!,
      title: title ?? id!,
      description: description,
      group: group,
      enabled: enabled,
      keywords: keywords,
    );
  }
}

/// 启用状态筛选。
enum ResourceStatusFilter {
  all,
  enabled,
  disabled;

  bool matches(bool enabled) => switch (this) {
    ResourceStatusFilter.all => true,
    ResourceStatusFilter.enabled => enabled,
    ResourceStatusFilter.disabled => !enabled,
  };
}

/// 一次筛选条件。
class ResourceFilter {
  const ResourceFilter({
    this.query = '',
    this.status = ResourceStatusFilter.all,
  });

  final String query;
  final ResourceStatusFilter status;

  bool get isActive =>
      query.trim().isNotEmpty || status != ResourceStatusFilter.all;

  ResourceFilter copyWith({String? query, ResourceStatusFilter? status}) =>
      ResourceFilter(query: query ?? this.query, status: status ?? this.status);
}

/// 分组后的一段。
class ResourceSection {
  const ResourceSection({required this.label, required this.items});

  /// 分组名；null 表示未分组（直接平铺）。
  final String? label;
  final List<ResourceEntry> items;

  int get count => items.length;
}

abstract final class ResourceListing {
  /// 关键词匹配：标题、描述、附加关键词，大小写不敏感。
  static bool matchesQuery(ResourceEntry e, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    if (e.title.toLowerCase().contains(q)) return true;
    final d = e.description;
    if (d != null && d.toLowerCase().contains(q)) return true;
    for (final k in e.searchKeywords) {
      if (k.toLowerCase().contains(q)) return true;
    }
    return false;
  }

  /// 先筛选再分组。
  ///
  /// 分组顺序按标签排序，保证同一批数据每次渲染顺序一致
  /// （设置面板来回切换时不该跳来跳去）。
  static List<ResourceSection> apply(
    List<ResourceEntry> items, {
    ResourceFilter filter = const ResourceFilter(),
  }) {
    final kept = items
        .where((e) => filter.status.matches(e.enabled))
        .where((e) => matchesQuery(e, filter.query))
        .toList();
    if (kept.isEmpty) return const [];

    final grouped = <String?, List<ResourceEntry>>{};
    for (final e in kept) {
      grouped.putIfAbsent(e.group, () => []).add(e);
    }

    final labels = grouped.keys.toList()
      ..sort((a, b) {
        if (a == null) return 1; // 未分组放最后
        if (b == null) return -1;
        return a.compareTo(b);
      });

    return [
      for (final l in labels) ResourceSection(label: l, items: grouped[l]!),
    ];
  }

  /// 计数摘要：(总数, 已启用)。
  static ({int total, int enabled}) counts(List<ResourceEntry> items) {
    var on = 0;
    for (final e in items) {
      if (e.enabled) on++;
    }
    return (total: items.length, enabled: on);
  }

  /// 是否需要显示分组标题（全都同一组时不显示，省视觉噪音）。
  static bool needsGroupHeaders(List<ResourceSection> sections) =>
      sections.length > 1 && sections.any((s) => s.label != null);
}

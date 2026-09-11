import 'resource_list.dart';

/// 一个技能。
///
/// ⚠️ 官方没有公开 schema，实测响应里可见的字段是
/// `{id, name, description, ...}`，`id` 形如 `glm:user:brainstorming:6595ece1`。
/// 这里**按容错方式解析**：字段缺失或改名都不至于让界面空白，
/// 同时保留 [raw] 以便后续按需补充。
class SkillEntry implements ResourceEntry {
  const SkillEntry({
    required this.id,
    required this.name,
    String? description,
    this.enabled = true,
    this.source,
    this.path,
    this.raw = const {},
  }) : _description = description;

  @override
  final String id;

  final String name;

  /// 描述。这里用私有字段 + 覆写 getter 实现 [ResourceEntry.description]。
  final String? _description;

  @override
  String? get description => _description;

  @override
  final bool enabled;

  /// 来源：`user` / `workspace` / `plugin` / `builtin`。
  final String? source;

  /// 技能目录（若上游给了）。
  final String? path;

  final Map<String, dynamic> raw;

  @override
  String get title => name;

  /// 分组名。Plugin 来源的技能单独一组（与官方 `settings.skills.group.*` 一致）。
  @override
  String? get group => switch (source) {
    'plugin' => 'plugin',
    'builtin' => 'builtin',
    _ => 'local',
  };

  /// 由插件 / 内置注册的技能不在本页改动。
  @override
  bool get readOnly => source == 'plugin' || source == 'builtin';

  @override
  Iterable<String> get searchKeywords => [
    ?source,
    ?path,
    if (raw['directoryName'] is String) raw['directoryName'] as String,
  ];

  /// 从 `glm:user:brainstorming:hash` 这类 id 里推出来源。
  ///
  /// 推不出就返回 null（不猜）。
  static String? _sourceFromId(String id) {
    final parts = id.split(':');
    if (parts.length < 2) return null;
    final scope = parts[1].toLowerCase();
    return switch (scope) {
      'user' || 'workspace' || 'plugin' || 'builtin' => scope,
      _ => null,
    };
  }

  /// 容错解析一条；连 id/name 都拿不到才返回 null。
  static SkillEntry? tryParse(dynamic node) {
    if (node is! Map) return null;
    final m = Map<String, dynamic>.from(node);

    String? str(List<String> keys) {
      for (final k in keys) {
        final v = m[k];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
      return null;
    }

    final name = str(['name', 'title', 'directoryName', 'id']);
    if (name == null) return null;
    final id = str(['id', 'directoryName', 'name']) ?? name;

    final source = str(['source', 'origin', 'scope']) ?? _sourceFromId(id);

    return SkillEntry(
      id: id,
      name: name,
      description: str(['description', 'summary', 'detail']),
      enabled: m['enabled'] is bool ? m['enabled'] as bool : true,
      source: source,
      path: str(['path', 'filePath', 'directoryPath']),
      raw: m,
    );
  }

  /// 解析 `skills.list` 的响应体（`{skills:[…]}`）。
  static List<SkillEntry>? parseResponse(dynamic value) {
    final dynamic list = value is Map
        ? (value['skills'] ?? value['items'] ?? value['entries'])
        : value;
    if (list is! List) return null;
    return list.map(SkillEntry.tryParse).whereType<SkillEntry>().toList();
  }

  SkillEntry copyWith({bool? enabled}) => SkillEntry(
    id: id,
    name: name,
    description: description,
    enabled: enabled ?? this.enabled,
    source: source,
    path: path,
    raw: raw,
  );
}

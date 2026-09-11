import 'resource_list.dart';

/// 本地用户目录发现的 MCP 服务器。
///
/// 数据来自桌面端 `listLocalUserMcpCandidates()`。配置对象可能包含
/// `headers`、token 等凭证，因此这里只保留用于列表展示的脱敏字段，
/// 不把完整 config 带进 UI 模型。
class McpServerEntry implements ResourceEntry {
  const McpServerEntry({
    required this.id,
    required this.name,
    required this.enabled,
    this.source,
    this.path,
    this.transport,
    this.endpoint,
    this.command,
    this.status,
    this.remote = false,
  });

  @override
  final String id;

  final String name;

  @override
  final bool enabled;
  final String? source;
  final String? path;
  final String? transport;
  final String? endpoint;
  final String? command;
  final String? status;
  final bool remote;

  @override
  String get title => name;

  @override
  String? get description {
    final parts = <String>[?transport, ?endpoint, ?command, ?status];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// Local user-directory entries can use the verified
  /// `mcp-sync.saveMcpToUserDirectory` toggle.  Remote status rows are a
  /// mirror of the desktop side and stay read-only.
  @override
  bool get readOnly => remote;

  @override
  String? get group {
    final value = source?.toLowerCase() ?? '';
    if (remote) return '远端';
    if (value.contains('plugin')) return 'plugin';
    if (value.contains('builtin') || value.contains('built-in')) {
      return 'builtin';
    }
    return 'local';
  }

  @override
  Iterable<String> get searchKeywords => [
    ?source,
    ?transport,
    ?endpoint,
    ?command,
    ?path,
    id,
  ];

  static McpServerEntry? tryParse(
    String key,
    dynamic node, {
    bool remote = false,
  }) {
    if (node is! Map) return null;
    final item = Map<String, dynamic>.from(node);
    final config = item['config'] is Map
        ? Map<String, dynamic>.from(item['config'] as Map)
        : item;

    String? text(Object? value) {
      final result = value?.toString().trim();
      return result == null || result.isEmpty ? null : result;
    }

    final endpoint = _safeEndpoint(
      config['url'] ?? config['serverUrl'] ?? config['endpoint'],
    );
    final command = _safeCommand(config['command']);
    final transport =
        text(config['transport'] ?? config['type'] ?? item['transport']) ??
        (command == null ? (endpoint == null ? null : 'http') : 'stdio');

    return McpServerEntry(
      id: text(item['id']) ?? key,
      name: text(item['name']) ?? text(item['id']) ?? key,
      enabled: item['enabled'] is bool
          ? item['enabled'] as bool
          : config['enabled'] is bool
          ? config['enabled'] as bool
          : true,
      source: text(item['source']),
      path: text(item['path']),
      transport: transport,
      endpoint: endpoint,
      command: command,
      status: text(item['status'] ?? item['state'] ?? config['status']),
      remote: remote,
    );
  }

  /// 兼容 `{candidates:[...]}`、`{servers:[...]}` 和 map 形态。
  static List<McpServerEntry>? parseResponse(
    dynamic value, {
    bool remote = false,
  }) {
    if (value is! Map) return null;
    final candidates =
        value['candidates'] ??
        value['servers'] ??
        value['mcpServers'] ??
        value['statuses'] ??
        value['remoteServers'];

    if (candidates is List) {
      final out = <McpServerEntry>[];
      for (final item in candidates) {
        if (item is! Map) continue;
        final key = item['id']?.toString() ?? item['name']?.toString() ?? '';
        if (key.isEmpty) continue;
        final entry = tryParse(key, item, remote: remote);
        if (entry != null) out.add(entry);
      }
      return out;
    }

    if (candidates is Map) {
      final out = <McpServerEntry>[];
      candidates.forEach((key, node) {
        final entry = tryParse(key.toString(), node, remote: remote);
        if (entry != null) out.add(entry);
      });
      return out;
    }
    return null;
  }

  static String? _safeEndpoint(Object? value) {
    final raw = value?.toString().trim();
    if (raw == null || raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    final port = uri.hasPort ? ':${uri.port}' : '';
    // 只显示 origin，不把 query、fragment 或路径中的 token 暴露到 UI。
    return '${uri.scheme}://${uri.host}$port';
  }

  static String? _safeCommand(Object? value) {
    final raw = value?.toString().trim();
    if (raw == null || raw.isEmpty) return null;
    final first = raw.split(RegExp(r'\s+')).first;
    return first.length > 80 ? first.substring(0, 80) : first;
  }
}

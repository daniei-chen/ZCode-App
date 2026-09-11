/// 会话正文行模型。
///
/// 数据来自 `zcode-agent.conversationRowsRangeV4` 的响应（JSON），
/// 形状实测自真实桌面端：
///
/// `toolCall`：
/// ```json
/// {"rowId":605,"turnId":"msg_…","entityId":"call_…","productTurnId":"msg_…",
///  "visibility":"visible","createdAt":1789021398251,"createdAtSeq":58815,
///  "kind":"toolCall","assistantResponseId":"msg_…",
///  "toolCallId":"call_…","toolName":"Edit","status":"success",
///  "inputText":"{\"replace_all\":false,\"file_path\":\"…\"}"}
/// ```
///
/// `assistantText`：
/// ```json
/// {"…","kind":"assistantText","assistantResponseId":"msg_…",
///  "text":"写 R4 攻击套件 `test-r4-approval.js`。","state":"complete"}
/// ```
library;

import 'dart:convert';

/// 行种类。
enum ConversationRowKind {
  /// 用户消息（上游 `kind` 实测为 `userInput`）。
  userText,

  /// 助手正文。
  assistantText,

  /// 思考过程。
  reasoning,

  /// 工具调用。
  toolCall,

  /// 钩子调用。
  hookInvocation,

  /// 待批准（授权 / 提问）。**写操作的入口。**
  permission,

  /// 轮次边界。
  turnHeader,

  /// 时间线上的标记（实测为模型切换）。
  timelineMarker,

  /// 其他（保留原文）。
  unknown;

  static ConversationRowKind parse(String? raw) => switch (raw) {
    'userText' || 'user' || 'userInput' => ConversationRowKind.userText,
    'assistantText' || 'assistant' => ConversationRowKind.assistantText,
    'reasoning' => ConversationRowKind.reasoning,
    'toolCall' => ConversationRowKind.toolCall,
    'hookInvocation' => ConversationRowKind.hookInvocation,
    'permission' => ConversationRowKind.permission,
    'turnHeader' => ConversationRowKind.turnHeader,
    'timelineMarker' => ConversationRowKind.timelineMarker,
    _ => ConversationRowKind.unknown,
  };

  /// 是否适合直接展示大段文本。
  bool get hasBodyText =>
      this == ConversationRowKind.assistantText ||
      this == ConversationRowKind.userText ||
      this == ConversationRowKind.reasoning;

  /// 是否是需要用户处理的交互。
  bool get needsUserAction => this == ConversationRowKind.permission;
}

/// 授权选项（`permission` 行的 `options[]`）。
class PermissionOption {
  const PermissionOption({
    required this.optionId,
    required this.label,
    this.kind,
  });

  final String optionId;
  final String label;

  /// `allowOnce` / `allowAlways` / `deny` / `custom`。
  final String? kind;

  /// 是否属于"允许"。
  bool get isAllow => kind == 'allowOnce' || kind == 'allowAlways';

  bool get isDeny => kind == 'deny';

  static PermissionOption? tryParse(dynamic node) {
    if (node is! Map) return null;
    final id = node['optionId'];
    final label = node['label'];
    if (id is! String || id.isEmpty) return null;
    return PermissionOption(
      optionId: id,
      label: label is String && label.isNotEmpty ? label : id,
      kind: node['kind']?.toString(),
    );
  }
}

/// 一条待办（`TodoWrite` 类工具调用的产物）。
class TodoItem {
  const TodoItem({required this.title, required this.status});

  final String title;

  /// `pending` / `in_progress` / `completed`。
  final String status;

  bool get isDone => status == 'completed';
  bool get isActive => status == 'in_progress';

  static TodoItem? tryParse(dynamic node) {
    if (node is String) {
      final t = node.trim();
      return t.isEmpty ? null : TodoItem(title: t, status: 'pending');
    }
    if (node is! Map) return null;
    final title =
        (node['title'] ?? node['content'] ?? node['text'] ?? node['step'])
            ?.toString()
            .trim();
    if (title == null || title.isEmpty) return null;
    final raw = node['status']?.toString().replaceAll('-', '_').toLowerCase();
    final status = switch (raw) {
      'pending' || 'in_progress' || 'completed' => raw!,
      _ => 'pending',
    };
    return TodoItem(title: title, status: status);
  }
}

/// 一条正文行。
class ConversationRow {
  const ConversationRow({
    required this.rowId,
    required this.kind,
    this.turnId,
    this.entityId,
    this.createdAt,
    this.createdAtSeq,
    this.visibility,
    this.text,
    this.toolName,
    this.toolCallId,
    this.status,
    this.inputText,
    this.permissionOptions = const [],
    this.raw = const {},
  });

  /// 行号（稳定、可用于翻页游标）。
  final int? rowId;

  final ConversationRowKind kind;

  /// 所属轮次。
  final String? turnId;

  /// 实体 id（工具调用是 `call_…`，文本是 `msg_…`）。
  final String? entityId;

  final int? createdAt;
  final int? createdAtSeq;

  /// `visible` / 其他。非 visible 的行按需过滤。
  final String? visibility;

  /// 文本正文（assistantText / reasoning / userText）。
  final String? text;

  /// 工具名（toolCall）。
  final String? toolName;

  final String? toolCallId;

  /// 工具状态（`success` / `error` / …）。
  final String? status;

  /// 工具入参的**原始 JSON 字符串**，按需解析。
  final String? inputText;

  /// `permission` 行的可选项。
  final List<PermissionOption> permissionOptions;

  /// 原始行，保留未知字段。
  final Map<String, dynamic> raw;

  bool get isVisible => visibility == null || visibility == 'visible';

  String? get startedAtIso => createdAt == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(createdAt!).toIso8601String();

  static int? _asInt(dynamic v) => v is int ? v : (v is num ? v.toInt() : null);

  static String? _asString(dynamic v) => v is String && v.isNotEmpty ? v : null;

  static ConversationRow? tryParse(dynamic node) {
    if (node is! Map) return null;
    final m = Map<String, dynamic>.from(node);
    final kind = ConversationRowKind.parse(_asString(m['kind']));
    return ConversationRow(
      rowId: _asInt(m['rowId']),
      kind: kind,
      turnId: _asString(m['turnId']),
      entityId: _asString(m['entityId']),
      createdAt: _asInt(m['createdAt']),
      createdAtSeq: _asInt(m['createdAtSeq']),
      visibility: _asString(m['visibility']),
      text: _asString(m['text']),
      toolName: _asString(m['toolName']),
      toolCallId: _asString(m['toolCallId']),
      status: _asString(m['status']),
      inputText: _asString(m['inputText']),
      permissionOptions: m['options'] is List
          ? (m['options'] as List)
                .map(PermissionOption.tryParse)
                .whereType<PermissionOption>()
                .toList()
          : const [],
      raw: m,
    );
  }

  /// 解析 `conversationRowsRangeV4` 的响应体（`{rows:[…]}`）。
  ///
  /// 也接受直接给数组；都拿不到返回 null。
  static List<ConversationRow>? parseResponse(dynamic value) {
    final dynamic rows = value is Map ? value['rows'] : value;
    if (rows is! List) return null;
    final out = <ConversationRow>[];
    for (final r in rows) {
      final row = tryParse(r);
      if (row != null) out.add(row);
    }
    return out;
  }

  /// 按 `rowId` 升序（桌面端给的是倒序分页）。
  static List<ConversationRow> sortedAscending(List<ConversationRow> rows) {
    final copy = [...rows];
    copy.sort((a, b) => (a.rowId ?? 0).compareTo(b.rowId ?? 0));
    return copy;
  }

  /// 最小 rowId（继续向上翻页用的游标）。
  static int? oldestRowId(List<ConversationRow> rows) {
    int? min;
    for (final r in rows) {
      final id = r.rowId;
      if (id == null) continue;
      if (min == null || id < min) min = id;
    }
    return min;
  }

  /// 工具调用的一句话摘要（用于紧凑行展示）。
  ///
  /// `inputText` 是 JSON 字符串；不同工具的关键字段不一样，按工具名挑，
  /// 挑不到就退回第一个字符串值。解析失败则截断原文。
  String get summary {
    final raw = inputText;
    if (raw == null || raw.isEmpty) return '';
    Map<String, dynamic>? m;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) m = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return _clip(raw, 80);
    }
    if (m == null) return '';

    String? pick(List<String> keys) {
      for (final k in keys) {
        if (_isSensitiveKey(k)) continue;
        final v = m![k];
        if (v is String && v.isNotEmpty) return v;
        if (v is num || v is bool) return v.toString();
      }
      return null;
    }

    final n = toolName ?? '';
    String? val;
    if (_shellTools.contains(n)) {
      val = pick(const ['command', 'cmd']);
    } else if (_fileTools.contains(n)) {
      val = pick(const ['file_path', 'path', 'notebook_path']);
      if (val != null) val = fileBasename(val);
    } else if (_searchTools.contains(n)) {
      val = pick(const ['pattern', 'query', 'glob']);
    } else if (_webTools.contains(n)) {
      val = pick(const ['url', 'query']);
    } else if (_agentTools.contains(n)) {
      val = pick(const ['description', 'prompt']);
    }
    val ??= pick(const [
      'command',
      'file_path',
      'path',
      'pattern',
      'query',
      'description',
    ]);
    val ??= m.entries
        .where((e) => !_isSensitiveKey(e.key))
        .map((e) => e.value)
        .whereType<String>()
        .firstOrNull;

    return val == null ? '' : _clip(val, 90);
  }

  /// 待办类工具名的识别规则。
  ///
  /// 与官方一致：匹配 `todo_read` / `todo_write` / `update_plan`，
  /// 分隔符（`_` `-` 空格）与大小写不敏感。
  static final _todoToolPattern = RegExp(
    r'(?:^|[_\s-])(?:todo[_\s-]*(?:read|write)|update[_\s-]*plan)(?:$|[_\s-])',
    caseSensitive: false,
  );

  /// 待办清单在入参里的容器键（官方用这四个）。
  static const _todoKeys = ['todos', 'plan', 'steps', 'items'];

  /// 是否待办类工具调用。
  bool get isTodoCall {
    final n = toolName;
    if (n == null) return false;
    if (!_todoToolPattern.hasMatch(n)) return false;
    return todos.isNotEmpty;
  }

  /// 解析出的待办清单（非待办工具返回空）。
  List<TodoItem> get todos {
    final raw = inputText;
    if (raw == null || raw.isEmpty) return const [];
    Map<String, dynamic>? m;
    try {
      final d = jsonDecode(raw);
      if (d is Map) m = Map<String, dynamic>.from(d);
    } catch (_) {
      return const [];
    }
    if (m == null) return const [];
    for (final k in _todoKeys) {
      final v = m[k];
      if (v is List) {
        final items = v.map(TodoItem.tryParse).whereType<TodoItem>().toList();
        if (items.isNotEmpty) return items;
      }
    }
    return const [];
  }

  /// 用户消息的来源（`userInput` 行的 `origin`）。
  ///
  /// 实测取值：`realUser` / `backgroundResult` / `goalContinuation` /
  /// `mailbox` / `synthetic`。**只有 realUser 才是真人发言**，
  /// 后台结果长得像用户消息会让人误解来源。
  String? get userInputOrigin => raw['origin']?.toString();

  /// 是否是真人输入（没有 origin 字段时按真人处理）。
  bool get isRealUserInput {
    final o = userInputOrigin;
    return o == null || o == 'realUser';
  }

  /// 轮次标题（`turnHeader.originMeta.title`，实测是任务的简短描述）。
  String? get turnTitle {
    final m = raw['originMeta'];
    if (m is! Map) return null;
    final t = m['title']?.toString().trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  /// 轮次来源（`userInput` / `backgroundResult` / `goalContinuation` / `editRerun`）。
  String? get turnOrigin => raw['origin']?.toString();

  /// 轮次实际耗时（毫秒）。
  int? get activeMs =>
      raw['activeMs'] is num ? (raw['activeMs'] as num).toInt() : null;

  /// 时间线标记（实测为模型切换）。
  ({String type, String? fromModel, String? toModel, String? toThought})?
  get marker {
    final m = raw['marker'];
    if (m is! Map) return null;
    final type = m['type']?.toString();
    if (type == null) return null;
    String? s(Object? v) {
      final t = v?.toString().trim();
      return (t == null || t.isEmpty) ? null : t;
    }

    return (
      type: type,
      fromModel: s(m['fromModel']),
      toModel: s(m['toModel']),
      toThought: s(m['toThought']),
    );
  }

  /// `permission` 行的一句话说明（官方字段是 `summary`）。
  String get permissionSummary =>
      (raw['summary']?.toString().trim().isNotEmpty ?? false)
      ? _redactText(raw['summary'].toString().trim())
      : _redactText(summary.isEmpty ? (toolName ?? '') : summary);

  static const _shellTools = {'Bash', 'Shell', 'Terminal'};
  static const _fileTools = {'Edit', 'Write', 'Read', 'NotebookEdit'};
  static const _searchTools = {'Grep', 'Glob', 'Search'};
  static const _webTools = {'WebFetch', 'WebSearch'};
  static const _agentTools = {'Task', 'Agent'};

  static String _clip(String s, int n) =>
      s.length > n ? '${s.substring(0, n)}…' : s;

  static final _sensitiveKeyPattern = RegExp(
    r'(token|secret|password|passwd|api[_-]?key|authorization|cookie|credential|private[_-]?key|access[_-]?key|signature|hash)',
    caseSensitive: false,
  );

  static bool _isSensitiveKey(String key) => _sensitiveKeyPattern.hasMatch(key);

  static String _redactText(String input) => input.replaceAllMapped(
    RegExp(
      r'''\b(authorization|token|password|secret|api[_-]?key|cookie)\b\s*[:=]\s*("[^"]*"|'[^']*'|[^\s,}]+)''',
      caseSensitive: false,
    ),
    (m) => '${m.group(1)}=<hidden>',
  );

  static Object? _redactJson(Object? value, int depth, List<int> budget) {
    if (depth > 10 || budget.first++ > 2048) return '<hidden>';
    if (value is Map) {
      final out = <String, Object?>{};
      for (final entry in value.entries) {
        final key = entry.key.toString();
        out[key] = _isSensitiveKey(key)
            ? '<hidden>'
            : _redactJson(entry.value, depth + 1, budget);
      }
      return out;
    }
    if (value is List) {
      return [
        for (final item in value.take(256))
          _redactJson(item, depth + 1, budget),
      ];
    }
    if (value is String) return _redactText(value);
    return value;
  }

  /// 取路径末段（兼容 Windows 反斜杠）。
  static String fileBasename(String path) {
    final p = path.replaceAll('\\', '/');
    final i = p.lastIndexOf('/');
    return i >= 0 && i + 1 < p.length ? p.substring(i + 1) : path;
  }

  /// 入参美化：能解析就缩进两格，不能就原样返回。
  String get prettyInput {
    final raw = inputText;
    if (raw == null || raw.isEmpty) return '';
    try {
      final budget = [0];
      final safe = _redactJson(jsonDecode(raw), 0, budget);
      return _clip(const JsonEncoder.withIndent('  ').convert(safe), 12000);
    } catch (_) {
      return _clip(_redactText(raw), 12000);
    }
  }

  /// 待办完成数（列表里显示 x/y 用）。
  static ({int done, int total}) todoProgress(List<TodoItem> items) {
    var done = 0;
    for (final t in items) {
      if (t.isDone) done++;
    }
    return (done: done, total: items.length);
  }

  @override
  String toString() =>
      'ConversationRow(#$rowId ${kind.name}'
      '${toolName == null ? '' : ' $toolName'}'
      '${status == null ? '' : ' $status'})';
}

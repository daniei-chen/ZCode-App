import 'dart:convert';

const int kMaxListenBytes = 4194304;

abstract final class EventObserver {
  static const String hookScript =
      '''
(function() {
  if (window.__zrHooked) return;
  window.__zrHooked = true;
  var q = [];
  var qBytes = 0;
  var qMaxEntries = 2048;
  var post = function(name, body) {
    try {
      var h = window.flutter_inappwebview;
      if (h && h.callHandler) {
        h.callHandler(name, body);
        return;
      }
      if (q.length >= qMaxEntries) {
        qBytes -= q.shift().b.length;
      }
      q.push({ n: name, b: body });
      qBytes += body.length;
      while (qBytes > $kMaxListenBytes && q.length > 1) {
        qBytes -= q.shift().b.length;
      }
    } catch (e) {}
  };
  var flush = function() {
    var h = window.flutter_inappwebview;
    if (!h || !h.callHandler) return false;
    while (q.length > 0) {
      var m = q.shift();
      qBytes -= m.b.length;
      try { h.callHandler(m.n, m.b); } catch (e) {}
    }
    return true;
  };
  window.addEventListener('flutterInAppWebViewPlatformReady', function() { flush(); }, false);
  var flushTries = 0;
  var flushTimer = setInterval(function() {
    // 通道长期缺席（页面环境异常）时最多空转约 30s 后放弃；通道晚就绪
    // 另有 flutterInAppWebViewPlatformReady 事件兜底。
    if (flush() || ++flushTries > 250) clearInterval(flushTimer);
  }, 120);
  var send = function(body) { post('zrEvents', body); };
  var seenQ = [];
  var seenFlush = setInterval(function() {
    if (seenQ.length === 0 || !window.flutter_inappwebview) return;
    var batch = seenQ.splice(0, seenQ.length);
    post('zrSeen', JSON.stringify(batch));
  }, 900);
  var recordSeen = function(url, method, body) {
    try {
      if (seenQ.length >= 64) return;
      if (typeof url !== 'string' || url.length > 2048) return;
      var b = null;
      if (typeof body === 'string') b = body;
      else if (body && typeof body === 'object') {
        try { b = JSON.stringify(body); } catch (e2) { b = null; }
      }
      if (b && b.length > 16384) return;
      seenQ.push({ u: url, m: String(method || 'GET').toUpperCase(), b: b });
    } catch (e) {}
  };
  var asm = {};
  var asmOrder = [];
  var b64Bytes = function(b64) {
    var bin = atob(b64);
    var bytes = new Uint8Array(bin.length);
    for (var k = 0; k < bin.length; k++) bytes[k] = bin.charCodeAt(k);
    return bytes;
  };
  var tryDecodePayload = function(p) {
    try {
      if (!p || typeof p.dataBase64 !== 'string' || p.dataBase64.length === 0) return;
      var sizeHint = p.messageBytes != null ? p.messageBytes : Math.ceil(p.dataBase64.length * 0.75);
      var bytesCapOk = sizeHint < $kMaxListenBytes;
      if (!bytesCapOk) return;
      var bytes;
      if (p.kind === 'fragment' && p.fragmentCount > 1) {
        var id = p.logicalFrameId;
        if (!id) return;
        var slot = asm[id];
        if (!slot) {
          if (asmOrder.length > 32) { delete asm[asmOrder.shift()]; }
          slot = asm[id] = { parts: {}, got: 0, total: p.fragmentCount };
          asmOrder.push(id);
        }
        if (!(p.fragmentIndex in slot.parts)) slot.got++;
        slot.parts[p.fragmentIndex] = b64Bytes(p.dataBase64);
        if (slot.got < slot.total) return;
        delete asm[id];
        var idx = asmOrder.indexOf(id);
        if (idx >= 0) asmOrder.splice(idx, 1);
        var size = 0;
        for (var q = 0; q < slot.total; q++) size += (slot.parts[q] || {length:0}).length;
        if (size > $kMaxListenBytes) return;
        bytes = new Uint8Array(size);
        var off = 0;
        for (var q2 = 0; q2 < slot.total; q2++) {
          var part = slot.parts[q2];
          if (!part) return;
          bytes.set(part, off);
          off += part.length;
        }
      } else {
        bytes = b64Bytes(p.dataBase64);
      }
      var text = new TextDecoder('utf-8', {fatal: false}).decode(bytes);
      if (text && text.length > 0) {
        var first = text.indexOf('{');
        var last = text.lastIndexOf('}');
        if (first > 0 && last > first) {
          text = text.slice(first, last + 1);
        }
        if (text && text.length > 0) send(text);
      }
    } catch (e) {}
  };
  // A relay message has appeared in three equivalent shapes across desktop
  // versions: the rpc frame can be the root object, `payload`, or `frame`.
  // Walk those envelopes so session-index responses are observed even when
  // the official page is currently displaying a different conversation.
  var decodeEnvelope = function(node, depth) {
    if (!node || typeof node !== 'object' || depth > 6) return;
    if (typeof node.dataBase64 === 'string') tryDecodePayload(node);
    var keys = ['payload', 'frame', 'data', 'body', 'message'];
    for (var i = 0; i < keys.length; i++) {
      var child = node[keys[i]];
      if (child && typeof child === 'object') decodeEnvelope(child, depth + 1);
    }
  };
  var sendWithDecode = function(body) {
    send(body);
    try {
      var env = JSON.parse(body);
      decodeEnvelope(env, 0);
    } catch (e) {}
  };
  var origFetch = window.fetch;
  if (origFetch) {
    window.fetch = function() {
      try {
        var u = arguments[0], init = arguments[1];
        var url = typeof u === 'string' ? u : ((u && u.url) || '');
        var method = (init && init.method) || '';
        if (url && method && String(method).toUpperCase() !== 'OPTIONS') {
          recordSeen(url, method, init && init.body);
        }
        if (url.indexOf('/mobile-view-state') >= 0 &&
            String(method).toUpperCase() === 'POST') {
          var b = init && init.body;
          if (typeof b === 'string' && b.length > 0) {
            post('zrViewState', b);
          }
        }
      } catch (e) {}
      var p = origFetch.apply(this, arguments);
      return p.then(function(res) {
        try {
          if (res.status !== 200) return res;
          var ct = (res.headers && res.headers.get)
              ? (res.headers.get('content-type') || '')
              : '';
          if (/^(image|audio|video|font)\\//.test(ct)) return res;
          var cl = (res.headers && res.headers.get)
              ? res.headers.get('content-length')
              : null;
          if (cl && +cl > $kMaxListenBytes) return res;
          res.clone().text().then(function(t) {
            if (t && t.length > 0 && t.length < $kMaxListenBytes) sendWithDecode(t);
          }).catch(function() {});
        } catch (e) {}
        return res;
      });
    };
  }
  var OrigES = window.EventSource;
  if (OrigES) {
    var Wrapped = function(url, cfg) {
      var es = new OrigES(url, cfg);
      es.addEventListener('message', function(ev) { sendWithDecode(ev.data); });
      return es;
    };
    Wrapped.prototype = OrigES.prototype;
    var statics = ['CONNECTING', 'OPEN', 'CLOSED'];
    for (var i = 0; i < statics.length; i++) {
      Wrapped[statics[i]] = OrigES[statics[i]];
    }
    window.EventSource = Wrapped;
  }
  var OrigWS = window.WebSocket;
  if (OrigWS) {
    var wsSend = function(event) {
      post('zrWs', event);
    };
    var WSWrapped = function(url, protocols) {
      var ws = (protocols === undefined)
          ? new OrigWS(url)
          : new OrigWS(url, protocols);
      try {
        var urlStr = (url && url.href) ? url.href : String(url);
        ws.addEventListener('open', function() {
          wsSend(JSON.stringify({s: 'open', u: urlStr}));
        });
        ws.addEventListener('close', function(ev) {
          wsSend(JSON.stringify({s: 'closed', u: urlStr, c: ev && ev.code, r: (ev && ev.reason) || ''}));
        });
        ws.addEventListener('message', function(ev) {
          try {
            var d = ev.data;
            if (typeof d === 'string') {
              sendWithDecode(d);
            } else if (d && typeof d.size === 'number') {
              if (d.size > 0 && d.size < $kMaxListenBytes) {
                d.text().then(function(t) { sendWithDecode(t); }).catch(function() {});
              }
            } else if (d && d.byteLength > 0 && d.byteLength < $kMaxListenBytes) {
              try { sendWithDecode(new TextDecoder('utf-8', {fatal: false}).decode(d)); } catch (e2) {}
            }
          } catch (e) {}
        });
      } catch (e) {}
      return ws;
    };
    WSWrapped.prototype = OrigWS.prototype;
    var wsStatics = ['CONNECTING', 'OPEN', 'CLOSED'];
    for (var j = 0; j < wsStatics.length; j++) {
      WSWrapped[wsStatics[j]] = OrigWS[wsStatics[j]];
    }
    window.WebSocket = WSWrapped;
  }
})();
''';
}

const Set<String> kKnownEventTypes = {
  'created',
  'prompt_sent',
  'resumed',
  'streaming',
  'permission_request',
  'permission_resolved',
  'elicitation_request',
  'elicitation_resolved',
  'updated',
  'completed',
  'error',
};

const Set<String> kNotifiableTypes = {
  'permission_request',
  'elicitation_request',
  'completed',
  'error',
};

class ObservedEvent {
  const ObservedEvent({
    required this.type,
    this.taskId,
    this.sessionTitle,
    this.summary,
  });

  final String type;

  final String? taskId;

  final String? sessionTitle;

  final String? summary;

  ObservedEvent copyWith({String? sessionTitle, String? summary}) =>
      ObservedEvent(
        type: type,
        taskId: taskId,
        sessionTitle: sessionTitle ?? this.sessionTitle,
        summary: summary ?? this.summary,
      );
}

abstract final class EventParser {
  static const int _maxDepth = 3;

  static List<ObservedEvent> parseMessage(String body) {
    final dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    return parseRoot(root);
  }

  static List<ObservedEvent> parseRoot(dynamic root) {
    final events = <ObservedEvent>[];
    _walk(root, 0, events);
    return events;
  }

  /// Returns only events that represent an immediate user action request.
  ///
  /// Completion and failure are deliberately not returned here. The remote
  /// page carries many nested `type`/`event` values while a reply is still
  /// streaming (for example a tool step finishing or a reasoning item being
  /// updated). Those values are not proof that the whole assistant turn has
  /// ended. The callers use [StateDiffer] for the terminal transition instead.
  static List<ObservedEvent> parseUserActionRoot(dynamic root) =>
      parseRoot(root)
          .where((event) {
            final hasTarget = event.taskId != null && event.taskId!.isNotEmpty;
            return hasTarget &&
                (event.type == 'permission_request' ||
                    event.type == 'elicitation_request');
          })
          .toList(growable: false);

  /// Removes duplicate representations of one event in a relay delivery.
  /// The same request can arrive once as an explicit event and once alongside
  /// the state delta that produced it.
  static List<ObservedEvent> dedupe(Iterable<ObservedEvent> input) {
    final seen = <String>{};
    final result = <ObservedEvent>[];
    for (final event in input) {
      final key = '${event.type}\u0000${event.taskId ?? ''}';
      if (seen.add(key)) result.add(event);
    }
    return result;
  }

  static void _walk(dynamic node, int depth, List<ObservedEvent> out) {
    if (depth > _maxDepth || node == null) return;
    if (node is Map) {
      final type = _eventTypeOf(node);
      if (type != null) out.add(_eventFrom(node, type));
      for (final value in node.values) {
        _walk(value, depth + 1, out);
      }
    } else if (node is List) {
      for (final value in node) {
        _walk(value, depth + 1, out);
      }
    }
  }

  static String? _eventTypeOf(Map<dynamic, dynamic> node) {
    for (final key in const ['event', 'type']) {
      final value = node[key];
      if (value is String && kKnownEventTypes.contains(value)) return value;
    }
    return null;
  }

  static ObservedEvent _eventFrom(Map<dynamic, dynamic> node, String type) {
    String? taskId;
    for (final key in const ['taskId', 'task_id']) {
      final value = node[key];
      if (value is String && value.isNotEmpty) {
        taskId = value;
        break;
      }
    }

    final summary = _firstEventText(
      node,
      type == 'permission_request' || type == 'elicitation_request'
          ? const ['description', 'summary', 'title', 'kind', 'toolName']
          : const [
              'summary',
              'content',
              'text',
              'message',
              'result',
              'error',
              'output',
              'response',
              'description',
            ],
    );

    return ObservedEvent(type: type, taskId: taskId, summary: summary);
  }

  static String? _firstEventText(
    Map<dynamic, dynamic> node,
    List<String> keys,
  ) {
    for (final key in keys) {
      final text = _eventText(node[key]);
      if (text != null) return text;
    }
    return null;
  }

  static String? _eventText(Object? value) {
    if (value is String) {
      final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) return null;
      return text.length > 180 ? '${text.substring(0, 180)}…' : text;
    }
    if (value is Map) {
      for (final key in const [
        'text',
        'content',
        'message',
        'body',
        'response',
        'output',
      ]) {
        final text = _eventText(value[key]);
        if (text != null) return text;
      }
    }
    return null;
  }
}

class SessionState {
  const SessionState({
    required this.sessionId,
    this.title,
    this.phase,
    this.sessionEnded,
    this.permissionCount = 0,
    this.userInputCount = 0,
    this.interactionKind,
    this.toolName,
    this.description,
    this.preview,
    this.lastActivityAt,
    this.createdAt,
    this.workspace,
    this.workspacePath,
    this.pinned = false,
  });

  final String sessionId;
  final String? title;
  final String? phase;
  final bool? sessionEnded;
  final int permissionCount;
  final int userInputCount;
  final String? interactionKind;
  final String? toolName;

  final String? description;

  /// 最近一段可恢复的会话正文，用于完成/失败通知的正文预览。
  final String? preview;

  final int? lastActivityAt;

  final int? createdAt;

  /// 工作区显示名（relay 侧是 `workspaceLabel`）。
  final String? workspace;

  /// 工作区**完整路径**。relay 的会话接口（订阅 / 拉正文）需要它。
  final String? workspacePath;

  final bool pinned;

  @override
  bool operator ==(Object other) =>
      other is SessionState &&
      other.sessionId == sessionId &&
      other.title == title &&
      other.phase == phase &&
      other.sessionEnded == sessionEnded &&
      other.permissionCount == permissionCount &&
      other.userInputCount == userInputCount &&
      other.interactionKind == interactionKind &&
      other.toolName == toolName &&
      other.description == description &&
      other.preview == preview &&
      other.lastActivityAt == lastActivityAt &&
      other.createdAt == createdAt &&
      other.workspace == workspace &&
      other.workspacePath == workspacePath &&
      other.pinned == pinned;

  @override
  int get hashCode => Object.hashAll([
    sessionId,
    title,
    phase,
    sessionEnded,
    permissionCount,
    userInputCount,
    interactionKind,
    toolName,
    description,
    preview,
    lastActivityAt,
    createdAt,
    workspace,
    workspacePath,
    pinned,
  ]);
}

abstract final class SessionStateExtractor {
  static const int _maxDepth = 8;

  static List<SessionState> parse(String body) {
    final dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    return parseRoot(root);
  }

  static List<SessionState> parseRoot(dynamic root) {
    final states = <SessionState>[];
    _walk(root, 0, states);
    return states;
  }

  static List<String> parseRemoved(String body) {
    final dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    return parseRemovedRoot(root);
  }

  static List<String> parseRemovedRoot(dynamic root) {
    final removed = <String>[];
    _walkRemoved(root, 0, removed);
    return removed;
  }

  static void _walkRemoved(dynamic node, int depth, List<String> out) {
    if (depth > _maxDepth || node == null) return;
    if (node is Map) {
      if (node['op'] == 'session.removed') {
        final id = node['sessionId'];
        if (id is String && id.isNotEmpty) out.add(id);
      }
      for (final value in node.values) {
        _walkRemoved(value, depth + 1, out);
      }
    } else if (node is List) {
      for (final value in node) {
        _walkRemoved(value, depth + 1, out);
      }
    }
  }

  static String? workspaceBasenameOf(String? id) {
    if (id == null) return null;
    final trimmed = id.trim();
    if (trimmed.isEmpty) return null;
    final slash = trimmed.lastIndexOf('/');
    final backslash = trimmed.lastIndexOf(r'\');
    final cut = slash > backslash ? slash : backslash;
    final base = (cut < 0 ? trimmed : trimmed.substring(cut + 1)).trim();
    return base.isEmpty ? null : base;
  }

  static void _walk(dynamic node, int depth, List<SessionState> out) {
    if (depth > _maxDepth || node == null) return;
    if (node is Map) {
      final state = _stateOf(node);
      if (state != null) out.add(state);
      for (final value in node.values) {
        _walk(value, depth + 1, out);
      }
    } else if (node is List) {
      for (final value in node) {
        _walk(value, depth + 1, out);
      }
    }
  }

  static SessionState? _stateOf(Map<dynamic, dynamic> node) {
    final id = node['sessionId'];
    if (id is! String || id.isEmpty) return null;
    final hasSummary = node['pendingInteractionSummary'] is Map;
    final hasEnded = node['sessionEnded'] is bool;
    final hasPhase = node['phase'] is String;
    if (!hasSummary && !hasEnded && !hasPhase) return null;

    var permCount = 0;
    var userInputCount = 0;
    final summary = node['pendingInteractionSummary'];
    if (summary is Map) {
      final p = summary['permissionCount'];
      final u = summary['userInputCount'];
      if (p is int) permCount = p;
      if (u is int) userInputCount = u;
    }

    String? interactionKind;
    String? toolName;
    String? description;
    final interaction = node['pendingInteraction'];
    if (interaction is Map) {
      final k = interaction['kind'];
      final t = interaction['toolName'];
      if (k is String) interactionKind = k;
      if (t is String) toolName = t;
      for (final key in const ['description', 'summary']) {
        final d = interaction[key];
        if (d is String && d.isNotEmpty) {
          description = d;
          break;
        }
      }
    }

    final title = node['title'];
    final laa = node['lastActivityAt'];
    final ca = node['createdAt'];
    final workspacePath = _firstString(node, const [
      'workspacePath',
      'workspaceId',
    ]);
    final workspaceLabel = _firstString(node, const [
      'workspaceLabel',
      'workspace',
    ]);
    return SessionState(
      sessionId: id,
      title: title is String ? title : null,
      phase: node['phase'] is String ? node['phase'] as String? : null,
      sessionEnded: node['sessionEnded'] is bool
          ? node['sessionEnded'] as bool?
          : null,
      permissionCount: permCount,
      userInputCount: userInputCount,
      interactionKind: interactionKind,
      toolName: toolName,
      description: description,
      preview: previewOf(node),
      lastActivityAt: laa is num ? laa.toInt() : null,
      createdAt: ca is num ? ca.toInt() : null,
      workspace: workspaceLabel ?? workspaceBasenameOf(workspacePath),
      workspacePath: workspacePath,
    );
  }

  /// 从不同桌面端版本的任务快照中提取最近正文。字段不存在时返回 null，
  /// 不把工作区标题或内部状态误当成消息内容。
  static String? previewOf(Map<dynamic, dynamic> node) {
    final sources = <Map<dynamic, dynamic>>[node];
    for (final key in const ['activity', 'meta', 'latest', 'lastMessage']) {
      final value = node[key];
      if (value is Map) sources.add(value);
    }
    for (final source in sources) {
      for (final key in const [
        'lastAssistantText',
        'lastAssistantMessage',
        'lastResponse',
        'lastMessage',
        'preview',
        'summary',
        'content',
        'output',
      ]) {
        final text = _previewText(source[key]);
        if (text != null) return text;
      }
    }
    return null;
  }

  static String? _previewText(Object? value) {
    if (value is String) {
      final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) return null;
      return text.length > 180 ? '${text.substring(0, 180)}…' : text;
    }
    if (value is Map) {
      for (final key in const [
        'text',
        'content',
        'message',
        'body',
        'output',
      ]) {
        final text = _previewText(value[key]);
        if (text != null) return text;
      }
    }
    return null;
  }

  static String? _firstString(Map<dynamic, dynamic> node, List<String> keys) {
    for (final key in keys) {
      final value = node[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }
}

abstract final class TaskIndexExtractor {
  static const int _maxDepth = 8;

  static List<SessionState> parse(String body) {
    final dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    return parseRoot(root);
  }

  static List<SessionState> parseRoot(dynamic root) {
    final states = <SessionState>[];
    _walk(root, 0, states);
    return states;
  }

  static void _walk(dynamic node, int depth, List<SessionState> out) {
    if (depth > _maxDepth || node == null) return;
    if (node is Map) {
      if (node['op'] == 'task.upserted' && node['task'] is Map) {
        final state = _stateOf(node['task'] as Map<dynamic, dynamic>);
        if (state != null) out.add(state);
      }
      for (final value in node.values) {
        _walk(value, depth + 1, out);
      }
    } else if (node is List) {
      for (final value in node) {
        _walk(value, depth + 1, out);
      }
    }
  }

  static List<String> parseArchived(String body) {
    final dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    return parseArchivedRoot(root);
  }

  static List<String> parseArchivedRoot(dynamic root) {
    final archived = <String>[];
    _walkArchived(root, 0, archived);
    return archived;
  }

  static List<String> parseRemoved(String body) {
    final dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    return parseRemovedRoot(root);
  }

  static List<String> parseRemovedRoot(dynamic root) {
    final removed = <String>[];
    _walkRemoved(root, 0, removed);
    return removed;
  }

  static void _walkRemoved(dynamic node, int depth, List<String> out) {
    if (depth > _maxDepth || node == null) return;
    if (node is Map) {
      if (node['op'] == 'task.removed' && node['address'] is Map) {
        final id = (node['address'] as Map<dynamic, dynamic>)['taskId'];
        if (id is String && id.isNotEmpty) out.add(id);
      }
      for (final value in node.values) {
        _walkRemoved(value, depth + 1, out);
      }
    } else if (node is List) {
      for (final value in node) {
        _walkRemoved(value, depth + 1, out);
      }
    }
  }

  static void _walkArchived(dynamic node, int depth, List<String> out) {
    if (depth > _maxDepth || node == null) return;
    if (node is Map) {
      if (node['op'] == 'task.upserted' && node['task'] is Map) {
        final task = node['task'] as Map<dynamic, dynamic>;
        final membership = task['membership'];
        if (membership is Map && membership['archived'] == true) {
          final id = _taskIdOf(task);
          if (id != null) out.add(id);
        }
      }
      for (final value in node.values) {
        _walkArchived(value, depth + 1, out);
      }
    } else if (node is List) {
      for (final value in node) {
        _walkArchived(value, depth + 1, out);
      }
    }
  }

  static String? _taskIdOf(Map<dynamic, dynamic> task) {
    final address = task['address'];
    if (address is Map) {
      final id = address['taskId'];
      if (id is String && id.isNotEmpty) return id;
    }
    final meta = task['meta'];
    if (meta is Map) {
      final id = meta['taskId'];
      if (id is String && id.isNotEmpty) return id;
    }
    return null;
  }

  static List<SessionState>? parseSnapshot(String body) {
    final dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return null;
    }
    return parseSnapshotRoot(root);
  }

  static List<SessionState>? parseSnapshotRoot(dynamic root) {
    final snapshot = _findTasksSnapshot(root, 0);
    if (snapshot == null) return null;
    final out = <SessionState>[];
    for (final t in snapshot) {
      if (t is Map<dynamic, dynamic>) {
        final state = _stateOf(t);
        if (state != null) out.add(state);
      }
    }
    return out;
  }

  static List<dynamic>? _findTasksSnapshot(dynamic node, int depth) {
    if (depth > _maxDepth || node is! Map) return null;
    final payload = node['payload'];
    if (payload is Map && payload['kind'] == 'snapshot') {
      final snapshot = payload['snapshot'];
      if (snapshot is Map && snapshot['tasks'] is List) {
        return snapshot['tasks'] as List<dynamic>;
      }
    }
    for (final value in node.values) {
      final found = _findTasksSnapshot(value, depth + 1);
      if (found != null) return found;
    }
    return null;
  }

  static List<SessionState>? parseResultTasks(String body) {
    final dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return null;
    }
    return parseResultTasksRoot(root);
  }

  static List<SessionState>? parseResultTasksRoot(dynamic root) {
    final tasks = _findResultTasks(root, 0);
    if (tasks == null) return null;
    final out = <SessionState>[];
    for (final t in tasks) {
      if (t is! Map<dynamic, dynamic>) continue;
      final state = _stateOfFlat(t);
      if (state != null) out.add(state);
    }
    return out;
  }

  static List<dynamic>? _findResultTasks(dynamic node, int depth) {
    if (depth > _maxDepth || node is! Map) return null;
    final result = node['result'];
    if (result is Map && result['tasks'] is List) {
      return result['tasks'] as List<dynamic>;
    }
    for (final value in node.values) {
      final found = _findResultTasks(value, depth + 1);
      if (found != null) return found;
    }
    return null;
  }

  static bool isBootstrapResult(dynamic root) {
    if (root is! Map) return false;
    final payload = root['payload'];
    if (payload is! Map) return false;
    final requestId = payload['requestId'];
    return requestId is String && requestId.startsWith('bootstrap');
  }

  static SessionState? _stateOfFlat(Map<dynamic, dynamic> t) {
    final id = t['taskId'];
    if (id is! String || id.isEmpty) return null;
    final status = t['displayStatus'];
    final phase = status is String ? _phaseFromStatus(status) : null;
    final laa = t['updatedAt'];
    final ca = t['createdAt'];
    final wsPath = t['workspacePath'];
    final wsLabel = t['workspaceLabel'];
    return SessionState(
      sessionId: id,
      title: t['title'] is String ? t['title'] as String? : null,
      preview: SessionStateExtractor.previewOf(t),
      phase: phase,
      lastActivityAt: laa is num ? laa.toInt() : null,
      createdAt: ca is num ? ca.toInt() : null,
      workspace: wsLabel is String && wsLabel.isNotEmpty
          ? wsLabel
          : SessionStateExtractor.workspaceBasenameOf(
              wsPath is String ? wsPath : null,
            ),
      workspacePath: wsPath is String && wsPath.isNotEmpty ? wsPath : null,
    );
  }

  static SessionState? _stateOf(Map<dynamic, dynamic> task) {
    final taskId = _taskIdOf(task);
    if (taskId == null) return null;

    final membership = task['membership'];
    if (membership is Map && membership['archived'] == true) return null;

    final address = task['address'];
    final meta = task['meta'];
    final activity = task['activity'];

    final containers = <Map<dynamic, dynamic>>[
      task,
      if (address is Map) address,
      if (meta is Map) meta,
      if (activity is Map) activity,
      for (final key in const ['latest', 'lastMessage'])
        if (task[key] is Map) task[key] as Map<dynamic, dynamic>,
    ];

    Map<dynamic, dynamic>? firstMap(String key) {
      for (final source in containers) {
        final value = source[key];
        if (value is Map) return value;
      }
      return null;
    }

    int intFromMaps(String key) {
      for (final source in containers) {
        final value = source[key];
        if (value is num) return value.toInt();
      }
      return 0;
    }

    final pendingSummary = firstMap('pendingInteractionSummary');
    final permissionCount = pendingSummary == null
        ? intFromMaps('permissionCount')
        : ((pendingSummary['permissionCount'] is num)
              ? (pendingSummary['permissionCount'] as num).toInt()
              : 0);
    final userInputCount = pendingSummary == null
        ? intFromMaps('userInputCount')
        : ((pendingSummary['userInputCount'] is num)
              ? (pendingSummary['userInputCount'] as num).toInt()
              : 0);

    final pending = firstMap('pendingInteraction');
    final interactionKind = pending != null && pending['kind'] is String
        ? pending['kind'] as String
        : null;
    final toolName = pending != null && pending['toolName'] is String
        ? pending['toolName'] as String
        : null;
    String? description;
    for (final key in const ['description', 'summary']) {
      final value = pending == null ? null : pending[key];
      if (value is String && value.trim().isNotEmpty) {
        description = value.trim();
        break;
      }
    }

    String? workspacePath;
    if (address is Map) {
      final p = address['workspacePath'];
      if (p is String && p.isNotEmpty) workspacePath = p;
    }
    if (workspacePath == null && meta is Map) {
      final p = meta['workspacePath'];
      if (p is String && p.isNotEmpty) workspacePath = p;
    }

    String? title;
    if (meta is Map) {
      final t = meta['title'];
      if (t is String && t.isNotEmpty) title = t;
    }

    int? lastActivityAt;
    if (activity is Map) {
      final v = activity['lastActivityAt'];
      if (v is num) lastActivityAt = v.toInt();
    }
    if (lastActivityAt == null && meta is Map) {
      final v = meta['updatedAt'];
      if (v is num) lastActivityAt = v.toInt();
    }

    int? createdAt;
    if (meta is Map) {
      final v = meta['createdAt'];
      if (v is num) createdAt = v.toInt();
    }

    String? phase;
    if (activity is Map) {
      final p = activity['phase'];
      if (p is String && p.isNotEmpty) phase = p;
    }
    if (phase == null) {
      final live = task['liveStatus'];
      if (live is String && live.isNotEmpty) phase = live;
    }
    if (phase == null && meta is Map) {
      final status = meta['status'];
      if (status is String) phase = _phaseFromStatus(status);
    }
    if (phase == null && task['displayStatus'] is String) {
      phase = _phaseFromStatus(task['displayStatus'] as String);
    }

    bool? sessionEnded;
    for (final source in containers) {
      final value = source['sessionEnded'];
      if (value is bool) {
        sessionEnded = value;
        break;
      }
    }

    return SessionState(
      sessionId: taskId,
      title: title,
      preview: SessionStateExtractor.previewOf(task),
      phase: phase,
      sessionEnded: sessionEnded,
      permissionCount: permissionCount,
      userInputCount: userInputCount,
      interactionKind: interactionKind,
      toolName: toolName,
      description: description,
      lastActivityAt: lastActivityAt,
      createdAt: createdAt,
      workspace: SessionStateExtractor.workspaceBasenameOf(workspacePath),
      workspacePath: workspacePath,
      pinned: membership is Map && membership['pinned'] == true,
    );
  }

  static String? _phaseFromStatus(String status) => switch (status) {
    'completed' => 'completedSuccess',
    'error' => 'error',
    'running' => 'running',
    _ => null,
  };
}

class StateDiffer {
  StateDiffer();

  final Map<String, SessionState> _prev = {};

  List<ObservedEvent> apply(
    List<SessionState> incoming, {
    List<String> removed = const [],
  }) {
    final events = <ObservedEvent>[];
    for (final id in removed) {
      final gone = _prev.remove(id);
      if (gone != null &&
          (gone.permissionCount > 0 || gone.userInputCount > 0)) {
        events.add(
          ObservedEvent(type: 'resolved', taskId: id, sessionTitle: gone.title),
        );
      }
    }
    // A single relay delivery may contain both a task delta and its nested
    // session mirror. Collapse those copies before diffing; otherwise the
    // same non-current session can produce an event and immediately overwrite
    // its baseline with a second representation.
    final latestById = <String, SessionState>{};
    for (final next in incoming) {
      latestById[next.sessionId] = next;
    }
    for (final next in latestById.values) {
      final prev = _prev[next.sessionId];
      _prev[next.sessionId] = next;

      final prevPerm = prev?.permissionCount ?? 0;
      final prevInput = prev?.userInputCount ?? 0;

      if (next.permissionCount > 0 && prevPerm == 0) {
        events.add(
          ObservedEvent(
            type: 'permission_request',
            taskId: next.sessionId,
            sessionTitle: next.title,
            summary: next.description ?? next.preview,
          ),
        );
      }
      if (next.userInputCount > 0 && prevInput == 0) {
        events.add(
          ObservedEvent(
            type: 'elicitation_request',
            taskId: next.sessionId,
            sessionTitle: next.title,
            summary: next.description ?? next.preview,
          ),
        );
      }

      if ((prevPerm > 0 && next.permissionCount == 0) ||
          (prevInput > 0 && next.userInputCount == 0)) {
        events.add(
          ObservedEvent(
            type: 'resolved',
            taskId: next.sessionId,
            sessionTitle: next.title,
          ),
        );
      }

      final prevPhase = prev?.phase;
      final phase = next.phase;
      const donePhases = {'completedSuccess', 'completedInterrupted'};
      // `sessionEnded:false` is still an active turn even if a nested
      // activity object briefly reports a completed-looking phase. A flat
      // task-index row may omit sessionEnded, so null remains acceptable for
      // that authoritative displayStatus representation.
      final isDone =
          phase != null &&
          donePhases.contains(phase) &&
          next.sessionEnded != false;
      final wasDone =
          prev != null &&
          prev.sessionEnded != false &&
          prevPhase != null &&
          donePhases.contains(prevPhase);
      final wasError =
          prev != null && prev.sessionEnded != false && prevPhase == 'error';
      if (prev != null && isDone && !wasDone) {
        events.add(
          ObservedEvent(
            type: 'completed',
            taskId: next.sessionId,
            sessionTitle: next.title,
            summary: next.preview ?? next.description ?? prev.preview,
          ),
        );
      }
      if (prev != null &&
          phase == 'error' &&
          next.sessionEnded != false &&
          !wasError) {
        events.add(
          ObservedEvent(
            type: 'error',
            taskId: next.sessionId,
            sessionTitle: next.title,
            summary: next.preview ?? next.description ?? prev.preview,
          ),
        );
      }
    }
    return events;
  }

  /// 快照全量替换后的基线对账：只剪"已终态且不在最新快照中"的条目。
  ///
  /// completed/error 事件都要求 prev != null，因此 pending（审批/输入
  /// 计数大于 0）与运行中基线一律保留，否则会漏报；终态条目不会再产生
  /// 新转移（唯一出口是 removed 对账），剪掉零漏报，同时清掉长会话场景
  /// 下 `_prev` 的增长大头。
  void pruneOnSnapshot(Iterable<SessionState> snapshot) {
    if (_prev.isEmpty) return;
    final alive = snapshot.map((s) => s.sessionId).toSet();
    _prev.removeWhere((id, state) {
      if (alive.contains(id)) return false;
      final terminal =
          (state.phase == 'error' ||
              state.phase == 'completedSuccess' ||
              state.phase == 'completedInterrupted') &&
          state.sessionEnded != false;
      return terminal;
    });
  }
}

abstract final class MobileViewStateSync {
  static ({bool valid, String? taskId}) parse(String body) {
    final dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return (valid: false, taskId: null);
    }
    if (root is! Map) return (valid: false, taskId: null);
    if (root['activeWorkspaceKey'] is! String) {
      return (valid: false, taskId: null);
    }
    final id = root['activeTaskId'];
    return (valid: true, taskId: id is String && id.isNotEmpty ? id : null);
  }
}

abstract final class ActiveSessionExtractor {
  static const int _maxDepth = 6;

  static String? parse(String body) {
    final dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return null;
    }
    return parseRoot(root);
  }

  static String? parseRoot(dynamic root) => _walk(root, 0);

  static String? _walk(dynamic node, int depth) {
    if (depth > _maxDepth || node is! Map) return null;
    final topic = node['topic'];
    if (topic is String && topic.startsWith('conversation/')) {
      final sid = topic.substring('conversation/'.length);
      if (sid.isNotEmpty) return sid;
    }
    final view = node['mobileViewState'];
    if (view is Map) {
      final id = view['activeTaskId'];
      if (id is String && id.isNotEmpty) return id;
    }
    final bridge = node['bridge'];
    if (bridge is Map) {
      final id = bridge['initialTaskId'];
      if (id is String && id.isNotEmpty) return id;
    }
    String? found;
    for (final value in node.values) {
      found = _walk(value, depth + 1);
      if (found != null) return found;
    }
    return null;
  }
}

abstract final class NotificationGate {
  static bool shouldNotify({
    required bool appForeground,
    required String? visibleDeviceId,
    required String eventDeviceId,
    required String? activeSessionId,
    required String? eventSessionId,
  }) {
    // 前台由应用内浮窗和通知中心承接；系统通知只在应用离开前台后发出，
    // 避免同一个事件在屏幕上重复出现。保留其余参数是为了兼容调用方。
    return !appForeground;
  }
}

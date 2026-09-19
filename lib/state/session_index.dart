import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/event_observer.dart';
import '../services/text_sanitize.dart';

abstract final class SessionRanking {
  /// Drawer order inside one workspace: pinned first, then sessions that
  /// need attention (running or waiting for approval), then recency.  Ties
  /// fall through to createdAt and finally sessionId so the order never
  /// jumps between refreshes.
  static int compareSessions(SessionState a, SessionState b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    final aRunning = a.phase == 'running' || a.permissionCount > 0;
    final bRunning = b.phase == 'running' || b.permissionCount > 0;
    if (aRunning != bRunning) return aRunning ? -1 : 1;
    if (aRunning) {
      final byCreated = (b.createdAt ?? 0).compareTo(a.createdAt ?? 0);
      if (byCreated != 0) return byCreated;
      return a.sessionId.compareTo(b.sessionId);
    }
    final byRecency = (b.lastActivityAt ?? -1).compareTo(
      a.lastActivityAt ?? -1,
    );
    if (byRecency != 0) return byRecency;
    final byCreated = (b.createdAt ?? 0).compareTo(a.createdAt ?? 0);
    if (byCreated != 0) return byCreated;
    return a.sessionId.compareTo(b.sessionId);
  }
}

class SessionIndexNotifier
    extends Notifier<Map<String, Map<String, SessionState>>> {
  final Map<String, Map<String, SessionState>> _tasks = {};
  final Map<String, Map<String, SessionState>> _sessions = {};

  /// 单设备单表条目上限（安全审计 S-1）：敌对页面可用唯一 `sessionId` 无限
  /// 灌大 `_sessions/_tasks`（一条 4 MiB 帧就能带 ~10 万个 id），把整个进程
  /// 打进 OOM/ANR。超限按**插入序**把表压到上限的 7/8（留 1/8 headroom，
  /// 避免每次插入都触发驱逐；Dart LinkedHashMap 保插入序，刷新不改位置，
  /// 活跃会话天然沉底）。真实页面远低于此值。
  ///
  /// iter12 N-P2-3：上限同时约束**合并视图**——两表独立计数时，只出现在
  /// 单侧的 id 会让 `_rebuild` 的 merged 达到 2×上限；合并后再次执行
  /// 本驱逐，保证 `state[deviceId]` 也 ≤ 上限（合并表按 tasks 先、sessions
  /// 后的并集插入序驱逐，钉住的会话同样最后驱逐）。驱逐是**视图级**的：
  /// 被裁掉的 id 仍在背表 `_tasks/_sessions`（各自有界），下一轮 `_rebuild`
  /// 会重新并集、重新驱逐——不变量每轮成立，但敌对灌满时视图内容可随
  /// 重建顺序抖动（复核 P3，如实记录）。
  static const int maxEntriesPerDevice = 5000;

  void _evictOverflow(Map<String, SessionState> m) {
    if (m.length <= maxEntriesPerDevice) return;
    final overflow = m.length - maxEntriesPerDevice + maxEntriesPerDevice ~/ 8;
    // 钉住的会话最后驱逐（iter7 R-8）：洪泛不应挤掉用户的钉住标记；
    // 极端全 pinned 时走第二轮兜底，保有界性优先。
    // Set（LinkedHashSet）保插入序：第二轮兜底无需 contains 的 O(n²) 扫描
    // （复核 P3：全 pinned 的 5000 条敌对输入在 UI 线程跑 1250 万次比较）。
    final drop = <String>{};
    for (final key in m.keys) {
      if (drop.length >= overflow) break;
      if (m[key]?.pinned ?? false) continue;
      drop.add(key);
    }
    for (final key in m.keys) {
      if (drop.length >= overflow) break;
      drop.add(key);
    }
    for (final key in drop) {
      m.remove(key);
    }
  }

  @override
  Map<String, Map<String, SessionState>> build() => const {};

  void upsertAll(String deviceId, List<SessionState> states) {
    if (states.isEmpty) return;
    final m = Map.of(_sessions[deviceId] ?? const <String, SessionState>{});
    for (final s in states) {
      m[s.sessionId] = _sanitize(s);
    }
    _evictOverflow(m);
    _sessions[deviceId] = m;
    _rebuild(deviceId);
  }

  void upsertTasks(String deviceId, List<SessionState> taskEntries) {
    if (taskEntries.isEmpty) return;
    final m = Map.of(_tasks[deviceId] ?? const <String, SessionState>{});
    for (final t in taskEntries) {
      m[t.sessionId] = _sanitize(t);
    }
    _evictOverflow(m);
    _tasks[deviceId] = m;
    _rebuild(deviceId);
  }

  void replaceTasks(
    String deviceId,
    List<SessionState> taskEntries, {
    bool preservePinned = false,
  }) {
    final prev = _tasks[deviceId];
    _tasks[deviceId] = {
      for (final t in taskEntries)
        t.sessionId: _sanitize(
          preservePinned && !t.pinned && (prev?[t.sessionId]?.pinned ?? false)
              ? _withPinned(t, true)
              : t,
        ),
    };
    // 快照整体替换同样要收敛到上限（安全审计 S-1/N-3）：一帧 4 MiB 快照
    // 可带数万条任务，虽无跨帧累积，但“表压到上限”的承诺必须一致。
    _evictOverflow(_tasks[deviceId]!);
    _rebuild(deviceId);
  }

  static SessionState _withPinned(SessionState s, bool pinned) => SessionState(
    sessionId: s.sessionId,
    title: s.title,
    phase: s.phase,
    sessionEnded: s.sessionEnded,
    permissionCount: s.permissionCount,
    userInputCount: s.userInputCount,
    interactionKind: s.interactionKind,
    toolName: s.toolName,
    description: s.description,
    preview: s.preview,
    lastActivityAt: s.lastActivityAt,
    createdAt: s.createdAt,
    workspace: s.workspace,
    workspacePath: s.workspacePath,
    pinned: pinned,
  );

  /// 页面来源文本（标题/预览/工作区名）在入表前剥离 Bidi 控制符
  /// （iter12 W-021，[TextSanitize]）：它们会原样进入会话列表渲染。
  static SessionState _sanitize(SessionState s) {
    final title = TextSanitize.stripBidiControls(s.title);
    final preview = TextSanitize.stripBidiControls(s.preview);
    final workspace = TextSanitize.stripBidiControls(s.workspace);
    final workspacePath = TextSanitize.stripBidiControls(s.workspacePath);
    if (identical(title, s.title) &&
        identical(preview, s.preview) &&
        identical(workspace, s.workspace) &&
        identical(workspacePath, s.workspacePath)) {
      return s;
    }
    return SessionState(
      sessionId: s.sessionId,
      title: title,
      phase: s.phase,
      sessionEnded: s.sessionEnded,
      permissionCount: s.permissionCount,
      userInputCount: s.userInputCount,
      interactionKind: s.interactionKind,
      toolName: s.toolName,
      description: s.description,
      preview: preview,
      lastActivityAt: s.lastActivityAt,
      createdAt: s.createdAt,
      workspace: workspace,
      workspacePath: workspacePath,
      pinned: s.pinned,
    );
  }

  void removeSessions(String deviceId, List<String> sessionIds) {
    if (sessionIds.isEmpty) return;
    var touched = false;
    for (final store in [_tasks, _sessions]) {
      final m = store[deviceId];
      if (m == null) continue;
      for (final id in sessionIds) {
        touched |= m.remove(id) != null;
      }
      if (m.isEmpty) store.remove(deviceId);
    }
    if (touched) _rebuild(deviceId);
  }

  void forget(String deviceId) {
    _tasks.remove(deviceId);
    _sessions.remove(deviceId);
    if (!state.containsKey(deviceId)) return;
    state = Map.of(state)..remove(deviceId);
  }

  /// 擦除事务（R-04）：会话索引含标题/预览路径等远控内容，全量清除。
  void clearAll() {
    _tasks.clear();
    _sessions.clear();
    if (state.isEmpty) return;
    state = const {};
  }

  void _rebuild(String deviceId) {
    final tasks = _tasks[deviceId];
    final sessions = _sessions[deviceId];
    if ((tasks == null || tasks.isEmpty) &&
        (sessions == null || sessions.isEmpty)) {
      if (!state.containsKey(deviceId)) return;
      state = Map.of(state)..remove(deviceId);
      return;
    }
    final ids = <String>{...?tasks?.keys, ...?sessions?.keys};
    final merged = <String, SessionState>{
      for (final id in ids) id: _mergeTaskSession(tasks?[id], sessions?[id]),
    };
    _evictOverflow(merged);
    state = {...state, deviceId: merged};
  }

  static SessionState _mergeTaskSession(SessionState? task, SessionState? s) {
    if (s == null) return task!;
    if (task == null) return s;
    return SessionState(
      sessionId: s.sessionId,
      title: task.title ?? s.title,
      phase: s.phase ?? task.phase,
      sessionEnded: s.sessionEnded ?? task.sessionEnded,
      permissionCount: s.permissionCount,
      userInputCount: s.userInputCount,
      interactionKind: s.interactionKind,
      toolName: s.toolName,
      description: s.description,
      preview: s.preview ?? task.preview,
      lastActivityAt: s.lastActivityAt ?? task.lastActivityAt,
      createdAt: s.createdAt ?? task.createdAt,
      workspace: task.workspace ?? s.workspace,
      workspacePath: task.workspacePath ?? s.workspacePath,
      pinned: task.pinned,
    );
  }
}

final sessionIndexProvider =
    NotifierProvider<
      SessionIndexNotifier,
      Map<String, Map<String, SessionState>>
    >(SessionIndexNotifier.new);

abstract final class RelativeTime {
  static ({String kind, int n}) format(int? lastActivityAtMs, int nowMs) {
    final diff = lastActivityAtMs == null ? null : nowMs - lastActivityAtMs;
    if (diff == null || diff < 0) return (kind: 'now', n: 0);
    if (diff < 60 * 1000) return (kind: 'now', n: 0);
    if (diff < 3600 * 1000) return (kind: 'minute', n: diff ~/ (60 * 1000));
    if (diff < 24 * 3600 * 1000) {
      return (kind: 'hour', n: diff ~/ (3600 * 1000));
    }
    return (kind: 'day', n: diff ~/ (24 * 3600 * 1000));
  }
}

abstract final class SessionGrouping {
  /// Stable grouping key for the WorkBuddy-style conversation list.
  /// Prefer a real path because workspace display names can collide across
  /// devices; fall back to the server workspace label only when no path was
  /// included in the snapshot.
  static String workspaceKey(SessionState session) {
    final path = session.workspacePath?.trim();
    if (path != null && path.isNotEmpty) return path;
    final name = session.workspace?.trim();
    if (name != null && name.isNotEmpty) return name;
    return 'unknown';
  }

  static String workspaceLabel(String key) {
    if (key == 'unknown') return '未命名工作区';
    final normalized = key.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    if (slash >= 0 && slash + 1 < normalized.length) {
      return normalized.substring(slash + 1);
    }
    return key;
  }

  static List<MapEntry<String, List<SessionState>>> groupByWorkspace(
    List<SessionState> sorted,
  ) {
    final groups = <String, List<SessionState>>{};
    final order = <String>[];
    for (final session in sorted) {
      final key = session.pinned ? 'pinned' : workspaceKey(session);
      if (!groups.containsKey(key)) {
        groups[key] = <SessionState>[];
        order.add(key);
      }
      groups[key]!.add(session);
    }
    return [for (final key in order) MapEntry(key, groups[key]!)];
  }

  static List<MapEntry<String, List<SessionState>>> groupByDay(
    List<SessionState> sorted,
    DateTime now, {
    bool weekStartsMonday = true,
  }) {
    final pinned = <SessionState>[];
    final rest = <SessionState>[];
    for (final s in sorted) {
      (s.pinned ? pinned : rest).add(s);
    }
    final out = <MapEntry<String, List<SessionState>>>[];
    if (pinned.isNotEmpty) out.add(MapEntry('pinned', pinned));

    final groups = <String, List<SessionState>>{};
    final order = <String>[];
    for (final s in rest) {
      final key = _keyOf(s, now, weekStartsMonday);
      if (!groups.containsKey(key)) {
        groups[key] = <SessionState>[];
        order.add(key);
      }
      groups[key]!.add(s);
    }
    out.addAll([for (final key in order) MapEntry(key, groups[key]!)]);
    return out;
  }

  static String _keyOf(SessionState s, DateTime now, bool weekStartsMonday) {
    final laa = s.lastActivityAt;
    if (laa == null) return 'unknown';
    final then = DateTime.fromMillisecondsSinceEpoch(laa);
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(then.year, then.month, then.day);
    final days = today.difference(day).inDays;
    if (days <= 0) return 'today';
    if (days == 1) return 'yesterday';
    if (days <= 3) return 'day:$days';

    final weekStart = _startOfWeek(now, weekStartsMonday);
    if (!then.isBefore(weekStart)) return 'thisWeek';
    if (!then.isBefore(weekStart.subtract(const Duration(days: 7)))) {
      return 'lastWeek';
    }
    if (!then.isBefore(DateTime(now.year, now.month))) return 'thisMonth';
    if (!then.isBefore(DateTime(now.year, now.month - 1))) return 'lastMonth';
    return 'older';
  }

  static DateTime _startOfWeek(DateTime now, bool weekStartsMonday) {
    final today = DateTime(now.year, now.month, now.day);
    final dow = today.weekday;
    final shift = weekStartsMonday ? dow - 1 : dow % 7;
    return today.subtract(Duration(days: shift));
  }
}

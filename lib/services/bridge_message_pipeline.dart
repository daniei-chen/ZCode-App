import 'dart:convert';

/// 桥接消息共享解析管线（评审 A2 阶段 1）。
///
/// 旧实现同一条消息被 `jsonDecode` 两次、再串行跑约 8 趟全树遍历；
/// 这里提供单次 decode 与 removed 三路合并的单趟遍历。会话状态、
/// 任务索引等提取仍走 event_observer 的既有公共 API（relay_bridge
/// 与 event_parser_test 依赖它们），本文件不改它们的语义。
abstract final class BridgeMessagePipeline {
  /// removed 提取的遍历深度上限，与 SessionState/TaskIndex 提取器
  /// 的 `_maxDepth = 8` 保持一致。
  static const int _maxDepth = 8;

  /// 单次 decode；失败返回 null（与调用方原 catch-continue 语义一致）。
  static dynamic decode(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  /// 单趟合并三路 removed 提取。每个列表的元素与相对顺序都和旧的三趟
  /// （SessionStateExtractor.parseRemovedRoot → TaskIndexExtractor
  /// .parseRemovedRoot → parseArchivedRoot）逐一等价。
  static ({List<String> sessions, List<String> tasks, List<String> archived})
  parseRemoved(dynamic root) {
    final sessions = <String>[];
    final tasks = <String>[];
    final archived = <String>[];
    _walkRemoved(root, 0, sessions, tasks, archived);
    return (sessions: sessions, tasks: tasks, archived: archived);
  }

  static void _walkRemoved(
    dynamic node,
    int depth,
    List<String> sessions,
    List<String> tasks,
    List<String> archived,
  ) {
    if (depth > _maxDepth || node == null) return;
    if (node is Map) {
      final op = node['op'];
      if (op == 'session.removed') {
        final id = node['sessionId'];
        if (id is String && id.isNotEmpty) sessions.add(id);
      } else if (op == 'task.removed' && node['address'] is Map) {
        final id = (node['address'] as Map<dynamic, dynamic>)['taskId'];
        if (id is String && id.isNotEmpty) tasks.add(id);
      } else if (op == 'task.upserted' && node['task'] is Map) {
        final task = node['task'] as Map<dynamic, dynamic>;
        final membership = task['membership'];
        if (membership is Map && membership['archived'] == true) {
          final id = _taskIdOf(task);
          if (id != null) archived.add(id);
        }
      }
      for (final value in node.values) {
        _walkRemoved(value, depth + 1, sessions, tasks, archived);
      }
    } else if (node is List) {
      for (final value in node) {
        _walkRemoved(value, depth + 1, sessions, tasks, archived);
      }
    }
  }

  /// 与 event_observer 的 `_taskIdOf` 保持一致（address → meta）。
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
}

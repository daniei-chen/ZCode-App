import 'agent_rpc.dart';
import 'conversation_row.dart';

/// 原生会话通道的一次更新。
///
/// 历史行来自 RPC 响应，实时行来自桌面端推送的 agent RPC。两者形状并不
/// 完全一致，所以先在协议层归一化，再交给会话状态层合并。解析器只接受
/// 有限深度、有限数量的 Map/List，避免异常负载把 UI 线程拖进无限遍历。
class ConversationUpdate {
  const ConversationUpdate({
    required this.rows,
    this.sessionId,
    this.workspacePath,
    this.isRealtime = false,
  });

  final List<ConversationRow> rows;
  final String? sessionId;
  final String? workspacePath;
  final bool isRealtime;

  static ConversationUpdate? fromResponse(Object? value) {
    final rows = ConversationRow.parseResponse(value);
    if (rows == null || rows.isEmpty) return null;
    final scope = _scopeOf(value);
    return ConversationUpdate(
      rows: rows,
      sessionId: scope.sessionId,
      workspacePath: scope.workspacePath,
    );
  }

  /// 解析 `onDynamicConversationFrame` 以及后续版本可能使用的同类回调。
  static ConversationUpdate? fromAgentRpc(AgentRpc rpc) {
    if (rpc.service != 'zcode-agent') return null;
    final method = rpc.method.toLowerCase();
    if (!method.contains('conversation') &&
        !method.contains('dynamic') &&
        !method.contains('stream') &&
        !method.contains('row')) {
      return null;
    }

    final candidates = <Object?>[...rpc.args];
    for (final candidate in candidates) {
      final update = _fromNode(candidate, realtime: true);
      if (update != null) return update;
    }
    return null;
  }

  static ConversationUpdate? _fromNode(Object? node, {required bool realtime}) {
    final queue = <({Object? value, int depth})>[(value: node, depth: 0)];
    var visited = 0;
    while (queue.isNotEmpty && visited < 256) {
      final current = queue.removeLast();
      visited++;
      final value = current.value;
      final direct = ConversationRow.parseResponse(value);
      if (direct != null && direct.isNotEmpty) {
        final scope = _scopeOf(value);
        return ConversationUpdate(
          rows: direct,
          sessionId: scope.sessionId,
          workspacePath: scope.workspacePath,
          isRealtime: realtime,
        );
      }

      // 单行事件：row.upserted / row.appended / row.delta。
      if (value is Map) {
        final row = ConversationRow.tryParse(
          value['row'] ?? value['item'] ?? value['data'],
        );
        if (row != null && row.kind != ConversationRowKind.unknown) {
          final scope = _scopeOf(value);
          return ConversationUpdate(
            rows: [row],
            sessionId: scope.sessionId,
            workspacePath: scope.workspacePath,
            isRealtime: realtime,
          );
        }
      }

      if (current.depth >= 8) continue;
      if (value is Map) {
        for (final child in value.values) {
          if (child is Map || child is List) {
            queue.add((value: child, depth: current.depth + 1));
          }
        }
      } else if (value is List) {
        for (final child in value) {
          if (child is Map || child is List) {
            queue.add((value: child, depth: current.depth + 1));
          }
        }
      }
    }
    return null;
  }

  static ({String? sessionId, String? workspacePath}) _scopeOf(Object? value) {
    if (value is! Map) return (sessionId: null, workspacePath: null);
    String? text(Object? v) => v is String && v.trim().isNotEmpty ? v : null;
    return (
      sessionId: text(
        value['sessionId'] ?? value['taskId'] ?? value['conversationId'],
      ),
      workspacePath: text(
        value['workspacePath'] ?? value['workspace'] ?? value['workspaceKey'],
      ),
    );
  }
}

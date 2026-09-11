import '../relay/conversation_row.dart';

/// Canonical identity of a conversation row across every ingestion path
/// (initial range, older page, live push, refresh, optimistic user row).
///
/// Priority mirrors the behaviour contract:
///   1. official `rowId`
///   2. official `entityId`
///   3. `toolCallId`
///   4. `messageId` / `clientOperationId` carried in the raw row
///   5. low-confidence composite: kind + role-ish origin + 2 s time bucket +
///      normalised text hash.  Used only when the desktop omitted every id;
///      flagged so diagnostics can show it.
class ConversationIdentity {
  const ConversationIdentity._(this.key, this.confidence);

  final String key;
  final IdentityConfidence confidence;

  bool get isLowConfidence => confidence == IdentityConfidence.composite;

  /// Width of the timestamp bucket for the composite key.
  static const int bucketMs = 2000;

  static ConversationIdentity of(ConversationRow row) {
    final rowId = row.rowId;
    if (rowId != null) {
      return ConversationIdentity._('row:$rowId', IdentityConfidence.rowId);
    }
    final entityId = row.entityId?.trim();
    if (entityId != null && entityId.isNotEmpty) {
      return ConversationIdentity._(
        'entity:$entityId',
        IdentityConfidence.entityId,
      );
    }
    final toolCallId = row.toolCallId?.trim();
    if (toolCallId != null && toolCallId.isNotEmpty) {
      return ConversationIdentity._(
        'tool:$toolCallId',
        IdentityConfidence.toolCallId,
      );
    }
    final raw = row.raw;
    for (final k in const ['messageId', 'clientOperationId', 'commandId']) {
      final v = raw[k];
      if (v is String && v.trim().isNotEmpty) {
        return ConversationIdentity._(
          '$k:${v.trim()}',
          IdentityConfidence.messageId,
        );
      }
    }
    return ConversationIdentity._(composite(row), IdentityConfidence.composite);
  }

  /// Deterministic key for rows without any id.  Two pushes of the same
  /// message within one bucket collapse; two genuinely different turns with
  /// identical text more than [bucketMs] apart stay separate.
  static String composite(ConversationRow row) {
    final origin = row.raw['origin']?.toString() ?? '';
    final ts = row.createdAt;
    final bucket = ts == null ? 'na' : (ts ~/ bucketMs).toString();
    final text = normalize(row.text ?? row.inputText ?? '');
    return 'cmp:${row.kind.name}:$origin:$bucket:${text.hashCode.toRadixString(16)}:${text.length}';
  }

  /// Collapse whitespace so a re-serialised row hashes the same.
  static String normalize(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

enum IdentityConfidence { rowId, entityId, toolCallId, messageId, composite }

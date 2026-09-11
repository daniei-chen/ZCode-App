import '../models/conversation_identity.dart';
import '../relay/conversation_row.dart';

/// Where a batch of rows came from.  Every path goes through
/// [ConversationReducer.merge]; nothing appends to the timeline directly.
enum RowSource { initial, older, live, refresh, optimistic }

/// Pure merge of conversation rows.
///
/// Guarantees (see docs/UX-NATIVE-REBUILD-SPEC.md §4.1 and the S05 duplicate
/// screenshot):
///  * a row whose identity already exists replaces it, never appends;
///  * a row that arrives first without ids (push) and later with a `rowId`
///    (refresh) is upgraded in place, not duplicated;
///  * an optimistic user row is replaced by the official `userInput` row
///    whose `sourceCommandId` is our command id;
///  * an empty `refresh` never clears live rows;
///  * ordering uses `rowId` when both sides have one, otherwise `createdAt`,
///    otherwise arrival order — so id-less rows no longer sort to the top.
abstract final class ConversationReducer {
  static List<ConversationRow> merge(
    List<ConversationRow> current,
    List<ConversationRow> incoming, {
    required RowSource source,
  }) {
    if (incoming.isEmpty) return current;
    final out = <ConversationRow>[...current];
    final byKey = <String, int>{};
    final byComposite = <String, int>{};
    final pendingByCommand = <String, int>{};
    for (var i = 0; i < out.length; i++) {
      _index(out[i], i, byKey, byComposite, pendingByCommand);
    }

    for (final row in incoming) {
      final id = ConversationIdentity.of(row);
      int? target = byKey[id.key];

      // Official row answering our optimistic one.
      if (target == null) {
        final source = _sourceCommandId(row);
        if (source != null) target = pendingByCommand[source];
      }
      // Same message seen before under a different identity level: an
      // id-less push followed by the official row, or the reverse.  Two
      // distinct official rows are never merged this way, even if their
      // text and time bucket coincide.
      if (target == null) {
        final ci = byComposite[ConversationIdentity.composite(row)];
        if (ci != null &&
            (id.isLowConfidence ||
                ConversationIdentity.of(out[ci]).isLowConfidence)) {
          target = ci;
        }
      }

      if (target != null) {
        out[target] = _prefer(out[target], row);
      } else {
        out.add(row);
        target = out.length - 1;
      }
      _index(out[target], target, byKey, byComposite, pendingByCommand);
    }
    return sorted(out);
  }

  /// Stable order: rowId → createdAt → arrival index.
  static List<ConversationRow> sorted(List<ConversationRow> rows) {
    final indexed = [for (var i = 0; i < rows.length; i++) (rows[i], i)];
    indexed.sort((a, b) {
      final ra = a.$1.rowId, rb = b.$1.rowId;
      if (ra != null && rb != null && ra != rb) return ra.compareTo(rb);
      final ta = a.$1.createdAt, tb = b.$1.createdAt;
      if (ta != null && tb != null && ta != tb) return ta.compareTo(tb);
      final sa = a.$1.createdAtSeq, sb = b.$1.createdAtSeq;
      if (sa != null && sb != null && sa != sb) return sa.compareTo(sb);
      return a.$2.compareTo(b.$2);
    });
    return [for (final e in indexed) e.$1];
  }

  /// Build a pending user row for the composer.  It is replaced by the
  /// desktop's `userInput` row carrying the same command id.
  static ConversationRow optimisticUserRow({
    required String clientOperationId,
    required String text,
    required int nowMs,
  }) => ConversationRow(
    rowId: null,
    kind: ConversationRowKind.userText,
    createdAt: nowMs,
    text: text,
    raw: {
      'kind': 'userInput',
      'origin': 'realUser',
      'clientOperationId': clientOperationId,
      'pending': true,
    },
  );

  static bool isPending(ConversationRow row) => row.raw['pending'] == true;

  // ---------------------------------------------------------------------

  static void _index(
    ConversationRow row,
    int i,
    Map<String, int> byKey,
    Map<String, int> byComposite,
    Map<String, int> pendingByCommand,
  ) {
    final id = ConversationIdentity.of(row);
    byKey[id.key] = i;
    byComposite[ConversationIdentity.composite(row)] = i;
    if (isPending(row)) {
      final op = row.raw['clientOperationId']?.toString();
      if (op != null && op.isNotEmpty) pendingByCommand[op] = i;
    }
  }

  static String? _sourceCommandId(ConversationRow row) {
    for (final k in const ['sourceCommandId', 'rootSourceCommandId']) {
      final v = row.raw[k];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  /// When both sides describe the same row, keep the one with more official
  /// structure (an id beats no id); otherwise the newer arrival wins.
  static ConversationRow _prefer(
    ConversationRow existing,
    ConversationRow next,
  ) {
    if (next.rowId == null && existing.rowId != null && !isPending(existing)) {
      // A late id-less duplicate must not erase the official row's ids.
      return existing;
    }
    return next;
  }
}

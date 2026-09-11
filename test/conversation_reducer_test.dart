import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/conversation_identity.dart';
import 'package:zremote/relay/conversation_row.dart';
import 'package:zremote/state/conversation_reducer.dart';

ConversationRow _row({
  int? rowId,
  String kind = 'assistantText',
  String? text,
  String? entityId,
  String? toolCallId,
  int? createdAt,
  Map<String, dynamic> extra = const {},
}) => ConversationRow.tryParse({
  'rowId': ?rowId,
  'kind': kind,
  'text': ?text,
  'entityId': ?entityId,
  'toolCallId': ?toolCallId,
  'createdAt': ?createdAt,
  ...extra,
})!;

List<String?> _texts(List<ConversationRow> rows) =>
    rows.map((r) => r.text).toList();

void main() {
  group('ConversationIdentity', () {
    test('prefers rowId, then entityId, then toolCallId, then messageId', () {
      expect(
        ConversationIdentity.of(_row(rowId: 5, entityId: 'e')).key,
        'row:5',
      );
      expect(ConversationIdentity.of(_row(entityId: 'e')).key, 'entity:e');
      expect(
        ConversationIdentity.of(_row(kind: 'toolCall', toolCallId: 'c')).key,
        'tool:c',
      );
      expect(
        ConversationIdentity.of(_row(extra: {'messageId': 'm1'})).key,
        'messageId:m1',
      );
    });

    test('id-less rows get a low-confidence composite key', () {
      final a = _row(kind: 'userInput', text: '你好', createdAt: 10_000);
      final b = _row(kind: 'userInput', text: ' 你好 ', createdAt: 10_900);
      final id = ConversationIdentity.of(a);
      expect(id.isLowConfidence, isTrue);
      expect(
        id.key,
        ConversationIdentity.of(b).key,
        reason: 'same bucket + normalised text',
      );
    });
  });

  group('ConversationReducer.merge', () {
    test('F06: duplicate live rows with the same rowId collapse to one', () {
      final base = [_row(rowId: 1, text: 'a')];
      final out = ConversationReducer.merge(base, [
        _row(rowId: 1, text: 'a'),
        _row(rowId: 1, text: 'a (updated)'),
      ], source: RowSource.live);
      expect(out.length, 1);
      expect(out.single.text, 'a (updated)');
    });

    test(
      'push without id first, refresh with rowId later: upgraded not duplicated',
      () {
        final pushed = _row(kind: 'userInput', text: '你好', createdAt: 50_000);
        var rows = ConversationReducer.merge(const [], [
          pushed,
        ], source: RowSource.live);
        final official = _row(
          rowId: 42,
          kind: 'userInput',
          text: '你好',
          createdAt: 50_300,
        );
        rows = ConversationReducer.merge(rows, [
          official,
        ], source: RowSource.refresh);
        expect(rows.length, 1);
        expect(rows.single.rowId, 42);
      },
    );

    test('refresh with rowId first, late id-less push: official ids kept', () {
      final official = _row(
        rowId: 7,
        kind: 'assistantText',
        text: 'hi',
        createdAt: 1000,
      );
      var rows = ConversationReducer.merge(const [], [
        official,
      ], source: RowSource.initial);
      final late = _row(kind: 'assistantText', text: 'hi', createdAt: 1500);
      rows = ConversationReducer.merge(rows, [late], source: RowSource.live);
      expect(rows.length, 1);
      expect(rows.single.rowId, 7);
    });

    test('optimistic user row is replaced by the official userInput twin', () {
      final optimistic = ConversationReducer.optimisticUserRow(
        clientOperationId: 'zr-send-1',
        text: '你好',
        nowMs: 100_000,
      );
      var rows = ConversationReducer.merge(const [], [
        optimistic,
      ], source: RowSource.optimistic);
      expect(ConversationReducer.isPending(rows.single), isTrue);

      final official = _row(
        rowId: 90,
        kind: 'userInput',
        text: '你好',
        createdAt: 100_400,
        extra: {'origin': 'realUser', 'sourceCommandId': 'zr-send-1'},
      );
      rows = ConversationReducer.merge(rows, [
        official,
      ], source: RowSource.live);
      expect(rows.length, 1);
      expect(rows.single.rowId, 90);
      expect(ConversationReducer.isPending(rows.single), isFalse);
    });

    test('an empty refresh never clears live rows', () {
      final rows = [
        _row(rowId: 1, text: 'a'),
        _row(text: 'live', createdAt: 5),
      ];
      expect(
        ConversationReducer.merge(rows, const [], source: RowSource.refresh),
        same(rows),
      );
    });

    test('older page overlapping the boundary does not duplicate', () {
      final current = [_row(rowId: 10, text: 'j'), _row(rowId: 11, text: 'k')];
      final older = [_row(rowId: 9, text: 'i'), _row(rowId: 10, text: 'j')];
      final out = ConversationReducer.merge(
        current,
        older,
        source: RowSource.older,
      );
      expect(out.map((r) => r.rowId), [9, 10, 11]);
    });

    test('id-less rows sort by createdAt, not to the top', () {
      final out = ConversationReducer.merge(
        [
          _row(rowId: 1, text: 'first', createdAt: 1000),
          _row(rowId: 2, text: 'second', createdAt: 2000),
        ],
        [_row(text: 'streamed', createdAt: 3000)],
        source: RowSource.live,
      );
      expect(_texts(out), ['first', 'second', 'streamed']);
    });

    test('S02: two real turns with identical text far apart stay separate', () {
      final out = ConversationReducer.merge(
        [_row(rowId: 1, kind: 'userInput', text: '你好', createdAt: 1_000)],
        [_row(rowId: 5, kind: 'userInput', text: '你好', createdAt: 60_000)],
        source: RowSource.live,
      );
      expect(out.length, 2);
    });

    test('S05 replay: id-less push of an existing turn adds nothing', () {
      final history = [
        _row(rowId: 1, kind: 'userInput', text: '你好', createdAt: 1000),
        _row(rowId: 2, kind: 'reasoning', text: 'thinking', createdAt: 1100),
        _row(
          rowId: 3,
          kind: 'assistantText',
          text: '你好！我是 ZCode',
          createdAt: 1200,
        ),
      ];
      final push = [
        _row(kind: 'userInput', text: '你好', createdAt: 1000),
        _row(kind: 'assistantText', text: '你好！我是 ZCode', createdAt: 1200),
      ];
      final out = ConversationReducer.merge(
        history,
        push,
        source: RowSource.live,
      );
      expect(out.length, 3, reason: 'no second bubble for the same turn');
      expect(out.map((r) => r.rowId), [1, 2, 3]);
    });
  });
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/relay/agent_rpc.dart';
import 'package:zremote/relay/conversation_row.dart';

Uint8List hex(String s) {
  final t = s.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  return Uint8List.fromList([
    for (var i = 0; i + 1 < t.length; i += 2)
      int.parse(t.substring(i, i + 2), radix: 16),
  ]);
}

// 基准由独立的 Python 实现按实测帧格式生成（请求头部与响应头部不同）。
const _hello =
    '04 02 06 c9 01 06 01 05 b3 02 7b 22 6b 69 6e 64 22 3a 22 68 65 6c'
    '6c 6f 22 2c 22 70 72 6f 74 6f 63 6f 6c 56 65 72 73 69 6f 6e 22 3a'
    '33 2c 22 63 6f 6e 6e 65 63 74 69 6f 6e 49 64 22 3a 22 68 6f 73 74'
    '2d 72 70 63 2d 74 65 73 74 2d 30 30 30 31 22 2c 22 63 6c 69 65 6e'
    '74 4d 6f 64 65 22 3a 22 77 65 62 2d 72 65 6d 6f 74 65 2d 72 65 70'
    '6c 61 79 61 62 6c 65 22 2c 22 64 65 6c 69 76 65 72 79 50 72 6f 66'
    '69 6c 65 22 3a 22 72 65 70 6c 61 79 61 62 6c 65 22 2c 22 73 65 72'
    '76 65 72 54 69 6d 65 22 3a 31 37 38 39 30 32 31 32 39 32 31 35 37'
    '2c 22 63 61 70 61 62 69 6c 69 74 69 65 73 22 3a 7b 22 6e 61 74 69'
    '76 65 44 69 61 6c 6f 67 73 22 3a 66 61 6c 73 65 2c 22 6c 6f 63 61'
    '6c 54 65 72 6d 69 6e 61 6c 22 3a 66 61 6c 73 65 2c 22 62 69 6e 61'
    '72 79 46 72 61 6d 65 73 22 3a 66 61 6c 73 65 2c 22 63 6f 6d 70 72'
    '65 73 73 69 6f 6e 22 3a 22 6e 6f 6e 65 22 2c 22 77 6f 72 6b 73 70'
    '61 63 65 48 6f 6f 6b 52 65 76 69 65 77 22 3a 74 72 75 65 7d 2c 22'
    '61 75 74 68 22 3a 7b 7d 7d';

const _error =
    '04 02 06 ca 01 06 04 05 50 7b 22 6d 65 73 73 61 67 65 22 3a 22 66'
    '61 75 6c 74 2e 63 6f 6e 6e 65 63 74 69 6f 6e 2e 63 6c 69 65 6e 74'
    '43 68 61 6e 67 65 64 22 2c 22 6e 61 6d 65 22 3a 22 45 72 72 6f 72'
    '22 2c 22 73 74 61 63 6b 22 3a 5b 22 45 72 72 6f 72 3a 20 78 22 5d'
    '7d';

const _rows =
    '04 02 06 c9 01 06 07 05 d1 03 7b 22 72 6f 77 73 22 3a 5b 7b 22 72'
    '6f 77 49 64 22 3a 36 31 33 2c 22 74 75 72 6e 49 64 22 3a 22 74 31'
    '22 2c 22 6b 69 6e 64 22 3a 22 74 6f 6f 6c 43 61 6c 6c 22 2c 22 74'
    '6f 6f 6c 4e 61 6d 65 22 3a 22 42 61 73 68 22 2c 22 73 74 61 74 75'
    '73 22 3a 22 73 75 63 63 65 73 73 22 2c 22 74 6f 6f 6c 43 61 6c 6c'
    '49 64 22 3a 22 63 61 6c 6c 5f 31 22 2c 22 76 69 73 69 62 69 6c 69'
    '74 79 22 3a 22 76 69 73 69 62 6c 65 22 2c 22 63 72 65 61 74 65 64'
    '41 74 22 3a 31 37 38 39 30 32 31 33 39 38 32 35 31 2c 22 69 6e 70'
    '75 74 54 65 78 74 22 3a 22 7b 5c 22 63 6f 6d 6d 61 6e 64 5c 22 3a'
    '5c 22 6c 73 20 2d 6c 61 5c 22 7d 22 7d 2c 7b 22 72 6f 77 49 64 22'
    '3a 36 31 34 2c 22 74 75 72 6e 49 64 22 3a 22 74 31 22 2c 22 6b 69'
    '6e 64 22 3a 22 72 65 61 73 6f 6e 69 6e 67 22 2c 22 74 65 78 74 22'
    '3a 22 54 68 72 65 65 20 74 65 73 74 20 62 75 67 73 22 2c 22 76 69'
    '73 69 62 69 6c 69 74 79 22 3a 22 76 69 73 69 62 6c 65 22 2c 22 63'
    '72 65 61 74 65 64 41 74 22 3a 31 37 38 39 30 32 31 33 39 39 30 30'
    '30 7d 2c 7b 22 72 6f 77 49 64 22 3a 36 31 35 2c 22 74 75 72 6e 49'
    '64 22 3a 22 74 31 22 2c 22 6b 69 6e 64 22 3a 22 61 73 73 69 73 74'
    '61 6e 74 54 65 78 74 22 2c 22 74 65 78 74 22 3a 22 e5 b7 b2 e4 bf'
    'ae e6 ad a3 e3 80 82 22 2c 22 73 74 61 74 65 22 3a 22 63 6f 6d 70'
    '6c 65 74 65 22 2c 22 76 69 73 69 62 69 6c 69 74 79 22 3a 22 76 69'
    '73 69 62 6c 65 22 2c 22 63 72 65 61 74 65 64 41 74 22 3a 31 37 38'
    '39 30 32 31 34 30 30 30 30 30 7d 5d 7d';

void main() {
  group('AgentResponse 解码（响应头 04 02 06）', () {
    test('hello 响应：类型 201、字段完整', () {
      final r = AgentRpcCodec.tryDecodeResponse(hex(_hello));
      expect(r, isNotNull);
      expect(r!.type, AgentResponseType.ok);
      expect(r.isOk, isTrue);
      expect(r.seq, 1);
      final v = r.value as Map;
      expect(v['kind'], 'hello');
      expect(v['protocolVersion'], 3);
      expect(v['connectionId'], 'host-rpc-test-0001');
      expect(v['clientMode'], 'web-remote-replayable');
      expect(v['deliveryProfile'], 'replayable');
      final caps = v['capabilities'] as Map;
      // 官方明确告知不使用二进制帧
      expect(caps['binaryFrames'], isFalse);
      expect(caps['workspaceHookReview'], isTrue);
    });

    test('错误响应：类型 202，可取出 fault 原因', () {
      final r = AgentRpcCodec.tryDecodeResponse(hex(_error));
      expect(r, isNotNull);
      expect(r!.type, AgentResponseType.error);
      expect(r.isError, isTrue);
      expect(r.isOk, isFalse);
      expect(r.faultReason, 'fault.connection.clientChanged');
    });

    test('rows 响应能解成 ConversationRow', () {
      final r = AgentRpcCodec.tryDecodeResponse(hex(_rows))!;
      final rows = ConversationRow.parseResponse(r.value);
      expect(rows, isNotNull);
      expect(rows!, hasLength(3));
      expect(rows[0].kind, ConversationRowKind.toolCall);
      expect(rows[0].toolName, 'Bash');
      expect(rows[0].status, 'success');
      expect(rows[0].inputText, contains('ls -la'));
      expect(rows[1].kind, ConversationRowKind.reasoning);
      expect(rows[1].text, 'Three test bugs');
      expect(rows[2].kind, ConversationRowKind.assistantText);
      expect(rows[2].text, '已修正。');
    });

    test('请求形态不会被误判成响应', () {
      // 请求头是 04 04，响应是 04 02
      final req = AgentRpcCodec.encode(
        const AgentRpc(
          kind: AgentFrameKind.call,
          seq: 1,
          service: 'setting',
          method: 'get',
        ),
      );
      expect(AgentRpcCodec.tryDecodeResponse(req), isNull);
      expect(AgentRpcCodec.looksLikeResponse(req), isFalse);
    });

    test('响应不会被误判成请求', () {
      expect(AgentRpcCodec.tryDecode(hex(_hello)), isNull);
    });

    test('过短或形状不符返回 null', () {
      expect(AgentRpcCodec.tryDecodeResponse(Uint8List(0)), isNull);
      expect(AgentRpcCodec.tryDecodeResponse(hex('04 02 06 c9')), isNull);
    });
  });

  group('ConversationRow', () {
    test('kind 映射未知值落到 unknown 且不崩', () {
      expect(
        ConversationRowKind.parse('toolCall'),
        ConversationRowKind.toolCall,
      );
      expect(
        ConversationRowKind.parse('userText'),
        ConversationRowKind.userText,
      );
      expect(ConversationRowKind.parse('??'), ConversationRowKind.unknown);
      expect(ConversationRowKind.parse(null), ConversationRowKind.unknown);
    });

    test('只有文本类行适合直接展示正文', () {
      expect(ConversationRowKind.assistantText.hasBodyText, isTrue);
      expect(ConversationRowKind.reasoning.hasBodyText, isTrue);
      expect(ConversationRowKind.toolCall.hasBodyText, isFalse);
      expect(ConversationRowKind.hookInvocation.hasBodyText, isFalse);
    });

    test('中文文本与转义路径往返正确', () {
      final row = ConversationRow.tryParse({
        'rowId': 1,
        'kind': 'toolCall',
        'toolName': 'Edit',
        'inputText': r'{"file_path":"E:\zcode\杂事.js"}',
      })!;
      expect(row.inputText, contains(r'E:\zcode\杂事.js'));
    });

    test('按 rowId 升序排序', () {
      final rows = [
        ConversationRow.tryParse({'rowId': 9, 'kind': 'assistantText'})!,
        ConversationRow.tryParse({'rowId': 3, 'kind': 'toolCall'})!,
        ConversationRow.tryParse({'rowId': 6, 'kind': 'reasoning'})!,
      ];
      final sorted = ConversationRow.sortedAscending(rows);
      expect(sorted.map((r) => r.rowId), [3, 6, 9]);
    });

    test('oldestRowId 用作向上翻页游标', () {
      final rows = [
        ConversationRow.tryParse({'rowId': 9, 'kind': 'x'})!,
        ConversationRow.tryParse({'rowId': 3, 'kind': 'x'})!,
      ];
      expect(ConversationRow.oldestRowId(rows), 3);
      expect(ConversationRow.oldestRowId([]), isNull);
    });

    test('可见性过滤', () {
      final a = ConversationRow.tryParse({'rowId': 1, 'kind': 'x'})!;
      final b = ConversationRow.tryParse({
        'rowId': 2,
        'kind': 'x',
        'visibility': 'hidden',
      })!;
      expect(a.isVisible, isTrue);
      expect(b.isVisible, isFalse);
    });

    test('形状不符返回 null；响应体不是 rows 也返回 null', () {
      expect(ConversationRow.tryParse(null), isNull);
      expect(ConversationRow.tryParse('x'), isNull);
      expect(ConversationRow.parseResponse({'nope': 1}), isNull);
      expect(ConversationRow.parseResponse(null), isNull);
      // 接受直接给数组
      expect(
        ConversationRow.parseResponse([
          {'rowId': 1, 'kind': 'x'},
        ]),
        hasLength(1),
      );
    });
  });
}

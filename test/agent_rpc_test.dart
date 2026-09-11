import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/relay/agent_rpc.dart';

Uint8List hex(String s) {
  final parts = s.trim().split(RegExp(r'\s+'));
  return Uint8List.fromList(parts.map((p) => int.parse(p, radix: 16)).toList());
}

String toHex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');

void main() {
  group('AgentRpcCodec 解码（真实抓包样本）', () {
    test('broadcast.onMessage —— 订阅、无参', () {
      final b = hex(
        '04 04 06 66 06 00 01 09 62 72 6f 61 64 63 61 73 74 '
        '01 09 6f 6e 4d 65 73 73 61 67 65 00',
      );
      final r = AgentRpcCodec.tryDecode(b);
      expect(r, isNotNull);
      expect(r!.kind, AgentFrameKind.subscribe);
      expect(r.seq, 0);
      expect(r.service, 'broadcast');
      expect(r.method, 'onMessage');
      expect(r.args, isEmpty);
    });

    test('setting.get —— 调用、0 个参数', () {
      final b = hex(
        '04 04 06 64 06 01 01 07 73 65 74 74 69 6e 67 '
        '01 03 67 65 74 04 00',
      );
      final r = AgentRpcCodec.tryDecode(b)!;
      expect(r.kind, AgentFrameKind.call);
      expect(r.seq, 1);
      expect(r.service, 'setting');
      expect(r.method, 'get');
      expect(r.args, isEmpty);
    });

    test('file-watcher.onDynamicChange —— 字符串参数 "12"', () {
      final b = hex(
        '04 04 06 66 06 52 01 0c 66 69 6c 65 2d 77 61 74 63 68 65 72 '
        '01 0f 6f 6e 44 79 6e 61 6d 69 63 43 68 61 6e 67 65 01 02 31 32',
      );
      final r = AgentRpcCodec.tryDecode(b)!;
      expect(r.kind, AgentFrameKind.subscribe);
      expect(r.seq, 0x52);
      expect(r.service, 'file-watcher');
      expect(r.method, 'onDynamicChange');
      expect(r.args.single, '12');
    });

    test('call 构建器：JSON 参数用 Map 传入（不是预编码字符串）', () {
      final r = AgentRpc.call(
        seq: 4,
        service: 'file-watcher',
        method: 'watch',
        args: [
          {'path': r'E:/zcode/.git', 'recursive': true},
        ],
      );
      final decoded = AgentRpcCodec.tryDecode(AgentRpcCodec.encode(r))!;
      expect(decoded.args.single, {
        'path': r'E:/zcode/.git',
        'recursive': true,
      });
    });

    test('字符串参数与 JSON 参数用的是不同标签', () {
      final asString = AgentRpcCodec.encode(
        const AgentRpc(
          kind: AgentFrameKind.call,
          seq: 1,
          service: 's',
          method: 'm',
          args: ['{"a":1}'],
        ),
      );
      final asJson = AgentRpcCodec.encode(
        AgentRpc(
          kind: AgentFrameKind.call,
          seq: 1,
          service: 's',
          method: 'm',
          args: [
            {'a': 1},
          ],
        ),
      );
      // 字符串标签 01，JSON 标签 05
      expect(AgentRpcCodec.tryDecode(asString)!.args.single, isA<String>());
      expect(AgentRpcCodec.tryDecode(asJson)!.args.single, isA<Map>());
      expect(asString, isNot(asJson));
    });

    test('subscribeConversationV4 —— 真实方法名与参数', () {
      final rpc = AgentRpc.call(
        seq: 102,
        service: 'zcode-agent',
        method: 'subscribeConversationV4',
        args: [
          {'workspacePath': r'E:\x', 'sessionId': 'sess_1'},
        ],
      );
      final decoded = AgentRpcCodec.tryDecode(AgentRpcCodec.encode(rpc))!;
      expect(decoded.service, 'zcode-agent');
      expect(decoded.method, 'subscribeConversationV4');
      expect(decoded.args.single, {
        'workspacePath': r'E:\x',
        'sessionId': 'sess_1',
      });
    });

    test('形状不符一律返回 null', () {
      expect(AgentRpcCodec.tryDecode(Uint8List(0)), isNull);
      expect(AgentRpcCodec.tryDecode(hex('01 02 03 04 05 06 07 08')), isNull);
      // kind 非法
      expect(
        AgentRpcCodec.tryDecode(
          hex('04 04 06 7a 06 00 01 01 61 01 01 62 04 00'),
        ),
        isNull,
      );
      // 长度越界
      expect(
        AgentRpcCodec.tryDecode(hex('04 04 06 64 06 00 01 20 61 62 63')),
        isNull,
      );
    });
  });

  group('AgentRpcCodec 编码（与抓包逐字节对齐）', () {
    test('broadcast.onMessage 编码结果与抓包样本完全一致', () {
      final bytes = AgentRpcCodec.encode(
        const AgentRpc(
          kind: AgentFrameKind.subscribe,
          seq: 0,
          service: 'broadcast',
          method: 'onMessage',
        ),
      );
      expect(
        toHex(bytes),
        '04 04 06 66 06 00 01 09 62 72 6f 61 64 63 61 73 74 '
        '01 09 6f 6e 4d 65 73 73 61 67 65 00',
      );
    });

    test('setting.get 编码结果与抓包样本完全一致', () {
      final bytes = AgentRpcCodec.encode(
        const AgentRpc(
          kind: AgentFrameKind.call,
          seq: 1,
          service: 'setting',
          method: 'get',
        ),
      );
      expect(
        toHex(bytes),
        '04 04 06 64 06 01 01 07 73 65 74 74 69 6e 67 '
        '01 03 67 65 74 04 00',
      );
    });

    test('file-watcher.onDynamicChange（字符串参数）逐字节一致', () {
      final bytes = AgentRpcCodec.encode(
        const AgentRpc(
          kind: AgentFrameKind.subscribe,
          seq: 0x52,
          service: 'file-watcher',
          method: 'onDynamicChange',
          args: ['12'],
        ),
      );
      expect(
        toHex(bytes),
        '04 04 06 66 06 52 01 0c 66 69 6c 65 2d 77 61 74 63 68 65 72 '
        '01 0f 6f 6e 44 79 6e 61 6d 69 63 43 68 61 6e 67 65 01 02 31 32',
      );
    });

    test('subscribeSessionsIndexV4 与官方抓包逐字节一致（含中文路径）', () {
      // 官方帧 seq=57，118 字节，来自真实远控会话上行
      const official =
          '04 04 06 64 06 39 01 0b 7a 63 6f 64 65 2d 61 67 65 6e 74 '
          '01 18 73 75 62 73 63 72 69 62 65 53 65 73 73 69 6f 6e 73 49 6e 64 65 78 56 34 '
          '04 01 05 45 7b 22 77 6f 72 6b 73 70 61 63 65 50 61 74 68 22 3a 22 45 3a 5c 5c '
          '7a 63 6f 64 65 5c 5c e6 9d 82 e4 ba 8b 22 2c 22 72 75 6e 74 69 6d 65 50 6f 6c '
          '69 63 79 22 3a 22 65 78 69 73 74 69 6e 67 2d 6f 6e 6c 79 22 7d';

      final bytes = AgentRpcCodec.encode(
        AgentRpc.call(
          seq: 57,
          service: 'zcode-agent',
          method: 'subscribeSessionsIndexV4',
          args: [
            {'workspacePath': r'E:\zcode\杂事', 'runtimePolicy': 'existing-only'},
          ],
        ),
      );

      expect(bytes.length, 118, reason: '长度应与官方帧一致');
      expect(toHex(bytes), official.replaceAll(RegExp(r'\s+'), ' ').trim());
    });

    test('subscribeConversationV4 编码长度与官方帧一致', () {
      // 官方帧 seq=102，141 字节
      final bytes = AgentRpcCodec.encode(
        AgentRpc.call(
          seq: 102,
          service: 'zcode-agent',
          method: 'subscribeConversationV4',
          args: [
            {
              'workspacePath': r'E:\zcode\杂事',
              'sessionId': 'sess_b97bd6d8-4fc2-4ba1-921e-5455ceb809f7',
            },
          ],
        ),
      );
      expect(bytes.length, 141);
      final r = AgentRpcCodec.tryDecode(bytes)!;
      expect(r.method, 'subscribeConversationV4');
      expect(r.args.single, {
        'workspacePath': r'E:\zcode\杂事',
        'sessionId': 'sess_b97bd6d8-4fc2-4ba1-921e-5455ceb809f7',
      });
    });

    test('varint 编解码往返（含多字节）', () {
      for (final v in [0, 1, 63, 64, 127, 128, 300, 16383, 16384, 1 << 20]) {
        final b = BytesBuilder(copy: false);
        AgentRpcCodec.writeVarint(b, v);
        final bytes = b.toBytes();
        final r = AgentRpcCodec.tryReadVarint(bytes, 0)!;
        expect(r.value, v, reason: 'v=$v');
        expect(r.next, bytes.length, reason: 'v=$v');
      }
    });

    test('负数 varint 直接拒绝', () {
      final b = BytesBuilder(copy: false);
      expect(() => AgentRpcCodec.writeVarint(b, -1), throwsArgumentError);
    });

    test('多参数按顺序编解码', () {
      final bytes = AgentRpcCodec.encode(
        const AgentRpc(
          kind: AgentFrameKind.call,
          seq: 7,
          service: 'svc',
          method: 'm',
          args: [
            'a',
            {'k': 1},
          ],
        ),
      );
      final r = AgentRpcCodec.tryDecode(bytes)!;
      expect(r.args, hasLength(2));
      expect(r.args[0], 'a');
      expect(r.args[1], {'k': 1});
    });

    test('中文参数往返正确', () {
      final bytes = AgentRpcCodec.encode(
        const AgentRpc(
          kind: AgentFrameKind.call,
          seq: 1,
          service: 'zcode-agent',
          method: 'conversationRowsRangeV4',
          args: [
            {'workspacePath': r'E:\zcode\杂事', 'limit': 200},
          ],
        ),
      );
      final r = AgentRpcCodec.tryDecode(bytes)!;
      expect(r.args.single, {'workspacePath': r'E:\zcode\杂事', 'limit': 200});
    });
  });
}

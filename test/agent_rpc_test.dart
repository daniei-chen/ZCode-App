import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/relay/agent_rpc.dart';

void main() {
  test('CRC-32 金向量：官方实测帧 04 01 06 C8 01 00 = b4ff6360', () {
    expect(AgentWire.crc32Hex([0x04, 0x01, 0x06, 0xC8, 0x01, 0x00]),
        'b4ff6360');
    // 空/已知向量防退化。
    expect(AgentWire.crc32Hex([]), '00000000');
    expect(AgentWire.crc32(utf8.encode('123456789')), 0xCBF43926);
  });

  test('base64 金向量：BAEGyAEA 解码 = 04 01 06 C8 01 00（标准字母表带填充）',
      () {
    final bytes = AgentWire.decodePayloadBase64('BAEGyAEA');
    expect(bytes, [0x04, 0x01, 0x06, 0xC8, 0x01, 0x00]);
    // 编码必须产标准 base64 带填充（URL-safe 会被判 rpc-transport-fault）。
    expect(AgentWire.encodePayloadBase64(bytes), 'BAEGyAEA');
    // 解码器对 URL-safe 输入也兼容（桌面端下行两种字母表都出现过）。
    final round = utf8.encode('{"a":"+/="}');
    expect(AgentWire.decodePayloadBase64(
        AgentWire.encodePayloadBase64(round)), round);
  });

  test('varint 往返：1/127/128/300/2^20', () {
    final builder = BytesBuilder();
    for (final v in [1, 127, 128, 300, 0x100000]) {
      AgentWire.writeVarint(builder, v);
    }
    final bytes = builder.toBytes();
    final cursor = [0];
    for (final v in [1, 127, 128, 300, 0x100000]) {
      expect(AgentWire.readVarint(bytes, cursor[0], cursor), v);
    }
    expect(cursor[0], bytes.length);
  });

  test('请求帧形状：04 04 06 64 + varint seq + service/method 带长度前缀', () {
    final frame = AgentWire.encodeRequest(
      seq: 1,
      service: 'zcode-agent',
      method: 'helloConversationV4',
      args: const [],
    );
    // 头五字节固定。
    expect(frame.sublist(0, 5), [0x04, 0x04, 0x06, 0x64, 0x06]);
    // seq=1。
    final cursor = [5];
    expect(AgentWire.readVarint(frame, cursor[0], cursor), 1);
    // service 长度前缀 + 内容。
    expect(frame[cursor[0]], 0x01);
    cursor[0] += 1;
    final serviceLen =
        AgentWire.readVarint(frame, cursor[0], cursor);
    expect(serviceLen, 'zcode-agent'.length);
    expect(utf8.decode(frame.sublist(cursor[0], cursor[0] + serviceLen)),
        'zcode-agent');
  });

  test('无参调用的 args = 04 00；JSON 参数走 05 标签', () {
    final noArgs = AgentWire.encodeRequest(
      seq: 1,
      service: 'a',
      method: 'b',
      args: const [],
    );
    // 结尾两个字节是 args 计数标签：04 00。
    expect(noArgs.sublist(noArgs.length - 2), [0x04, 0x00]);

    final jsonArg = AgentWire.encodeRequest(
      seq: 2,
      service: 'a',
      method: 'b',
      args: [
        {'k': 'v'},
      ],
    );
    // args 段：04 01 05 <varint len> <json>。
    final idx = jsonArg.lastIndexOf(0x04);
    expect(jsonArg[idx + 1], 0x01); // 一个参数
    expect(jsonArg[idx + 2], 0x05); // JSON 标签
    final cursor = [idx + 3];
    final len = AgentWire.readVarint(jsonArg, cursor[0], cursor);
    expect(utf8.decode(jsonArg.sublist(cursor[0], cursor[0] + len)),
        '{"k":"v"}');
  });

  test('响应解码：成功 0xC9 带 JSON；失败 0xCA 返回 null；坏头返回 null', () {
    final json = utf8.encode('{"clientMode":"web-remote-replayable"}');
    final ok = <int>[
      0x04, 0x02, 0x06, 0xC9, 0x01, 0x06, 0x01, // seq=1
      0x05,
      json.length,
      ...json,
    ];
    final decoded = AgentWire.tryDecodeResponse(Uint8List.fromList(ok));
    expect(decoded, isA<Map>());
    expect((decoded as Map)['clientMode'], 'web-remote-replayable');

    final fail = Uint8List.fromList([
      0x04, 0x02, 0x06, 0xCA, 0x01, 0x06, 0x01, 0x05, 0x02, 0x7B, 0x7D,
    ]);
    expect(AgentWire.tryDecodeResponse(fail), isNull);
    // 请求方向（04 04）不是响应。
    expect(
      AgentWire.tryDecodeResponse(
        Uint8List.fromList([0x04, 0x04, 0x06, 0x64]),
      ),
      isNull,
    );
    expect(AgentWire.tryDecodeResponse(Uint8List.fromList([0x04])), isNull);
  });

  test('rpc-frame 信封：CRC 与 base64 对齐、ack 形状', () {
    final payload = Uint8List.fromList([0x04, 0x01, 0x06, 0xC8, 0x01, 0x00]);
    final envelope = AgentWire.rpcFrameEnvelope(
      bridgeSessionId: 'bridge-1',
      bridgeGeneration: 1,
      messageSeq: 1,
      payload: payload,
    );
    expect(envelope['zcode_type'], 'rpc-frame');
    expect((envelope['checksum'] as Map)['value'], 'b4ff6360');
    expect(envelope['dataBase64'], 'BAEGyAEA');
    expect(envelope['messageBytes'], 6);
    expect(envelope['fragmentCount'], 1);

    final ack = AgentWire.ackEnvelope(
      bridgeSessionId: 'bridge-1',
      bridgeGeneration: 1,
      ackMessageSeq: 1,
    );
    expect(ack['zcode_type'], 'rpc-frame-ack');
    expect(ack['ackMessageSeq'], 1);
  });

  test('命令信封：页面 Bl() 的字段全集（bundle 实证）', () {
    final envelope = AgentWire.commandEnvelope(
      commandId: 'c1',
      clientId: 'zr-notif',
      type: 'resolveInteraction',
      sessionId: 'sess_1',
      payload: {
        'interactionId': 'i1',
        'answer': {'optionId': 'allow'},
      },
    );
    expect(envelope['commandId'], 'c1');
    expect(envelope['clientId'], 'zr-notif');
    expect(envelope['sessionId'], 'sess_1');
    expect(envelope['type'], 'resolveInteraction');
    expect((envelope['payload'] as Map)['interactionId'], 'i1');
    expect(envelope['issuedAt'], isA<int>());
    // sessionId 为空的命令（sendText 不带会话）不写 sessionId 字段。
    final noSession = AgentWire.commandEnvelope(
      commandId: 'c2',
      clientId: 'zr',
      type: 'sendText',
      payload: {'text': 'hi'},
    );
    expect(noSession.containsKey('sessionId'), isFalse);
  });
}

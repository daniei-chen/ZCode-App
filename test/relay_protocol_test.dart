import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/relay/relay_frame.dart';
import 'package:zremote/relay/relay_link.dart';
import 'package:zremote/relay/relay_proof.dart';
import 'package:zremote/relay/rpc_assembler.dart';

/// URL 安全、无填充的 base64（与协议一致）。
String b64(String text) =>
    base64Url.encode(utf8.encode(text)).replaceAll('=', '');

RpcFrame frame({
  String sid = 'bridge-1',
  int? generation,
  String? recovery,
  int? seq,
  int index = 0,
  int count = 1,
  String? data,
  int? messageBytes,
  String? checksum,
  String? checksumAlgorithm,
  bool ack = false,
  int? ackSeq,
}) => RpcFrame(
  bridgeSessionId: sid,
  bridgeGeneration: generation,
  recoveryId: recovery,
  seq: seq,
  messageSeq: seq,
  fragmentIndex: index,
  fragmentCount: count,
  messageBytes: messageBytes,
  checksum: checksum,
  checksumAlgorithm: checksumAlgorithm,
  dataBase64: data,
  isAck: ack,
  ackMessageSeq: ackSeq,
);

void main() {
  group('RelayProof', () {
    test('base64url 无填充：去掉 = 并换掉 +/', () {
      // 0xFB 0xFF 0xBF 会产生 + / 与填充
      expect(RelayProof.base64UrlNoPad([0xFB, 0xFF, 0xBF]), '-_-_');
      expect(RelayProof.base64UrlNoPad([]), '');
      expect(RelayProof.base64UrlNoPad([65]), 'QQ');
    });

    test('proof 与独立实现（Python hmac）逐字节一致', () {
      // 向量由 Python hmac/hashlib 独立算出，作为跨实现基准
      expect(
        RelayProof.calculate(
          passHash: 'test-pass-hash',
          nonce: 'abc123',
          role: RelayProof.roleTerminal,
          deviceSid: 'dev-001',
        ),
        'bdIZBPdENxWtAKUXsDZyFPGHXx9OiOtqinhXc-mTUDw',
      );
      expect(
        RelayProof.calculate(
          passHash: 'p@ss',
          nonce: 'n-0',
          role: RelayProof.roleDevice,
          deviceSid: 's',
        ),
        'S03oPfWYJR3gVmO93qgv44k34MDm1n7Nivz2F0eKOuM',
      );
    });

    test('role 参与签名：terminal 与 device 结果必须不同', () {
      final t = RelayProof.calculate(
        passHash: 'k',
        nonce: 'n',
        role: RelayProof.roleTerminal,
        deviceSid: 'd',
      );
      final d = RelayProof.calculate(
        passHash: 'k',
        nonce: 'n',
        role: RelayProof.roleDevice,
        deviceSid: 'd',
      );
      expect(t, isNot(d));
    });

    test('forTerminal 等价于 role=terminal', () {
      expect(
        RelayProof.forTerminal(passHash: 'k', nonce: 'n', deviceSid: 'd'),
        RelayProof.calculate(
          passHash: 'k',
          nonce: 'n',
          role: 'terminal',
          deviceSid: 'd',
        ),
      );
    });

    test('nonce 变化会改变 proof（防重放）', () {
      final a = RelayProof.forTerminal(
        passHash: 'k',
        nonce: 'n1',
        deviceSid: 'd',
      );
      final b = RelayProof.forTerminal(
        passHash: 'k',
        nonce: 'n2',
        deviceSid: 'd',
      );
      expect(a, isNot(b));
    });
  });

  group('RelayLink', () {
    test('解析 v4 链接的全部参数', () {
      final link = RelayLink.parse(
        'https://zcode.z.ai/remote/v4?remoteControlToken=tok-1'
        '&relayOrigin=https://relay.example.com&deviceSid=dev-9'
        '&passHash=hash-9&deviceMid=mid-9&appVersion=3.11.2&theme=dark',
      );
      expect(link, isNotNull);
      expect(link!.token, 'tok-1');
      expect(link.origin, 'https://relay.example.com');
      expect(link.deviceSid, 'dev-9');
      expect(link.passHash, 'hash-9');
      expect(link.deviceMid, 'mid-9');
      expect(link.appVersion, '3.11.2');
      expect(link.theme, 'dark');
      expect(link.canAuthenticate, isTrue);
    });

    test('relayOrigin 缺省时回落到链接自身 origin', () {
      final link = RelayLink.parse(
        'https://zcode.z.ai/remote/v4?remoteControlToken=t',
      );
      expect(link!.origin, 'https://zcode.z.ai');
    });

    test('兼容 v3 形态（sid / hash / mid）', () {
      final link = RelayLink.parse(
        'https://zcode.z.ai/remote/v3?sid=tok-v3&hash=h-v3&mid=m',
      );
      expect(link!.deviceSid, 'tok-v3');
      expect(link.passHash, 'h-v3');
      expect(link.deviceMid, 'm');
      expect(link.hasRestApi, isFalse);
      expect(link.canAuthenticate, isTrue);
    });

    test('实测生产链接（ZCode 3.11.2）解析正确', () {
      // 参数名与编码形态均来自真实链接：hash 是 URL 编码的 base64
      final link = RelayLink.parse(
        'https://zcode.z.ai/remote/v4'
        '?sid=d_EXAMPLE000000000000000'
        '&hash=%2FEXAMPLE%2BEXAMPLE%2FEXAMPLE%3D'
        '&t=1789013692786'
        '&mid=00000000-0000-4000-8000-000000000000'
        '&name=DESKTOP-EXAMPLE'
        '&app_version=3.11.2',
      );
      expect(link, isNotNull);
      expect(link!.origin, 'https://zcode.z.ai');
      expect(link.deviceSid, 'd_EXAMPLE000000000000000');
      // 百分号解码后是标准 base64，包含 + / =
      expect(link.passHash, '/EXAMPLE+EXAMPLE/EXAMPLE=');
      expect(link.deviceMid, '00000000-0000-4000-8000-000000000000');
      expect(link.deviceName, 'DESKTOP-EXAMPLE');
      expect(link.appVersion, '3.11.2');
      expect(link.issuedAt, 1789013692786);
      expect(link.token, isNull);
      expect(link.canAuthenticate, isTrue);
      expect(RelayLink.usesV4(link.appVersion), isTrue);
      // Model B 主通道
      expect(link.relaySocketUrl.toString(), 'wss://zcode.z.ai/ws');
      // 无 token 时 REST 端点不可用
      expect(link.bootstrapUrl, isNull);
      expect(link.windowSocketUrl, isNull);
    });

    test('缺任一凭证都不是 relay 链接', () {
      expect(RelayLink.parse('https://zcode.z.ai/remote/v4'), isNull);
      expect(
        RelayLink.parse('https://zcode.z.ai/remote/v4?remoteControlToken='),
        isNull,
      );
      expect(RelayLink.parse('   '), isNull);
      expect(RelayLink.parse('not a url'), isNull);
    });

    test('from() 用已存字段解析，sid 视为 deviceSid', () {
      final link = RelayLink.from(
        baseUrl: 'https://zcode.z.ai/remote/v4',
        params: const {
          'sid': 'd1',
          'hash': 'h1',
          'mid': 'm1',
          'app_version': '3.11.2',
        },
      );
      expect(link!.deviceSid, 'd1');
      expect(link.canAuthenticate, isTrue);
      expect(link.origin, 'https://zcode.z.ai');
      // 完全没有任何凭证时判为非 relay 记录
      expect(
        RelayLink.from(baseUrl: 'https://x', params: const {'foo': 'a'}),
        isNull,
      );
    });

    test('缺少 deviceSid 或 passHash 时 canAuthenticate 为 false', () {
      final a = RelayLink.parse('https://x/remote/v4?remoteControlToken=t');
      expect(a!.canAuthenticate, isFalse);
      final b = RelayLink.parse(
        'https://x/remote/v4?remoteControlToken=t&deviceSid=d',
      );
      expect(b!.canAuthenticate, isFalse);
    });

    test('wsBase 按 scheme 换协议', () {
      final https = RelayLink.parse(
        'https://zcode.z.ai/remote/v4?remoteControlToken=t',
      );
      expect(https!.wsBase.toString(), 'wss://zcode.z.ai');

      final http = RelayLink.parse(
        'http://localhost:8081/remote/v4?remoteControlToken=t',
      );
      expect(http!.wsBase.toString(), 'ws://localhost:8081');
    });

    test('端点拼装与 token 一致（Model A）', () {
      final l = RelayLink.parse(
        'https://zcode.z.ai/remote/v4?remoteControlToken=ABC',
      )!;
      expect(l.hasRestApi, isTrue);
      expect(
        l.bootstrapUrl.toString(),
        'https://zcode.z.ai/api/remote-control/windows/bootstrap/ABC',
      );
      expect(
        l.windowSocketUrl.toString(),
        'wss://zcode.z.ai/ws/remote-control/window/ABC',
      );
      expect(
        l.workspaceBridgeUrl.toString(),
        'https://zcode.z.ai/api/remote-control/windows/ABC/workspace-bridge',
      );
      expect(
        l.viewStateUrl.toString(),
        'https://zcode.z.ai/api/remote-control/windows/ABC/mobile-view-state',
      );
      expect(
        l.platformUrl.toString(),
        'https://zcode.z.ai/api/remote-control/platform/ABC',
      );
    });

    test('带 ?remote= 时给出直连通道地址', () {
      final l = RelayLink.parse(
        'https://zcode.z.ai/remote/v4?remoteControlToken=t&remote=r-7',
      )!;
      expect(l.remoteId, 'r-7');
      expect(l.remoteSocketUrl.toString(), 'wss://zcode.z.ai/ws/remote/r-7');
    });

    test('无 remote 参数时直连通道为 null', () {
      final l = RelayLink.parse(
        'https://zcode.z.ai/remote/v4?remoteControlToken=t',
      )!;
      expect(l.remoteSocketUrl, isNull);
    });

    test('origin 归一化：去尾斜杠、补 scheme', () {
      expect(RelayLink.normalizeOrigin('https://a.com/'), 'https://a.com');
      expect(RelayLink.normalizeOrigin('a.com'), 'https://a.com');
    });

    test('usesV4 阈值：3.4 起走 v4', () {
      expect(RelayLink.usesV4('3.4.0'), isTrue);
      expect(RelayLink.usesV4('3.11.2'), isTrue);
      expect(RelayLink.usesV4('v4.0.0'), isTrue);
      expect(RelayLink.usesV4('3.3.9'), isFalse);
      expect(RelayLink.usesV4('2.9.9'), isFalse);
      expect(RelayLink.usesV4(null), isFalse);
      expect(RelayLink.usesV4('garbage'), isFalse);
    });
  });

  group('WireBase64 / Crc32', () {
    test('解码带与不带填充都成立', () {
      expect(WireBase64.tryDecodeUtf8(b64('hello')), 'hello');
      expect(WireBase64.tryDecodeUtf8('aGVsbG8='), 'hello');
      expect(WireBase64.tryDecodeUtf8(''), isNull);
    });

    test('非法字符返回 null 而不是抛异常', () {
      expect(WireBase64.tryDecode('!!!!'), isNull);
      expect(WireBase64.tryDecode('a'), isNull); // 单字符不足以构成一个字节
    });

    test('中文往返正确', () {
      const text = '会话标题：用量统计 ✅';
      expect(WireBase64.tryDecodeUtf8(b64(text)), text);
    });

    test('crc32 命中 IEEE 基准向量', () {
      expect(Crc32.of(utf8.encode('123456789')), 0xCBF43926);
      expect(Crc32.of(const []), 0);
    });
  });

  group('RelayEnvelope', () {
    test('解析 data 信封', () {
      final env = RelayEnvelope.tryParse(
        '{"type":"data","payload":{"zcode_type":"rpc-frame"},'
        '"client_ts":1,"server_ts":2}',
      );
      expect(env!.type, 'data');
      expect(env.payload!['zcode_type'], 'rpc-frame');
      expect(env.clientTs, 1);
      expect(env.serverTs, 2);
    });

    test('形状不符返回 null', () {
      expect(RelayEnvelope.tryParse('not json'), isNull);
      expect(RelayEnvelope.tryParse('[1,2]'), isNull);
      expect(RelayEnvelope.tryParse('{"payload":{}}'), isNull);
      expect(RelayEnvelope.tryParse('{"type":""}'), isNull);
    });

    test('握手消息提取 nonce / device_sid', () {
      final ch = RelayHandshake.from(
        RelayEnvelope.tryParse(
          '{"type":"auth_challenge","payload":{"nonce":"n1"}}',
        )!,
      );
      expect(ch!.nonce, 'n1');

      final ac = RelayHandshake.from(
        RelayEnvelope.tryParse(
          '{"type":"device_register_ack","payload":{"device_sid":"d1"}}',
        )!,
      );
      expect(ac!.deviceSid, 'd1');
    });
  });

  group('RpcFrame 解析', () {
    test('接受合法 data 帧', () {
      final f = RpcFrame.tryParse({
        'zcode_type': 'rpc-frame',
        'bridgeSessionId': 'b1',
        'seq': 3,
        'fragmentIndex': 0,
        'fragmentCount': 1,
        'dataBase64': b64('{}'),
      });
      expect(f, isNotNull);
      expect(f!.isAck, isFalse);
      expect(f.bridgeSessionId, 'b1');
    });

    test('接受 ack 帧', () {
      final f = RpcFrame.tryParse({
        'zcode_type': 'rpc-frame-ack',
        'bridgeSessionId': 'b1',
        'ackMessageSeq': 7,
      });
      expect(f!.isAck, isTrue);
      expect(f.ackMessageSeq, 7);
    });

    test('拒绝：未知类型 / 缺 sessionId / 超长 id', () {
      expect(RpcFrame.tryParse({'zcode_type': 'other'}), isNull);
      expect(RpcFrame.tryParse({'zcode_type': 'rpc-frame'}), isNull);
      expect(
        RpcFrame.tryParse({
          'zcode_type': 'rpc-frame',
          'bridgeSessionId': 'x' * 257,
          'dataBase64': b64('{}'),
        }),
        isNull,
      );
    });

    test('拒绝：分片数超上限或索引越界', () {
      expect(
        RpcFrame.tryParse({
          'zcode_type': 'rpc-frame',
          'bridgeSessionId': 'b',
          'fragmentCount': 65,
          'fragmentIndex': 0,
          'dataBase64': b64('{}'),
        }),
        isNull,
      );
      expect(
        RpcFrame.tryParse({
          'zcode_type': 'rpc-frame',
          'bridgeSessionId': 'b',
          'fragmentCount': 2,
          'fragmentIndex': 2,
          'dataBase64': b64('{}'),
        }),
        isNull,
      );
    });

    test('拒绝：声明体积超上限', () {
      expect(
        RpcFrame.tryParse({
          'zcode_type': 'rpc-frame',
          'bridgeSessionId': 'b',
          'messageBytes': RelayLimits.maxMessageBytes + 1,
          'dataBase64': b64('{}'),
        }),
        isNull,
      );
    });

    test('isCandidate 只认两种传输类型', () {
      expect(RpcFrame.isCandidate({'zcode_type': 'rpc-frame'}), isTrue);
      expect(RpcFrame.isCandidate({'zcode_type': 'rpc-frame-ack'}), isTrue);
      expect(RpcFrame.isCandidate({'zcode_type': 'task.upserted'}), isFalse);
      expect(RpcFrame.isCandidate(null), isFalse);
    });
  });

  group('RpcAssembler', () {
    test('单帧消息直接产出文本', () {
      final a = RpcAssembler();
      final out = a.accept(frame(data: b64('{"op":"x"}')));
      expect(out, isA<AssemblyMessage>());
      expect((out as AssemblyMessage).text, '{"op":"x"}');
    });

    test('单帧校验 messageBytes 与 CRC32', () {
      final bytes = utf8.encode('hello');
      final checksum = Crc32.of(bytes).toRadixString(16).padLeft(8, '0');
      final a = RpcAssembler();
      final out = a.accept(
        frame(
          data: base64Url.encode(bytes).replaceAll('=', ''),
          messageBytes: bytes.length,
          checksum: checksum,
          checksumAlgorithm: 'crc32',
        ),
      );
      expect(out, isA<AssemblyMessage>());

      final bad = RpcAssembler().accept(
        frame(
          data: base64Url.encode(bytes).replaceAll('=', ''),
          messageBytes: bytes.length,
          checksum: '00000000',
          checksumAlgorithm: 'crc32',
        ),
      );
      expect((bad as AssemblyFault).reason, RpcFaultReason.checksumMismatch);
    });

    test('未收到的分片返回 Incomplete', () {
      final a = RpcAssembler();
      expect(
        a.accept(frame(data: b64('ab'), index: 0, count: 2)),
        isA<AssemblyIncomplete>(),
      );
      expect(a.openSlotCount, 1);
    });

    test('多分片乱序也能正确重组', () {
      final a = RpcAssembler();
      expect(
        a.accept(frame(data: b64('world'), index: 1, count: 2)),
        isA<AssemblyIncomplete>(),
      );
      final out = a.accept(frame(data: b64('hello'), index: 0, count: 2));
      expect((out as AssemblyMessage).text, 'helloworld');
      expect(a.openSlotCount, 0);
    });

    test('身份不一致的帧被拒绝（不同 bridgeSessionId）', () {
      final a = RpcAssembler();
      a.accept(frame(sid: 'b1', data: b64('x')));
      final out = a.accept(frame(sid: 'b2', data: b64('y')));
      expect(out, isA<AssemblyFault>());
      expect((out as AssemblyFault).reason, RpcFaultReason.transportFault);
    });

    test('identity 首帧锁定后固定不变', () {
      final a = RpcAssembler();
      expect(a.identity, isNull);
      a.accept(frame(sid: 'b1', generation: 4, data: b64('x')));
      expect(a.identity!.bridgeSessionId, 'b1');
      expect(a.identity!.bridgeGeneration, 4);
    });

    test('重复分片视为损坏并丢弃整条', () {
      final a = RpcAssembler();
      a.accept(frame(data: b64('a'), index: 0, count: 2));
      final out = a.accept(frame(data: b64('c'), index: 0, count: 2));
      expect(out, isA<AssemblyFault>());
      expect(a.openSlotCount, 0);
    });

    test('非法 base64 分片报传输故障', () {
      final a = RpcAssembler();
      final out = a.accept(frame(data: '!!!!', index: 0, count: 2));
      expect(out, isA<AssemblyFault>());
    });

    test('seq 跳跃上报 rpc-frame-gap 并给出缺口数', () {
      final a = RpcAssembler();
      a.accept(frame(seq: 1, data: b64('a')));
      final out = a.accept(frame(seq: 5, data: b64('b')));
      expect(out, isA<AssemblyFault>());
      final f = out as AssemblyFault;
      expect(f.reason, RpcFaultReason.frameGap);
      expect(f.expectedSeq, 2);
      expect(f.droppedCount, 3);
    });

    test('seq 重传（不前进）被识别为重复，不重复交付', () {
      final a = RpcAssembler();
      expect(a.accept(frame(seq: 3, data: b64('a'))), isA<AssemblyMessage>());
      expect(a.accept(frame(seq: 3, data: b64('a'))), isA<AssemblyDuplicate>());
      expect(a.accept(frame(seq: 2, data: b64('a'))), isA<AssemblyDuplicate>());
      // 前进的 seq 仍能交付
      expect(a.accept(frame(seq: 4, data: b64('b'))), isA<AssemblyMessage>());
    });

    test('多分片消息重传也去重', () {
      final a = RpcAssembler();
      a.accept(frame(seq: 5, data: b64('x'), index: 0, count: 2));
      expect(
        a.accept(frame(seq: 5, data: b64('y'), index: 1, count: 2)),
        isA<AssemblyMessage>(),
      );
      // 整条重放
      a.accept(frame(seq: 5, data: b64('x'), index: 0, count: 2));
      expect(
        a.accept(frame(seq: 5, data: b64('y'), index: 1, count: 2)),
        isA<AssemblyDuplicate>(),
      );
      expect(a.openSlotCount, 0);
    });

    test('reset 后 seq 重新可用', () {
      final a = RpcAssembler();
      a.accept(frame(seq: 9, data: b64('a')));
      expect(a.accept(frame(seq: 9, data: b64('a'))), isA<AssemblyDuplicate>());
      a.reset();
      expect(a.accept(frame(seq: 9, data: b64('a'))), isA<AssemblyMessage>());
    });

    test('ack 帧直接透传', () {
      final a = RpcAssembler();
      final out = a.accept(frame(ack: true, ackSeq: 9));
      expect((out as AssemblyAck).ackMessageSeq, 9);
    });

    test('分片累计体积超上限报 buffer-overflow', () {
      final a = RpcAssembler();
      final big = 'x' * (RelayLimits.maxMessageBytes ~/ 2 + 1024);
      a.accept(frame(data: b64(big), index: 0, count: 4));
      final out = a.accept(frame(data: b64(big), index: 1, count: 4));
      expect(out, isA<AssemblyFault>());
      expect((out as AssemblyFault).reason, RpcFaultReason.bufferOverflow);
    });

    test('槽位超时被清理并上报 buffer-timeout', () {
      var now = 1000;
      final a = RpcAssembler(clock: () => now);
      a.accept(frame(data: b64('a'), index: 0, count: 2));
      expect(a.openSlotCount, 1);
      now += RelayLimits.assemblyTimeout.inMilliseconds + 1;
      expect(a.takeTimeoutReason(), RpcFaultReason.bufferTimeout);
      expect(a.openSlotCount, 0);
    });

    test('reset 清空身份与槽位', () {
      final a = RpcAssembler();
      a.accept(frame(sid: 'b1', data: b64('a'), index: 0, count: 2));
      a.reset();
      expect(a.identity, isNull);
      expect(a.openSlotCount, 0);
    });

    test('多字节 UTF-8 跨分片不被截断', () {
      final a = RpcAssembler();
      const text = '中文跨分片测试';
      final bytes = utf8.encode(text);
      final mid = bytes.length ~/ 2;
      final p1 = base64Url.encode(bytes.sublist(0, mid)).replaceAll('=', '');
      final p2 = base64Url.encode(bytes.sublist(mid)).replaceAll('=', '');
      a.accept(frame(data: p1, index: 0, count: 2));
      final out = a.accept(frame(data: p2, index: 1, count: 2));
      expect((out as AssemblyMessage).text, text);
    });
  });
}

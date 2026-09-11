import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/relay/agent_rpc.dart';
import 'package:zremote/relay/relay_bridge.dart';
import 'package:zremote/relay/relay_channel.dart';
import 'package:zremote/relay/relay_link.dart';
import 'package:zremote/relay/relay_payloads.dart';
import 'package:zremote/relay/relay_socket.dart';

RelayLink link() => RelayLink.parse(
  'https://zcode.z.ai/remote/v4?remoteControlToken=tok'
  '&relayOrigin=https://relay.test&deviceSid=dev-1'
  '&passHash=hash-1&deviceMid=mid-1&appVersion=3.11.2',
)!;

String b64(String text) =>
    base64Url.encode(utf8.encode(text)).replaceAll('=', '');

/// 解出上行消息；若是 data 外壳则返回里面的 payload（模拟服务端视角）。
Map<String, dynamic> decode(String raw) {
  final m = jsonDecode(raw) as Map<String, dynamic>;
  if (m['type'] == 'data' && m['payload'] is Map) {
    return Map<String, dynamic>.from(m['payload'] as Map);
  }
  return m;
}

/// 组装一条 data 信封。
Map<String, dynamic> dataEnv(Map<String, dynamic> payload) => {
  'type': 'data',
  'payload': payload,
};

Uint8List responseBytes(
  Object? value, {
  int type = AgentResponseType.ok,
  int seq = 1,
}) {
  final out = BytesBuilder(copy: false)
    ..addByte(0x04)
    ..addByte(0x02)
    ..addByte(0x06)
    ..addByte(type)
    ..addByte(0x01)
    ..addByte(0x06);
  AgentRpcCodec.writeVarint(out, seq);
  out.addByte(0x05);
  final json = utf8.encode(jsonEncode(value));
  AgentRpcCodec.writeVarint(out, json.length);
  out.add(json);
  return out.toBytes();
}

Map<String, dynamic> rpcFrameEnv(
  Uint8List bytes, {
  required String bridgeSessionId,
  int messageSeq = 99,
}) => dataEnv({
  'zcode_type': 'rpc-frame',
  'bridgeSessionId': bridgeSessionId,
  'messageSeq': messageSeq,
  'fragmentIndex': 0,
  'fragmentCount': 1,
  'dataBase64': base64Url.encode(bytes).replaceAll('=', ''),
});

/// 一条单分片 rpc-frame，内容为给定 JSON 文本。
Map<String, dynamic> frameEnv(String jsonText, {int? seq}) => dataEnv({
  'zcode_type': 'rpc-frame',
  'bridgeSessionId': 'b-auto',
  'fragmentIndex': 0,
  'fragmentCount': 1,
  'dataBase64': b64(jsonText),
  'seq': ?seq,
});

/// 脚本化应答：模拟服务端按顺序回包。
class ScriptedRelay {
  ScriptedRelay(this.socket);

  final FakeRelaySocket socket;
  final List<String> received = [];
  String? bridgeSessionId;

  /// 挂上应答逻辑。
  void attach() {
    socket.onSend = _onSend;
  }

  void _onSend(String raw) {
    final p = decode(raw);
    received.add(p['type'] as String? ?? p['zcode_type'] as String? ?? '?');

    if (p['type'] == 'auth_init') {
      socket.emitJson({
        'type': 'auth_challenge',
        'payload': {'nonce': 'n-1'},
      });
      return;
    }
    if (p['type'] == 'auth_response') {
      socket.emitJson({'type': 'auth_ack'});
      return;
    }
    if (p['zcode_type'] == ZcodeType.workspaceListRequest) {
      socket.emitJson(
        dataEnv({
          'zcode_type': ZcodeType.workspaceListResponse,
          'requestId': p['requestId'],
          'result': {
            'workspaces': [
              {'workspaceKey': 'w1', 'path': '/proj', 'name': 'Proj'},
            ],
            'mobileViewState': {'activeWorkspaceKey': 'w1'},
          },
        }),
      );
      return;
    }
    if (p['zcode_type'] == ZcodeType.bridgeOpen) {
      bridgeSessionId = p['bridgeSessionId'] as String?;
      socket.emitJson(
        dataEnv({
          'zcode_type': ZcodeType.bridgeReady,
          'requestId': p['requestId'],
          'bridgeSessionId': bridgeSessionId,
        }),
      );
      return;
    }
  }

  /// 推一条业务帧（用真实桥 id，保证身份校验通过）。
  void pushPayload(Map<String, dynamic> payload, {int? seq}) {
    final env = frameEnv(jsonEncode(payload), seq: seq);
    (env['payload'] as Map)['bridgeSessionId'] = bridgeSessionId ?? 'b-auto';
    socket.emitJson(env);
  }
}

void main() {
  group('RelayBridge 全流程', () {
    test('握手 → 取工作区 → 开桥 → 收到业务负载', () async {
      final socket = FakeRelaySocket();
      final script = ScriptedRelay(socket)..attach();
      final bridge = RelayBridge(
        link: link(),
        socketFactory: FakeRelaySocketFactory(socket: socket),
      );

      final payloads = <String>[];
      bridge.payloads.listen(payloads.add);

      await bridge.start();

      // 上行顺序：auth_init → auth_response → workspace-list-request → bridge-open
      // （之后还会异步发一条 platform-request 做会话层握手，故只校验前四条）
      expect(script.received.take(4), [
        'auth_init',
        'auth_response',
        ZcodeType.workspaceListRequest,
        ZcodeType.bridgeOpen,
      ]);
      expect(bridge.isReady, isTrue);
      expect(bridge.workspace!.workspaceKey, 'w1');
      expect(bridge.bridgeSessionId, isNotNull);

      // 推一条 sessionIndex 形状的业务负载
      script.pushPayload({
        'op': 'sessionIndex',
        'sessions': [
          {'sessionId': 's1', 'title': 'T', 'phase': 'running'},
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(payloads, hasLength(1));
      expect(RelayBridge.asMap(payloads.first)!['op'], 'sessionIndex');
      expect(bridge.assembledCount, 1);

      await bridge.stop();
      bridge.dispose();
    });

    test('优先选择可建桥的工作区，跳过不可建桥的 remote', () async {
      final socket = FakeRelaySocket();
      socket.onSend = (raw) {
        final p = decode(raw);
        if (p['type'] == 'auth_init') {
          socket.emitJson({
            'type': 'auth_challenge',
            'payload': {'nonce': 'n'},
          });
        } else if (p['type'] == 'auth_response') {
          socket.emitJson({'type': 'auth_ack'});
        } else if (p['zcode_type'] == ZcodeType.workspaceListRequest) {
          socket.emitJson(
            dataEnv({
              'zcode_type': ZcodeType.workspaceListResponse,
              'requestId': p['requestId'],
              'result': {
                'workspaces': [
                  {'workspaceKey': 'w-bad', 'kind': 'remote'},
                  {'workspaceKey': 'w-good', 'path': '/x'},
                ],
              },
            }),
          );
        } else if (p['zcode_type'] == ZcodeType.bridgeOpen) {
          expect(p['workspaceKey'], 'w-good');
          socket.emitJson(
            dataEnv({
              'zcode_type': ZcodeType.bridgeReady,
              'requestId': p['requestId'],
              'bridgeSessionId': p['bridgeSessionId'],
            }),
          );
        }
      };

      final bridge = RelayBridge(
        link: link(),
        socketFactory: FakeRelaySocketFactory(socket: socket),
      );
      await bridge.start();
      expect(bridge.workspace!.workspaceKey, 'w-good');
      await bridge.stop();
      bridge.dispose();
    });

    test('preferredWorkspaceKey 命中时优先用它', () async {
      final socket = FakeRelaySocket();
      socket.onSend = (raw) {
        final p = decode(raw);
        if (p['type'] == 'auth_init') {
          socket.emitJson({
            'type': 'auth_challenge',
            'payload': {'nonce': 'n'},
          });
        } else if (p['type'] == 'auth_response') {
          socket.emitJson({'type': 'auth_ack'});
        } else if (p['zcode_type'] == ZcodeType.workspaceListRequest) {
          socket.emitJson(
            dataEnv({
              'zcode_type': ZcodeType.workspaceListResponse,
              'requestId': p['requestId'],
              'result': {
                'workspaces': [
                  {'workspaceKey': 'w1'},
                  {'workspaceKey': 'w2'},
                ],
              },
            }),
          );
        } else if (p['zcode_type'] == ZcodeType.bridgeOpen) {
          expect(p['workspaceKey'], 'w2');
          socket.emitJson(
            dataEnv({
              'zcode_type': ZcodeType.bridgeReady,
              'bridgeSessionId': p['bridgeSessionId'],
            }),
          );
        }
      };

      final bridge = RelayBridge(
        link: link(),
        socketFactory: FakeRelaySocketFactory(socket: socket),
      );
      await bridge.start(preferredWorkspaceKey: 'w2');
      expect(bridge.workspace!.workspaceKey, 'w2');
      await bridge.stop();
      bridge.dispose();
    });

    test('没有可建桥的工作区时报 workspace-closed', () async {
      final socket = FakeRelaySocket();
      socket.onSend = (raw) {
        final p = decode(raw);
        if (p['type'] == 'auth_init') {
          socket.emitJson({
            'type': 'auth_challenge',
            'payload': {'nonce': 'n'},
          });
        } else if (p['type'] == 'auth_response') {
          socket.emitJson({'type': 'auth_ack'});
        } else if (p['zcode_type'] == ZcodeType.workspaceListRequest) {
          socket.emitJson(
            dataEnv({
              'zcode_type': ZcodeType.workspaceListResponse,
              'requestId': p['requestId'],
              'result': {
                'workspaces': [
                  {'workspaceKey': 'w', 'kind': 'remote'},
                ],
              },
            }),
          );
        }
      };

      final bridge = RelayBridge(
        link: link(),
        socketFactory: FakeRelaySocketFactory(socket: socket),
      );
      final failures = <RelayFailure>[];
      bridge.failures.listen(failures.add);

      await expectLater(bridge.start(), throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);
      expect(failures.first.reason, 'workspace-closed');
      await bridge.stop();
      bridge.dispose();
    });

    test('多分片帧被正确重组成一条负载', () async {
      final socket = FakeRelaySocket();
      final script = ScriptedRelay(socket)..attach();
      final bridge = RelayBridge(
        link: link(),
        socketFactory: FakeRelaySocketFactory(socket: socket),
      );
      final payloads = <String>[];
      bridge.payloads.listen(payloads.add);
      await bridge.start();

      const text = '{"op":"split","who":"中文"}';
      final bytes = utf8.encode(text);
      final mid = bytes.length ~/ 2;
      final sid = script.bridgeSessionId!;

      for (final part in [
        (0, bytes.sublist(0, mid)),
        (1, bytes.sublist(mid)),
      ]) {
        socket.emitJson(
          dataEnv({
            'zcode_type': 'rpc-frame',
            'bridgeSessionId': sid,
            'messageSeq': 7,
            'fragmentIndex': part.$1,
            'fragmentCount': 2,
            'dataBase64': base64Url.encode(part.$2).replaceAll('=', ''),
          }),
        );
      }
      await Future<void>.delayed(Duration.zero);

      expect(payloads, hasLength(1));
      expect(payloads.first, text);
      await bridge.stop();
      bridge.dispose();
    });

    test('分片缺口通过 failures 上报，不影响后续帧', () async {
      final socket = FakeRelaySocket();
      final script = ScriptedRelay(socket)..attach();
      final bridge = RelayBridge(
        link: link(),
        socketFactory: FakeRelaySocketFactory(socket: socket),
      );
      final failures = <RelayFailure>[];
      final payloads = <String>[];
      bridge.failures.listen(failures.add);
      bridge.payloads.listen(payloads.add);
      await bridge.start();

      script.pushPayload({'op': 'a'}, seq: 1);
      script.pushPayload({'op': 'b'}, seq: 5); // 缺口
      script.pushPayload({'op': 'c'}, seq: 6);
      await Future<void>.delayed(Duration.zero);

      expect(failures.single.reason, 'rpc-frame-gap');
      // 缺口帧本身被丢弃，但后续仍能继续产出
      expect(payloads, hasLength(2));
      expect(RelayBridge.asMap(payloads.last)!['op'], 'c');
      await bridge.stop();
      bridge.dispose();
    });

    test('pushViewState 上报当前工作区与任务', () async {
      final socket = FakeRelaySocket();
      ScriptedRelay(socket).attach();
      final bridge = RelayBridge(
        link: link(),
        socketFactory: FakeRelaySocketFactory(socket: socket),
      );
      await bridge.start();

      bridge.pushViewState(taskId: 't-9');
      await Future<void>.delayed(Duration.zero);

      final sent = socket.sent.map(decode).toList();
      final vs = sent.lastWhere(
        (p) => p['zcode_type'] == ZcodeType.viewStateUpdate,
      );
      expect((vs['viewState'] as Map)['activeWorkspaceKey'], 'w1');
      expect((vs['viewState'] as Map)['activeTaskId'], 't-9');
      await bridge.stop();
      bridge.dispose();
    });

    test('asMap 对非法输入返回 null 而不抛', () {
      expect(RelayBridge.asMap('{"a":1}')!['a'], 1);
      expect(RelayBridge.asMap('nope'), isNull);
      expect(RelayBridge.asMap('[1]'), isNull);
    });

    test('start 幂等：重复调用不会二次握手', () async {
      final socket = FakeRelaySocket();
      final script = ScriptedRelay(socket)..attach();
      final bridge = RelayBridge(
        link: link(),
        socketFactory: FakeRelaySocketFactory(socket: socket),
      );
      await bridge.start();
      // 会话层握手会在开桥后异步发送 rpc-frame；这里只统计 Relay
      // 连接/工作区握手，避免把另一层协议误判成 start 重复执行。
      int relayHandshakeCount() => script.received
          .where(
            (type) =>
                type == 'auth_init' ||
                type == 'auth_response' ||
                type == ZcodeType.workspaceListRequest ||
                type == ZcodeType.bridgeOpen,
          )
          .length;

      final countAfterFirst = relayHandshakeCount();
      expect(countAfterFirst, greaterThan(0));
      await bridge.start();
      expect(relayHandshakeCount(), countAfterFirst);
      await bridge.stop();
      bridge.dispose();
    });

    test('sendConversationMessage 使用 sendText 并等待 command receipt', () async {
      final socket = FakeRelaySocket();
      final script = ScriptedRelay(socket)..attach();
      final bridge = RelayBridge(
        link: link(),
        socketFactory: FakeRelaySocketFactory(socket: socket),
      );
      await bridge.start();

      AgentRpc? sentRpc;
      final handshakeHandler = socket.onSend;
      socket.onSend = (raw) {
        handshakeHandler?.call(raw);
        final payload = decode(raw);
        if (payload['zcode_type'] != 'rpc-frame' ||
            payload['dataBase64'] is! String) {
          return;
        }
        final encoded = base64Url.decode(
          base64Url.normalize(payload['dataBase64'] as String),
        );
        final rpc = AgentRpcCodec.tryDecode(Uint8List.fromList(encoded));
        if (rpc?.method != 'sendConversationCommandV4') return;
        sentRpc = rpc;
        final scoped = rpc!.args.single as Map;
        final envelope = scoped['envelope'] is Map
            ? scoped['envelope'] as Map
            : scoped;
        socket.emitJson(
          rpcFrameEnv(
            responseBytes({
              'commandId': envelope['commandId'],
              'status': 'accepted',
              'revisionAtDecision': 12,
              'result': {
                'type': 'inputAccepted',
                'delivery': 'started',
                'inputId': 'input-1',
              },
            }),
            bridgeSessionId: script.bridgeSessionId!,
          ),
        );
      };

      final ok = await bridge.sendConversationMessage(
        sessionId: 'session-1',
        text: '请检查这个文件',
      );

      expect(ok, isTrue);
      expect(sentRpc?.service, 'zcode-agent');
      expect(sentRpc?.method, 'sendConversationCommandV4');
      final scoped = sentRpc!.args.single as Map;
      final command = scoped['envelope'] is Map
          ? scoped['envelope'] as Map
          : scoped;
      expect(command['sessionId'], 'session-1');
      expect(command['type'], 'sendText');
      expect(command['payload'], {
        'text': '请检查这个文件',
        'requestedDelivery': 'startNow',
        'heldQueueDisposition': 'keepQueueAndSend',
      });

      await bridge.stop();
      bridge.dispose();
    });
  });
}

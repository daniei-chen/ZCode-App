import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/relay/relay_monitor.dart';

/// 与 relay_monitor_test 的 FakeSocket 同形（独立副本避免跨文件耦合）。
class FakeSocket implements RelaySocket {
  FakeSocket(this.failConnect);

  final bool failConnect;
  final sent = <String>[];
  final connectUrls = <String>[];
  final _messages = StreamController<String>.broadcast();
  bool closed = false;

  void serverSends(String text) => _messages.add(text);

  @override
  Future<void> connect(Uri uri, Duration timeout) async {
    connectUrls.add(uri.toString());
    if (failConnect) throw StateError('offline');
  }

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Future<void> send(String text) async => sent.add(text);

  @override
  Future<void> close() async {
    closed = true;
    await _messages.close();
  }
}

/// 桌面端 rpc 响应体：`04 02 06 C9 01 06 <seq> 05 <len> <json>`。
Uint8List rpcResponse(Object json) {
  final jsonBytes = utf8.encode(jsonEncode(json));
  final out = BytesBuilder();
  out.addByte(0x04);
  out.addByte(0x02);
  out.addByte(0x06);
  out.addByte(0xC9);
  out.addByte(0x01);
  out.addByte(0x06);
  out.addByte(0x2A);
  out.addByte(0x05);
  var len = jsonBytes.length;
  while (true) {
    if (len < 0x80) {
      out.addByte(len);
      break;
    }
    out.addByte((len & 0x7F) | 0x80);
    len >>= 7;
  }
  out.add(jsonBytes);
  return out.toBytes();
}

String rpcFrameDown(Map<dynamic, dynamic> payload) => jsonEncode({
  'type': 'data',
  'payload': payload,
  'client_ts': 1792972706,
});

Map<dynamic, dynamic> rpcFrameUp(String dataBase64, int messageSeq) => {
  'zcode_type': 'rpc-frame',
  'bridgeSessionId': 'bs',
  'bridgeGeneration': 1,
  'messageSeq': messageSeq,
  'dataBase64': dataBase64,
};

Map<dynamic, dynamic>? sentPayloadOfType(FakeSocket socket, String type) {
  for (final text in socket.sent.reversed) {
    final message = jsonDecode(text);
    if (message is Map && message['type'] == 'data') {
      final payload = message['payload'];
      if (payload is Map && payload['zcode_type'] == type) return payload;
    }
  }
  return null;
}

int? sentMessageSeq(FakeSocket socket) {
  for (final text in socket.sent.reversed) {
    final message = jsonDecode(text);
    if (message is Map && message['type'] == 'data') {
      final payload = message['payload'];
      if (payload is Map && payload['zcode_type'] == 'rpc-frame') {
        final seq = payload['messageSeq'];
        if (seq is int) return seq;
      }
    }
  }
  return null;
}

void main() {
  test('agent 层并入监控连接：单 socket 走完引导链并就绪，命令同 socket 提交', () {
    fakeAsync((async) {
      final sockets = <FakeSocket>[];
      final readyStates = <bool>[];
      final events = <Map<dynamic, dynamic>>[];
      final connection = RelayMonitorConnection(
        deviceId: 'dev12345678',
        deviceSid: 'd_ABC',
        deviceMid: 'mid-1234',
        appVersion: '3.16.3',
        tokenProvider: () async => 'jwt-token-1',
        relayTokenExchange: (jwt) async => 'relay-from-$jwt',
        socketFactory: () {
          final socket = FakeSocket(false);
          sockets.add(socket);
          return socket;
        },
        onState: (_, _) {},
        onSnapshot: (_, _) {},
        onAgentEvent: (_, event) => events.add(event),
        onAgentReady: (_, ready) => readyStates.add(ready),
      );
      unawaited(connection.start());
      async.elapse(const Duration(milliseconds: 10));
      expect(sockets, hasLength(1));
      sockets.first.serverSends(
        '{"type":"auth_ack","device_sid":"d_ABC","pair_status":"matched"}',
      );
      async.elapse(const Duration(milliseconds: 10));

      // 引导第 1 步：workspace-list-request 走监控同一条 socket。
      expect(sentPayloadOfType(sockets.first, 'workspace-list-request'),
          isNotNull);
      // 真实形状（v1.8.5）：activeWorkspaceKey 在 payload.result 里，
      // 不在 payload 顶层。
      sockets.first.serverSends(
        jsonEncode({
          'type': 'data',
          'payload': {
            'zcode_type': 'workspace-list-response',
            'requestId': 'agent-1',
            'result': {
              'activeWorkspaceKey': 'ws-key',
              'tasks': <Object>[],
            },
          },
          'client_ts': 1792972706,
        }),
      );
      async.elapse(const Duration(milliseconds: 10));

      // 第 2 步：开桥。客户端自生成 bridgeSessionId（官方接受）。
      final bridgeOpen = sentPayloadOfType(
        sockets.first,
        'workspace-bridge-open',
      );
      expect(bridgeOpen, isNotNull);
      final bridgeSessionId = '${bridgeOpen!['bridgeSessionId']}';
      expect(bridgeSessionId, isNotEmpty);
      // 只回 bridgeSessionId，不回 requestId——官方匹配谓词就是这个
      // （v1.8.5 修：旧代码只认 requestId，这种响应会被丢弃）。
      sockets.first.serverSends(
        jsonEncode({
          'type': 'data',
          'payload': {
            'zcode_type': 'workspace-bridge-ready',
            'bridgeSessionId': bridgeSessionId,
          },
          'client_ts': 1792972706,
        }),
      );
      async.elapse(const Duration(milliseconds: 10));

      // 第 3-5 步：hello → initialize → subscribe，rpc 响应按内容匹配。
      final helloSeq = sentMessageSeq(sockets.first);
      expect(helloSeq, isNotNull);
      sockets.first.serverSends(
        rpcFrameDown({
          ...rpcFrameUp(
            base64Encode(rpcResponse({
              'clientMode': 'web-remote-replayable',
              'connectionId': 'c-1',
            })),
            helloSeq! + 100,
          ),
          'bridgeSessionId': bridgeSessionId,
        }),
      );
      async.elapse(const Duration(milliseconds: 10));
      final initSeq = sentMessageSeq(sockets.first);
      expect(initSeq, isNotNull);
      expect(initSeq, isNot(helloSeq));
      sockets.first.serverSends(
        rpcFrameDown({
          ...rpcFrameUp(
            base64Encode(rpcResponse({'capabilities': {}, 'ok': true})),
            initSeq! + 100,
          ),
          'bridgeSessionId': bridgeSessionId,
        }),
      );
      async.elapse(const Duration(milliseconds: 10));
      final subSeq = sentMessageSeq(sockets.first);
      expect(subSeq, isNotNull);
      sockets.first.serverSends(
        rpcFrameDown({
          ...rpcFrameUp(
            base64Encode(rpcResponse({'ack': {'ok': true}})),
            subSeq! + 100,
          ),
          'bridgeSessionId': bridgeSessionId,
        }),
      );
      async.elapse(const Duration(milliseconds: 10));

      // 就绪：命令通道可用（诊断"命令通道"口径），且全程只有一条 socket。
      expect(connection.agentReady, isTrue);
      expect(readyStates, contains(true));
      expect(sockets, hasLength(1));

      // 订阅推送事件：非 pending 匹配的 rpc 载荷进 onEvent。
      sockets.first.serverSends(
        rpcFrameDown({
          ...rpcFrameUp(
            base64Encode(rpcResponse({
              'pendingInteractions': <Object>[],
            })),
            999,
          ),
          'bridgeSessionId': bridgeSessionId,
        }),
      );
      async.elapse(const Duration(milliseconds: 10));
      expect(events, hasLength(1));

      // 命令提交走同一条 socket，accepted 即成功。
      final submitDone = connection.submitAgentCommand({
        'commandId': 'cmd-1',
        'type': 'resolve',
      });
      async.elapse(const Duration(milliseconds: 10));
      final cmdSeq = sentMessageSeq(sockets.first);
      expect(cmdSeq, isNotNull);
      sockets.first.serverSends(
        rpcFrameDown({
          ...rpcFrameUp(
            base64Encode(rpcResponse({'commandId': 'cmd-1', 'status': 'accepted'})),
            cmdSeq! + 100,
          ),
          'bridgeSessionId': bridgeSessionId,
        }),
      );
      async.elapse(const Duration(milliseconds: 10));
      expect(submitDone, completion(isTrue));

      // 被踢让路：agent 层随连接复位（就绪态回落），仍只有一条 socket。
      sockets.first.serverSends('{"type":"error","code":"KICKED"}');
      async.elapse(const Duration(milliseconds: 10));
      expect(connection.agentReady, isFalse);
      expect(sockets, hasLength(1));
    });
  });

  test('未启用 agent 层（onAgentEvent 为空）：行为与 v1.7.0 前一致', () {
    fakeAsync((async) {
      final sockets = <FakeSocket>[];
      final connection = RelayMonitorConnection(
        deviceId: 'dev12345678',
        deviceSid: 'd_ABC',
        deviceMid: 'mid-1234',
        appVersion: '3.16.3',
        tokenProvider: () async => 'jwt-token-1',
        relayTokenExchange: (jwt) async => 'relay-from-$jwt',
        socketFactory: () {
          final socket = FakeSocket(false);
          sockets.add(socket);
          return socket;
        },
        onState: (_, _) {},
      );
      unawaited(connection.start());
      async.elapse(const Duration(milliseconds: 10));
      sockets.first.serverSends(
        '{"type":"auth_ack","device_sid":"d_ABC","pair_status":"matched"}',
      );
      async.elapse(const Duration(milliseconds: 10));
      expect(connection.agentReady, isFalse);
      // 不发 agent 引导请求：仅有监控自己的快照轮询（requestId monitor-N）。
      for (final text in sockets.first.sent) {
        final message = jsonDecode(text);
        if (message is! Map || message['type'] != 'data') continue;
        final payload = message['payload'];
        if (payload is Map &&
            payload['zcode_type'] == 'workspace-list-request') {
          expect('${payload['requestId']}', startsWith('monitor-'));
        }
      }
    });
  });

  test('引导失败后自动重试（v1.8.5：不让 agent 永久 down）', () {
    fakeAsync((async) {
      final sockets = <FakeSocket>[];
      final readyStates = <bool>[];
      final connection = RelayMonitorConnection(
        deviceId: 'dev12345678',
        deviceSid: 'd_ABC',
        deviceMid: 'mid-1',
        appVersion: '3.16.3',
        tokenProvider: () async => 'jwt',
        relayTokenExchange: (jwt) async => 'relay',
        socketFactory: () {
          final socket = FakeSocket(false);
          sockets.add(socket);
          return socket;
        },
        onState: (_, _) {},
        onAgentEvent: (_, _) {},
        onAgentReady: (_, ready) => readyStates.add(ready),
      );
      unawaited(connection.start());
      async.elapse(const Duration(milliseconds: 10));
      sockets.first.serverSends(
        '{"type":"auth_ack","device_sid":"d_ABC","pair_status":"matched"}',
      );
      async.elapse(const Duration(milliseconds: 10));

      // 故意不回 workspace-list-response → 引导链超时失败。
      final firstRequestCount = sockets.first.sent
          .where((t) => t.contains('workspace-list-request'))
          .length;
      expect(firstRequestCount, greaterThanOrEqualTo(1));

      // 10s 请求超时 + 5s 重试间隔后，应再次发起引导（证明有重试）。
      async.elapse(const Duration(seconds: 20));
      final laterCount = sockets.first.sent
          .where((t) => t.contains('workspace-list-request'))
          .length;
      expect(
        laterCount,
        greaterThan(firstRequestCount),
        reason: '引导失败后必须自动重试，否则 agent 永远 down',
      );
      expect(connection.agentReady, isFalse);
    });
  });
}

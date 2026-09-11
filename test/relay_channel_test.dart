import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/relay/relay_channel.dart';
import 'package:zremote/relay/relay_link.dart';
import 'package:zremote/relay/relay_payloads.dart';
import 'package:zremote/relay/relay_proof.dart';
import 'package:zremote/relay/relay_socket.dart';

const _link =
    'https://zcode.z.ai/remote/v4?remoteControlToken=tok'
    '&relayOrigin=https://relay.test&deviceSid=dev-1'
    '&passHash=hash-1&deviceMid=mid-1&appVersion=3.11.2';

RelayLink link() => RelayLink.parse(_link)!;

/// 把收到的上行按序解析出来（测试助手）。
List<Map<String, dynamic>> sentPayloads(FakeRelaySocket s) =>
    s.sent.map((e) => jsonDecode(e) as Map<String, dynamic>).toList();

void main() {
  group('RelayChannel 握手', () {
    test('连接地址带 mid，且首条上行是 auth_init(role=terminal)', () async {
      final socket = FakeRelaySocket();
      final factory = FakeRelaySocketFactory(socket: socket);
      final ch = RelayChannel(link: link(), socketFactory: factory);

      final done = ch.connect();
      await Future<void>.delayed(Duration.zero);

      expect(factory.connected, hasLength(1));
      expect(
        factory.connected.first.toString(),
        'wss://relay.test/ws?mid=mid-1',
      );

      final first = sentPayloads(socket).first;
      expect(first['type'], 'auth_init');
      expect(first['role'], 'terminal');
      expect(first['device_sid'], 'dev-1');
      expect((first['meta'] as Map)['version'], '3.11.2');
      expect((first['meta'] as Map)['name'], ClientKind.mobileApp);
      expect(first['client_ts'], isA<int>());

      // 收尾
      socket.emitJson({'type': 'auth_ack'});
      await done;
      await ch.close();
      ch.dispose();
    });

    test('auth_challenge 用 terminal 角色算 proof 并回传', () async {
      final socket = FakeRelaySocket();
      final ch = RelayChannel(
        link: link(),
        socketFactory: FakeRelaySocketFactory(socket: socket),
      );

      final done = ch.connect();
      await Future<void>.delayed(Duration.zero);
      socket.emitJson({
        'type': 'auth_challenge',
        'payload': {'nonce': 'n-42'},
      });
      await Future<void>.delayed(Duration.zero);

      final sent = sentPayloads(socket);
      final resp = sent.firstWhere((p) => p['type'] == 'auth_response');
      expect(resp['device_sid'], 'dev-1');
      expect(
        resp['proof'],
        RelayProof.calculate(
          passHash: 'hash-1',
          nonce: 'n-42',
          role: RelayProof.roleTerminal,
          deviceSid: 'dev-1',
        ),
      );
      expect(ch.authRounds, 1);

      socket.emitJson({'type': 'auth_ack'});
      await done;
      await ch.close();
      ch.dispose();
    });

    test('auth_ack 后进入 ready 并开始心跳', () async {
      final socket = FakeRelaySocket();
      final ch = RelayChannel(
        link: link(),
        socketFactory: FakeRelaySocketFactory(socket: socket),
        heartbeatInterval: const Duration(milliseconds: 30),
        heartbeatJitter: Duration.zero,
      );

      final done = ch.connect();
      await Future<void>.delayed(Duration.zero);
      expect(ch.phase, RelayPhase.authenticating);

      socket.emitJson({'type': 'auth_ack'});
      await done;
      expect(ch.phase, RelayPhase.ready);
      expect(ch.isReady, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 90));
      final beats = sentPayloads(
        socket,
      ).where((p) => p['type'] == 'pair_status_query').length;
      expect(beats, greaterThanOrEqualTo(1));

      await ch.close();
      ch.dispose();
    });

    test('pair_status_ack 也能结束握手', () async {
      final socket = FakeRelaySocket();
      final ch = RelayChannel(
        link: link(),
        socketFactory: FakeRelaySocketFactory(socket: socket),
      );
      final done = ch.connect();
      await Future<void>.delayed(Duration.zero);
      socket.emitJson({
        'type': 'pair_status_ack',
        'payload': {'pair_status': 'paired'},
      });
      await done;
      expect(ch.phase, RelayPhase.ready);
      await ch.close();
      ch.dispose();
    });

    test('缺 nonce 的 challenge 视为失败', () async {
      final socket = FakeRelaySocket();
      final ch = RelayChannel(
        link: link(),
        socketFactory: FakeRelaySocketFactory(socket: socket),
      );
      final failures = <RelayFailure>[];
      ch.failures.listen(failures.add);

      final done = ch.connect();
      await Future<void>.delayed(Duration.zero);
      socket.emitJson({'type': 'auth_challenge', 'payload': {}});

      await expectLater(done, throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);
      expect(failures.first.reason, 'unexpected-error');
      await ch.close();
      ch.dispose();
    });

    test('服务端 error 信封转成 RelayFailure', () async {
      final socket = FakeRelaySocket();
      final ch = RelayChannel(
        link: link(),
        socketFactory: FakeRelaySocketFactory(socket: socket),
      );
      final failures = <RelayFailure>[];
      ch.failures.listen(failures.add);

      final done = ch.connect();
      await Future<void>.delayed(Duration.zero);
      socket.emitJson({
        'type': 'error',
        'payload': {'code': 'session-conflict', 'message': 'occupied'},
      });

      await expectLater(done, throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);
      expect(failures.first.reason, 'session-conflict');
      expect(failures.first.isTerminal, isTrue);
      await ch.close();
      ch.dispose();
    });

    test('无 deviceMid 时不带 mid 参数', () async {
      final l = RelayLink.parse(
        'https://zcode.z.ai/remote/v4?remoteControlToken=t'
        '&relayOrigin=https://relay.test&deviceSid=d&passHash=p',
      )!;
      final factory = FakeRelaySocketFactory(socket: FakeRelaySocket());
      final ch = RelayChannel(link: l, socketFactory: factory);
      final done = ch.connect();
      await Future<void>.delayed(Duration.zero);
      expect(factory.connected.first.toString(), 'wss://relay.test/ws');
      factory.socket!.emitJson({'type': 'auth_ack'});
      await done;
      await ch.close();
      ch.dispose();
    });

    test('缺 deviceSid/passHash 时握手直接失败', () async {
      final l = RelayLink.parse(
        'https://zcode.z.ai/remote/v4?remoteControlToken=t'
        '&relayOrigin=https://relay.test',
      )!;
      final socket = FakeRelaySocket();
      final ch = RelayChannel(
        link: l,
        socketFactory: FakeRelaySocketFactory(socket: socket),
      );
      final done = ch.connect();
      await Future<void>.delayed(Duration.zero);
      socket.emitJson({
        'type': 'auth_challenge',
        'payload': {'nonce': 'n'},
      });

      await expectLater(done, throwsA(isA<StateError>()));
      await ch.close();
      ch.dispose();
    });
  });

  group('RelayChannel 下行分发', () {
    Future<RelayChannel> ready(
      FakeRelaySocket socket, {
      List<RelayDownlink>? sink,
      List<RelayFailure>? failures,
    }) async {
      final ch = RelayChannel(
        link: link(),
        socketFactory: FakeRelaySocketFactory(socket: socket),
      );
      if (sink != null) ch.downlinks.listen(sink.add);
      if (failures != null) ch.failures.listen(failures.add);
      final done = ch.connect();
      await Future<void>.delayed(Duration.zero);
      socket.emitJson({'type': 'auth_ack'});
      await done;
      return ch;
    }

    test('rpc-frame 被标记为帧并透传，且自动回 ack', () async {
      final socket = FakeRelaySocket();
      final got = <RelayDownlink>[];
      final ch = await ready(socket, sink: got);

      socket.emitJson({
        'type': 'data',
        'payload': {
          'zcode_type': 'rpc-frame',
          'bridgeSessionId': 'b1',
          'bridgeGeneration': 2,
          'seq': 4,
          'fragmentIndex': 0,
          'fragmentCount': 1,
          'dataBase64': 'e30',
        },
      });
      await Future<void>.delayed(Duration.zero);

      expect(got, hasLength(1));
      expect(got.first.isFrame, isTrue);
      expect(ch.framesIn, 1);
      expect(ch.acksOut, 1);

      // ack 必须是 data 外壳 + rpc-frame-ack + 正确 identity 与 ackMessageSeq
      final ack = sentPayloads(socket).last;
      expect(ack['type'], 'data');
      final body = ack['payload'] as Map;
      expect(body['zcode_type'], 'rpc-frame-ack');
      expect(body['bridgeSessionId'], 'b1');
      expect(body['bridgeGeneration'], 2);
      expect(body['ackMessageSeq'], 4);

      await ch.close();
      ch.dispose();
    });

    test('rpc-frame-ack 不会再被回 ack（避免死循环）', () async {
      final socket = FakeRelaySocket();
      final ch = await ready(socket);
      socket.emitJson({
        'type': 'data',
        'payload': {
          'zcode_type': 'rpc-frame-ack',
          'bridgeSessionId': 'b1',
          'ackMessageSeq': 9,
        },
      });
      await Future<void>.delayed(Duration.zero);
      expect(ch.acksOut, 0);
      await ch.close();
      ch.dispose();
    });

    test('缺 messageSeq 的帧不回 ack 也不崩', () async {
      final socket = FakeRelaySocket();
      final ch = await ready(socket);
      socket.emitJson({
        'type': 'data',
        'payload': {
          'zcode_type': 'rpc-frame',
          'bridgeSessionId': 'b1',
          'fragmentIndex': 0,
          'fragmentCount': 1,
          'dataBase64': 'e30',
        },
      });
      await Future<void>.delayed(Duration.zero);
      expect(ch.acksOut, 0);
      await ch.close();
      ch.dispose();
    });

    test('workspace-list-request 走 data 外壳（官方封装约定）', () async {
      final socket = FakeRelaySocket();
      final ch = await ready(socket);
      final fut = ch.request({
        'zcode_type': ZcodeType.workspaceListRequest,
        'requestId': 'r1',
      });
      await Future<void>.delayed(Duration.zero);

      final raw = socket.sent.last;
      final outer = jsonDecode(raw) as Map<String, dynamic>;
      expect(outer['type'], 'data');
      expect(outer['client_ts'], isA<int>());
      expect(
        (outer['payload'] as Map)['zcode_type'],
        ZcodeType.workspaceListRequest,
      );

      socket.emitJson({
        'type': 'data',
        'payload': {
          'zcode_type': ZcodeType.workspaceListResponse,
          'requestId': 'r1',
          'result': {'workspaces': []},
        },
      });
      await fut;
      await ch.close();
      ch.dispose();
    });

    test('workspace-list-updated 被透传为非帧负载', () async {
      final socket = FakeRelaySocket();
      final got = <RelayDownlink>[];
      final ch = await ready(socket, sink: got);

      socket.emitJson({
        'type': 'data',
        'payload': {
          'zcode_type': 'workspace-list-updated',
          'result': {
            'workspaces': [
              {'workspaceKey': 'w1', 'path': '/tmp/a'},
            ],
          },
        },
      });
      await Future<void>.delayed(Duration.zero);

      expect(got, hasLength(1));
      expect(got.first.isFrame, isFalse);
      expect(got.first.zcodeType, 'workspace-list-updated');
      await ch.close();
      ch.dispose();
    });

    test('workspace-bridge-ready 按 requestId 完成 RPC', () async {
      final socket = FakeRelaySocket();
      final ch = await ready(socket);

      final fut = ch.request({
        'zcode_type': ZcodeType.bridgeOpen,
        'requestId': 'req-1',
        'bridgeSessionId': 'b1',
        'bridgeGeneration': 1,
        'workspaceKey': 'w1',
      });
      await Future<void>.delayed(Duration.zero);

      socket.emitJson({
        'type': 'data',
        'payload': {
          'zcode_type': ZcodeType.bridgeReady,
          'requestId': 'req-1',
          'bridgeSessionId': 'b1',
        },
      });

      final res = await fut;
      expect(res['zcode_type'], ZcodeType.bridgeReady);
      await ch.close();
      ch.dispose();
    });

    test('request 缺少 requestId 直接报错', () async {
      final socket = FakeRelaySocket();
      final ch = await ready(socket);
      expect(
        () => ch.request({'zcode_type': 'x'}),
        throwsA(isA<ArgumentError>()),
      );
      await ch.close();
      ch.dispose();
    });

    test('bridge-degraded 进入 degraded 并给出原因', () async {
      final socket = FakeRelaySocket();
      final failures = <RelayFailure>[];
      final ch = await ready(socket, failures: failures);
      ch.bridgeSessionId = 'b1';

      socket.emitJson({
        'type': 'data',
        'payload': {
          'zcode_type': ZcodeType.bridgeDegraded,
          'bridgeSessionId': 'b1',
          'reason': 'rpc-frame-gap',
        },
      });
      await Future<void>.delayed(Duration.zero);

      expect(ch.phase, RelayPhase.degraded);
      expect(failures.last.reason, 'rpc-frame-gap');
      await ch.close();
      ch.dispose();
    });

    test('其他桥的 degraded 通知被忽略', () async {
      final socket = FakeRelaySocket();
      final failures = <RelayFailure>[];
      final ch = await ready(socket, failures: failures);
      ch.bridgeSessionId = 'b-current';

      socket.emitJson({
        'type': 'data',
        'payload': {
          'zcode_type': ZcodeType.bridgeDegraded,
          'bridgeSessionId': 'b-old',
          'reason': 'rpc-frame-gap',
        },
      });
      await Future<void>.delayed(Duration.zero);

      expect(ch.phase, RelayPhase.ready);
      expect(failures, isEmpty);
      await ch.close();
      ch.dispose();
    });

    test('非法 JSON 与形状不符的消息被静默丢弃', () async {
      final socket = FakeRelaySocket();
      final got = <RelayDownlink>[];
      final ch = await ready(socket, sink: got);

      socket.emit('not json');
      socket.emitJson({'type': 'data'});
      socket.emitJson({
        'type': 'data',
        'payload': {'no_type': 1},
      });
      socket.emitJson({'unknown': true});
      await Future<void>.delayed(Duration.zero);

      expect(got, isEmpty);
      expect(ch.framesIn, 0);
      await ch.close();
      ch.dispose();
    });

    test('连接失败会抛出且不影响后续状态', () async {
      final factory = FakeRelaySocketFactory(error: StateError('refused'));
      final ch = RelayChannel(link: link(), socketFactory: factory);
      await expectLater(ch.connect(), throwsA(isA<StateError>()));
      await ch.close();
      ch.dispose();
    });

    test('close 会拒绝未完成的 RPC，避免调用方永久挂起', () async {
      final socket = FakeRelaySocket();
      final ch = await ready(socket);
      final fut = ch.request({
        'zcode_type': ZcodeType.workspaceListRequest,
        'requestId': 'r-pending',
      });
      await ch.close();
      await expectLater(fut, throwsA(isA<Object>()));
      ch.dispose();
    });
  });

  group('RelayUplink 构造', () {
    test('viewStateUpdate 省略空 taskId', () {
      final a = RelayUplink.viewStateUpdate(
        activeWorkspaceKey: 'w1',
        updatedAt: 5,
      );
      expect((a['viewState'] as Map).containsKey('activeTaskId'), isFalse);
      final b = RelayUplink.viewStateUpdate(
        activeWorkspaceKey: 'w1',
        activeTaskId: 't1',
        updatedAt: 5,
      );
      expect((b['viewState'] as Map)['activeTaskId'], 't1');
    });

    test('bridgeOpen 省略空 taskId 与 0 世代', () {
      final p = RelayUplink.bridgeOpen(
        requestId: 'r',
        bridgeSessionId: 'b',
        bridgeGeneration: 0,
        workspaceKey: 'w',
      );
      expect(p.containsKey('taskId'), isFalse);
      expect(p.containsKey('bridgeGeneration'), isFalse);
    });

    test('platformRequest 形状（实测页面用法）', () {
      final p = RelayUplink.platformRequest(
        requestId: 'platform-1',
        method: ConversationMethod.hello,
      );
      expect(p['zcode_type'], 'platform-request');
      expect(p['requestId'], 'platform-1');
      expect(p['method'], 'helloConversationV4');
      expect(p['args'], isEmpty);
    });

    test('clientHello 不声明 binaryFrames', () {
      final p = RelayUplink.clientHello(clientId: 'zr-1', appVersion: '3.11.2');
      expect(p['kind'], 'clientHello');
      expect(p['protocolVersion'], 3);
      expect(p['clientKind'], ClientKind.mobileApp);
      final caps = p['capabilities'] as Map;
      // 关键：不声明二进制帧，才会拿到可被 JSON 解析的帧
      expect(caps.containsKey('binaryFrames'), isFalse);
      expect(caps['workspaceHookReviewUi'], isTrue);
    });

    test('subscribe 不带 base 时不含该字段', () {
      final p = RelayUplink.subscribe(topic: 'conversation/s1');
      expect(p['topic'], 'conversation/s1');
      expect(p['visibility'], 'foreground');
      expect(p.containsKey('base'), isFalse);
    });

    test('subscribe 带 base 时写入 logEpoch / seq', () {
      final p = RelayUplink.subscribe(
        topic: 'conversation/s1',
        logEpoch: 'e1',
        seq: 7,
      );
      final base = p['base'] as Map;
      expect(base['logEpoch'], 'e1');
      expect(base['seq'], 7);
    });
  });

  group('RelayTopic', () {
    test('会话主题拼接与解析往返', () {
      final t = RelayTopic.conversation('sess_abc');
      expect(t, 'conversation/sess_abc');
      expect(RelayTopic.sessionIdOf(t), 'sess_abc');
    });

    test('非会话主题返回 null', () {
      expect(RelayTopic.sessionIdOf('sessions-index/x'), isNull);
      expect(RelayTopic.sessionIdOf('conversation/'), isNull);
    });

    test('sessions-index 主题', () {
      expect(RelayTopic.sessionsIndex('ws-1'), 'sessions-index/ws-1');
    });
  });

  group('RelayWorkspace / RelayBootstrap 解析', () {
    test('解析工作区列表', () {
      final b = RelayBootstrap.tryParse({
        'workspaces': [
          {'workspaceKey': 'w1', 'path': '/a', 'name': 'A'},
          {'workspaceKey': 'w2', 'kind': 'remote'},
        ],
        'mobileViewState': {'activeWorkspaceKey': 'w1', 'activeTaskId': 't9'},
      });
      expect(b, isNotNull);
      expect(b!.workspaces, hasLength(2));
      expect(b.workspaces.first.path, '/a');
      expect(b.viewState!.activeTaskId, 't9');
      // remote 且缺 identity 时不允许建桥
      expect(b.workspaces[1].canBridge, isFalse);
      expect(b.workspaces.first.canBridge, isTrue);
    });

    test('形状不符返回 null 或空列表', () {
      expect(RelayBootstrap.tryParse(null), isNull);
      expect(RelayBootstrap.tryParse({'nothing': 1}), isNull);
      expect(RelayWorkspace.parseList('nope'), isEmpty);
      expect(RelayWorkspace.tryParse({'noKey': 1}), isNull);
    });

    test('remote 工作区带 identity+sessionId 时允许建桥', () {
      final w = RelayWorkspace.tryParse({
        'workspaceKey': 'w',
        'kind': 'remote',
        'workspaceIdentity': 'id-1',
        'remoteSessionId': 'rs-1',
      })!;
      expect(w.canBridge, isTrue);
    });
  });
}

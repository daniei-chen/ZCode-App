import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:zremote/relay/relay_monitor.dart';

class FakeSocket implements RelaySocket {
  FakeSocket(this.failConnect);

  final bool failConnect;
  final sent = <String>[];
  final connectUrls = <String>[];
  final _messages = StreamController<String>.broadcast();
  bool closed = false;

  /// 测试脚本用：模拟服务端下行。
  void serverSends(String text) => _messages.add(text);

  void serverError() => _messages.addError(StateError('boom'));

  @override
  Future<void> connect(Uri uri, Duration timeout) async {
    connectUrls.add(uri.toString());
    if (failConnect) throw const SocketException('offline');
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

void main() {
  test('auth_init 报文形状（V2：无 role、无 proof，client_ts 秒）', () {
    final message = RelayMonitorPolicy.authInitMessage(
      deviceSid: 'd_ABC123',
      appVersion: '3.16.3',
      nowSeconds: 1789014602,
    );
    expect(message, {
      'type': 'auth_init',
      'device_sid': 'd_ABC123',
      'meta': {'platform': 'web', 'version': '3.16.3', 'name': 'mobile-browser'},
      'client_ts': 1789014602,
    });
  });

  test('pair_status_query 不再携带 device_sid（V2 bundle 实证）', () {
    final message = RelayMonitorPolicy.pairStatusQueryMessage(42);
    expect(message, {'type': 'pair_status_query', 'client_ts': 42});
  });

  test('workspace-list-request 套 data 外壳（裸负载会被 WRONG_PARAM 拒绝）', () {
    final message = RelayMonitorPolicy.workspaceListRequest(
      requestId: 'monitor-1',
      nowSeconds: 7,
    );
    expect(message['type'], 'data');
    expect((message['payload'] as Map)['zcode_type'], 'workspace-list-request');
    expect((message['payload'] as Map)['requestId'], 'monitor-1');
  });

  group('parse', () {
    test('auth_ack', () {
      final inbound = RelayMonitorPolicy.parse(
        '{"type":"auth_ack","server_ts":1,"device_sid":"d_A","pair_status":"matched"}',
      );
      expect(inbound, isA<RelayAuthAck>());
      final ack = inbound! as RelayAuthAck;
      expect(ack.deviceSid, 'd_A');
      expect(ack.pairStatus, 'matched');
    });

    test('pair_status_ack', () {
      final inbound = RelayMonitorPolicy.parse(
        '{"type":"pair_status_ack","pair_status":"waiting_terminal"}',
      );
      expect((inbound! as RelayPairStatusAck).pairStatus, 'waiting_terminal');
    });

    test('data 帧透传 payload', () {
      final inbound = RelayMonitorPolicy.parse(
        '{"type":"data","server_ts":1,"payload":{"requestId":"r","result":{"tasks":[]}}}',
      );
      final payload = (inbound! as RelayDataPayload).payload;
      expect((payload['result'] as Map)['tasks'], isEmpty);
    });

    test('error 帧带 code', () {
      final inbound = RelayMonitorPolicy.parse(
        '{"type":"error","code":"WRONG_PARAM"}',
      );
      expect((inbound! as RelayErrorFrame).code, 'WRONG_PARAM');
    });

    test('非 JSON / 非对象 / 缺 device_sid 的 auth_ack 一律 null', () {
      expect(RelayMonitorPolicy.parse('garbage'), isNull);
      expect(RelayMonitorPolicy.parse('[1,2]'), isNull);
      expect(RelayMonitorPolicy.parse('{"type":"auth_ack"}'), isNull);
      // 二进制 rpc-frame 是 data 帧的一种 payload（Map payload 透传给
      // 连接层，连接层只在 result 存在时消费）。
      expect(
        RelayMonitorPolicy.parse('{"type":"data","payload":{"zcode_type":"rpc-frame"}}'),
        isA<RelayDataPayload>(),
      );
    });
  });

  test('重连退避：3s 起、指数翻倍、封顶 120s', () {
    expect(RelayMonitorPolicy.backoff(0), const Duration(seconds: 3));
    expect(RelayMonitorPolicy.backoff(1), const Duration(seconds: 3));
    expect(RelayMonitorPolicy.backoff(2), const Duration(seconds: 6));
    expect(RelayMonitorPolicy.backoff(3), const Duration(seconds: 12));
    expect(RelayMonitorPolicy.backoff(10), const Duration(seconds: 120));
    expect(RelayMonitorPolicy.backoff(50), const Duration(seconds: 120));
  });

  group('状态机（fake socket）', () {
    test('连接 → auth_init → matched → 拉快照 → 收快照', () {
      fakeAsync((async) {
        final sockets = <FakeSocket>[];
        final states = <RelayMonitorState>[];
        final snapshots = <Map<dynamic, dynamic>>[];
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
          onState: (_, state) => states.add(state),
          onSnapshot: (_, result) => snapshots.add(result),
        );

        unawaited(connection.start());
        async.elapse(const Duration(milliseconds: 10));
        expect(states, contains(RelayMonitorState.authenticating));
        // 握手报文已发出且 sid 正确；连接 URL 带 token+mid（V2 配方）。
        expect(sockets.first.sent.join(), contains('d_ABC'));
        expect(sockets.first.connectUrls.single, contains('token=relay-from-jwt-token-1'));
        expect(sockets.first.connectUrls.single, contains('mid=mid-1234'));

        sockets.first.serverSends(
          '{"type":"auth_ack","device_sid":"d_ABC","pair_status":"matched"}',
        );
        async.elapse(const Duration(milliseconds: 10));
        expect(connection.state, RelayMonitorState.paired);
        expect(
          sockets.first.sent.join(),
          contains('workspace-list-request'),
        );

        sockets.first.serverSends(
          '{"type":"data","payload":{"requestId":"x","result":{"tasks":[{"taskId":"s1","displayStatus":"completed"}]}}}',
        );
        async.elapse(const Duration(milliseconds: 10));
        expect(snapshots, hasLength(1));
        expect((snapshots.first['tasks'] as List), hasLength(1));

        // 别的 sid 的 ack 不是给这条连接的：状态不被打扰。
        sockets.first.serverSends(
          '{"type":"auth_ack","device_sid":"d_OTHER","pair_status":"matched"}',
        );
        async.elapse(const Duration(milliseconds: 10));
        expect(connection.state, RelayMonitorState.paired);

        connection.stop();
        // broadcast 订阅的 cancel/close 在 fake_async 下需要一个 timer tick
        // 才完成（flushMicrotasks 不够）。
        async.elapse(const Duration(milliseconds: 1));
        expect(states.last, RelayMonitorState.idle);
        expect(sockets.first.closed, isTrue);
      });
    });

    test('waiting → pair_status_ack matched 转正；paired 不受 waiting 超时影响', () {
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
          '{"type":"auth_ack","device_sid":"d_ABC","pair_status":"waiting_terminal"}',
        );
        async.elapse(const Duration(milliseconds: 10));
        expect(connection.state, RelayMonitorState.waiting);

        sockets.first.serverSends(
          '{"type":"pair_status_ack","pair_status":"matched"}',
        );
        async.elapse(const Duration(milliseconds: 10));
        expect(connection.state, RelayMonitorState.paired);

        // paired 状态下不再受 waiting 超时影响。
        async.elapse(const Duration(seconds: 40));
        expect(connection.state, RelayMonitorState.paired);
      });
    });

    test('桌面 30s 不配对 → 断开 → 3s 后自动重连', () {
      fakeAsync((async) {
        final sockets = <FakeSocket>[];
        final states = <RelayMonitorState>[];
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
          onState: (_, state) => states.add(state),
        );
        unawaited(connection.start());
        async.elapse(const Duration(milliseconds: 10));
        sockets.first.serverSends(
          '{"type":"auth_ack","device_sid":"d_ABC","pair_status":"waiting_terminal"}',
        );
        async.elapse(const Duration(seconds: 31));
        expect(states, contains(RelayMonitorState.disconnected));
        // 退避 3s 后第二条 socket 建起来。
        async.elapse(const Duration(seconds: 4));
        expect(sockets.length, 2);
        expect(sockets.last.sent.join(), contains('d_ABC'));
      });
    });

    test('建连失败进入退避，不抛异常', () {
      fakeAsync((async) {
        final states = <RelayMonitorState>[];
        final connection = RelayMonitorConnection(
          deviceId: 'dev12345678',
          deviceSid: 'd_ABC',
          deviceMid: 'mid-1234',
          appVersion: '3.16.3',
          tokenProvider: () async => 'jwt-token-1',
          relayTokenExchange: (jwt) async => 'relay-from-$jwt',
          socketFactory: () => FakeSocket(true),
          onState: (_, state) => states.add(state),
        );
        unawaited(connection.start());
        async.elapse(const Duration(seconds: 1));
        expect(states, contains(RelayMonitorState.disconnected));
      });
    });

    test('auth_ack 迟到超过预算 → 断开重连', () {
      fakeAsync((async) {
        final connection = RelayMonitorConnection(
          deviceId: 'dev12345678',
          deviceSid: 'd_ABC',
          deviceMid: 'mid-1234',
          appVersion: '3.16.3',
          tokenProvider: () async => 'jwt-token-1',
          relayTokenExchange: (jwt) async => 'relay-from-$jwt',
          socketFactory: () => FakeSocket(false),
          onState: (_, _) {},
        );
        unawaited(connection.start());
        async.elapse(const Duration(seconds: 13));
        expect(connection.state, RelayMonitorState.disconnected);
      });
    });

    test('wsUrlFor：token 必带、mid 非空才带（与官方 searchParams 逐参对齐）', () {
      final url = RelayMonitorConnection.wsUrlFor(token: 't0 k', deviceMid: 'mid-9');
      expect(url.toString(), 'wss://zcode.z.ai/api/v1/remote/ws2?token=t0+k&mid=mid-9');
      final noMid = RelayMonitorConnection.wsUrlFor(token: 't', deviceMid: '  ');
      expect(noMid.toString(), 'wss://zcode.z.ai/api/v1/remote/ws2?token=t');
    });

    test('无 token：不建连，60s 后重读 token 再连（v1.3.1）', () {
      fakeAsync((async) {
        var reads = 0;
        var token = '';
        final sockets = <FakeSocket>[];
        final connection = RelayMonitorConnection(
          deviceId: 'dev12345678',
          deviceSid: 'd_ABC',
          deviceMid: 'mid-1234',
          appVersion: '3.16.3',
          tokenProvider: () async {
            reads += 1;
            return token.isEmpty ? null : token;
          },
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
        expect(sockets, isEmpty, reason: '没有 JWT 绝不裸连');
        expect(reads, 1);
        expect(connection.state, RelayMonitorState.authMissing,
            reason: '缺令牌是独立诊断态（区别于网络故障）');

        token = 'late-token';
        async.elapse(const Duration(seconds: 61));
        expect(reads, 2);
        expect(sockets, hasLength(1));
        expect(sockets.first.connectUrls.single, contains('token=relay-from-late-token'));
        expect(sockets.first.connectUrls.single, contains('mid=mid-1234'));
      });
    });
  });

  test('tasksOfResult：非 List 的 tasks 返回 null', () {
    expect(tasksOfResult({'tasks': [1]}), [1]);
    expect(tasksOfResult({'tasks': 'nope'}), isNull);
    expect(tasksOfResult({}), isNull);
  });
}

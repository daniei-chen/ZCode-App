import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/native/bootstrap/native_bootstrap_coordinator.dart';
import 'package:zremote/native/bootstrap/native_bootstrap_state.dart';
import 'package:zremote/relay/agent_rpc.dart';
import 'package:zremote/state/conversation.dart';
import 'package:zremote/state/relay_source.dart';

import 'fake_relay_server.dart';

RemoteDevice relayDevice({String id = 'dev-1'}) => RemoteDevice(
  id: id,
  baseUrl: 'https://zcode.z.ai/remote/v4',
  params: const {
    'sid': 'd_EXAMPLE000000000000000',
    'hash': '/EXAMPLE+EXAMPLE/EXAMPLE=',
    'mid': '00000000-0000-4000-8000-000000000000',
    'name': 'DESKTOP',
    'app_version': '3.11.2',
  },
  label: 'PC',
  createdAt: DateTime(2026, 9, 11),
);

Map<String, dynamic> userRow(int id, String text, {int at = 1000}) => {
  'rowId': id,
  'kind': 'userInput',
  'text': text,
  'origin': 'realUser',
  'createdAt': at,
};

Map<String, dynamic> assistantRow(int id, String text, {int at = 2000}) => {
  'rowId': id,
  'kind': 'assistantText',
  'text': text,
  'state': 'complete',
  'createdAt': at,
};

Future<void> settle([int rounds = 6]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late FakeRelayServer server;
  late ProviderContainer c;

  setUp(() {
    server = FakeRelayServer()..installDefaults();
    RelaySourceNotifier.debugSocketFactory = server.factory;
    c = ProviderContainer();
  });

  tearDown(() async {
    RelaySourceNotifier.debugSocketFactory = null;
    await c.read(relaySourceProvider.notifier).disconnect('dev-1');
    c.dispose();
  });

  RelaySourceNotifier relay() => c.read(relaySourceProvider.notifier);
  ConversationNotifier conv() => c.read(conversationProvider.notifier);
  NativeBootstrapState boot([String? sessionId]) => c.read(
    nativeBootstrapProvider((deviceId: 'dev-1', sessionId: sessionId)),
  );

  group('happy path (bootstrap → subscribe → send → stop)', () {
    test(
      'four layers become ready in order and sending is offered only at the end',
      () async {
        final connecting = relay().connect(relayDevice());
        await settle(2);
        expect(
          boot().transport,
          isIn([TransportPhase.connecting, TransportPhase.relayReady]),
        );
        await connecting;

        expect(boot().transport, TransportPhase.relayReady);
        expect(
          boot().agent,
          AgentPhase.ready,
          reason: 'handshake is part of connect',
        );
        expect(boot().workspace, WorkspacePhase.ready);
        expect(boot().draftCreateReady, isTrue);
        expect(
          boot('sess_fixture_0001').canSend,
          isFalse,
          reason: 'no subscription ack yet',
        );

        await conv().load(
          deviceId: 'dev-1',
          workspacePath: '/proj',
          sessionId: 'sess_fixture_0001',
        );
        final st = conv().stateOf('dev-1', 'sess_fixture_0001');
        expect(st.subscription, ConversationPhase.acked);
        expect(st.subscriptionId, 'sub-1');
        expect(boot('sess_fixture_0001').canSend, isTrue);
        expect(boot('sess_fixture_0001').status, NativeStatusKind.sessionReady);
        expect(
          server.calls.map((r) => r.method),
          containsAllInOrder([
            'helloConversationV4',
            'initializeConversationV4',
            'subscribeConversationV4',
          ]),
        );
      },
    );

    test(
      'send: one optimistic row replaced by the official twin, one receipt',
      () async {
        await relay().connect(relayDevice());
        await conv().load(
          deviceId: 'dev-1',
          workspacePath: '/proj',
          sessionId: 'sess_fixture_0001',
        );
        final ok = await conv().sendMessage(
          deviceId: 'dev-1',
          workspacePath: '/proj',
          sessionId: 'sess_fixture_0001',
          text: '你好',
        );
        expect(ok, isTrue);
        expect(server.sendRequests, 1);
        var st = conv().stateOf('dev-1', 'sess_fixture_0001');
        expect(st.rows.where((r) => r.text == '你好').length, 1);
        expect(st.sendPhase, SendPhase.streaming);

        // Desktop echoes the user input with our command id as sourceCommandId.
        final sent = server.calls.lastWhere(
          (r) => r.method == 'sendConversationCommandV4',
        );
        final scoped = sent.args.first as Map;
        final envelope = scoped['envelope'] is Map
            ? scoped['envelope'] as Map
            : scoped;
        final commandId = envelope['commandId'];
        server.pushRows([
          {...userRow(10, '你好', at: 1500), 'sourceCommandId': commandId},
          assistantRow(11, '你好！', at: 1600),
        ]);
        await settle();
        st = conv().stateOf('dev-1', 'sess_fixture_0001');
        expect(
          st.rows.where((r) => r.text == '你好').length,
          1,
          reason: 'optimistic row must be replaced, not duplicated',
        );
        expect(st.rows.map((r) => r.rowId), containsAll([10, 11]));
      },
    );
  });

  group('F01 handshake delayed', () {
    test('shell stays connecting, then becomes ready', () async {
      server.handshakeDelay = const Duration(milliseconds: 150);
      final f = relay().connect(relayDevice());
      await settle(3);
      expect(boot().status, NativeStatusKind.connecting);
      expect(boot().canSend, isFalse);
      await f;
      expect(boot().status, NativeStatusKind.draftReady);
    });
  });

  group('F02 relay ready, agent handshake pending', () {
    test('never shows "sendable" while hello is unanswered', () async {
      AgentRpc? heldHello;
      server.handlers['zcode-agent.helloConversationV4'] = (s, rpc) =>
          heldHello = rpc;
      final f = relay().connect(relayDevice());
      await settle(8);
      final s = c.read(relaySourceProvider)['dev-1']!;
      expect(s.isLive, isTrue, reason: 'transport is up');
      expect(s.agentPhase, AgentPhase.handshaking);
      expect(boot().status, NativeStatusKind.agentHandshaking);
      expect(boot().status.labelZh, '已连接，正在初始化 Agent');
      expect(boot().draftCreateReady, isFalse);
      expect(heldHello, isNotNull);

      server.installDefaults(); // restore
      server.replyOk({
        'kind': 'hello',
        'connectionId': 'conn-1',
        'clientMode': 'web-remote-replayable',
        'capabilities': {},
      });
      await f;
      expect(boot().agent, AgentPhase.ready);
    });
  });

  group('F03 session subscribe fails', () {
    test('shows a session-layer retry, not a transport failure', () async {
      server.handlers['zcode-agent.subscribeConversationV4'] = (s, _) =>
          s.replyError('fault.subscribe.denied');
      await relay().connect(relayDevice());
      await conv().load(
        deviceId: 'dev-1',
        workspacePath: '/proj',
        sessionId: 'sess_fixture_0001',
      );
      final st = conv().stateOf('dev-1', 'sess_fixture_0001');
      expect(st.subscription, ConversationPhase.failed);
      expect(
        boot('sess_fixture_0001').status,
        NativeStatusKind.sessionSubscribeFailed,
      );
      expect(boot('sess_fixture_0001').transport, TransportPhase.relayReady);
      expect(
        boot('sess_fixture_0001').lastFailure?.layer,
        NativeLayer.conversation,
      );
    });
  });

  group('F06 duplicate stream row', () {
    test('the same row pushed twice renders once', () async {
      await relay().connect(relayDevice());
      server.rows = [userRow(1, '你好')];
      await conv().load(
        deviceId: 'dev-1',
        workspacePath: '/proj',
        sessionId: 'sess_fixture_0001',
      );
      server.pushRows([assistantRow(2, 'hi')]);
      server.pushRows([assistantRow(2, 'hi')]);
      server.pushRows([
        {'kind': 'assistantText', 'text': 'hi', 'createdAt': 2000},
      ]);
      await settle();
      final st = conv().stateOf('dev-1', 'sess_fixture_0001');
      expect(st.rows.length, 2);
      expect(st.rows.where((r) => r.text == 'hi').length, 1);
    });
  });

  group('F12 stop clicked twice', () {
    test('only one stop request reaches the desktop', () async {
      await relay().connect(relayDevice());
      await conv().load(
        deviceId: 'dev-1',
        workspacePath: '/proj',
        sessionId: 'sess_fixture_0001',
      );
      await Future.wait([
        conv().stopConversation(
          deviceId: 'dev-1',
          workspacePath: '/proj',
          sessionId: 'sess_fixture_0001',
        ),
        conv().stopConversation(
          deviceId: 'dev-1',
          workspacePath: '/proj',
          sessionId: 'sess_fixture_0001',
        ),
      ]);
      await conv().stopConversation(
        deviceId: 'dev-1',
        workspacePath: '/proj',
        sessionId: 'sess_fixture_0001',
      );
      expect(server.stopRequests, 1);
      expect(conv().stateOf('dev-1', 'sess_fixture_0001').stopping, isFalse);
    });
  });

  group('F14 method not found', () {
    test('usage call reports unsupported instead of null-and-guess', () async {
      server.handlers['usage-stats.getAppUsageStats'] = (s, _) =>
          s.replyError('fault.method_not_found: usage-stats.getAppUsageStats');
      await relay().connect(relayDevice());
      final r = await relay().callService(
        'dev-1',
        'usage-stats',
        'getAppUsageStats',
        const [],
      );
      expect(r.ok, isFalse);
      expect(r.isMethodNotFound, isTrue);
      expect(
        await relay().callServiceExpectValue(
          'dev-1',
          'usage-stats',
          'getAppUsageStats',
        ),
        isNull,
      );
    });
  });
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/native/bootstrap/native_bootstrap_state.dart';
import 'package:zremote/relay/relay_socket.dart';
import 'package:zremote/state/conversation.dart';
import 'package:zremote/state/relay_source.dart';

import 'fake_relay_server.dart';
import 'failure_injection_test.dart' as shared;

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
  Future<void> load() => conv().load(
    deviceId: 'dev-1',
    workspacePath: '/proj',
    sessionId: 'sess_fixture_0001',
  );

  group('review P0-1: sendPhase lifecycle', () {
    test('terminal turnHeader returns the composer to send', () async {
      await relay().connect(shared.relayDevice());
      await load();
      await conv().sendMessage(
        deviceId: 'dev-1',
        workspacePath: '/proj',
        sessionId: 'sess_fixture_0001',
        text: '你好',
      );
      var st = conv().stateOf('dev-1', 'sess_fixture_0001');
      expect(st.sendPhase, SendPhase.streaming);

      server.pushRows([
        {
          'rowId': 30,
          'kind': 'turnHeader',
          'state': 'completedSuccess',
          'createdAt': 3000,
        },
        {
          'rowId': 31,
          'kind': 'assistantText',
          'text': 'done',
          'createdAt': 3100,
        },
      ]);
      await shared.settle();
      st = conv().stateOf('dev-1', 'sess_fixture_0001');
      expect(
        st.sendPhase,
        SendPhase.idle,
        reason: 'the desktop closed the turn; send must be offered again',
      );
      expect(st.stopEpoch, isNull, reason: 'per-run stop guard re-armed');
    });

    test('non-terminal turnHeader keeps streaming', () async {
      await relay().connect(shared.relayDevice());
      await load();
      await conv().sendMessage(
        deviceId: 'dev-1',
        workspacePath: '/proj',
        sessionId: 'sess_fixture_0001',
        text: 'go',
      );
      server.pushRows([
        {
          'rowId': 30,
          'kind': 'turnHeader',
          'state': 'running',
          'createdAt': 3000,
        },
      ]);
      await shared.settle();
      expect(
        conv().stateOf('dev-1', 'sess_fixture_0001').sendPhase,
        SendPhase.streaming,
      );
    });
  });

  group('review P0-2: stop guard is per run', () {
    test('stop → new run → stop again sends a second request', () async {
      await relay().connect(shared.relayDevice());
      await load();

      await conv().stopConversation(
        deviceId: 'dev-1',
        workspacePath: '/proj',
        sessionId: 'sess_fixture_0001',
      );
      expect(server.stopRequests, 1);

      // Turn ends (re-arm), a new send starts a new run.
      server.pushRows([
        {
          'rowId': 40,
          'kind': 'turnHeader',
          'state': 'stopped',
          'createdAt': 4000,
        },
      ]);
      await shared.settle();
      await conv().sendMessage(
        deviceId: 'dev-1',
        workspacePath: '/proj',
        sessionId: 'sess_fixture_0001',
        text: 'again',
      );

      await conv().stopConversation(
        deviceId: 'dev-1',
        workspacePath: '/proj',
        sessionId: 'sess_fixture_0001',
      );
      expect(
        server.stopRequests,
        2,
        reason: 'a different execution must be stoppable',
      );
    });

    test('double tap within one run still sends exactly one', () async {
      await relay().connect(shared.relayDevice());
      await load();
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
      expect(server.stopRequests, 1);
    });
  });

  group('review P1-3: retrying phase', () {
    test(
      'a non-terminal connect failure schedules retry and surfaces it',
      () async {
        // A connect error is non-terminal: relay_source schedules backoff.
        RelaySourceNotifier.debugSocketFactory = FakeRelaySocketFactory(
          error: StateError('refused'),
        );
        await relay().connect(shared.relayDevice());
        final s = c.read(relaySourceProvider)['dev-1']!;
        expect(s.kind, RelaySourceKind.failed);
        expect(s.autoRetrying, isTrue);
        final b = s.bootstrap;
        expect(b.transport, TransportPhase.retrying);
        expect(b.status, NativeStatusKind.reconnecting);
        expect(b.status.labelZh, '连接中断，正在自动重连');
        expect(b.status.isRetryable, isTrue);
      },
    );
  });
}

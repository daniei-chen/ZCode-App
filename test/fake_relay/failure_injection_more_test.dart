import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/native/bootstrap/native_bootstrap_state.dart';
import 'package:zremote/relay/agent_rpc.dart';
import 'package:zremote/state/conversation.dart';
import 'package:zremote/state/conversation_config.dart';
import 'package:zremote/state/create_recovery.dart';
import 'package:zremote/state/relay_source.dart';
import 'package:zremote/state/session_index.dart';

import 'fake_relay_server.dart';

RemoteDevice relayDevice() => RemoteDevice(
  id: 'dev-1',
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

Future<void> settle([int rounds = 6]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

const _s = 'sess_fixture_0001';

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
  Future<void> load() =>
      conv().load(deviceId: 'dev-1', workspacePath: '/proj', sessionId: _s);

  group('F04 / F05 create receipt lost', () {
    test(
      'F04: desktop created the session; it is recovered from the task index, '
      'no second create is sent',
      () async {
        final startedAt = DateTime.now().millisecondsSinceEpoch;
        server.handlers['zcode-agent.sendConversationCommandV4'] = (s, rpc) {
          final scoped = rpc.args.first as Map;
          final cmd = scoped['envelope'] is Map
              ? scoped['envelope'] as Map
              : scoped;
          if (cmd['type'] == 'createSession') {
            s.createRequests++;
            // The desktop applies the create but the receipt never arrives.
            s.tasks = [
              ...s.tasks,
              {
                'taskId': 'sess_new_0002',
                'title': '你好',
                'displayStatus': 'running',
                'workspacePath': '/proj',
                'createdAt': DateTime.now().millisecondsSinceEpoch,
                'updatedAt': DateTime.now().millisecondsSinceEpoch,
              },
            ];
            s.replyError('fault.receipt.lost');
          }
        };
        await relay().connect(relayDevice());
        final known = {
          for (final s
              in c.read(sessionIndexProvider)['dev-1']?.values ??
                  const <dynamic>[])
            (s as dynamic).sessionId as String,
        };
        final id = await relay().createConversation(
          deviceId: 'dev-1',
          workspacePath: '/proj',
          text: '你好',
          clientOperationId: 'zr-create-op1',
        );
        expect(id, isNull);
        expect(server.createRequests, 1);

        await relay().bridgeOf('dev-1')!.refreshTasks();
        await settle();
        final recovered = CreateRecovery.findCreatedSession(
          sessions: c.read(sessionIndexProvider)['dev-1']!.values,
          workspacePath: '/proj',
          firstInput: '你好',
          sinceMs: startedAt - 5000,
          knownBefore: known,
        );
        expect(recovered, 'sess_new_0002');
        expect(server.createRequests, 1, reason: 'recovery never re-creates');
      },
    );

    test(
      'F05: nothing was created; recovery returns null and the draft stays',
      () async {
        server.handlers['zcode-agent.sendConversationCommandV4'] = (s, _) =>
            s.replyError('fault.receipt.lost');
        await relay().connect(relayDevice());
        final id = await relay().createConversation(
          deviceId: 'dev-1',
          workspacePath: '/proj',
          text: '一个全新的问题',
        );
        expect(id, isNull);
        final recovered = CreateRecovery.findCreatedSession(
          sessions: c.read(sessionIndexProvider)['dev-1']?.values ?? const [],
          workspacePath: '/proj',
          firstInput: '一个全新的问题',
          sinceMs: 0,
        );
        expect(recovered, isNull);
      },
    );
  });

  group('F08 model catalogue empty', () {
    test(
      'current model shows, catalogue is reported empty (not "not returned")',
      () async {
        server.handlers['zcode-session.readSession'] = (s, _) => s.replyOk({
          'settings': {
            'model': {
              'current': {'providerId': 'fixture-provider', 'modelId': 'flash'},
              'available': <Object>[],
            },
            'thoughtLevel': {
              'enabled': true,
              'current': 'max',
              'available': <Object>[],
            },
          },
          'projection': {'contextUsed': 5, 'contextWindow': 0},
        });
        await relay().connect(relayDevice());
        await conv().loadRuntimeConfig(
          deviceId: 'dev-1',
          workspacePath: '/proj',
          sessionId: _s,
        );
        final cfg = conv().stateOf('dev-1', _s).runtimeConfig;
        expect(cfg.modelId, 'flash');
        expect(cfg.catalogState, ConfigFieldState.empty);
        expect(cfg.thoughtSelectable, isFalse);
        expect(cfg.thoughtLevel, 'max');
        expect(cfg.contextUsedTokens, 5);
        expect(
          cfg.contextMaxTokens,
          isNull,
          reason: 'F10: window 0 is unknown',
        );
      },
    );
  });

  group('F11 config update rejected', () {
    test('old values stay and the desktop reason is shown', () async {
      server.handlers['zcode-session.setThoughtLevel'] = (s, _) =>
          s.replyError('fault.rejected: thought_level_unsupported');
      await relay().connect(relayDevice());
      await conv().loadRuntimeConfig(
        deviceId: 'dev-1',
        workspacePath: '/proj',
        sessionId: _s,
      );
      expect(conv().stateOf('dev-1', _s).runtimeConfig.thoughtLevel, 'max');

      await conv().updateRuntimeConfig(
        deviceId: 'dev-1',
        workspacePath: '/proj',
        sessionId: _s,
        thoughtLevel: 'high',
      );
      final st = conv().stateOf('dev-1', _s);
      expect(
        st.runtimeConfig.thoughtLevel,
        'max',
        reason: 'no optimistic change',
      );
      expect(st.actionError, contains('thought_level_unsupported'));
      expect(st.runtimeConfig.loading, isFalse);
      expect(
        server.calls.where((r) => r.method == 'setThoughtLevel').length,
        1,
      );
      expect(
        server.calls.where((r) => r.method == 'switchModelConfig').length,
        0,
        reason: 'a plain rejection must not fall back to the combined command',
      );
    });

    test(
      'independent thought change sends setThoughtLevel with expectedRevision',
      () async {
        await relay().connect(relayDevice());
        await conv().loadRuntimeConfig(
          deviceId: 'dev-1',
          workspacePath: '/proj',
          sessionId: _s,
        );
        await conv().updateRuntimeConfig(
          deviceId: 'dev-1',
          workspacePath: '/proj',
          sessionId: _s,
          thoughtLevel: 'high',
        );
        final call = server.calls.lastWhere(
          (r) => r.method == 'setThoughtLevel',
        );
        final args = call.args.first as Map;
        expect(call.service, 'zcode-session');
        expect(args['thoughtLevel'], 'high');
        expect(args['expectedRevision'], 7);
        expect(args.containsKey('model'), isFalse);
        expect(server.calls.where((r) => r.method == 'setModel'), isEmpty);
      },
    );
  });

  group('F07 / F13 / F15 reconnect', () {
    test('a subscribe attempt from the old epoch cannot win; the new bridge is '
        'subscribed automatically and pushes flow again', () async {
      await relay().connect(relayDevice());
      // Hold the ack so the first subscribe is still pending when we reconnect.
      AgentRpc? held;
      server.handlers['zcode-agent.subscribeConversationV4'] = (s, rpc) =>
          held = rpc;
      final loading = load();
      await settle(4);
      expect(
        conv().stateOf('dev-1', _s).subscription,
        ConversationPhase.subscribing,
      );
      final oldEpoch = relay().epochOf('dev-1');
      expect(held, isNotNull);

      server.installDefaults(); // the new connection answers normally
      await relay().reconnect(relayDevice());
      await loading;
      await settle(10);

      final st = conv().stateOf('dev-1', _s);
      final newEpoch = relay().epochOf('dev-1');
      expect(newEpoch, greaterThan(oldEpoch));
      expect(st.subscription, ConversationPhase.acked);
      expect(
        st.subscriptionEpoch,
        newEpoch,
        reason: 'the ack belongs to the new bridge',
      );
      expect(
        server.callsThisConnection
            .where((r) => r.method == 'subscribeConversationV4')
            .length,
        1,
        reason: 'rebound exactly once on the new connection',
      );

      server.pushRows([
        {
          'rowId': 3,
          'kind': 'assistantText',
          'text': 'after reconnect',
          'createdAt': 3000,
        },
      ]);
      await settle();
      expect(
        conv().stateOf('dev-1', _s).rows.map((r) => r.text),
        contains('after reconnect'),
      );
    });

    test(
      'F13: rows survive a dropped connection and realtime resumes',
      () async {
        server.rows = [
          {
            'rowId': 1,
            'kind': 'userInput',
            'text': '你好',
            'origin': 'realUser',
            'createdAt': 1000,
          },
        ];
        await relay().connect(relayDevice());
        await load();
        server.pushRows([
          {
            'rowId': 2,
            'kind': 'assistantText',
            'text': 'partial…',
            'createdAt': 2000,
          },
        ]);
        await settle();
        expect(conv().stateOf('dev-1', _s).rows.length, 2);

        await server.dropConnection();
        await settle(4);
        // An unexpected socket close is reported as a transport failure and
        // resets the agent layer; the old ack is void.
        final failed = c.read(relaySourceProvider)['dev-1']!;
        expect(failed.kind, RelaySourceKind.failed);
        expect(failed.agentPhase, AgentPhase.notStarted);
        expect(
          conv().stateOf('dev-1', _s).rows.length,
          2,
          reason: 'rows are kept while disconnected',
        );

        // Quiet mode reconnects when the app resumes; that is a connect().
        await relay().connect(relayDevice());
        await settle(10);

        final relayState = c.read(relaySourceProvider)['dev-1']!;
        expect(relayState.isLive, isTrue);
        expect(relayState.agentReady, isTrue);
        final st = conv().stateOf('dev-1', _s);
        expect(st.rows.length, 2, reason: 'nothing was cleared by the drop');
        expect(st.subscription, ConversationPhase.acked);
        expect(st.subscriptionEpoch, relay().epochOf('dev-1'));

        server.pushRows([
          {
            'rowId': 2,
            'kind': 'assistantText',
            'text': 'partial… done',
            'createdAt': 2000,
          },
        ]);
        await settle();
        final rows = conv().stateOf('dev-1', _s).rows;
        expect(rows.length, 2, reason: 'update replaces, never appends');
        expect(rows.last.text, 'partial… done');
        expect(server.connections, 2);
      },
    );
  });
}

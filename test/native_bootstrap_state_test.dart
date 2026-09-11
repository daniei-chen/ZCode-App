import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/native/bootstrap/native_bootstrap_state.dart';
import 'package:zremote/relay/command_receipt.dart';
import 'package:zremote/relay/conversation_subscription.dart';
import 'package:zremote/state/relay_source.dart';

void main() {
  group('NativeBootstrapState readiness', () {
    test('relay ready alone is not sendable (S01/S02 contradiction)', () {
      const s = NativeBootstrapState(
        transport: TransportPhase.relayReady,
        agent: AgentPhase.notStarted,
      );
      expect(s.transportLive, isTrue);
      expect(s.canSend, isFalse);
      expect(s.draftCreateReady, isFalse);
      expect(s.status, NativeStatusKind.agentHandshaking);
      expect(s.status.labelZh, '已连接，正在初始化 Agent');
    });

    test('status reports the lowest unready layer', () {
      expect(
        const NativeBootstrapState(transport: TransportPhase.connecting).status,
        NativeStatusKind.connecting,
      );
      expect(
        const NativeBootstrapState(transport: TransportPhase.failed).status,
        NativeStatusKind.transportFailed,
      );
      expect(
        const NativeBootstrapState(
          transport: TransportPhase.relayReady,
          agent: AgentPhase.unavailable,
        ).status,
        NativeStatusKind.agentUnavailable,
      );
      expect(
        const NativeBootstrapState(
          transport: TransportPhase.relayReady,
          agent: AgentPhase.ready,
          workspace: WorkspacePhase.loading,
        ).status,
        NativeStatusKind.workspaceLoading,
      );
      expect(
        const NativeBootstrapState(
          transport: TransportPhase.relayReady,
          agent: AgentPhase.ready,
          workspace: WorkspacePhase.ready,
          conversation: ConversationPhase.subscribing,
        ).status,
        NativeStatusKind.sessionSubscribing,
      );
      expect(
        const NativeBootstrapState(
          transport: TransportPhase.relayReady,
          agent: AgentPhase.ready,
          workspace: WorkspacePhase.ready,
          conversation: ConversationPhase.failed,
        ).status,
        NativeStatusKind.sessionSubscribeFailed,
      );
    });

    test('draft can create once transport+agent+workspace are ready', () {
      const s = NativeBootstrapState(
        transport: TransportPhase.relayReady,
        agent: AgentPhase.ready,
        workspace: WorkspacePhase.ready,
      );
      expect(s.draftCreateReady, isTrue);
      expect(s.canSend, isFalse, reason: 'no subscription ack yet');
      expect(s.status, NativeStatusKind.draftReady);
    });

    test('canSend requires the subscription ack', () {
      const s = NativeBootstrapState(
        transport: TransportPhase.relayReady,
        agent: AgentPhase.ready,
        workspace: WorkspacePhase.ready,
        conversation: ConversationPhase.acked,
        subscriptionId: 'sub_1',
      );
      expect(s.canSend, isTrue);
      expect(s.status, NativeStatusKind.sessionReady);
    });

    test('nextEpoch resets every layer below transport', () {
      const s = NativeBootstrapState(
        transport: TransportPhase.relayReady,
        agent: AgentPhase.ready,
        workspace: WorkspacePhase.ready,
        conversation: ConversationPhase.acked,
        connectionEpoch: 1,
        subscriptionId: 'sub_1',
      );
      final next = s.nextEpoch(2);
      expect(next.connectionEpoch, 2);
      expect(next.transport, TransportPhase.connecting);
      expect(next.agent, AgentPhase.notStarted);
      expect(next.conversation, ConversationPhase.none);
      expect(next.subscriptionId, isNull);
    });

    test('retryable statuses are exactly the failure layers', () {
      for (final k in NativeStatusKind.values) {
        final expected = {
          NativeStatusKind.transportFailed,
          NativeStatusKind.reconnecting,
          NativeStatusKind.agentUnavailable,
          NativeStatusKind.workspaceError,
          NativeStatusKind.sessionSubscribeFailed,
        }.contains(k);
        expect(k.isRetryable, expected, reason: k.name);
      }
    });
  });

  group('RelaySourceState.bootstrap', () {
    test('live transport with unstarted agent is agentHandshaking', () {
      const s = RelaySourceState(kind: RelaySourceKind.live);
      expect(s.isLive, isTrue);
      expect(s.agentReady, isFalse);
      expect(s.bootstrap.status, NativeStatusKind.agentHandshaking);
    });

    test('agent ready + workspace key is draftReady', () {
      const s = RelaySourceState(
        kind: RelaySourceKind.live,
        agentPhase: AgentPhase.ready,
        workspaceKey: '/w',
        lastSyncAt: 1,
        connectionEpoch: 3,
      );
      expect(s.bootstrap.status, NativeStatusKind.draftReady);
      expect(s.bootstrap.connectionEpoch, 3);
    });

    test('agent failure surfaces as a layer failure with safe code', () {
      const s = RelaySourceState(
        kind: RelaySourceKind.live,
        agentPhase: AgentPhase.unavailable,
        agentFailure: 'fault.connection.clientChanged',
      );
      final f = s.bootstrap.lastFailure;
      expect(f, isNotNull);
      expect(f!.layer, NativeLayer.agent);
      expect(f.code, 'fault.connection.clientChanged');
    });

    test('failed transport carries reason as transport failure', () {
      const s = RelaySourceState(
        kind: RelaySourceKind.failed,
        reason: 'rpc-transport-fault',
      );
      expect(s.bootstrap.status, NativeStatusKind.transportFailed);
      expect(s.bootstrap.lastFailure?.layer, NativeLayer.transport);
    });
  });

  group('ConversationSubscriptionAck', () {
    test('parses the verified ack envelope', () {
      final ack = ConversationSubscriptionAck.tryParse({
        'ack': {'subscriptionId': 'sub_1', 'mode': 'snapshot', 'logEpoch': '7'},
      });
      expect(ack, isNotNull);
      expect(ack!.subscriptionId, 'sub_1');
      expect(ack.isSnapshot, isTrue);
      expect(ack.logEpoch, '7');
    });

    test('never matches a command receipt or a rows push', () {
      expect(
        ConversationSubscriptionAck.matches({
          'commandId': 'c1',
          'status': 'accepted',
        }),
        isFalse,
      );
      expect(ConversationSubscriptionAck.matches({'rows': []}), isFalse);
      expect(ConversationSubscriptionAck.matches({'ack': {}}), isFalse);
      expect(ConversationSubscriptionAck.matches(null), isFalse);
    });
  });

  group('CommandReceipt', () {
    test('parses all six verified statuses', () {
      for (final status in [
        'accepted',
        'rejected',
        'stale',
        'duplicate',
        'noop',
        'failed',
      ]) {
        final r = CommandReceipt.tryParse({
          'commandId': 'c',
          'status': status,
          'revisionAtDecision': 1,
        });
        expect(r, isNotNull, reason: status);
        expect(r!.status.name, status);
      }
    });

    test('duplicate is idempotent success; rejected/stale/failed refuse', () {
      CommandReceipt r(String s) =>
          CommandReceipt.tryParse({'commandId': 'c', 'status': s})!;
      expect(r('accepted').isSuccess, isTrue);
      expect(r('noop').isSuccess, isTrue);
      expect(r('duplicate').isSuccess, isTrue);
      expect(r('rejected').isRefusal, isTrue);
      expect(r('stale').isRefusal, isTrue);
      expect(r('failed').isRefusal, isTrue);
      expect(r('rejected').isSuccess, isFalse);
    });

    test('exposes reasonCode and message for refusals', () {
      final r = CommandReceipt.tryParse({
        'commandId': 'c',
        'status': 'rejected',
        'reasonCode': 'thought_level_unsupported',
        'message': 'not offered',
        'revisionAtDecision': 7,
      })!;
      expect(r.reasonCode, 'thought_level_unsupported');
      expect(r.message, 'not offered');
      expect(r.revisionAtDecision, 7);
      expect(r.safeLabel, 'rejected:thought_level_unsupported');
    });

    test('unknown status or missing commandId is not a receipt', () {
      expect(
        CommandReceipt.tryParse({'commandId': 'c', 'status': 'ok'}),
        isNull,
      );
      expect(CommandReceipt.tryParse({'status': 'accepted'}), isNull);
      expect(CommandReceipt.tryParse({'rows': []}), isNull);
    });

    test('createdSessionId reads the createSession result', () {
      final r = CommandReceipt.tryParse({
        'commandId': 'c',
        'status': 'accepted',
        'result': {'type': 'createSession', 'sessionId': 'sess_1'},
      })!;
      expect(r.createdSessionId, 'sess_1');
      final other = CommandReceipt.tryParse({
        'commandId': 'c',
        'status': 'accepted',
        'result': {'type': 'resolveInteraction'},
      })!;
      expect(other.createdSessionId, isNull);
    });
  });
}

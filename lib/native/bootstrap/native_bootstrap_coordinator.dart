import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/conversation.dart';
import '../../state/relay_source.dart';
import 'native_bootstrap_state.dart';

/// Device + optional session the UI is looking at.
typedef NativeScope = ({String deviceId, String? sessionId});

/// Single source of layered readiness for a device (and, when a session is
/// selected, that session's subscription).
///
/// Pages must derive every "can I send / is this live" decision from this
/// provider.  It is the only place where relay transport, agent handshake,
/// workspace bootstrap and conversation subscription are combined, so the
/// old contradiction (green dot + "cannot send") cannot be reintroduced by a
/// page reading one flag in isolation.
final nativeBootstrapProvider =
    Provider.family<NativeBootstrapState, NativeScope>((ref, scope) {
      final relay = ref.watch(
        relaySourceProvider.select(
          (m) => m[scope.deviceId] ?? const RelaySourceState(),
        ),
      );
      var state = relay.bootstrap;

      final sessionId = scope.sessionId;
      if (sessionId == null || sessionId.isEmpty) return state;

      final conversation = ref.watch(
        conversationProvider.select(
          (m) =>
              m[ConversationNotifier.keyOf(scope.deviceId, sessionId)] ??
              const ConversationState(),
        ),
      );
      // A subscription (or its failure) recorded on an older epoch belongs
      // to a bridge that no longer exists; report it as not started so the
      // UI shows "subscribing" instead of a stale ack or a stale error.
      final currentEpoch =
          conversation.subscriptionEpoch == relay.connectionEpoch;
      final phase = currentEpoch
          ? conversation.subscription
          : ConversationPhase.none;
      state = state.copyWith(
        conversation: phase,
        subscriptionId: phase == ConversationPhase.acked
            ? conversation.subscriptionId
            : null,
      );
      if (phase == ConversationPhase.failed && state.lastFailure == null) {
        state = state.copyWith(
          lastFailure: const NativeLayerFailure(
            layer: NativeLayer.conversation,
            method: 'subscribeConversationV4',
            code: 'subscribe_not_acked',
          ),
        );
      }
      return state;
    });

/// Convenience selector: may the composer send into [scope] right now?
final nativeCanSendProvider = Provider.family<bool, NativeScope>((ref, scope) {
  final state = ref.watch(nativeBootstrapProvider(scope));
  final sessionId = scope.sessionId;
  return sessionId == null || sessionId.isEmpty
      ? state.draftCreateReady
      : state.canSend;
});

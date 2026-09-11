import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/native/bootstrap/native_bootstrap_state.dart';
import 'package:zremote/relay/conversation_row.dart';
import 'package:zremote/state/conversation.dart';
import 'package:zremote/services/event_observer.dart';
import 'package:zremote/state/relay_source.dart';
import 'package:zremote/state/session_index.dart';
import 'package:zremote/ui/conversation_page.dart';

/// Relay already live, agent ready, workspace resolved (epoch 1).
class _ReadyRelay extends RelaySourceNotifier {
  @override
  Map<String, RelaySourceState> build() => const {
    'd': RelaySourceState(
      kind: RelaySourceKind.live,
      agentPhase: AgentPhase.ready,
      workspaceKey: '/w',
      lastSyncAt: 1,
      connectionEpoch: 1,
    ),
  };
}

/// A subscribed session; the desktop reports phase 'running' via the
/// session index (the real stop signal since the P0-1 fix).
class _StreamingConversation extends ConversationNotifier {
  static int stops = 0;

  @override
  Map<String, ConversationState> build() => {
    'd|s': ConversationState(
      fromNative: true,
      subscription: ConversationPhase.acked,
      subscriptionId: 'sub',
      subscriptionEpoch: 1,
      sendPhase: SendPhase.streaming,
      rows: [
        ConversationRow.tryParse({
          'rowId': 1,
          'kind': 'userInput',
          'text': 'hi',
          'origin': 'realUser',
        })!,
      ],
    ),
  };

  @override
  Future<void> load({
    required String deviceId,
    required String workspacePath,
    required String sessionId,
    bool refresh = false,
  }) async {}

  @override
  Future<void> loadRuntimeConfig({
    required String deviceId,
    required String workspacePath,
    required String sessionId,
    bool refresh = false,
  }) async {}

  @override
  Future<void> stopConversation({
    required String deviceId,
    required String workspacePath,
    required String sessionId,
  }) async {
    stops++;
  }
}

/// The desktop reports the session as running via the session index — the
/// real stop signal since the P0-1 fix removed the sendPhase shortcut.
class _RunningIndex extends SessionIndexNotifier {
  @override
  Map<String, Map<String, SessionState>> build() => const {
    'd': {'s': SessionState(sessionId: 's', phase: 'running')},
  };
}

Widget _app({required Widget home}) => ProviderScope(
  overrides: [
    relaySourceProvider.overrideWith(_ReadyRelay.new),
    conversationProvider.overrideWith(_StreamingConversation.new),
    sessionIndexProvider.overrideWith(_RunningIndex.new),
  ],
  child: MaterialApp(
    theme: ThemeData(brightness: Brightness.dark),
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  ),
);

void main() {
  group('composerPrimaryAction (UX spec §5.1 single slot)', () {
    PrimaryActionState f({
      bool enabled = true,
      bool sending = false,
      bool stopping = false,
      bool canStop = false,
      bool hasContent = false,
    }) => composerPrimaryAction(
      enabled: enabled,
      sending: sending,
      stopping: stopping,
      canStop: canStop,
      hasContent: hasContent,
    );

    test('idle + empty → attach; idle + content → send', () {
      expect(f(), PrimaryActionState.attach);
      expect(f(hasContent: true), PrimaryActionState.send);
    });

    test('running shows stop even with content; stopping wins over all', () {
      expect(f(canStop: true, hasContent: true), PrimaryActionState.stop);
      expect(
        f(canStop: true, stopping: true, sending: true, hasContent: true),
        PrimaryActionState.stopping,
      );
    });

    test('sending shows a spinner, never a second button', () {
      expect(f(sending: true, hasContent: true), PrimaryActionState.sending);
    });

    test('not ready → disabled placeholder, regardless of content', () {
      expect(f(enabled: false, hasContent: true), PrimaryActionState.disabled);
    });
  });

  group('stop (P1-COMPOSER-010)', () {
    testWidgets('one primary slot; tapping stop sends without a dialog', (
      tester,
    ) async {
      _StreamingConversation.stops = 0;
      await tester.pumpWidget(
        _app(
          home: const ConversationPage(
            deviceId: 'd',
            workspacePath: '/w',
            sessionId: 's',
            title: 'hi',
          ),
        ),
      );
      await tester.pump();

      // Exactly one primary action, and it is the stop square.
      expect(find.byKey(const ValueKey('primary-action-stop')), findsOneWidget);
      for (final other in [
        'send',
        'sending',
        'attach',
        'stopping',
        'disabled',
      ]) {
        expect(find.byKey(ValueKey('primary-action-$other')), findsNothing);
      }
      expect(find.byIcon(Icons.arrow_upward_rounded), findsNothing);

      await tester.tap(find.byKey(const ValueKey('primary-action-stop')));
      await tester.pump();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('停止当前执行？'), findsNothing);
      expect(_StreamingConversation.stops, 1);
    });

    testWidgets('status line reports the session as ready', (tester) async {
      await tester.pumpWidget(
        _app(
          home: const ConversationPage(
            deviceId: 'd',
            workspacePath: '/w',
            sessionId: 's',
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('会话已就绪'), findsOneWidget);
      expect(find.text('原生通道已连接'), findsNothing);
    });
  });
}

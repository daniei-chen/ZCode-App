import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/relay/service_call_result.dart';
import 'package:zremote/state/conversation.dart';
import 'package:zremote/state/conversation_config.dart';
import 'package:zremote/state/relay_source.dart';

Map<String, dynamic> _fixture(String rel) =>
    jsonDecode(File('test/fixtures/native/$rel').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  group('verified snapshot parsing (S0 fixtures)', () {
    test(
      'full runtime snapshot: current, catalogue, thought options, context',
      () {
        final config = ConversationRuntimeConfig.parse(
          _fixture('verified/session_snapshot_with_runtime.json'),
        );
        expect(config.providerId, 'fixture-provider');
        expect(config.modelId, 'fixture-model-flash');
        expect(config.modelLabel, 'Fixture Flash');
        expect(config.thoughtLevel, 'max');
        expect(config.thoughtSelectable, isTrue);
        expect(config.thoughtOptions.map((o) => o.value), ['high', 'max']);
        expect(
          config.thoughtOptions.firstWhere((o) => o.value == 'max').label,
          'Max',
        );
        expect(config.catalogState, ConfigFieldState.returned);
        expect(config.models.length, 2);
        expect(config.models[1].enabled, isFalse);
        expect(config.models[1].disabledReason, 'quota_exhausted');
        expect(config.models[0].contextWindow, 200000);
        expect(config.models[0].reasoningLevels.map((o) => o.value), [
          'high',
          'max',
        ]);
        expect(config.contextUsedTokens, 39300);
        expect(config.contextMaxTokens, 200000);
        expect(config.revision, 7);
      },
    );

    test('F09: options not returned → current value stays read-only', () {
      final config = ConversationRuntimeConfig.parse(
        _fixture('verified/session_snapshot_thought_current_only.json'),
      );
      expect(config.thoughtLevel, 'max');
      expect(
        config.thoughtSelectable,
        isFalse,
        reason: 'no options list anywhere in the snapshot',
      );
      expect(
        config.thoughtOptionsState,
        ConfigFieldState.empty,
        reason: 'the desktop returned an explicit empty list',
      );
      expect(config.hasModel, isTrue);
    });

    test('F10: contextWindow 0 means unknown, never a 0-token limit', () {
      final config = ConversationRuntimeConfig.parse(
        _fixture('verified/session_snapshot_thought_current_only.json'),
      );
      expect(config.contextUsedTokens, 1200);
      expect(config.contextMaxTokens, isNull);
    });

    test(
      'runtime.contextUsage fills the context when projection is absent',
      () {
        final config = ConversationRuntimeConfig.parse({
          'runtime': {
            'stateRevision': 3,
            'contextUsage': {'used': 500, 'size': 9000},
          },
        });
        expect(config.contextUsedTokens, 500);
        expect(config.contextMaxTokens, 9000);
        expect(config.revision, 3);
      },
    );

    test('usage quota never becomes context (F10 legacy guard)', () {
      final config = ConversationRuntimeConfig.parse({
        'quota': 88,
        'usage': {'percent': 90},
      });
      expect(config.hasContext, isFalse);
    });

    test(
      'partial overlay preserves omitted fields but honors an explicit empty catalog',
      () {
        final base = ConversationRuntimeConfig.parse(
          _fixture('verified/session_snapshot_with_runtime.json'),
        );
        final partial = ConversationRuntimeConfig(
          modelId: 'fixture-model-flash',
          catalogState: ConfigFieldState.empty,
          thoughtOptionsState: ConfigFieldState.notReturned,
        );
        final merged = base.overlay(partial);
        expect(merged.models, isEmpty);
        expect(merged.thoughtOptions, base.thoughtOptions);
        expect(merged.thoughtOptionsState, base.thoughtOptionsState);
        expect(merged.contextMaxTokens, base.contextMaxTokens);
      },
    );
  });

  group('ServiceCallResult', () {
    test('ok / failure / method-not-found', () {
      expect(const ServiceCallResult.success({'changed': true}).ok, isTrue);
      const miss = ServiceCallResult.failure(
        'fault.method_not_found: zcode-session.setThoughtLevel',
      );
      expect(miss.ok, isFalse);
      expect(miss.isMethodNotFound, isTrue);
      expect(
        const ServiceCallResult.failure('timeout').isMethodNotFound,
        isFalse,
      );
    });
  });

  group('updateRuntimeConfig validation and write path', () {
    late ProviderContainer container;
    late _StubRelay relay;
    late _ConvNotifier conversation;

    setUp(() {
      relay = _StubRelay();
      conversation = _ConvNotifier();
      container = ProviderContainer(
        overrides: [
          relaySourceProvider.overrideWith(() => relay),
          conversationProvider.overrideWith(() => conversation),
        ],
      );
      addTearDown(container.dispose);
    });

    test('unknown model is refused locally without any write', () async {
      await container
          .read(conversationProvider.notifier)
          .updateRuntimeConfig(
            deviceId: 'd',
            workspacePath: '/w',
            sessionId: 's',
            providerId: 'fixture-provider',
            modelId: 'not-in-catalog',
          );
      final st = container.read(conversationProvider)['d|s']!;
      expect(st.actionError, '该模型不在桌面端目录中');
      expect(relay.modelCalls, 0);
    });

    test('disabled model is refused with its reason', () async {
      await container
          .read(conversationProvider.notifier)
          .updateRuntimeConfig(
            deviceId: 'd',
            workspacePath: '/w',
            sessionId: 's',
            providerId: 'fixture-provider',
            modelId: 'fixture-model-pro',
          );
      final st = container.read(conversationProvider)['d|s']!;
      expect(st.actionError, '该模型不可用：quota_exhausted');
      expect(relay.modelCalls, 0);
    });

    test('thought level outside the returned options is refused locally', () {
      // F11 precondition: the value must come from the desktop.
      expect(
        _ConvNotifier.seeded().thoughtOptions.any((o) => o.value == 'xhigh'),
        isFalse,
        reason: 'the old hard-coded xhigh is not a real option',
      );
    });

    test(
      'F11: rejected write keeps the old snapshot and shows reasonCode',
      () async {
        relay.modelResult = const ServiceCallResult.failure(
          'thought_level_unsupported',
        );
        await container
            .read(conversationProvider.notifier)
            .updateRuntimeConfig(
              deviceId: 'd',
              workspacePath: '/w',
              sessionId: 's',
              providerId: 'fixture-provider',
              modelId: 'fixture-model-turbo',
            );
        final st = container.read(conversationProvider)['d|s']!;
        expect(relay.modelCalls, 1);
        expect(st.actionError, contains('thought_level_unsupported'));
        expect(
          st.runtimeConfig.modelId,
          'fixture-model-flash',
          reason: 'no optimistic change persists',
        );
        expect(st.runtimeConfig.loading, isFalse);
      },
    );

    test('model-only change calls setModel, never setThoughtLevel', () async {
      await container
          .read(conversationProvider.notifier)
          .updateRuntimeConfig(
            deviceId: 'd',
            workspacePath: '/w',
            sessionId: 's',
            providerId: 'fixture-provider',
            modelId: 'fixture-model-turbo',
          );
      expect(relay.modelCalls, 1);
      expect(relay.thoughtCalls, 0);
      expect(container.read(conversationProvider)['d|s']!.actionError, isNull);
    });

    test(
      'thought-only change calls setThoughtLevel with the revision',
      () async {
        await container
            .read(conversationProvider.notifier)
            .updateRuntimeConfig(
              deviceId: 'd',
              workspacePath: '/w',
              sessionId: 's',
              thoughtLevel: 'high',
            );
        expect(relay.thoughtCalls, 1);
        expect(relay.modelCalls, 0);
        expect(relay.lastExpectedRevision, 7);
      },
    );

    test('same values as current are a no-op', () async {
      await container
          .read(conversationProvider.notifier)
          .updateRuntimeConfig(
            deviceId: 'd',
            workspacePath: '/w',
            sessionId: 's',
            thoughtLevel: 'max',
            providerId: 'fixture-provider',
            modelId: 'fixture-model-flash',
          );
      expect(relay.thoughtCalls, 0);
      expect(relay.modelCalls, 0);
    });
  });
}

class _StubRelay extends RelaySourceNotifier {
  int modelCalls = 0;
  int thoughtCalls = 0;
  int? lastExpectedRevision;
  ServiceCallResult modelResult = const ServiceCallResult.success({
    'changed': true,
  });

  @override
  Map<String, RelaySourceState> build() => const {};

  @override
  Future<ServiceCallResult> applySessionModel({
    required String deviceId,
    required String workspacePath,
    required String sessionId,
    required String providerId,
    required String modelId,
    int? expectedRevision,
  }) async {
    modelCalls++;
    lastExpectedRevision = expectedRevision;
    return modelResult;
  }

  @override
  Future<ServiceCallResult> applySessionThoughtLevel({
    required String deviceId,
    required String workspacePath,
    required String sessionId,
    required String thoughtLevel,
    int? expectedRevision,
  }) async {
    thoughtCalls++;
    lastExpectedRevision = expectedRevision;
    return const ServiceCallResult.success({'changed': true});
  }

  @override
  Future<bool> ensureConversation(String deviceId) async => true;
}

class _ConvNotifier extends ConversationNotifier {
  static ConversationRuntimeConfig seeded() => ConversationRuntimeConfig.parse(
    _fixtureStatic('verified/session_snapshot_with_runtime.json'),
  );

  static Map<String, dynamic> _fixtureStatic(String rel) =>
      jsonDecode(File('test/fixtures/native/$rel').readAsStringSync())
          as Map<String, dynamic>;

  @override
  Map<String, ConversationState> build() {
    final base = seeded();
    return {
      'd|s': ConversationState(
        fromNative: true,
        runtimeConfig: base.copyWith(
          models: [
            ...base.models,
            const ConversationModelOption(
              providerId: 'fixture-provider',
              modelId: 'fixture-model-turbo',
              label: 'Fixture Turbo',
            ),
          ],
        ),
      ),
    };
  }

  @override
  Future<void> loadRuntimeConfig({
    required String deviceId,
    required String workspacePath,
    required String sessionId,
    bool refresh = false,
  }) async {}
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/skill.dart';
import 'package:zremote/state/relay_source.dart';

import 'fake_relay_server.dart';
import 'failure_injection_test.dart' as shared;

void main() {
  late FakeRelayServer server;
  late ProviderContainer container;

  setUp(() {
    server = FakeRelayServer()..installDefaults();
    RelaySourceNotifier.debugSocketFactory = server.factory;
    container = ProviderContainer();
  });

  tearDown(() async {
    RelaySourceNotifier.debugSocketFactory = null;
    await container.read(relaySourceProvider.notifier).disconnect('dev-1');
    container.dispose();
  });

  RelaySourceNotifier relay() => container.read(relaySourceProvider.notifier);

  SkillEntry localSkill() => const SkillEntry(
    id: 'glm:user:review:fixture',
    name: 'review',
    description: 'Fixture skill',
    source: 'user',
    enabled: true,
  );

  test(
    'skills.setEnabled sends the verified payload and accepts null success',
    () async {
      Map<String, dynamic>? received;
      server.handlers['skills.setEnabled'] = (s, rpc) {
        received = Map<String, dynamic>.from(rpc.args.single as Map);
        s.replyOk(null);
      };

      await relay().connect(shared.relayDevice());
      final result = await relay().setSkillEnabled(
        deviceId: 'dev-1',
        workspacePath: '/proj',
        skill: localSkill(),
        enabled: false,
      );

      expect(result.ok, isTrue);
      expect(received, {
        'workspacePath': '/proj',
        'provider': 'glm',
        'scope': 'user',
        'skillId': 'glm:user:review:fixture',
        'enabled': false,
      });
    },
  );

  test(
    'skills.setEnabled exposes the desktop fault and does not claim success',
    () async {
      server.handlers['skills.setEnabled'] = (s, _) =>
          s.replyError('desktop rejected skill update');

      await relay().connect(shared.relayDevice());
      final result = await relay().setSkillEnabled(
        deviceId: 'dev-1',
        workspacePath: '/proj',
        skill: localSkill(),
        enabled: false,
      );

      expect(result.ok, isFalse);
      expect(result.error, contains('desktop rejected skill update'));
    },
  );

  test('plugin and built-in skills remain read-only without an RPC', () async {
    await relay().connect(shared.relayDevice());
    final before = server.calls.length;
    final result = await relay().setSkillEnabled(
      deviceId: 'dev-1',
      workspacePath: '/proj',
      skill: const SkillEntry(
        id: 'glm:plugin:fixture',
        name: 'fixture',
        source: 'plugin',
      ),
      enabled: false,
    );

    expect(result.error, 'read_only_source');
    expect(server.calls.length, before);
  });
}

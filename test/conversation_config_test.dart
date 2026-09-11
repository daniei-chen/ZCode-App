import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/state/conversation_config.dart';

void main() {
  test('parses native session model, thought and context fields', () {
    final config = ConversationRuntimeConfig.parse({
      'revision': 8,
      'settings': {
        'model': {
          'current': {
            'providerId': 'zai',
            'modelId': 'glm-5',
            'displayName': 'GLM 5',
          },
        },
        'thoughtLevel': {'current': 'high'},
      },
      'modelCatalog': [
        {
          'providerId': 'zai',
          'models': [
            {'modelId': 'glm-5', 'displayName': 'GLM 5'},
            {'modelId': 'glm-4', 'displayName': 'GLM 4'},
          ],
        },
      ],
      'contextWindow': {
        'usedTokens': 1200,
        'maxTokens': 8000,
        'autoCompactThresholdTokens': 7000,
      },
    });

    expect(config.providerId, 'zai');
    expect(config.modelId, 'glm-5');
    expect(config.modelLabel, 'GLM 5');
    expect(config.thoughtLevel, 'high');
    expect(config.contextUsedTokens, 1200);
    expect(config.contextMaxTokens, 8000);
    expect(config.autoCompactThresholdTokens, 7000);
    expect(config.revision, 8);
    expect(config.models.map((m) => m.key), ['zai:glm-5', 'zai:glm-4']);
  });

  test('does not invent a model or context when the response is empty', () {
    final config = ConversationRuntimeConfig.parse({'status': 'ok'});
    expect(config.modelId, isNull);
    expect(config.thoughtLevel, isNull);
    expect(config.hasContext, isFalse);
    expect(config.models, isEmpty);
  });

  test(
    'parses token usage response without treating arbitrary quota as context',
    () {
      final config = ConversationRuntimeConfig.parse({
        'inputTokens': 300,
        'outputTokens': 100,
        'quota': 88,
        'contextUsage': {'used': 400, 'limit': 2000},
      });
      expect(config.contextUsedTokens, 400);
      expect(config.contextMaxTokens, 2000);
    },
  );
}

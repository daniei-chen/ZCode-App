import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/bridge_message_pipeline.dart';
import 'package:zremote/services/event_observer.dart';

void main() {
  group('BridgeMessagePipeline.decode', () {
    test('合法 JSON 解出 root', () {
      expect(BridgeMessagePipeline.decode('{"a":1}'), {'a': 1});
    });

    test('非法 JSON 返回 null（与旧 catch-continue 语义一致）', () {
      expect(BridgeMessagePipeline.decode('not-json'), isNull);
      expect(BridgeMessagePipeline.decode(''), isNull);
    });
  });

  group('BridgeMessagePipeline.parseRemoved（与旧三趟逐一等价）', () {
    final root = {
      'deltas': [
        {'op': 'session.removed', 'sessionId': 'sess_a'},
        {'op': 'task.removed', 'address': {'taskId': 'task_b'}},
        {
          'op': 'task.upserted',
          'task': {
            'address': {'taskId': 'task_c'},
            'membership': {'archived': true},
          },
        },
        {
          'op': 'task.upserted',
          'task': {'taskId': 'task_live', 'membership': {'archived': false}},
        },
        // 噪声：缺 id / 缺 address / 非法 op
        {'op': 'session.removed'},
        {'op': 'task.removed', 'address': 'not-a-map'},
        {'op': 'task.upserted', 'task': {'membership': {'archived': true}}},
        // meta 回退路径
        {
          'op': 'task.upserted',
          'task': {
            'meta': {'taskId': 'task_meta'},
            'membership': {'archived': true},
          },
        },
      ],
    };

    test('sessions / tasks / archived 三路与旧实现逐字段一致', () {
      final result = BridgeMessagePipeline.parseRemoved(root);
      expect(result.sessions, ['sess_a']);
      expect(result.tasks, ['task_b']);
      expect(result.archived, containsAll(['task_c', 'task_meta']));
      expect(result.archived, isNot(contains('task_live')));
    });

    test('对拍：合并单趟输出与旧三趟分别调用完全一致', () {
      final legacySessions = SessionStateExtractor.parseRemovedRoot(root);
      final legacyTasks = TaskIndexExtractor.parseRemovedRoot(root);
      final legacyArchived = TaskIndexExtractor.parseArchivedRoot(root);
      final merged = BridgeMessagePipeline.parseRemoved(root);
      expect(merged.sessions, legacySessions);
      expect(merged.tasks, legacyTasks);
      expect(merged.archived, legacyArchived);
    });

    test('空输入返回三个空列表', () {
      final r = BridgeMessagePipeline.parseRemoved(null);
      expect(r.sessions, isEmpty);
      expect(r.tasks, isEmpty);
      expect(r.archived, isEmpty);
    });
  });
}

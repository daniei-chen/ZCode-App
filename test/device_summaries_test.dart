import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/event_observer.dart';
import 'package:zremote/state/device_summaries.dart';
import 'package:zremote/state/relay_monitor.dart' show summaryOfTasks;

SessionState task(
  String id, {
  String? phase,
  int? at,
  int perm = 0,
  int input = 0,
  String? title,
}) => SessionState(
  sessionId: id,
  title: title,
  phase: phase,
  permissionCount: perm,
  userInputCount: input,
  lastActivityAt: at,
);

void main() {
  test('等待审批优先于一切（工作台红点语义）', () {
    final s = summaryOfTasks([
      task('a', phase: 'running', at: 100, title: '长任务'),
      task('b', phase: 'running', at: 50, perm: 1, title: '待审批'),
    ]);
    expect(s['phase'], 'pending');
    expect(s['pending'], isTrue);
    expect(s['title'], '待审批');
  });

  test('无待办时取最近活跃任务的三态', () {
    final s = summaryOfTasks([
      task('old', phase: 'completedSuccess', at: 10, title: '旧任务'),
      task('new', phase: 'error', at: 99, title: '新任务'),
    ]);
    expect(s['phase'], 'error');
    expect(s['title'], '新任务');
    expect(s['pending'], isFalse);

    final s2 = summaryOfTasks([task('r', phase: 'running', at: 5)]);
    expect(s2['phase'], 'running');
  });

  test('completedInterrupted 也算完成态；空列表给空摘要', () {
    final s = summaryOfTasks([
      task('x', phase: 'completedInterrupted', at: 1, title: '被打断'),
    ]);
    expect(s['phase'], 'completed');
    expect(summaryOfTasks(const []), isEmpty);
  });

  test('taskLineOf：四态映射 + 无摘要返回 null', () {
    expect(taskLineOf({'phase': 'pending', 'title': 't'}), ('pending', 't'));
    expect(taskLineOf({'phase': 'running', 'title': 't'}), ('running', 't'));
    expect(taskLineOf(null), (null, ''));
    expect(taskLineOf(const {}), (null, ''));
    expect(taskLineOf({'phase': 'weird'}), (null, ''));
  });

  group('freshnessOf（v1.8.4 摘要新鲜度）', () {
    Map<String, Object?> at(Duration ago) => {
          'phase': 'running',
          'title': 't',
          'updatedAt': DateTime.now().subtract(ago).millisecondsSinceEpoch,
        };

    test('60 秒内显示"刚刚"', () {
      expect(freshnessOf(at(const Duration(seconds: 5))), '刚刚');
    });

    test('分钟与小时分档', () {
      expect(freshnessOf(at(const Duration(minutes: 3))), '3 分钟前');
      expect(freshnessOf(at(const Duration(hours: 2))), '2 小时前');
      expect(freshnessOf(at(const Duration(days: 3))), '3 天前');
    });

    test('缺 updatedAt 或空摘要返回空串（不显示噪声）', () {
      expect(freshnessOf(null), '');
      expect(freshnessOf(const {}), '');
      expect(freshnessOf(const {'phase': 'running'}), '');
    });

    test('时钟回拨（未来时间）按"刚刚"处理', () {
      expect(
        freshnessOf({
          'updatedAt':
              DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch,
        }),
        '刚刚',
      );
    });
  });
}

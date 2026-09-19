import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/event_observer.dart';
import 'package:zremote/state/event_feed.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  ObservedEvent ev(
    String type, {
    String? summary,
    String? taskId,
    int? pendingTotal,
  }) => ObservedEvent(
    type: type,
    summary: summary,
    taskId: taskId,
    pendingTotal: pendingTotal,
  );

  group('EventFeedNotifier', () {
    test('白名单事件计数 +1', () {
      final notifier = container.read(eventFeedProvider.notifier);
      notifier.ingest('d1', ev('completed', summary: '修复登录页'));
      notifier.ingest('d1', ev('error'));

      final feed = container.read(eventFeedProvider)['d1'];
      expect(feed?.unread, 2);
      expect(feed?.lastSummary, 'error');
    });

    test('status/meta 类高频事件不计入（防徽标风暴）', () {
      final notifier = container.read(eventFeedProvider.notifier);
      notifier.ingest('d1', ev('streaming'));
      notifier.ingest('d1', ev('updated'));
      notifier.ingest('d1', ev('tool_call_update'));

      expect(container.read(eventFeedProvider).containsKey('d1'), isFalse);
    });

    test('permission_request 置 permPending', () {
      final notifier = container.read(eventFeedProvider.notifier);
      notifier.ingest('d1', ev('permission_request', summary: 'npm install'));

      final feed = container.read(eventFeedProvider)['d1'];
      expect(feed?.unread, 1);
      expect(feed?.permPending, isTrue);
      expect(feed?.lastSummary, 'npm install');
    });

    test('普通事件不置 permPending', () {
      final notifier = container.read(eventFeedProvider.notifier);
      notifier.ingest('d1', ev('completed'));
      expect(container.read(eventFeedProvider)['d1']?.permPending, isFalse);
    });

    test('clear 清零（看了即清）', () {
      final notifier = container.read(eventFeedProvider.notifier);
      notifier.ingest('d1', ev('permission_request'));
      notifier.clear('d1');
      expect(container.read(eventFeedProvider).containsKey('d1'), isFalse);
    });

    test('markRead 进入设备后清未读，但保留待审批状态', () {
      final notifier = container.read(eventFeedProvider.notifier);
      notifier.ingest('d1', ev('permission_request'));
      notifier.ingest('d1', ev('completed'));
      notifier.markRead('d1');

      final feed = container.read(eventFeedProvider)['d1'];
      expect(feed?.unread, 0);
      expect(feed?.permPending, isTrue);
    });

    test('forget 移除条目；多设备互不影响', () {
      final notifier = container.read(eventFeedProvider.notifier);
      notifier.ingest('d1', ev('error'));
      notifier.ingest('d2', ev('error'));
      notifier.forget('d1');

      final state = container.read(eventFeedProvider);
      expect(state.containsKey('d1'), isFalse);
      expect(state['d2']?.unread, 1);
    });

    test('resolved 清审批红旗，未读数不动（历史是历史）', () {
      final notifier = container.read(eventFeedProvider.notifier);
      notifier.ingest('d1', ev('permission_request', summary: 'npm install'));
      notifier.ingest('d1', ev('completed'));
      notifier.ingest('d1', ev('resolved', taskId: 'sess_b'));

      final feed = container.read(eventFeedProvider)['d1'];
      expect(feed?.unread, 2, reason: 'resolved 不计入未读');
      expect(feed?.permPending, isFalse, reason: '待办已解决，红旗必须落下');
      expect(feed?.lastSummary, 'completed', reason: 'resolved 不覆盖摘要');
    });

    test('resolved 在空 feed 上 no-op（不建条目）', () {
      final notifier = container.read(eventFeedProvider.notifier);
      notifier.ingest('d1', ev('resolved'));
      expect(container.read(eventFeedProvider).containsKey('d1'), isFalse);
    });

    test('两个任务同时待批：解决一个不得清掉另一个（F11）', () {
      final notifier = container.read(eventFeedProvider.notifier);
      notifier.ingest('d1', ev('permission_request', summary: 'A', taskId: 'a'));
      notifier.ingest('d1', ev('permission_request', summary: 'B', taskId: 'b'));
      expect(container.read(eventFeedProvider)['d1']?.pendingByTask, {
        'a': 1,
        'b': 1,
      });

      notifier.ingest('d1', ev('resolved', taskId: 'a'));
      expect(
        container.read(eventFeedProvider)['d1']?.permPending,
        isTrue,
        reason: 'B 仍在等待批准，红点必须保留',
      );

      notifier.ingest('d1', ev('resolved', taskId: 'b'));
      expect(
        container.read(eventFeedProvider)['d1']?.permPending,
        isFalse,
        reason: '两个都解决了才落下红点',
      );
    });

    test('补充输入类交互同样点亮红点，并按任务消除（F11）', () {
      final notifier = container.read(eventFeedProvider.notifier);
      notifier.ingest('d1', ev('elicitation_request', taskId: 't1'));
      expect(container.read(eventFeedProvider)['d1']?.permPending, isTrue);
      notifier.ingest('d1', ev('resolved', taskId: 't1'));
      expect(container.read(eventFeedProvider)['d1']?.permPending, isFalse);
    });

    // R-19：观察面没有请求级 id，只有按任务聚合的计数——pending 按计数降级
    // 记账。下面几条钉住"同任务多条交互，解决一条不清红点"的口径。
    group('R-19 同任务多条交互按计数记账', () {
      test('同任务审批+输入并存：审批解决（剩余 1）红点保留，输入解决才落下', () {
        final notifier = container.read(eventFeedProvider.notifier);
        notifier.ingest(
          'd1',
          ev('permission_request', taskId: 't', pendingTotal: 1),
        );
        notifier.ingest(
          'd1',
          ev('elicitation_request', taskId: 't', pendingTotal: 2),
        );
        expect(container.read(eventFeedProvider)['d1']?.pendingByTask, {
          't': 2,
        });

        // 审批那条解决：differ 发 resolved，但 userInput 仍剩 1。
        notifier.ingest('d1', ev('resolved', taskId: 't', pendingTotal: 1));
        final mid = container.read(eventFeedProvider)['d1'];
        expect(mid?.permPending, isTrue, reason: '输入请求还在等，红点不能落');
        expect(mid?.pendingByTask, {'t': 1}, reason: '刷新为权威剩余量');

        notifier.ingest('d1', ev('resolved', taskId: 't', pendingTotal: 0));
        expect(
          container.read(eventFeedProvider)['d1']?.permPending,
          isFalse,
          reason: '剩余归零才落下',
        );
      });

      test('计数直接采信：请求事件带 pendingTotal=2 记 2，不按条数累加', () {
        final notifier = container.read(eventFeedProvider.notifier);
        notifier.ingest(
          'd1',
          ev('permission_request', taskId: 't', pendingTotal: 2),
        );
        expect(container.read(eventFeedProvider)['d1']?.pendingByTask, {
          't': 2,
        });
      });

      test('resolved 带正计数但条目缺失（基线晚建）：补上红点而不是忽略', () {
        final notifier = container.read(eventFeedProvider.notifier);
        notifier.ingest('d1', ev('completed', taskId: 'x'));
        notifier.ingest('d1', ev('resolved', taskId: 't', pendingTotal: 1));
        expect(container.read(eventFeedProvider)['d1']?.pendingByTask, {
          't': 1,
        });
      });

      test('缺计数的 resolved 维持旧语义：按任务整条清除（任务整行消失）', () {
        final notifier = container.read(eventFeedProvider.notifier);
        notifier.ingest(
          'd1',
          ev('permission_request', taskId: 't', pendingTotal: 3),
        );
        notifier.ingest('d1', ev('resolved', taskId: 't'));
        expect(container.read(eventFeedProvider)['d1']?.permPending, isFalse);
      });

      test('显式页面事件（无计数）只保证在场，不覆盖已有权威计数', () {
        final notifier = container.read(eventFeedProvider.notifier);
        notifier.ingest(
          'd1',
          ev('permission_request', taskId: 't', pendingTotal: 2),
        );
        notifier.ingest('d1', ev('permission_request', taskId: 't'));
        expect(
          container.read(eventFeedProvider)['d1']?.pendingByTask,
          {'t': 2},
          reason: '无计数事件不能把 2 改写成 1',
        );
      });

      test('resolved 带正计数且与现值相同：不发状态更新（防无意义重建）', () {
        final notifier = container.read(eventFeedProvider.notifier);
        notifier.ingest(
          'd1',
          ev('permission_request', taskId: 't', pendingTotal: 1),
        );
        final before = container.read(eventFeedProvider);
        notifier.ingest('d1', ev('resolved', taskId: 't', pendingTotal: 1));
        expect(identical(container.read(eventFeedProvider), before), isTrue);
      });

      test('resolved 无 taskId：只清 unknown 占位键，其他任务键保留（绝不整设备清空）', () {
        final notifier = container.read(eventFeedProvider.notifier);
        notifier.ingest(
          'd1',
          ev('permission_request', taskId: 'a', pendingTotal: 1),
        );
        notifier.ingest('d1', ev('permission_request'));
        expect(container.read(eventFeedProvider)['d1']?.pendingByTask, {
          'a': 1,
          'unknown': 1,
        });
        notifier.ingest('d1', ev('resolved'));
        expect(container.read(eventFeedProvider)['d1']?.pendingByTask, {
          'a': 1,
        });
      });

      test('已挂起 1，新到带计数的请求事件写 2（计数上调直接采信）', () {
        final notifier = container.read(eventFeedProvider.notifier);
        notifier.ingest(
          'd1',
          ev('permission_request', taskId: 't', pendingTotal: 1),
        );
        notifier.ingest(
          'd1',
          ev('elicitation_request', taskId: 't', pendingTotal: 2),
        );
        expect(container.read(eventFeedProvider)['d1']?.pendingByTask, {
          't': 2,
        });
      });
    });
  });
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/event_observer.dart';
import 'package:zremote/state/event_feed.dart';
import 'package:zremote/state/event_history.dart';
import 'package:zremote/state/pending_session_jump.dart';
import 'package:zremote/state/session_pool.dart';
import 'package:zremote/ui/manage_page.dart';
import 'package:zremote/ui/pending_center_sheet.dart';

/// 待处理中心（升级路线图）：等待处理 + 最近事件 + 点按跳转。
RemoteDevice _device(String sid, String label) => RemoteDevice(
  id: 'id-$sid',
  baseUrl: 'https://zcode.z.ai/remote/v4',
  params: {'sid': sid, 'hash': 'h'},
  label: label,
  createdAt: DateTime(2026, 1, 1),
);

ProviderContainer _container(List<RemoteDevice> devices) {
  final container = ProviderContainer(
    overrides: [deviceListProvider.overrideWith(() => DeviceListNotifier(seed: devices))],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpHost(WidgetTester tester, ProviderContainer container) {
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => PendingCenterSheet.show(ctx),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('空状态：无待处理与历史时显示提示', (tester) async {
    final container = _container([_device('a', '设备A')]);
    await _pumpHost(tester, container);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('待处理中心'), findsOneWidget);
    expect(find.text('暂无待处理与最近事件'), findsOneWidget);
  });

  testWidgets('等待处理：设备行 + 计数求和 + 红点', (tester) async {
    final container = _container([_device('a', '设备A'), _device('b', '设备B')]);
    final feed = container.read(eventFeedProvider.notifier);
    feed.ingest('id-a', const ObservedEvent(type: 'permission_request', taskId: 't1', pendingTotal: 2));
    feed.ingest('id-a', const ObservedEvent(type: 'elicitation_request', taskId: 't2', pendingTotal: 1));
    feed.ingest('id-b', const ObservedEvent(type: 'permission_request', taskId: 't3', pendingTotal: 5));
    feed.markRead('id-a'); // 已读不清待批准（W-032 语义）

    await _pumpHost(tester, container);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('等待处理'), findsOneWidget);
    expect(find.text('设备A'), findsOneWidget);
    expect(find.text('3 项待处理'), findsOneWidget); // 2+1 求和
    expect(find.text('设备B'), findsOneWidget);
    expect(find.text('5 项待处理'), findsOneWidget);
  });

  testWidgets('最近事件：类型标签 + 摘要 + 相对时间（刚刚）', (tester) async {
    final container = _container([_device('a', '设备A')]);
    container.read(eventHistoryProvider.notifier).record(
      'id-a',
      const ObservedEvent(type: 'permission_request', taskId: 't1', summary: 'npm install'),
    );
    await _pumpHost(tester, container);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('最近事件'), findsOneWidget);
    expect(find.textContaining('待批准 · npm install'), findsOneWidget);
    expect(find.text('刚刚'), findsOneWidget);
  });

  testWidgets('点按等待行：切到该设备 + 设置会话跳转 + 关闭面板', (tester) async {
    final container = _container([_device('a', '设备A'), _device('b', '设备B')]);
    container.read(eventFeedProvider.notifier).ingest(
      'id-b',
      const ObservedEvent(type: 'permission_request', taskId: 'task-9', pendingTotal: 1),
    );
    container.read(eventHistoryProvider.notifier).record(
      'id-b',
      const ObservedEvent(type: 'permission_request', taskId: 'task-9', summary: '等你批准'),
    );

    await _pumpHost(tester, container);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // 设备名在等待行与历史分组头各出现一次 → 点唯一的计数文本（在等待行内）。
    await tester.tap(find.text('1 项待处理'));
    await tester.pumpAndSettle();

    expect(container.read(activeTabProvider), 1, reason: '切到设备B（索引 1）');
    final jump = container.read(pendingSessionJumpProvider);
    expect(jump?.deviceId, 'id-b');
    expect(jump?.sessionId, 'task-9');
    expect(find.text('待处理中心'), findsNothing, reason: '面板已关闭');
  });

  testWidgets('等待行历史无命中时用 feed 权威键兜底跳转（iter16：点按不再原地）', (tester) async {
    final container = _container([_device('a', '设备A')]);
    container.read(eventFeedProvider.notifier).ingest(
      'id-a',
      const ObservedEvent(type: 'permission_request', taskId: 'task-9', pendingTotal: 1),
    );
    // 历史里只有更早的完成事件（模拟审批请求条目被 50 条上限挤出历史）。
    container.read(eventHistoryProvider.notifier).record(
      'id-a',
      const ObservedEvent(type: 'completed', taskId: 'task-old'),
    );

    await _pumpHost(tester, container);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 项待处理'));
    await tester.pumpAndSettle();

    final jump = container.read(pendingSessionJumpProvider);
    expect(jump?.deviceId, 'id-a');
    expect(
      jump?.sessionId,
      'task-9',
      reason: '仍在该设备 pendingByTask 里的权威键必须成为兜底目标',
    );
  });

  testWidgets('设备列表入口：有待批准时显示红点，点按打开面板', (tester) async {
    final container = _container([_device('a', '设备A')]);
    container.read(eventFeedProvider.notifier).ingest(
      'id-a',
      const ObservedEvent(type: 'permission_request', taskId: 't1', pendingTotal: 1),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: const ManagePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.notifications_outlined), findsOneWidget);
    final entryButton = find.ancestor(
      of: find.byIcon(Icons.notifications_outlined),
      matching: find.byType(IconButton),
    );
    expect(
      find.descendant(of: entryButton, matching: find.byType(Container)),
      findsOneWidget,
      reason: '有待批准时入口带红点（permPending 驱动，与 W-032 同口径）',
    );
    await tester.tap(find.byIcon(Icons.notifications_outlined));
    await tester.pumpAndSettle();
    expect(find.text('待处理中心'), findsOneWidget);
    expect(find.text('1 项待处理'), findsOneWidget);
  });
  test('源码钉：AppShell 对跳转请求揭启动器盖板（复核 F1）', () {
    final src = File('lib/ui/app_shell.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final listener = RegExp(
      r'ref\.listen\(pendingSessionJumpProvider,',
    );
    expect(listener.allMatches(src).length, 1, reason: '恰好一处跳转监听');
    // 断言两行序列（文件别处也有同名单行 _setLauncherVisible，contains 单行会误配）。
    expect(
      src.contains(
        'ref.listen(pendingSessionJumpProvider, (_, next) {\n'
        '      if (next == null) return;\n'
        '      if (_launcherVisible && mounted) {',
      ),
      isTrue,
      reason: '跳转到达即揭盖（activeTab 同值不发射的死路）',
    );
  });
}

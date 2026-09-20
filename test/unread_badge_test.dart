import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/state/event_feed.dart';
import 'package:zremote/theme.dart';
import 'package:zremote/ui/unread_badge.dart';

/// W-032（iter14，升级路线图 top1）：未读数与「待批准」语义分离。
/// 旧实现 unread<=0 时徽标整体隐身——打开设备 markRead 后仍在等待的
/// 审批红点被一并抹掉；现在仅剩待批准时红点常显（无数字）。
Future<void> pumpBadge(WidgetTester tester, DeviceFeed? feed) {
  return tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: Builder(builder: (context) => UnreadBadge(feed: feed)),
        ),
      ),
    ),
  );
}

BoxDecoration badgeDecoration(WidgetTester tester, Finder anchor) {
  final container = tester.widget<Container>(
    find.ancestor(of: anchor, matching: find.byType(Container)).first,
  );
  return container.decoration! as BoxDecoration;
}

void main() {
  testWidgets('有未读且待批准：显示计数，危险色', (tester) async {
    await pumpBadge(
      tester,
      const DeviceFeed(unread: 3, pendingByTask: {'t1': 1}),
    );
    expect(find.text('3'), findsOneWidget);
    final ctx = tester.element(find.text('3'));
    expect(
      badgeDecoration(tester, find.text('3')).color,
      ctx.zt.danger,
      reason: '待批准时徽标用危险色',
    );
  });

  testWidgets('有未读、无待批准：计数正常色（accent）', (tester) async {
    await pumpBadge(tester, const DeviceFeed(unread: 2));
    expect(find.text('2'), findsOneWidget);
    final ctx = tester.element(find.text('2'));
    expect(badgeDecoration(tester, find.text('2')).color, ctx.zt.accent);
  });

  testWidgets('已读但待批准：红点常显（无数字）', (tester) async {
    await pumpBadge(
      tester,
      const DeviceFeed(unread: 0, pendingByTask: {'t1': 1}),
    );
    expect(find.text('0'), findsNothing);
    final dot = find.bySemanticsLabel('有待批准的请求');
    expect(dot, findsOneWidget);
    final ctx = tester.element(dot);
    // Semantics 是圆点的父节点：从它往下找 Container（与计数徽标方向相反）。
    final deco = tester
        .widget<Container>(find.descendant(of: dot, matching: find.byType(Container)))
        .decoration! as BoxDecoration;
    expect(deco.color, ctx.zt.danger, reason: '红点用危险色');
    expect(deco.shape, BoxShape.circle, reason: '红点是圆点（区别于计数胶囊）');
  });

  testWidgets('已读且无待批准：不渲染任何指示', (tester) async {
    await pumpBadge(tester, const DeviceFeed(unread: 0));
    expect(find.bySemanticsLabel('有待批准的请求'), findsNothing);
    expect(find.byType(Container), findsNothing);
  });

  testWidgets('99+ 封顶', (tester) async {
    await pumpBadge(tester, const DeviceFeed(unread: 150));
    expect(find.text('99+'), findsOneWidget);
  });

  testWidgets('feed 为 null：不渲染', (tester) async {
    await pumpBadge(tester, null);
    expect(find.byType(Container), findsNothing);
  });
}

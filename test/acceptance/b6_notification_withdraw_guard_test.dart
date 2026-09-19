import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 独立验收（2026-09-18）对 B6 / T-03"通知撤销条件"的回退即失败守卫。
///
/// B6 不变量：resolved 只证明"有一项解决了"——该任务还有剩余交互
/// （pendingTotal > 0）时**不得**撤系统通知；仅在计数证明无剩余
/// （<= 0）或缺计数（按 0，维持旧行为）时才撤。
///
/// 被测路径位于 `WebViewSyncController`（需要 WidgetRef/BuildContext 与
/// 通知平台通道），行为级单测不可行（见 docs/audits/2026-09-16-acceptance-R19.md
/// 对 `flutter_local_notifications` 单测环境限制的记录），故沿用仓库既有的
/// source-invariant 风格（同 security_invariants_test）把条件钉在源码上：
/// 改坏条件（如 `<= 0` → 无条件 / `<= -1`）即失败。
void main() {
  final source = File('lib/services/webview_sync.dart').readAsStringSync();

  test('B6：撤销条件钉死为"无剩余才撤"（(pendingTotal ?? 0) <= 0）', () {
    final guard = "if (taskId != null && (enriched.pendingTotal ?? 0) <= 0) {";
    final count = guard.allMatches(source).length;
    expect(count, 1, reason: 'B6 撤销条件必须存在且唯一——删条件或改阈值都是回归');
  });

  test('B6：cancelPending 只出现在 resolved 分支且受守卫约束（不撤错还活着的提醒）', () {
    final resolvedBranch = source.indexOf("enriched.type == 'resolved'");
    expect(resolvedBranch, greaterThanOrEqualTo(0), reason: 'resolved 分支必须存在');

    final guard =
        source.indexOf('(enriched.pendingTotal ?? 0) <= 0', resolvedBranch);
    expect(guard, greaterThan(resolvedBranch), reason: '守卫必须在 resolved 分支内');

    final call = source.indexOf(
      'NotifierService.instance.cancelPending(device, taskId)',
      guard,
    );
    expect(call, greaterThan(guard), reason: '撤销调用必须受"无剩余才撤"守卫约束');
    expect(
      call - guard,
      lessThan(200),
      reason: '守卫与调用之间不得插入会绕过守卫的代码',
    );
    expect(
      source.indexOf('cancelPending', resolvedBranch),
      source.indexOf('cancelPending', guard),
      reason: 'resolved 分支内不得有第二个不受同一守卫约束的撤销点',
    );
  });

  test('B6：缺计数按未知维持旧行为（撤回）——?? 0 缺省不得被删', () {
    expect(
      source.contains('(enriched.pendingTotal ?? 0) <= 0'),
      isTrue,
      reason: '守卫文本（含 ?? 0 缺省）任何改写都是对成文兜底语义的回归',
    );
  });
}

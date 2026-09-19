import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/biometric.dart';
import 'package:zremote/services/page_refresh_policy.dart';

/// ITERATION 13 加固批（W-030）：远控页静默刷新的"不可见时长"从墙钟单钟
/// 改为单调+墙钟成对记录，读取处复用 [BiometricService.relockEvidence]
/// 取大（main.dart relock 双钟同款先例）。逐条"回退即失败"钉住：
/// 深睡（单调冻结）与回拨（墙钟差为负）两类失真都必须 fail-closed。
void main() {
  group('W-030：relockEvidence 驱动静默刷新的双钟证据', () {
    test('深睡场景：单调钟冻结、墙钟差大 → 取墙钟并触发静默刷新', () {
      final now = DateTime(2026, 9, 20, 10);
      // 深睡：页面隐藏后设备休眠 45min，Stopwatch 冻结在睡前值（30s）。
      // 旧单调单钟算出 30s（<staleAfter，不刷→陈旧缓存）；双钟取大取墙钟。
      final evidence = BiometricService.relockEvidence(
        monotonic: const Duration(seconds: 30),
        wallSince: now.subtract(const Duration(minutes: 45)),
        now: now,
      );
      expect(evidence, const Duration(minutes: 45),
          reason: '墙钟差 > 冻结的单调时长 → 必须取墙钟（W-030）');
      expect(
        PageRefreshPolicy.shouldRefreshOnVisible(
          hiddenFor: evidence,
          isCurrentDevice: true,
          loadInFlight: false,
          failed: false,
        ),
        isTrue,
        reason: '深睡后回到页面不得继续展示陈旧缓存（W-030）',
      );
    });

    test('回拨场景：墙钟差为负 → 取单调并触发静默刷新', () {
      final now = DateTime(2026, 9, 20, 10);
      // 回拨：墙钟被拨回 1h，"隐藏时刻"落在未来，差值为负；单调钟真实走了
      // 5min。旧墙钟单钟算出负时长 → 永不刷新；双钟取大回落到单调。
      final evidence = BiometricService.relockEvidence(
        monotonic: const Duration(minutes: 5),
        wallSince: now.add(const Duration(hours: 1)),
        now: now,
      );
      expect(evidence, const Duration(minutes: 5),
          reason: '墙钟差为负 → 必须回落到单调时长（W-030）');
      expect(
        PageRefreshPolicy.shouldRefreshOnVisible(
          hiddenFor: evidence,
          isCurrentDevice: true,
          loadInFlight: false,
          failed: false,
        ),
        isTrue,
        reason: '回拨不得把刷新判定"续期"到永不刷新（W-030）',
      );
    });
  });

  group('源码钉：_hiddenFor/_hiddenSinceWall 成对状态机（official_remote_page 无 WebView 测试环境）', () {
    final src = File('lib/ui/official_remote_page.dart').readAsStringSync();
    int count(String needle) => src.split(needle).length - 1;

    test('W-030：_hiddenFor 与 _hiddenSinceWall 成对出现，读取走 relockEvidence', () {
      final forCount = count('_hiddenFor');
      final wallCount = count('_hiddenSinceWall');
      expect(forCount, greaterThan(0), reason: '单调字段应存在（W-030）');
      expect(wallCount, forCount,
          reason: '声明/置位/读取/清空必须成对出现——单边丢失即退化为单钟（W-030）');
      expect(count('_hiddenFor ??= (Stopwatch()..start());'), 2,
          reason: '盖板与生命周期两条置位路径都要起单调表（W-030）');
      expect(count('_hiddenSinceWall ??= DateTime.now();'), 2,
          reason: '两条置位路径都要记墙钟起点（W-030）');
      expect(count('_hiddenFor = null;'), 1, reason: '清空点唯一');
      expect(count('_hiddenSinceWall = null;'), 1, reason: '清空点唯一');
      expect(src.contains('BiometricService.relockEvidence('), isTrue,
          reason: '读取处必须用双钟取大，不得退回单钟差值（W-030）');
    });

    test('W-030：旧单字段 _hiddenSince 不再存在（防回退墙钟单钟）', () {
      expect(
        RegExp('_hiddenSince(?!Wall)').hasMatch(src),
        isFalse,
        reason: '旧墙钟单字段必须移除；_hiddenSinceWall 不算命中（W-030）',
      );
    });
  });
}

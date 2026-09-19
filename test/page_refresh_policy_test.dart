import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/page_refresh_policy.dart';

/// W-017 打开页面静默刷新：纯策略的阈值边界与守卫。
void main() {
  bool refresh({Duration? hiddenFor, bool current = true, bool loading = false, bool failed = false}) =>
      PageRefreshPolicy.shouldRefreshOnVisible(
        hiddenFor: hiddenFor,
        isCurrentDevice: current,
        loadInFlight: loading,
        failed: failed,
      );

  group('PageRefreshPolicy', () {
    test('不可见满 staleAfter 才刷新：59 秒不刷，60 秒整刷', () {
      expect(
        refresh(hiddenFor: PageRefreshPolicy.staleAfter - const Duration(seconds: 1)),
        isFalse,
      );
      expect(refresh(hiddenFor: PageRefreshPolicy.staleAfter), isTrue);
    });

    test('从未隐藏（null）不刷新', () {
      expect(refresh(hiddenFor: null), isFalse,
          reason: '同帧内的揭开/快速来回不得触发整页重载');
    });

    test('长时间不可见必刷', () {
      expect(refresh(hiddenFor: const Duration(hours: 12)), isTrue,
          reason: '用户反馈的核心场景：放置半天回来不能还是旧缓存');
    });

    test('非当前设备页永不刷新（揭启动器盖板是全体解盖，iter6 F-1）', () {
      expect(
        refresh(hiddenFor: const Duration(hours: 12), current: false),
        isFalse,
        reason: '不收敛到当前页的话，N 台设备会同时整页重载 N 次',
      );
    });

    test('加载在途 / 错误卡不抢各自恢复路径', () {
      expect(refresh(hiddenFor: const Duration(hours: 12), loading: true), isFalse);
      expect(refresh(hiddenFor: const Duration(hours: 12), failed: true), isFalse);
    });
  });
}

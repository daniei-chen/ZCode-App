import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/relay/relay_monitor.dart';
import 'package:zremote/state/connection_status.dart';

void main() {
  group('ConnectionPolicy', () {
    test('任一来源活着就算在线', () {
      final now = DateTime(2026, 10, 25, 12);
      expect(
        ConnectionPolicy.isLive(
          webviewOpen: true,
          monitorPaired: false,
          lastAliveAt: null,
          now: now,
        ),
        isTrue,
      );
      expect(
        ConnectionPolicy.isLive(
          webviewOpen: false,
          monitorPaired: true,
          lastAliveAt: null,
          now: now,
        ),
        isTrue,
      );
    });

    test('双源沉寂：宽限期内在线，超宽限判断连', () {
      final now = DateTime(2026, 10, 25, 12);
      final lastAlive = now.subtract(const Duration(seconds: 44));
      expect(
        ConnectionPolicy.isLive(
          webviewOpen: false,
          monitorPaired: false,
          lastAliveAt: lastAlive,
          now: now,
        ),
        isTrue,
      );
      final stale = now.subtract(ConnectionPolicy.grace);
      expect(
        ConnectionPolicy.isLive(
          webviewOpen: false,
          monitorPaired: false,
          lastAliveAt: stale,
          now: now,
        ),
        isFalse,
      );
    });

    test('从未有过生命迹象（无 lastAliveAt）不算在线', () {
      expect(
        ConnectionPolicy.isLive(
          webviewOpen: false,
          monitorPaired: false,
          lastAliveAt: null,
          now: DateTime(2026, 10, 25, 12),
        ),
        isFalse,
      );
    });
  });

  group('ConnectionStatusNotifier', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
      addTearDown(container.dispose);
    });

    test('monitor 配对 → 在线；断开 + 宽限超时 → 离线', () {
      final notifier = container.read(connectionStatusProvider.notifier);
      notifier.reportMonitor('dev1', RelayMonitorState.paired);
      expect(notifier.isLive('dev1'), isTrue);

      notifier.reportMonitor('dev1', RelayMonitorState.disconnected);
      // 刚断开：lastAliveAt 还在宽限期内，不算断连（吸收重连抖动）。
      expect(notifier.isLive('dev1'), isTrue);

      // 手动把生命迹象拨到宽限之外（模拟长时间沉寂）。
      container
          .read(connectionStatusProvider)['dev1']!
          .lastAliveAt = DateTime.now().subtract(ConnectionPolicy.grace);
      expect(notifier.isLive('dev1'), isFalse);
    });

    test('webview socket 开关反映到在线状态', () {
      final notifier = container.read(connectionStatusProvider.notifier);
      notifier.reportWebview('dev1', open: true);
      expect(notifier.isLive('dev1'), isTrue);
      notifier.reportWebview('dev1', open: false);
      // 关闭后仍在宽限期内。
      expect(notifier.isLive('dev1'), isTrue);
      container
          .read(connectionStatusProvider)['dev1']!
          .lastAliveAt = DateTime.now().subtract(ConnectionPolicy.grace);
      expect(notifier.isLive('dev1'), isFalse);
    });

    test('liveState：无信号返回 null（乐观展示），有信号按宽限判定', () {
      final notifier = container.read(connectionStatusProvider.notifier);
      expect(notifier.liveState('devX'), isNull);
      notifier.markAlive('devX', LinkSignal.monitor);
      expect(notifier.liveState('devX'), isTrue);
    });

    test('markAlive(monitor) 隐含配对成立', () {
      final notifier = container.read(connectionStatusProvider.notifier);
      notifier.markAlive('dev1', LinkSignal.monitor);
      expect(container.read(connectionStatusProvider)['dev1']!.monitorPaired,
          isTrue);
    });

    test('forget 清掉踪迹与提醒状态', () {
      final notifier = container.read(connectionStatusProvider.notifier);
      notifier.reportMonitor('dev1', RelayMonitorState.paired);
      notifier.forget('dev1');
      expect(container.read(connectionStatusProvider).containsKey('dev1'),
          isFalse);
      expect(notifier.isLive('dev1'), isFalse);
    });

    test('forgetMonitor 只清 monitor 侧标记，保留 webview 状态', () {
      final notifier = container.read(connectionStatusProvider.notifier);
      notifier.reportWebview('dev1', open: true);
      notifier.reportMonitor('dev1', RelayMonitorState.paired);
      notifier.forgetMonitor('dev1');
      final track = container.read(connectionStatusProvider)['dev1']!;
      expect(track.monitorPaired, isFalse);
      expect(track.webviewOpen, isTrue);
    });
  });
}

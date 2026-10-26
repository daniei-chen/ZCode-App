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

    test('让路/交接期不算断连（v1.7.2 假断连修复）', () {
      final now = DateTime(2026, 10, 25, 12);
      final stale = now.subtract(const Duration(minutes: 5));
      // 沉寂远超宽限，但处于交接窗口 → 仍算在线（不发假断连）。
      expect(
        ConnectionPolicy.isLive(
          webviewOpen: false,
          monitorPaired: false,
          lastAliveAt: stale,
          now: now,
          handoff: true,
        ),
        isTrue,
      );
      // 交接结束后同一条踪迹如实判离线。
      expect(
        ConnectionPolicy.isLive(
          webviewOpen: false,
          monitorPaired: false,
          lastAliveAt: stale,
          now: now,
          handoff: false,
        ),
        isFalse,
      );
    });

    test('交接豁免有上限：超过 handoffCap 如实报离线（v1.7.2）', () {
      final now = DateTime(2026, 10, 25, 12);
      final stale = now.subtract(const Duration(minutes: 10));
      final track = DeviceLinkTrack()
        ..handoff = true
        ..handoffSince = now.subtract(ConnectionPolicy.handoffCap);
      expect(track.handoffActiveAt(now), isFalse);
      expect(
        ConnectionPolicy.isLive(
          webviewOpen: false,
          monitorPaired: false,
          lastAliveAt: stale,
          now: now,
          handoff: track.handoffActiveAt(now),
        ),
        isFalse,
        reason: '另一台设备长期占槽位时，本机不能永远装作在线',
      );
      // 窗口内仍豁免。
      track.handoffSince = now.subtract(const Duration(seconds: 30));
      expect(track.handoffActiveAt(now), isTrue);
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

    test('yielded 让路 → 不计断连；配对恢复后清豁免（v1.7.2）', () {
      final notifier = container.read(connectionStatusProvider.notifier);
      notifier.reportMonitor('dev1', RelayMonitorState.paired);
      expect(notifier.isLive('dev1'), isTrue);

      // 被踢让路：槽位在别的终端手里，这是设计行为，不是断线。
      notifier.reportMonitor('dev1', RelayMonitorState.yielded);
      container
          .read(connectionStatusProvider)['dev1']!
          .lastAliveAt = DateTime.now().subtract(const Duration(minutes: 5));
      expect(notifier.isLive('dev1'), isTrue);

      // 重新配对：豁免清除，回到正常在线判定。
      notifier.reportMonitor('dev1', RelayMonitorState.paired);
      expect(
        container.read(connectionStatusProvider)['dev1']!.handoff,
        isFalse,
      );
      expect(notifier.isLive('dev1'), isTrue);
    });

    test('reportHandoff 控制交接豁免', () {
      final notifier = container.read(connectionStatusProvider.notifier);
      notifier.reportWebview('dev1', open: true);
      container
          .read(connectionStatusProvider)['dev1']!
          .lastAliveAt = DateTime.now().subtract(const Duration(minutes: 5));
      expect(notifier.isLive('dev1'), isTrue);
      notifier.reportWebview('dev1', open: false);
      notifier.reportHandoff('dev1', active: true);
      expect(notifier.isLive('dev1'), isTrue);
      notifier.reportHandoff('dev1', active: false);
      expect(notifier.isLive('dev1'), isFalse);
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

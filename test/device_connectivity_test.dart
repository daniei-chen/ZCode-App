import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/device_connectivity.dart';
import 'package:zremote/state/session_status.dart';

/// ITERATION 8 用户需求：设备列表连通性指示（可联通绿点 / 不可联通橙点）。
/// 纯策略 + 探测服务（注入 fetch，不发真实网络请求）。
void main() {
  RemoteDevice device(String url, [String id = 'd1']) => RemoteDevice(
    id: id,
    baseUrl: url,
    params: const {'sid': 's', 'hash': 'h'},
    label: '',
    createdAt: DateTime(2026),
  );

  group('DeviceConnectivityPolicy.state', () {
    test('relay 实流（live）最强：即使探测失败也判可达', () {
      expect(
        DeviceConnectivityPolicy.state(
          sessionStatus: SessionStatus.live,
          probe: ProbeOutcome.failed,
        ),
        DeviceLinkState.reachable,
        reason: '数据帧真的在流动，比一次探测更有说服力',
      );
    });

    test('探测成功 → 可达；探测失败 → 不可达（W-023 绿/橙语义）', () {
      expect(
        DeviceConnectivityPolicy.state(
          sessionStatus: SessionStatus.loading,
          probe: ProbeOutcome.ok,
        ),
        DeviceLinkState.reachable,
      );
      expect(
        DeviceConnectivityPolicy.state(
          sessionStatus: SessionStatus.error,
          probe: ProbeOutcome.failed,
        ),
        DeviceLinkState.unreachable,
      );
    });

    test('都没有 → unknown（UI 保持"连接中"色）', () {
      expect(
        DeviceConnectivityPolicy.state(sessionStatus: null, probe: null),
        DeviceLinkState.unknown,
      );
    });
  });

  group('probeUri', () {
    test('探测目标跟随控制链接路径：去 query（凭证不随探测发送），保留页面路径', () {
      final uri = DeviceConnectivityPolicy.probeUri(
        device('https://zcode.z.ai/remote/v4?sid=sid-abc&hash=h'),
      );
      expect(uri.scheme, 'https');
      expect(uri.host, 'zcode.z.ai');
      expect(uri.port, 443);
      expect(uri.query, isEmpty, reason: 'sid/hash 凭证不得随探测发送');
      expect(uri.fragment, isEmpty);
      expect(
        uri.path,
        '/remote/v4',
        reason: 'iter12 N-P2-2：探测打裸根会与远控页可用性背离',
      );
    });

    test('非白名单源站 → 指向无效探测目标（默认 fetch 直接判失败）', () {
      final uri = DeviceConnectivityPolicy.probeUri(
        device('https://evil.example.com/remote/v4'),
      );
      expect(uri.host, 'invalid.probe');
    });
  });

  group('ConnectivityProbe + probeAll', () {
    test('注入 fetch：HTTP 响应（任意状态码语义）= ok', () async {
      final probe = ConnectivityProbe(
        fetch: (_) async => ProbeOutcome.ok,
      );
      expect(await probe.probe(device('https://zcode.z.ai/remote/v4')),
          ProbeOutcome.ok);
    });

    test('注入 fetch 抛错 = 原样上抛（错误捕获属于 defaultFetch/调用方）', () async {
      final probe = ConnectivityProbe(
        fetch: (_) async => throw const SocketException('timeout'),
      );
      await expectLater(
        probe.probe(device('https://zcode.z.ai/remote/v4')),
        throwsA(isA<SocketException>()),
      );
    });

    test('probeAll：live 设备跳过探测直接可达，其余并发探测并合并结果', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(deviceConnectivityProvider.notifier);
      var fetchCalls = 0;
      notifier.probe = ConnectivityProbe(
        fetch: (_) async {
          fetchCalls++;
          return ProbeOutcome.failed;
        },
      );
      final devices = [
        device('https://zcode.z.ai/remote/v4?sid=live', 'd1'),
        device('https://zcode.z.ai/remote/v4?sid=dead', 'd2'),
      ];
      await notifier.probeAll(devices, {
        'd1': SessionStatus.live,
        'd2': SessionStatus.loading,
      });
      expect(fetchCalls, 1, reason: 'live 设备不发探测');
      expect(container.read(deviceConnectivityProvider)['d1'],
          ProbeOutcome.ok);
      expect(container.read(deviceConnectivityProvider)['d2'],
          ProbeOutcome.failed);
    });

    test('forget 清理单设备；clear 全清', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(deviceConnectivityProvider.notifier);
      notifier.probe = ConnectivityProbe(fetch: (_) async => ProbeOutcome.ok);
      await notifier.probeAll(
        [device('https://zcode.z.ai/remote/v4')],
        const {},
      );
      notifier.forget('d1');
      expect(container.read(deviceConnectivityProvider), isEmpty);
    });
  });
}

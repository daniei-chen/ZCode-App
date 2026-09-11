import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/relay/relay_payloads.dart';
import 'package:zremote/relay/relay_socket.dart';
import 'package:zremote/state/relay_source.dart';
import 'package:zremote/state/session_index.dart';

RemoteDevice relayDevice({String id = 'dev-1'}) => RemoteDevice(
  id: id,
  baseUrl: 'https://zcode.z.ai/remote/v4',
  params: const {
    'sid': 'd_EXAMPLE000000000000000',
    'hash': '/EXAMPLE+EXAMPLE/EXAMPLE=',
    'mid': '00000000-0000-4000-8000-000000000000',
    'name': 'DESKTOP',
    'app_version': '3.11.2',
  },
  label: '我的电脑',
  createdAt: DateTime(2026, 9, 10),
);

RemoteDevice webViewOnlyDevice() => RemoteDevice(
  id: 'dev-old',
  baseUrl: 'https://zcode.z.ai/remote/v3',
  params: const {'foo': 'bar'},
  label: '旧设备',
  createdAt: DateTime(2026, 9, 10),
);

/// 一次真实抓到的 result 形状（字段名保留，值做匿名化）。
Map<String, dynamic> tasksResult() => {
  'activeTaskId': 'sess_active',
  'activeWorkspaceKey': r'D:\工作\工作1',
  'tasks': [
    {
      'taskId': 'sess_a',
      'title': '任务甲',
      'displayStatus': 'running',
      'provider': 'glm',
      'workspaceKind': 'local',
      'workspaceLabel': '工作1',
      'workspacePath': r'D:\工作\工作1',
      'createdAt': 1789013789954,
      'updatedAt': 1789014288491,
    },
    {
      'taskId': 'sess_b',
      'title': '任务乙',
      'displayStatus': 'completed',
      'workspaceLabel': '杂事',
      'workspacePath': r'E:\zcode\杂事',
      'createdAt': 1789012324938,
      'updatedAt': 1789014255207,
    },
  ],
};

/// 脚本化的假服务端：走完握手 → 工作区列表 → 开桥。
FakeRelaySocket scriptedSocket() {
  final socket = FakeRelaySocket();
  socket.onSend = (raw) {
    final outer = jsonDecode(raw) as Map<String, dynamic>;

    // 控制消息：平铺，不套 data 外壳
    if (outer['type'] != 'data') {
      switch (outer['type']) {
        case 'auth_init':
          socket.emitJson({'type': 'auth_challenge', 'nonce': 'n-1'});
        case 'auth_response':
          socket.emitJson({'type': 'auth_ack', 'pair_status': 'matched'});
      }
      return;
    }

    // 数据负载：套在 payload 里
    final p = Map<String, dynamic>.from(outer['payload'] as Map);
    switch (p['zcode_type']) {
      case ZcodeType.workspaceListRequest:
        socket.emitJson({
          'type': 'data',
          'payload': {
            'zcode_type': ZcodeType.workspaceListResponse,
            'requestId': p['requestId'],
            'result': tasksResult(),
          },
        });
      case ZcodeType.bridgeOpen:
        socket.emitJson({
          'type': 'data',
          'payload': {
            'zcode_type': ZcodeType.bridgeReady,
            'requestId': p['requestId'],
            'bridgeSessionId': p['bridgeSessionId'],
            'bridgeGeneration': 1,
          },
        });
    }
  };
  return socket;
}

ProviderContainer makeContainer() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

void main() {
  tearDown(() => RelaySourceNotifier.debugSocketFactory = null);

  group('RelaySourceNotifier 设备识别', () {
    test('有 sid+hash 的设备支持原生通道', () {
      expect(RelaySourceNotifier.supports(relayDevice()), isTrue);
      expect(RelaySourceNotifier.supports(webViewOnlyDevice()), isFalse);
    });

    test('linkOf 解析出正确的中继地址与凭证', () {
      final link = RelaySourceNotifier.linkOf(relayDevice())!;
      expect(link.origin, 'https://zcode.z.ai');
      expect(link.deviceSid, 'd_EXAMPLE000000000000000');
      expect(link.deviceMid, '00000000-0000-4000-8000-000000000000');
      expect(link.canAuthenticate, isTrue);
      expect(RelaySourceNotifier.linkOf(webViewOnlyDevice()), isNull);
    });

    test('非 relay 设备标记为 unsupported，且不建连接', () async {
      RelaySourceNotifier.debugSocketFactory = FakeRelaySocketFactory(
        socket: scriptedSocket(),
      );
      final c = makeContainer();
      await c.read(relaySourceProvider.notifier).connect(webViewOnlyDevice());
      expect(
        c.read(relaySourceProvider)['dev-old']!.kind,
        RelaySourceKind.unsupported,
      );
    });
  });

  group('RelaySourceNotifier 供数', () {
    test('连接成功后进入 live，并把任务写进 session_index', () async {
      RelaySourceNotifier.debugSocketFactory = FakeRelaySocketFactory(
        socket: scriptedSocket(),
      );
      final c = makeContainer();
      await c.read(relaySourceProvider.notifier).connect(relayDevice());

      final s = c.read(relaySourceProvider)['dev-1']!;
      expect(s.kind, RelaySourceKind.live);
      expect(s.taskCount, 2);
      expect(s.lastSyncAt, isNotNull);
      expect(s.workspaceKey, r'D:\工作\工作1');

      final index = c.read(sessionIndexProvider)['dev-1']!;
      expect(index.keys, containsAll(['sess_a', 'sess_b']));
      expect(index['sess_a']!.title, '任务甲');
      expect(index['sess_a']!.phase, 'running');
      expect(index['sess_a']!.workspace, '工作1');
      expect(index['sess_b']!.phase, 'completedSuccess');
      expect(index['sess_a']!.lastActivityAt, 1789014288491);

      await c.read(relaySourceProvider.notifier).disconnect('dev-1');
    });

    test('phase 映射与 WebView 侧一致（displayStatus → phase）', () async {
      RelaySourceNotifier.debugSocketFactory = FakeRelaySocketFactory(
        socket: scriptedSocket(),
      );
      final c = makeContainer();
      await c.read(relaySourceProvider.notifier).connect(relayDevice());
      final index = c.read(sessionIndexProvider)['dev-1']!;
      // 与 WebView 通道用同一个提取器，语义必须相同
      expect(index['sess_a']!.phase, 'running');
      expect(index['sess_b']!.phase, 'completedSuccess');
      await c.read(relaySourceProvider.notifier).disconnect('dev-1');
    });

    test('connect 幂等：重复调用不会建第二条连接', () async {
      final factory = FakeRelaySocketFactory(socket: scriptedSocket());
      RelaySourceNotifier.debugSocketFactory = factory;
      final c = makeContainer();
      final n = c.read(relaySourceProvider.notifier);
      await n.connect(relayDevice());
      await n.connect(relayDevice());
      expect(factory.connected, hasLength(1));
      await n.disconnect('dev-1');
    });

    test('断开后状态回到 idle', () async {
      RelaySourceNotifier.debugSocketFactory = FakeRelaySocketFactory(
        socket: scriptedSocket(),
      );
      final c = makeContainer();
      final n = c.read(relaySourceProvider.notifier);
      await n.connect(relayDevice());
      expect(n.liveCount, 1);
      await n.disconnect('dev-1');
      expect(c.read(relaySourceProvider)['dev-1']!.kind, RelaySourceKind.idle);
      expect(n.liveCount, 0);
    });

    test('forget 会移除状态与索引数据', () async {
      RelaySourceNotifier.debugSocketFactory = FakeRelaySocketFactory(
        socket: scriptedSocket(),
      );
      final c = makeContainer();
      final n = c.read(relaySourceProvider.notifier);
      await n.connect(relayDevice());
      await n.forget('dev-1');
      expect(c.read(relaySourceProvider).containsKey('dev-1'), isFalse);
    });

    test('连接失败时进入 failed 并记录原因', () async {
      RelaySourceNotifier.debugSocketFactory = FakeRelaySocketFactory(
        error: StateError('refused'),
      );
      final c = makeContainer();
      await c.read(relaySourceProvider.notifier).connect(relayDevice());
      final s = c.read(relaySourceProvider)['dev-1']!;
      expect(s.kind, RelaySourceKind.failed);
      expect(s.reason, isNotNull);
    });
  });
}

import 'dart:convert';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/relay/relay_payloads.dart';
import 'package:zremote/relay/relay_socket.dart';
import 'package:zremote/state/app_lifecycle.dart';
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

/// 轮询等待异步状态收敛（连接/重连涉及真实超时路径）。
Future<void> pumpUntil(bool Function() cond, {int maxMs = 15000}) async {
  final sw = Stopwatch()..start();
  while (!cond() && sw.elapsedMilliseconds < maxMs) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
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

  group('RelaySourceNotifier 轮询前后台', () {
    test('后台挂起跳过周期刷新，回前台立即补发', () async {
      final socket = scriptedSocket();
      RelaySourceNotifier.debugSocketFactory = FakeRelaySocketFactory(
        socket: socket,
      );
      final c = makeContainer();
      await c.read(relaySourceProvider.notifier).connect(relayDevice());
      int requests() => socket.sent
          .where((m) => m.contains('workspace-list-request'))
          .length;
      final baseline = requests();
      expect(baseline, greaterThan(0));

      // paused：周期 tick 被抑制，不打桌面端。
      c.read(appLifecycleProvider.notifier).set(AppLifecycleState.paused);
      c.read(relaySourceProvider.notifier).refreshTick('dev-1');
      await Future<void>.delayed(Duration.zero);
      expect(requests(), baseline);

      // resumed：立即补刷一次，列表不因后台暂停而过期。
      c.read(appLifecycleProvider.notifier).set(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(requests(), greaterThan(baseline));
    });
  });

  group('RelaySourceNotifier 前置修复回归', () {
    test('degraded 后 connect 重建桥而不是被 isReady 短路（N1）', () async {
      final factory = _ScriptedSocketFactory();
      RelaySourceNotifier.debugSocketFactory = factory;
      final c = makeContainer();
      await c.read(relaySourceProvider.notifier).connect(relayDevice());
      expect(c.read(relaySourceProvider)['dev-1']!.kind, RelaySourceKind.live);

      // 注入 bridge-degraded：phase 保持 degraded（isReady 仍为 true）。
      // 不带 bridgeSessionId：通道只接受属于当前桥的降级通知。
      factory.created.single.emitJson({
        'type': 'data',
        'payload': {
          'zcode_type': ZcodeType.bridgeDegraded,
          'reason': 'rpc-frame-gap',
          'seq': 1,
          'expectedSeq': 1,
          'droppedCount': 1,
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.read(relaySourceProvider)['dev-1']!.kind, RelaySourceKind.failed);

      // 退避重试（1s）里的 connect 必须重建新桥：若被 isReady 短路，
      // kind 将永远卡在 failed。
      await pumpUntil(
        () => c.read(relaySourceProvider)['dev-1']!.kind ==
            RelaySourceKind.live,
        maxMs: 20000,
      );
      expect(factory.created.length, greaterThanOrEqualTo(2));
    });

    test('disconnect 丢弃在途 connect，随后的 connect 建立新连接（N2）', () async {
      final factory = FakeRelaySocketFactory(error: StateError('x'));
      RelaySourceNotifier.debugSocketFactory = factory;
      final c = makeContainer();
      final n = c.read(relaySourceProvider.notifier);
      final first = n.connect(relayDevice());
      // 在途 future 完成前就断开：generation 递增使 pending 作废。
      await n.disconnect('dev-1');
      factory.error = null;
      factory.socket = scriptedSocket();
      await n.connect(relayDevice());
      expect(c.read(relaySourceProvider)['dev-1']!.kind, RelaySourceKind.live);
      await first;
    });

    test('forget 清理会话层与面板/事件等全部运行时数据', () async {
      RelaySourceNotifier.debugSocketFactory = _ScriptedSocketFactory();
      final c = makeContainer();
      final n = c.read(relaySourceProvider.notifier);
      await n.connect(relayDevice());
      c
          .read(sessionIndexProvider.notifier)
          .upsertTasks('dev-1', const []);
      await n.forget('dev-1');
      expect(c.read(relaySourceProvider).containsKey('dev-1'), isFalse);
      expect(c.read(sessionIndexProvider).containsKey('dev-1'), isFalse);
    });
  });
}

/// 每次连接产出全新 scripted socket 的工厂：桥重建（degraded 重连等）
/// 时旧 socket 已被 stop/close，必须给新桥新 socket。
class _ScriptedSocketFactory implements RelaySocketFactory {
  final List<FakeRelaySocket> created = [];

  @override
  Future<RelaySocket> connect(
    Uri url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final socket = scriptedSocket();
    created.add(socket);
    return socket;
  }
}

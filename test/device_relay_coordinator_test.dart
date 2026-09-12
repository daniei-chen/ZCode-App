import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/relay/relay_socket.dart';
import 'package:zremote/state/device_relay_coordinator.dart';
import 'package:zremote/state/native_channel.dart';
import 'package:zremote/state/relay_source.dart';
import 'package:zremote/state/session_index.dart';
import 'package:zremote/state/session_pool.dart';

import 'relay_source_test.dart' show relayDevice, scriptedSocket;

/// 轮询等待异步状态收敛（连接/重连涉及真实超时路径）。
Future<void> pumpUntil(bool Function() cond, {int maxMs = 20000}) async {
  final sw = Stopwatch()..start();
  while (!cond() && sw.elapsedMilliseconds < maxMs) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// 每次连接产出全新 scripted socket 的工厂（桥重建时旧 socket 已关闭）。
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

Future<ProviderContainer> makeContainer({bool nativeChannel = true}) async {
  FlutterSecureStorage.setMockInitialValues({
    'zremote.device.index': '["dev-1","dev-2"]',
    'zremote.device.dev-1': jsonEncode(relayDevice(id: 'dev-1').toJson()),
    'zremote.device.dev-2': jsonEncode(relayDevice(id: 'dev-2').toJson()),
  });
  SharedPreferences.setMockInitialValues({});
  final c = ProviderContainer(
    overrides: [
      nativeChannelProvider.overrideWith(
        () => NativeChannelNotifier(initial: nativeChannel),
      ),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  tearDown(() => RelaySourceNotifier.debugSocketFactory = null);

  test('增强层开启：非活动设备原生供数，活动设备让位 WebView，切换即互换', () async {
    RelaySourceNotifier.debugSocketFactory = _ScriptedSocketFactory();
    final c = await makeContainer();
    await pumpUntil(() => c.read(deviceListProvider).length == 2);
    // 订阅以保持 autoDispose 协调器存活（等价 AppShell watch）。
    c.listen(deviceRelayCoordinatorProvider, (_, _) {});

    // dev-1 是活动设备（tab 0）→ 原生桥不持有；dev-2 由原生桥供数。
    await pumpUntil(
      () => c.read(relaySourceProvider)['dev-2']?.kind == RelaySourceKind.live,
    );
    expect(
      c.read(relaySourceProvider)['dev-1']?.kind ?? RelaySourceKind.idle,
      RelaySourceKind.idle,
    );
    expect(c.read(relaySourceProvider)['dev-2']!.kind, RelaySourceKind.live);

    // 切到 dev-2：原生桥让位（idle），dev-1 转由原生桥供数。
    c.read(activeTabProvider.notifier).set(1);
    await pumpUntil(
      () => c.read(relaySourceProvider)['dev-1']?.kind == RelaySourceKind.live,
    );
    await pumpUntil(
      () => c.read(relaySourceProvider)['dev-2']?.kind == RelaySourceKind.idle,
    );
    expect(c.read(relaySourceProvider)['dev-1']!.kind, RelaySourceKind.live);
    expect(c.read(relaySourceProvider)['dev-2']!.kind, RelaySourceKind.idle);
  });

  test('开关关闭：协调器不持有任何桥，行为与历史版本一致', () async {
    RelaySourceNotifier.debugSocketFactory = _ScriptedSocketFactory();
    final c = await makeContainer(nativeChannel: false);
    await pumpUntil(() => c.read(deviceListProvider).length == 2);
    c.listen(deviceRelayCoordinatorProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(c.read(relaySourceProvider), isEmpty);
  });

  test('删除设备：原生桥断开并全量清理（对齐 webview_sync.forget 范围）', () async {
    RelaySourceNotifier.debugSocketFactory = _ScriptedSocketFactory();
    final c = await makeContainer();
    await pumpUntil(() => c.read(deviceListProvider).length == 2);
    c.listen(deviceRelayCoordinatorProvider, (_, _) {});
    await pumpUntil(
      () => c.read(relaySourceProvider)['dev-2']?.kind == RelaySourceKind.live,
    );

    await c.read(deviceListProvider.notifier).remove('dev-2');
    await pumpUntil(() => !c.read(relaySourceProvider).containsKey('dev-2'));
    expect(c.read(relaySourceProvider).containsKey('dev-2'), isFalse);
    expect(c.read(sessionIndexProvider).containsKey('dev-2'), isFalse);
  });

  test('锁定（AppShell 卸载 → 协调器销毁）：全部原生桥断开', () async {
    RelaySourceNotifier.debugSocketFactory = _ScriptedSocketFactory();
    final c = await makeContainer();
    await pumpUntil(() => c.read(deviceListProvider).length == 2);
    final sub = c.listen(deviceRelayCoordinatorProvider, (_, _) {});
    await pumpUntil(
      () => c.read(relaySourceProvider)['dev-2']?.kind == RelaySourceKind.live,
    );

    // 模拟生物识别锁定：AppShell 卸载 → 订阅关闭 → autoDispose 协调器
    // dispose → onDispose 断开全部原生桥。
    sub.close();
    await pumpUntil(
      () => c.read(relaySourceProvider)['dev-2']?.kind == RelaySourceKind.idle,
    );
    expect(c.read(relaySourceProvider)['dev-2']!.kind, RelaySourceKind.idle);
  });
}

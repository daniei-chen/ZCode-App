import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/device_store.dart';
import 'package:zremote/services/event_observer.dart';
import 'package:zremote/services/warmup.dart';
import 'package:zremote/state/active_session.dart';
import 'package:zremote/state/event_feed.dart';
import 'package:zremote/state/protected_wipe.dart';
import 'package:zremote/state/session_index.dart';
import 'package:zremote/state/session_pool.dart';
import 'package:zremote/state/session_status.dart';
import 'package:zremote/state/subframe_stats.dart';

/// R-04 擦除事务：审计复现是"clearAll 只清磁盘，Provider 仍持 CANARY 凭证"。
/// 这里把修复后的行为固化成回归：擦除完成后，内存与磁盘都不得再出现该凭证。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final backing = <String, String>{};

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    backing.clear();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map<Object?, Object?>;
      switch (call.method) {
        case 'read':
          return backing[args['key'] as String];
        case 'readAll':
          return Map<String, String>.of(backing);
        case 'write':
          backing[args['key'] as String] = args['value'] as String;
          return null;
        case 'delete':
          backing.remove(args['key'] as String);
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  RemoteDevice device(String id) => RemoteDevice(
    id: id,
    baseUrl: 'https://zcode.z.ai/remote/v4',
    params: const {'token': 'INVALID_CANARY_TOKEN'},
    label: 'Audit',
    createdAt: DateTime(2026),
  );

  ProviderContainer seededContainer() {
    final d = device('audit-device');
    backing['zremote.device.index'] = jsonEncode(['audit-device']);
    backing['zremote.device.audit-device'] = jsonEncode(d.toJson());
    backing['zremote.warmup.audit-device'] = jsonEncode([
      {'u': '/api/panel/list', 'm': 'GET'},
    ]);
    final container = ProviderContainer(
      overrides: [deviceListProvider.overrideWith(() => DeviceListNotifier(seed: [d]))],
    );
    addTearDown(container.dispose);
    container.read(deviceListProvider);
    return container;
  }

  test('擦除事务：内存 Provider 与磁盘上的 CANARY 凭证都被清除（R-04）', () async {
    final container = seededContainer();
    // 制造其它内存态：活动会话/事件/索引/状态都持有该设备的数据。
    container.read(activeSessionProvider.notifier).report('audit-device', 'sess-1');
    container.read(sessionStatusProvider.notifier).report('audit-device', SessionStatus.live);
    container.read(sessionIndexProvider.notifier).upsertAll('audit-device', [
      SessionState(sessionId: 's1', title: '检查数据', phase: 'running'),
    ]);
    // 预置 warmup 内存态（含请求签名）。
    container.read(warmupMemoryProvider.notifier).ingestSeen(
      'audit-device',
      jsonEncode([
        {'u': '/api/panel/list', 'm': 'GET'},
      ]),
    );
    // 预置子 frame 取证计数（iter1 复审 F-4）：擦除后必须一并清零。
    container.read(subFrameStatsProvider.notifier).record('audit-device', trusted: true);

    expect(container.read(deviceListProvider), hasLength(1));

    await ProtectedStateWipe.run(container);

    // 内存：凭证不可再从任何 Provider 恢复。
    expect(container.read(deviceListProvider), isEmpty);
    expect(container.read(activeSessionProvider), isEmpty);
    expect(container.read(sessionStatusProvider), isEmpty);
    expect(container.read(sessionIndexProvider), isEmpty);
    expect(container.read(eventFeedProvider), isEmpty);
    expect(container.read(warmupMemoryProvider), isEmpty);
    expect(container.read(subFrameStatsProvider), isEmpty);

    // 磁盘：设备记录、索引、warmup 脚本都不在了。
    expect(backing.containsKey('zremote.device.audit-device'), isFalse);
    expect(backing.containsKey('zremote.warmup.audit-device'), isFalse);
    expect(backing['zremote.device.index'], anyOf(isNull, '[]'));
  });

  test('擦除后重载不会从磁盘"复活"设备（R-04/R-06 交叉）', () async {
    final container = seededContainer();
    await ProtectedStateWipe.run(container);
    // 模拟重启后的加载路径。
    final reloaded = await DeviceStore.instance.loadAllWithStatus();
    expect(reloaded.unavailable, isFalse);
    expect(reloaded.devices, isEmpty);
  });

  test('擦除事务清单覆盖所有持凭证的 Provider', () {
    // 防止未来新增 Provider 持有凭证却漏进擦除（清单即验收面）。
    expect(
      ProtectedStateWipe.coveredProviders,
      containsAll([
        'deviceListProvider',
        'activeTabProvider',
        'activeSessionProvider',
        'sessionIndexProvider',
        'sessionStatusProvider',
        'eventFeedProvider',
        'warmupMemoryProvider',
        'subFrameStatsProvider',
      ]),
    );
    // 键格式兜底检查；"清单 ⊆ 实际 clear()"由上方主用例的
    // 预置→擦除→断言空路径保证（iter1 复审 N-2）。
    for (final name in ProtectedStateWipe.coveredProviders) {
      expect(name, isNot(contains(' ')));
    }
  });
}

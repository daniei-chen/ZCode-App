import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/app_log.dart';
import 'package:zremote/services/device_store.dart';
import 'package:zremote/services/event_observer.dart';
import 'package:zremote/services/warmup.dart';
import 'package:zremote/state/bridge_health.dart';
import 'package:zremote/state/session_index.dart';
import 'package:zremote/state/session_pool.dart';

/// ITERATION 7 服务面审计（R-2/R-3/R-6/R-8/R-9）的回归钉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('R-2 设置写入失败：不显示假成功（source-pin：插件通道行为单测不可控）', () {
    String read(String path) => File(path).readAsStringSync();

    test('通知偏好：持久化必须先于 state 发布，失败必须回读磁盘', () {
      final src = read('lib/state/notification_prefs.dart');
      final persist = src.indexOf('await DeviceStore.instance.setNotificationPrefs(prefs);');
      final publish = src.indexOf('state = prefs;');
      expect(persist, greaterThanOrEqualTo(0));
      expect(publish, greaterThan(persist),
          reason: '乐观更新（先改 state 后落盘）会在写失败时"UI 已改、重启回滚"（R-2）');
      expect(
        src.indexOf('catch (_)', persist),
        greaterThan(persist),
        reason: '写失败必须被捕获并回读磁盘真实值（_load），不得假成功',
      );
      expect(src.contains('await _load();'), isTrue);
    });

    test('启动进入页：同样的持久化优先 + 失败回退 initial 契约', () {
      final src = read('lib/state/startup_target.dart');
      final persist = src.indexOf('await DeviceStore.instance.setStartupTarget(value);');
      final publish = src.indexOf('state = value;');
      expect(persist, greaterThanOrEqualTo(0));
      expect(publish, greaterThan(persist));
      expect(src.contains('catch (_)'), isTrue);
    });
  });

  group('R-3 损坏设备记录隔离留痕', () {
    test('损坏记录被隔离：计入 skippedRecords 且 DS704 留痕', () async {
      const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      final backing = <String, String>{};
      final good = RemoteDevice(
        id: 'good-device',
        baseUrl: 'https://zcode.z.ai/remote/v4',
        params: const {'token': 'x'},
        label: 'Good',
        createdAt: DateTime(2026),
      );
      backing['zremote.device.index'] = jsonEncode(['good-device', 'bad-device']);
      backing['zremote.device.good-device'] = jsonEncode(good.toJson());
      backing['zremote.device.bad-device'] = '{"label": '; // 截断的 JSON
      const channel2 = channel;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel2, (call) async {
            switch (call.method) {
              case 'read':
                return backing[call.arguments['key'] as String];
              case 'readAll':
                return Map<String, String>.of(backing);
              case 'write':
                backing[call.arguments['key'] as String] =
                    call.arguments['value'] as String;
                return null;
              case 'delete':
                backing.remove(call.arguments['key'] as String);
                return null;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel2, null);
      });
      AppLog.resetForTest();

      final result = await DeviceStore.instance.loadAllWithStatus();
      expect(result.skippedRecords, greaterThanOrEqualTo(1));
      expect(
        result.devices.any((d) => d.id == 'good-device'),
        isTrue,
        reason: '坏记录只隔离自己，好设备不受牵连',
      );
      expect(
        AppLog.snapshot().any((line) => line.contains('record_quarantined')),
        isTrue,
        reason: '隔离必须留痕（用户视角是"设备消失"，无日志就是无头案）',
      );
    });
  });

  group('R-8 洪泛驱逐不挤掉 pinned 会话', () {
    test('6000 条（前 2000 pinned）：驱逐只落在非 pinned 上', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionIndexProvider.notifier);
      SessionState s(String id, {bool pinned = false}) =>
          SessionState(sessionId: id, phase: 'idle', pinned: pinned);
      notifier.upsertAll('dev', [
        for (var i = 0; i < 2000; i++) s('p${'$i'.padLeft(6, '0')}', pinned: true),
        for (var i = 0; i < 3000; i++) s('n${'$i'.padLeft(6, '0')}'),
      ]);
      notifier.upsertAll('dev', [
        for (var i = 0; i < 1000; i++) s('x${'$i'.padLeft(6, '0')}'),
      ]);
      final after = container.read(sessionIndexProvider)['dev']!;
      expect(
        after.length,
        SessionIndexNotifier.maxEntriesPerDevice -
            SessionIndexNotifier.maxEntriesPerDevice ~/ 8,
      );
      for (var i = 0; i < 2000; i++) {
        expect(after.containsKey('p${'$i'.padLeft(6, '0')}'), isTrue,
            reason: 'pinned 会话不得被洪泛挤掉');
      }
    });
  });

  group('R-9 ingestSeen 按 UTF-8 字节计', () {
    test('CJK 密集的合法 JSON：UTF-16 长度过旧检查、UTF-8 字节超限被拒', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(warmupMemoryProvider.notifier);
      final dense = jsonEncode([
        for (var i = 0; i < 300; i++)
          {'u': '/api/usage/${'设' * 400}', 'm': 'GET'},
      ]);
      expect(dense.length, lessThan(256 * 1024),
          reason: '旧实现按 UTF-16 length 检查时会放行这条载荷');
      expect(utf8.encode(dense).length, greaterThan(256 * 1024));
      notifier.ingestSeen('dev', dense);
      expect(container.read(warmupMemoryProvider)['dev'], isNull);
      // 正常小载荷（路径在预热白名单内）不受影响。
      notifier.ingestSeen('dev', jsonEncode([
        {'u': '/api/usage', 'm': 'GET'},
      ]));
      expect(container.read(warmupMemoryProvider)['dev'], isNotNull);
    });

    test('W-019：加载时清扫孤儿 warmup 键（remove 防抖写入残留）', () async {
      const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      final backing = <String, String>{};
      final d = RemoteDevice(
        id: 'kept-device',
        baseUrl: 'https://zcode.z.ai/remote/v4',
        params: const {'token': 'x'},
        label: 'Kept',
        createdAt: DateTime(2026),
      );
      backing['zremote.device.index'] = jsonEncode(['kept-device']);
      backing['zremote.device.kept-device'] = jsonEncode(d.toJson());
      backing['zremote.warmup.kept-device'] = jsonEncode([
        {'u': '/api/usage', 'm': 'GET'},
      ]);
      // 已删设备的残留键（3 秒防抖写入在 remove 之后落盘的产物）。
      backing['zremote.warmup.gone-device'] = jsonEncode([
        {'u': '/api/usage', 'm': 'GET'},
      ]);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'read':
                return backing[call.arguments['key'] as String];
              case 'readAll':
                return Map<String, String>.of(backing);
              case 'write':
                backing[call.arguments['key'] as String] =
                    call.arguments['value'] as String;
                return null;
              case 'delete':
                backing.remove(call.arguments['key'] as String);
                return null;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      await DeviceStore.instance.loadAllWithStatus();

      expect(backing.containsKey('zremote.warmup.kept-device'), isTrue,
          reason: '在册设备的预热脚本不得被误删');
      expect(
        backing.containsKey('zremote.warmup.gone-device'),
        isFalse,
        reason: '孤儿预热键（URL/请求签名）必须按索引收敛删除',
      );
    });
  });

  group('R-6 桥健康与设备同生命周期', () {
    test('删除设备后 bridgeHealth 不再残留该设备（诊断包不带幽灵行）', () async {
      const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      final backing = <String, String>{};
      final d = RemoteDevice(
        id: 'doomed-device',
        baseUrl: 'https://zcode.z.ai/remote/v4',
        params: const {'token': 'x'},
        label: 'Doomed',
        createdAt: DateTime(2026),
      );
      backing['zremote.device.index'] = jsonEncode(['doomed-device']);
      backing['zremote.device.doomed-device'] = jsonEncode(d.toJson());
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'read':
                return backing[call.arguments['key'] as String];
              case 'readAll':
                return Map<String, String>.of(backing);
              case 'write':
                backing[call.arguments['key'] as String] =
                    call.arguments['value'] as String;
                return null;
              case 'delete':
                backing.remove(call.arguments['key'] as String);
                return null;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final container = ProviderContainer(
        overrides: [
          deviceListProvider.overrideWith(() => DeviceListNotifier(seed: [d])),
        ],
      );
      addTearDown(container.dispose);
      container.read(deviceListProvider);
      container
          .read(bridgeHealthProvider.notifier)
          .report('doomed-device', 1, ready: true);
      expect(container.read(bridgeHealthProvider), contains('doomed-device'));

      await container.read(deviceListProvider.notifier).remove('doomed-device');

      expect(
        container.read(bridgeHealthProvider),
        isNot(contains('doomed-device')),
        reason: 'iter7 R-6：删除设备必须同步清桥健康，诊断包不带幽灵行',
      );
    });
  });
}

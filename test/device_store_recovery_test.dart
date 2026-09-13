import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/device_store.dart';

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

  String deviceJson(String id, DateTime createdAt) => jsonEncode({
    'id': id,
    'baseUrl': 'https://example.invalid',
    'params': const {'sid': 's', 'hash': 'h'},
    'label': 'dev-$id',
    'createdAt': createdAt.toIso8601String(),
  });

  test('索引损坏自愈：排除索引键/坏数据/键值不符，只恢复真实设备（D1）', () async {
    backing['zremote.device.index'] = '{corrupted';
    backing['zremote.device.dev-b'] = deviceJson('dev-b', DateTime(2026, 1, 2));
    backing['zremote.device.dev-a'] = deviceJson('dev-a', DateTime(2026, 1, 1));
    backing['zremote.device.bad'] = '{invalid';
    // 键名与内容 id 不一致 → 拒绝。
    backing['zremote.device.mismatch'] = deviceJson(
      'other',
      DateTime(2026, 1, 3),
    );
    // warmup 键不匹配设备前缀，天然排除。
    backing['zremote.warmup.dev-a'] = '[]';

    final devices = await DeviceStore.instance.loadAll();

    expect(devices.map((d) => d.id), ['dev-a', 'dev-b']);
    // 索引被重建为干净列表，不再包含 'index' 等污染项。
    expect(backing['zremote.device.index'], '["dev-a","dev-b"]');
  });

  test('索引损坏且无有效设备 → 返回空列表而不是崩溃', () async {
    backing['zremote.device.index'] = '{corrupted';
    backing['zremote.device.bad'] = 'not-a-device';

    expect(await DeviceStore.instance.loadAll(), isEmpty);
  });

  test('索引键缺失但有设备记录 → 扫描重建，不显示为空库（D01）', () async {
    // 首次 add 写完设备记录、还没写索引就崩溃：记录在，索引键不存在。
    backing['zremote.device.dev-a'] = deviceJson('dev-a', DateTime(2026, 1, 1));

    final result = await DeviceStore.instance.loadAllWithStatus();

    expect(result.devices.map((d) => d.id), ['dev-a']);
    expect(result.repaired, isTrue);
    expect(result.unavailable, isFalse);
    expect(backing['zremote.device.index'], '["dev-a"]');
  });

  test('索引损坏后 add：不得抹掉索引外的既有设备（F07）', () async {
    backing['zremote.device.index'] = '{corrupted';
    backing['zremote.device.old'] = deviceJson('old', DateTime(2026, 1, 1));

    await DeviceStore.instance.add(
      RemoteDevice.fromJson(
        jsonDecode(deviceJson('new', DateTime(2026, 1, 2)))
            as Map<String, dynamic>,
      ),
    );

    final devices = await DeviceStore.instance.loadAll();
    expect(devices.map((d) => d.id), ['old', 'new']);
  });

  test('secure storage 读取失败 → unavailable + typed error，不伪装空库（D05）', () async {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'readAll' || call.method == 'read') {
            throw PlatformException(code: 'storage_unavailable');
          }
          return null;
        });

    final result = await DeviceStore.instance.loadAllWithStatus();
    expect(result.unavailable, isTrue);
    expect(result.devices, isEmpty);

    await expectLater(
      DeviceStore.instance.add(
        RemoteDevice.fromJson(
          jsonDecode(deviceJson('x', DateTime(2026, 1, 1)))
              as Map<String, dynamic>,
        ),
      ),
      throwsA(isA<DeviceStoreUnavailableException>()),
    );
  });
}

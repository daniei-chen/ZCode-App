import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
}

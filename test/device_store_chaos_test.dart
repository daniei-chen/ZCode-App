import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/services/device_store.dart';

/// v1.3.0 DeviceStore 混沌测试：损坏/畸形存储必须不崩溃、尽可能恢复、
/// 坏数据隔离、索引自动修复。
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

  String deviceJson(String id, {int day = 1}) => jsonEncode({
    'id': id,
    'baseUrl': 'https://example.invalid',
    'params': const {'sid': 's', 'hash': 'h'},
    'label': 'dev-$id',
    'createdAt': DateTime(2026, 1, day).toIso8601String(),
  });

  test('索引含重复 id → 去重，设备只加载一次', () async {
    backing['zremote.device.index'] = '["a","b","a","b","a"]';
    backing['zremote.device.a'] = deviceJson('a');
    backing['zremote.device.b'] = deviceJson('b', day: 2);

    final devices = await DeviceStore.instance.loadAll();

    expect(devices.map((d) => d.id), ['a', 'b']);
  });

  test('索引为 JSON 但非数组（Map/字符串/null）→ 自愈重建', () async {
    backing['zremote.device.index'] = '{"a":1}';
    backing['zremote.device.a'] = deviceJson('a');
    expect((await DeviceStore.instance.loadAll()).map((d) => d.id), ['a']);

    backing['zremote.device.index'] = '"just-a-string"';
    expect((await DeviceStore.instance.loadAll()).map((d) => d.id), ['a']);

    backing['zremote.device.index'] = 'null';
    expect((await DeviceStore.instance.loadAll()).map((d) => d.id), ['a']);
  });

  test('索引含非字符串项 → 自愈重建', () async {
    backing['zremote.device.index'] = '["a", 5, null]';
    backing['zremote.device.a'] = deviceJson('a');

    expect((await DeviceStore.instance.loadAll()).map((d) => d.id), ['a']);
  });

  test('索引正常但设备键缺失 → 该设备跳过，其余正常', () async {
    backing['zremote.device.index'] = '["a","missing","c"]';
    backing['zremote.device.a'] = deviceJson('a');
    backing['zremote.device.c'] = deviceJson('c', day: 3);

    final devices = await DeviceStore.instance.loadAll();
    expect(devices.map((d) => d.id), ['a', 'c']);
  });

  test('设备 JSON 为旧 schema（缺字段）→ 跳过不崩溃', () async {
    backing['zremote.device.index'] = '["old","ok"]';
    backing['zremote.device.old'] = '{"id":"old","label":"legacy"}';
    backing['zremote.device.ok'] = deviceJson('ok');

    final devices = await DeviceStore.instance.loadAll();
    expect(devices.map((d) => d.id), ['ok']);
  });

  test('设备值为空/纯空白 → 跳过不崩溃', () async {
    backing['zremote.device.index'] = '["empty","ok"]';
    backing['zremote.device.empty'] = '';
    backing['zremote.device.ok'] = deviceJson('ok');

    final devices = await DeviceStore.instance.loadAll();
    expect(devices.map((d) => d.id), ['ok']);
  });

  test('索引损坏 + 存储里只有 warmup 键 → 空列表而非崩溃', () async {
    backing['zremote.device.index'] = '{broken';
    backing['zremote.warmup.a'] = '[]';

    expect(await DeviceStore.instance.loadAll(), isEmpty);
  });
}

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/device_store.dart';

/// R-05：secure storage 枚举（readAll）失败时，"读不到"不得被当成"没有设备"。
///
/// 审计反例（AUDIT_DEFECT）：索引缺失 + readAll 抛错 → 旧实现返回
/// `devices=[] + unavailable=false`，并把空索引写回：一次暂时故障被固化成
/// "设备记录消失 + 索引被抹"。修复后应返回 unavailable，且不落任何写。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final backing = <String, String>{};
  var readAllFails = false;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    backing.clear();
    readAllFails = false;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map<Object?, Object?>;
      switch (call.method) {
        case 'read':
          return backing[args['key'] as String];
        case 'readAll':
          if (readAllFails) {
            throw PlatformException(code: 'storage_unavailable');
          }
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

  String deviceJson(String id) => jsonEncode({
    'id': id,
    'baseUrl': 'https://example.invalid',
    'params': const {'sid': 's', 'hash': 'h'},
    'label': 'dev-$id',
    'createdAt': DateTime(2026).toIso8601String(),
  });

  test('索引缺失 + readAll 失败：unavailable，且不得写空索引覆盖（R-05）', () async {
    backing['zremote.device.audit-device'] = deviceJson('audit-device');
    readAllFails = true;

    final result = await DeviceStore.instance.loadAllWithStatus();

    expect(result.unavailable, isTrue, reason: '读不到 ≠ 没有设备');
    expect(result.devices, isEmpty);
    // 关键：不得把"只含本次读到的内容"的索引写回——那会抹掉尚未发现的记录。
    expect(
      backing.containsKey('zremote.device.index'),
      isFalse,
      reason: '枚举失败时写空索引 = 把暂时故障固化成永久丢数据',
    );
    expect(
      backing.containsKey('zremote.device.audit-device'),
      isTrue,
      reason: '设备记录本体必须原样保留（可重试恢复）',
    );

    // 恢复后重试：能读回设备，且这次才写回索引。
    readAllFails = false;
    final recovered = await DeviceStore.instance.loadAllWithStatus();
    expect(recovered.unavailable, isFalse);
    expect(recovered.devices.map((d) => d.id), ['audit-device']);
  });

  test('索引有效但枚举失败：已读到的设备照常返回（不误报故障）', () async {
    backing['zremote.device.index'] = '["a"]';
    backing['zremote.device.a'] = deviceJson('a');
    readAllFails = true;

    final result = await DeviceStore.instance.loadAllWithStatus();
    expect(result.unavailable, isFalse, reason: '索引可信 + 逐键读取成功 = 快照可用');
    expect(result.devices.map((d) => d.id), ['a']);
  });

  test('索引为空数组 + 枚举失败：unavailable（无法证明"真的没有设备"）', () async {
    backing['zremote.device.index'] = '[]';
    readAllFails = true;

    final result = await DeviceStore.instance.loadAllWithStatus();
    expect(result.unavailable, isTrue,
        reason: '索引 [] 只代表索引内没有；索引外的孤儿记录要靠枚举才能发现');
    expect(result.devices, isEmpty);
  });

  test('枚举失败时变更入口 fail-closed：不静默按空库继续写', () async {
    backing['zremote.device.audit-device'] = deviceJson('audit-device');
    readAllFails = true;

    await expectLater(
      DeviceStore.instance.add(
        RemoteDevice.fromJson(
          jsonDecode(deviceJson('new')) as Map<String, dynamic>,
        ),
      ),
      throwsA(isA<DeviceStoreUnavailableException>()),
    );
    expect(
      backing.containsKey('zremote.device.new'),
      isFalse,
      reason: '存储不可用时不得写入（否则会与新快照混在一起）',
    );
  });
}

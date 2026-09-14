import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/services/device_store.dart';

/// v1.1.8 锁屏恢复出口的数据层：确认标记存放在**安全存储**
/// （与 SharedPreferences 独立的文件与密钥）——SharedPreferences 损坏时
/// 它是唯一还能写进去的地方，启动失败回退凭它放行。
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

  test('确认标记默认不存在', () async {
    expect(await DeviceStore.instance.securityResetAcknowledged(), isFalse);
  });

  test('写入后读回 true；清除后读回 false', () async {
    await DeviceStore.instance.setSecurityResetAcknowledged(true);
    expect(await DeviceStore.instance.securityResetAcknowledged(), isTrue);
    expect(backing.containsKey('zremote.securityResetAck'), isTrue,
        reason: '标记必须落在安全存储后端（独立于 prefs 文件）');

    await DeviceStore.instance.setSecurityResetAcknowledged(false);
    expect(await DeviceStore.instance.securityResetAcknowledged(), isFalse);
  });

  test('重新写入门禁开关（prefs 可用）会清除确认标记', () async {
    await DeviceStore.instance.setSecurityResetAcknowledged(true);
    await DeviceStore.instance.setBiometricEnabled(false);
    expect(await DeviceStore.instance.securityResetAcknowledged(), isFalse,
        reason: '后端恢复后，旧标记不得再静默放行');
  });

  test('安全存储读取异常时不抛给调用方（按未确认处理）', () async {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'storage_unavailable');
    });
    expect(await DeviceStore.instance.securityResetAcknowledged(), isFalse);
  });
}

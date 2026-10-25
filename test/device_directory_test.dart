import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/state/device_directory.dart';

void main() {
  test('解析官方响应形状（zod schema 实证）：code=0 + data[]', () {
    final body = '''
{"code":0,"msg":"ok","data":[
  {"device_sid":"d_A","device_mid":"mid-1","online":true,"created_at":1789000000,
   "meta":{"name":"PC-20260816OWHB","platform":"win32","version":"3.16.3"}},
  {"device_sid":"d_B","device_mid":"mid-2","online":false,
   "meta":{"platform":"darwin"}}
]}
''';
    final devices = DeviceDirectoryNotifier.parse(body);
    expect(devices, hasLength(2));
    expect(devices![0].sid, 'd_A');
    expect(devices[0].online, isTrue);
    expect(devices[0].displayName, 'PC-20260816OWHB');
    expect(devices[0].platform, 'win32');
    expect(devices[1].online, isFalse);
    expect(devices[1].name, isNull);
    // 无名设备回退到 mid 前缀，绝不显示空串。
    expect(devices[1].displayName, 'PC mid-2');
  });

  test('code≠0 / 非对象 / 缺 data 一律 null（不抛）', () {
    expect(DeviceDirectoryNotifier.parse('{"code":1,"msg":"denied"}'), isNull);
    expect(DeviceDirectoryNotifier.parse('[]'), isNull);
    expect(DeviceDirectoryNotifier.parse('garbage'), isNull);
    expect(DeviceDirectoryNotifier.parse('{"code":0}'), isNull);
  });

  test('坏条目跳过，好条目保留', () {
    final body =
        '{"code":0,"data":[{"device_sid":"d_OK","device_mid":"m1","online":true},{"device_sid":"","device_mid":"m2"}]}';
    final devices = DeviceDirectoryNotifier.parse(body);
    expect(devices, hasLength(1));
    expect(devices![0].sid, 'd_OK');
  });
}

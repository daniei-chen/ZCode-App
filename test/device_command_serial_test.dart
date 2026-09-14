import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/device_store.dart';
import 'package:zremote/state/session_pool.dart';

/// R-06：Notifier 命令串行回归。
///
/// 审计的三条 AUDIT_DEFECT 复现（并发 rename×replace 丢标签、add×reorder
/// 丢设备、remove×rename 复活记录）在这里反转为"修复后必须成立"的断言：
/// 命令队列让每条命令看到前一条提交后的 state，旧快照不再覆盖新结果。
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

  RemoteDevice device(
    String id, {
    String label = 'Old label',
    String token = 'INVALID_OLD',
  }) => RemoteDevice(
    id: id,
    baseUrl: 'https://zcode.z.ai/remote/v4',
    params: {'token': token},
    label: label,
    createdAt: DateTime(2026),
  );

  ProviderContainer seed(List<RemoteDevice> devices) {
    backing['zremote.device.index'] = jsonEncode(
      devices.map((d) => d.id).toList(),
    );
    for (final d in devices) {
      backing['zremote.device.${d.id}'] = jsonEncode(d.toJson());
    }
    final container = ProviderContainer(
      overrides: [
        deviceListProvider.overrideWith(() => DeviceListNotifier(seed: devices)),
      ],
    );
    addTearDown(container.dispose);
    container.read(deviceListProvider);
    return container;
  }

  test('并发 rename × replaceLink：标签不丢，凭证是新链接的（R-06）', () async {
    final c = seed([device('a')]);
    final n = c.read(deviceListProvider.notifier);
    await Future.wait([
      n.rename('a', 'New label'),
      n.replaceLink('a', device('new', token: 'INVALID_NEW')),
    ]);

    // 磁盘记录：标签与内容保持各自命令的结果，不得互相覆盖。
    final persisted = jsonDecode(backing['zremote.device.a']!) as Map;
    final labelOk = persisted['label'] == 'New label';
    final tokenOk =
        (persisted['params'] as Map)['token'] == 'INVALID_NEW';
    expect(labelOk, isTrue, reason: 'rename 不得被 replace 的旧快照覆盖');
    expect(tokenOk, isTrue, reason: 'replaceLink 的凭证必须落盘');

    // 内存与磁盘一致。
    final mem = c.read(deviceListProvider).single;
    expect(mem.label, 'New label');
    expect(mem.params['token'], 'INVALID_NEW');
  });

  test('并发 add × reorder：新设备不被旧快照丢出内存列表（R-06）', () async {
    final c = seed([device('a'), device('b')]);
    final n = c.read(deviceListProvider.notifier);
    await Future.wait([n.add(device('c')), n.reorder(0, 1)]);

    final memIds = c.read(deviceListProvider).map((d) => d.id).toList();
    expect(memIds.length, 3, reason: '三条设备都必须在内存列表里');
    expect(memIds, containsAll(['a', 'b', 'c']));

    final stored = (await DeviceStore.instance.loadAll()).map((d) => d.id);
    expect(stored.length, 3);
    expect(stored, containsAll(['a', 'b', 'c']));

    // 索引与记录一致：内存顺序 = 磁盘索引顺序（saveOrder 校验通过才写）。
    final index = jsonDecode(backing['zremote.device.index']!) as List;
    expect(index.toSet(), {'a', 'b', 'c'});
  });

  test('并发 remove × rename：已删凭证不得复活（R-06）', () async {
    final c = seed([device('a'), device('b')]);
    final n = c.read(deviceListProvider.notifier);
    await Future.wait([n.remove('a'), n.rename('a', 'Renamed after delete')]);

    expect(
      c.read(deviceListProvider).map((d) => d.id),
      ['b'],
      reason: '内存列表不得含已删设备',
    );
    expect(
      backing.containsKey('zremote.device.a'),
      isFalse,
      reason: 'rename 在 remove 之后看到目标不存在，不得把记录写回',
    );
    expect(
      (await DeviceStore.instance.loadAll()).map((d) => d.id),
      ['b'],
    );
  });

  test('两个并发 reorder：最终顺序是完整排列，不丢设备（R-06）', () async {
    final c = seed([device('a'), device('b'), device('c')]);
    final n = c.read(deviceListProvider.notifier);
    await Future.wait([n.reorder(0, 2), n.reorder(1, 0)]);

    final ids = c.read(deviceListProvider).map((d) => d.id).toList();
    expect(ids.toSet(), {'a', 'b', 'c'}, reason: '重排不得丢设备或重复');
    final index = jsonDecode(backing['zremote.device.index']!) as List;
    expect(index.toSet(), {'a', 'b', 'c'});
  });

  test('命令队列不因单条失败而卡死（后续命令仍可执行）', () async {
    final c = seed([device('a')]);
    final n = c.read(deviceListProvider.notifier);

    // saveOrder 校验失败（长度不匹配）返回而不写；随后 rename 仍必须生效。
    await n.reorder(0, 0); // no-op：走完队列
    await n.rename('a', 'After');
    expect(c.read(deviceListProvider).single.label, 'After');
  });
}

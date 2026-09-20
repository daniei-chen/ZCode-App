import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/event_observer.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/state/event_history.dart';
import 'package:zremote/state/protected_wipe.dart';
import 'package:zremote/state/session_pool.dart';

/// 待处理中心（升级路线图）的事件历史：有界、清洗、生命周期。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  ObservedEvent ev(
    String type, {
    String? taskId,
    String? summary,
    String? sessionTitle,
    int? pendingTotal,
  }) => ObservedEvent(
    type: type,
    taskId: taskId,
    summary: summary,
    sessionTitle: sessionTitle,
    pendingTotal: pendingTotal,
  );

  test('record：新在前，字段保留；空 deviceId 不记录', () {
    final h = container.read(eventHistoryProvider.notifier);
    h.record('d1', ev('completed', taskId: 't1', summary: '第一次'));
    h.record('d1', ev('error', taskId: 't2', summary: '第二次'));
    h.record('', ev('error')); // no-op

    final list = container.read(eventHistoryProvider)['d1']!;
    expect(list, hasLength(2));
    expect(list.first.type, 'error');
    expect(list.first.summary, '第二次');
    expect(list.last.type, 'completed');
    expect(container.read(eventHistoryProvider).containsKey(''), isFalse);
  });

  test('record：bidi 控制符剥离、超长按 120 码元截断（不切代理对）', () {
    final h = container.read(eventHistoryProvider.notifier);
    final long = 'a' * 119 + '\u{1F600}' + 'tail';
    h.record('d1', ev('completed', summary: '\u202E伪装\u202C', sessionTitle: long));

    final e = container.read(eventHistoryProvider)['d1']!.first;
    expect(e.summary, '伪装');
    // 切点恰逢代理对高位 → 回退一位：结果 ≤120 且不以孤立高位代理结尾。
    expect(e.sessionTitle!.length, 119);
    final last = e.sessionTitle!.codeUnitAt(e.sessionTitle!.length - 1);
    expect(last & 0xFC00, isNot(0xD800), reason: '末尾不得是孤立高位代理');
  });

  test('taskId 与跳转白名单上限对齐（≤128 截断）', () {
    final h = container.read(eventHistoryProvider.notifier);
    h.record('d1', ev('permission_request', taskId: 't' * 200));
    final e = container.read(eventHistoryProvider)['d1']!.first;
    expect(e.taskId, hasLength(128));
  });

  test('上限：第 51 条挤掉最旧，最新保留', () {
    final h = container.read(eventHistoryProvider.notifier);
    for (var i = 0; i < 51; i++) {
      h.record('d1', ev('completed', taskId: 't$i'));
    }
    final list = container.read(eventHistoryProvider)['d1']!;
    expect(list, hasLength(EventHistoryNotifier.maxEntriesPerDevice));
    expect(list.first.taskId, 't50');
    expect(list.map((e) => e.taskId), isNot(contains('t0')));
  });

  test('forget 移除该设备；clearAll 全清；多设备互不影响', () {
    final h = container.read(eventHistoryProvider.notifier);
    h.record('d1', ev('completed'));
    h.record('d2', ev('error'));
    h.forget('d1');
    expect(container.read(eventHistoryProvider).containsKey('d1'), isFalse);
    expect(container.read(eventHistoryProvider).containsKey('d2'), isTrue);
    h.clearAll();
    expect(container.read(eventHistoryProvider), isEmpty);
  });

  test('latestPendingRequest：只认仍在等待的审批类（权威键过滤），取最新一条', () {
    final h = container.read(eventHistoryProvider.notifier);
    h.record('d1', ev('completed', taskId: 't-done'));
    h.record('d1', ev('permission_request', taskId: 't-perm'));
    h.record('d1', ev('completed', taskId: 't-newer')); // 更新的非审批类
    final list = container.read(eventHistoryProvider)['d1']!;
    expect(latestPendingRequest(list, {'t-perm'})?.taskId, 't-perm');

    // 复核 F2：最新的审批类已被 resolved（不在权威键里）→ 跳过它命中更旧的等待项。
    const newer = <HistoryEntry>[
      HistoryEntry(type: 'resolved', atMs: 30, taskId: 't-req2'),
      HistoryEntry(type: 'permission_request', atMs: 20, taskId: 't-req2'),
      HistoryEntry(type: 'permission_request', atMs: 10, taskId: 't-req1'),
    ];
    expect(latestPendingRequest(newer, {'t-req1'})?.taskId, 't-req1');

    // type 检查可观察面：同 taskId 的非审批类更旧条目在权威键里也不得被选中。
    const mixed = <HistoryEntry>[
      HistoryEntry(type: 'completed', atMs: 40, taskId: 't-mix'),
      HistoryEntry(type: 'permission_request', atMs: 30, taskId: 't-mix'),
    ];
    expect(latestPendingRequest(mixed, {'t-mix'})?.type, 'permission_request');

    expect(latestPendingRequest(const [], {'x'}), isNull);
    expect(
      latestPendingRequest(const [
        HistoryEntry(type: 'permission_request', atMs: 1),
      ], {'x'}),
      isNull,
      reason: '无 taskId 的审批请求不可跳转',
    );
  });
  test('擦除事务清空历史（R-04）', () async {
    final wipeContainer = ProviderContainer();
    addTearDown(wipeContainer.dispose);
    wipeContainer
        .read(eventHistoryProvider.notifier)
        .record('d1', ev('permission_request', taskId: 't1'));
    expect(wipeContainer.read(eventHistoryProvider), isNotEmpty);
    await ProtectedStateWipe.run(wipeContainer);
    expect(
      wipeContainer.read(eventHistoryProvider),
      isEmpty,
      reason: 'iter15 复核 F3：历史含标题/摘要，必须随擦除事务清空',
    );
  });

  test('删除设备清历史（与服务面同生命周期）', () async {
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
    final removeContainer = ProviderContainer(
      overrides: [
        deviceListProvider.overrideWith(() => DeviceListNotifier(seed: [d])),
      ],
    );
    addTearDown(removeContainer.dispose);
    removeContainer.read(deviceListProvider);
    removeContainer
        .read(eventHistoryProvider.notifier)
        .record('doomed-device', ev('permission_request', taskId: 't1'));
    expect(removeContainer.read(eventHistoryProvider), contains('doomed-device'));
    await removeContainer.read(deviceListProvider.notifier).remove('doomed-device');
    expect(
      removeContainer.read(eventHistoryProvider),
      isNot(contains('doomed-device')),
      reason: 'iter15 复核 F3：设备删除必须同步清历史',
    );
  });

  test('源码钉：webview_sync 两处收口都记录历史且 forget 同生命周期', () {
    final src = File('lib/services/webview_sync.dart').readAsStringSync();
    final records = RegExp(r'history\.record\(device\.id, enriched\);')
        .allMatches(src)
        .length;
    expect(records, 2, reason: 'resolved 分支与 enabled 分支都必须记录');
    expect(
      src.contains('ref.read(eventHistoryProvider.notifier).forget(device.id);'),
      isTrue,
      reason: '页面销毁 forget 必须覆盖历史',
    );
  });
}

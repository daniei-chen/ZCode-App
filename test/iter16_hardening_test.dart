import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/models/device_label.dart';
import 'package:zremote/services/bridge_schema.dart';
import 'package:zremote/services/bridge_token.dart';
import 'package:zremote/services/device_connectivity.dart';
import 'package:zremote/services/device_store.dart';
import 'package:zremote/services/diagnostics_bundle.dart';
import 'package:zremote/services/event_observer.dart';
import 'package:zremote/services/notifier.dart';
import 'package:zremote/services/session_jump.dart';
import 'package:zremote/services/warmup.dart';
import 'package:zremote/services/webview_storage.dart';
import 'package:zremote/state/event_feed.dart';
import 'package:zremote/state/event_history.dart';
import 'package:zremote/state/pending_session_jump.dart';
import 'package:zremote/state/session_pool.dart';

/// iter16 加固批：DPI/完整性问题闭环 + 生命周期/预算/时钟口径统一。
RemoteDevice _device(String id, {Map<String, String>? params}) => RemoteDevice(
  id: id,
  baseUrl: 'https://zcode.z.ai/remote/v4',
  params: params ?? {'sid': 's-$id', 'hash': 'h'},
  label: '设备$id',
  createdAt: DateTime(2026, 1, 1),
);

const _storageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);
const _notificationsChannel = MethodChannel(
  'dexterous.com/flutter/local_notifications',
);

/// secure storage 通道的内存实现（沿用 iter12/iter15 测试的既有形态）。
void _mockSecureStorage(Map<String, String> backing) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_storageChannel, (call) async {
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
        .setMockMethodCallHandler(_storageChannel, null);
  });
}

void main() {
  // 平台通道 mock（secure storage / 通知）在纯 test() 里也要用。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('设备库完整性（iter16：生产 seed 路径可见、未知不谎报干净）', () {
    test('seed 注入结果进 provider；null 时诊断包渲染 unknown（不是 0/no）', () {
      final container = ProviderContainer(
        overrides: [
          deviceStoreIntegrityProvider.overrideWith(
            () => DeviceStoreIntegrityNotifier(
              initial: const DeviceStoreIntegrity(
                skippedRecords: 3,
                repaired: true,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final integrity = container.read(deviceStoreIntegrityProvider);
      expect(integrity?.skippedRecords, 3, reason: '冷启动注入必须立即可见');
      expect(integrity?.repaired, isTrue);

      String render({int? skipped, bool? repaired}) =>
          DiagnosticsBundle.render(
            DiagnosticsBundle.capture(
              appVersion: '1.0.0',
              buildNumber: '28',
              android: const {'release': '14', 'sdkInt': 34},
              deviceIds: const [],
              statuses: const {},
              stats: const {},
              bridgeHealth: const {},
              biometric: false,
              notificationsEnabled: false,
              batteryIgnored: false,
              storeSkippedRecords: skipped,
              storeRepaired: repaired,
            ),
          );
      final unknown = render();
      expect(unknown.contains('storeSkippedRecords = unknown'), isTrue);
      expect(unknown.contains('storeRepaired = unknown'), isTrue,
          reason: '"从未上报"不得渲染成 0/no（谎报干净）');
      final known = render(skipped: 2, repaired: true);
      expect(known.contains('storeSkippedRecords = 2'), isTrue);
      expect(known.contains('storeRepaired = yes'), isTrue);

      // 生产接线：main 用 seed 构造 DeviceListNotifier 的同一处注入本次
      // 真实加载结果（否则 seed 路径永远不会 report）。
      final src = File('lib/main.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      expect(src.contains('deviceStoreIntegrityProvider.overrideWith('), isTrue);
      expect(
        src.contains('skippedRecords: initialDevicesResult.skippedRecords'),
        isTrue,
      );
      expect(
        src.contains('repaired: initialDevicesResult.repaired'),
        isTrue,
      );
      expect(
        src.contains('initialDevicesResult.unavailable'),
        isTrue,
        reason: '存储不可用时必须注入 null（unknown），不得落成干净的 0/no',
      );

      // 运行期上报同口径（iter16 复核返修）：unavailable = "什么都没读到"。
      final notifier = container.read(deviceStoreIntegrityProvider.notifier);
      notifier.report(
        const DeviceLoadResult(devices: [], unavailable: true),
      );
      expect(
        container.read(deviceStoreIntegrityProvider),
        isNull,
        reason: 'unavailable 是未知，不是"读过且干净"',
      );
      notifier.report(
        const DeviceLoadResult(
          devices: [],
          skippedRecords: 1,
          repaired: true,
        ),
      );
      expect(container.read(deviceStoreIntegrityProvider)?.skippedRecords, 1);
      expect(container.read(deviceStoreIntegrityProvider)?.repaired, isTrue);
    });
  });

  test('仓库改址补漏：SECURITY.md / README.en.md 不再指向已封停账号', () {
    final security = File('SECURITY.md').readAsStringSync();
    final readme = File('README.en.md').readAsStringSync();
    expect(security.contains('2421873411a-rgb'), isFalse,
        reason: '安全披露入口不能指向封停账号（DEC-17 声称全部改址）');
    expect(readme.contains('2421873411a-rgb'), isFalse);
    expect(
      security.contains(
        'github.com/daniei-chen/ZCode-App/security/advisories/new',
      ),
      isTrue,
    );
    expect(
      readme.contains('github.com/daniei-chen/ZCode-App/releases'),
      isTrue,
    );
  });

  group('设备删除的通知收口（iter16）', () {
    test('撤销该设备全部通知位；指向它的陈旧跳转一并清掉', () async {
      final backing = <String, String>{};
      final cancelCalls = <Object?>[];
      final device = _device('doomed');
      backing['zremote.device.index'] = jsonEncode(['doomed']);
      backing['zremote.device.doomed'] = jsonEncode(device.toJson());
      _mockSecureStorage(backing);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_notificationsChannel, (call) async {
            if (call.method == 'cancel') {
              final args = call.arguments;
              cancelCalls.add(args is Map ? args['id'] : args);
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_notificationsChannel, null);
      });
      FlutterLocalNotificationsPlatform.instance =
          AndroidFlutterLocalNotificationsPlugin();

      final container = ProviderContainer(
        overrides: [
          deviceListProvider.overrideWith(
            () => DeviceListNotifier(seed: [device]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(deviceListProvider);
      container.read(eventFeedProvider.notifier).ingest(
        device.id,
        const ObservedEvent(
          type: 'permission_request',
          taskId: 'task-1',
          pendingTotal: 2,
        ),
      );
      container.read(eventHistoryProvider.notifier).record(
        device.id,
        const ObservedEvent(type: 'permission_request', taskId: 'task-1'),
      );
      container.read(pendingSessionJumpProvider.notifier).set(
        const PendingSessionJump(deviceId: 'doomed', sessionId: 'task-1'),
      );

      await container.read(deviceListProvider.notifier).remove('doomed');

      final expected = <int>{
        ...NotificationSpec.cancellableIds(device, 'task-1'),
        NotificationSpec.stableId(
          device,
          const ObservedEvent(type: 'completed', taskId: 'task-1'),
        ),
        NotificationSpec.stableId(
          device,
          const ObservedEvent(type: 'error', taskId: 'task-1'),
        ),
      };
      final cancelled = cancelCalls.whereType<int>().toSet();
      expect(
        cancelled.containsAll(expected),
        isTrue,
        reason: '审批/追问/完成/失败四类通知位都必须撤销（实际 $cancelled）',
      );
      expect(
        container.read(pendingSessionJumpProvider),
        isNull,
        reason: '指向已删设备的跳转没有任何消费方，不得长驻',
      );
      expect(container.read(eventHistoryProvider).containsKey('doomed'), isFalse);
    });

    test('重启后删除设备仍撤通知：持久登记 id（内存表为空也撤得掉）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final backing = <String, String>{};
      final cancelCalls = <Object?>[];
      final device = _device('doomed');
      backing['zremote.device.index'] = jsonEncode(['doomed']);
      backing['zremote.device.doomed'] = jsonEncode(device.toJson());
      _mockSecureStorage(backing);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_notificationsChannel, (call) async {
            switch (call.method) {
              case 'cancel':
                final args = call.arguments;
                cancelCalls.add(args is Map ? args['id'] : args);
                return null;
              default:
                // initialize / requestNotificationsPermission / show 一律成功。
                return null;
            }
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_notificationsChannel, null);
      });
      FlutterLocalNotificationsPlatform.instance =
          AndroidFlutterLocalNotificationsPlugin();

      // 重启前的展示：notifyFrom 成功后登记通知 id（模拟跨进程存活的系统通知）。
      const event = ObservedEvent(
        type: 'completed',
        taskId: 'task-9',
        summary: 'done',
      );
      await NotifierService.instance.notifyFrom(device, event, l10n: l10nZh);
      final shownId = NotificationSpec.stableId(device, event);
      expect(
        await DeviceStore.instance.notificationIds(device.id),
        contains(shownId),
        reason: 'show 成功必须登记 id（撤销的持久依据）',
      );

      // "重启后"：feed / history 均为空 —— 只靠内存表推不出任何 id。
      final container = ProviderContainer(
        overrides: [
          deviceListProvider.overrideWith(
            () => DeviceListNotifier(seed: [device]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(deviceListProvider);
      await container.read(deviceListProvider.notifier).remove('doomed');

      expect(
        cancelCalls.whereType<int>(),
        contains(shownId),
        reason: '重启后内存表为空，只有持久登记能把陈旧通知撤掉',
      );
      expect(
        await DeviceStore.instance.notificationIds(device.id),
        isEmpty,
        reason: '撤销后登记应清空（幂等）',
      );
    });
  });

  group('通知深链载荷（iter16）', () {
    test('decodePayload：精确两段 + 白名单，含 | 的 taskId 不截断成前缀', () {
      void expectDecoded(String payload, String deviceId, String? sessionId) {
        final decoded = SessionJump.decodePayload(payload);
        expect(decoded.$1, deviceId, reason: 'payload=$payload');
        expect(decoded.$2, sessionId, reason: 'payload=$payload');
      }

      expectDecoded('dev', 'dev', null);
      expectDecoded('dev|sess_1', 'dev', 'sess_1');
      expectDecoded(
        'dev|abc|def',
        'dev',
        null,
      );
      expectDecoded('dev|abc def', 'dev', null);
      expectDecoded('dev|', 'dev', null);
      expectDecoded('|sess', '|sess', null);
    });

    test('源码钉：AppShell 对已删设备提前返回，不写陈旧跳转', () {
      final src = File('lib/ui/app_shell.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      expect(src.contains('SessionJump.decodePayload(payload)'), isTrue);
      expect(src.contains('if (index < 0) return;'), isTrue,
          reason: '设备已删除时不得继续写 pendingSessionJump');
    });
  });

  group('截断不切代理对（iter16：三处裸 substring 迁到 clipCodeUnits）', () {
    const emoji = '\u{1F600}';

    void expectNoLoneSurrogate(String out) {
      final beforeEllipsis = out.codeUnitAt(out.length - 2);
      expect(
        beforeEllipsis & 0xFC00,
        isNot(0xD800),
        reason: '省略号前不得是孤立高位代理（半 emoji）',
      );
    }

    test('事件摘要（_eventText）与预览（_previewText）：emoji 落在 180 切点', () {
      final events = EventParser.parseRoot({
        'event': 'completed',
        'taskId': 't1',
        'summary': '${'a' * 179}$emoji tail',
      });
      expect(events, hasLength(1));
      final summary = events.first.summary!;
      expect(summary.length, 180);
      expect(summary.endsWith('…'), isTrue);
      expectNoLoneSurrogate(summary);

      final preview = SessionStateExtractor.previewOf({
        'lastAssistantText': '${'a' * 179}$emoji tail',
      });
      expect(preview, isNotNull);
      expect(preview!.length, 180);
      expectNoLoneSurrogate(preview);
    });

    test('通知标题/正文（_clip）：emoji 落在 120/180 切点', () {
      final title = NotificationSpec.titleFor(
        _device('d1'),
        '${'a' * 119}$emoji tail',
        l10nZh,
      );
      expect(title.length, 120);
      expect(title.endsWith('…'), isTrue);
      expectNoLoneSurrogate(title);

      final body = NotificationSpec.bodyFor(
        'completed',
        '${'a' * 179}$emoji tail',
        l10nZh,
      );
      expect(body.length, 180);
      expectNoLoneSurrogate(body);
    });
  });

  test('存储策略文案与实现一致：设备删除不在触发列表', () {
    expect(WebViewStorage.policySummary.contains('移除设备'), isFalse);
    expect(WebViewStorage.policySummary.contains('换凭证/锁定擦除'), isTrue);
    for (final entry in WebViewStorage.inventory.entries) {
      expect(
        entry.value.contains('移除设备'),
        isFalse,
        reason: '${entry.key} 的文案必须与实际触发点一致',
      );
    }
    // 实现侧：设备删除路径不调用站点数据清理（只有换凭证与锁定擦除）。
    final sessionPool = File('lib/state/session_pool.dart').readAsStringSync();
    expect(sessionPool.contains('clearForCredentialChange'), isFalse);
    expect(sessionPool.contains('clearAllSiteData'), isFalse);
    // 用户可见的 PRIVACY.md 与 in-app 清单同口径（iter16 复核返修：
    // 上轮只改了 webview_storage，漏了这份 README 可达的隐私文档）。
    final privacy = File('docs/PRIVACY.md').readAsStringSync();
    expect(privacy.contains('换凭证、移除设备'), isFalse,
        reason: 'PRIVACY.md 仍在声称"移除设备清空"');
    expect(privacy.contains('换凭证 / 移除设备'), isFalse,
        reason: 'PRIVACY.md 清单仍把移除设备列为清理触发点');
    expect(privacy.contains('换凭证、锁定擦除时清空'), isTrue);
    expect(privacy.contains('换凭证 / 锁定擦除'), isTrue);
  });

  group('墙钟回拨（iter16）', () {
    test('桥令牌等待预算双钟：回拨不拉长、深睡由墙钟补位', () {
      final start = DateTime(2026, 9, 20, 12);
      expect(
        BridgeTokenPolicy.waitBudgetExhausted(
          monotonic: const Duration(milliseconds: 100),
          startedWall: start,
          now: start.add(const Duration(milliseconds: 100)),
          budget: const Duration(milliseconds: 1400),
        ),
        isFalse,
        reason: '正常等待未到预算',
      );
      expect(
        BridgeTokenPolicy.waitBudgetExhausted(
          monotonic: const Duration(seconds: 5),
          startedWall: start,
          now: start.subtract(const Duration(hours: 1)),
          budget: const Duration(milliseconds: 1400),
        ),
        isTrue,
        reason: '墙钟回拨（差为负）不得把等待拉长——单调钟已超预算',
      );
      expect(
        BridgeTokenPolicy.waitBudgetExhausted(
          monotonic: const Duration(seconds: 1),
          startedWall: start,
          now: start.add(const Duration(hours: 2)),
          budget: const Duration(milliseconds: 1400),
        ),
        isTrue,
        reason: '深睡（单调冻结）由墙钟补位，等待已是真实两小时',
      );
    });

    test('EventDedupeGate 默认时钟单调（不再取 DateTime.now）', () {
      final src = File('lib/services/event_observer.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      expect(
        src.contains('clock = DateTime.now'),
        isFalse,
        reason: '墙钟回拨会让窗口永不过期 + 新事件被一律压制',
      );
      expect(src.contains('_monotonicOrigin.add(_monotonic.elapsed)'), isTrue);
      final gate = EventDedupeGate();
      final t0 = gate.clock();
      for (var i = 0; i < 100; i++) {
        expect(gate.clock().isBefore(t0), isFalse, reason: '默认时钟不得倒退');
      }
    });
  });

  group('zrSeen 预算跨层对齐（iter16）', () {
    test('钩子批次预算 = warmup 第二道门，且低于桥侧上限', () {
      expect(kMaxSeenBatchBytes, 192 * 1024);
      expect(BridgeSchema.seenCapMatchesHook, isTrue);
      expect(BridgeSchema.maxSeenBytes, greaterThan(kMaxSeenBatchBytes));
      expect(
        EventObserver.hookScript.contains(
          'kSeenBatchBytes = $kMaxSeenBatchBytes',
        ),
        isTrue,
        reason: '钩子的批次预算必须由 Dart 常量插值，不能各写一份',
      );

      // warmup 侧第二道门用同一常量、边界一致：等于预算放行、超一字节拒绝。
      expect(
        WarmupMemoryNotifier.seenBatchWithinBudget('x' * (192 * 1024)),
        isTrue,
      );
      expect(
        WarmupMemoryNotifier.seenBatchWithinBudget('x' * (192 * 1024 + 1)),
        isFalse,
      );
    });
  });

  test('预热加载的 await 后守卫：擦除纪元翻转时读结果不写回内存', () async {
    final readGate = Completer<void>();
    final script = jsonEncode([
      {'u': '/api/v1/usage-stats', 'm': 'GET'},
    ]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_storageChannel, (call) async {
          if (call.method == 'read') {
            final key = call.arguments['key'] as String;
            if (key.startsWith('zremote.warmup.')) {
              await readGate.future;
              return script;
            }
            return null;
          }
          if (call.method == 'readAll') return <String, String>{};
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_storageChannel, null);
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(warmupMemoryProvider.notifier);
    final pending = notifier.load('d1');
    // 存储在途期间擦除事务到达：清空内存态并把纪元 +1。
    notifier.clearAll();
    readGate.complete();
    await pending;
    expect(
      container.read(warmupMemoryProvider).containsKey('d1'),
      isFalse,
      reason: '擦除后到达的读结果不得把已清除设备的预热脚本写回内存',
    );
  });

  test('预热加载的 await 后守卫：设备在读取期间被删除（forget）时不写回内存', () async {
    final readGate = Completer<void>();
    final script = jsonEncode([
      {'u': '/api/v1/usage-stats', 'm': 'GET'},
    ]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_storageChannel, (call) async {
          if (call.method == 'read') {
            final key = call.arguments['key'] as String;
            if (key.startsWith('zremote.warmup.')) {
              await readGate.future;
              return script;
            }
            return null;
          }
          if (call.method == 'readAll') return <String, String>{};
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_storageChannel, null);
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(warmupMemoryProvider.notifier);
    final pending = notifier.load('d1');
    // 读取在途期间设备被删除：forget 清盘并推该设备纪元。
    await notifier.forget('d1');
    readGate.complete();
    await pending;
    expect(
      container.read(warmupMemoryProvider).containsKey('d1'),
      isFalse,
      reason: '设备已删除，在途读结果不得把它的预热脚本写回内存',
    );
  });

  group('连通性（iter16）', () {
    test('在途探测轮次不把已删设备写回 provider', () async {
      final device = _device('d1');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(deviceConnectivityProvider.notifier);
      final gate = Completer<ProbeOutcome>();
      notifier.probe = ConnectivityProbe(fetch: (_) => gate.future);

      final round = notifier.probeAll([device], const {});
      notifier.forget('d1'); // remove 的清理（设备随后从清单删除）
      gate.complete(ProbeOutcome.ok);
      await round;

      expect(
        container.read(deviceConnectivityProvider).containsKey('d1'),
        isFalse,
        reason: 'forget 之后旧轮次不得把结果插回来',
      );
    });

    test('擦除 clear() 之后的在途轮次不写回任何结果', () async {
      final device = _device('d1');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(deviceConnectivityProvider.notifier);
      final gate = Completer<ProbeOutcome>();
      notifier.probe = ConnectivityProbe(fetch: (_) => gate.future);

      final round = notifier.probeAll([device], const {});
      notifier.clear(); // 擦除事务（R-04）
      gate.complete(ProbeOutcome.ok);
      await round;

      expect(
        container.read(deviceConnectivityProvider),
        isEmpty,
        reason: '擦除后不得再落任何探测结果',
      );
    });

    test('replaceLink 清掉旧链接的探测结果（probeUri 随 path 变化）', () async {
      final backing = <String, String>{};
      final device = _device('d1');
      backing['zremote.device.index'] = jsonEncode(['d1']);
      backing['zremote.device.d1'] = jsonEncode(device.toJson());
      _mockSecureStorage(backing);

      final container = ProviderContainer(
        overrides: [
          deviceListProvider.overrideWith(
            () => DeviceListNotifier(seed: [device]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(deviceListProvider);
      final notifier = container.read(deviceConnectivityProvider.notifier);
      notifier.probe = ConnectivityProbe(fetch: (_) async => ProbeOutcome.ok);
      await notifier.probeAll([device], const {});
      expect(container.read(deviceConnectivityProvider)['d1'], ProbeOutcome.ok);

      await container.read(deviceListProvider.notifier).replaceLink(
        'd1',
        _device('d1', params: const {'sid': 'new', 'hash': 'new'}),
      );
      expect(
        container.read(deviceConnectivityProvider).containsKey('d1'),
        isFalse,
        reason: '换到不同 /remote/vN 路径后旧探测结果的语义已变',
      );
    });
  });

  test('源码钉：观测热路径不再做 activeSession 整树扫描/写 provider', () {
    final src = File('lib/services/webview_sync.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(
      RegExp(r'ActiveSessionExtractor\.parseRoot\(').hasMatch(src),
      isFalse,
      reason: '无消费方的全树递归扫描不留在每条桥消息的热路径上',
    );
    expect(src.contains('activeSessionProvider.notifier).report'), isFalse,
        reason: '写完没人读的状态面不再写入');
  });

  test('源码钉：桥回调 await 后 mounted 守卫在位（iter16 复核返修）', () {
    final src = File('lib/ui/official_remote_page.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    // zrViewState / zrSeen / zrStats / zrWs 四个回调的守卫（zrEvents 用
    // context.mounted，另算）。
    expect(
      RegExp(r'if \(!mounted\) return null;').allMatches(src).length,
      greaterThanOrEqualTo(4),
      reason: '桥回调 await 之后必须重新检查 mounted 再碰 ref',
    );
    expect(
      src.contains(
        'if (!mounted || _bridgeToken != token) return false;\n'
        '          _markBridgeTokenReady();',
      ),
      isTrue,
      reason: '令牌读回成功后的 provider 写入必须带卸载守卫',
    );
    expect(
      src.contains(
        '// 日志本身仍留痕（全局缓冲，不碰 ref）。\n    if (mounted) {',
      ),
      isTrue,
      reason: '_logTokenMissing 的 provider 上报必须带卸载守卫',
    );
  });
}

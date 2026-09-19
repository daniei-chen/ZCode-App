import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/notification_prefs.dart';
import 'package:zremote/services/app_settings.dart';
import 'package:zremote/services/biometric.dart';
import 'package:zremote/services/diagnostics_bundle.dart';
import 'package:zremote/services/device_store.dart';
import 'package:zremote/services/event_observer.dart';
import 'package:zremote/services/structured_log.dart';
import 'package:zremote/services/text_sanitize.dart';
import 'package:zremote/services/update_service.dart';
import 'package:zremote/services/warmup.dart';
import 'package:zremote/state/bridge_health.dart';
import 'package:zremote/state/event_feed.dart';
import 'package:zremote/state/protected_wipe.dart';
import 'package:zremote/state/session_index.dart';
import 'package:zremote/state/session_pool.dart';

import 'package:local_auth/local_auth.dart';
// ignore: depend_on_referenced_packages
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart'
    show AuthMessages;

/// ITERATION 12 加固批：零上下文深探审计（WebView/网络面 + 状态/持久化面）
/// 发现的修复项，逐条"回退即失败"钉住。编号沿用审计报告（N-P1-1 等）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('源码钉：盖板状态机（official_remote_page 无 WebView 测试环境）', () {
    final src = File('lib/ui/official_remote_page.dart').readAsStringSync();

    test('N-P1-1：_armBootCover 必须重置 _takeoverLogged（否则第二次顶号无日志）', () {
      final start = src.indexOf('void _armBootCover()');
      expect(start, greaterThan(0), reason: '钩子函数应存在');
      final body = src.substring(start, src.indexOf('_startPageStateWatch();', start));
      expect(
        body.contains('_takeoverLogged = false;'),
        isTrue,
        reason: '顶号日志节流必须按新一轮加载重置（N-P1-1）',
      );
    });

    test('N-P2-1：三处揭盖点都必须停掉盖板跟随计时器', () {
      expect(src.contains('void _disarmCoverWatch()'), isTrue);
      final calls = RegExp('_disarmCoverWatch\\(\\);').allMatches(src).length;
      expect(
        calls,
        3,
        reason: 'deadline 揭盖 / 失败揭盖 / 探针揭盖三处都必须 disarm',
      );
    });

    test('N-P2-1 配套：盖板纪元护栏（揭盖/重挂递增，陈旧探针作废）', () {
      expect(RegExp('_coverEpoch\\+\\+;').allMatches(src).length, 2,
          reason: 'disarm 与 armBootCover 两处都必须递增纪元');
      expect(
        src.contains('if (epochAtProbe != _coverEpoch) return;'),
        isTrue,
        reason: '探针 apply 前必须校验纪元，陈旧探针不得逆转揭盖/重挂',
      );
    });
  });

  group('N-P2-3：session_index 合并视图上限', () {
    late ProviderContainer container;
    setUp(() {
      container = ProviderContainer();
      addTearDown(container.dispose);
    });

    SessionState sess(String id, {bool pinned = false}) =>
        SessionState(sessionId: id, pinned: pinned);

    test('两表各 5000 个互不相同的 id：合并视图也必须 ≤ 上限', () {
      final notifier = container.read(sessionIndexProvider.notifier);
      notifier.upsertTasks(
        'd1',
        [for (var i = 0; i < 5000; i++) sess('task-$i')],
      );
      notifier.upsertAll(
        'd1',
        [for (var i = 0; i < 5000; i++) sess('sess-$i')],
      );
      final merged = container.read(sessionIndexProvider)['d1']!;
      expect(
        merged.length,
        lessThanOrEqualTo(SessionIndexNotifier.maxEntriesPerDevice),
        reason: '合并视图不设防时可达 2×上限（N-P2-3）',
      );
    });

    test('合并视图驱逐同样保护钉住会话', () {
      final notifier = container.read(sessionIndexProvider.notifier);
      notifier.upsertAll(
        'd1',
        [for (var i = 0; i < 4999; i++) sess('sess-$i')],
      );
      final pinnedId = 'pinned-target';
      notifier.upsertTasks('d1', [sess(pinnedId, pinned: true)]);
      notifier.upsertTasks(
        'd1',
        [for (var i = 0; i < 4999; i++) sess('task-$i')],
      );
      final merged = container.read(sessionIndexProvider)['d1']!;
      expect(merged[pinnedId]?.pinned ?? false, isTrue,
          reason: '洪泛不得挤掉钉住标记');
    });
  });

  group('N-P2-5：event_feed pendingByTask 硬上限', () {
    late ProviderContainer container;
    setUp(() {
      container = ProviderContainer();
      addTearDown(container.dispose);
    });

    test('灌唯一 taskId：上限内不提前驱逐，超限有界且最新键受保护', () {
      // 阈值带（复核 P1）：上限之内一个键都不能少——把"超限才压"变异成
      // "每次插入都压"时，这里从 1999 变 1750，必须变红。
      final band = ProviderContainer();
      addTearDown(band.dispose);
      final bandNotifier = band.read(eventFeedProvider.notifier);
      final cap = EventFeedNotifier.maxPendingTasks;
      for (var i = 0; i < cap - 1; i++) {
        bandNotifier.ingest(
          'd1',
          ObservedEvent(
            type: 'permission_request',
            taskId: 'band-$i',
            pendingTotal: 1,
          ),
        );
      }
      expect(
        band.read(eventFeedProvider)['d1']!.pendingByTask,
        hasLength(cap - 1),
        reason: '未超限时不得提前驱逐（cap=$cap）',
      );

      // 超限：有界 + 最新写入的键受保护。
      final notifier = container.read(eventFeedProvider.notifier);
      final total = cap + 500;
      for (var i = 0; i < total; i++) {
        notifier.ingest(
          'd1',
          ObservedEvent(
            type: 'permission_request',
            taskId: 'task-$i',
            pendingTotal: 1,
          ),
        );
      }
      final pending = container.read(eventFeedProvider)['d1']!.pendingByTask;
      expect(pending.length, lessThanOrEqualTo(EventFeedNotifier.maxPendingTasks));
      expect(
        pending.containsKey('task-${total - 1}'),
        isTrue,
        reason: '最近写入的键不得被本轮数据自己挤出',
      );
    });
  });

  group('W-021：Bidi 控制符清洗', () {
    test('TextSanitize：剥离 U+202A–E / U+2066–69，其余原样', () {
      const dirty = 'a\u202Eevil\u202Cb\u2066x\u2069';
      expect(TextSanitize.stripBidiControls(dirty), 'aevilbx');
      expect(TextSanitize.stripBidiControls('干净文本'), '干净文本');
      expect(TextSanitize.stripBidiControls(null), isNull);
      // 无控制符时返回同一实例（快速路径，不复制）。
      const clean = 'hello';
      expect(identical(TextSanitize.stripBidiControls(clean), clean), isTrue);
    });

    test('event_feed：lastSummary/lastSessionTitle 入表前清洗', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(eventFeedProvider.notifier).ingest(
        'd1',
        const ObservedEvent(
          type: 'permission_request',
          summary: '\u202Egpu\u202Dinstall',
          sessionTitle: '\u2066T\u2069ask',
        ),
      );
      final feed = container.read(eventFeedProvider)['d1']!;
      expect(feed.lastSummary, 'gpuinstall');
      expect(feed.lastSessionTitle, 'Task');
    });

    test('session_index：标题/预览/工作区入表前清洗', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(sessionIndexProvider.notifier).upsertTasks('d1', [
        const SessionState(
          sessionId: 's1',
          title: '标题\u202E伪装',
          preview: '\u202B预\u202C览',
          workspace: '\u2066ws\u2069',
        ),
      ]);
      final s = container.read(sessionIndexProvider)['d1']!['s1']!;
      expect(s.title, '标题伪装');
      expect(s.preview, '预览');
      expect(s.workspace, 'ws');
    });
  });

  group('N-P2-6：update tag 归一收紧', () {
    test('带后缀的 tag 一律非法（fail-closed，不参与比较）', () {
      expect(UpdateService.normalizeVersion('v1.2.3-rc.1'), isNull);
      expect(UpdateService.normalizeVersion('1.2.3-malicious'), isNull);
      expect(UpdateService.normalizeVersion('v9.9.9-beta'), isNull);
    });
    test('合法形态兼容：v 前缀 / 两段 / 首尾空白', () {
      expect(UpdateService.normalizeVersion('v1.6.0'), '1.6.0');
      expect(UpdateService.normalizeVersion('v1.2'), '1.2.0');
      expect(UpdateService.normalizeVersion('1.2.3'), '1.2.3');
      expect(UpdateService.normalizeVersion(' v1.2.3 '), '1.2.3');
      expect(UpdateService.normalizeVersion('release-2026'), isNull);
    });
  });

  group('N-P3-2：warmup 不收录 query/fragment', () {
    test('带 query 的只读面板请求不再进入重放脚本', () {
      final script = WarmupReplay.script([
        const WarmupRequest(url: '/api/v1/usage-stats', method: 'GET'),
        const WarmupRequest(
          url: '/api/v1/usage-stats?range=7d&user=input-term',
          method: 'GET',
        ),
        const WarmupRequest(url: '/api/v1/models#frag', method: 'GET'),
      ]);
      expect(script, contains('/api/v1/usage-stats'));
      expect(
        script.contains('usage-stats?'),
        isFalse,
        reason: 'query 含用户输入，不进安全存储、不重放（N-P3-2）',
      );
      expect(script.contains('#frag'), isFalse);
    });
  });

  group('W-021 杂项', () {
    test('alertMode 白名单归一：未知值回落 sound', () {
      expect(NotificationPrefs.normalizeAlertMode(null),
          NotificationPrefs.kAlertSound);
      expect(NotificationPrefs.normalizeAlertMode('bogus'),
          NotificationPrefs.kAlertSound);
      expect(NotificationPrefs.normalizeAlertMode('vibrate'), 'vibrate');
      expect(NotificationPrefs.normalizeAlertMode('silent'), 'silent');
    });

    test('startupTarget 白名单归一：未知值回落 lastDevice', () async {
      SharedPreferences.setMockInitialValues({
        'zremote.startupTarget': 'bogus-value',
      });
      expect(await DeviceStore.instance.startupTarget(), 'lastDevice');
      SharedPreferences.setMockInitialValues({
        'zremote.startupTarget': 'launcher',
      });
      expect(await DeviceStore.instance.startupTarget(), 'launcher');
    });

    test('LogRedactor._clip 不产出孤立代理', () {
      // 相对路由走 _clip 直路径（绝对 URL 会被 Uri.parse 规范化成百分号编码，
      // 代理对消失，探不到切点）。
      final emoji = '\u{1F600}';
      final path =
          '${'a' * (LogRedactor.maxRouteChars - 1)}$emoji${'x' * 10}';
      final out = LogRedactor.route(path);
      final last = out.codeUnitAt(out.length - 1);
      expect(last & 0xFC00, isNot(0xD800), reason: '末尾不得是孤立高位代理');
      expect(out.length, LogRedactor.maxRouteChars - 1);
    });

    test('bridge_health：旧 generation 迟到状态两个方向都不得覆盖新代', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(bridgeHealthProvider.notifier);
      notifier.report('d1', 3, ready: true);
      notifier.report('d1', 2, ready: false);
      expect(container.read(bridgeHealthProvider)['d1']!.generation, 3);
      notifier.report('d1', 2, ready: true);
      expect(container.read(bridgeHealthProvider)['d1']!.generation, 3);
    });

    test('biometric：sinceLastSuccess 单调时长（成功后非空，失败前为 null）', () async {
      final svc = BiometricService.forTesting(_ScriptedAuth(() => true));
      expect(svc.sinceLastSuccess, isNull);
      expect(await svc.authenticate('r'), isTrue);
      final since = svc.sinceLastSuccess;
      expect(since, isNotNull);
      expect(since!, lessThan(const Duration(seconds: 10)));
      expect(svc.lastSuccessAt, isNotNull);
    });

    test('AppSettings.notificationsEnabled：未知一律 false（fail-closed）', () async {
      const channel = MethodChannel('zremote/app');
      Future<Object?>? Function(MethodCall)? handler;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) => handler?.call(call));
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      handler = (_) async => true;
      expect(await AppSettings.notificationsEnabled(), isTrue);

      handler = (_) async => null;
      expect(await AppSettings.notificationsEnabled(), isFalse,
          reason: '通道返回空 = 未知，不得谎报已开启');

      handler = (_) async => throw PlatformException(code: 'boom');
      expect(await AppSettings.notificationsEnabled(), isFalse,
          reason: '通道异常 = 未知，不得谎报已开启');
    });

    test('integrity provider：加载结果上报 + 清空', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(deviceStoreIntegrityProvider), isNull);
      container.read(deviceStoreIntegrityProvider.notifier).report(
            const DeviceLoadResult(
              devices: [],
              skippedRecords: 3,
              repaired: true,
            ),
          );
      final integrity = container.read(deviceStoreIntegrityProvider);
      expect(integrity?.skippedRecords, 3);
      expect(integrity?.repaired, isTrue);
      container.read(deviceStoreIntegrityProvider.notifier).clear();
      expect(container.read(deviceStoreIntegrityProvider), isNull);
    });

    test('诊断包 settings 段含设备库完整性两行（只有数字/枚举）', () {
      final text = DiagnosticsBundle.render(
        DiagnosticsBundle.capture(
          appVersion: '1.0.0',
          buildNumber: '27',
          android: const {'release': '14', 'sdkInt': 34},
          deviceIds: const [],
          statuses: const {},
          stats: const {},
          bridgeHealth: const {},
          biometric: false,
          notificationsEnabled: false,
          batteryIgnored: false,
          storeSkippedRecords: 2,
          storeRepaired: true,
        ),
      );
      expect(text.contains('storeSkippedRecords = 2'), isTrue);
      expect(text.contains('storeRepaired = yes'), isTrue);
    });
  });

  group('复核返修：双钟 relock 证据 / 标题代理对 / 擦除覆盖', () {
    test('relockEvidence：深睡（墙钟大）与回拨（单调大）两场景都取真值', () {
      final now = DateTime(2026, 9, 19, 12);
      // 深睡：单调钟冻结在 1s，墙钟差 2h → 取 2h（旧单调实现会漏 relock）。
      expect(
        BiometricService.relockEvidence(
          monotonic: const Duration(seconds: 1),
          wallSince: now.subtract(const Duration(hours: 2)),
          now: now,
        ),
        const Duration(hours: 2),
      );
      // 回拨：墙钟被拨回 1h（差值为负），单调真实 5min → 取 5min。
      expect(
        BiometricService.relockEvidence(
          monotonic: const Duration(minutes: 5),
          wallSince: now.add(const Duration(hours: 1)),
          now: now,
        ),
        const Duration(minutes: 5),
      );
      // 双参皆 null → zero（调用方须先判"有无记录"）。
      expect(
        BiometricService.relockEvidence(monotonic: null, wallSince: null, now: now),
        Duration.zero,
      );
    });

    test('标题截断：emoji 落在 120 切点上不产出孤立代理', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final title = 'a' * 119 + '\u{1F600}' + 'tail';
      container.read(eventFeedProvider.notifier).ingest(
        'd1',
        ObservedEvent(
          type: 'permission_request',
          summary: 'x',
          sessionTitle: title,
        ),
      );
      final out = container.read(eventFeedProvider)['d1']!.lastSessionTitle!;
      final last = out.codeUnitAt(out.length - 2); // '…' 之前
      expect(last & 0xFC00, isNot(0xD800), reason: '省略号前不得是孤立高位代理');
      expect(out.endsWith('…'), isTrue);
    });

    test('擦除事务清掉设备库完整性计数（同生命周期口径）', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(deviceStoreIntegrityProvider.notifier).report(
            const DeviceLoadResult(devices: [], skippedRecords: 1, repaired: true),
          );
      expect(
        ProtectedStateWipe.coveredProviders,
        contains('deviceStoreIntegrityProvider'),
      );
      // 读 deviceListProvider 会触发 build→_load 的异步报告；先排空它，
      // 否则擦除清掉后又被在途 _load 的 report 顶回来（测试编排问题，
      // 生产中 load 只发生在启动/重试，与擦除无并发窗口）。
      container.read(deviceListProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final wipeResult = await ProtectedStateWipe.run(container);
      expect(wipeResult.steps.first.ok,
          isTrue, reason: 'providers 步必须成功，清 integrity 才算执行');
      expect(container.read(deviceStoreIntegrityProvider), isNull);
    });
  });
}

class _ScriptedAuth extends LocalAuthentication {
  _ScriptedAuth(this._script);

  final Object Function() _script;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<AuthMessages> authMessages = const <AuthMessages>[],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async {
    final result = _script();
    if (result is bool) return result;
    throw result;
  }
}

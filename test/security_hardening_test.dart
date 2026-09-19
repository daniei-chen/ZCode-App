import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/l10n/app_localizations_zh.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/bridge_message_pipeline.dart';
import 'package:zremote/services/event_observer.dart';
import 'package:zremote/services/in_page_back.dart';
import 'package:zremote/services/notifier.dart';
import 'package:zremote/services/session_jump.dart';
import 'package:zremote/services/structured_log.dart';
import 'package:zremote/state/event_feed.dart';
import 'package:zremote/state/session_index.dart';

/// ITERATION 5 安全加固（R3 审计 S-1..S-9）的回归钉。
/// 每条对应一处修复；"回退即失败"变异见 `tools/iteration/mutations/iter5.json`。
void main() {
  group('S-2 JSON 深度炸弹防护', () {
    test('深度 64 以内可解析，超过上限整帧丢弃', () {
      final ok = '[' * 64 + ']' * 64;
      expect(BridgeMessagePipeline.decode(ok), isA<List<dynamic>>());
      expect(BridgeMessagePipeline.decode('[' * 65 + ']' * 65), isNull);
      expect(BridgeMessagePipeline.decode('[' * 1000000), isNull);
    });

    test('字符串内的括号不计入深度', () {
      final body = jsonEncode(['[[[[[[[[' * 20, ']]]]]]]]' * 20]);
      final decoded = BridgeMessagePipeline.decode(body) as List<dynamic>;
      expect(decoded.first, '[[[[[[[[' * 20);
    });

    test('普通消息不受影响', () {
      expect(
        BridgeMessagePipeline.decode('{"a": [1, {"b": "c"}]}'),
        {'a': [1, {'b': 'c'}]},
      );
    });
  });

  group('S-1 会话索引与 differ 基线有界', () {
    test('SessionIndex 6000 条唯一 id：收敛到上限，最旧的被逐出、可重新进入', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionIndexProvider.notifier);
      SessionState s(String id) => SessionState(sessionId: id, phase: 'running');
      notifier.upsertAll('dev', [for (var i = 0; i < 6000; i++) s('s${'$i'.padLeft(6, '0')}')]);
      final after = container.read(sessionIndexProvider)['dev']!;
      // 驱逐到上限的 7/8（留 1/8 headroom，避免每次插入都触发驱逐）。
      expect(
        after.length,
        SessionIndexNotifier.maxEntriesPerDevice -
            SessionIndexNotifier.maxEntriesPerDevice ~/ 8,
      );
      expect(after.containsKey('s000000'), isFalse, reason: '最旧被逐出');
      expect(after.containsKey('s005999'), isTrue);
      // 被逐出的会话再次上报仍会重新建立（驱逐不是拉黑）。
      notifier.upsertAll('dev', [s('s000000')]);
      expect(container.read(sessionIndexProvider)['dev']!.containsKey('s000000'), isTrue);
    });

    test('StateDiffer 基线封顶：被驱逐的会话下次出现重新产生边沿事件', () {
      final differ = StateDiffer();
      List<SessionState> states() => [
        for (var i = 0; i < 12000; i++)
          SessionState(
            sessionId: 's${'$i'.padLeft(6, '0')}',
            phase: 'running',
            permissionCount: 1,
          ),
      ];
      expect(differ.apply(states()), hasLength(12000));
      // 无界实现下第二次全为 0 边沿；封顶后被逐出的 2000 条重新产生请求事件。
      expect(differ.apply(states()), hasLength(12000 - StateDiffer.maxPrevEntries));
    });

    test('replaceTasks 快照整体替换同样收敛到上限（S-1/N-3）', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionIndexProvider.notifier);
      notifier.replaceTasks('dev', [
        for (var i = 0; i < 7000; i++)
          SessionState(sessionId: 't${'$i'.padLeft(6, '0')}', phase: 'idle'),
      ]);
      expect(
        container.read(sessionIndexProvider)['dev']!.length,
        SessionIndexNotifier.maxEntriesPerDevice -
            SessionIndexNotifier.maxEntriesPerDevice ~/ 8,
      );
    });

    test('DeviceFeed.lastSessionTitle 与通知通道同上限（S-7/N-5）', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(eventFeedProvider.notifier).ingest(
        'dev',
        ObservedEvent(
          type: 'completed',
          taskId: 't1',
          sessionTitle: '长' * 2000000,
        ),
      );
      final title = container.read(eventFeedProvider)['dev']!.lastSessionTitle!;
      expect(title.length, 121);
      expect(title.endsWith('…'), isTrue);
    });
  });

  group('N-1/N-2 解析与注入面源码不变量（iter5 复核新增）', () {
    String read(String path) => File(path).readAsStringSync();

    test('zrWs 通道不再有裸 jsonDecode（深度炸弹统一走共享管线）', () {
      expect(
        read('lib/services/webview_sync.dart').contains('jsonDecode('),
        isFalse,
        reason: '页面可控字符串的解码必须收敛到 BridgeMessagePipeline.decode',
      );
    });

    test('_injectBridgeToken 内含 URL 信任守卫（单点收口）', () {
      final src = read('lib/ui/official_remote_page.dart');
      final start = src.indexOf('Future<bool> _injectBridgeToken');
      expect(start, greaterThanOrEqualTo(0));
      final body = src.substring(start, src.indexOf('\n  }', start));
      expect(
        body.contains('isTrustedRemotePage'),
        isTrue,
        reason: '返回手势退避循环也会调注入，守卫必须在函数内部单点生效',
      );
    });
  });

  group('S-4 outcome id 有限性', () {
    test('Infinity / NaN 的 id 返回 null 而不是抛 UnsupportedError', () {
      expect(
        JumpOutcome.parse('{"id": 1e400, "ok": true, "reason": "found"}'),
        isNull,
      );
      expect(
        JumpOutcome.parse('{"id": NaN, "ok": true, "reason": "found"}'),
        isNull,
      );
      expect(
        InPageBackOutcome.parse('{"id": Infinity, "ok": false, "reason": "gone"}'),
        isNull,
      );
      // 合法整数仍通过。
      final ok = JumpOutcome.parse('{"id": 7, "ok": true, "reason": "found"}');
      expect(ok?.attemptId, 7);
    });
  });

  group('S-6 route 长度上限', () {
    test('超长 path 截到 maxRouteChars，普通路由不受影响', () {
      final huge = LogRedactor.route('https://zcode.z.ai/${'A' * 2000000}');
      expect(huge.length, LogRedactor.maxRouteChars);
      expect(
        LogRedactor.route('https://zcode.z.ai/remote/v4?token=x'),
        'https://zcode.z.ai/remote/v4',
      );
      expect(LogRedactor.route('/relative/path'), '/relative/path');
    });
  });

  group('S-7 通知标题与正文同上限', () {
    test('4 MB 会话标题被截到 120 字符', () {
      final AppLocalizations l10n = AppLocalizationsZh();
      final device = RemoteDevice(
        id: 'd1',
        baseUrl: 'https://zcode.z.ai/remote/v4',
        params: const {'sid': 's', 'hash': 'h'},
        label: '',
        createdAt: DateTime(2026, 1, 1),
      );
      final title = NotificationSpec.titleFor(device, '长' * 2000000, l10n);
      // _clip 截到 120 并追加省略号。
      expect(title.length, 121);
      expect(title.endsWith('…'), isTrue);
      expect(NotificationSpec.titleFor(device, '', l10n), isNotEmpty);
    });
  });

  group('S-3 / S-5 注入面源码不变量', () {
    test('hookScript 用无原型 assembler 且 logicalFrameId 受正则约束', () {
      final script = EventObserver.hookScript;
      expect(script, contains('Object.create(null)'));
      expect(script, contains('/^[A-Za-z0-9_-]{1,128}\$/'));
      expect(script.contains('var asm = {};'), isFalse);
    });
  });
}

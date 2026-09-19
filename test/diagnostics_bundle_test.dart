import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/app_log.dart';
import 'package:zremote/services/diagnostics_bundle.dart';
import 'package:zremote/services/structured_log.dart';
import 'package:zremote/services/webview_storage.dart';

const canarySid = 'CANARY-SID-8f3a1c2b9d4e';
const canaryToken = 'CANARY-TOKEN-9d2a7f4c1e8b3a6d';
const canaryHash = 'CANARY-HASH-4b7c9e2f1a8d3c6b5e';
const canaryLink =
    'https://zcode.z.ai/remote/v4?sid=$canarySid&hash=$canaryHash&'
    'remoteControlToken=$canaryToken';
const canaries = [canarySid, canaryToken, canaryHash];

DiagnosticsInputs _inputs({
  String appVersion = '1.1.0',
  String buildNumber = '11',
  Map<String, String>? platform,
  List<String>? deviceIds,
  Map<String, String>? statuses,
  List<String>? logs,
}) => DiagnosticsInputs(
  generatedAt: DateTime.utc(2026, 9, 13, 9, 0),
  appVersion: appVersion,
  buildNumber: buildNumber,
  platform: platform ?? {'android': '14', 'sdkInt': '34', 'webview': '128.0'},
  deviceIds:
      deviceIds ??
      ['3f2a1b9c-1234-5678-9abc-def012345678', 'aa11bb22-2222-3333-4444-555566667777'],
  statuses:
      statuses ??
      {
        '3f2a1b9c-1234-5678-9abc-def012345678': 'live',
        'aa11bb22-2222-3333-4444-555566667777': 'loading',
      },
  settings: const {
    'biometric': 'on',
    'notifications': 'on',
    'batteryUnrestricted': 'off',
    'webviewStorage': 'cookies+domStorage+httpCache',
  },
  stats: const {
    '3f2a1b9c-1234-5678-9abc-def012345678': {'wsMessages': 12, 'queueDropped': 0},
    'aa11bb22-2222-3333-4444-555566667777': {'wsMessages': 3},
  },
  bridgeHealth: const {
    '3f2a1b9c-1234-5678-9abc-def012345678': 'ok',
    'aa11bb22-2222-3333-4444-555566667777': 'missing',
  },
  droppedMessages: 2,
  droppedDebugLines: 7,
  logs: logs ?? const [],
);

void main() {
  setUp(AppLog.resetForTest);

  group('DiagnosticsBundle', () {
    test('section 覆盖版本/平台/设置/设备/遥测/存储/日志', () {
      final titles = DiagnosticsBundle.sections(_inputs())
          .map((s) => s.title)
          .toList();
      expect(
        titles,
        containsAll([
          'app',
          'platform',
          'settings',
          'devices',
          'observer',
          'storage',
          'logs',
        ]),
      );
    });

    test('设备只以短 id 出现（诊断包不外泄完整标识）', () {
      final text = DiagnosticsBundle.render(_inputs());
      expect(text.contains('3f2a1b9c = live'), isTrue);
      expect(
        text.contains('3f2a1b9c-1234-5678-9abc-def012345678'),
        isFalse,
        reason: '完整设备 id 不应出现',
      );
      // 两台设备的计数各自成行（F18：交错上报不互相覆盖）
      expect(text.contains('3f2a1b9c.wsMessages = 12'), isTrue);
      expect(text.contains('aa11bb22.wsMessages = 3'), isTrue);
      // 设备行尾附主 frame 桥令牌状态（真机诊断第一现场）
      expect(text.contains('bridge=ok'), isTrue);
      expect(text.contains('bridge=missing'), isTrue);
    });

    test('canary 零命中：把凭证塞进构建日志后，诊断包整段无 canary', () {
      AppLog.event(LogEvent.webviewNavBlocked, fields: {LogField.route: canaryLink});
      AppLog.warn('raw $canaryLink');
      AppLog.failure(LogEvent.updateCheckFailed, Exception('sid=$canarySid'));
      final text = DiagnosticsBundle.render(
        DiagnosticsBundle.capture(
          appVersion: '1.1.0',
          buildNumber: '11',
          android: const {'release': '14', 'sdkInt': 34, 'webViewChrome': '128.0'},
          deviceIds: const ['3f2a1b9c-1234-5678-9abc-def012345678'],
          statuses: const {'3f2a1b9c-1234-5678-9abc-def012345678': 'live'},
          stats: const {
            '3f2a1b9c-1234-5678-9abc-def012345678': {'wsMessages': 1},
          },
          bridgeHealth: const {
            '3f2a1b9c-1234-5678-9abc-def012345678': 'ok',
          },
          biometric: true,
          notificationsEnabled: true,
          batteryIgnored: false,
          storeSkippedRecords: 2,
          storeRepaired: true,
        ),
      );
      expect(text.contains('[logs]'), isTrue);
      for (final canary in [...canaries, canaryLink]) {
        expect(text.contains(canary), isFalse, reason: 'canary 泄漏: $canary');
      }
      expect(text.contains('https://zcode.z.ai/remote/v4'), isTrue);
    });

    test('canary 零命中（对抗性输入）：版本号/平台/日志里塞链接也不泄漏', () {
      final text = DiagnosticsBundle.render(
        _inputs(
          appVersion: '1.1.0',
          platform: {'android': canaryLink, 'sdkInt': '34'},
          logs: [
            'https://zcode.z.ai/remote/v4?sid=$canarySid',
            'remoteControlToken=$canaryToken',
          ],
        ),
      );
      // 键名保留（便于人工核对），但值必须被打掉。
      for (final canary in [...canaries, canaryLink]) {
        expect(text.contains(canary), isFalse, reason: 'canary 泄漏: $canary');
      }
      // 带 scheme 的链接会被整体收敛成路由（query 连键名一起丢）；
      // 不带 scheme 的 key=value 形态则保留键名、打掉值。
      expect(text.contains('https://zcode.z.ai/remote/v4'), isTrue);
      expect(text.contains('remoteControlToken=<redacted>'), isTrue);
    });

    test('日志条数有上限（诊断包不无限膨胀）', () {
      final logs = List.generate(600, (i) => 'line $i');
      final section = DiagnosticsBundle.sections(_inputs(logs: logs)).firstWhere(
        (s) => s.title == 'logs',
      );
      expect(section.rows.length, DiagnosticsBundle.maxLogLines);
      expect(section.rows.last.value, 'line 599');
    });

    test('JSON 形态与文本形态同源，可被机器解析', () {
      final json = DiagnosticsBundle.renderJson(_inputs());
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded['schema'], 1);
      final sections = decoded['sections'] as List;
      final titles = [
        for (final s in sections) (s as Map)['title'],
      ];
      expect(titles, contains('storage'));
    });

    test('存储清单包含 Cookie/DOM storage/cache 与清理触发点（F19）', () {
      final text = DiagnosticsBundle.render(_inputs());
      expect(text.contains('cookies'), isTrue);
      expect(text.contains('domStorage'), isTrue);
      expect(text.contains('httpCache'), isTrue);
      // 每一条都必须写明"什么时候清"，否则清单只是描述、不成策略。
      for (final entry in WebViewStorage.inventory.entries) {
        expect(entry.value, isNotEmpty);
        final hasTrigger = ['清空', '清理', '消失'].any(entry.value.contains);
        expect(hasTrigger, isTrue, reason: '${entry.key} 未写明清理/失效时机');
      }
    });
  });
}

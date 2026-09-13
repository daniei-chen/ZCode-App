import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/app_log.dart';
import 'package:zremote/services/structured_log.dart';

/// canary：把"绝不能出现在日志里"的东西都写成这个名字，便于整段扫零命中。
const canarySid = 'CANARY-SID-8f3a1c2b9d4e';
const canaryHash = 'CANARY-HASH-4b7c9e2f1a8d3c6b5e';
const canaryToken = 'CANARY-TOKEN-9d2a7f4c1e8b3a6d';
const canaryJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJDQU5BUlkifQ.c2lnbmF0dXJl';
const canaryLink =
    'https://zcode.z.ai/remote/v4?sid=$canarySid&hash=$canaryHash&'
    'remoteControlToken=$canaryToken#frag';

void main() {
  setUp(AppLog.resetForTest);

  group('LogRedactor', () {
    test('URL 只保留 scheme://host/path（query/fragment/userinfo 全丢）', () {
      final route = LogRedactor.route(canaryLink);
      expect(route, 'https://zcode.z.ai/remote/v4');
      for (final canary in [canarySid, canaryHash, canaryToken]) {
        expect(route.contains(canary), isFalse);
      }
      expect(
        LogRedactor.route('https://user:pass@zcode.z.ai/remote/v4?x=1'),
        'https://zcode.z.ai/remote/v4',
      );
      expect(LogRedactor.route('/remote/v4?sid=abc'), '/remote/v4');
      expect(LogRedactor.route(null), '-');
      expect(LogRedactor.route('not a url'), 'not a url');
    });

    test('凭证参数无论出现在哪里都被打掉', () {
      final redacted = LogRedactor.redact(
        'GET /remote/v4 sid=$canarySid&hash=$canaryHash&remoteControlToken=$canaryToken '
        'cookie: token=$canaryToken',
      );
      for (final canary in [canarySid, canaryHash, canaryToken]) {
        expect(redacted.contains(canary), isFalse, reason: 'canary 泄漏: $canary');
      }
      expect(redacted.contains('sid='), isTrue, reason: '保留键名便于人工核对');
      expect(redacted.contains(LogRedactor.replacement), isTrue);
    });

    test('JWT 与长不透明串被打掉', () {
      final redacted = LogRedactor.redact('auth $canaryJwt hex ${'a' * 64}');
      expect(redacted.contains(canaryJwt), isFalse);
      expect(redacted.contains('a' * 64), isFalse);
    });

    test('设备 id 只保留前 8 位且可读', () {
      expect(LogRedactor.shortId('3f2a1b9c-1234-5678-9abc-def012345678'), '3f2a1b9c');
      expect(LogRedactor.shortId('short'), 'short');
      expect(LogRedactor.shortId(null), '-');
      expect(LogRedactor.shortId('!!!'), '-');
    });

    test('reason 只允许机器标签（小写/数字/_.:-，≤40）', () {
      expect(LogRedactor.reason('First load timeout (retry budget)'), 'first_load_timeout_retry_budget');
      expect(LogRedactor.reason('  '), '-');
      expect(LogRedactor.reason(null), '-');
      expect(LogRedactor.reason('x' * 80).length, 40);
    });

    test('异常摘要压缩为单行并截断', () {
      final text = LogRedactor.errorText(
        'ClientException: failed $canaryLink\n  at foo.dart:1:1',
      );
      expect(text.contains('\n'), isFalse);
      expect(text.contains(canarySid), isFalse);
      expect(text.length <= LogRedactor.maxErrorChars + 1, isTrue);
    });
  });

  group('AppLog 结构化事件', () {
    test('事件行含事件码、事件名与白名单字段', () {
      AppLog.event(
        LogEvent.webviewLoadStop,
        fields: {
          LogField.device: '3f2a1b9c-1234',
          LogField.generation: 2,
          LogField.route: canaryLink,
          LogField.durationMs: 318,
          LogField.ok: true,
        },
      );
      final line = AppLog.snapshot().last;
      expect(line.contains('WV101'), isTrue);
      expect(line.contains('event=webviewLoadStop'), isTrue);
      expect(line.contains('dev=3f2a1b9c'), isTrue);
      expect(line.contains('gen=2'), isTrue);
      expect(line.contains('route=https://zcode.z.ai/remote/v4'), isTrue);
      expect(line.contains('ms=318'), isTrue);
      expect(line.contains('ok=true'), isTrue);
      expect(line.contains(canarySid), isFalse);
    });

    test('null 字段被跳过，不会写出 key=- 这种噪声', () {
      AppLog.event(
        LogEvent.webviewLoadStart,
        fields: {LogField.route: null, LogField.reason: null},
      );
      final line = AppLog.snapshot().last;
      expect(line.contains('route='), isFalse);
      expect(line.contains('reason='), isFalse);
    });

    test('failure 走同一脱敏路径（异常文本带凭证也不泄漏）', () {
      AppLog.failure(LogEvent.updateCheckFailed, Exception(canaryLink));
      final line = AppLog.snapshot().last;
      expect(line.contains('UP600'), isTrue);
      expect(line.contains('err='), isTrue);
      expect(line.contains(canarySid), isFalse);
      expect(line.contains(canaryHash), isFalse);
    });

    test('旧字符串入口同样被强制脱敏（第二道防线）', () {
      AppLog.warn('raw $canaryLink token=$canaryToken');
      final line = AppLog.snapshot().last;
      expect(line.contains(canarySid), isFalse);
      expect(line.contains(canaryToken), isFalse);
      expect(line.contains('token=<redacted>'), isTrue);
    });

    test('canary 扫零命中：多种凭证形态混写后，整段导出无 canary', () {
      AppLog.event(LogEvent.webviewNavBlocked, fields: {LogField.route: canaryLink});
      AppLog.failure(LogEvent.updateCheckFailed, 'boom $canaryJwt');
      AppLog.warn('link $canaryLink');
      AppLog.error('inner', Exception('sid=$canarySid hash=$canaryHash'));
      final exported = AppLog.export();
      expect(exported.isNotEmpty, isTrue);
      for (final canary in [
        canarySid,
        canaryHash,
        canaryToken,
        canaryJwt,
        'frag',
      ]) {
        expect(exported.contains(canary), isFalse, reason: 'canary 泄漏: $canary');
      }
    });

    test('环形缓冲有上限，不无限增长', () {
      for (var i = 0; i < 600; i++) {
        AppLog.info('line $i');
      }
      expect(AppLog.snapshot().length, 500);
      expect(AppLog.snapshot().last.contains('line 599'), isTrue);
    });
  });

  group('事件码表', () {
    test('事件码唯一且形如 XXnnn', () {
      final codes = LogEvent.values.map((e) => e.code).toList();
      expect(codes.toSet().length, codes.length, reason: '事件码不得重复');
      for (final code in codes) {
        expect(RegExp(r'^[A-Z]{2}[0-9]{3}$').hasMatch(code), isTrue, reason: code);
      }
    });

    test('字段键唯一且短（日志行不长）', () {
      final keys = LogField.values.map((f) => f.key).toList();
      expect(keys.toSet().length, keys.length);
      for (final key in keys) {
        expect(key.length <= 8, isTrue, reason: key);
      }
    });
  });
}

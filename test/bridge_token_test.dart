import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/bridge_token.dart';

/// 主 frame 令牌的注入策略（现场回归：真机 BR200 → 事件与返回回执全被 fail-closed 拦住）。
void main() {
  const token = 'AbC-123_xyz';

  group('read-back 规范化与判定', () {
    test('裸字符串直接通过', () {
      expect(BridgeTokenPolicy.isReady(token, token), isTrue);
    });

    test('带引号/空白的返回值同样通过（不同 WebView 实现差异）', () {
      expect(BridgeTokenPolicy.isReady('"$token"', token), isTrue);
      expect(BridgeTokenPolicy.isReady('  "$token"  ', token), isTrue);
      expect(BridgeTokenPolicy.isReady(' $token ', token), isTrue);
    });

    test('缺失/空串/不一致一律不通过', () {
      expect(BridgeTokenPolicy.isReady('', token), isFalse);
      expect(BridgeTokenPolicy.isReady('""', token), isFalse);
      expect(BridgeTokenPolicy.isReady(null, token), isFalse);
      expect(BridgeTokenPolicy.isReady(42, token), isFalse);
      expect(BridgeTokenPolicy.isReady('other-token', token), isFalse);
      // 期望值为空（还没生成令牌）时绝不判定就绪
      expect(BridgeTokenPolicy.isReady(token, ''), isFalse);
    });

    test('normalize 只处理引号与空白，不改变内容', () {
      expect(BridgeTokenPolicy.normalize('"a b"'), 'a b');
      expect(BridgeTokenPolicy.normalize('a b'), 'a b');
      expect(BridgeTokenPolicy.normalize('   '), isNull);
      expect(BridgeTokenPolicy.normalize('"'), '"');
    });
  });

  group('重试计划', () {
    test('首次立即尝试，随后退避，覆盖足够窗口（≥2s）', () {
      expect(BridgeTokenPolicy.retryDelays.first, 0);
      final total = BridgeTokenPolicy.retryDelays.fold<int>(0, (a, b) => a + b);
      expect(total, greaterThanOrEqualTo(2000));
      expect(BridgeTokenPolicy.shouldRetry(0), isTrue);
      expect(
        BridgeTokenPolicy.shouldRetry(BridgeTokenPolicy.retryDelays.length),
        isFalse,
      );
    });

    test('delayFor 越界时钳制在最后一个间隔（不抛异常）', () {
      expect(BridgeTokenPolicy.delayFor(0), Duration.zero);
      expect(
        BridgeTokenPolicy.delayFor(999),
        BridgeTokenPolicy.delayFor(BridgeTokenPolicy.retryDelays.length - 1),
      );
    });

    test('返回键前的等待预算有限（不无限等令牌）', () {
      expect(BridgeTokenPolicy.backBudget.inMilliseconds, greaterThan(500));
      expect(BridgeTokenPolicy.backBudget.inMilliseconds, lessThan(3000));
    });
  });

  group('注入与引导脚本', () {
    test('引导脚本把令牌写进主 frame，且不含可执行的危险字符', () {
      final script = BridgeTokenPolicy.bootstrapScript(token);
      expect(script.contains("window.__zrToken = '$token';"), isTrue);
      expect(script.contains("document-start"), isTrue);
      expect(script.contains(';'), isTrue);
      // 令牌字符集限定：base64url（无引号/反斜杠/分号）
      expect(RegExp(r"^[A-Za-z0-9_-]+$").hasMatch(token), isTrue);
    });

    test('空令牌的引导脚本是安全空操作', () {
      expect(BridgeTokenPolicy.bootstrapScript(''), 'void 0;');
    });

    test('注入脚本先调用钩子的 __zrSetToken 再回读', () {
      final script = BridgeTokenPolicy.injectScript(token);
      expect(script.contains('window.__zrSetToken &&'), isTrue);
      expect(script.trimRight().endsWith(BridgeTokenPolicy.readScript), isTrue);
    });

    test('回读脚本不泄露期望值（只读环境变量）', () {
      expect(BridgeTokenPolicy.readScript.contains('window.__zrToken'), isTrue);
      expect(BridgeTokenPolicy.readScript.contains(token), isFalse);
      expect(BridgeTokenPolicy.hookReadyScript.contains('__zrHookReady'), isTrue);
    });
  });
}

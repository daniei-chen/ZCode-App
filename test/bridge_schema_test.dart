import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/bridge_schema.dart';

/// v1.1.0 Bridge 消息 schema/尺寸门禁测试：超限与类型不符必须 fail-closed。
void main() {
  setUp(() => BridgeSchema.droppedMessages = 0);

  group('acceptString', () {
    test('正常字符串通过', () {
      expect(
        BridgeSchema.acceptString('hello', maxBytes: 64),
        'hello',
      );
    });

    test('类型不符丢弃并计数', () {
      expect(BridgeSchema.acceptString(123, maxBytes: 64), isNull);
      expect(BridgeSchema.acceptString(null, maxBytes: 64), isNull);
      expect(BridgeSchema.acceptString(<String>[], maxBytes: 64), isNull);
      expect(BridgeSchema.droppedMessages, 3);
    });

    test('空字符串静默忽略（不计丢弃）', () {
      expect(BridgeSchema.acceptString('', maxBytes: 64), isNull);
      expect(BridgeSchema.droppedMessages, 0);
    });

    test('超长丢弃并计数，边界值通过', () {
      final ok = 'a' * 64;
      final tooLong = 'a' * 65;
      expect(BridgeSchema.acceptString(ok, maxBytes: 64), ok);
      expect(BridgeSchema.acceptString(tooLong, maxBytes: 64), isNull);
      expect(BridgeSchema.droppedMessages, 1);
    });

    test('按真实 UTF-8 字节数判定：多字节字符不得用字符数蒙混过关（F04）', () {
      // 21 个汉字 = 63 字节（≤64）→ 通过；22 个 = 66 字节（>64）→ 丢弃，
      // 尽管字符数都远小于上限。
      final ok = '中' * 21;
      final tooLong = '中' * 22;
      expect(BridgeSchema.acceptString(ok, maxBytes: 64), ok);
      expect(BridgeSchema.acceptString(tooLong, maxBytes: 64), isNull);
    });
  });

  group('acceptStats', () {
    test('只保留 Map<String, 非负数字>', () {
      final stats = BridgeSchema.acceptStats({
        'fetch200': 10,
        'wsMessages': 3.7,
      });
      expect(stats, {'fetch200': 10, 'wsMessages': 3});
    });

    test('非 Map 整体拒绝并计数', () {
      expect(BridgeSchema.acceptStats('not-a-map'), isNull);
      expect(BridgeSchema.acceptStats(null), isNull);
      expect(BridgeSchema.droppedMessages, 2);
    });

    test('负数与未知类型键跳过，不影响其余键', () {
      final stats = BridgeSchema.acceptStats({
        'ok': 1,
        'negative': -5,
        'wrongType': 'text',
      });
      expect(stats, {'ok': 1});
    });

    test('全部非法时返回 null，不产生空 Map 上报', () {
      expect(
        BridgeSchema.acceptStats({'a': -1, 'b': 'x'}),
        isNull,
      );
    });

    test('键数封顶 maxStatsKeys', () {
      final input = {
        for (var i = 0; i < BridgeSchema.maxStatsKeys + 10; i++) 'k$i': i,
      };
      final stats = BridgeSchema.acceptStats(input)!;
      expect(stats.length, BridgeSchema.maxStatsKeys);
    });
  });

  test('事件字节上限与 JS 钩子保持一致', () {
    expect(BridgeSchema.eventCapMatchesHook, isTrue);
  });

  group('BridgeAuthPolicy.tokenMatches（F03 主 frame 令牌）', () {
    test('令牌一致才放行', () {
      expect(BridgeAuthPolicy.tokenMatches('abc', 'abc'), isTrue);
    });

    test('缺失/类型不符/不一致一律拒绝', () {
      expect(BridgeAuthPolicy.tokenMatches(null, 'abc'), isFalse);
      expect(BridgeAuthPolicy.tokenMatches('', 'abc'), isFalse);
      expect(BridgeAuthPolicy.tokenMatches('abd', 'abc'), isFalse);
      expect(BridgeAuthPolicy.tokenMatches(123, 'abc'), isFalse);
    });

    test('期望值为空（未生成令牌）时拒绝一切', () {
      expect(BridgeAuthPolicy.tokenMatches('abc', ''), isFalse);
      expect(BridgeAuthPolicy.tokenMatches('abc', null), isFalse);
    });
  });
}

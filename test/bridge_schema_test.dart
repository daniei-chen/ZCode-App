import 'dart:io';

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

  group('acceptStats（F18 白名单 + 有限性）', () {
    test('只保留白名单内的非负整数计数', () {
      final stats = BridgeSchema.acceptStats({
        'fetch200': 10,
        'wsMessages': 3.7,
      });
      expect(stats, {'fetch200': 10, 'wsMessages': 3});
    });

    test('白名单之外的键一律丢弃（页面不能借遥测通道塞任意字符串）', () {
      expect(
        BridgeSchema.acceptStats({'customKey': 1, 'fetch200': 2}),
        {'fetch200': 2},
      );
      expect(BridgeSchema.acceptStats({'sessionTitle': 1}), isNull);
      expect(BridgeSchema.acceptStats({'window.__zrStats': 1}), isNull);
    });

    test('非 Map 整体拒绝并计数', () {
      expect(BridgeSchema.acceptStats('not-a-map'), isNull);
      expect(BridgeSchema.acceptStats(null), isNull);
      expect(BridgeSchema.droppedMessages, 2);
    });

    test('NaN / Infinity / 超大值 / 负数一律丢弃（旧实现会让 toInt 抛错被吞掉）', () {
      expect(
        BridgeSchema.acceptStats({
          'fetch200': double.nan,
          'wsMessages': double.infinity,
          'queueDropped': -5,
          'seenDropped': BridgeSchema.maxStatValue + 1,
        }),
        isNull,
      );
      expect(
        BridgeSchema.acceptStats({'fetch200': double.nan, 'wsMessages': 4}),
        {'wsMessages': 4},
      );
      expect(
        BridgeSchema.acceptStats({'wsMessages': BridgeSchema.maxStatValue})!,
        {'wsMessages': BridgeSchema.maxStatValue},
      );
    });

    test('全部非法时返回 null，不产生空 Map 上报', () {
      expect(BridgeSchema.acceptStats({'fetch200': -1, 'wsMessages': 'x'}), isNull);
    });

    test('白名单键全部可用，且数量不超过 maxStatsKeys', () {
      final stats = BridgeSchema.acceptStats({
        for (final key in BridgeSchema.statsKeys) key: 1,
      })!;
      expect(stats.length, BridgeSchema.statsKeys.length);
      expect(
        BridgeSchema.statsKeys.length <= BridgeSchema.maxStatsKeys,
        isTrue,
        reason: '白名单不能超过键数上限，否则部分计数会被静默截断',
      );
    });

    test('白名单与 JS 钩子的 __zrStats 字段一一对应（防漂移）', () {
      final source = File(
        'lib/services/event_observer.dart',
      ).readAsStringSync();
      final block = RegExp(
        r'window\.__zrStats = window\.__zrStats \|\| \{([^}]*)\}',
      ).firstMatch(source);
      expect(block, isNotNull, reason: '未找到 __zrStats 初始化块');
      final hookKeys = RegExp(r'([A-Za-z_][A-Za-z0-9_]*)\s*:')
          .allMatches(block!.group(1)!)
          .map((m) => m.group(1)!)
          .toSet();
      expect(
        hookKeys,
        BridgeSchema.statsKeys,
        reason: '钩子新增计数必须同步进 BridgeSchema.statsKeys，否则会被白名单丢掉',
      );
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

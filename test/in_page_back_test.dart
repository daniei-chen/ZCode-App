import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/in_page_back.dart';

/// 页内返回（用户上报回归）：脚本必须"点完能自证"，Dart 必须只看当前这一代的回执。
void main() {
  group('InPageBackOutcome.parse', () {
    test('合法回执被解析', () {
      final outcome = InPageBackOutcome.parse(
        jsonEncode({'id': 3, 'ok': true, 'reason': 'clicked'}),
      )!;
      expect(outcome.attemptId, 3);
      expect(outcome.ok, isTrue);
      expect(outcome.reason, InPageBackOutcome.reasonClicked);
    });

    test('非法输入一律拒绝（不抛异常）', () {
      expect(InPageBackOutcome.parse(null), isNull);
      expect(InPageBackOutcome.parse(''), isNull);
      expect(InPageBackOutcome.parse('nope'), isNull);
      expect(InPageBackOutcome.parse('[]'), isNull);
      expect(InPageBackOutcome.parse(jsonEncode({'ok': true, 'reason': 'x'})), isNull);
      expect(
        InPageBackOutcome.parse(jsonEncode({'id': -1, 'ok': true, 'reason': 'x'})),
        isNull,
      );
      expect(
        InPageBackOutcome.parse(jsonEncode({'id': 1, 'ok': 'yes', 'reason': 'x'})),
        isNull,
      );
      expect(InPageBackOutcome.parse(jsonEncode({'id': 1, 'ok': false})), isNull);
      expect(
        InPageBackOutcome.parse(
          jsonEncode({
            'id': 1,
            'ok': false,
            'reason': 'x' * (InPageBackOutcome.maxReasonChars + 1),
          }),
        ),
        isNull,
      );
    });
  });

  group('InPageBack.script', () {
    final script = InPageBack.script(7);

    test('是 IIFE 表达式并带上本次尝试号', () {
      final body = script.trim();
      expect(RegExp(r'^\(function\s*\(').hasMatch(body), isTrue);
      expect(body.endsWith('})()'), isTrue);
      expect(script.contains('var attempt = 7;'), isTrue);
      expect(script.contains('var MAX = ${InPageBack.maxCandidates};'), isTrue);
    });

    test('回执经 bridge 携带主 frame 令牌，且没令牌不裸发', () {
      expect(script.contains("callHandler('zrBack'"), isTrue);
      expect(script.contains('window.__zrToken'), isTrue);
      expect(script.contains('}), window.__zrToken);'), isTrue);
      expect(script.contains('if (reported) return;'), isTrue);
    });

    test('三种结论都会回执：clicked / not_found / no_change', () {
      expect(script.contains("done(true, 'clicked')"), isTrue);
      expect(script.contains("done(false, 'not_found')"), isTrue);
      expect(script.contains("done(false, 'no_change')"), isTrue);
    });

    test('点击后用内容签名验证页面确实换了（不是点到就算）', () {
      expect(script.contains('var signature = function ()'), isTrue);
      expect(script.contains('var before = signature();'), isTrue);
      expect(script.contains('if (signature() !== before)'), isTrue);
      // 验证轮询与单候选预算
      expect(script.contains('setTimeout(poll, 80)'), isTrue);
      expect(script.contains('Date.now() + 600'), isTrue);
    });

    test('多策略候选：显式标签 → 通用标签 → 左上角图标键几何兜底', () {
      expect(script.contains('aria-label="返回任务首页"'), isTrue);
      expect(script.contains('aria-label^="Back to"'), isTrue);
      expect(script.contains('data-testid*="back"'), isTrue);
      expect(script.contains('isBackLabel'), isTrue);
      // 几何兜底收紧到"左上角 56×40 内的图标键"：官方页面返回键在 (8,10,24,24)，
      // 而列表页左上角没有返回键——放宽会误点工作区/新建控件（模拟器实测回归）。
      expect(script.contains('var cornerRight = 56;'), isTrue);
      expect(script.contains('var cornerBottom = 40;'), isTrue);
      expect(script.contains('var minSize = 20;'), isTrue);
      expect(script.contains('var maxSize = 40;'), isTrue);
      expect(script.contains("node.querySelector('svg')"), isTrue);
      expect(script.contains('score: rect.top * 2 + rect.left'), isTrue);
      // 旧规则必须已删除（防止回退）
      expect(script.contains('rect.left > 96'), isFalse);
      expect(script.contains('limitTop'), isFalse);
    });

    test('「返回顶部」绝不能被当成返回（历史回归点）', () {
      expect(script.contains('返回顶部'), isTrue);
      expect(script.contains('back to top'), isTrue);
      // 每个候选入口都要先排除返回顶部
      expect('if (isBackToTop(labelOf('.allMatches(script).length, greaterThanOrEqualTo(3));
    });

    test('只点击可见且可交互的元素，不碰 disabled / pointer-events:none', () {
      expect(script.contains("style.pointerEvents === 'none'"), isTrue);
      expect(script.contains('if (el.disabled) return false;'), isTrue);
      expect(script.contains("style.display === 'none'"), isTrue);
      expect(script.contains("style.visibility === 'hidden'"), isTrue);
    });

    test('代际守卫：新的返回尝试会让旧脚本停止', () {
      expect(script.contains("__zrBackGen"), isTrue);
      expect(script.contains('window[GEN] !== myGen'), isTrue);
      expect(script.contains('if (cancelled()) return;'), isTrue);
    });

    test('预算常量与 Dart 侧兜底超时匹配（脚本更短，避免双超时打架）', () {
      expect(InPageBack.budget.inMilliseconds, greaterThan(0));
      expect(
        InPageBack.dartTimeout.inMilliseconds,
        greaterThan(InPageBack.budget.inMilliseconds),
      );
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/relay/conversation_row.dart';
import 'package:zremote/state/conversation.dart';

ConversationRow row(
  int id,
  String kind, {
  String? text,
  String? toolName,
  String? status,
  String? inputText,
  String? visibility,
}) => ConversationRow.tryParse({
  'rowId': id,
  'kind': kind,
  'text': ?text,
  'toolName': ?toolName,
  'status': ?status,
  'inputText': ?inputText,
  'visibility': ?visibility,
})!;

void main() {
  group('ConversationBlock 分组', () {
    test('连续工具调用合并成一组', () {
      final blocks = ConversationBlock.group([
        row(1, 'toolCall', toolName: 'Read'),
        row(2, 'toolCall', toolName: 'Grep'),
        row(3, 'toolCall', toolName: 'Read'),
      ]);
      expect(blocks, hasLength(1));
      final g = blocks.single as ToolCallGroup;
      expect(g.rows, hasLength(3));
      // 去重且保持出现顺序
      expect(g.toolNames, ['Read', 'Grep']);
    });

    test('正文会把工具组切断', () {
      final blocks = ConversationBlock.group([
        row(1, 'toolCall', toolName: 'Read'),
        row(2, 'assistantText', text: '看一下'),
        row(3, 'toolCall', toolName: 'Edit'),
      ]);
      expect(blocks.map((b) => b.runtimeType).toList(), [
        ToolCallGroup,
        TextBlock,
        ToolCallGroup,
      ]);
    });

    test('连续思考合并，且与工具组互不干扰', () {
      final blocks = ConversationBlock.group([
        row(1, 'reasoning', text: '第一段'),
        row(2, 'reasoning', text: '第二段'),
        row(3, 'toolCall', toolName: 'Bash'),
      ]);
      expect(blocks, hasLength(2));
      expect((blocks[0] as ReasoningBlock).rows, hasLength(2));
      expect((blocks[0] as ReasoningBlock).text, '第一段\n第二段');
    });

    test('思考块提供服务端耗时，工具组统计明确的技能', () {
      final reasoning = ConversationRow.tryParse({
        'rowId': 1,
        'kind': 'reasoning',
        'text': '分析',
        'activeMs': 2450,
      })!;
      final skillA = ConversationRow.tryParse({
        'rowId': 2,
        'kind': 'toolCall',
        'toolName': 'SkillLoad',
        'skillName': 'review',
      })!;
      final skillB = ConversationRow.tryParse({
        'rowId': 3,
        'kind': 'toolCall',
        'toolName': 'SkillLoad',
        'skillName': 'review',
      })!;
      final blocks = ConversationBlock.group([reasoning, skillA, skillB]);
      expect((blocks[0] as ReasoningBlock).durationMs, 2450);
      expect((blocks[1] as ToolCallGroup).skillsLoaded, 1);
    });

    test('非 visible 的行被跳过', () {
      final blocks = ConversationBlock.group([
        row(1, 'assistantText', text: '可见'),
        row(2, 'assistantText', text: '隐藏', visibility: 'hidden'),
      ]);
      expect(blocks, hasLength(1));
      expect((blocks.single as TextBlock).text, '可见');
    });

    test('unknown 类型不产出块，也不会崩', () {
      final blocks = ConversationBlock.group([
        row(1, 'newKindFromFuture', text: 'x'),
        row(2, 'assistantText', text: '正常'),
      ]);
      expect(blocks, hasLength(1));
    });

    test('空输入产出空列表', () {
      expect(ConversationBlock.group(const []), isEmpty);
    });

    test('工具组状态聚合', () {
      final ok =
          ConversationBlock.group([
                row(1, 'toolCall', toolName: 'A', status: 'success'),
                row(2, 'toolCall', toolName: 'B', status: 'success'),
              ]).single
              as ToolCallGroup;
      expect(ok.allOk, isTrue);
      expect(ok.anyFailed, isFalse);

      final bad =
          ConversationBlock.group([
                row(1, 'toolCall', toolName: 'A', status: 'success'),
                row(2, 'toolCall', toolName: 'B', status: 'error'),
              ]).single
              as ToolCallGroup;
      expect(bad.allOk, isFalse);
      expect(bad.anyFailed, isTrue);
    });

    test('首个 rowId 取自第一行（翻页游标用）', () {
      final blocks = ConversationBlock.group([
        row(7, 'toolCall', toolName: 'A'),
        row(8, 'toolCall', toolName: 'B'),
      ]);
      expect(blocks.single.firstRowId, 7);
    });

    test('用户消息与助手正文分属不同块', () {
      final blocks = ConversationBlock.group([
        row(1, 'userText', text: '问题'),
        row(2, 'assistantText', text: '回答'),
      ]);
      expect(blocks, hasLength(2));
      expect((blocks[0] as TextBlock).isUser, isTrue);
      expect((blocks[1] as TextBlock).isUser, isFalse);
    });

    test('钩子块单独成块并给出标签', () {
      final h = ConversationRow.tryParse({
        'rowId': 1,
        'kind': 'hookInvocation',
        'hookName': 'PreToolUse',
      })!;
      final blocks = ConversationBlock.group([h]);
      expect((blocks.single as HookBlock).label, 'PreToolUse');
    });
  });

  group('ConversationRow.summary（工具一句话摘要）', () {
    test('Bash 取 command', () {
      final r = row(
        1,
        'toolCall',
        toolName: 'Bash',
        inputText: '{"command":"npm test","description":"跑测试"}',
      );
      expect(r.summary, 'npm test');
    });

    test('Edit 只显示文件名，不显示整条路径', () {
      final r = row(
        1,
        'toolCall',
        toolName: 'Edit',
        inputText: r'{"file_path":"E:\\zcode\\杂事\\a.js","old_string":"x"}',
      );
      expect(r.summary, 'a.js');
    });

    test('Grep 取 pattern', () {
      final r = row(
        1,
        'toolCall',
        toolName: 'Grep',
        inputText: '{"pattern":"TODO"}',
      );
      expect(r.summary, 'TODO');
    });

    test('未知工具退回第一个字符串值', () {
      final r = row(
        1,
        'toolCall',
        toolName: 'MysteryTool',
        inputText: '{"whatever":"hello","n":3}',
      );
      expect(r.summary, 'hello');
    });

    test('摘要与展开入参不泄露 token 等敏感字段', () {
      final r = row(
        1,
        'toolCall',
        toolName: 'MysteryTool',
        inputText:
            '{"token":"abc123","authorization":"Bearer xyz",'
            '"description":"safe"}',
      );
      expect(r.summary, 'safe');
      expect(r.prettyInput, contains('<hidden>'));
      expect(r.prettyInput, isNot(contains('abc123')));
      expect(r.prettyInput, isNot(contains('Bearer xyz')));
    });

    test('非 JSON 入参退化为截断原文', () {
      final long = 'x' * 200;
      final r = row(1, 'toolCall', toolName: 'Bash', inputText: long);
      expect(r.summary.length, lessThanOrEqualTo(81));
      expect(r.summary, endsWith('…'));
    });

    test('超长摘要被截断', () {
      final long = 'a' * 300;
      final r = row(
        1,
        'toolCall',
        toolName: 'Bash',
        inputText: '{"command":"$long"}',
      );
      expect(r.summary.length, lessThanOrEqualTo(91));
    });

    test('无入参返回空串', () {
      expect(row(1, 'toolCall', toolName: 'Bash').summary, '');
    });
  });

  group('ConversationRow.prettyInput', () {
    test('JSON 会被缩进', () {
      final r = row(1, 'toolCall', inputText: '{"a":1}');
      expect(r.prettyInput, contains('\n'));
      expect(r.prettyInput, contains('"a": 1'));
    });

    test('非 JSON 原样返回', () {
      final r = row(1, 'toolCall', inputText: 'not json');
      expect(r.prettyInput, 'not json');
    });
  });

  group('fileBasename', () {
    test('兼容 Windows 与 POSIX 分隔符', () {
      expect(ConversationRow.fileBasename(r'E:\zcode\杂事\a.js'), 'a.js');
      expect(ConversationRow.fileBasename('/tmp/a/b.py'), 'b.py');
      expect(ConversationRow.fileBasename('plain.txt'), 'plain.txt');
      expect(ConversationRow.fileBasename(r'E:\dir\'), r'E:\dir\');
    });
  });

  group('ConversationState', () {
    test('blocks 由 rows 派生', () {
      const st = ConversationState(rows: []);
      expect(st.blocks, isEmpty);
      expect(st.isEmpty, isTrue);
    });

    test('loading 时不算空态', () {
      const st = ConversationState(loading: true);
      expect(st.isEmpty, isFalse);
    });

    test('copyWith(clearError) 能清掉错误', () {
      const st = ConversationState(error: 'boom');
      expect(st.copyWith(clearError: true).error, isNull);
    });

    test('keyOf 组合设备与会话', () {
      expect(ConversationNotifier.keyOf('dev', 'sess'), 'dev|sess');
    });
  });
}

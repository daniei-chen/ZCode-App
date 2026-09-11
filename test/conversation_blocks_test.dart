import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/relay/conversation_row.dart';
import 'package:zremote/state/conversation.dart';

ConversationRow mk(int id, Map<String, dynamic> data) =>
    ConversationRow.tryParse({'rowId': id, ...data})!;

ConversationRow call(int id, String tool, String input) =>
    mk(id, {'kind': 'toolCall', 'toolName': tool, 'inputText': input});

void main() {
  group('待办解析', () {
    test('todo_write 被识别，容器键 todos 生效', () {
      final r = call(
        1,
        'TodoWrite',
        '{"todos":[{"content":"改 A","status":"in_progress"},'
            '{"content":"改 B","status":"completed"}]}',
      );
      expect(r.isTodoCall, isTrue);
      expect(r.todos, hasLength(2));
      expect(r.todos[0].title, '改 A');
      expect(r.todos[0].isActive, isTrue);
      expect(r.todos[1].isDone, isTrue);
    });

    test('update_plan 与其它容器键（plan/steps/items）同样识别', () {
      for (final key in ['plan', 'steps', 'items']) {
        final r = call(1, 'update-plan', '{"$key":["第一步","第二步"]}');
        expect(r.isTodoCall, isTrue, reason: key);
        expect(r.todos.map((t) => t.title), ['第一步', '第二步']);
        // 字符串项默认 pending
        expect(r.todos.every((t) => t.status == 'pending'), isTrue);
      }
    });

    test('分隔符与大小写不敏感', () {
      for (final name in [
        'todo_write',
        'TodoWrite',
        'todo-write',
        'TODO WRITE',
      ]) {
        expect(
          call(1, name, '{"todos":["x"]}').isTodoCall,
          isTrue,
          reason: name,
        );
      }
    });

    test('普通工具不会被误判为待办', () {
      expect(call(1, 'Read', '{"file_path":"a.js"}').isTodoCall, isFalse);
      expect(call(1, 'Bash', '{"command":"ls"}').isTodoCall, isFalse);
      // 名字像但内容不是清单
      expect(call(1, 'TodoWrite', '{"note":"x"}').isTodoCall, isFalse);
      expect(call(1, 'TodoWrite', '不是 JSON').isTodoCall, isFalse);
    });

    test('未知状态回落 pending，不丢条目', () {
      final r = call(1, 'TodoWrite', '{"todos":[{"title":"x","status":"怪值"}]}');
      expect(r.todos.single.status, 'pending');
    });

    test('完成度统计', () {
      final items = [
        const TodoItem(title: 'a', status: 'completed'),
        const TodoItem(title: 'b', status: 'in_progress'),
        const TodoItem(title: 'c', status: 'completed'),
      ];
      final p = ConversationRow.todoProgress(items);
      expect(p.done, 2);
      expect(p.total, 3);
    });

    test('TodoBlock 取最后一条（整体覆盖语义）', () {
      final blocks = ConversationBlock.group([
        call(1, 'TodoWrite', '{"todos":["旧的"]}'),
        call(2, 'TodoWrite', '{"todos":["新的1","新的2"]}'),
      ]);
      expect(blocks, hasLength(1));
      final b = blocks.single as TodoBlock;
      expect(b.items.map((t) => t.title), ['新的1', '新的2']);
    });

    test('待办不会并入普通工具组', () {
      final blocks = ConversationBlock.group([
        call(1, 'Read', '{"file_path":"a"}'),
        call(2, 'TodoWrite', '{"todos":["x"]}'),
      ]);
      expect(blocks.map((b) => b.runtimeType).toList(), [
        ToolCallGroup,
        TodoBlock,
      ]);
    });
  });

  group('授权（permission）', () {
    ConversationRow perm({List<dynamic>? options, String? toolCallId}) =>
        mk(1, {
          'kind': 'permission',
          'toolName': 'Bash',
          'summary': 'rm -rf build',
          'toolCallId': ?toolCallId,
          'options': ?options,
        });

    test('选项解析与允许/拒绝判定', () {
      final r = perm(
        options: [
          {'optionId': 'o1', 'label': '允许一次', 'kind': 'allowOnce'},
          {'optionId': 'o2', 'label': '总是允许', 'kind': 'allowAlways'},
          {'optionId': 'o3', 'label': '拒绝', 'kind': 'deny'},
        ],
      );
      expect(r.kind, ConversationRowKind.permission);
      expect(r.permissionOptions, hasLength(3));
      expect(r.permissionOptions[0].isAllow, isTrue);
      expect(r.permissionOptions[1].isAllow, isTrue);
      expect(r.permissionOptions[2].isDeny, isTrue);
      expect(r.permissionOptions[2].isAllow, isFalse);
    });

    test('非法选项被丢弃，不炸', () {
      final r = perm(
        options: [
          {'label': '缺 id'},
          'garbage',
          {'optionId': 'ok', 'label': '允许', 'kind': 'allowOnce'},
        ],
      );
      expect(r.permissionOptions, hasLength(1));
      expect(r.permissionOptions.single.optionId, 'ok');
    });

    test('摘要读取 summary 字段', () {
      expect(perm().permissionSummary, 'rm -rf build');
    });

    test('单独成块，不与工具组混', () {
      final blocks = ConversationBlock.group([call(1, 'Read', '{}'), perm()]);
      expect(blocks.last, isA<PermissionBlock>());
    });

    test('interactionId 优先取 interactionId，其次 toolCallId', () {
      expect((PermissionBlock([perm()])).interactionId, isNull);
      expect(
        PermissionBlock([perm(toolCallId: 'call_1')]).interactionId,
        'call_1',
      );
      final withInteraction = mk(1, {
        'kind': 'permission',
        'interactionId': 'int_9',
        'toolCallId': 'call_1',
      });
      expect(PermissionBlock([withInteraction]).interactionId, 'int_9');
    });

    test('kind.needsUserAction 只对 permission 为真', () {
      expect(ConversationRowKind.permission.needsUserAction, isTrue);
      expect(ConversationRowKind.toolCall.needsUserAction, isFalse);
    });

    test('hasPendingAction 反映正文里有没有待处理交互', () {
      const none = ConversationState(rows: []);
      expect(none.hasPendingAction, isFalse);
      final st = ConversationState(rows: [perm()]);
      expect(st.hasPendingAction, isTrue);
    });
  });

  group('工具分组开关（对齐官方三个设置）', () {
    test('探索工具：开关关闭时不并组', () {
      final rows = [call(1, 'Read', '{}'), call(2, 'Grep', '{}')];
      expect(ConversationBlock.group(rows), hasLength(1));
      expect(
        ConversationBlock.group(
          rows,
          grouping: const ConversationGrouping(explore: false),
        ),
        hasLength(2),
      );
    });

    test('终端与文件更改开关各自独立', () {
      final terminal = [call(1, 'Bash', '{}'), call(2, 'Bash', '{}')];
      final changes = [call(1, 'Edit', '{}'), call(2, 'Write', '{}')];

      expect(ConversationBlock.group(terminal), hasLength(1));
      expect(
        ConversationBlock.group(
          terminal,
          grouping: const ConversationGrouping(terminal: false),
        ),
        hasLength(2),
      );

      expect(ConversationBlock.group(changes), hasLength(1));
      expect(
        ConversationBlock.group(
          changes,
          grouping: const ConversationGrouping(changes: false),
        ),
        hasLength(2),
      );
      // 关掉文件更改不影响终端
      expect(
        ConversationBlock.group(
          terminal,
          grouping: const ConversationGrouping(changes: false),
        ),
        hasLength(1),
      );
    });

    test('未归类工具不受开关影响', () {
      final rows = [call(1, 'mcp__x__do', '{}'), call(2, 'mcp__x__do', '{}')];
      expect(
        ConversationBlock.group(
          rows,
          grouping: const ConversationGrouping(
            explore: false,
            terminal: false,
            changes: false,
          ),
        ),
        hasLength(1),
      );
    });

    test('跨分类不会并到一起去', () {
      final blocks = ConversationBlock.group([
        call(1, 'Read', '{}'),
        call(2, 'Bash', '{}'),
      ]);
      expect(blocks, hasLength(2));
    });

    test('合并后仍保留分类（回归：曾因丢 category 导致后续无法归并）', () {
      final blocks = ConversationBlock.group([
        call(1, 'Read', '{}'),
        call(2, 'Grep', '{}'),
        call(3, 'Glob', '{}'),
      ]);
      expect(blocks, hasLength(1));
      expect((blocks.single as ToolCallGroup).category, 'explore');
      expect((blocks.single as ToolCallGroup).rows, hasLength(3));
    });
  });

  group('轮次分隔', () {
    test('解析 fileChanges', () {
      final r = mk(1, {
        'kind': 'turnHeader',
        'state': 'completedSuccess',
        'fileChanges': {'additions': 12, 'deletions': 3, 'files': 4},
      });
      expect(r.kind, ConversationRowKind.turnHeader);
      final b = TurnHeaderBlock([r]);
      expect(b.fileChanges, isNotNull);
      expect(b.fileChanges!.additions, 12);
      expect(b.fileChanges!.deletions, 3);
      expect(b.fileChanges!.files, 4);
      expect(b.state, 'completedSuccess');
    });

    test('无 fileChanges 时返回 null（UI 退化成细线）', () {
      final b = TurnHeaderBlock([
        mk(1, {'kind': 'turnHeader'}),
      ]);
      expect(b.fileChanges, isNull);
    });
  });

  group('行类型映射', () {
    test('上游 userInput 映射为用户消息', () {
      final r = mk(1, {'kind': 'userInput', 'text': '帮我看看'});
      expect(r.kind, ConversationRowKind.userText);
      expect(r.text, '帮我看看');
      final b = ConversationBlock.group([r]).single as TextBlock;
      expect(b.isUser, isTrue);
    });

    test('新增类型不会打断分组', () {
      final blocks = ConversationBlock.group([
        mk(1, {'kind': 'turnHeader'}),
        mk(2, {'kind': 'userInput', 'text': '问题'}),
        call(3, 'Read', '{}'),
        mk(4, {'kind': 'reasoning', 'text': '想想'}),
        mk(5, {'kind': 'assistantText', 'text': '答'}),
      ]);
      expect(blocks.map((b) => b.runtimeType).toList(), [
        TurnHeaderBlock,
        TextBlock,
        ToolCallGroup,
        ReasoningBlock,
        TextBlock,
      ]);
    });
  });

  group('模型切换标记（真机实测 kind=timelineMarker）', () {
    ConversationRow marker() => mk(1, {
      'kind': 'timelineMarker',
      'lane': 'lightBoundary',
      'marker': {
        'type': 'modelChange',
        'fromProvider': 'p1',
        'fromModel': 'deepseek-v4-flash',
        'toProvider': 'p2',
        'toModel': 'mimo-v2.5',
        'toThought': 'enabled',
      },
    });

    test('映射为 timelineMarker 并解析出模型变化', () {
      final r = marker();
      expect(r.kind, ConversationRowKind.timelineMarker);
      expect(r.marker, isNotNull);
      expect(r.marker!.type, 'modelChange');
      expect(r.marker!.fromModel, 'deepseek-v4-flash');
      expect(r.marker!.toModel, 'mimo-v2.5');
    });

    test('单独成块且被识别为模型切换', () {
      final b = ConversationBlock.group([marker()]).single;
      expect(b, isA<MarkerBlock>());
      expect((b as MarkerBlock).isModelChange, isTrue);
      expect(b.toModel, 'mimo-v2.5');
    });

    test('缺 marker 字段不炸', () {
      final r = mk(1, {'kind': 'timelineMarker'});
      expect(r.marker, isNull);
      expect(ConversationBlock.group([r]).single, isA<MarkerBlock>());
    });

    test('不会打断相邻的工具分组', () {
      final blocks = ConversationBlock.group([
        call(1, 'Read', '{}'),
        marker(),
        call(2, 'Read', '{}'),
      ]);
      expect(blocks.map((b) => b.runtimeType).toList(), [
        ToolCallGroup,
        MarkerBlock,
        ToolCallGroup,
      ]);
    });
  });

  group('用户消息来源（真机实测 userInput.origin）', () {
    test('realUser 视为真人发言', () {
      final b =
          ConversationBlock.group([
                mk(1, {
                  'kind': 'userInput',
                  'text': '继续',
                  'origin': 'realUser',
                }),
              ]).single
              as TextBlock;
      expect(b.isUser, isTrue);
      expect(b.isRealUser, isTrue);
      expect(b.userOrigin, isNull);
    });

    test('backgroundResult 不算真人发言，并给出来源', () {
      final b =
          ConversationBlock.group([
                mk(1, {
                  'kind': 'userInput',
                  'text': '跑完了',
                  'origin': 'backgroundResult',
                }),
              ]).single
              as TextBlock;
      expect(b.isUser, isTrue);
      expect(b.isRealUser, isFalse);
      expect(b.userOrigin, 'backgroundResult');
    });

    test('缺 origin 时按真人处理（兼容旧数据）', () {
      final b =
          ConversationBlock.group([
                mk(1, {'kind': 'userInput', 'text': 'x'}),
              ]).single
              as TextBlock;
      expect(b.isRealUser, isTrue);
    });

    test('goalContinuation / mailbox / synthetic 同样被标记', () {
      for (final o in ['goalContinuation', 'mailbox', 'synthetic']) {
        final b =
            ConversationBlock.group([
                  mk(1, {'kind': 'userInput', 'text': 'x', 'origin': o}),
                ]).single
                as TextBlock;
        expect(b.userOrigin, o, reason: o);
      }
    });
  });

  group('轮次信息（真机实测 turnHeader 字段）', () {
    test('解析 originMeta.title / activeMs / origin', () {
      final r = mk(1, {
        'kind': 'turnHeader',
        'origin': 'backgroundResult',
        'executionKind': 'agent',
        'state': 'completedSuccess',
        'activeMs': 2041220,
        'originMeta': {
          'backgroundSource': 'bash',
          'workId': 'exec_1',
          'title': 'Final full regression for R3 evidence',
        },
      });
      final b = TurnHeaderBlock([r]);
      expect(b.title, 'Final full regression for R3 evidence');
      expect(b.activeMs, 2041220);
      expect(b.origin, 'backgroundResult');
      expect(b.state, 'completedSuccess');
    });

    test('没有 fileChanges 时不当作错误（真机上确实没有）', () {
      final b = TurnHeaderBlock([
        mk(1, {'kind': 'turnHeader'}),
      ]);
      expect(b.fileChanges, isNull);
      expect(b.title, isNull);
      expect(b.activeMs, isNull);
    });

    test('originMeta 标题为空字符串时返回 null', () {
      final b = TurnHeaderBlock([
        mk(1, {
          'kind': 'turnHeader',
          'originMeta': {'title': '   '},
        }),
      ]);
      expect(b.title, isNull);
    });
  });
}

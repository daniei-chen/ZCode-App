import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/relay/agent_rpc.dart';
import 'package:zremote/relay/conversation_update.dart';

void main() {
  test('历史响应归一化并保留会话范围', () {
    final update = ConversationUpdate.fromResponse({
      'sessionId': 'sess-1',
      'workspacePath': r'E:\work',
      'rows': [
        {'rowId': 2, 'kind': 'assistantText', 'text': '答'},
      ],
    });

    expect(update, isNotNull);
    expect(update!.rows.single.text, '答');
    expect(update.sessionId, 'sess-1');
    expect(update.workspacePath, r'E:\work');
    expect(update.isRealtime, isFalse);
  });

  test('实时 RPC 支持批量 rows 与单行 data', () {
    final batch = ConversationUpdate.fromAgentRpc(
      AgentRpc.call(
        seq: 1,
        service: 'zcode-agent',
        method: 'onDynamicConversationFrame',
        args: [
          {
            'sessionId': 'sess-2',
            'rows': [
              {'rowId': 3, 'kind': 'userText', 'text': '问'},
            ],
          },
        ],
      ),
    );
    expect(batch, isNotNull);
    expect(batch!.rows.single.kind.name, 'userText');
    expect(batch.sessionId, 'sess-2');
    expect(batch.isRealtime, isTrue);

    final single = ConversationUpdate.fromAgentRpc(
      AgentRpc.call(
        seq: 2,
        service: 'zcode-agent',
        method: 'conversationRowAppended',
        args: [
          {
            'sessionId': 'sess-3',
            'data': {'rowId': 4, 'kind': 'toolCall', 'toolName': 'Read'},
          },
        ],
      ),
    );
    expect(single, isNotNull);
    expect(single!.rows.single.toolName, 'Read');
    expect(single.sessionId, 'sess-3');
  });

  test('非会话 service 和深层异常对象不会进入更新流', () {
    expect(
      ConversationUpdate.fromAgentRpc(
        AgentRpc.call(
          seq: 1,
          service: 'setting',
          method: 'onDynamicChange',
          args: const [],
        ),
      ),
      isNull,
    );
    expect(
      ConversationUpdate.fromAgentRpc(
        AgentRpc.call(
          seq: 1,
          service: 'zcode-agent',
          method: 'onDynamicConversationFrame',
          args: [
            {
              'payload': {
                'nested': {
                  'stillNested': {'notRows': true},
                },
              },
            },
          ],
        ),
      ),
      isNull,
    );
  });
}

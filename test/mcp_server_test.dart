import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/mcp_server.dart';

void main() {
  group('McpServerEntry 容错解析与脱敏', () {
    test('解析真实候选列表并保留安全字段', () {
      final list = McpServerEntry.parseResponse({
        'candidates': [
          {
            'id': 'anysearch-0',
            'name': 'anysearch-0',
            'enabled': true,
            'source': 'user',
            'path': 'C:/Users/example/.mcp.json',
            'config': {
              'url': 'https://mcp.example.test/sse?token=secret',
              'headers': {'authorization': 'Bearer secret'},
            },
          },
        ],
      });

      expect(list, hasLength(1));
      final entry = list!.single;
      expect(entry.name, 'anysearch-0');
      expect(entry.enabled, isTrue);
      expect(entry.group, 'local');
      expect(entry.transport, 'http');
      expect(entry.endpoint, 'https://mcp.example.test');
      expect(entry.description, isNot(contains('secret')));
      expect(entry.searchKeywords, contains('anysearch-0'));
    });

    test('stdio 只展示命令，不展示参数或配置 headers', () {
      final list = McpServerEntry.parseResponse({
        'candidates': [
          {
            'name': 'computer-use',
            'config': {
              'command': 'node',
              'args': ['server.js', '--token', 'secret'],
              'headers': {'x-token': 'secret'},
            },
          },
        ],
      })!;
      expect(list.single.transport, 'stdio');
      expect(list.single.command, 'node');
      expect(list.single.description, 'stdio · node');
      expect(list.single.description, isNot(contains('secret')));
    });

    test('URL query、路径与 fragment 不进入展示', () {
      final entry = McpServerEntry.tryParse('server', {
        'config': {'url': 'https://example.test/private/path?key=secret#x'},
      })!;
      expect(entry.endpoint, 'https://example.test');
      expect(entry.description, isNot(contains('secret')));
    });

    test('按 source 分组', () {
      final list = McpServerEntry.parseResponse({
        'servers': [
          {'id': 'p', 'name': 'plugin-server', 'source': 'plugin'},
          {'id': 'b', 'name': 'builtin-server', 'source': 'built-in'},
          {'id': 'u', 'name': 'user-server', 'source': 'user'},
        ],
      })!;
      expect(list.map((e) => e.group), ['plugin', 'builtin', 'local']);
    });

    test('兼容 map 形态与缺字段', () {
      final list = McpServerEntry.parseResponse({
        'mcpServers': {
          'one': <String, dynamic>{},
          'two': {'enabled': false},
        },
      })!;
      expect(list, hasLength(2));
      expect(list[0].name, 'one');
      expect(list[0].enabled, isTrue);
      expect(list[1].enabled, isFalse);
    });

    test('远端状态使用独立分组并保留状态字段', () {
      final list = McpServerEntry.parseResponse({
        'statuses': {
          'remote-server': {'status': 'synced', 'transport': 'http'},
        },
      }, remote: true);
      expect(list, hasLength(1));
      expect(list!.single.remote, isTrue);
      expect(list.single.group, '远端');
      expect(list.single.status, 'synced');
      expect(list.single.description, contains('synced'));
    });

    test('非法响应返回 null，非法条目被丢弃', () {
      expect(McpServerEntry.parseResponse(null), isNull);
      expect(McpServerEntry.parseResponse({'candidates': 'bad'}), isNull);
      final list = McpServerEntry.parseResponse({
        'candidates': [
          'bad',
          {'id': 'ok'},
        ],
      });
      expect(list, hasLength(1));
      expect(list!.single.id, 'ok');
    });
  });
}

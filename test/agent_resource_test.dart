import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/resource_list.dart';

void main() {
  test('通用 Agent 资源只提取白名单字段', () {
    final items = AgentResourceEntry.parseResponse({
      'items': [
        {
          'id': 'hook-1',
          'name': 'Before tool',
          'description': 'runs before tools',
          'scope': 'user',
          'enabled': false,
          'headers': {'Authorization': 'secret'},
          'commandBody': 'do not render',
        },
      ],
    });

    expect(items, hasLength(1));
    final item = items!.single;
    expect(item.id, 'hook-1');
    expect(item.title, 'Before tool');
    expect(item.description, 'runs before tools');
    expect(item.enabled, isFalse);
    expect(item.readOnly, isTrue);
    expect(item.searchKeywords, contains('user'));
  });

  test('支持 map keyed-by-id 与字符串项', () {
    final items = AgentResourceEntry.parseResponse({
      'commands': {
        'build': {'description': 'Build project'},
        'check': {'label': 'Check project'},
      },
    });
    expect(items, hasLength(2));
    expect(items!.map((e) => e.title), containsAll(['build', 'Check project']));
  });

  test('不把标量配置 map 当作列表', () {
    expect(
      AgentResourceEntry.parseResponse({'enabled': true, 'token': 'secret'}),
      isNull,
    );
  });
}

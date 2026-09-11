import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/plugin_status.dart';

void main() {
  group('PluginOverview 目录解析', () {
    test('同时解析已安装、可用插件和市场摘要', () {
      final overview = PluginOverview.parseResponse({
        'installedPlugins': [
          {
            'id': 'document-skills',
            'displayName': 'Document Skills',
            'version': '1.2.0',
            'enabled': true,
          },
        ],
        'availablePlugins': {
          'computer-use': {'title': 'Computer Use', 'source': 'builtin'},
        },
        'marketplaces': [
          {'id': 'official', 'name': 'Official'},
        ],
        'capability': {'supported': false, 'reason': 'desktop-only'},
      });

      expect(overview, isNotNull);
      expect(overview!.installed.single.title, 'Document Skills');
      expect(overview.available.single.id, 'computer-use');
      expect(overview.available.single.group, '可用');
      expect(overview.marketplaces.single.name, 'Official');
      expect(overview.capabilitySupported, isFalse);
      expect(overview.entries, hasLength(2));
    });

    test('不存在目录键时不把服务状态误判成插件目录', () {
      expect(
        PluginOverview.parseResponse({
          'statuses': {
            'plugin:p:server': {'status': 'connected'},
          },
        }),
        isNull,
      );
    });
  });

  group('PluginStatusEntry 容错解析', () {
    test('从真实结构解析（真机实测）', () {
      final list = PluginStatusEntry.parseResponse({
        'statuses': {
          'plugin:document-skills:image_search': {
            'status': 'connected',
            'transport': 'http',
            'toolCount': 1,
            'updatedAt': '2026-09-10T10:54:50.023Z',
            'protocolEra': 'modern',
          },
          'plugin:computer-use:computer-use': {
            'status': 'connected',
            'transport': 'stdio',
            'toolCount': 30,
          },
        },
      });
      expect(list, isNotNull);
      expect(list!, hasLength(2));

      final first = list.firstWhere((e) => e.serverName == 'image_search');
      expect(first.pluginName, 'document-skills');
      expect(first.status, 'connected');
      expect(first.transport, 'http');
      expect(first.toolCount, 1);
      expect(first.enabled, isTrue);
      expect(first.readOnly, isTrue);
    });

    test('key 切分：多段服务名保留完整', () {
      final list = PluginStatusEntry.parseResponse({
        'statuses': {
          'plugin:my-plugin:a:b': {'status': 'connected'},
        },
      })!;
      expect(list.single.pluginName, 'my-plugin');
      expect(list.single.serverName, 'a:b');
    });

    test('key 只有两段时不崩', () {
      final list = PluginStatusEntry.parseResponse({
        'statuses': {
          'plugin:only': {'status': 'connected'},
        },
      })!;
      expect(list.single.serverName, 'only');
      expect(list.single.pluginName, isNull);
    });

    test('描述把关键信息拼起来而不是只显示一个词', () {
      final list = PluginStatusEntry.parseResponse({
        'statuses': {
          'plugin:computer-use:computer-use': {
            'status': 'connected',
            'transport': 'stdio',
            'toolCount': 30,
            'protocolEra': 'modern',
          },
        },
      })!;
      final d = list.single.description!;
      expect(d, contains('computer-use'));
      expect(d, contains('stdio'));
      expect(d, contains('30'));
      expect(d, contains('modern'));
    });

    test('按插件名分组', () {
      final list = PluginStatusEntry.parseResponse({
        'statuses': {
          'plugin:p1:a': {'status': 'connected'},
          'plugin:p2:b': {'status': 'connected'},
          'plugin:p1:c': {'status': 'connected'},
        },
      })!;
      expect(list.where((e) => e.group == 'p1'), hasLength(2));
      expect(list.where((e) => e.group == 'p2'), hasLength(1));
    });

    test('非 connected 不算已启用', () {
      final list = PluginStatusEntry.parseResponse({
        'statuses': {
          'plugin:p:a': {'status': 'error'},
          'plugin:p:b': {'status': 'connecting'},
        },
      })!;
      expect(list.every((e) => !e.enabled), isTrue);
    });

    test('缺字段不影响解析', () {
      final list = PluginStatusEntry.parseResponse({
        'statuses': {'plugin:p:a': <String, dynamic>{}},
      })!;
      expect(list.single.serverName, 'a');
      expect(list.single.pluginName, 'p');
      expect(list.single.status, isNull);
      expect(list.single.description, 'p');
    });

    test('非法条目被丢弃但不炸', () {
      final list = PluginStatusEntry.parseResponse({
        'statuses': {
          'plugin:p:a': 'not-a-map',
          'plugin:p:b': {'status': 'connected'},
        },
      })!;
      expect(list, hasLength(1));
      expect(list.single.serverName, 'b');
    });

    test('兼容 list 形态', () {
      final list = PluginStatusEntry.parseResponse({
        'servers': [
          {'id': 'plugin:p:a', 'status': 'connected', 'transport': 'http'},
        ],
      })!;
      expect(list.single.serverName, 'a');
      expect(list.single.transport, 'http');
    });

    test('响应不是预期形状时返回 null', () {
      expect(PluginStatusEntry.parseResponse(null), isNull);
      expect(PluginStatusEntry.parseResponse('x'), isNull);
      expect(PluginStatusEntry.parseResponse({'nope': 1}), isNull);
    });

    test('空 statuses 返回空列表而非 null', () {
      expect(PluginStatusEntry.parseResponse({'statuses': {}}), isEmpty);
    });

    test('搜索关键词包含插件名、状态与传输方式', () {
      final list = PluginStatusEntry.parseResponse({
        'statuses': {
          'plugin:my-plugin:my-server': {
            'status': 'connected',
            'transport': 'stdio',
          },
        },
      })!;
      final kw = list.single.searchKeywords.toList();
      expect(kw, contains('my-plugin'));
      expect(kw, contains('connected'));
      expect(kw, contains('stdio'));
      expect(kw, contains('plugin:my-plugin:my-server'));
    });
  });
}

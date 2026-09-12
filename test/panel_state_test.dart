import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/state/panel_state.dart';

void main() {
  group('PanelDataExtractor.parseRoot（characterization：锁定防御式提取行为）', () {
    test('空输入返回 PanelSnapshot.empty', () {
      expect(PanelDataExtractor.parseRoot(null), PanelSnapshot.empty);
      expect(PanelDataExtractor.parseRoot(<String, dynamic>{}), PanelSnapshot.empty);
      expect(PanelDataExtractor.parseRoot('not a map'), PanelSnapshot.empty);
    });

    test('plan Map：planName + 百分比配额提取，且继续深扫嵌套内容', () {
      // 配额形状：plan Map 的直接子键（数值 0-100 或含 percent 的 Map）。
      final root = {
        'plan': {
          'planName': 'GLM 高级版',
          'audience': '个人',
          'tokensRemaining': {'percent': 42, 'label': 'Token'},
        },
      };
      final snapshot = PanelDataExtractor.parseRoot(root);
      expect(snapshot.plan?.name, 'GLM 高级版');
      expect(snapshot.plan?.audience, '个人');
      expect(snapshot.quotas, hasLength(1));
      expect(snapshot.quotas.single.label, 'Token');
      expect(snapshot.quotas.single.percent, 42);
    });

    test('providers 列表里的嵌套 models 不会被误分类成供应商（单趟修复）', () {
      // 旧双重遍历会把 models 列表（含 'model' 键名）再次分类为
      // providers 并以更长的列表覆盖真实供应商；单趟版本不再重扫
      // 已消费的分类列表。
      final root = {
        'payload': {
          'snapshot': {
            'modelProviders': [
              {
                'name': 'GLM',
                'id': 'glm',
                'enabled': true,
                'current': true,
                'models': ['glm-5.3', {'name': 'glm-4.7'}],
              },
            ],
          },
        },
      };
      final snapshot = PanelDataExtractor.parseRoot(root);
      expect(snapshot.providers, hasLength(1));
      expect(snapshot.providers.single.name, 'GLM');
      expect(snapshot.providers.single.id, 'glm');
      expect(snapshot.providers.single.enabled, isTrue);
      expect(snapshot.providers.single.isCurrent, isTrue);
      expect(snapshot.providers.single.models, ['glm-5.3', 'glm-4.7']);
    });

    test('providers 双列表 longest-wins：更长者胜', () {
      final root = {
        'providers': [
          {'name': 'A'},
          {'name': 'B'},
        ],
        'nested': {
          'modelList': [
            {'name': 'C'},
            {'name': 'D'},
            {'name': 'E'},
          ],
        },
      };
      final snapshot = PanelDataExtractor.parseRoot(root);
      expect(snapshot.providers, hasLength(3));
      expect(snapshot.providers.map((p) => p.name), containsAll(['C', 'D', 'E']));
    });

    test('subagents / quotas / usage / 列表面板（skills、mcp）分类正确', () {
      final root = {
        'subagents': [
          {'name': 'planner', 'description': '规划', 'enabled': false},
        ],
        'quotaList': [
          {'label': '用量', 'percent': 0.5, 'resetAt': '周一'},
        ],
        'usageStats': [
          {'label': 'glm-5.3', 'value': '1.2k', 'detail': '今日'},
        ],
        'skills': [
          {'name': 'brainstorming', 'enabled': true},
        ],
        'mcpServers': [
          {'name': 'anysearch', 'description': '搜索'},
        ],
      };
      final snapshot = PanelDataExtractor.parseRoot(root);
      expect(snapshot.subagents.single.name, 'planner');
      expect(snapshot.subagents.single.enabled, isFalse);
      expect(snapshot.quotas.single.percent, 50);
      expect(snapshot.quotas.single.resetLabel, '周一');
      expect(snapshot.usage.single.label, 'glm-5.3');
      expect(snapshot.usage.single.value, '1.2k');
      expect(snapshot.listPanels[PanelKeys.skills], hasLength(1));
      expect(snapshot.listPanels[PanelKeys.mcp], hasLength(1));
    });

    test('空列表不挡深层扫描：空 skills 后的嵌套 skills 仍被找到', () {
      final root = {
        'skills': <Map>[],
        'wrapper': {'deep': {'skills': [{'name': 'deep-skill'}]}},
      };
      final snapshot = PanelDataExtractor.parseRoot(root);
      expect(snapshot.listPanels[PanelKeys.skills], hasLength(1));
      expect(snapshot.listPanels[PanelKeys.skills]!.single.name, 'deep-skill');
    });

    test('深度上限：超过 _maxDepth 的数据不提取', () {
      Map<String, dynamic> wrap(Map<String, dynamic> inner, int times) {
        var node = inner;
        for (var i = 0; i < times; i++) {
          node = {'l$i': node};
        }
        return node;
      }

      final root = wrap({
        'providers': [
          {'name': 'too-deep'},
        ],
      }, 9);
      final snapshot = PanelDataExtractor.parseRoot(root);
      expect(snapshot.providers, isEmpty);
      expect(snapshot, PanelSnapshot.empty);
    });

    test('重复字段名（防御式重复键）：first-wins / longest-wins 语义', () {
      final root = {
        'plan': {'planName': '第一个'},
        'codingPlan': {'planName': '第二个'},
      };
      final snapshot = PanelDataExtractor.parseRoot(root);
      expect(snapshot.plan?.name, '第一个');
    });
  });
}

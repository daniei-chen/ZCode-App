import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/resource_list.dart';
import 'package:zremote/models/skill.dart';

class FakeEntry implements ResourceEntry {
  FakeEntry({
    required this.id,
    required this.title,
    this.description,
    this.group,
    this.enabled = true,
    this.readOnly = false,
    this.keywords = const [],
  });

  @override
  final String id;
  @override
  final String title;
  @override
  final String? description;
  @override
  final String? group;
  @override
  final bool enabled;
  @override
  final bool readOnly;
  final List<String> keywords;
  @override
  Iterable<String> get searchKeywords => keywords;
}

void main() {
  test('资源阶段覆盖空、过期、未支持和拒绝状态', () {
    expect(
      ResourcePhase.values,
      containsAll([
        ResourcePhase.empty,
        ResourcePhase.stale,
        ResourcePhase.unsupported,
        ResourcePhase.permissionDenied,
      ]),
    );
  });

  group('ResourceListing 筛选与分组', () {
    final items = [
      FakeEntry(id: 'a', title: 'brainstorming', group: 'local'),
      FakeEntry(id: 'b', title: 'anysearch', group: 'plugin'),
      FakeEntry(
        id: 'c',
        title: 'self-iterate',
        description: '反复改进',
        group: 'local',
        enabled: false,
      ),
      FakeEntry(id: 'd', title: 'no-group'),
    ];

    test('无筛选时全部保留', () {
      final sections = ResourceListing.apply(items);
      final all = sections.expand((s) => s.items).toList();
      expect(all, hasLength(4));
    });

    test('关键词匹配标题、描述与附加关键词', () {
      expect(
        ResourceListing.apply(
          items,
          filter: const ResourceFilter(query: 'brain'),
        ).expand((s) => s.items).single.id,
        'a',
      );
      // 描述命中
      expect(
        ResourceListing.apply(
          items,
          filter: const ResourceFilter(query: '反复'),
        ).expand((s) => s.items).single.id,
        'c',
      );
      // 大小写不敏感
      expect(
        ResourceListing.apply(
          items,
          filter: const ResourceFilter(query: 'BRAIN'),
        ).expand((s) => s.items),
        hasLength(1),
      );
      // 附加关键词
      final withKw = [
        FakeEntry(id: 'e', title: 'x', keywords: ['glm:user:x']),
      ];
      expect(
        ResourceListing.apply(
          withKw,
          filter: const ResourceFilter(query: 'user'),
        ),
        hasLength(1),
      );
    });

    test('状态筛选', () {
      final enabled = ResourceListing.apply(
        items,
        filter: const ResourceFilter(status: ResourceStatusFilter.enabled),
      ).expand((s) => s.items);
      expect(enabled.map((e) => e.id), ['a', 'b', 'd']);

      final disabled = ResourceListing.apply(
        items,
        filter: const ResourceFilter(status: ResourceStatusFilter.disabled),
      ).expand((s) => s.items);
      expect(disabled.map((e) => e.id), ['c']);
    });

    test('筛选与关键词叠加', () {
      // 只有 c 是未启用；用 'brain' 查不到它 → 两个条件叠加后应为空
      final r = ResourceListing.apply(
        items,
        filter: const ResourceFilter(
          query: 'brain',
          status: ResourceStatusFilter.disabled,
        ),
      ).expand((s) => s.items);
      expect(r, isEmpty);

      // 查到 c 自己时则应命中
      final hit = ResourceListing.apply(
        items,
        filter: const ResourceFilter(
          query: 'iterate',
          status: ResourceStatusFilter.disabled,
        ),
      ).expand((s) => s.items);
      expect(hit.map((e) => e.id), ['c']);
    });

    test('分组标签排序稳定，未分组放最后', () {
      final sections = ResourceListing.apply(items);
      expect(sections.map((s) => s.label), ['local', 'plugin', null]);
    });

    test('只有一组时不显示分组标题（省视觉噪音）', () {
      final single = [FakeEntry(id: 'a', title: 'x', group: 'local')];
      expect(
        ResourceListing.needsGroupHeaders(ResourceListing.apply(single)),
        isFalse,
      );
      expect(
        ResourceListing.needsGroupHeaders(ResourceListing.apply(items)),
        isTrue,
      );
    });

    test('全部无分组时不需要分组标题', () {
      final flat = [
        FakeEntry(id: 'a', title: 'x'),
        FakeEntry(id: 'b', title: 'y'),
      ];
      expect(
        ResourceListing.needsGroupHeaders(ResourceListing.apply(flat)),
        isFalse,
      );
    });

    test('计数', () {
      final c = ResourceListing.counts(items);
      expect(c.total, 4);
      expect(c.enabled, 3);
    });

    test('空输入返回空', () {
      expect(ResourceListing.apply(const []), isEmpty);
    });

    test('isActive 只在真正筛选时为真', () {
      expect(const ResourceFilter().isActive, isFalse);
      expect(const ResourceFilter(query: '  ').isActive, isFalse);
      expect(const ResourceFilter(query: 'a').isActive, isTrue);
      expect(
        const ResourceFilter(status: ResourceStatusFilter.enabled).isActive,
        isTrue,
      );
    });
  });

  group('SkillEntry 容错解析', () {
    test('标准字段', () {
      final s = SkillEntry.tryParse({
        'id': 'glm:user:brainstorming:abc',
        'name': 'brainstorming',
        'description': '你必须在任何创作前使用',
      })!;
      expect(s.id, 'glm:user:brainstorming:abc');
      expect(s.name, 'brainstorming');
      expect(s.description, '你必须在任何创作前使用');
      expect(s.enabled, isTrue);
      // 从 id 推出来源
      expect(s.source, 'user');
      expect(s.group, 'local');
      expect(s.readOnly, isFalse);
    });

    test('缺 id 时用 name 兜底；缺 name 时用 directoryName', () {
      expect(SkillEntry.tryParse({'name': 'x'})!.id, 'x');
      expect(SkillEntry.tryParse({'directoryName': 'dir'})!.name, 'dir');
    });

    test('既无 id 也无 name 返回 null', () {
      expect(SkillEntry.tryParse({}), isNull);
      expect(SkillEntry.tryParse('x'), isNull);
      expect(SkillEntry.tryParse(null), isNull);
      expect(SkillEntry.tryParse({'name': '   '}), isNull);
    });

    test('source 显式字段优先于 id 推断', () {
      final s = SkillEntry.tryParse({
        'id': 'glm:user:x:1',
        'name': 'x',
        'source': 'plugin',
      })!;
      expect(s.source, 'plugin');
      expect(s.group, 'plugin');
      expect(s.readOnly, isTrue);
    });

    test('推不出来源时为 null，不瞎猜', () {
      final s = SkillEntry.tryParse({'id': 'weird', 'name': 'weird'})!;
      expect(s.source, isNull);
      // 归到 local 组，仍可编辑
      expect(s.group, 'local');
      expect(s.readOnly, isFalse);
    });

    test('enabled 非 bool 时按启用处理', () {
      expect(
        SkillEntry.tryParse({'name': 'x', 'enabled': 'yes'})!.enabled,
        isTrue,
      );
      expect(
        SkillEntry.tryParse({'name': 'x', 'enabled': false})!.enabled,
        isFalse,
      );
    });

    test('description 缺失不影响解析', () {
      expect(SkillEntry.tryParse({'name': 'x'})!.description, isNull);
    });

    test('parseResponse 兼容 skills / items / entries 与裸数组', () {
      expect(
        SkillEntry.parseResponse({
          'skills': [
            {'name': 'a'},
          ],
        }),
        hasLength(1),
      );
      expect(
        SkillEntry.parseResponse({
          'items': [
            {'name': 'a'},
          ],
        }),
        hasLength(1),
      );
      expect(
        SkillEntry.parseResponse({
          'entries': [
            {'name': 'a'},
          ],
        }),
        hasLength(1),
      );
      expect(
        SkillEntry.parseResponse([
          {'name': 'a'},
        ]),
        hasLength(1),
      );
      expect(SkillEntry.parseResponse({'nope': 1}), isNull);
      expect(SkillEntry.parseResponse(null), isNull);
    });

    test('parseResponse 丢弃非法项但不炸', () {
      final r = SkillEntry.parseResponse({
        'skills': [
          {'name': 'ok'},
          'garbage',
          {},
        ],
      });
      expect(r, hasLength(1));
      expect(r!.single.name, 'ok');
    });

    test('copyWith 只改启用状态', () {
      final s = SkillEntry.tryParse({'name': 'x', 'description': 'd'})!;
      final t = s.copyWith(enabled: false);
      expect(t.enabled, isFalse);
      expect(t.name, 'x');
      expect(t.description, 'd');
    });

    test('搜索关键词包含来源与目录名', () {
      final s = SkillEntry.tryParse({
        'name': 'x',
        'source': 'plugin',
        'path': '/a/b',
        'directoryName': 'dirname',
      })!;
      expect(s.searchKeywords, containsAll(['plugin', '/a/b', 'dirname']));
    });
  });
}

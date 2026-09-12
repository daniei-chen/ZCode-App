import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/bridge_message_pipeline.dart';

/// 工作台面板的数据快照。全部字段可为空 —— 远控页何时推送哪类数据
/// 取决于用户在页面里的操作，未拿到的面板显示引导空态。
class PanelSnapshot {
  const PanelSnapshot({
    this.updatedAt,
    this.providers = const <ModelProviderInfo>[],
    this.plan,
    this.quotas = const <QuotaInfo>[],
    this.usage = const <UsageEntry>[],
    this.subagents = const <SubagentInfo>[],
    this.listPanels = const <String, List<PanelItem>>{},
  });

  final int? updatedAt;

  final List<ModelProviderInfo> providers;

  final PlanInfo? plan;

  final List<QuotaInfo> quotas;

  final List<UsageEntry> usage;

  final List<SubagentInfo> subagents;

  /// 技能 / MCP / 插件 / 命令 / 钩子 / 记忆 等列表型面板。
  final Map<String, List<PanelItem>> listPanels;

  bool get isEmpty =>
      providers.isEmpty &&
      plan == null &&
      quotas.isEmpty &&
      usage.isEmpty &&
      subagents.isEmpty &&
      listPanels.values.every((l) => l.isEmpty);

  PanelSnapshot copyWith({
    int? updatedAt,
    List<ModelProviderInfo>? providers,
    PlanInfo? plan,
    bool clearPlan = false,
    List<QuotaInfo>? quotas,
    List<UsageEntry>? usage,
    List<SubagentInfo>? subagents,
    Map<String, List<PanelItem>>? listPanels,
  }) => PanelSnapshot(
    updatedAt: updatedAt ?? this.updatedAt,
    providers: providers ?? this.providers,
    plan: clearPlan ? null : (plan ?? this.plan),
    quotas: quotas ?? this.quotas,
    usage: usage ?? this.usage,
    subagents: subagents ?? this.subagents,
    listPanels: listPanels ?? this.listPanels,
  );

  static const empty = PanelSnapshot();
}

class ModelProviderInfo {
  const ModelProviderInfo({
    required this.name,
    this.id,
    this.enabled,
    this.models = const <String>[],
    this.isCurrent = false,
  });

  final String name;

  final String? id;

  final bool? enabled;

  final List<String> models;

  final bool isCurrent;
}

class PlanInfo {
  const PlanInfo({
    required this.name,
    this.audience,
    this.expiresAt,
    this.renewLabel,
  });

  final String name;

  final String? audience;

  final String? expiresAt;

  final String? renewLabel;
}

class QuotaInfo {
  const QuotaInfo({
    required this.label,
    required this.percent,
    this.resetLabel,
  });

  final String label;

  /// 0–100。
  final double percent;

  final String? resetLabel;
}

class UsageEntry {
  const UsageEntry({required this.label, this.value, this.detail});

  final String label;

  final String? value;

  final String? detail;
}

class SubagentInfo {
  const SubagentInfo({
    required this.name,
    this.description,
    this.model,
    this.enabled,
  });

  final String name;

  final String? description;

  final String? model;

  final bool? enabled;
}

/// 通用列表项（技能 / MCP / 插件 / 命令 / 钩子 / 记忆）。
class PanelItem {
  const PanelItem({
    required this.name,
    this.description,
    this.tag,
    this.enabled,
  });

  final String name;

  final String? description;

  final String? tag;

  final bool? enabled;
}

/// 面板类别 key —— listPanels 的键。
abstract final class PanelKeys {
  static const skills = 'skills';
  static const mcp = 'mcp';
  static const plugins = 'plugins';
  static const commands = 'commands';
  static const hooks = 'hooks';
  static const memory = 'memory';
  static const outputStyles = 'outputStyles';

  static const all = [
    skills,
    mcp,
    plugins,
    commands,
    hooks,
    memory,
    outputStyles,
  ];
}

/// 从桥接消息里扫描面板数据。协议字段名未公开文档化，
/// 这里沿用 event_observer 的防御式风格：按常见键名 + 深度受限遍历。
abstract final class PanelDataExtractor {
  static const int _maxDepth = 6;
  static const int _maxItems = 64;

  static PanelSnapshot parseRoot(dynamic root, {int? now}) {
    var providers = <ModelProviderInfo>[];
    PlanInfo? plan;
    var quotas = <QuotaInfo>[];
    var usage = <UsageEntry>[];
    var subagents = <SubagentInfo>[];
    var lists = <String, List<PanelItem>>{};

    _walk(
      root,
      0,
      _Sink(
        onProviders: (p) => providers = _mergeProviders(providers, p),
        onPlan: (p) => plan ??= p,
        onQuotas: (q) => quotas = quotas.isEmpty ? q : quotas,
        onUsage: (u) => usage = usage.isEmpty ? u : usage,
        onSubagents: (s) => subagents = _mergeSubagents(subagents, s),
        onList: (k, v) => lists[k] ??= v,
      ),
    );

    if (providers.isEmpty &&
        plan == null &&
        quotas.isEmpty &&
        usage.isEmpty &&
        subagents.isEmpty &&
        lists.isEmpty) {
      return PanelSnapshot.empty;
    }
    return PanelSnapshot(
      updatedAt: now,
      providers: providers,
      plan: plan,
      quotas: quotas,
      usage: usage,
      subagents: subagents,
      listPanels: lists,
    );
  }

  static List<ModelProviderInfo> _mergeProviders(
    List<ModelProviderInfo> prev,
    List<ModelProviderInfo> next,
  ) => next.length >= prev.length ? next : prev;

  static List<SubagentInfo> _mergeSubagents(
    List<SubagentInfo> prev,
    List<SubagentInfo> next,
  ) => next.length >= prev.length ? next : prev;

  static void _walk(dynamic node, int depth, _Sink sink) {
    if (depth > _maxDepth || node == null) return;
    if (node is List) {
      for (final v in node) {
        _walk(v, depth + 1, sink);
      }
      return;
    }
    if (node is! Map) return;

    for (final entry in node.entries) {
      final key = entry.key;
      final value = entry.value;

      if (key is! String) {
        // 非字符串键（防御）：不参与分类，但继续向下扫。
        if (value is Map || value is List) _walk(value, depth + 1, sink);
        continue;
      }
      final lower = key.toLowerCase();

      if (value is List) {
        final items = value.whereType<Map>().toList();
        if (items.isNotEmpty) {
          if (_isProviderList(lower, items)) {
            sink.onProviders(_providersOf(items));
            // 已分类的列表不再向深处重扫：列表项是完整消费过的领域对象，
            // 旧实现的双重遍历会把嵌套 models 列表误分类成 providers 并
            // 覆盖真实供应商（characterization 测试锁定的行为修复）。
            continue;
          } else if (lower.contains('subagent') || lower.contains('sub_agent')) {
            sink.onSubagents(_subagentsOf(items));
            continue;
          } else if (lower.contains('quota') || lower.contains('entitlement')) {
            sink.onQuotas(_quotasOf(items));
            continue;
          } else if (lower.contains('usage') &&
              !lower.contains('lastused') &&
              items.length <= _maxItems) {
            sink.onUsage(_usageOf(items));
            continue;
          } else {
            final panelKey = _panelKeyOf(lower);
            if (panelKey != null) {
              sink.onList(panelKey, _itemsOf(items));
              continue;
            }
          }
        }
        // 未命中的列表继续向下扫描。
        _walk(value, depth + 1, sink);
      } else if (value is Map) {
        if (lower.contains('entitlement') ||
            lower == 'plan' ||
            lower.contains('codingplan')) {
          final plan = _planOf(value);
          if (plan != null) sink.onPlan(plan);
          final q = _quotasMapOf(value);
          if (q.isNotEmpty) sink.onQuotas(q);
          // plan 节点内也可能嵌套其他面板数据，继续扫一遍（单趟内完成）。
          _walk(value, depth + 1, sink);
        } else {
          _walk(value, depth + 1, sink);
        }
      }
    }
    // 旧实现这里有一个第二遍全值循环：非 plan 的 Map 子节点被访问两次
    // （深度 d 翻倍放大），且会把已消费列表的嵌套内容误分类。上面的
    // 单趟版本对每个子节点恰好访问一次，首次 emit 的相对次序不变。
  }

  static String? _panelKeyOf(String lower) {
    if (lower == 'skills' || lower == 'skilllist') return PanelKeys.skills;
    if (lower.contains('mcp')) return PanelKeys.mcp;
    if (lower == 'plugins' || lower == 'pluginlist') return PanelKeys.plugins;
    if (lower == 'commands' || lower.contains('slashcommand')) {
      return PanelKeys.commands;
    }
    if (lower == 'hooks' || lower == 'hooklist') return PanelKeys.hooks;
    if (lower == 'memories' || lower.contains('memorylist')) {
      return PanelKeys.memory;
    }
    return null;
  }

  static bool _isProviderList(String lower, List<Map> items) {
    if (lower.contains('provider') || lower.contains('model')) {
      return items.any((m) => m['name'] is String || m['id'] is String);
    }
    return false;
  }

  static List<ModelProviderInfo> _providersOf(List<Map> items) {
    final out = <ModelProviderInfo>[];
    for (final m in items.take(_maxItems)) {
      final name = _firstString(m, const ['name', 'displayName', 'title']);
      final id = _firstString(m, const ['id', 'providerId', 'key']);
      if (name == null && id == null) continue;
      final models = <String>[];
      final rawModels = m['models'];
      if (rawModels is List) {
        for (final mm in rawModels.take(24)) {
          if (mm is String && mm.isNotEmpty) {
            models.add(mm);
          } else if (mm is Map) {
            final mn = _firstString(mm, const ['name', 'id', 'model']);
            if (mn != null) models.add(mn);
          }
        }
      }
      out.add(
        ModelProviderInfo(
          name: name ?? id ?? '',
          id: id,
          enabled: m['enabled'] is bool ? m['enabled'] as bool : null,
          models: models,
          isCurrent: m['current'] == true || m['isCurrent'] == true,
        ),
      );
    }
    return out;
  }

  static PlanInfo? _planOf(Map m) {
    final name = _firstString(m, const [
      'planName',
      'plan',
      'name',
      'productName',
      'title',
    ]);
    if (name == null) return null;
    return PlanInfo(
      name: name,
      audience: _firstString(m, const ['audience', 'planAudience', 'type']),
      expiresAt: _firstString(m, const [
        'expiresAt',
        'expireAt',
        'expiredAt',
        'renewDate',
        'expiry',
      ]),
      renewLabel: _firstString(m, const ['renewLabel', 'renew']),
    );
  }

  static List<QuotaInfo> _quotasMapOf(Map m) {
    final out = <QuotaInfo>[];
    m.forEach((k, v) {
      if (k is! String) return;
      if (v is num && v >= 0 && v <= 100) {
        out.add(QuotaInfo(label: k, percent: v.toDouble()));
      } else if (v is Map) {
        final p = _firstNum(v, const [
          'percent',
          'remaining',
          'value',
          'ratio',
        ]);
        if (p != null) {
          out.add(
            QuotaInfo(
              label: _firstString(v, const ['label', 'name', 'title']) ?? k,
              percent: (p <= 1 ? p * 100 : p).toDouble(),
              resetLabel: _firstString(v, const [
                'resetAt',
                'resetLabel',
                'reset',
              ]),
            ),
          );
        }
      }
    });
    return out;
  }

  static List<QuotaInfo> _quotasOf(List<Map> items) {
    final out = <QuotaInfo>[];
    for (final m in items.take(16)) {
      final label = _firstString(m, const ['label', 'name', 'title', 'type']);
      final percent = _firstNum(m, const [
        'percent',
        'remaining',
        'remainingPercent',
        'value',
        'ratio',
      ]);
      if (label == null || percent == null) continue;
      out.add(
        QuotaInfo(
          label: label,
          percent: (percent <= 1 ? percent * 100 : percent).toDouble(),
          resetLabel: _firstString(m, const ['resetAt', 'resetLabel', 'reset']),
        ),
      );
    }
    return out;
  }

  static List<UsageEntry> _usageOf(List<Map> items) {
    final out = <UsageEntry>[];
    for (final m in items.take(_maxItems)) {
      final label = _firstString(m, const [
        'label',
        'name',
        'title',
        'model',
        'key',
      ]);
      if (label == null) continue;
      out.add(
        UsageEntry(
          label: label,
          value:
              _firstString(m, const ['value', 'display', 'count', 'tokens']) ??
              _firstNum(m, const ['value', 'count'])?.toString(),
          detail: _firstString(m, const ['detail', 'description', 'subtitle']),
        ),
      );
    }
    return out;
  }

  static List<SubagentInfo> _subagentsOf(List<Map> items) {
    final out = <SubagentInfo>[];
    for (final m in items.take(_maxItems)) {
      final name = _firstString(m, const ['name', 'title', 'id', 'agentType']);
      if (name == null) continue;
      out.add(
        SubagentInfo(
          name: name,
          description: _firstString(m, const [
            'description',
            'prompt',
            'whenToUse',
            'summary',
          ]),
          model: _firstString(m, const ['model', 'modelId']),
          enabled: m['enabled'] is bool ? m['enabled'] as bool : null,
        ),
      );
    }
    return out;
  }

  static List<PanelItem> _itemsOf(List<Map> items) {
    final out = <PanelItem>[];
    for (final m in items.take(_maxItems)) {
      final name = _firstString(m, const ['name', 'title', 'id', 'label']);
      if (name == null) continue;
      out.add(
        PanelItem(
          name: name,
          description: _firstString(m, const [
            'description',
            'summary',
            'detail',
          ]),
          tag: _firstString(m, const ['type', 'kind', 'version', 'category']),
          enabled: m['enabled'] is bool
              ? m['enabled'] as bool
              : (m['active'] is bool ? m['active'] as bool : null),
        ),
      );
    }
    return out;
  }

  static String? _firstString(Map m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  static num? _firstNum(Map m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v is num) return v;
    }
    return null;
  }
}

class _Sink {
  const _Sink({
    required this.onProviders,
    required this.onPlan,
    required this.onQuotas,
    required this.onUsage,
    required this.onSubagents,
    required this.onList,
  });

  final void Function(List<ModelProviderInfo>) onProviders;
  final void Function(PlanInfo) onPlan;
  final void Function(List<QuotaInfo>) onQuotas;
  final void Function(List<UsageEntry>) onUsage;
  final void Function(List<SubagentInfo>) onSubagents;
  final void Function(String, List<PanelItem>) onList;
}

/// 按设备累积面板数据；工作台展示合并视图。
class PanelDataNotifier extends Notifier<Map<String, PanelSnapshot>> {
  /// 面板字段可能出现的键名 —— 命中其一才做 JSON 全量解析。
  static const _needles = [
    'provider',
    'model',
    'entitlement',
    'quota',
    'codingPlan',
    'codingplan',
    'usage',
    'subagent',
    'sub_agent',
    'skill',
    'mcp',
    'plugin',
    'command',
    'hook',
    'memory',
  ];

  @override
  Map<String, PanelSnapshot> build() => const {};

  void ingest(String deviceId, String body) => ingestRoot(deviceId, body, null);

  /// 已由调用方完成单次 decode 的入口：needle 与大小门仍按原始 [body]
  /// 判断，[root] 复用调用方解析结果，省掉第二次 jsonDecode（评审 A2）。
  void ingestRoot(String deviceId, String body, dynamic root) {
    if (body.isEmpty || body.length > 512 * 1024) return;
    final lower = body.toLowerCase();
    if (!_needles.any(lower.contains)) return;
    root ??= BridgeMessagePipeline.decode(body);
    if (root == null) return;
    final parsed = PanelDataExtractor.parseRoot(
      root,
      now: DateTime.now().millisecondsSinceEpoch,
    );
    if (parsed.isEmpty) return;
    final prev = state[deviceId] ?? PanelSnapshot.empty;
    state = {
      ...state,
      deviceId: PanelSnapshot(
        updatedAt: parsed.updatedAt,
        providers: parsed.providers.isNotEmpty
            ? parsed.providers
            : prev.providers,
        plan: parsed.plan ?? prev.plan,
        quotas: parsed.quotas.isNotEmpty ? parsed.quotas : prev.quotas,
        usage: parsed.usage.isNotEmpty ? parsed.usage : prev.usage,
        subagents: parsed.subagents.isNotEmpty
            ? parsed.subagents
            : prev.subagents,
        listPanels: {...prev.listPanels, ...parsed.listPanels},
      ),
    };
  }

  void forget(String deviceId) {
    if (!state.containsKey(deviceId)) return;
    state = Map.of(state)..remove(deviceId);
  }

  /// 合并所有设备的面板视图（供工作台展示）。
  PanelSnapshot get merged {
    var providers = const <ModelProviderInfo>[];
    PlanInfo? plan;
    var quotas = const <QuotaInfo>[];
    var usage = const <UsageEntry>[];
    var subagents = const <SubagentInfo>[];
    var lists = <String, List<PanelItem>>{};
    int? updatedAt;
    for (final snap in state.values) {
      if (snap.updatedAt != null &&
          (updatedAt == null || snap.updatedAt! > updatedAt)) {
        updatedAt = snap.updatedAt;
      }
      if (snap.providers.length > providers.length) {
        providers = snap.providers;
      }
      plan ??= snap.plan;
      if (quotas.isEmpty && snap.quotas.isNotEmpty) quotas = snap.quotas;
      if (usage.isEmpty && snap.usage.isNotEmpty) usage = snap.usage;
      if (snap.subagents.length > subagents.length) subagents = snap.subagents;
      lists = {...lists, ...snap.listPanels};
    }
    return PanelSnapshot(
      updatedAt: updatedAt,
      providers: providers,
      plan: plan,
      quotas: quotas,
      usage: usage,
      subagents: subagents,
      listPanels: lists,
    );
  }
}

final panelDataProvider =
    NotifierProvider<PanelDataNotifier, Map<String, PanelSnapshot>>(
      PanelDataNotifier.new,
    );

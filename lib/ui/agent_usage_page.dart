import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../services/usage_metric_policy.dart';
import '../native/bootstrap/native_bootstrap_coordinator.dart';
import '../state/relay_source.dart';
import '../theme.dart';

/// 原生 usage-stats 服务的安全摘要页。
///
/// 不把完整响应直接 JSON 展示，避免把账号标识、内部路径或计费元数据
/// 原样暴露到移动端；只提取有限的数值型用量字段。
class AgentUsagePage extends ConsumerStatefulWidget {
  const AgentUsagePage({
    super.key,
    required this.deviceId,
    required this.workspacePath,
  });

  final String deviceId;
  final String workspacePath;

  @override
  ConsumerState<AgentUsagePage> createState() => _AgentUsagePageState();
}

class _AgentUsagePageState extends ConsumerState<AgentUsagePage> {
  Future<_UsageRead>? _future;
  String _range = '7d';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    // Pending intent: if the page opened before the agent handshake finished,
    // run the load once the device becomes ready instead of leaving a stale
    // error that asks the user to retry by hand.
    ref.listenManual(
      nativeBootstrapProvider((deviceId: widget.deviceId, sessionId: null)),
      (prev, next) {
        if (!(prev?.draftCreateReady ?? false) && next.draftCreateReady) {
          _load();
        }
      },
    );
  }

  void _load() {
    final future = _readUsage();
    // An arrow closure would return the Future and trip setState's assert.
    if (mounted) {
      setState(() {
        _future = future;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.panelUsageTitle),
        actions: [
          IconButton(
            tooltip: l10n.conversationRefresh,
            onPressed: _future == null ? null : _load,
            icon: const Icon(Icons.refresh_rounded, size: 19),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: context.zt.hairline),
        ),
      ),
      body: FutureBuilder<_UsageRead>(
        future: _future,
        builder: (context, snapshot) {
          if (_future == null ||
              snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 1.6),
              ),
            );
          }
          final read = snapshot.data;
          if (snapshot.hasError || read == null || !read.ok) {
            return _UsageNotice(onRetry: _load, detail: read?.error);
          }
          final metrics = _metrics(read.value);
          if (metrics.isEmpty) return _UsageNotice(onRetry: _load, empty: true);
          return _UsageDashboard(
            range: _range,
            method: read.method!,
            metrics: metrics,
            onRangeChanged: (value) {
              if (value == _range) return;
              setState(() => _range = value);
              _load();
            },
          );
        },
      ),
    );
  }

  Future<_UsageRead> _readUsage() async {
    final source = ref.read(relaySourceProvider.notifier);
    String? lastError;
    // The desktop settings page uses usage-stats.getAppUsageSnapshot, which
    // delegates to zcode-agent.getAppUsageStats.  The range is required: the
    // host's method reads `args[0].range` and a zero-argument call crashes as
    // "undefined.range" before it can return a snapshot.
    final args = [
      {'range': _range},
    ];
    final calls = <(String, String)>[
      ('usage-stats', 'getAppUsageSnapshot'),
      ('zcode-agent', 'getAppUsageStats'),
      // Compatibility with a short-lived 3.10 service name.
      ('usage-stats', 'getSnapshot'),
    ];
    for (final (service, method) in calls) {
      final result = await source.callService(
        widget.deviceId,
        service,
        method,
        args,
      );
      if (result.ok && result.value != null) {
        return _UsageRead(value: result.value, method: '$service.$method');
      }
      lastError = result.safeLabel;
    }
    return _UsageRead(error: lastError ?? 'usage-stats 未返回数据');
  }

  static List<(String, String)> _metrics(Object? root) {
    final out = <(String, String)>[];
    final queue = <({Object? value, int depth})>[(value: root, depth: 0)];
    final seen = <String>{};
    var visited = 0;
    while (queue.isNotEmpty && visited < 160 && out.length < 32) {
      final current = queue.removeLast();
      visited++;
      final value = current.value;
      if (value is Map) {
        for (final entry in value.entries) {
          if (entry.key is! String) continue;
          final key = (entry.key as String).trim();
          final lower = key.toLowerCase();
          final scalar = entry.value;
          if (_isMetricKey(lower) && _isSafeScalar(scalar)) {
            final label = _labelOf(key);
            final rendered = _renderScalar(scalar);
            if (seen.add(label) && rendered != null) {
              out.add((label, rendered));
            }
          }
          if (current.depth < 6 && (scalar is Map || scalar is List)) {
            queue.add((value: scalar, depth: current.depth + 1));
          }
        }
      } else if (value is List && current.depth < 6) {
        for (final child in value) {
          if (child is Map || child is List) {
            queue.add((value: child, depth: current.depth + 1));
          }
        }
      }
    }
    return out;
  }

  static bool _isMetricKey(String key) => UsageMetricPolicy.isMetricKey(key);

  static bool _isSafeScalar(Object? value) =>
      UsageMetricPolicy.isSafeScalar(value);

  static String? _renderScalar(Object? value) => switch (value) {
    num n => n.toString(),
    bool b => b ? '已启用' : '未启用',
    String s when s.trim().isNotEmpty => s.trim(),
    _ => null,
  };

  static String _labelOf(String key) {
    final spaced = key
        .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
        .replaceAll('_', ' ')
        .replaceAll('-', ' ');
    return spaced[0].toUpperCase() + spaced.substring(1);
  }
}

class _UsageDashboard extends StatelessWidget {
  const _UsageDashboard({
    required this.range,
    required this.method,
    required this.metrics,
    required this.onRangeChanged,
  });

  final String range;
  final String method;
  final List<(String, String)> metrics;
  final ValueChanged<String> onRangeChanged;

  String _value(Iterable<String> needles) {
    for (final metric in metrics) {
      final label = metric.$1.toLowerCase();
      if (needles.any(label.contains)) return metric.$2;
    }
    return '—';
  }

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    final overview = [
      ('总 Token', _value(const ['token', 'usage'])),
      ('请求次数', _value(const ['request', 'call', 'completion'])),
      ('活跃天数', _value(const ['active', 'day'])),
      ('会话数', _value(const ['session', 'conversation', 'task'])),
    ];
    final modelMetrics = metrics
        .where(
          (metric) =>
              metric.$1.toLowerCase().contains('model') ||
              metric.$1.toLowerCase().contains('provider'),
        )
        .take(6)
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      children: [
        _RangeSelector(value: range, onChanged: onRangeChanged),
        const SizedBox(height: 12),
        _NativeUsageHeader(method: method),
        const SizedBox(height: 14),
        Text(
          '概览',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: zt.textLo,
          ),
        ),
        const SizedBox(height: 7),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: 1.75,
          children: [
            for (final metric in overview)
              _UsageMetricCard(label: metric.$1, value: metric.$2),
          ],
        ),
        const SizedBox(height: 18),
        _UsageSection(
          title: '活动趋势',
          trailing: Text(
            range == '7d'
                ? '近 7 天'
                : range == '30d'
                ? '近 30 天'
                : '全部',
            style: TextStyle(fontSize: 11, color: zt.textLo),
          ),
          child: const _UsageChartPlaceholder(),
        ),
        _UsageSection(title: '活跃分布', child: const _UsageHeatmapPlaceholder()),
        _UsageSection(
          title: '模型使用',
          child: modelMetrics.isEmpty
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
                  child: Text(
                    '原生服务未返回模型分项',
                    style: TextStyle(fontSize: 12, color: zt.textLo),
                  ),
                )
              : Column(
                  children: [
                    for (final (index, metric) in modelMetrics.indexed) ...[
                      if (index > 0) Divider(height: 1, color: zt.hairline),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 11,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                metric.$1,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: zt.textHi,
                                ),
                              ),
                            ),
                            Text(
                              metric.$2,
                              style: TextStyle(
                                fontSize: 12,
                                color: zt.accent,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
        ),
        Text(
          '数据来自原生 usage-stats 服务，不在移动端伪造统计值。',
          style: TextStyle(fontSize: 10.5, color: zt.textLo),
        ),
      ],
    );
  }
}

class _UsageSection extends StatelessWidget {
  const _UsageSection({
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 2, 7),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: zt.textLo,
                    ),
                  ),
                ),
                trailing ?? const SizedBox.shrink(),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: zt.surface,
              border: Border.all(color: zt.hairline),
              borderRadius: BorderRadius.circular(9),
            ),
            clipBehavior: Clip.antiAlias,
            child: child,
          ),
        ],
      ),
    );
  }
}

class _UsageMetricCard extends StatelessWidget {
  const _UsageMetricCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 10),
      decoration: BoxDecoration(
        color: zt.surface,
        border: Border.all(color: zt.hairline),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: zt.textLo)),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: zt.textHi,
            ),
          ),
        ],
      ),
    );
  }
}

class _UsageChartPlaceholder extends StatelessWidget {
  const _UsageChartPlaceholder();

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return SizedBox(
      height: 158,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(painter: _UsageGridPainter(color: zt.hairline)),
          ),
          Center(
            child: Text(
              '等待趋势序列',
              style: TextStyle(fontSize: 12, color: zt.textLo),
            ),
          ),
        ],
      ),
    );
  }
}

class _UsageGridPainter extends CustomPainter {
  const _UsageGridPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _UsageGridPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _UsageHeatmapPlaceholder extends StatelessWidget {
  const _UsageHeatmapPlaceholder();

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 13, 12, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var row = 0; row < 5; row++)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                children: [
                  for (var column = 0; column < 12; column++)
                    Expanded(
                      child: Container(
                        height: 12,
                        margin: const EdgeInsets.only(right: 5),
                        decoration: BoxDecoration(
                          color: zt.surfaceHi,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 3),
          Text(
            '连接后按日期展示活动强度',
            style: TextStyle(fontSize: 11, color: zt.textLo),
          ),
        ],
      ),
    );
  }
}

class _RangeSelector extends StatelessWidget {
  const _RangeSelector({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final option in const [
          ('7d', '近 7 天'),
          ('30d', '近 30 天'),
          ('all', '全部'),
        ]) ...[
          ChoiceChip(
            label: Text(option.$2),
            selected: value == option.$1,
            onSelected: (_) => onChanged(option.$1),
          ),
          const SizedBox(width: 8),
        ],
      ],
    ),
  );
}

class _NativeUsageHeader extends StatelessWidget {
  const _NativeUsageHeader({required this.method});

  final String method;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
    decoration: BoxDecoration(
      color: context.zt.live.withValues(alpha: 0.08),
      border: Border.all(color: context.zt.live.withValues(alpha: 0.22)),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      children: [
        Icon(Icons.insights_outlined, size: 18, color: context.zt.live),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            '原生已接入 · usage-stats.$method',
            style: TextStyle(fontSize: 12, color: context.zt.textHi),
          ),
        ),
      ],
    ),
  );
}

class _UsageNotice extends StatelessWidget {
  const _UsageNotice({required this.onRetry, this.empty = false, this.detail});

  final VoidCallback onRetry;
  final bool empty;
  final String? detail;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            empty ? '原生服务已响应，但没有可展示的用量字段' : '未能读取原生用量统计',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: context.zt.textLo),
          ),
          if (detail != null) ...[
            const SizedBox(height: 6),
            Text(
              detail!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: context.zt.textLo),
            ),
          ],
          const SizedBox(height: 14),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    ),
  );
}

class _UsageRead {
  const _UsageRead({this.value, this.method, this.error});

  final Object? value;
  final String? method;
  final String? error;

  bool get ok => value != null && error == null;
}

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/monitor_state_store.dart';

/// 设备任务摘要的 UI 侧镜像（v1.6.0 首页工作台）。
///
/// 摘要本体由监控引擎（头无隔离体）每轮快照写入 SharedPreferences；
/// 本 provider 在 UI 引擎里短周期（5s）镜像一份供设备卡 watch。
/// sid → {title, phase, pending, tool, updatedAt}。
class DeviceSummariesNotifier
    extends Notifier<Map<String, Map<String, Object?>>> {
  Timer? _timer;

  @override
  Map<String, Map<String, Object?>> build() {
    ref.onDispose(() => _timer?.cancel());
    unawaited(_load());
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(_load()));
    return const {};
  }

  Future<void> _load() async {
    final summaries = await MonitorStateStore.readSummaries();
    if (!ref.mounted) return;
    // 值比较省一次 setState：内容没变不重建。
    if (_same(state, summaries)) return;
    state = summaries;
  }

  static bool _same(
    Map<String, Map<String, Object?>> a,
    Map<String, Map<String, Object?>> b,
  ) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      final other = b[e.key];
      if (other == null) return false;
      final mine = e.value;
      if (mine.length != other.length) return false;
      for (final f in mine.entries) {
        if (other[f.key] != f.value) return false;
      }
    }
    return true;
  }
}

final deviceSummariesProvider =
    NotifierProvider<DeviceSummariesNotifier, Map<String, Map<String, Object?>>>(
      DeviceSummariesNotifier.new,
    );

/// 摘要 → 首页展示行（纯函数，可单测）：返回 (状态文案 key, 任务标题)。
/// 状态 key：pending / running / completed / error / null（无摘要）。
(String?, String?) taskLineOf(Map<String, Object?>? summary) {
  if (summary == null || summary.isEmpty) return (null, '');
  final phase = '${summary['phase']}';
  final title = '${summary['title'] ?? ''}'.trim();
  switch (phase) {
    case 'pending':
      return ('pending', title);
    case 'running':
      return ('running', title);
    case 'completed':
      return ('completed', title);
    case 'error':
      return ('error', title);
    default:
      return (null, '');
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/panel_state.dart';
import '../../theme.dart';

/// 用量统计面板：额度概览 + 明细条目 + 最近同步时间。
class UsagePanelPage extends ConsumerWidget {
  const UsagePanelPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final snapshots = ref.watch(panelDataProvider);
    var usage = const <UsageEntry>[];
    var quotas = const <QuotaInfo>[];
    int? updatedAt;
    for (final s in snapshots.values) {
      if (s.usage.length > usage.length) usage = s.usage;
      if (quotas.isEmpty && s.quotas.isNotEmpty) quotas = s.quotas;
      final t = s.updatedAt;
      if (t != null && (updatedAt == null || t > updatedAt)) updatedAt = t;
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.panelUsageTitle)),
      body: usage.isEmpty && quotas.isEmpty
          ? const _GuideEmpty()
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                if (quotas.isNotEmpty) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.panelUsageQuotaTitle,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: context.zt.textHi,
                            ),
                          ),
                          const SizedBox(height: 12),
                          for (final q in quotas.take(4)) ...[
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    q.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: context.zt.textLo,
                                    ),
                                  ),
                                ),
                                Text(
                                  '${q.percent.round()}%',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: _color(context.zt, q.percent),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 5),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: LinearProgressIndicator(
                                value: q.percent.clamp(0, 100) / 100,
                                minHeight: 5,
                                backgroundColor: context.zt.surfaceHi,
                                valueColor: AlwaysStoppedAnimation(
                                  _color(context.zt, q.percent),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (usage.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                    child: Text(
                      l10n.panelUsageDetail,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: context.zt.textLo,
                      ),
                    ),
                  ),
                  Card(
                    clipBehavior: Clip.antiAlias,
                    margin: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (final (i, e) in usage.indexed) ...[
                          if (i > 0)
                            const Divider(indent: 14, endIndent: 14, height: 1),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 11,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    e.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      color: context.zt.textHi,
                                    ),
                                  ),
                                ),
                                if (e.value != null)
                                  Text(
                                    e.value!,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: context.zt.accent,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                if (updatedAt != null) ...[
                  const SizedBox(height: 14),
                  Center(
                    child: Text(
                      l10n.panelUsageLastSync(_relative(updatedAt, l10n)),
                      style: TextStyle(fontSize: 11, color: context.zt.textLo),
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  static Color _color(ZTPalette zt, double pct) => pct > 50
      ? zt.live
      : pct > 20
      ? zt.warn
      : zt.danger;

  static String _relative(int at, AppLocalizations l10n) {
    final diff = DateTime.now().millisecondsSinceEpoch - at;
    if (diff < 60 * 1000) return l10n.sessionTimeNow;
    if (diff < 3600 * 1000) return l10n.sessionTimeMinutes(diff ~/ 60000);
    if (diff < 24 * 3600 * 1000) return l10n.sessionTimeHours(diff ~/ 3600000);
    return l10n.sessionTimeDays(diff ~/ 86400000);
  }
}

class _GuideEmpty extends StatelessWidget {
  const _GuideEmpty();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: context.zt.live.withValues(alpha: 0.10),
              ),
              child: Icon(Icons.query_stats, size: 30, color: context.zt.live),
            ),
            const SizedBox(height: 14),
            Text(
              l10n.panelUsageEmptyHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: context.zt.textLo,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

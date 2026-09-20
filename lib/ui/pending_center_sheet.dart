import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../models/device_label.dart';
import '../state/event_feed.dart';
import '../state/event_history.dart';
import '../state/session_index.dart';
import '../state/session_pool.dart';
import '../state/pending_session_jump.dart';
import '../theme.dart';

/// 待处理中心（升级路线图）：把"哪台机器哪个会话在等你"集中展示。
///
/// - 等待处理：来自 `EventFeed` 的 permPending（权威计数），点按切到设备并
///   尝试跳到最近的审批会话（复用 session_jump）；
/// - 最近事件：来自 `EventHistory` 的内存态有界历史（错过即永久错过的
///   补偿面），带相对时间。
class PendingCenterSheet extends ConsumerWidget {
  const PendingCenterSheet({super.key});

  static const _maxRecentPerDevice = 8;

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.zt.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      isScrollControlled: true,
      builder: (_) => const PendingCenterSheet(),
    );
  }

  static String typeLabel(AppLocalizations l10n, String type) =>
      switch (type) {
        'permission_request' => l10n.eventTypeApproval,
        'elicitation_request' => l10n.eventTypeInput,
        'completed' => l10n.eventTypeDone,
        'error' => l10n.eventTypeFailed,
        'resolved' => l10n.eventTypeResolved,
        _ => l10n.eventTypeOther,
      };

  static String timeLabel(AppLocalizations l10n, int atMs, int nowMs) {
    final r = RelativeTime.format(atMs, nowMs);
    return switch (r.kind) {
      'now' => l10n.timeJustNow,
      'minute' => l10n.timeMinutesAgo(r.n),
      'hour' => l10n.timeHoursAgo(r.n),
      _ => l10n.timeDaysAgo(r.n),
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context) ?? l10nZh;
    final devices = ref.watch(deviceListProvider);
    final feed = ref.watch(eventFeedProvider);
    final history = ref.watch(eventHistoryProvider);

    final waiting = [
      for (final d in devices)
        if (feed[d.id]?.permPending ?? false) d,
    ];
    final historyOrder = [
      for (final d in devices)
        if ((history[d.id] ?? const <HistoryEntry>[]).isNotEmpty) d,
    ]..sort((a, b) {
        final am = history[a.id]!.first.atMs;
        final bm = history[b.id]!.first.atMs;
        return bm.compareTo(am);
      });

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.72,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: context.zt.hairline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  l10n.pendingCenterTitle,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: context.zt.textHi,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (waiting.isEmpty && historyOrder.isEmpty)
              Padding(
                padding: const EdgeInsets.all(28),
                child: Text(
                  l10n.pendingCenterEmpty,
                  style: TextStyle(fontSize: 13, color: context.zt.textLo),
                ),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 12),
                  children: [
                    if (waiting.isNotEmpty) ...[
                      _sectionLabel(context, l10n.pendingCenterWaiting),
                      for (final d in waiting)
                        _WaitingRow(
                          label: d.displayName(l10n),
                          count: _pendingTotal(feed[d.id]),
                          onTap: () => _openDevice(
                            ref,
                            context,
                            devices,
                            d.id,
                            history[d.id],
                            feed[d.id],
                          ),
                        ),
                    ],
                    if (historyOrder.isNotEmpty) ...[
                      _sectionLabel(context, l10n.pendingCenterRecent),
                      for (final d in historyOrder) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
                          child: Text(
                            d.displayName(l10n),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: context.zt.textLo,
                            ),
                          ),
                        ),
                        for (final e in history[d.id]!.take(_maxRecentPerDevice))
                          _HistoryRow(
                            label: typeLabel(l10n, e.type),
                            summary: e.summary ?? e.sessionTitle,
                            time: timeLabel(
                              l10n,
                              e.atMs,
                              DateTime.now().millisecondsSinceEpoch,
                            ),
                          ),
                      ],
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static int _pendingTotal(DeviceFeed? feed) {
    final map = feed?.pendingByTask;
    if (map == null || map.isEmpty) return 0;
    return map.values.fold<int>(0, (a, b) => a + b);
  }

  void _openDevice(
    WidgetRef ref,
    BuildContext context,
    List<RemoteDevice> devices,
    String deviceId,
    List<HistoryEntry>? entries,
    DeviceFeed? feed,
  ) {
    final index = devices.indexWhere((d) => d.id == deviceId);
    if (index >= 0) {
      ref.read(activeTabProvider.notifier).set(index);
    }
    // 与 _openDevice（AppShell）同口径：打开设备即确认未读（复核 F1）。
    ref.read(eventFeedProvider.notifier).markRead(deviceId);
    // 跳转目标必须仍在等待（权威计数命中），否则只切设备（复核 F2）。
    final pendingKeys =
        feed?.pendingByTask.keys.toSet() ?? const <String>{};
    final target = latestPendingRequest(
      entries ?? const <HistoryEntry>[],
      pendingKeys,
    );
    if (target?.taskId != null) {
      ref
          .read(pendingSessionJumpProvider.notifier)
          .set(PendingSessionJump(deviceId: deviceId, sessionId: target!.taskId!));
    }
    Navigator.of(context).pop();
  }
}

Widget _sectionLabel(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
  child: Align(
    alignment: Alignment.centerLeft,
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4,
        color: context.zt.textLo,
      ),
    ),
  ),
);

class _WaitingRow extends StatelessWidget {
  const _WaitingRow({
    required this.label,
    required this.count,
    required this.onTap,
  });

  final String label;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context) ?? l10nZh;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: context.zt.danger,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: context.zt.textHi),
              ),
            ),
            Text(
              l10n.pendingCenterWaitingCount(count),
              style: TextStyle(fontSize: 12, color: context.zt.danger),
            ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right, size: 18, color: context.zt.textLo),
          ],
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.label,
    required this.summary,
    required this.time,
  });

  final String label;
  final String? summary;
  final String time;

  @override
  Widget build(BuildContext context) {
    final text = summary == null || summary!.isEmpty
        ? label
        : '$label · $summary';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: context.zt.textHi),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            time,
            style: TextStyle(fontSize: 11, color: context.zt.textLo),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../services/notification_history.dart';
import '../services/notifier.dart';
import '../theme.dart';

/// 通知历史（v1.3.0）：已送达系统通知的本地留底，错过弹窗也能回看。
///
/// 点击条目复用通知深链（'deviceId' 或 'deviceId|taskId'）直达对应会话；
/// 设备已删除时深链静默降级为跳不转（与通知点按一致）。
class NotificationHistoryPage extends ConsumerStatefulWidget {
  const NotificationHistoryPage({super.key});

  @override
  ConsumerState<NotificationHistoryPage> createState() =>
      _NotificationHistoryPageState();
}

class _NotificationHistoryPageState
    extends ConsumerState<NotificationHistoryPage> {
  List<NotificationHistoryEntry> _entries = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final entries = await NotificationHistory.load();
    if (!mounted) return;
    setState(() => _entries = entries);
  }

  void _open(NotificationHistoryEntry entry) {
    NotificationTap.route(entry.payload);
  }

  Future<void> _clear() async {
    final l10n = AppLocalizations.of(context)!;
    await NotificationHistory.clear();
    if (!mounted) return;
    setState(() => _entries = const []);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.notifHistoryCleared)));
  }

  static String _timeLabel(DateTime at) {
    final now = DateTime.now();
    final sameDay =
        at.year == now.year && at.month == now.month && at.day == now.day;
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    if (sameDay) return '$hh:$mm';
    final month = at.month.toString().padLeft(2, '0');
    final day = at.day.toString().padLeft(2, '0');
    return '$month-$day $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 14, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    visualDensity: VisualDensity.compact,
                    tooltip: l10n.commonBack,
                    icon: Icon(Icons.arrow_back, color: context.zt.textLo),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.notifHistoryTitle,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                            color: context.zt.textHi,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          l10n.notifHistorySubtitle,
                          style: TextStyle(
                            fontSize: 11,
                            color: context.zt.textLo,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_entries.isNotEmpty)
                    TextButton(
                      onPressed: _clear,
                      child: Text(l10n.notifHistoryClear),
                    ),
                ],
              ),
            ),
            Expanded(
              child: _entries.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 40),
                        child: Text(
                          l10n.notifHistoryEmpty,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.6,
                            color: context.zt.textLo,
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 40),
                      itemCount: _entries.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final entry = _entries[index];
                        return _HistoryCard(
                          entry: entry,
                          timeLabel: _timeLabel(entry.at),
                          onTap: () => _open(entry),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({
    required this.entry,
    required this.timeLabel,
    required this.onTap,
  });

  final NotificationHistoryEntry entry;
  final String timeLabel;
  final VoidCallback onTap;

  IconData get _icon => switch (entry.type) {
    'permission_request' || 'elicitation_request' =>
      Icons.notifications_active_outlined,
    'completed' => Icons.check_circle_outline,
    'error' => Icons.error_outline,
    _ => Icons.notifications_none_outlined,
  };

  Color _color(ZTPalette palette) => switch (entry.type) {
    'completed' => palette.live,
    'error' => palette.danger,
    'permission_request' || 'elicitation_request' => palette.warn,
    _ => palette.accent,
  };

  @override
  Widget build(BuildContext context) {
    final color = _color(context.zt);
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(_icon, size: 20, color: color),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: context.zt.textHi,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          timeLabel,
                          style: TextStyle(
                            fontSize: 11,
                            color: context.zt.textLo,
                          ),
                        ),
                      ],
                    ),
                    if (entry.body.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        entry.body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: context.zt.textLo,
                        ),
                      ),
                    ],
                    if (entry.deviceName.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        entry.deviceName,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.zt.textLo,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

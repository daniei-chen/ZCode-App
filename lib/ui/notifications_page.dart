import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../services/notifier.dart';
import '../state/event_feed.dart';
import '../state/root_tabs.dart';
import '../state/session_pool.dart';
import '../theme.dart';

/// 通知 Tab：跨设备事件时间线（与系统推送同一事件源）。
class NotificationsPage extends ConsumerStatefulWidget {
  const NotificationsPage({super.key});

  @override
  ConsumerState<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends ConsumerState<NotificationsPage> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 进入通知中心即视为已读（保留「等待批准」红点，仅清未读徽标）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final devices = ref.read(deviceListProvider);
      ref.read(eventFeedProvider.notifier).markAllRead([
        for (final d in devices) d.id,
      ]);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _openDevice(String deviceId, FeedEvent event) {
    final devices = ref.read(deviceListProvider);
    final index = devices.indexWhere((d) => d.id == deviceId);
    if (index < 0) return;
    ref.read(activeTabProvider.notifier).set(index);
    final taskId = event.taskId?.trim();
    if (taskId != null && taskId.isNotEmpty) {
      ref
          .read(pendingSessionJumpProvider.notifier)
          .set(PendingSessionJump(deviceId: deviceId, sessionId: taskId));
    }
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(deviceListProvider);
    final history = ref.watch(eventHistoryProvider);
    final l10n = AppLocalizations.of(context)!;
    final now = DateTime.now();

    final items = <(String, FeedEvent)>[
      for (final d in devices)
        for (final e in history[d.id] ?? const <FeedEvent>[]) (d.id, e),
    ]..sort((a, b) => b.$2.at.compareTo(a.$2.at));

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: items.isEmpty
            ? _EmptyState()
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
                    child: Text(
                      l10n.notifCenterTitle,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                        color: context.zt.textHi,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (final (deviceId, e) in items)
                    _EventCard(
                      event: e,
                      device: devices.firstWhere((d) => d.id == deviceId),
                      now: now,
                      onTap: () => _openDevice(deviceId, e),
                    ),
                ],
              ),
      ),
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({
    required this.event,
    required this.device,
    required this.now,
    required this.onTap,
  });

  final FeedEvent event;

  final RemoteDevice device;

  final DateTime now;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final typeLabel = switch (event.type) {
      'permission_request' ||
      'elicitation_request' => l10n.notifChannelApproval,
      'completed' => l10n.notifChannelDone,
      'error' => l10n.notifChannelFail,
      _ => event.type,
    };
    final session = event.sessionTitle?.trim() ?? '';
    final summary = event.summary?.trim() ?? '';
    final title = NotificationSpec.titleFor(device, session, l10n);
    final body = NotificationSpec.bodyFor(event.type, summary, l10n);
    final diff = now.millisecondsSinceEpoch - event.at;
    final relative = diff < 60 * 1000
        ? l10n.sessionTimeNow
        : diff < 3600 * 1000
        ? l10n.sessionTimeMinutes(diff ~/ (60 * 1000))
        : diff < 24 * 3600 * 1000
        ? l10n.sessionTimeHours(diff ~/ (3600 * 1000))
        : l10n.sessionTimeDays(diff ~/ (24 * 3600 * 1000));

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: Image.asset(
                      'assets/brand/mark.png',
                      width: 30,
                      height: 30,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: context.zt.textHi,
                      ),
                    ),
                  ),
                  Text(
                    relative,
                    style: TextStyle(fontSize: 11, color: context.zt.textLo),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '$typeLabel · $body',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: context.zt.textLo),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
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
                color: context.zt.accent.withValues(alpha: 0.10),
              ),
              child: Icon(
                Icons.notifications_none,
                size: 30,
                color: context.zt.accent,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              l10n.notifCenterEmpty,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: context.zt.textLo,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../models/device_label.dart';
import '../services/event_observer.dart';
import '../state/relay_source.dart';
import '../state/root_tabs.dart';
import '../state/session_index.dart';
import '../state/session_pool.dart';
import '../theme.dart';
import 'conversation_page.dart';
import 'session_panel.dart';

/// 任务 Tab：跨设备任务卡流（数据来自各设备会话的 sessionIndex）。
class TasksPage extends ConsumerStatefulWidget {
  const TasksPage({super.key});

  @override
  ConsumerState<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends ConsumerState<TasksPage> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// 任务卡直接进入原生会话页；网页版只作为明确点击后的兼容兜底。
  void _openSession(RemoteDevice device, SessionState session) {
    final workspacePath = session.workspacePath?.trim().isNotEmpty == true
        ? session.workspacePath!.trim()
        : (ref.read(relaySourceProvider)[device.id]?.workspaceKey ?? '');
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ConversationPage(
          deviceId: device.id,
          workspacePath: workspacePath,
          sessionId: session.sessionId,
          title: session.title,
          onOpenWebView: RelaySourceNotifier.supports(device)
              ? null
              : () {
                  Navigator.of(context).pop();
                  ref
                      .read(pendingSessionJumpProvider.notifier)
                      .set(
                        PendingSessionJump(
                          deviceId: device.id,
                          sessionId: session.sessionId,
                        ),
                      );
                  final index = ref.read(deviceListProvider).indexOf(device);
                  if (index >= 0) {
                    ref.read(activeTabProvider.notifier).set(index);
                  }
                },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(deviceListProvider);
    final index = ref.watch(sessionIndexProvider);
    final l10n = AppLocalizations.of(context)!;
    final now = DateTime.now();

    final entries = <(RemoteDevice, SessionState)>[
      for (final d in devices)
        for (final s in index[d.id]?.values ?? const <SessionState>[]) (d, s),
    ]..sort((a, b) => SessionRanking.compareSessions(a.$2, b.$2));
    final groups = <String, List<(RemoteDevice, SessionState)>>{};
    final groupOrder = <String>[];
    for (final entry in entries) {
      final key = entry.$2.pinned
          ? 'pinned'
          : SessionGrouping.workspaceKey(entry.$2);
      if (!groups.containsKey(key)) {
        groups[key] = <(RemoteDevice, SessionState)>[];
        groupOrder.add(key);
      }
      groups[key]!.add(entry);
    }

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: entries.isEmpty
            ? _EmptyState(hasDevices: devices.isNotEmpty)
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
                    child: Text(
                      l10n.tasksTitle,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                        color: context.zt.textHi,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const _RelaySourceStrip(),
                  for (final groupKey in groupOrder) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          groupKey == 'pinned'
                              ? l10n.sessionGroupPinned
                              : SessionGrouping.workspaceLabel(groupKey),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: context.zt.textLo,
                          ),
                        ),
                      ),
                    ),
                    for (final entry in groups[groupKey]!)
                      _TaskCard(
                        session: entry.$2,
                        device: entry.$1,
                        now: now,
                        onTap: () => _openSession(entry.$1, entry.$2),
                      ),
                  ],
                ],
              ),
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.session,
    required this.device,
    required this.now,
    required this.onTap,
  });

  final SessionState session;

  final RemoteDevice device;

  final DateTime now;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final s = session;
    final title = (s.title == null || s.title!.isEmpty)
        ? s.sessionId
        : s.title!;
    final pill = SessionPanelSheet.phaseL10n(l10n, context.zt, s.phase);
    final t = RelativeTime.format(s.lastActivityAt, now.millisecondsSinceEpoch);
    final relative = switch (t.kind) {
      'minute' => l10n.sessionTimeMinutes(t.n),
      'hour' => l10n.sessionTimeHours(t.n),
      'day' => l10n.sessionTimeDays(t.n),
      _ => l10n.sessionTimeNow,
    };

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
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: context.zt.textHi,
                      ),
                    ),
                  ),
                  if (s.permissionCount > 0) ...[
                    const SizedBox(width: 8),
                    _MiniPill(
                      label: '${s.permissionCount}',
                      background: context.zt.danger,
                      foreground: Colors.white,
                    ),
                  ],
                  if (s.userInputCount > 0) ...[
                    const SizedBox(width: 6),
                    _MiniPill(
                      label: '${s.userInputCount}',
                      background: context.zt.accent,
                      foreground: context.zt.onAccent,
                    ),
                  ],
                  if (pill != null) ...[
                    const SizedBox(width: 6),
                    _MiniPill(
                      label: pill.$1,
                      background: pill.$2,
                      foreground: pill.$3,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    Icons.desktop_windows_outlined,
                    size: 12,
                    color: context.zt.textLo,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      device.displayName(l10n),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: context.zt.textLo),
                    ),
                  ),
                  if (s.workspace != null) ...[
                    Text(
                      ' · ',
                      style: TextStyle(fontSize: 12, color: context.zt.textLo),
                    ),
                    Flexible(
                      child: Text(
                        s.workspace!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.zt.textLo,
                        ),
                      ),
                    ),
                  ],
                  Text(
                    ' · $relative',
                    style: TextStyle(fontSize: 12, color: context.zt.textLo),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniPill extends StatelessWidget {
  const _MiniPill({
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String label;

  final Color background;

  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: foreground,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasDevices});

  final bool hasDevices;

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
                Icons.assignment_outlined,
                size: 30,
                color: context.zt.accent,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              hasDevices ? l10n.tasksEmptyNoSessions : l10n.tasksEmptyNoDevices,
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

/// 原生 relay 通道状态条。
///
/// 存在的意义：让人一眼看出当前列表数据是否已经由**原生通道**接管；
/// 仅旧版或不支持 Relay 的设备才会保留 WebView 回退。
class _RelaySourceStrip extends ConsumerWidget {
  const _RelaySourceStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final sources = ref.watch(relaySourceProvider);
    if (sources.isEmpty) return const SizedBox.shrink();

    final live = sources.values.where((s) => s.isLive).length;
    final connecting = sources.values
        .where((s) => s.kind == RelaySourceKind.connecting)
        .length;
    final usable = sources.values
        .where(
          (s) =>
              s.kind != RelaySourceKind.unsupported &&
              s.kind != RelaySourceKind.idle,
        )
        .length;

    final Color hue;
    final String text;
    if (live > 0) {
      hue = context.zt.live;
      text = l10n.relayBadgeLive(live);
    } else if (connecting > 0) {
      hue = context.zt.textLo;
      text = l10n.relayBadgeConnecting;
    } else if (usable == 0) {
      hue = context.zt.textLo;
      text = l10n.relayBadgeNone;
    } else {
      hue = context.zt.danger;
      // reason 可能来自远端错误对象，不能直接渲染到 UI；详细原因只留在
      // 内部诊断状态中，避免 token、URL 或服务端原文意外出现在屏幕上。
      text = l10n.relayBadgeFailed;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 2),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: hue),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: hue),
            ),
          ),
        ],
      ),
    );
  }
}

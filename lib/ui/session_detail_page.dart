import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../models/device_label.dart';
import '../services/event_observer.dart';
import '../state/event_feed.dart';
import '../state/panel_state.dart';
import '../state/relay_source.dart';
import '../state/session_index.dart';
import '../theme.dart';
import 'conversation_page.dart';
import 'session_panel.dart';

/// Legacy compatibility page for older callers.
///
/// New navigation goes directly to [ConversationPage], which owns the native
/// conversation surface and only exposes WebView as an explicit fallback.
@Deprecated('Use ConversationPage for native conversations')
class SessionDetailPage extends ConsumerStatefulWidget {
  const SessionDetailPage({
    super.key,
    required this.device,
    required this.session,
    required this.onOpenFullSession,
  });

  final RemoteDevice device;

  final SessionState session;

  final VoidCallback onOpenFullSession;

  @override
  ConsumerState<SessionDetailPage> createState() => _SessionDetailPageState();
}

class _SessionDetailPageState extends ConsumerState<SessionDetailPage> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final session =
        ref.watch(
          sessionIndexProvider,
        )[widget.device.id]?[widget.session.sessionId] ??
        widget.session;
    final timeline = ref
        .watch(eventHistoryProvider)[widget.device.id]
        ?.where((e) => e.taskId == session.sessionId)
        .toList();
    final snapshot = ref.watch(panelDataProvider)[widget.device.id];
    final now = DateTime.now().millisecondsSinceEpoch;

    final title = (session.title == null || session.title!.isEmpty)
        ? session.sessionId
        : session.title!;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: Icon(Icons.arrow_back, color: context.zt.textLo),
                ),
                Expanded(
                  child: Text(
                    widget.device.displayName(l10n),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: context.zt.textLo,
                    ),
                  ),
                ),
                const SizedBox(width: 48),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: TextStyle(
                fontSize: 24,
                height: 1.25,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
                color: context.zt.textHi,
              ),
            ),
            if (session.workspace != null) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    Icons.folder_outlined,
                    size: 13,
                    color: context.zt.textLo,
                  ),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      session.workspace!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: context.zt.textLo),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            _StatusLine(session: session),
            const SizedBox(height: 14),
            _ModelCard(snapshot: snapshot),
            const SizedBox(height: 14),
            _TimelineCard(events: timeline ?? const <FeedEvent>[]),
            const SizedBox(height: 14),
            _InfoCard(session: session, nowMs: now),
            const SizedBox(height: 22),
            // 主入口走原生正文；通道不可用时自动降级到网页版。
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: context.zt.accent,
                foregroundColor: context.zt.onAccent,
                minimumSize: const Size.fromHeight(50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () => _openConversation(nativeFirst: true),
              icon: const Icon(Icons.subject_rounded, size: 18),
              label: Text(
                l10n.detailOpenConversation,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: context.zt.textLo,
                minimumSize: const Size.fromHeight(42),
              ),
              onPressed: widget.onOpenFullSession,
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: Text(
                l10n.detailOpenFull,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 打开会话正文。
  ///
  /// [nativeFirst] 为 true 时优先用原生通道；缺工作区路径或该设备不支持 relay
  /// 时直接落到网页版，不给用户一个必然失败的按钮。
  void _openConversation({bool nativeFirst = true}) {
    final session =
        ref.read(
          sessionIndexProvider,
        )[widget.device.id]?[widget.session.sessionId] ??
        widget.session;
    final wsPath = session.workspacePath;
    final supported = RelaySourceNotifier.supports(widget.device);

    if (nativeFirst && supported && wsPath != null && wsPath.isNotEmpty) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ConversationPage(
            deviceId: widget.device.id,
            workspacePath: wsPath,
            sessionId: session.sessionId,
            title: session.title,
            onOpenWebView: widget.onOpenFullSession,
          ),
        ),
      );
      return;
    }
    widget.onOpenFullSession();
  }
}

/// 状态行：进行中呼吸灯 / 等待批准橙闪 / 完成 / 失败。
class _StatusLine extends StatefulWidget {
  const _StatusLine({required this.session});

  final SessionState session;

  @override
  State<_StatusLine> createState() => _StatusLineState();
}

class _StatusLineState extends State<_StatusLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final s = widget.session;
    final pill = SessionPanelSheet.phaseL10n(l10n, context.zt, s.phase);
    final waiting = s.permissionCount > 0 || s.userInputCount > 0;

    final (Color hue, bool pulse, Widget label) = pill == null
        ? waiting
              ? (
                  context.zt.accent,
                  true,
                  _label(l10n.sessionPhaseWaiting, context.zt.textHi),
                )
              : (
                  context.zt.textLo,
                  false,
                  _label(l10n.sessionPhaseIdle, context.zt.textLo),
                )
        : waiting && s.phase == 'running'
        ? (
            context.zt.danger,
            true,
            _label(l10n.sessionPhaseWaiting, context.zt.danger),
          )
        : (
            pill.$2,
            pill.$1 == l10n.sessionPhaseRunning,
            _label(pill.$1, pill.$2),
          );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: context.zt.surface,
        border: Border.all(color: hue.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          FadeTransition(
            opacity: pulse
                ? Tween(begin: 0.25, end: 1.0).animate(_pulse)
                : const AlwaysStoppedAnimation(1),
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hue,
                boxShadow: pulse
                    ? [
                        BoxShadow(
                          color: hue.withValues(alpha: 0.45),
                          blurRadius: 10,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: label),
          if (s.permissionCount > 0)
            _countPill('${s.permissionCount}', context.zt.danger, Colors.white),
          if (s.userInputCount > 0) ...[
            const SizedBox(width: 6),
            _countPill(
              '${s.userInputCount}',
              context.zt.accent,
              context.zt.onAccent,
            ),
          ],
        ],
      ),
    );
  }

  Widget _label(String text, Color color) => Text(
    text,
    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color),
  );

  Widget _countPill(String n, Color bg, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(999),
      color: bg,
    ),
    child: Text(
      n,
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: fg),
    ),
  );
}

/// 当前模型（只读展示）—— 数据来自桥接流的模型面板快照。
class _ModelCard extends StatelessWidget {
  const _ModelCard({required this.snapshot});

  final PanelSnapshot? snapshot;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final providers = snapshot?.providers ?? const <ModelProviderInfo>[];
    final current = providers.firstWhere(
      (p) => p.isCurrent,
      orElse: () => providers.isEmpty
          ? const ModelProviderInfo(name: '')
          : providers.first,
    );
    final hasModel = providers.isNotEmpty && current.name.isNotEmpty;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.detailModel,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: context.zt.textLo,
              ),
            ),
            const SizedBox(height: 8),
            if (hasModel) ...[
              Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(9),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          context.zt.accent.withValues(alpha: 0.30),
                          context.zt.accent.withValues(alpha: 0.08),
                        ],
                      ),
                    ),
                    child: Icon(
                      Icons.auto_awesome,
                      size: 16,
                      color: context.zt.accent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      current.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: context.zt.textHi,
                      ),
                    ),
                  ),
                  if (current.models.isNotEmpty)
                    Text(
                      l10n.detailModelCount(current.models.length),
                      style: TextStyle(fontSize: 11, color: context.zt.textLo),
                    ),
                ],
              ),
              if (current.models.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final m in current.models.take(6))
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          color: context.zt.field,
                          border: Border.all(color: context.zt.hairline),
                        ),
                        child: Text(
                          m,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: context.zt.textLo,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ] else
              Text(
                l10n.detailModelEmpty,
                style: TextStyle(fontSize: 12.5, color: context.zt.textLo),
              ),
          ],
        ),
      ),
    );
  }
}

/// 本会话活动时间线（来自通知中心的事件历史，按 taskId 过滤）。
class _TimelineCard extends StatelessWidget {
  const _TimelineCard({required this.events});

  final List<FeedEvent> events;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final now = DateTime.now().millisecondsSinceEpoch;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.detailTimeline,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: context.zt.textLo,
              ),
            ),
            const SizedBox(height: 10),
            if (events.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  l10n.detailTimelineEmpty,
                  style: TextStyle(fontSize: 12.5, color: context.zt.textLo),
                ),
              )
            else
              for (var i = 0; i < events.length; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                _TimelineRow(
                  event: events[i],
                  isLast: i == events.length - 1,
                  nowMs: now,
                ),
              ],
          ],
        ),
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.event,
    required this.isLast,
    required this.nowMs,
  });

  final FeedEvent event;

  final bool isLast;

  final int nowMs;

  Color _hue(BuildContext context) => switch (event.type) {
    'permission_request' => context.zt.danger,
    'elicitation_request' => context.zt.accent,
    'completed' => context.zt.live,
    'error' => context.zt.danger,
    _ => context.zt.textLo,
  };

  IconData get _icon => switch (event.type) {
    'permission_request' => Icons.gpp_maybe_outlined,
    'elicitation_request' => Icons.keyboard_alt_outlined,
    'completed' => Icons.check_circle_outline,
    'error' => Icons.error_outline,
    _ => Icons.circle_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final label = switch (event.type) {
      'permission_request' => l10n.notifChannelApproval,
      'elicitation_request' => l10n.notifChannelApproval,
      'completed' => l10n.notifChannelDone,
      'error' => l10n.notifChannelFail,
      _ => event.type,
    };
    final diff = nowMs - event.at;
    final relative = diff < 60 * 1000
        ? l10n.sessionTimeNow
        : diff < 3600 * 1000
        ? l10n.sessionTimeMinutes(diff ~/ (60 * 1000))
        : diff < 24 * 3600 * 1000
        ? l10n.sessionTimeHours(diff ~/ (3600 * 1000))
        : l10n.sessionTimeDays(diff ~/ (24 * 3600 * 1000));

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _hue(context).withValues(alpha: 0.14),
                ),
                child: Icon(_icon, size: 14, color: _hue(context)),
              ),
              if (!isLast)
                Expanded(
                  child: Container(width: 1.5, color: context.zt.hairline),
                ),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: _hue(context),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        relative,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.zt.textLo,
                        ),
                      ),
                    ],
                  ),
                  if (event.summary != null && event.summary!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      event.summary!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        color: context.zt.textLo,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 会话信息卡：工作区 / 创建 / 最近活动。
class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.session, required this.nowMs});

  final SessionState session;

  final int nowMs;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    String rel(int? at) {
      final t = RelativeTime.format(at, nowMs);
      return switch (t.kind) {
        'minute' => l10n.sessionTimeMinutes(t.n),
        'hour' => l10n.sessionTimeHours(t.n),
        'day' => l10n.sessionTimeDays(t.n),
        _ => l10n.sessionTimeNow,
      };
    }

    final rows = <(IconData, String, String)>[
      if (session.workspace != null)
        (Icons.folder_outlined, l10n.detailInfoWorkspace, session.workspace!),
      if (session.createdAt != null)
        (
          Icons.schedule_outlined,
          l10n.detailInfoCreated,
          rel(session.createdAt),
        ),
      if (session.lastActivityAt != null)
        (
          Icons.bolt_outlined,
          l10n.detailInfoActivity,
          rel(session.lastActivityAt),
        ),
      if (session.description != null && session.description!.isNotEmpty)
        (
          Icons.description_outlined,
          l10n.detailInfoPending,
          session.description!,
        ),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const Divider(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(rows[i].$1, size: 15, color: context.zt.textLo),
                    const SizedBox(width: 10),
                    Text(
                      rows[i].$2,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: context.zt.textLo,
                      ),
                    ),
                    const Spacer(),
                    Flexible(
                      child: Text(
                        rows[i].$3,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: context.zt.textHi,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../services/app_log.dart';
import '../services/app_settings.dart';
import '../services/device_connectivity.dart';
import '../services/device_import.dart';
import '../services/link_builder.dart';
import '../services/structured_log.dart';
import '../state/back_stack.dart';
import '../state/session_pool.dart';
import '../state/session_status.dart';
import '../state/event_feed.dart';
import '../theme.dart';
import '../models/device_label.dart';
import 'section_label.dart';
import 'settings_page.dart';
import 'pending_center_sheet.dart';
import 'unread_badge.dart';

class ManagePage extends ConsumerWidget {
  const ManagePage({
    super.key,
    this.onOpenDevice,
    this.onSettingsReturned,
    this.onProbeCombinedLayout,
  });

  final ValueChanged<int>? onOpenDevice;

  /// 从设置页返回后调用（**仅当页面实际是"对话+列表同屏"布局**）：
  /// 平板语义是"设置返回 → 同屏页 → 再返回 → 设备页"；手机语义是
  /// "设置返回 → 设备列表页"。落地由 [_SettingsEntry] 在进入设置前探测
  /// 官方页的**真实布局**决定，不再靠屏幕尺寸猜（真机两次误判的修正）。
  final VoidCallback? onSettingsReturned;

  /// 探测官方页当前是否为"任务列表 + 输入区同屏"。null/失败时回退到
  /// 屏幕尺寸启发式。
  final Future<bool?> Function()? onProbeCombinedLayout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(deviceListProvider);
    final l10n = AppLocalizations.of(context)!;

    // 设备列表连通性探测（用户需求：可联通绿点 / 不可联通橙点）：
    // 每次启动器出现时对全部设备做一轮源站探测，结果驱动卡片状态点。
    return Stack(
      children: [
        const _ConnectivityProbeTrigger(),
        Scaffold(
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(2, 4, 2, 0),
                  child: Row(
                    children: [
                      Image.asset(
                        'assets/brand/mark.png',
                        width: 46,
                        height: 46,
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          'ZCode',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                            color: context.zt.textHi,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(2, 10, 2, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          l10n.manageTitle,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                            color: context.zt.textHi,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Flexible(child: _TimeGreeting()),
                      const SizedBox(width: 6),
                      IconButton(
                        tooltip: l10n.pendingCenterTitle,
                        onPressed: () => PendingCenterSheet.show(context),
                        icon: Stack(
                          alignment: Alignment.center,
                          children: [
                            Icon(
                              Icons.notifications_outlined,
                              size: 22,
                              color: context.zt.textLo,
                            ),
                            if (ref
                                .watch(eventFeedProvider)
                                .values
                                .any((f) => f.permPending))
                              Positioned(
                                right: 1,
                                top: 1,
                                child: Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: context.zt.danger,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                if (devices.isEmpty)
                  _EmptyHint(
                    storageUnavailable: ref.watch(
                      deviceStoreUnavailableProvider,
                    ),
                    onRetry: () =>
                        ref.read(deviceListProvider.notifier).reload(),
                    onScan: () => _openScanner(context, ref),
                    onPaste: () => _showPasteDialog(context, ref),
                  )
                else ...[
                  SectionLabel(l10n.devicesCount(devices.length)),
                  ReorderableListView(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    buildDefaultDragHandles: false,
                    onReorderItem: (oldIndex, newIndex) {
                      // ReorderCallback 是 void 型：Future 被框架丢弃，异常
                      // 必须在这里兜住（iter10 F-1），否则排序失败静默回弹。
                      unawaited(
                        ref
                            .read(deviceListProvider.notifier)
                            .reorder(oldIndex, newIndex)
                            .catchError((Object e) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    AppLocalizations.of(context)!.operationFailed,
                                  ),
                                ),
                              );
                            }),
                      );
                    },
                    children: [
                      for (var i = 0; i < devices.length; i++)
                        _DeviceCard(
                          key: ValueKey(devices[i].id),
                          device: devices[i],
                          index: i,
                          onOpenDevice: onOpenDevice,
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  _ConnectAnotherCard(
                    onScan: () => _openScanner(context, ref),
                    onPaste: () => _showPasteDialog(context, ref),
                  ),
                ],
                const SizedBox(height: 14),
                SectionLabel(l10n.manageGroupApp),
                const ThemeSettingTile(),
                const UpdateSettingTile(),
                const SizedBox(height: 4),
                _SettingsEntry(
                  onReturned: onSettingsReturned,
                  onProbe: onProbeCombinedLayout,
                ),
                const VersionFooter(),
              ],
            ),
          ),
        ),
      ),
      ),
      ],
    );
  }

  Future<void> _openScanner(BuildContext context, WidgetRef ref) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const ScannerPage(),
      ),
    );
  }

  Future<void> _showPasteDialog(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _PasteDialog(l10n: l10n),
    );
    if (text == null || !context.mounted) return;
    await _importFromText(context, ref, text);
  }

  Future<void> _importFromText(
    BuildContext context,
    WidgetRef ref,
    String text,
  ) async {
    final device = LinkBuilder.parse(text);
    if (device == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.importFailed)),
        );
      }
      return;
    }
    final devices = ref.read(deviceListProvider);
    final dup = findDuplicateDevice(devices, device);
    if (dup != null) {
      if (context.mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.importDuplicate(dup.displayName(l10n)))),
        );
        final index = ref.read(deviceListProvider).indexOf(dup);
        if (index >= 0) ref.read(activeTabProvider.notifier).set(index);
      }
      return;
    }
    // ≥5 台时提醒一次（iter7 R-7：原 == 5 只在第 6 台导入前触发一次，
    // 之后再导第 7/8 台永远不提示——意图是"达到 5 台起提醒"）。
    if (devices.length >= 5 && context.mounted) {
      final l10n = AppLocalizations.of(context)!;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          // 200% 字体下正文会变高：允许滚动，确认按钮始终可达（PR22/F25）。
          scrollable: true,
          title: Text(l10n.manyDevicesTitle),
          content: Text(l10n.manyDevicesBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l10n.commonGotIt),
            ),
          ],
        ),
      );
    }
    try {
      await ref.read(deviceListProvider.notifier).add(device);
    } catch (_) {
      // 写入失败必须有用户可见反馈（iter7 R-1）：不能对话框关了、设备没出现、
      // 也不提示。存储不可用时底层抛 DeviceStoreUnavailableException。
      if (!context.mounted) return;
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.operationFailed)),
      );
      return;
    }
    ref.read(activeTabProvider.notifier).set(devices.length);
  }
}

class _TimeGreeting extends StatefulWidget {
  const _TimeGreeting();

  @override
  State<_TimeGreeting> createState() => _TimeGreetingState();
}

class _TimeGreetingState extends State<_TimeGreeting> {
  late DateTime _now;
  Timer? _timer;

  static const _changeHours = [5, 9, 12, 14, 18, 23];

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _scheduleNextChange();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _scheduleNextChange() {
    _timer?.cancel();
    final now = DateTime.now();
    final next = _nextChange(now);
    _timer = Timer(next.difference(now), () {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
      _scheduleNextChange();
    });
  }

  static DateTime _nextChange(DateTime now) {
    for (final hour in _changeHours) {
      final candidate = DateTime(now.year, now.month, now.day, hour);
      if (candidate.isAfter(now)) return candidate;
    }
    return DateTime(now.year, now.month, now.day + 1, 5);
  }

  String _text(AppLocalizations l10n) {
    final hour = _now.hour;
    if (hour >= 5 && hour < 9) return l10n.manageGreetingMorningEarly;
    if (hour >= 9 && hour < 12) return l10n.manageGreetingMorning;
    if (hour >= 12 && hour < 14) return l10n.manageGreetingNoon;
    if (hour >= 14 && hour < 18) return l10n.manageGreetingAfternoon;
    if (hour >= 18 && hour < 23) return l10n.manageGreetingEvening;
    return l10n.manageGreetingLateNight;
  }

  @override
  Widget build(BuildContext context) {
    final greeting = _text(AppLocalizations.of(context)!);
    return Align(
      alignment: Alignment.centerRight,
      // 单行硬约束：放不下时整行等比缩小（FittedBox），既不折第二行，
      // 也不用省略号截断文案。
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          greeting,
          maxLines: 1,
          textAlign: TextAlign.right,
          style: TextStyle(
            fontSize: 12,
            height: 1.25,
            fontWeight: FontWeight.w500,
            color: context.zt.textLo,
          ),
        ),
      ),
    );
  }
}

class _PasteDialog extends StatefulWidget {
  const _PasteDialog({required this.l10n, this.title, this.actionLabel});

  final AppLocalizations l10n;

  final String? title;
  final String? actionLabel;

  @override
  State<_PasteDialog> createState() => _PasteDialogState();
}

class _PasteDialogState extends State<_PasteDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title ?? widget.l10n.pasteDialogTitle),
      content: TextField(
        controller: _controller,
        maxLines: 3,
        autofocus: true,
        style: const TextStyle(fontSize: 13),
        decoration: const InputDecoration(
          hintText: 'https://zcode.z.ai/remote/v4?sid=...&hash=...',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: Text(widget.actionLabel ?? widget.l10n.importButton),
        ),
      ],
    );
  }
}

Future<void> _applyReplaceLink(
  BuildContext context,
  WidgetRef ref,
  RemoteDevice target,
  RemoteDevice parsed,
) async {
  final l10n = AppLocalizations.of(context)!;
  final dup = findDuplicateDevice(
    ref.read(deviceListProvider),
    parsed,
    exceptId: target.id,
  );
  if (dup != null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.replaceDuplicate(dup.displayName(l10n)))),
    );
    return;
  }
  try {
    await ref.read(deviceListProvider.notifier).replaceLink(target.id, parsed);
  } catch (_) {
    // 写失败反馈（iter7 R-1）。
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.operationFailed)));
    return;
  }
  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(l10n.replaceDone)));
  final index = ref
      .read(deviceListProvider)
      .indexWhere((d) => d.id == target.id);
  if (index >= 0) ref.read(activeTabProvider.notifier).set(index);
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.l10n, required this.initialName});

  final AppLocalizations l10n;
  final String initialName;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _controller = TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      icon: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: context.zt.accent.withValues(alpha: 0.10),
        ),
        child: Icon(Icons.edit_outlined, color: context.zt.accent, size: 22),
      ),
      title: Text(widget.l10n.renameDialogTitle),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 40,
        decoration: InputDecoration(
          hintText: widget.initialName,
          counterText: '',
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: Text(widget.l10n.commonSave),
        ),
      ],
    );
  }
}

class _ImportActions extends StatelessWidget {
  const _ImportActions({required this.onScan, required this.onPaste});

  final VoidCallback onScan;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(13),
    );
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: onScan,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              shape: shape,
            ),
            icon: const Icon(Icons.qr_code_scanner, size: 19),
            label: Text(l10n.importScanLabel),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onPaste,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              shape: shape,
              side: BorderSide(color: context.zt.hairline),
            ),
            icon: const Icon(Icons.link_outlined, size: 19),
            label: Text(l10n.importPasteTooltip),
          ),
        ),
      ],
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({
    required this.storageUnavailable,
    required this.onRetry,
    required this.onScan,
    required this.onPaste,
  });

  final bool storageUnavailable;
  final VoidCallback onRetry;
  final VoidCallback onScan;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (storageUnavailable) {
      // 读不到安全存储 ≠ 没有设备：把故障伪装成"等待接入设备"会让用户
      // 以为数据被删了。这里给出可重试的明确故障状态。
      return _StorageUnavailableCard(onRetry: onRetry);
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
      decoration: BoxDecoration(
        color: context.zt.accent.withValues(alpha: 0.055),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: context.zt.accent.withValues(alpha: 0.20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(17),
                  color: context.zt.surface,
                  border: Border.all(color: context.zt.hairline),
                ),
                child: Icon(
                  Icons.qr_code_2_rounded,
                  size: 30,
                  color: context.zt.accent,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l10n.emptyTitle,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: context.zt.textHi,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _ImportActions(onScan: onScan, onPaste: onPaste),
        ],
      ),
    );
  }
}

class _StorageUnavailableCard extends StatelessWidget {
  const _StorageUnavailableCard({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
      decoration: BoxDecoration(
        color: context.zt.danger.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: context.zt.danger.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(17),
                  color: context.zt.surface,
                  border: Border.all(color: context.zt.hairline),
                ),
                child: Icon(
                  Icons.warning_amber_rounded,
                  size: 30,
                  color: context.zt.danger,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l10n.deviceStoreUnavailableTitle,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: context.zt.textHi,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            l10n.deviceStoreUnavailableBody,
            style: TextStyle(fontSize: 13, color: context.zt.textLo),
          ),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: onRetry, child: Text(l10n.retry)),
        ],
      ),
    );
  }
}

class _ConnectAnotherCard extends StatelessWidget {
  const _ConnectAnotherCard({required this.onScan, required this.onPaste});

  final VoidCallback onScan;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: context.zt.surfaceHi.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: context.zt.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.add_circle_outline, color: context.zt.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.connectAnotherTitle,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: context.zt.textHi,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _ImportActions(onScan: onScan, onPaste: onPaste),
        ],
      ),
    );
  }
}

class _DeviceCard extends ConsumerWidget {
  const _DeviceCard({
    super.key,
    required this.device,
    required this.index,
    this.onOpenDevice,
  });

  final RemoteDevice device;

  final int index;

  final ValueChanged<int>? onOpenDevice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(sessionStatusProvider)[device.id];
    final probe = ref.watch(deviceConnectivityProvider)[device.id];
    final linkState = DeviceConnectivityPolicy.state(
      sessionStatus: status,
      probe: probe,
    );
    final feed = ref.watch(eventFeedProvider)[device.id];
    final l10n = AppLocalizations.of(context)!;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          final index = ref.read(deviceListProvider).indexOf(device);
          if (index < 0) return;
          final open = onOpenDevice;
          if (open != null) {
            open(index);
          } else {
            ref.read(activeTabProvider.notifier).set(index);
          }
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: context.zt.surfaceHi,
                ),
                child: Icon(
                  Icons.desktop_windows,
                  size: 20,
                  color: context.zt.accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.displayName(l10n),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: context.zt.textHi,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      l10n.deviceAddedOn(
                        '${device.createdAt.month}/${device.createdAt.day}',
                      ),
                      style: TextStyle(fontSize: 12, color: context.zt.textLo),
                    ),
                  ],
                ),
              ),
              UnreadBadge(feed: feed),
              Tooltip(
                message: switch (linkState) {
                  // relay 实流与"仅探测可达"分开表述（iter10 F-5）：探测只
                  // 证明源站网络可达，不证明会话活着。
                  DeviceLinkState.reachable when status == SessionStatus.live =>
                    l10n.statusLive,
                  DeviceLinkState.reachable => l10n.statusReachable,
                  DeviceLinkState.unreachable => l10n.statusUnreachable,
                  DeviceLinkState.unknown => l10n.statusConnecting,
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 10),
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: switch (linkState) {
                      DeviceLinkState.reachable => context.zt.live,
                      DeviceLinkState.unreachable => context.zt.warn,
                      DeviceLinkState.unknown => context.zt.statusColor(status),
                    },
                  ),
                ),
              ),
              PopupMenuButton<String>(
                padding: EdgeInsets.zero,
                iconSize: 20,
                offset: const Offset(0, 8),
                elevation: 8,
                color: context.zt.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: context.zt.hairline),
                ),
                constraints: const BoxConstraints(minWidth: 184),
                icon: Icon(Icons.more_horiz, color: context.zt.textLo),
                onSelected: (action) async {
                  switch (action) {
                    case 'open':
                      final index = ref
                          .read(deviceListProvider)
                          .indexOf(device);
                      if (index >= 0) {
                        final open = onOpenDevice;
                        if (open != null) {
                          open(index);
                        } else {
                          ref.read(activeTabProvider.notifier).set(index);
                        }
                      }
                    case 'rename':
                      await _rename(context, ref);
                    case 'replace':
                      await _replace(context, ref);
                    case 'delete':
                      await _confirmDelete(context, ref);
                  }
                },
                itemBuilder: (_) => [
                  _deviceMenuItem(
                    context,
                    value: 'open',
                    icon: Icons.open_in_new_rounded,
                    label: l10n.menuOpenSession,
                  ),
                  _deviceMenuItem(
                    context,
                    value: 'rename',
                    icon: Icons.edit_outlined,
                    label: l10n.menuRename,
                  ),
                  _deviceMenuItem(
                    context,
                    value: 'replace',
                    icon: Icons.link_rounded,
                    label: l10n.menuReplace,
                  ),
                  _deviceMenuItem(
                    context,
                    value: 'delete',
                    icon: Icons.delete_outline_rounded,
                    label: l10n.menuDelete,
                    color: context.zt.danger,
                  ),
                ],
              ),
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(2, 12, 10, 12),
                  child: Icon(
                    Icons.drag_indicator,
                    size: 20,
                    color: context.zt.textLo,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  PopupMenuItem<String> _deviceMenuItem(
    BuildContext context, {
    required String value,
    required IconData icon,
    required String label,
    Color? color,
  }) {
    final foreground = color ?? context.zt.textHi;
    return PopupMenuItem<String>(
      value: value,
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Icon(icon, size: 19, color: color ?? context.zt.textLo),
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) =>
          _RenameDialog(l10n: l10n, initialName: device.label),
    );
    final ok = name != null && name.trim().isNotEmpty;
    if (ok && context.mounted) {
      try {
        await ref.read(deviceListProvider.notifier).rename(device.id, name);
      } catch (_) {
        // 写失败反馈（iter7 R-1）。
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.operationFailed)),
        );
      }
    }
  }

  Future<void> _replace(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: context.zt.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.replaceSheetTitle,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: context.zt.textHi,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.replaceSheetBody,
                    style: TextStyle(fontSize: 13, color: context.zt.textLo),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.qr_code_scanner, color: context.zt.accent),
              title: Text(l10n.replaceScan),
              onTap: () => Navigator.pop(sheetContext, 'scan'),
            ),
            ListTile(
              leading: Icon(Icons.content_paste, color: context.zt.accent),
              title: Text(l10n.replacePaste),
              onTap: () => Navigator.pop(sheetContext, 'paste'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'scan':
        await Navigator.of(context).push(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => ScannerPage(replaceOf: device),
          ),
        );
      case 'paste':
        final text = await showDialog<String>(
          context: context,
          builder: (dialogContext) => _PasteDialog(
            l10n: l10n,
            title: l10n.replacePasteDialogTitle,
            actionLabel: l10n.commonSave,
          ),
        );
        if (text == null || !context.mounted) return;
        final parsed = LinkBuilder.parse(text);
        if (parsed == null) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(AppLocalizations.of(context)!.importFailed),
              ),
            );
          }
          return;
        }
        await _applyReplaceLink(context, ref, device, parsed);
    }
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        // 设备名可能很长：200% 字体下允许滚动（PR22/F25）。
        scrollable: true,
        title: Text(l10n.deleteDeviceTitle(device.displayName(l10n))),
        content: Text(l10n.deleteDeviceBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.zt.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.menuDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!context.mounted) return;
    try {
      await ref.read(deviceListProvider.notifier).remove(device.id);
    } catch (_) {
      // 写失败反馈（iter7 R-1）：删除失败时设备必须还在列表里，不能假成功。
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.operationFailed)),
      );
    }
  }
}

class _SettingsEntry extends StatelessWidget {
  const _SettingsEntry({this.onReturned, this.onProbe});

  /// 设置页返回后的回调（仅当官方页是"对话+列表同屏"布局时触发）。
  final VoidCallback? onReturned;

  /// 进入设置前探测官方页真实布局；null/失败回退屏幕尺寸启发式。
  final Future<bool?> Function()? onProbe;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: context.zt.accent.withValues(alpha: 0.10),
          ),
          child: Icon(
            Icons.settings_outlined,
            size: 20,
            color: context.zt.accent,
          ),
        ),
        title: Text(
          AppLocalizations.of(context)!.settingsEntryTitle,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        trailing: Icon(Icons.chevron_right, color: context.zt.textLo),
        onTap: () async {
          // 跨 async gap 前先取 Navigator 与布局判定。
          final navigator = Navigator.of(context);
          final sizeTablet = isTabletLayout(MediaQuery.of(context).size);
          bool? combined;
          final probe = onProbe;
          if (probe != null) {
            try {
              combined = await probe();
            } catch (_) {}
          }
          final revealOnReturn = combined ?? sizeTablet;
          await navigator.push(
            MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
          );
          if (revealOnReturn && context.mounted) {
            onReturned?.call();
          }
        },
      ),
    );
  }
}

class ScannerPage extends ConsumerStatefulWidget {
  const ScannerPage({super.key, this.replaceOf});

  final RemoteDevice? replaceOf;

  @override
  ConsumerState<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends ConsumerState<ScannerPage>
    with WidgetsBindingObserver {
  String? _lastCode;
  DateTime _lastAccept = DateTime.fromMillisecondsSinceEpoch(0);
  bool _navigating = false;

  MobileScannerController? _controller;

  bool _permDenied = false;

  /// 相机故障（非权限）：旧实现直接返回 `SizedBox.shrink()`，用户只看到一片
  /// 黑屏、没有任何解释也无法恢复（F24）。这里记录错误码并给出可恢复的出口。
  MobileScannerErrorCode? _cameraError;

  int _scannerGeneration = 0;

  @visibleForTesting
  void debugMarkPermDenied() => _permDenied = true;

  @visibleForTesting
  void debugMarkCameraError(MobileScannerErrorCode code) => _cameraError = code;

  @visibleForTesting
  int get debugScannerGeneration => _scannerGeneration;

  Future<void> _guarded(Future<void> Function() f) async {
    try {
      await f();
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = MobileScannerController();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        if (_permDenied || _cameraError != null) {
          // 权限或相机故障恢复：重建控制器（同一套 generation 机制）。
          _permDenied = false;
          _retryCamera();
        } else {
          _guarded(controller.start);
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _guarded(controller.stop);
    }
  }

  /// 重建相机控制器（权限恢复、相机故障重试、回前台恢复共用）。
  void _retryCamera() {
    final previous = _controller;
    setState(() {
      _cameraError = null;
      _scannerGeneration++;
      _controller = MobileScannerController();
    });
    _guarded(() async {
      await previous?.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.black,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
        ),
        titleTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
        title: Text(AppLocalizations.of(context)!.scannerTitle),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            key: ValueKey(_scannerGeneration),
            controller: _controller,
            onDetect: (capture) => _onDetect(capture),
            errorBuilder: (context, error) {
              if (error.errorCode == MobileScannerErrorCode.permissionDenied) {
                _permDenied = true;
                return _PermDeniedView();
              }
              // 非权限错误（相机被占用/不支持/初始化失败）给出可恢复界面：
              // 重试会重建控制器，与权限恢复路径同一套 generation 机制。
              if (_cameraError != error.errorCode) {
                // 每个错误码只记一次：持续故障 + 页面反复重建会把
                // cameraFailed 刷进环形缓冲（iter8 U-7，build 期副作用收敛）。
                _cameraError = error.errorCode;
                AppLog.event(
                  LogEvent.cameraFailed,
                  level: LogLevel.warn,
                  fields: {
                    LogField.reason: error.errorCode.name,
                    LogField.ok: false,
                  },
                );
              }
              return _ScannerErrorView(
                errorCode: error.errorCode,
                onRetry: _retryCamera,
              );
            },
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _ScannerOverlayPainter(context.zt.accent),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 56,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.54),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Text(
                  widget.replaceOf == null
                      ? AppLocalizations.of(context)!.scannerHint
                      : AppLocalizations.of(context)!.scannerReplaceHint,
                  style: const TextStyle(fontSize: 13, color: Colors.white70),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_navigating) return;
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;
    final code = barcodes.first.rawValue;
    if (code == null || code.isEmpty) return;
    final now = DateTime.now();
    if (code == _lastCode && now.difference(_lastAccept).inSeconds < 2) return;
    _lastCode = code;
    _lastAccept = now;

    final device = LinkBuilder.parse(code);
    if (device == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.invalidQr)),
        );
      }
      return;
    }

    final replaceOf = widget.replaceOf;
    if (replaceOf != null) {
      _navigating = true;
      final l10n = AppLocalizations.of(context)!;
      final dup = findDuplicateDevice(
        ref.read(deviceListProvider),
        device,
        exceptId: replaceOf.id,
      );
      if (dup != null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.replaceDuplicate(dup.displayName(l10n)))),
        );
        Navigator.of(context).pop();
        return;
      }
      try {
        await ref
            .read(deviceListProvider.notifier)
            .replaceLink(replaceOf.id, device);
      } catch (_) {
        // 同扫码新增：失败复位 _navigating（iter7 R-1）。
        _navigating = false;
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.operationFailed)),
        );
        return;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.replaceDone)));
      Navigator.of(context).pop();
      final index = ref
          .read(deviceListProvider)
          .indexWhere((d) => d.id == replaceOf.id);
      if (index >= 0) ref.read(activeTabProvider.notifier).set(index);
      return;
    }

    final dup = findDuplicateDevice(ref.read(deviceListProvider), device);
    if (dup != null) {
      _navigating = true;
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.importDuplicate(dup.displayName(l10n)))),
      );
      Navigator.of(context).pop();
      final index = ref.read(deviceListProvider).indexOf(dup);
      if (index >= 0) ref.read(activeTabProvider.notifier).set(index);
      return;
    }

    _navigating = true;
    try {
      await ref.read(deviceListProvider.notifier).add(device);
    } catch (_) {
      // 写失败必须复位 _navigating 并给出反馈（iter7 R-1）：否则扫码页此后
      // 对所有二维码直接 return，相机取景但"死锁"直到手动退出。
      _navigating = false;
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.operationFailed)),
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    ref
        .read(activeTabProvider.notifier)
        .set(ref.read(deviceListProvider).length - 1);
  }
}

class _PermDeniedView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.no_photography_outlined,
              size: 44,
              color: Colors.white54,
            ),
            const SizedBox(height: 18),
            Text(
              l10n.scannerPermTitle,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.scannerPermBody,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                height: 1.5,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: AppSettings.open,
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: Text(l10n.scannerPermOpenSettings),
            ),
          ],
        ),
      ),
    );
  }
}

/// 相机故障（非权限）的可恢复界面（F24）。
///
/// 旧实现是 `SizedBox.shrink()`：黑屏 + 没有任何文字，用户只能反复进出页面。
/// 这里把错误码翻译成人能读的原因，并给出"重试"与"改用粘贴导入"两条出口。
class _ScannerErrorView extends StatelessWidget {
  const _ScannerErrorView({required this.errorCode, required this.onRetry});

  final MobileScannerErrorCode errorCode;
  final VoidCallback onRetry;

  /// 错误码 → 可读原因（只区分用户能应对的几类，其余归入通用）。
  static String reasonLabel(AppLocalizations l10n, MobileScannerErrorCode code) =>
      switch (code) {
        MobileScannerErrorCode.unsupported => l10n.scannerErrorUnsupported,
        MobileScannerErrorCode.controllerAlreadyInitialized ||
        MobileScannerErrorCode.controllerUninitialized ||
        MobileScannerErrorCode.controllerDisposed ||
        MobileScannerErrorCode.controllerInitializing =>
          l10n.scannerErrorBusy,
        _ => l10n.scannerErrorGeneric,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.videocam_off_outlined,
              size: 44,
              color: Colors.white54,
            ),
            const SizedBox(height: 18),
            Text(
              l10n.scannerErrorTitle,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.scannerErrorBody(reasonLabel(l10n, errorCode)),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                height: 1.5,
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(l10n.scannerErrorRetry),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: Text(
                l10n.scannerErrorUsePaste,
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScannerOverlayPainter extends CustomPainter {
  _ScannerOverlayPainter(this.bracketColor);

  /// 取景框颜色。CustomPainter 拿不到 context，由调用方传入。
  final Color bracketColor;

  @override
  void paint(Canvas canvas, Size size) {
    const windowSize = 260.0;
    const radius = 20.0;
    const arm = 28.0;

    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: windowSize,
      height: windowSize,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(radius));

    final mask = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(rrect);
    canvas.drawPath(
      mask,
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );

    final bracket = Paint()
      ..color = bracketColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;

    final l = rect.left, t = rect.top, r = rect.right, b = rect.bottom;
    final path = Path()
      ..moveTo(l, t + arm)
      ..lineTo(l, t)
      ..lineTo(l + arm, t)
      ..moveTo(r - arm, t)
      ..lineTo(r, t)
      ..lineTo(r, t + arm)
      ..moveTo(l, b - arm)
      ..lineTo(l, b)
      ..lineTo(l + arm, b)
      ..moveTo(r - arm, b)
      ..lineTo(r, b)
      ..lineTo(r, b - arm);
    canvas.drawPath(path, bracket);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 设备列表连通性探测触发器（零尺寸）：启动器每次出现（挂载）时对全部
/// 设备做一轮源站探测，结果经 [deviceConnectivityProvider] 驱动卡片状态点。
class _ConnectivityProbeTrigger extends ConsumerStatefulWidget {
  const _ConnectivityProbeTrigger();

  @override
  ConsumerState<_ConnectivityProbeTrigger> createState() =>
      _ConnectivityProbeTriggerState();
}

class _ConnectivityProbeTriggerState
    extends ConsumerState<_ConnectivityProbeTrigger> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        ref.read(deviceConnectivityProvider.notifier).probeAll(
              ref.read(deviceListProvider),
              ref.read(sessionStatusProvider),
            ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

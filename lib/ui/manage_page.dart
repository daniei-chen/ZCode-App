import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../services/app_log.dart';
import '../services/app_settings.dart';
import '../services/device_import.dart';
import '../services/link_builder.dart';
import '../services/structured_log.dart';
import '../state/account_label.dart';
import '../state/device_directory.dart';
import '../state/device_summaries.dart';
import '../state/back_stack.dart';
import '../state/session_pool.dart';
import '../state/session_status.dart';
import '../state/event_feed.dart';
import '../theme.dart';
import '../models/device_label.dart';
import 'account_login_page.dart';
import 'section_label.dart';
import 'settings_page.dart';
import 'unread_badge.dart';

class ManagePage extends ConsumerWidget {
  const ManagePage({super.key, this.onOpenDevice, this.onSettingsReturned});

  final ValueChanged<int>? onOpenDevice;

  /// 从设置页返回后调用（**仅平板**会触发，见 [_SettingsEntry]）：
  /// 平板的对话与列表同屏，设置返回先回到该页，再一次返回才到设备页；
  /// 手机的设置返回就是普通弹栈，停在设备列表页（用户 2026-09-14 口径）。
  final VoidCallback? onSettingsReturned;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(deviceListProvider);
    final l10n = AppLocalizations.of(context)!;
    // 登录账号芯片（v1.3.0，账号中心化第一片）：V2 账号流里所有设备
    // 同属一个已登录账号，在设备中心头部把它亮出来。探针没读到（还没
    // 进过远控页）时不占位。v1.7.0 起展示名 + 头像都来自 user_info 探针
    // 并持久化——重启后账号行仍是实名 + 头像。
    final profile = ref.watch(accountProfileProvider);
    final account = profile.name.isNotEmpty
        ? profile.name
        : ref.watch(accountLabelProvider);
    // 账号设备目录（v1.5.0）：官方"选择电脑"页的同款数据源，30s 探活。
    final directory = ref.watch(deviceDirectoryProvider);
    final directorySids = {
      for (final d in directory.devices) d.sid,
    };

    return Scaffold(
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
                  padding: const EdgeInsets.fromLTRB(2, 6, 2, 0),
                  child: Row(
                    children: [
                      _ZLogoBadge(size: 42, radius: 13),
                      const SizedBox(width: 11),
                      Flexible(
                        child: Text(
                          'ZCode',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.4,
                            color: context.zt.textHi,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(2, 14, 2, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          devices.isEmpty
                              ? l10n.launcherTitleSelectComputer
                              : l10n.launcherTitleSelectComputer,
                          style: TextStyle(
                            fontSize: 27,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.6,
                            color: context.zt.textHi,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: l10n.commonRefresh,
                        onPressed: () =>
                            ref.read(deviceListProvider.notifier).reload(),
                        icon: Icon(
                          Icons.refresh,
                          size: 22,
                          color: context.zt.textLo,
                        ),
                      ),
                    ],
                  ),
                ),
                if (account.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(2, 4, 2, 0),
                    child: Row(
                      children: [
                        _AccountAvatar(
                          profile: profile,
                          name: account,
                          size: 30,
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            account,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: context.zt.textHi,
                            ),
                          ),
                        ),
                        // 在线统计（官方排版：账号行右侧，权威口径=目录
                        // online 字段；官方服务端判定，与绿点一致）。
                        Text(
                          l10n.launcherGroupOnline(
                            directory.devices.where((d) => d.online).length,
                          ),
                          style: TextStyle(
                            fontSize: 12.5,
                            color: context.zt.textLo,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 14),
                // 账号优先的空态（v1.5.1）：没登录 = 整个空态就是"添加账号"，
                // 扫码/粘贴收进卡内次要行；登录后无设备 = 官方口径引导。
                if (directory.status == DeviceDirectoryStatus.authExpired)
                  _AccountExpiredBanner(
                    onRelogin: () => _openLogin(context),
                  ),
                // v1.6.3 结构修正：账号设备区不再挂在"手动设备非空"分支下
                //（全新装机手动为 0 时账号设备永远不渲染——MuMu 实测抓到）。
                if (directory.devices.isEmpty && devices.isEmpty) ...[
                  if (directory.status == DeviceDirectoryStatus.signedOut)
                    _AccountLoginCard(
                      onRefresh: () =>
                          ref.read(deviceDirectoryProvider.notifier).refresh(),
                      onScan: () => _openScanner(context, ref),
                      onPaste: () => _showPasteDialog(context, ref),
                    )
                  else if (directory.status == DeviceDirectoryStatus.ready)
                    _NoDirectoryDevicesHint(
                      onRefresh: () =>
                          ref.read(deviceDirectoryProvider.notifier).refresh(),
                      onScan: () => _openScanner(context, ref),
                      onPaste: () => _showPasteDialog(context, ref),
                    )
                  else
                    _EmptyHint(
                      storageUnavailable: ref.watch(
                        deviceStoreUnavailableProvider,
                      ),
                      onRetry: () =>
                          ref.read(deviceListProvider.notifier).reload(),
                      onScan: () => _openScanner(context, ref),
                      onPaste: () => _showPasteDialog(context, ref),
                    ),
                ] else ...[
                  if (directory.devices.isNotEmpty) ...[
                    SectionLabel(l10n.accountDevicesSection),
                    for (final entry in directory.devices)
                      _AccountDeviceCard(
                        device: entry,
                        onOpen: () => _openAccountDevice(context, ref, entry),
                      ),
                    const SizedBox(height: 2),
                  ],
                  // 手动设备：目录已展示的 sid 不重复出现。
                  if (devices.any((d) => !directorySids.contains(d.sid))) ...[
                    SectionLabel(l10n.devicesCount(devices.length)),
                    ReorderableListView(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      buildDefaultDragHandles: false,
                      onReorderItem: (oldIndex, newIndex) => ref
                          .read(deviceListProvider.notifier)
                          .reorder(oldIndex, newIndex),
                      children: [
                        for (var i = 0; i < devices.length; i++)
                          if (!directorySids.contains(devices[i].sid))
                            _DeviceCard(
                              key: ValueKey(devices[i].id),
                              device: devices[i],
                              index: i,
                              onOpenDevice: onOpenDevice,
                            ),
                      ],
                    ),
                  ],
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
                _SettingsEntry(onReturned: onSettingsReturned),
                const VersionFooter(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openLogin(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<bool>(builder: (_) => const AccountLoginPage()),
    );
  }

  /// 打开账号设备：sid 已导入则直达，否则按目录信息创建并打开。
  /// 连接 URL 与扫码导入完全同构（sid+mid+name），登录态已在 WebView
  /// 存储里，打开远控页即自动配对。
  Future<void> _openAccountDevice(
    BuildContext context,
    WidgetRef ref,
    AccountDevice device,
  ) async {
    var index = ref
        .read(deviceListProvider)
        .indexWhere((d) => d.sid == device.sid);
    if (index < 0) {
      const uuid = Uuid();
      final remote = RemoteDevice(
        id: uuid.v4(),
        baseUrl: 'https://zcode.z.ai/remote/v4',
        params: {
          'sid': device.sid,
          'mid': device.mid,
          'name': device.displayName,
          'app_version': '3.16.3',
        },
        label: device.displayName,
        createdAt: DateTime.now(),
      );
      await ref.read(deviceListProvider.notifier).add(remote);
      index = ref
          .read(deviceListProvider)
          .indexWhere((d) => d.sid == device.sid);
    }
    if (index < 0) return;
    ref.read(eventFeedProvider.notifier).markRead(
          ref.read(deviceListProvider)[index].id,
        );
    ref.read(activeTabProvider.notifier).set(index);
    final open = onOpenDevice;
    if (open != null) {
      open(index);
    }
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
    if (devices.length == 5 && context.mounted) {
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
    await ref.read(deviceListProvider.notifier).add(device);
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
          hintText: 'https://zcode.z.ai/remote/v4?sid=...&name=...',
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
  await ref.read(deviceListProvider.notifier).replaceLink(target.id, parsed);
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
          padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
          child: Row(
            children: [
              // 官方「选择电脑」风格（v1.4.0）：56px 圆角图标 + 左下角状态点
              //（在线=live 绿、连接中=黄、异常=红，白描边圆点叠在图标角上）。
              SizedBox(
                width: 56,
                height: 56,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(17),
                        color: context.zt.surfaceHi,
                      ),
                      child: Icon(
                        Icons.desktop_windows,
                        size: 27,
                        color: context.zt.accent,
                      ),
                    ),
                    Positioned(
                      left: -3,
                      bottom: -3,
                      child: Container(
                        width: 15,
                        height: 15,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: context.zt.bg,
                          border: Border.all(color: context.zt.bg, width: 3),
                        ),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: context.zt.statusColor(status),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.displayName(l10n),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: context.zt.textHi,
                      ),
                    ),
                    const SizedBox(height: 3),
                    _TaskStatusLine(sid: device.sid),
                  ],
                ),
              ),
              UnreadBadge(feed: feed),
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
      await ref.read(deviceListProvider.notifier).rename(device.id, name);
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
    await ref.read(deviceListProvider.notifier).remove(device.id);
  }
}

class _SettingsEntry extends StatelessWidget {
  const _SettingsEntry({this.onReturned});

  /// 设置页返回后的回调。**只在平板布局下触发**：平板从设置返回要先回到
  /// "对话 + 列表同屏"页，再一次返回才到设备页；手机就是普通弹栈停在
  /// 设备列表页（回调不会被调用）。
  final VoidCallback? onReturned;

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
          // 跨 async gap 前先取布局判定：push 返回后 context 可能已失效。
          final tablet = isTabletLayout(MediaQuery.of(context).size);
          await Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
          // 手机：设置返回 = 设备列表页（一次到位，普通弹栈）。
          // 平板：设置返回 = 对话/列表同屏页（onReturned），再返回才到设备页。
          if (tablet && context.mounted) {
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
              _cameraError = error.errorCode;
              AppLog.event(
                LogEvent.cameraFailed,
                level: LogLevel.warn,
                fields: {
                  LogField.reason: error.errorCode.name,
                  LogField.ok: false,
                },
              );
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
      await ref
          .read(deviceListProvider.notifier)
          .replaceLink(replaceOf.id, device);
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
    await ref.read(deviceListProvider.notifier).add(device);
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

/// ZCode 官方风格的黑色 Z 徽章（v1.4.0 首页改版）：圆角方块 + 白色粗体 Z，
/// 暗色模式反色为白底黑字。
/// 登录账号头像（v1.7.0）：官方 OAuth 资料图（白名单图床）优先；
/// 没有图或加载失败回退字母头像（黑白原生风），再回退人形图标。
class _AccountAvatar extends StatelessWidget {
  const _AccountAvatar({
    required this.profile,
    required this.name,
    this.size = 30,
  });

  final AccountProfile profile;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    Widget fallback() => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: context.zt.surfaceHi,
      ),
      alignment: Alignment.center,
      child: name.trim().isEmpty
          ? Icon(Icons.person_outline, size: size * 0.56, color: context.zt.textHi)
          : Text(
              name.trim().characters.first.toUpperCase(),
              style: TextStyle(
                fontSize: size * 0.45,
                height: 1.0,
                fontWeight: FontWeight.w800,
                color: context.zt.textHi,
              ),
            ),
    );

    final url = profile.avatarUrl;
    if (url == null || !AccountLabel.isTrustedAvatarUrl(url)) {
      return fallback();
    }
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: Image.network(
          url,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => fallback(),
        ),
      ),
    );
  }
}

class _ZLogoBadge extends StatelessWidget {
  const _ZLogoBadge({this.size = 44, this.radius = 14});

  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final dark = context.zt.isDark;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: dark ? Colors.white : Colors.black,
      ),
      child: Center(
        child: Text(
          'Z',
          style: TextStyle(
            fontSize: size * 0.55,
            height: 1.0,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.5,
            color: dark ? Colors.black : Colors.white,
          ),
        ),
      ),
    );
  }
}

/// 账号登录 CTA（v1.5.0）：黑白主按钮 + 说明；点击进官方登录流，
/// 登录完成后设备目录自动刷新出设备列表。
class _AccountLoginCard extends StatelessWidget {
  const _AccountLoginCard({
    required this.onRefresh,
    this.onScan,
    this.onPaste,
  });

  final Future<void> Function() onRefresh;
  final VoidCallback? onScan;
  final VoidCallback? onPaste;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.laptop_mac_outlined,
                  size: 22,
                  color: context.zt.textHi,
                ),
                const SizedBox(width: 9),
                Text(
                  l10n.accountLoginCta,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: context.zt.textHi,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              l10n.accountLoginHint,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: context.zt.textLo,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: context.zt.accent,
                  foregroundColor: context.zt.onAccent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
                onPressed: () async {
                  final ok = await Navigator.of(context).push(
                    MaterialPageRoute<bool>(
                      builder: (_) => const AccountLoginPage(),
                    ),
                  );
                  if (ok == true) await onRefresh();
                },
                child: Text(
                  l10n.accountLoginTitle,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            // 手动方式收进次要行：账号是主路，扫码/粘贴只是兜底。
            if (onScan != null || onPaste != null) ...[
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(
                    onPressed: onScan,
                    child: Text(l10n.accountManualAdd),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 已登录但账号下还没有设备（v1.5.1）：官方口径引导 + 刷新 + 手动兜底。
class _NoDirectoryDevicesHint extends StatelessWidget {
  const _NoDirectoryDevicesHint({
    required this.onRefresh,
    this.onScan,
    this.onPaste,
  });

  final Future<void> Function() onRefresh;
  final VoidCallback? onScan;
  final VoidCallback? onPaste;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.accountNoDevicesTitle,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: context.zt.textHi,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              l10n.accountNoDevicesHint,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: context.zt.textLo,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    backgroundColor: context.zt.surfaceHi,
                    foregroundColor: context.zt.textHi,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () => onRefresh(),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.refresh, size: 16),
                      const SizedBox(width: 5),
                      Text(l10n.commonRefresh),
                    ],
                  ),
                ),
                const Spacer(),
                TextButton(onPressed: onScan, child: Text(l10n.accountManualAdd)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 登录过期横幅（v1.5.0）：点按重新进入登录流。
class _AccountExpiredBanner extends StatelessWidget {
  const _AccountExpiredBanner({required this.onRelogin});

  final VoidCallback onRelogin;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: context.zt.surfaceHi,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onRelogin,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Row(
              children: [
                Icon(Icons.lock_clock, size: 17, color: context.zt.textHi),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    l10n.accountExpiredBanner,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: context.zt.textHi,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right, size: 18, color: context.zt.textLo),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 账号设备行（v1.5.0）：官方"选择电脑"形态——大图标 + 左下角探活点
///（在线=绿、离线=灰）+ 名称/状态副标题 + chevron，点按即连。
class _AccountDeviceCard extends StatelessWidget {
  const _AccountDeviceCard({required this.device, required this.onOpen});

  final AccountDevice device;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final online = device.online;
    return Card(
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
          child: Row(
            children: [
              SizedBox(
                width: 56,
                height: 56,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(17),
                        color: context.zt.surfaceHi,
                      ),
                      child: Icon(
                        Icons.desktop_windows,
                        size: 27,
                        color: context.zt.textHi,
                      ),
                    ),
                    Positioned(
                      left: -3,
                      bottom: -3,
                      child: Container(
                        width: 15,
                        height: 15,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: context.zt.bg,
                          border: Border.all(color: context.zt.bg, width: 3),
                        ),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: online
                                ? context.zt.live
                                : context.zt.hairline,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: context.zt.textHi,
                      ),
                    ),
                    const SizedBox(height: 3),
                    _TaskStatusLine(sid: device.sid),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 21, color: context.zt.textLo),
            ],
          ),
        ),
      ),
    );
  }
}

/// 设备卡任务状态行（v1.6.0 工作台）：优先显示"正在干什么"，
/// 没有摘要时回退到 在线/离线。pending 挂醒目色（审批红点语义）。
class _TaskStatusLine extends ConsumerWidget {
  const _TaskStatusLine({required this.sid});

  final String sid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final summary = ref.watch(deviceSummariesProvider)[sid];
    final (state, title) = taskLineOf(summary);
    // 新鲜度（v1.8.4）：区分"刚跑完"和"三小时前的旧状态"。
    final fresh = freshnessOf(summary);
    final suffix = fresh.isEmpty ? '' : ' · $fresh';
    final text = switch (state) {
      'pending' => '${l10n.taskPending} · $title$suffix',
      'running' => '${l10n.taskRunning} · $title$suffix',
      'completed' => '${l10n.taskCompleted} · $title$suffix',
      'error' => '${l10n.taskFailed} · $title$suffix',
      _ => '',
    };
    if (text.isEmpty) return const SizedBox(height: 17);
    final color = switch (state) {
      'pending' => context.zt.warn,
      'error' => context.zt.danger,
      'running' => context.zt.textLo,
      _ => context.zt.textLo,
    };
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12, color: color),
    );
  }
}

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../services/app_settings.dart';
import '../services/notifier.dart';
import '../services/session_jump.dart';
import '../services/update_service.dart';
import '../state/app_lifecycle.dart';
import '../state/back_stack.dart';
import '../state/event_feed.dart';
import '../state/notification_prefs.dart';
import '../state/pending_session_jump.dart';
import '../state/session_pool.dart';
import '../theme.dart';
import 'manage_page.dart';
import 'official_remote_page.dart';
import 'update_download_dialog.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, this.startAtLauncher = false});

  final bool startAtLauncher;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  bool _pendingTapConsumed = false;
  _FloatingNotice? _floatingNotice;
  Timer? _noticeTimer;
  UpdateCheckResult? _pendingUpdate;
  bool _updateDialogShowing = false;
  bool _backHandling = false;
  final Map<String, OfficialRemotePageController> _remotePageControllers = {};

  /// The launcher is a native App surface. Device WebViews stay mounted
  /// underneath it so returning to a device restores the exact same page
  /// instead of starting a fresh navigation.
  bool _launcherVisible = false;

  /// 设置返回揭示远控页的时刻（平板路径）。同一次返回键在部分机型上会被
  /// 再派发一次（真机 v1.1.5 反馈：设置返回后"自动又返回了一级"），揭示后
  /// 短窗口内的返回键按同一次操作的多余派发吞掉。
  DateTime? _settingsRevealedAt;

  static const _settingsRevealBackSwallow = Duration(milliseconds: 900);

  @override
  void initState() {
    super.initState();
    _launcherVisible = widget.startAtLauncher;
    NotificationTap.bind((payload) => _jumpTo(payload));
    NotifierService.instance.setLockScreenRedact(ref.read(biometricProvider));
    AppSettings.setRecentsCover(ref.read(biometricProvider));
    NotifierService.instance.setAlertMode(
      ref.read(notificationPrefsProvider).alertMode,
    );
    // Keep launch quiet: the check runs in the background and only a confirmed
    // newer release produces a one-time foreground prompt.
    unawaited(_checkForUpdateOnLaunch());
  }

  Future<void> _checkForUpdateOnLaunch() async {
    // 应用内更新只支持 Android（下载 APK + 系统安装器）；iOS 不进入该链路。
    if (!Platform.isAndroid) return;
    final result = await UpdateService.instance.checkForUpdate();
    if (!mounted || !result.hasUpdate || result.latestVersion == null) {
      return;
    }
    if (await UpdateService.instance.wasPrompted(result.latestVersion!)) {
      return;
    }
    _pendingUpdate = result;
    await _maybeShowUpdatePrompt();
  }

  Future<void> _maybeShowUpdatePrompt() async {
    if (!mounted ||
        _updateDialogShowing ||
        _pendingUpdate == null ||
        ref.read(appLifecycleProvider) != AppLifecycleState.resumed) {
      return;
    }
    final result = _pendingUpdate!;
    final version = result.latestVersion;
    if (version == null) return;
    _pendingUpdate = null;

    // _updateDialogShowing 负责防重复；markPrompted 必须在弹窗真实展示之后
    // 再落盘——提前落盘会在生命周期竞争下把本版本的提示永久吞掉（U07）。
    _updateDialogShowing = true;
    try {
      // The update surface stays in the current app. It fetches the exact APK
      // asset URL from GitHub, shows device-page styled progress, then hands
      // the downloaded file to Android's installer.
      await showUpdateDownloadDialog(context, result);
      await UpdateService.instance.markPrompted(version);
    } finally {
      _updateDialogShowing = false;
    }
  }

  @override
  void dispose() {
    _noticeTimer?.cancel();
    _remotePageControllers.clear();
    NotificationTap.bind(null);
    super.dispose();
  }

  Future<void> _handleSystemBack(
    OfficialRemotePageController controller,
  ) async {
    if (_backHandling || !mounted || _launcherVisible) return;
    // 设置返回刚揭示远控页：极短窗口内的再一次返回键视为同一次操作的
    // 多余派发（真机反馈"我只返回了一次，它返回了两次"），吞掉。
    final revealedAt = _settingsRevealedAt;
    if (revealedAt != null &&
        DateTime.now().difference(revealedAt) < _settingsRevealBackSwallow) {
      return;
    }
    _backHandling = true;
    try {
      // 页面先处理"对话页 → 对话列表"这类页内路由（手机与平板同一条路径）；
      // 页面处理不了时按层级露出设备页，再下一次返回才退出应用。
      final handled = await controller.handleBack();
      final decision = decideSystemBack(
        launcherVisible: _launcherVisible,
        pageHandled: handled,
      );
      if (decision == BackDecision.revealLauncher &&
          mounted &&
          !_launcherVisible) {
        _setLauncherVisible(true);
      }
    } finally {
      _backHandling = false;
    }
  }

  void _showFloatingNotice(String deviceId) {
    final devices = ref.read(deviceListProvider);
    final device = devices.where((d) => d.id == deviceId).firstOrNull;
    if (device == null || !mounted) return;

    final l10n = AppLocalizations.of(context)!;
    final feedItem = ref.read(eventFeedProvider)[deviceId];
    final type = feedItem?.lastType ?? '';
    final session = feedItem?.lastSessionTitle?.trim() ?? '';
    final summary = feedItem?.lastSummary?.trim() ?? '';
    final title = NotificationSpec.titleFor(device, session, l10n);
    final body = NotificationSpec.bodyFor(type, summary, l10n);

    _noticeTimer?.cancel();
    setState(() {
      _floatingNotice = _FloatingNotice(
        deviceId: deviceId,
        taskId: feedItem?.lastTaskId,
        type: type,
        title: title,
        body: body,
      );
    });
    _noticeTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _floatingNotice = null);
    });
  }

  void _dismissFloatingNotice() {
    _noticeTimer?.cancel();
    if (mounted) setState(() => _floatingNotice = null);
  }

  void _openFloatingNotice() {
    final notice = _floatingNotice;
    if (notice == null) return;
    _dismissFloatingNotice();
    final payload = notice.taskId == null || notice.taskId!.isEmpty
        ? notice.deviceId
        : '${notice.deviceId}|${notice.taskId}';
    _jumpTo(payload);
  }

  /// 'deviceId' switches the tab; 'deviceId|sessionId' additionally asks
  /// that device's conversation shell to open the session in place.
  ///
  /// iter16：设备已删除时**不写任何跳转**——没有页面会消费它，只会留下一条
  /// 长驻的陈旧目标，用户看到的是"点了通知什么也没发生"。payload 的会话段
  /// 由 [SessionJump.decodePayload] 做过精确两段 + 白名单校验（页面可控
  /// taskId 含 '|' 时不得截断成前缀去命中同前缀的另一个会话）。
  void _jumpTo(String payload) {
    if (!mounted) return;
    final (deviceId, sessionId) = SessionJump.decodePayload(payload);
    final index = ref
        .read(deviceListProvider)
        .indexWhere((d) => d.id == deviceId);
    if (index < 0) return;
    ref.read(eventFeedProvider.notifier).markRead(deviceId);
    ref.read(activeTabProvider.notifier).set(index);
    if (_launcherVisible) _setLauncherVisible(false);
    if (sessionId == null) return;
    ref
        .read(pendingSessionJumpProvider.notifier)
        .set(PendingSessionJump(deviceId: deviceId, sessionId: sessionId));
  }

  void _consumePendingTap() {
    if (_pendingTapConsumed) return;
    if (ref.read(deviceListProvider).isEmpty) return;
    _pendingTapConsumed = true;
    final pending = NotificationTap.consumePending();
    if (pending != null) _jumpTo(pending);
  }

  void _openDevice(int index) {
    if (!mounted) return;
    final devices = ref.read(deviceListProvider);
    if (index < 0 || index >= devices.length) return;
    // This also covers tapping the already-selected card: activeTabProvider
    // does not emit in that case, but entering the card still means “read”.
    ref.read(eventFeedProvider.notifier).markRead(devices[index].id);
    ref.read(activeTabProvider.notifier).set(index);
    if (_launcherVisible) {
      _setLauncherVisible(false);
    }
  }

  /// 统一维护"设备页/启动器是否遮盖远控页"：控制器据此决定主题变更时
  /// 是就地刷 DOM 还是整页重载（重载只在被遮盖、用户看不见时执行）。
  void _setLauncherVisible(bool visible) {
    if (!mounted) return;
    for (final controller in _remotePageControllers.values) {
      controller.setCovered(visible);
    }
    setState(() => _launcherVisible = visible);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AppLifecycleState>(appLifecycleProvider, (_, next) {
      if (next == AppLifecycleState.resumed) {
        unawaited(_maybeShowUpdatePrompt());
      }
    });
    ref.listen<bool>(
      biometricProvider,
      (_, next) {
        NotifierService.instance.setLockScreenRedact(next);
        AppSettings.setRecentsCover(next);
      },
    );
    ref.listen<NotificationPrefs>(notificationPrefsProvider, (_, next) {
      NotifierService.instance.setAlertMode(next.alertMode);
    });

    // 跳转请求（待处理中心点按/通知深链）到达即揭启动器盖板：点按**当前
    // 设备**的等待行时 activeTab.set 同值不发射，上面的 activeTab 监听
    // 不会触发，盖板会挡住会话跳转（iter15 复核 F1）。
    ref.listen(pendingSessionJumpProvider, (_, next) {
      if (next == null) return;
      if (_launcherVisible && mounted) {
        _setLauncherVisible(false);
      }
    });

    ref.listen(deviceListProvider, (prev, next) {
      ref.read(activeTabProvider.notifier).clampTo(next.length);
      if (prev != null && prev.isEmpty && next.isNotEmpty) {
        _consumePendingTap();
        ref.read(activeTabProvider.notifier).restoreLast();
      }
    });

    ref.listen(activeTabProvider, (_, next) {
      final list = ref.read(deviceListProvider);
      if (next < list.length) {
        // Opening a device acknowledges its unread event count. Keep the
        // actual pending permission state so the session itself can still
        // show that it needs a decision.
        ref.read(eventFeedProvider.notifier).markRead(list[next].id);
        if (_launcherVisible && mounted) {
          _setLauncherVisible(false);
        }
      }
    });

    // Feed events are also collected while the official remote page is in
    // front. That lets the native shell give immediate visual feedback even
    // when the OS notification gate intentionally stays quiet.
    ref.listen<Map<String, DeviceFeed>>(eventFeedProvider, (previous, next) {
      if (!mounted || previous == null) return;
      if (ref.read(appLifecycleProvider) != AppLifecycleState.resumed) return;
      for (final entry in next.entries) {
        final oldUnread = previous[entry.key]?.unread ?? 0;
        if (entry.value.unread > oldUnread) {
          unawaited(NotifierService.instance.playInAppSound());
          _showFloatingNotice(entry.key);
        }
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_pendingTapConsumed) _consumePendingTap();
      NotifierService.instance.ensurePermission();
    });

    final devices = ref.watch(deviceListProvider);
    if (devices.isEmpty) {
      return const ManagePage();
    }

    final active = ref.watch(activeTabProvider);
    final index = active.clamp(0, devices.length - 1);
    _remotePageControllers.removeWhere(
      (id, _) => !devices.any((device) => device.id == id),
    );
    for (final device in devices) {
      final controller = _remotePageControllers.putIfAbsent(
        device.id,
        OfficialRemotePageController.new,
      );
      // 新建的控制器要先同步当前遮盖状态（主题变更的整页重载据此选时机）。
      controller.setCovered(_launcherVisible);
    }
    final activeBackController = _remotePageControllers[devices[index].id]!;
    return PopScope<void>(
      // Back from the official page returns to the launcher. Back from the
      // launcher is allowed to leave the app normally.
      canPop: _launcherVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _launcherVisible) return;
        unawaited(_handleSystemBack(activeBackController));
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          IndexedStack(
            index: index,
            children: [
              for (final device in devices)
                OfficialRemotePage(
                  key: ValueKey(device.id),
                  device: device,
                  backController: _remotePageControllers[device.id],
                ),
            ],
          ),
          if (_launcherVisible)
            Positioned.fill(
              child: ManagePage(
                onOpenDevice: _openDevice,
                // 探测当前设备的官方页是否"对话+列表同屏"：设置返回的落地
                // 决策按页面实际布局（真平板/大屏手机都能走对）。
                onProbeCombinedLayout: () async {
                  final devices = ref.read(deviceListProvider);
                  if (devices.isEmpty) return null;
                  final idx = ref
                      .read(activeTabProvider)
                      .clamp(0, devices.length - 1);
                  return _remotePageControllers[devices[idx].id]
                      ?.probeCombinedLayout();
                },
                // 同屏布局下从设置返回先回该页，再一次返回才到设备页。
                onSettingsReturned: () {
                  if (!mounted || !_launcherVisible) return;
                  _settingsRevealedAt = DateTime.now();
                  _setLauncherVisible(false);
                },
              ),
            ),
          if (_floatingNotice != null)
            Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              left: 16,
              right: 16,
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: _FloatingNoticeCard(
                    notice: _floatingNotice!,
                    onTap: _openFloatingNotice,
                    onClose: _dismissFloatingNotice,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FloatingNotice {
  const _FloatingNotice({
    required this.deviceId,
    required this.taskId,
    required this.type,
    required this.title,
    required this.body,
  });

  final String deviceId;
  final String? taskId;
  final String type;
  final String title;
  final String body;
}

class _FloatingNoticeCard extends StatelessWidget {
  const _FloatingNoticeCard({
    required this.notice,
    required this.onTap,
    required this.onClose,
  });

  final _FloatingNotice notice;
  final VoidCallback onTap;
  final VoidCallback onClose;

  IconData get _icon => switch (notice.type) {
    'permission_request' ||
    'elicitation_request' => Icons.notifications_active_outlined,
    'completed' => Icons.check_circle_outline,
    'error' => Icons.error_outline,
    _ => Icons.notifications_none_outlined,
  };

  Color _color(BuildContext context) => switch (notice.type) {
    'completed' => context.zt.live,
    'error' => context.zt.danger,
    'permission_request' || 'elicitation_request' => context.zt.warn,
    _ => context.zt.accent,
  };

  @override
  Widget build(BuildContext context) {
    final color = _color(context);
    return Material(
      color: context.zt.surface,
      elevation: 8,
      shadowColor: Colors.black54,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: context.zt.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Image.asset(
                  'assets/brand/mark.png',
                  width: 38,
                  height: 38,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    width: 38,
                    height: 38,
                    color: color.withValues(alpha: 0.12),
                    child: Icon(_icon, size: 21, color: color),
                  ),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      notice.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: context.zt.textHi,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      notice.body,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: context.zt.textLo),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: onClose,
                icon: Icon(Icons.close, size: 18, color: context.zt.textLo),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

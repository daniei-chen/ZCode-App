import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../services/notifier.dart';
import '../services/update_service.dart';
import '../state/app_lifecycle.dart';
import '../state/event_feed.dart';
import '../state/root_tabs.dart';
import '../state/session_pool.dart';
import '../theme.dart';
import 'manage_page.dart';
import 'official_remote_page.dart';

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

  /// The launcher is a native App surface. Device WebViews stay mounted
  /// underneath it so returning to a device restores the exact same page
  /// instead of starting a fresh navigation.
  bool _launcherVisible = false;

  @override
  void initState() {
    super.initState();
    _launcherVisible = widget.startAtLauncher;
    NotificationTap.bind((payload) => _jumpTo(payload));
    NotifierService.instance.setLockScreenRedact(ref.read(biometricProvider));
    // Keep launch quiet: the check runs in the background and only a confirmed
    // newer release produces a one-time foreground prompt.
    unawaited(_checkForUpdateOnLaunch());
  }

  Future<void> _checkForUpdateOnLaunch() async {
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
    final releaseUri = result.releaseUri;
    if (version == null || releaseUri == null) return;
    _pendingUpdate = null;

    // Mark before displaying so a repeated rebuild or a second resume cannot
    // open the same prompt twice. Closing it means “ask again only for a new
    // version”, as requested.
    await UpdateService.instance.markPrompted(version);
    if (!mounted ||
        ref.read(appLifecycleProvider) != AppLifecycleState.resumed) {
      return;
    }

    _updateDialogShowing = true;
    try {
      final l10n = AppLocalizations.of(context)!;
      final open = await showDialog<bool>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.updateDialogTitle),
          content: Text(l10n.updateDialogMessage(version)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.updateDialogLater),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.updateDialogDownload),
            ),
          ],
        ),
      );
      if (open == true) {
        final opened = await UpdateService.instance.openRelease(releaseUri);
        if (!opened && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.updateFailed)),
          );
        }
      }
    } finally {
      _updateDialogShowing = false;
    }
  }

  @override
  void dispose() {
    _noticeTimer?.cancel();
    NotificationTap.bind(null);
    super.dispose();
  }

  void _showFloatingNotice(String deviceId) {
    final devices = ref.read(deviceListProvider);
    final device = devices.where((d) => d.id == deviceId).firstOrNull;
    if (device == null || !mounted) return;

    final l10n = AppLocalizations.of(context)!;
    final event = ref.read(eventHistoryProvider)[deviceId]?.firstOrNull;
    final type = event?.type ?? '';
    final session = event?.sessionTitle?.trim() ?? '';
    final summary = event?.summary?.trim() ?? '';
    final title = NotificationSpec.titleFor(device, session, l10n);
    final body = NotificationSpec.bodyFor(type, summary, l10n);

    _noticeTimer?.cancel();
    setState(() {
      _floatingNotice = _FloatingNotice(
        deviceId: deviceId,
        taskId: event?.taskId,
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
  void _jumpTo(String payload) {
    if (!mounted) return;
    final parts = payload.split('|');
    final deviceId = parts.isEmpty || parts.first.isEmpty
        ? payload
        : parts.first;
    final index = ref
        .read(deviceListProvider)
        .indexWhere((d) => d.id == deviceId);
    if (index >= 0) ref.read(activeTabProvider.notifier).set(index);
    if (parts.length > 1 && parts[1].isNotEmpty) {
      ref
          .read(pendingSessionJumpProvider.notifier)
          .set(PendingSessionJump(deviceId: deviceId, sessionId: parts[1]));
    }
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
    ref.read(activeTabProvider.notifier).set(index);
    if (_launcherVisible) {
      setState(() => _launcherVisible = false);
    }
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
      (_, next) => NotifierService.instance.setLockScreenRedact(next),
    );

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
        ref.read(eventFeedProvider.notifier).clear(list[next].id);
        if (_launcherVisible && mounted) {
          setState(() => _launcherVisible = false);
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
    return PopScope<void>(
      // Back from the official page returns to the launcher. Back from the
      // launcher is allowed to leave the app normally.
      canPop: _launcherVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_launcherVisible && mounted) {
          setState(() => _launcherVisible = true);
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          IndexedStack(
            index: index,
            children: [
              for (final device in devices)
                OfficialRemotePage(key: ValueKey(device.id), device: device),
            ],
          ),
          if (_launcherVisible)
            Positioned.fill(child: ManagePage(onOpenDevice: _openDevice)),
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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import 'l10n/app_localizations.dart';
import 'models/device_label.dart';
import 'services/app_log.dart';
import 'services/biometric.dart';
import 'services/device_store.dart';
import 'services/notifier.dart';
import 'services/structured_log.dart';
import 'services/webview_storage.dart';
import 'state/app_lifecycle.dart';
import 'state/observer_stats.dart';
import 'state/session_pool.dart';
import 'state/startup_target.dart';
import 'state/theme_mode.dart';
import 'theme.dart';
import 'ui/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = DeviceStore.instance;
  // Start all small persistence reads together. Android keeps the launch
  // window visible until the first Flutter frame; serial secure-storage and
  // SharedPreferences reads made that window feel like a second splash.
  unawaited(NotifierService.instance.init());
  final devicesFuture = _readDevices(store.loadAllWithStatus());
  final lastDeviceFuture = _safeLastDevice(store.lastDeviceId());
  final securityPrefFuture = _readSecurityPref(store.biometricEnabled());
  final themeModeFuture = _safeString(store.themeModeSetting(), 'system');
  final startupTargetFuture = _safeString(store.startupTarget(), 'lastDevice');

  // Resolve the saved devices before the first Flutter frame. Otherwise the
  // provider briefly reports an empty list and paints the import launcher
  // before switching to the last WebView a moment later.
  final initialDevicesResult = await devicesFuture;
  final initialDevices = initialDevicesResult.devices;
  final lastDeviceId = await lastDeviceFuture;
  final initialSecurityPref = await securityPrefFuture;
  final initialThemeMode = await themeModeFuture;
  final startupTarget = await startupTargetFuture;
  final recentIndex = lastDeviceId == null
      ? -1
      : initialDevices.indexWhere((d) => d.id == lastDeviceId);
  final initialActiveIndex = recentIndex >= 0 ? recentIndex : 0;
  // 启动进入可配置：默认恢复最近设备；选了"设备中心"或上次没有已保存设备
  // 时落在设备列表。
  final startAtLauncher =
      initialDevices.isNotEmpty &&
      (recentIndex < 0 || startupTarget == 'launcher');

  runApp(
    ProviderScope(
      overrides: [
        deviceListProvider.overrideWith(
          () => DeviceListNotifier(seed: initialDevices),
        ),
        activeTabProvider.overrideWith(
          () => ActiveTabNotifier(initialIndex: initialActiveIndex),
        ),
        deviceStoreUnavailableProvider.overrideWith(
          () => DeviceStoreUnavailableNotifier(
            initial: initialDevicesResult.unavailable,
          ),
        ),
        biometricProvider.overrideWith(
          () => BiometricNotifier(initial: initialSecurityPref.enabled),
        ),
        securityPrefUnreadableProvider.overrideWith(
          () => SecurityPrefNotifier(initial: initialSecurityPref.unreadable),
        ),
        themeModeProvider.overrideWith(
          () => ThemeModeNotifier(initial: initialThemeMode),
        ),
        startupTargetProvider.overrideWith(
          () => StartupTargetNotifier(initial: startupTarget),
        ),
      ],
      child: ZCodeControlApp(startAtLauncher: startAtLauncher),
    ),
  );
}

Future<DeviceLoadResult> _readDevices(Future<DeviceLoadResult> future) async {
  try {
    return await future;
  } catch (e) {
    // loadAllWithStatus 不抛异常；这里兜底也要如实上报"读不到"，
    // 绝不伪装成"没有设备"，否则用户会以为数据被删了。
    return DeviceLoadResult(devices: const [], unavailable: true, cause: e);
  }
}

Future<String?> _safeLastDevice(Future<String?> future) async {
  try {
    return await future;
  } catch (_) {
    return null;
  }
}

/// 安全偏好读取结果：`unreadable` 表示读取失败。
///
/// 读取失败必须保持锁定（fail-closed），不能等价于"未启用保护"：
/// 锁屏会提供重试，恢复读取后才允许进入内容。
class _SecurityPref {
  const _SecurityPref(this.enabled, {this.unreadable = false});

  final bool enabled;
  final bool unreadable;
}

Future<_SecurityPref> _readSecurityPref(Future<bool> future) async {
  try {
    return _SecurityPref(await future);
  } catch (_) {
    // fail-closed：读不到就锁定。但如果用户此前在锁屏明确确认过
    // "清除安全设置并继续"（标记存在独立的安全存储后端），凭它放行——
    // 否则 SharedPreferences 一旦损坏，重试永远失败，用户被永久锁在门外
    // （v1.1.7 真机反馈的死锁）。异常本身已由 DeviceStore 记入结构化日志。
    final acked = await DeviceStore.instance.securityResetAcknowledged();
    if (acked) return const _SecurityPref(false);
    return const _SecurityPref(true, unreadable: true);
  }
}

Future<String> _safeString(Future<String> future, String fallback) async {
  try {
    return await future;
  } catch (_) {
    return fallback;
  }
}

class ZCodeControlApp extends ConsumerWidget {
  const ZCodeControlApp({super.key, this.startAtLauncher = false});

  final bool startAtLauncher;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'ZCode',
      debugShowCheckedModeBanner: false,
      theme: ZT.lightTheme,
      darkTheme: ZT.darkTheme,
      themeMode: ThemeModeNotifier.toMaterial(themeMode),
      // The launcher is intentionally simplified-Chinese only. Keeping this
      // explicit also prevents the host device locale from switching the UI.
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) {
        final palette =
            Theme.of(context).extension<ZTPalette>() ??
            ZTPalette.of(Theme.of(context).brightness);
        final dark = palette.isDark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
            statusBarBrightness: dark ? Brightness.dark : Brightness.light,
            systemNavigationBarColor: palette.bg,
            systemNavigationBarIconBrightness: dark
                ? Brightness.light
                : Brightness.dark,
            systemNavigationBarDividerColor: Colors.transparent,
            systemNavigationBarContrastEnforced: false,
          ),
          child: BiometricGate(child: child ?? const SizedBox.shrink()),
        );
      },
      // 门禁包住整个 Navigator（F02）：锁定时整棵路由树——包括已 push 的
      // 设置/诊断页与粘贴控制链接的对话框——都不再构建，不会把敏感内容
      // 留在锁屏之上；解锁后从入口重新进入。
      home: LifecycleWatcher(child: AppShell(startAtLauncher: startAtLauncher)),
    );
  }
}

class BiometricGate extends ConsumerStatefulWidget {
  const BiometricGate({
    super.key,
    required this.child,
    this.relockAfter = const Duration(seconds: 10),
    this.authenticate = _defaultAuthenticate,
    this.authenticateWithDeviceCredential =
        _defaultDeviceCredentialAuthenticate,
    this.wipeProtectedData = _defaultWipeProtectedData,
  });

  final Widget child;

  final Duration relockAfter;

  final Future<bool> Function(String reason) authenticate;

  /// 恢复路径：生物识别不可用时，必须用系统锁屏凭据验证身份才解锁。
  final Future<bool> Function(String reason) authenticateWithDeviceCredential;

  /// 破坏性恢复路径：清除本机受保护数据；数据既已删除，此后免验证放行才成立。
  final Future<void> Function() wipeProtectedData;

  static Future<bool> _defaultAuthenticate(String reason) =>
      BiometricService.instance.authenticate(reason);

  static Future<bool> _defaultDeviceCredentialAuthenticate(String reason) =>
      BiometricService.instance.authenticateWithDeviceCredential(reason);

  static Future<void> _defaultWipeProtectedData() async {
    await DeviceStore.instance.clearAll();
  }

  @override
  ConsumerState<BiometricGate> createState() => _BiometricGateState();
}

class _BiometricGateState extends ConsumerState<BiometricGate>
    with WidgetsBindingObserver {
  bool _authed = false;
  bool _authenticating = false;
  bool _startupPrompted = false;
  DateTime? _leftAt;
  bool _authCovered = false;
  bool _unavailable = false;
  bool _noDeviceCredential = false;
  bool _wipeBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _startupPrompted = true;
      if (ref.read(biometricProvider) &&
          !ref.read(securityPrefUnreadableProvider)) {
        _unlock();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 门禁从"关闭"切到"开启"时（例如用户刚在设置里打开），不立刻把用户锁在
  /// 门外：开启本身要求通过一次系统验证，那次验证就在几秒前。把最近一次成功
  /// 验证当作本次会话的解锁凭据，与回前台时的判定规则一致（relockAfter 窗口）。
  void _adoptRecentAuthIfEnabled(bool enabled) {
    if (_authed || !enabled) return;
    final lastSuccess = BiometricService.instance.lastSuccessAt;
    if (lastSuccess == null) return;
    if (DateTime.now().difference(lastSuccess) >= widget.relockAfter) return;
    _authed = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      if (_authenticating) {
        _authCovered = true;
      } else {
        _leftAt ??= DateTime.now();
      }
    } else if (state == AppLifecycleState.resumed) {
      final covered = _authCovered;
      _authCovered = false;
      final leftAt = _leftAt;
      _leftAt = null;
      if (ref.read(securityPrefUnreadableProvider)) return;
      if (!ref.read(biometricProvider)) return;
      if (!_startupPrompted) return;
      if (covered) {
        return;
      }
      final lastSuccess = BiometricService.instance.lastSuccessAt;
      if (lastSuccess != null &&
          DateTime.now().difference(lastSuccess) < widget.relockAfter) {
        return;
      }
      final away = leftAt == null
          ? widget.relockAfter
          : DateTime.now().difference(leftAt);
      if (away < widget.relockAfter && _authed) return;
      _relockAndPrompt();
    }
  }

  void _relockAndPrompt() {
    if (!_authed) {
      _unlock();
      return;
    }
    setState(() => _authed = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _unlock();
    });
  }

  Future<void> _unlock() async {
    if (_authenticating) return;
    // 安全偏好读取失败时不得凭一次验证就放行：先让用户在锁屏重试读取。
    if (ref.read(securityPrefUnreadableProvider)) return;
    _authenticating = true;
    try {
      final reason = (AppLocalizations.of(context) ?? l10nZh).unlockReason;
      final ok = await widget.authenticate(reason);
      if (mounted && ok) {
        setState(() {
          _authed = true;
          _unavailable = false;
        });
      }
    } on BiometricUnavailableException {
      if (mounted) {
        // Do not silently disable a security control. The user gets an
        // explicit recovery action on the lock screen instead.
        setState(() => _unavailable = true);
      }
    } catch (e) {
      AppLog.failure(
        LogEvent.biometricAuthFailed,
        e,
        fields: {LogField.reason: 'authenticate'},
      );
    } finally {
      _authenticating = false;
    }
  }

  /// 恢复路径一：用系统锁屏凭据（PIN/图案/密码）验证身份后解锁。
  /// 不写入任何偏好——验证通过只代表"这次是本人"，不代表可以关闭保护。
  Future<void> _unlockWithDeviceCredential() async {
    if (_authenticating) return;
    setState(() {
      _authenticating = true;
      _noDeviceCredential = false;
    });
    try {
      final reason = (AppLocalizations.of(context) ?? l10nZh).unlockReason;
      final ok = await widget.authenticateWithDeviceCredential(reason);
      if (mounted && ok) {
        setState(() {
          _authed = true;
          _unavailable = false;
        });
      }
    } on BiometricUnavailableException {
      if (mounted) setState(() => _noDeviceCredential = true);
    } catch (e) {
      AppLog.failure(
        LogEvent.biometricUnlockFailed,
        e,
        fields: {LogField.reason: 'device_credential'},
      );
    } finally {
      if (mounted) setState(() => _authenticating = false);
    }
  }

  /// 恢复路径二（破坏性）：清除本机受保护数据后关闭门禁。
  /// 这是唯一免验证放行的路径——前提是凭证与设备记录已经删除（无可暴露的数据）。
  Future<void> _wipeAndDisable() async {
    final l10n = AppLocalizations.of(context) ?? l10nZh;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        // 200% 字体/横屏下内容会超出可视区：允许滚动，按钮始终可达（PR22/F25）。
        scrollable: true,
        title: Text(l10n.biometricWipeDataConfirmTitle),
        content: Text(l10n.biometricWipeDataConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.biometricWipeCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.biometricWipeDataConfirmAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _wipeBusy = true);
    try {
      await widget.wipeProtectedData();
      // 锁定擦除同样清掉 WebView 本地存储（PR20/F19）：设备都删了，
      // 旧凭证留下的 Cookie/DOM storage/缓存不能继续留在磁盘上。
      await WebViewStorage.clearForCredentialChange();
      ref.read(observerStatsProvider.notifier).clear();
      await ref.read(biometricProvider.notifier).set(false);
      if (mounted) {
        setState(() {
          _authed = true;
          _unavailable = false;
          _noDeviceCredential = false;
        });
      }
    } catch (e) {
      AppLog.failure(
        LogEvent.protectedDataWipeFailed,
        e,
        fields: {LogField.reason: 'wipe'},
      );
    } finally {
      if (mounted) setState(() => _wipeBusy = false);
    }
  }

  /// 安全偏好读取失败后的重试：只有确实读到值才解除"读取失败"状态。
  Future<void> _retrySecurityPref() async {
    final ok = await ref.read(biometricProvider.notifier).reload();
    if (!mounted || !ok) return;
    ref.read(securityPrefUnreadableProvider.notifier).setUnreadable(false);
    setState(() {});
    if (ref.read(biometricProvider)) _unlock();
  }

  /// 锁屏恢复出口（v1.1.8）：用户明确确认后清除安全设置并进入应用。
  ///
  /// SharedPreferences 损坏时读取永远失败，fail-closed 会把用户永久挡在
  /// 门外。此操作不是静默绕过：需要二次确认、记结构化日志（SL904）、并且
  /// 结果如实反映为"指纹锁关闭"——用户在设置里重新打开时会清掉确认标记，
  /// 恢复正常的 fail-closed 语义。
  Future<void> _resetSecurityPref() async {
    final l10n = AppLocalizations.of(context) ?? l10nZh;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: Text(l10n.securityResetConfirmTitle),
        content: Text(l10n.securityResetConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.securityResetConfirmAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // 尽量把"关闭"写回 prefs；写不进去（后端仍损坏）就把确认标记写进
    // 独立的安全存储后端，保证重启后不再锁死。
    var prefsWriteOk = true;
    try {
      await ref.read(biometricProvider.notifier).set(false);
    } catch (_) {
      prefsWriteOk = false;
    }
    if (!prefsWriteOk) {
      try {
        await DeviceStore.instance.setSecurityResetAcknowledged(true);
      } catch (_) {}
    }
    AppLog.event(LogEvent.securityPrefReset, level: LogLevel.warn, fields: {
      LogField.ok: prefsWriteOk,
      LogField.reason: prefsWriteOk ? 'prefs_written' : 'secure_ack',
    });
    if (!mounted) return;
    ref.read(securityPrefUnreadableProvider.notifier).setUnreadable(false);
    setState(() {
      _authed = true;
      _unavailable = false;
      _noDeviceCredential = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(biometricProvider);
    // 用户在设置里开启门禁时，刚刚的那次系统验证就是本次会话的解锁凭据；
    // 否则开启瞬间会把自己锁在门外（ref.listen 只在状态变化时触发）。
    ref.listen<bool>(biometricProvider, (_, next) {
      if (next && !_authed) {
        _adoptRecentAuthIfEnabled(next);
        if (_authed) setState(() {});
      }
    });
    final prefUnreadable = ref.watch(securityPrefUnreadableProvider);
    // fail-closed：读不到安全偏好时同样锁定，直到重试成功。
    final locked = (enabled || prefUnreadable) && !_authed;
    final l10n = AppLocalizations.of(context) ?? l10nZh;
    if (!locked) return widget.child;
    // Do not keep the protected subtree as a sibling under a visual overlay.
    // Returning only the lock screen disposes AppShell and its WebView
    // resources until authentication succeeds.
    return BlockSemantics(
      blocking: true,
      child: Scaffold(
        backgroundColor: context.zt.bg,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, viewport) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: viewport.maxHeight),
                child: Align(
                  alignment: const Alignment(0, -0.55),
                  child: SizedBox(
                    width: double.infinity,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Image.asset(
                            'assets/brand/mark.png',
                            width: 72,
                            height: 72,
                          ),
                          const SizedBox(height: 20),
                          Text(
                            'ZCODE',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 6,
                              color: context.zt.textLo,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            l10n.lockTitle,
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                              color: context.zt.textHi,
                            ),
                          ),
                          const SizedBox(height: 28),
                          if (prefUnreadable) ...[
                            Text(
                              l10n.securityPrefUnreadable,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13,
                                color: context.zt.danger,
                              ),
                            ),
                            const SizedBox(height: 16),
                            OutlinedButton(
                              onPressed: _retrySecurityPref,
                              child: Text(l10n.retry),
                            ),
                            const SizedBox(height: 8),
                            // 恢复出口（v1.1.8）：SharedPreferences 损坏时重试
                            // 永远不会成功，必须给用户一条明确的、带二次确认的
                            // 出路——而不是 fail-closed 永久锁死（真机反馈）。
                            OutlinedButton(
                              onPressed: _resetSecurityPref,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: context.zt.danger,
                              ),
                              child: Text(l10n.securityResetAction),
                            ),
                            const SizedBox(height: 12),
                          ] else if (_unavailable) ...[
                            Text(
                              l10n.biometricGateUnavailable,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13,
                                color: context.zt.danger,
                              ),
                            ),
                            if (_noDeviceCredential) ...[
                              const SizedBox(height: 8),
                              Text(
                                l10n.biometricNoDeviceCredential,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: context.zt.danger,
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            OutlinedButton(
                              onPressed: _authenticating
                                  ? null
                                  : _unlockWithDeviceCredential,
                              child: Text(l10n.biometricUseDeviceCredential),
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton(
                              onPressed: _wipeBusy ? null : _wipeAndDisable,
                              child: Text(l10n.biometricWipeDataButton),
                            ),
                            const SizedBox(height: 12),
                          ],
                          if (!prefUnreadable)
                            FilledButton.icon(
                              onPressed: _unlock,
                              icon: const Icon(Icons.lock_open, size: 18),
                              label: Text(l10n.unlockButton),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

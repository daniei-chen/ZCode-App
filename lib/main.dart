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
import 'state/app_lifecycle.dart';
import 'state/protected_wipe.dart';
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
        // 设备库完整性（iter16）：生产路径用 seed 构造 DeviceListNotifier，
        // `_load()` 不执行也就没人 report——这里把首帧前那次真实加载的
        // skippedRecords/repaired 注入 provider，诊断页/诊断包才看得到
        // 本次启动发生过隔离/修复（而非恒报 0/no）。存储不可用（unavailable）
        // 时注入 null：那是"什么都没读到"，不是"读过且干净"（复核返修）。
        deviceStoreIntegrityProvider.overrideWith(
          () => DeviceStoreIntegrityNotifier(
            initial: initialDevicesResult.unavailable
                ? null
                : DeviceStoreIntegrity(
                    skippedRecords: initialDevicesResult.skippedRecords,
                    repaired: initialDevicesResult.repaired,
                  ),
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
    this.wipeProtectedData,
  });

  final Widget child;

  final Duration relockAfter;

  final Future<bool> Function(String reason) authenticate;

  /// 恢复路径：生物识别不可用时，必须用系统锁屏凭据验证身份才解锁。
  final Future<bool> Function(String reason) authenticateWithDeviceCredential;

  /// 破坏性恢复路径的替身（仅测试注入）；返回"全部必需项是否成功"。
  ///
  /// 生产为 null：实际执行 [ProtectedStateWipe.run]（磁盘 + 内存 Provider +
  /// WebView 站点数据 + 通知的完整擦除事务），并按其
  /// `WipeResult.allRequiredSucceeded` 决定是否放行（R-04 / R-17）。
  final Future<bool> Function()? wipeProtectedData;

  static Future<bool> _defaultAuthenticate(String reason) =>
      BiometricService.instance.authenticate(reason);

  static Future<bool> _defaultDeviceCredentialAuthenticate(String reason) =>
      BiometricService.instance.authenticateWithDeviceCredential(reason);

  @override
  ConsumerState<BiometricGate> createState() => _BiometricGateState();
}

enum _LockPanel { main, recoveryConfirm, wipeConfirm }

class _BiometricGateState extends ConsumerState<BiometricGate>
    with WidgetsBindingObserver {
  bool _authed = false;
  bool _authenticating = false;
  bool _startupPrompted = false;
  /// 用户离开（inactive/hidden/paused）的单调计时 + 墙钟时刻（iter12
  /// W-021 + 复核 P2）：resumed 时取出并清空，离开时长取双钟证据
  /// （[BiometricService.relockEvidence]），深睡与回拨两洞同堵。
  Stopwatch? _awayFor;

  DateTime? _leftAtWall;
  bool _authCovered = false;
  bool _unavailable = false;
  bool _noDeviceCredential = false;
  bool _wipeBusy = false;
  bool _wipeFailed = false;
  bool _recoveryDenied = false;
  bool _writeFailed = false;

  /// 锁屏内的确认面板（R-02）。
  ///
  /// 锁屏在 `MaterialApp.builder` 之上、Navigator 之外：这里**不能**用
  /// `showDialog`（审计复现：Gate 的 context 上 `Navigator.maybeOf` 为 null，
  /// 恢复对话框在真实拓扑下抛 FlutterError）。确认改用锁屏内的内联面板，
  /// 不依赖任何 Navigator，也不会把受保护内容留在"锁屏之上的 route"里。
  _LockPanel _panel = _LockPanel.main;

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
    final svc = BiometricService.instance;
    if (svc.sinceLastSuccess == null && svc.lastSuccessAt == null) return;
    final evidence = BiometricService.relockEvidence(
      monotonic: svc.sinceLastSuccess,
      wallSince: svc.lastSuccessAt,
      now: DateTime.now(),
    );
    if (evidence >= widget.relockAfter) return;
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
        // 离开时长用单调时钟计量（iter12 W-021）：墙钟回拨会缩短"离开"
        // 时长，让 relock 窗口被续期。
        _awayFor ??= (Stopwatch()..start());
        _leftAtWall ??= DateTime.now();
      }
    } else if (state == AppLifecycleState.resumed) {
      final covered = _authCovered;
      _authCovered = false;
      final awayWatch = _awayFor;
      final leftWall = _leftAtWall;
      _awayFor = null;
      _leftAtWall = null;
      if (ref.read(securityPrefUnreadableProvider)) return;
      if (!ref.read(biometricProvider)) return;
      if (!_startupPrompted) return;
      if (covered) {
        return;
      }
      final since = BiometricService.instance.sinceLastSuccess;
      if (since != null && since < widget.relockAfter) {
        return;
      }
      final away = (awayWatch == null && leftWall == null)
          ? widget.relockAfter
          : BiometricService.relockEvidence(
              monotonic: awayWatch?.elapsed,
              wallSince: leftWall,
              now: DateTime.now(),
            );
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
  /// 这是唯一免验证放行的路径——前提是受保护状态**全部**已删除
  /// （磁盘 + 内存 Provider + WebView 站点数据 + 通知），任一环节失败
  /// 都保持锁定（R-03/R-04：不允许"部分清除"放行）。
  ///
  /// 只负责展示内联确认面板（R-02，不用 showDialog）；真正的擦除在用户
  /// 点"清除并关闭"后由 [_confirmWipe] 执行。
  void _wipeAndDisable() {
    setState(() {
      _panel = _LockPanel.wipeConfirm;
      _wipeFailed = false;
    });
  }

  /// 内联面板"清除并关闭"的确认动作（R-02/R-03/R-04；失败语义按 R-17 收紧）。
  ///
  /// 只有擦除事务**全部必需项成功**（[WipeResult.allRequiredSucceeded]）才
  /// 关闭门禁；任一项失败保持锁定并显示可重试状态（复审 P1-03：旧实现只对
  /// 磁盘路径 fail-closed，站点数据/通知失败会被静默放行）。
  Future<void> _confirmWipe() async {
    if (_wipeBusy) return;
    setState(() {
      _panel = _LockPanel.main;
      _wipeBusy = true;
      _wipeFailed = false;
    });
    try {
      final injected = widget.wipeProtectedData;
      bool allOk;
      if (injected != null) {
        // 测试替身：返回是否"全部必需项成功"。
        allOk = await injected();
      } else {
        // 生产：完整擦除事务（内存 Provider + 磁盘 + 站点数据 + 通知）。
        final container = ProviderScope.containerOf(context, listen: false);
        final result = await ProtectedStateWipe.run(container);
        allOk = result.allRequiredSucceeded;
        if (!allOk) {
          AppLog.event(
            LogEvent.protectedDataWipeFailed,
            level: LogLevel.warn,
            fields: {
              LogField.reason:
                  'wipe_incomplete_${result.failedSteps.map((s) => s.tag).join('_')}',
              LogField.count: result.failedSteps.length,
            },
          );
        }
      }
      if (!allOk) {
        // 存在残留（或无法证明已清除）：保持锁定，允许重试。
        if (mounted) setState(() => _wipeFailed = true);
        return;
      }
      // 安全偏好写不动也不影响"就此放行"：受保护状态已证明全部清除，
      // 没有数据可暴露。写失败只意味着下次启动仍走恢复流程。
      try {
        await ref.read(biometricProvider.notifier).set(false);
      } catch (_) {}
      if (mounted) {
        setState(() {
          _authed = true;
          _unavailable = false;
          _noDeviceCredential = false;
        });
      }
    } catch (e) {
      // 事务自身异常（理论上 run 不抛；兜底同样保持锁定）。
      logWipeFailure(e, 'wipe_transaction');
      if (mounted) setState(() => _wipeFailed = true);
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

  /// 锁屏恢复出口（R-03 重定）：偏好损坏时不再允许免验证关闭门禁。
  ///
  /// 只提供两条路径，且都必须先证明"这次是本人"或"数据已不存在"：
  ///
  ///   A. 用系统锁屏凭据（PIN/图案/密码）验证身份 → 关闭故障的安全偏好，
  ///      设备与链接保持不变（用户还能继续用已保存的设备）；
  ///   B. 清除全部受保护数据（[_confirmWipe]）→ 数据没了，免验证放行成立。
  ///
  /// 持久化失败时的语义：prefs 写不动就写独立的安全存储 marker；两条都写
  /// 不进去时**不放行**——不能谎报"已关闭保护"然后重启又被锁死。
  ///
  /// 确认同样走内联面板（R-02），不依赖 Navigator。
  Future<void> _recoverByVerifyingIdentity() async {
    setState(() {
      _panel = _LockPanel.recoveryConfirm;
      _recoveryDenied = false;
      _writeFailed = false;
    });
  }

  /// 内联面板"验证并关闭"的确认动作（R-03）。
  Future<void> _confirmRecoveryVerify() async {
    if (_wipeBusy) return;
    final l10n = AppLocalizations.of(context) ?? l10nZh;
    setState(() {
      _panel = _LockPanel.main;
      _wipeBusy = true;
      _recoveryDenied = false;
      _writeFailed = false;
    });
    try {
      // 第一步：系统凭据验证身份。取消/失败都保持锁定。
      final verified =
          await widget.authenticateWithDeviceCredential(l10n.unlockReason);
      if (!mounted) return;
      if (!verified) {
        AppLog.event(LogEvent.securityRecoveryDenied, level: LogLevel.warn,
            fields: {LogField.reason: 'not_verified'});
        setState(() => _recoveryDenied = true);
        return;
      }

      // 第二步：验证通过才允许写"关闭"。prefs → 独立 marker 双写，
      // 两条都失败则保持锁定（fail-closed，不谎报成功）。
      var prefsWriteOk = false;
      try {
        await ref.read(biometricProvider.notifier).set(false);
        prefsWriteOk = true;
      } catch (_) {}
      var markerWriteOk = false;
      try {
        await DeviceStore.instance.setSecurityResetAcknowledged(true);
        markerWriteOk = true;
      } catch (_) {}
      AppLog.event(LogEvent.securityRecoveryVerified, fields: {
        LogField.ok: prefsWriteOk,
        LogField.reason: prefsWriteOk
            ? 'verified_prefs_written'
            : (markerWriteOk ? 'verified_secure_ack' : 'verified_write_failed'),
      });
      if (!mounted) return;
      if (!prefsWriteOk && !markerWriteOk) {
        // 无法持久化"已关闭"：重启后仍会进入恢复流程。不放行。
        setState(() => _writeFailed = true);
        return;
      }
      ref.read(securityPrefUnreadableProvider.notifier).setUnreadable(false);
      setState(() {
        _authed = true;
        _unavailable = false;
        _noDeviceCredential = false;
        _recoveryDenied = false;
      });
    } on BiometricUnavailableException {
      // 没有可用的系统凭据：只能走清除数据路径，如实告知。
      if (mounted) setState(() => _noDeviceCredential = true);
    } catch (e) {
      AppLog.failure(
        LogEvent.securityRecoveryDenied,
        e,
        fields: {LogField.reason: 'verify_error'},
      );
      if (mounted) setState(() => _recoveryDenied = true);
    } finally {
      if (mounted) setState(() => _wipeBusy = false);
    }
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
                          // 确认面板（R-02）：锁屏在 Navigator 之外，确认必须
                          // 内联渲染，不能走 showDialog/AlertDialog route。
                          if (_panel == _LockPanel.recoveryConfirm)
                            _inlineConfirmPanel(
                              title: l10n.securityRecoveryVerifyTitle,
                              body: l10n.securityRecoveryVerifyBody,
                              cancelLabel: l10n.commonCancel,
                              confirmLabel:
                                  l10n.securityRecoveryVerifyConfirmAction,
                              onCancel: () =>
                                  setState(() => _panel = _LockPanel.main),
                              onConfirm: _confirmRecoveryVerify,
                              busy: _wipeBusy,
                            )
                          else if (_panel == _LockPanel.wipeConfirm)
                            _inlineConfirmPanel(
                              title: l10n.biometricWipeDataConfirmTitle,
                              body: l10n.biometricWipeDataConfirmBody,
                              cancelLabel: l10n.biometricWipeCancel,
                              confirmLabel:
                                  l10n.biometricWipeDataConfirmAction,
                              onCancel: () =>
                                  setState(() => _panel = _LockPanel.main),
                              onConfirm: _confirmWipe,
                              busy: _wipeBusy,
                              destructive: true,
                            )
                          else ...[
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
                            // 恢复出口（R-03）：先验证身份 → 关闭故障的安全
                            // 偏好，设备与链接都保留。不再提供免验证关闭。
                            OutlinedButton(
                              onPressed: _wipeBusy
                                  ? null
                                  : _recoverByVerifyingIdentity,
                              child: Text(l10n.securityRecoveryVerifyAction),
                            ),
                            const SizedBox(height: 8),
                            // 第二条路径：清除全部受保护数据后免验证放行。
                            OutlinedButton(
                              onPressed: _wipeBusy ? null : _wipeAndDisable,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: context.zt.danger,
                              ),
                              child: Text(l10n.biometricWipeDataButton),
                            ),
                            if (_recoveryDenied) ...[
                              const SizedBox(height: 8),
                              Text(
                                l10n.securityRecoveryDenied,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: context.zt.danger,
                                ),
                              ),
                            ],
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
                            if (_writeFailed) ...[
                              const SizedBox(height: 8),
                              Text(
                                l10n.securityRecoveryWriteFailed,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: context.zt.danger,
                                ),
                              ),
                            ],
                            if (_wipeFailed) ...[
                              const SizedBox(height: 8),
                              Text(
                                l10n.securityRecoveryWipeFailed,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: context.zt.danger,
                                ),
                              ),
                            ],
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
                            if (_wipeFailed) ...[
                              const SizedBox(height: 8),
                              Text(
                                l10n.securityRecoveryWipeFailed,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: context.zt.danger,
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                          ],
                          if (!prefUnreadable)
                            FilledButton.icon(
                              onPressed: _unlock,
                              icon: const Icon(Icons.lock_open, size: 18),
                              label: Text(l10n.unlockButton),
                            ),
                          ],
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

  /// 锁屏内联确认面板（R-02）：与 AlertDialog 同构的视觉块，但不依赖
  /// Navigator——锁屏位于 `MaterialApp.builder` 时 `Navigator.maybeOf` 为
  /// null，任何 `showDialog` 都会抛 FlutterError（审计复现）。
  Widget _inlineConfirmPanel({
    required String title,
    required String body,
    required String cancelLabel,
    required String confirmLabel,
    required VoidCallback onCancel,
    required VoidCallback onConfirm,
    required bool busy,
    bool destructive = false,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.zt.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.zt.hairline),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: context.zt.textHi,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: TextStyle(fontSize: 13, color: context.zt.textLo),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: busy ? null : onCancel,
                child: Text(cancelLabel),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: busy ? null : onConfirm,
                style: destructive
                    ? TextButton.styleFrom(
                        foregroundColor: context.zt.danger,
                      )
                    : null,
                child: Text(confirmLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

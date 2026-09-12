import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import 'l10n/app_localizations.dart';
import 'models/device.dart';
import 'models/device_label.dart';
import 'services/biometric.dart';
import 'services/device_store.dart';
import 'services/notifier.dart';
import 'state/session_pool.dart';
import 'state/startup_target.dart';
import 'state/theme_mode.dart';
import 'theme.dart';
import 'state/app_lifecycle.dart';
import 'ui/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = DeviceStore.instance;
  // Start all small persistence reads together. Android keeps the launch
  // window visible until the first Flutter frame; serial secure-storage and
  // SharedPreferences reads made that window feel like a second splash.
  unawaited(NotifierService.instance.init());
  final devicesFuture = _safeDevices(store.loadAll());
  final lastDeviceFuture = _safeLastDevice(store.lastDeviceId());
  final biometricFuture = _safeBool(store.biometricEnabled());
  final themeModeFuture = _safeString(store.themeModeSetting(), 'system');
  final startupTargetFuture = _safeString(store.startupTarget(), 'lastDevice');

  // Resolve the saved devices before the first Flutter frame. Otherwise the
  // provider briefly reports an empty list and paints the import launcher
  // before switching to the last WebView a moment later.
  final initialDevices = await devicesFuture;
  final lastDeviceId = await lastDeviceFuture;
  final initialBiometric = await biometricFuture;
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
        biometricProvider.overrideWith(
          () => BiometricNotifier(initial: initialBiometric),
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

Future<List<RemoteDevice>> _safeDevices(
  Future<List<RemoteDevice>> future,
) async {
  try {
    return await future;
  } catch (_) {
    return const <RemoteDevice>[];
  }
}

Future<String?> _safeLastDevice(Future<String?> future) async {
  try {
    return await future;
  } catch (_) {
    return null;
  }
}

Future<bool> _safeBool(Future<bool> future) async {
  try {
    return await future;
  } catch (_) {
    return false;
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
          child: child ?? const SizedBox.shrink(),
        );
      },
      // Put the gate above AppShell in the route tree. When the app is locked,
      // AppShell is not built at all, so relay connections and WebViews
      // cannot start underneath a visual overlay.
      home: LifecycleWatcher(
        child: BiometricGate(child: AppShell(startAtLauncher: startAtLauncher)),
      ),
    );
  }
}

class BiometricGate extends ConsumerStatefulWidget {
  const BiometricGate({
    super.key,
    required this.child,
    this.relockAfter = const Duration(seconds: 10),
    this.authenticate = _defaultAuthenticate,
  });

  final Widget child;

  final Duration relockAfter;

  final Future<bool> Function(String reason) authenticate;

  static Future<bool> _defaultAuthenticate(String reason) =>
      BiometricService.instance.authenticate(reason);

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _startupPrompted = true;
      if (ref.read(biometricProvider)) _unlock();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
      debugPrint('[ZR] biometric authentication failed: $e');
    } finally {
      _authenticating = false;
    }
  }

  Future<void> _disableAfterUnavailable() async {
    await ref.read(biometricProvider.notifier).set(false);
    if (mounted) {
      setState(() {
        _authed = true;
        _unavailable = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(biometricProvider);
    final locked = enabled && !_authed;
    final l10n = AppLocalizations.of(context) ?? l10nZh;
    if (!locked) return widget.child;
    // Do not keep the protected subtree as a sibling under a visual overlay.
    // Returning only the lock screen disposes AppShell and its relay/WebView
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
                          if (_unavailable) ...[
                            Text(
                              l10n.biometricGateUnavailable,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13,
                                color: context.zt.danger,
                              ),
                            ),
                            const SizedBox(height: 16),
                            OutlinedButton(
                              onPressed: _disableAfterUnavailable,
                              child: Text(l10n.biometricDisableButton),
                            ),
                            const SizedBox(height: 12),
                          ],
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

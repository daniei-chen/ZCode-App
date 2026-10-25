import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../l10n/app_localizations.dart';
import '../services/app_log.dart';
import '../services/app_settings.dart';
import '../services/battery_optimization.dart';
import '../services/bridge_schema.dart';
import '../services/diagnostics_bundle.dart';
import '../services/monitor_state_store.dart';
import '../state/device_directory.dart';
import 'account_login_page.dart';
import '../services/structured_log.dart';
import '../services/update_service.dart';
import '../services/webview_storage.dart';
import '../state/bridge_health.dart';
import '../state/observer_stats.dart';
import '../state/session_pool.dart';
import '../state/session_status.dart';
import '../theme.dart';

/// 诊断中心（v1.1.0）：只读状态页 + 用户主动导出日志。
///
/// 硬规则：不显示 sid/hash/remoteControlToken、控制链接、会话标题与正文、
/// 网络 payload（含 query）。只呈现版本号/枚举状态/数字计数。
class DiagnosticsPage extends ConsumerStatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  ConsumerState<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends ConsumerState<DiagnosticsPage> {
  String _version = '';
  String _buildNumber = '';
  Map<String, Object?> _android = const {};
  Map<String, String> _monitorStates = const {};
  bool? _notifEnabled;
  bool? _batteryIgnored;
  String? _updateStatus;
  bool _checkingUpdate = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _version = info.version;
      _buildNumber = info.buildNumber;
    } catch (_) {}
    final android = await AppSettings.androidInfo();
    final notif = await AppSettings.notificationsEnabled();
    final battery =
        await BatteryOptimizationService.isIgnoringBatteryOptimizations();
    // 头无监控引擎的状态经 SharedPreferences 跨隔离体共享（v1.4.0）。
    final monitor = await MonitorStateStore.readDevices();
    if (!mounted) return;
    setState(() {
      _android = android;
      _notifEnabled = notif;
      _batteryIgnored = battery;
      _monitorStates = monitor;
    });
  }

  Future<void> _checkUpdate() async {
    setState(() => _checkingUpdate = true);
    final result = await UpdateService.instance.checkForUpdate();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _checkingUpdate = false;
      final latest = result.latestVersion ?? '';
      _updateStatus = switch (result.status) {
        UpdateCheckStatus.upToDate => l10n.diagnosticsUpdateUpToDate,
        UpdateCheckStatus.updateAvailable =>
          result.canDownload
              ? l10n.diagnosticsUpdateDownloadable(latest)
              : l10n.diagnosticsUpdateManual(latest),
        UpdateCheckStatus.noRelease => l10n.diagnosticsUpdateNoRelease,
        UpdateCheckStatus.failed => l10n.diagnosticsUpdateFailed,
      };
    });
  }

  Future<void> _copyLogs() async {
    final l10n = AppLocalizations.of(context)!;
    await Clipboard.setData(ClipboardData(text: AppLog.export()));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.diagnosticsCopied)));
  }

  /// 复制脱敏诊断包（PR20/F19）：一次性给出版本/平台/设备短 id/设置/计数/日志。
  /// 内容由 `DiagnosticsBundle` 组装，只接受归一化字段，并在渲染时再过一次脱敏。
  Future<void> _copyBundle() async {
    final l10n = AppLocalizations.of(context)!;
    final bundle = DiagnosticsBundle.render(_buildBundle());
    await Clipboard.setData(ClipboardData(text: bundle));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.diagnosticsBundleCopied)),
    );
  }

  DiagnosticsInputs _buildBundle() {
    final devices = ref.read(deviceListProvider);
    final statuses = ref.read(sessionStatusProvider);
    final stats = ref.read(observerStatsProvider);
    return DiagnosticsBundle.capture(
      appVersion: _version,
      buildNumber: _buildNumber,
      android: _android,
      deviceIds: devices.map((d) => d.id).toList(growable: false),
      statuses: {
        for (final entry in statuses.entries) entry.key: entry.value.name,
      },
      stats: {
        for (final entry in stats.entries) entry.key: entry.value.counters,
      },
      bridgeHealth: {
        for (final entry in ref.read(bridgeHealthProvider).entries)
          entry.key: entry.value.ready ? 'ok' : 'missing',
      },
      biometric: ref.read(biometricProvider),
      notificationsEnabled: _notifEnabled ?? false,
      batteryIgnored: _batteryIgnored ?? false,
    );
  }

  String _monitorStateLabel(AppLocalizations l10n, String raw) =>
      switch (raw) {
        'paired' => l10n.diagnosticsMonitorPaired,
        'waiting' => l10n.diagnosticsMonitorWaiting,
        'authMissing' => l10n.diagnosticsMonitorAuthMissing,
        'connecting' || 'authenticating' => l10n.diagnosticsMonitorConnecting,
        'disconnected' => l10n.diagnosticsMonitorDisconnected,
        _ => raw,
      };

  String _statusLabel(AppLocalizations l10n, SessionStatus? status) =>
      switch (status) {
        SessionStatus.live => l10n.diagnosticsStatusLive,
        SessionStatus.loading => l10n.diagnosticsStatusLoading,
        SessionStatus.error => l10n.diagnosticsStatusError,
        null => '—',
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final palette = context.zt;
    final devices = ref.watch(deviceListProvider);
    final active = ref.watch(activeTabProvider);
    final statuses = ref.watch(sessionStatusProvider);
    final biometric = ref.watch(biometricProvider);
    final logs = AppLog.snapshot().reversed.take(120).toList();
    final bridge = ref.watch(bridgeHealthProvider);
    final deviceStats = ref.watch(observerStatsProvider).values.toList()
      ..sort((a, b) => a.deviceId.compareTo(b.deviceId));

    return Scaffold(
      backgroundColor: palette.bg,
      appBar: AppBar(
        backgroundColor: palette.bg,
        elevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: palette.textLo),
        title: Text(
          l10n.diagnosticsTitle,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            color: palette.textHi,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 40),
        children: [
          _section(palette, l10n.diagnosticsSectionApp),
          _row(
            palette,
            l10n.diagnosticsAppVersion,
            _version.isEmpty ? '…' : 'v$_version+$_buildNumber',
          ),
          _section(palette, l10n.diagnosticsSectionEnvironment),
          _row(
            palette,
            'Android',
            '${_android['release'] ?? '?'}（API ${_android['sdkInt'] ?? '?'}）',
          ),
          _row(
            palette,
            'WebView Chromium',
            '${_android['webViewChrome'] ?? '?'}',
          ),
          _section(palette, l10n.diagnosticsSectionDevices),
          _row(palette, l10n.diagnosticsDeviceCount, '${devices.length}'),
          _row(
            palette,
            l10n.diagnosticsActiveDevice,
            devices.isEmpty
                ? l10n.diagnosticsNoDevices
                : (active >= 0 && active < devices.length
                      ? devices[active].label
                      : '—'),
          ),
          for (final d in devices)
            _row(
              palette,
              d.label,
              '${_statusLabel(l10n, statuses[d.id])}'
                  '${bridge[d.id] != null ? ' · bridge=${bridge[d.id]!.ready ? 'ok' : 'missing'}' : ''}',
            ),
          const _HealthCheckCard(),
          _section(palette, l10n.diagnosticsSectionMonitor),
          for (final entry in _monitorStates.entries)
            _row(
              palette,
              LogRedactor.shortId(entry.key),
              _monitorStateLabel(l10n, entry.value),
            ),
          if (_monitorStates.isEmpty)
            _row(palette, l10n.diagnosticsMonitorNone, '—'),
          _section(palette, l10n.diagnosticsSectionNotifications),
          _row(
            palette,
            l10n.diagnosticsNotifPermission,
            _notifEnabled == null
                ? '…'
                : (_notifEnabled!
                      ? l10n.diagnosticsEnabled
                      : l10n.diagnosticsDisabled),
          ),
          _section(palette, l10n.diagnosticsSectionBackground),
          _row(
            palette,
            l10n.diagnosticsBatteryIgnored,
            _batteryIgnored == null
                ? '…'
                : (_batteryIgnored!
                      ? l10n.diagnosticsEnabled
                      : l10n.diagnosticsDisabled),
          ),
          _section(palette, l10n.diagnosticsSectionSecurity),
          _row(
            palette,
            l10n.diagnosticsBiometric,
            biometric ? l10n.diagnosticsEnabled : l10n.diagnosticsDisabled,
          ),
          _row(
            palette,
            l10n.diagnosticsRecentsCover,
            biometric ? l10n.diagnosticsEnabled : l10n.diagnosticsDisabled,
          ),
          _section(palette, l10n.diagnosticsSectionUpdate),
          _row(
            palette,
            l10n.diagnosticsUpdateStatus,
            _updateStatus ?? l10n.diagnosticsUpdateNotChecked,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                onPressed: _checkingUpdate ? null : _checkUpdate,
                child: Text(l10n.diagnosticsCheckUpdateNow),
              ),
            ),
          ),
          _section(palette, l10n.diagnosticsSectionObserver),
          _row(
            palette,
            l10n.diagnosticsBridgeDropped,
            '${BridgeSchema.droppedMessages}',
          ),
          if (deviceStats.isEmpty)
            _row(palette, l10n.diagnosticsSectionObserver, '—')
          else
            for (final device in deviceStats)
              for (final entry in device.counters.entries)
                _row(
                  palette,
                  '${LogRedactor.shortId(device.deviceId)}·${entry.key}',
                  '${entry.value}',
                ),
          _section(palette, l10n.diagnosticsSectionStorage),
          for (final entry in WebViewStorage.inventory.entries)
            _row(palette, entry.key, entry.value),
          _section(palette, l10n.diagnosticsSectionLogs),
          _row(
            palette,
            l10n.diagnosticsDebugDropped,
            '${AppLog.droppedInRelease}',
          ),
          if (logs.isEmpty)
            _row(palette, l10n.diagnosticsSectionLogs, l10n.diagnosticsLogsEmpty)
          else
            for (final line in logs)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Text(
                  line,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.3,
                    color: palette.textLo,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _copyLogs,
                  icon: const Icon(Icons.copy_all_outlined, size: 18),
                  label: Text(l10n.diagnosticsCopyLogs),
                ),
                OutlinedButton.icon(
                  onPressed: _copyBundle,
                  icon: const Icon(Icons.description_outlined, size: 18),
                  label: Text(l10n.diagnosticsCopyBundle),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(ZTPalette palette, String label) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 14, 2, 6),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: palette.textHi,
      ),
    ),
  );

  Widget _row(ZTPalette palette, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(fontSize: 13, color: palette.textLo),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 13, color: palette.textHi),
          ),
        ),
      ],
    ),
  );
}

/// 一键体检（v1.6.0）：把"没通知"的排查压成一次点击——
/// 通知权限 → 电池白名单 → 登录令牌 → 监控引擎 → 命令通道，
/// 逐项 ✅/⚠/❌ 并给修复动作；硬项全过即"通知链路正常"。
enum _HealthState { idle, running, done }

class _HealthCheckCard extends ConsumerStatefulWidget {
  const _HealthCheckCard();

  @override
  ConsumerState<_HealthCheckCard> createState() => _HealthCheckCardState();
}

class _HealthCheckCardState extends ConsumerState<_HealthCheckCard> {
  _HealthState _state = _HealthState.idle;
  final Map<String, bool> _ok = {};
  final Map<String, bool> _soft = {};

  Future<void> _run() async {
    setState(() => _state = _HealthState.running);
    final ok = <String, bool>{};
    final soft = <String, bool>{};

    ok["notif"] = await AppSettings.notificationsEnabled();
    soft['battery'] = await BatteryOptimizationService
        .isIgnoringBatteryOptimizations();

    final dir = ref.read(deviceDirectoryProvider);
    var dirStatus = dir.status;
    if (dirStatus == DeviceDirectoryStatus.loading ||
        dirStatus == DeviceDirectoryStatus.error) {
      await ref.read(deviceDirectoryProvider.notifier).refresh();
      dirStatus = ref.read(deviceDirectoryProvider).status;
    }
    ok['token'] = dirStatus == DeviceDirectoryStatus.ready;

    final monitor = await MonitorStateStore.readDevices();
    ok['monitor'] = monitor.values.contains('paired');

    final agent = await MonitorStateStore.readAgentReady();
    soft['agent'] = agent.values.contains(true);

    if (!mounted) return;
    setState(() {
      _ok
        ..clear()
        ..addAll(ok);
      _soft
        ..clear()
        ..addAll(soft);
      _state = _HealthState.done;
    });
  }

  bool get _allHardPass => _ok.isNotEmpty && _ok.values.every((v) => v);

  Future<void> _fix(String key) async {
    switch (key) {
      case 'notif':
        await AppSettings.openNotifications();
      case 'battery':
        await BatteryOptimizationService.requestIgnoreBatteryOptimizations();
      case 'token':
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<bool>(builder: (_) => const AccountLoginPage()),
        );
        await ref.read(deviceDirectoryProvider.notifier).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final palette = context.zt;
    final rows = <(String, String, bool, bool)>[
      if (_state == _HealthState.done)
        ('notif', l10n.healthItemNotifPerm, _ok['notif'] ?? false, false),
      if (_state == _HealthState.done)
        ('battery', l10n.healthItemBattery, _soft['battery'] ?? false, true),
      if (_state == _HealthState.done)
        ('token', l10n.healthItemToken, _ok['token'] ?? false, false),
      if (_state == _HealthState.done)
        ('monitor', l10n.healthItemMonitor, _ok['monitor'] ?? false, false),
      if (_state == _HealthState.done)
        ('agent', l10n.healthItemAgent, _soft['agent'] ?? false, true),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.health_and_safety_outlined,
                    size: 19, color: palette.textHi),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.healthCheckTitle,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: palette.textHi,
                    ),
                  ),
                ),
                if (_state == _HealthState.done && _allHardPass)
                  Icon(Icons.check_circle, size: 18, color: palette.live)
                else if (_state == _HealthState.done)
                  Icon(Icons.error_outline, size: 18, color: palette.danger),
              ],
            ),
            if (_state == _HealthState.done)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _allHardPass ? l10n.healthOk : _firstFailure(l10n),
                  style: TextStyle(
                    fontSize: 12.5,
                    color: _allHardPass ? palette.live : palette.danger,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            for (final (key, label, pass, soft) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Icon(
                      pass
                          ? Icons.check
                          : soft
                              ? Icons.warning_amber_rounded
                              : Icons.cancel,
                      size: 15,
                      color: pass
                          ? palette.live
                          : soft
                              ? palette.warn
                              : palette.danger,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        soft && !pass
                            ? '$label · ${l10n.healthOptionalBattery}'
                            : label,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: palette.textLo,
                        ),
                      ),
                    ),
                    if (!pass && !soft)
                      TextButton(
                        onPressed: () => _fix(key),
                        child: Text(
                          key == 'notif'
                              ? l10n.healthFixNotif
                              : key == 'token'
                                  ? l10n.healthFixToken
                                  : key == 'monitor'
                                      ? l10n.healthFixOpenPage
                                      : l10n.healthFixBattery,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: palette.accent,
                  foregroundColor: palette.onAccent,
                ),
                onPressed: _state == _HealthState.running ? null : _run,
                child: Text(
                  _state == _HealthState.running
                      ? l10n.healthCheckRunning
                      : l10n.healthCheckRun,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _firstFailure(AppLocalizations l10n) {
    if (_ok['notif'] != true) return '${l10n.healthItemNotifPerm} ✗';
    if (_ok['token'] != true) return '${l10n.healthItemToken} ✗';
    if (_ok['monitor'] != true) return '${l10n.healthItemMonitor} ✗';
    return l10n.healthOk;
  }
}

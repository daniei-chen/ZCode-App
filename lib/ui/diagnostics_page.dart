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
import '../services/observer_alerts.dart';
import '../services/structured_log.dart';
import '../services/update_service.dart';
import '../services/webview_storage.dart';
import '../state/bridge_health.dart';
import '../state/observer_stats.dart';
import '../state/subframe_stats.dart';
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
    } catch (_) {
      _version = '?';
      _buildNumber = '?';
    }
    final android = await AppSettings.androidInfo();
    final notif = await AppSettings.notificationsEnabled();
    final battery =
        await BatteryOptimizationService.isIgnoringBatteryOptimizations();
    if (!mounted) return;
    setState(() {
      _android = android;
      _notifEnabled = notif;
      _batteryIgnored = battery;
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
    // 子 frame 取证计数随包导出（ADR-002 步骤 1）：真机/soak 证据链的一环。
    // 与 JS 观测计数按设备取并集合并，缺任一侧的设备也不丢行。
    final subFrames = ref.read(subFrameStatsProvider);
    return DiagnosticsBundle.capture(
      appVersion: _version,
      buildNumber: _buildNumber,
      android: _android,
      deviceIds: devices.map((d) => d.id).toList(growable: false),
      statuses: {
        for (final entry in statuses.entries) entry.key: entry.value.name,
      },
      stats: mergeObserverAndSubFrameStats(stats, subFrames),
      bridgeHealth: {
        for (final entry in ref.read(bridgeHealthProvider).entries)
          entry.key: entry.value.ready ? 'ok' : 'missing',
      },
      biometric: ref.read(biometricProvider),
      notificationsEnabled: _notifEnabled ?? false,
      batteryIgnored: _batteryIgnored ?? false,
      storeSkippedRecords: ref.read(deviceStoreIntegrityProvider)?.skippedRecords ?? 0,
      storeRepaired: ref.read(deviceStoreIntegrityProvider)?.repaired ?? false,
    );
  }

  String _statusLabel(AppLocalizations l10n, SessionStatus? status) =>
      switch (status) {
        SessionStatus.live => l10n.diagnosticsStatusLive,
        SessionStatus.loading => l10n.diagnosticsStatusLoading,
        SessionStatus.error => l10n.diagnosticsStatusError,
        null => '—',
      };

  String _alertLabel(AppLocalizations l10n, ObserverAlertCode code) =>
      switch (code) {
        ObserverAlertCode.sseAppeared => l10n.diagnosticsAlertSseAppeared,
        ObserverAlertCode.wsMissHigh => l10n.diagnosticsAlertWsMissHigh,
        ObserverAlertCode.fetchMissHigh => l10n.diagnosticsAlertFetchMissHigh,
        ObserverAlertCode.fragmentAnomaly =>
          l10n.diagnosticsAlertFragmentAnomaly,
        ObserverAlertCode.budgetDrop => l10n.diagnosticsAlertBudgetDrop,
        ObserverAlertCode.bridgeDrop => l10n.diagnosticsAlertBridgeDrop,
        ObserverAlertCode.subFrameBlocked =>
          l10n.diagnosticsAlertSubFrameBlocked,
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
    final subFrameDevices = ref
        .watch(subFrameStatsProvider)
        .entries
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    // 观察面告警（W-005）：与诊断包同一份纯策略，输入是合并后的计数。
    final appAlerts = ObserverAlertPolicy.evaluateApp(
      droppedMessages: BridgeSchema.droppedMessages,
    );
    final deviceAlerts = mergeObserverAndSubFrameStats(
      ref.watch(observerStatsProvider),
      ref.watch(subFrameStatsProvider),
    ).entries.map((e) => MapEntry(e.key, ObserverAlertPolicy.evaluate(e.value))).toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final anyAlert =
        appAlerts.isNotEmpty || deviceAlerts.any((e) => e.value.isNotEmpty);

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
          _section(palette, l10n.diagnosticsSectionAlerts),
          if (!anyAlert)
            _row(palette, l10n.diagnosticsSectionAlerts, l10n.diagnosticsAlertsNone)
          else ...[
            for (final alert in appAlerts)
              _row(
                palette,
                'app·${alert.code.code}',
                '${_alertLabel(l10n, alert.code)} · ${alert.value}',
              ),
            for (final device in deviceAlerts)
              for (final alert in device.value)
                _row(
                  palette,
                  '${LogRedactor.shortId(device.key)}·${alert.code.code}',
                  '${_alertLabel(l10n, alert.code)} · ${alert.value}',
                ),
          ],
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
          // 子 frame 取证计数（ADR-002 步骤 1）：类别结果，无 URL/host。
          for (final device in subFrameDevices) ...[
            _row(
              palette,
              '${LogRedactor.shortId(device.key)}·subFrameTotal',
              '${device.value.total}',
            ),
            _row(
              palette,
              '${LogRedactor.shortId(device.key)}·subFrameAllowed',
              '${device.value.allowed}',
            ),
            _row(
              palette,
              '${LogRedactor.shortId(device.key)}·subFrameCancelled',
              '${device.value.cancelled}',
            ),
          ],
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

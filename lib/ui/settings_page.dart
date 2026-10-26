import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../services/device_store.dart';
import '../services/external_push.dart';
import '../services/app_log.dart';
import '../services/app_settings.dart';
import '../services/battery_optimization.dart';
import '../services/biometric.dart';
import '../services/notifier.dart';
import '../services/security_lock.dart';
import '../services/structured_log.dart';
import '../services/update_service.dart';
import '../state/app_lifecycle.dart';
import '../state/notification_prefs.dart';
import '../state/session_pool.dart';
import '../state/startup_target.dart';
import '../state/theme_mode.dart';
import '../theme.dart';
import 'diagnostics_page.dart';
import 'notification_history_page.dart';
import 'section_label.dart';
import 'update_download_dialog.dart';

const _settingsRowHeight = 64.0;

/// 设置页统一的轻量线性图标。
///
/// 参考系统设置的纯列表样式，取消大色块，只保留小尺寸图标；所有条目
/// 通过相同的行高和左右内边距对齐。
class _SettingsIcon extends StatelessWidget {
  const _SettingsIcon(this.icon, {this.color});

  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: context.zt.surfaceHi,
      ),
      child: Icon(icon, size: 20, color: color ?? context.zt.accent),
    );
  }
}

/// 设备页卡片使用的彩色图标，和设备列表/设置入口保持同一套视觉语言。
class _DeviceStyleSettingIcon extends StatelessWidget {
  const _DeviceStyleSettingIcon(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: context.zt.surfaceHi,
      ),
      child: Icon(icon, size: 20, color: context.zt.accent),
    );
  }
}

class SettingsPage extends ConsumerWidget {
  const SettingsPage({this.embedded = false, super.key});

  /// 作为底部 Tab 嵌入时隐藏返回键。
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final settingsTheme = Theme.of(context).copyWith(
      listTileTheme: ListTileThemeData(
        visualDensity: const VisualDensity(horizontal: 0, vertical: -1),
        minVerticalPadding: 0,
      ),
    );
    return Theme(
      data: settingsTheme,
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 40),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 12, 2, 8),
                child: Row(
                  children: [
                    if (!embedded)
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        visualDensity: VisualDensity.compact,
                        // 纯图标按钮必须可朗读（TalkBack）：tooltip 同时充当语义标签。
                        tooltip: l10n.commonBack,
                        icon: Icon(Icons.arrow_back, color: context.zt.textLo),
                      ),
                    Text(
                      l10n.settingsTitle,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                        color: context.zt.textHi,
                      ),
                    ),
                  ],
                ),
              ),
              // 原生设置只管理启动端本身；WebView 内部的 Agent、Hook、统计
              // 等选项留在远程页面自己的设置入口中。
              SectionLabel(l10n.settingsGroupBasics),
              const _SecurityLockCard(),
              const _BatteryTile(),
              const _StartupTargetTile(),
              const _FeedbackTile(),
              const _AuthorTile(),
              const _DiagnosticsTile(),
              SectionLabel(l10n.settingsGroupNotifications),
              const _NotificationCard(),
              const _ExternalPushCard(),
            ],
          ),
        ),
      ),
    );
  }
}

/// 安全门禁开关（F24 / PR21）：开启与关闭都必须先通过系统验证。
///
/// 之前这道门禁没有任何入口——只能靠"锁屏时的恢复路径"关闭，新安装也无法开启。
/// 规则：
/// * 开启：必须先通过生物识别验证；设备没有可用生物识别时明确告知，绝不放行。
/// * 关闭：同样必须先验证身份（关闭保护本身是敏感操作）；生物识别不可用时可以
///   退回系统锁屏凭据；两者都没有时，告知用户唯一路径是门禁自身的
///   "清除本机数据并关闭门禁"。
class _SecurityLockCard extends ConsumerStatefulWidget {
  const _SecurityLockCard();

  @override
  ConsumerState<_SecurityLockCard> createState() => _SecurityLockCardState();
}

class _SecurityLockCardState extends ConsumerState<_SecurityLockCard> {
  bool _busy = false;

  Future<bool> _verify(AppLocalizations l10n, {required bool enabling}) {
    return SecurityLockPolicy.verifyToggle(
      enabling: enabling,
      reason: enabling ? l10n.biometricEnableReason : l10n.biometricDisableReason,
      biometric: BiometricService.instance.authenticate,
      deviceCredential: BiometricService.instance.authenticateWithDeviceCredential,
    );
  }

  Future<void> _toggle(bool next) async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final verified = await _verify(l10n, enabling: next);
      if (!mounted) return;
      if (!verified) {
        final available = await BiometricService.instance.isAvailable();
        if (!mounted) return;
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              available
                  ? l10n.securityLockVerifyRequired
                  : (next
                        ? l10n.biometricUnavailableToast
                        : l10n.biometricNoDeviceCredential),
            ),
          ),
        );
        AppLog.event(
          LogEvent.securityLockRejected,
          level: LogLevel.warn,
          fields: {
            LogField.reason: next ? 'enable_not_verified' : 'disable_not_verified',
            LogField.ok: false,
          },
        );
        return;
      }
      await ref.read(biometricProvider.notifier).set(next);
      if (!mounted) return;
      AppLog.event(
        next ? LogEvent.securityLockEnabled : LogEvent.securityLockDisabled,
        fields: {LogField.ok: true},
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(next ? l10n.securityLockEnabled : l10n.securityLockDisabled),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final enabled = ref.watch(biometricProvider);
    return Card(
      child: SizedBox(
        height: _settingsRowHeight,
        child: SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          secondary: const _SettingsIcon(Icons.fingerprint),
          title: Text(
            l10n.securityLockTitle,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            l10n.securityLockSubtitle,
            style: TextStyle(fontSize: 12, color: context.zt.textLo),
          ),
          activeThumbColor: context.zt.accent,
          value: enabled,
          onChanged: _busy ? null : _toggle,
        ),
      ),
    );
  }
}

/// 启动进入页：恢复最近设备或落在设备中心（单行，行尾显示当前值）。
class _StartupTargetTile extends ConsumerWidget {
  const _StartupTargetTile();

  static String _label(AppLocalizations l10n, String value) => switch (value) {
    'launcher' => l10n.startupTargetLauncher,
    _ => l10n.startupTargetLastDevice,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final target = ref.watch(startupTargetProvider);
    return Card(
      child: SizedBox(
        height: _settingsRowHeight,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          leading: const _SettingsIcon(Icons.rocket_launch_outlined),
          title: Text(
            l10n.startupTargetTitle,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _label(l10n, target),
                style: TextStyle(fontSize: 13, color: context.zt.textLo),
              ),
              Icon(Icons.chevron_right, size: 18, color: context.zt.textLo),
            ],
          ),
          onTap: () async {
            final choice = await showDialog<String>(
              context: context,
              builder: (dialogContext) => SimpleDialog(
                title: Text(l10n.startupTargetTitle),
                children: [
                  for (final value in const ['lastDevice', 'launcher'])
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(dialogContext, value),
                      child: Row(
                        children: [
                          Icon(
                            target == value
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            size: 20,
                            color: target == value
                                ? dialogContext.zt.accent
                                : dialogContext.zt.textLo,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            _label(AppLocalizations.of(dialogContext)!, value),
                            style: const TextStyle(fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            );
            if (choice == null || choice == target) return;
            await ref.read(startupTargetProvider.notifier).set(choice);
          },
        ),
      ),
    );
  }
}

/// 反馈问题：直开 GitHub Issues（外置浏览器，失败给提示）。
class _FeedbackTile extends StatelessWidget {
  const _FeedbackTile();

  static const _issuesUrl =
      'https://github.com/daniei-chen/ZCode-App/issues';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      child: SizedBox(
        height: _settingsRowHeight,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          leading: const _SettingsIcon(Icons.feedback_outlined),
          title: Text(
            l10n.feedbackTitle,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          trailing: Icon(Icons.chevron_right, size: 18, color: context.zt.textLo),
          onTap: () => _open(context, Uri.parse(_issuesUrl)),
        ),
      ),
    );
  }

  static Future<void> _open(BuildContext context, Uri uri) async {
    final l10n = AppLocalizations.of(context)!;
    if (uri.scheme != 'https' || uri.host.isEmpty) return;
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && context.mounted) _toast(context, l10n);
    } catch (_) {
      if (context.mounted) _toast(context, l10n);
    }
  }

  static void _toast(BuildContext context, AppLocalizations l10n) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.feedbackOpenFailed)));
  }
}

/// 作者：点击跳转 QQ 群链接。
class _AuthorTile extends StatelessWidget {
  const _AuthorTile();

  static const _authorUrl = 'https://qm.qq.com/q/D3LXUdWyJi';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      child: SizedBox(
        height: _settingsRowHeight,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          leading: const _SettingsIcon(Icons.person_outline),
          title: Text(
            l10n.authorTitle,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          trailing: Icon(Icons.chevron_right, size: 18, color: context.zt.textLo),
          onTap: () => _FeedbackTile._open(context, Uri.parse(_authorUrl)),
        ),
      ),
    );
  }
}

class ThemeSettingTile extends ConsumerWidget {
  const ThemeSettingTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final mode = ref.watch(themeModeProvider);
    return Card(
      child: SizedBox(
        height: _settingsRowHeight,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          leading: _DeviceStyleSettingIcon(
            mode == kThemeDark
                ? Icons.dark_mode_outlined
                : mode == kThemeLight
                ? Icons.light_mode_outlined
                : Icons.brightness_auto_outlined,
          ),
          title: Text(
            l10n.themeTitle,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            _label(l10n, mode),
            style: const TextStyle(fontSize: 12),
          ),
          trailing: Icon(Icons.chevron_right, color: context.zt.textLo),
          onTap: () => _pick(context, ref),
        ),
      ),
    );
  }

  static String _label(AppLocalizations l10n, String mode) => switch (mode) {
    kThemeLight => l10n.themeLight,
    kThemeDark => l10n.themeDark,
    _ => l10n.themeSystem,
  };

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final mode = ref.read(themeModeProvider);
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(l10n.themeTitle),
        children: [
          for (final v in const [kThemeSystem, kThemeLight, kThemeDark])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, v),
              child: Row(
                children: [
                  Icon(
                    mode == v
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: mode == v
                        ? dialogContext.zt.accent
                        : dialogContext.zt.textLo,
                  ),
                  const SizedBox(width: 12),
                  Text(_label(l10n, v), style: const TextStyle(fontSize: 14)),
                ],
              ),
            ),
        ],
      ),
    );
    if (choice == null || choice == mode) return;
    await ref.read(themeModeProvider.notifier).set(choice);
  }
}

class _BatteryTile extends ConsumerStatefulWidget {
  const _BatteryTile();

  @override
  ConsumerState<_BatteryTile> createState() => _BatteryTileState();
}

/// 诊断信息入口：只读状态页 + 用户主动导出日志（v1.1.0）。
class _DiagnosticsTile extends StatelessWidget {
  const _DiagnosticsTile();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      child: SizedBox(
        height: _settingsRowHeight,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          leading: const _DeviceStyleSettingIcon(Icons.monitor_heart_outlined),
          title: Text(
            l10n.diagnosticsTitle,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          trailing: Icon(Icons.chevron_right, color: context.zt.textLo),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DiagnosticsPage()),
          ),
        ),
      ),
    );
  }
}

class _BatteryTileState extends ConsumerState<_BatteryTile> {
  bool? _ignored;
  bool _blocked = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final results = await Future.wait([
      BatteryOptimizationService.isIgnoringBatteryOptimizations(),
      BatteryOptimizationService.isVendorBlocked(),
    ]);
    if (mounted) {
      setState(() {
        _ignored = results[0];
        _blocked = results[1];
      });
    }
  }

  Future<void> _request() async {
    if (_blocked) {
      await BatteryOptimizationService.requestVendorExemption();
    } else {
      await BatteryOptimizationService.requestIgnoreBatteryOptimizations();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(appLifecycleProvider, (prev, next) {
      if (next == AppLifecycleState.resumed) _refresh();
    });
    final l10n = AppLocalizations.of(context)!;
    return Card(
      child: SizedBox(
        height: _settingsRowHeight,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          leading: _SettingsIcon(
            _blocked ? Icons.shield_moon_outlined : Icons.battery_saver,
            color: _blocked ? context.zt.danger : context.zt.accent,
          ),
          title: Text(
            l10n.batteryWhitelistTitle,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          trailing: switch ((_blocked, _ignored)) {
            (_, null) => const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            (true, _) => Icon(Icons.chevron_right, color: context.zt.textLo),
            (_, true) => Icon(
              Icons.check_circle,
              size: 20,
              color: context.zt.accent,
            ),
            (_, false) => Icon(Icons.chevron_right, color: context.zt.textLo),
          },
          onTap: _blocked || _ignored != true ? _request : null,
        ),
      ),
    );
  }
}

class _NotificationCard extends ConsumerStatefulWidget {
  const _NotificationCard();

  @override
  ConsumerState<_NotificationCard> createState() => _NotificationCardState();
}

class _NotificationCardState extends ConsumerState<_NotificationCard> {
  bool? _systemEnabled;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final enabled = await AppSettings.notificationsEnabled();
    if (mounted) setState(() => _systemEnabled = enabled);
  }

  Future<void> _sendTest() async {
    final ok = await NotifierService.instance.showTest();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    if (ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.notifTestSent)));
    } else {
      await AppSettings.openNotifications();
    }
    _refresh();
  }

  static String _alertLabel(AppLocalizations l10n, String mode) => switch (mode) {
    NotificationPrefs.kAlertVibrate => l10n.notifAlertVibrate,
    NotificationPrefs.kAlertSilent => l10n.notifAlertSilent,
    _ => l10n.notifAlertSound,
  };

  Future<void> _pickAlertMode(
    BuildContext context,
    NotificationPrefs prefs,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(l10n.notifAlertTitle),
        children: [
          for (final mode in const [
            NotificationPrefs.kAlertSound,
            NotificationPrefs.kAlertVibrate,
            NotificationPrefs.kAlertSilent,
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, mode),
              child: Row(
                children: [
                  Icon(
                    prefs.alertMode == mode
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: prefs.alertMode == mode
                        ? dialogContext.zt.accent
                        : dialogContext.zt.textLo,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    _alertLabel(AppLocalizations.of(dialogContext)!, mode),
                    style: const TextStyle(fontSize: 14),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (choice == null || choice == prefs.alertMode) return;
    await ref.read(notificationPrefsProvider.notifier).set(
      prefs.copyWith(alertMode: choice),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(appLifecycleProvider, (prev, next) {
      if (next == AppLifecycleState.resumed) _refresh();
    });
    final prefs = ref.watch(notificationPrefsProvider);
    final notifier = ref.read(notificationPrefsProvider.notifier);
    final l10n = AppLocalizations.of(context)!;

    Widget tile(
      String title,
      bool value,
      ValueChanged<bool> onChanged,
      IconData icon,
    ) => SizedBox(
      height: _settingsRowHeight,
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        secondary: _SettingsIcon(icon),
        title: Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        activeThumbColor: context.zt.accent,
        value: value,
        onChanged: onChanged,
      ),
    );

    return Card(
      child: Column(
        children: [
          SizedBox(
            height: _settingsRowHeight,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 14),
              leading: const _SettingsIcon(Icons.volume_up_outlined),
              title: Text(
                l10n.notifAlertTitle,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _alertLabel(l10n, prefs.alertMode),
                    style: TextStyle(fontSize: 13, color: context.zt.textLo),
                  ),
                  Icon(Icons.chevron_right, size: 18, color: context.zt.textLo),
                ],
              ),
              onTap: () => _pickAlertMode(context, prefs),
            ),
          ),
          const Divider(indent: 66, endIndent: 14, height: 1),
          if (_systemEnabled == false)
            SizedBox(
              height: _settingsRowHeight,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                leading: _SettingsIcon(
                  Icons.notifications_off_outlined,
                  color: context.zt.danger,
                ),
                title: Text(
                  l10n.notifSystemOffTitle,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: context.zt.danger,
                  ),
                ),
                trailing: Icon(Icons.chevron_right, color: context.zt.textLo),
                onTap: () async {
                  await AppSettings.openNotifications();
                  _refresh();
                },
              ),
            ),
          tile(
            l10n.notifApprovalTitle,
            prefs.approval,
            (v) => notifier.set(prefs.copyWith(approval: v)),
            Icons.verified_user_outlined,
          ),
          const Divider(indent: 66, endIndent: 14, height: 1),
          tile(
            l10n.notifCompleteTitle,
            prefs.complete,
            (v) => notifier.set(prefs.copyWith(complete: v)),
            Icons.check_circle_outline,
          ),
          const Divider(indent: 66, endIndent: 14, height: 1),
          tile(
            l10n.notifFailTitle,
            prefs.fail,
            (v) => notifier.set(prefs.copyWith(fail: v)),
            Icons.error_outline,
          ),
          const Divider(indent: 66, endIndent: 14, height: 1),
          SizedBox(
            height: _settingsRowHeight,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 14),
              leading: const _SettingsIcon(Icons.history_outlined),
              title: Text(
                l10n.notifHistoryTitle,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                l10n.notifHistorySubtitle,
                style: TextStyle(fontSize: 12, color: context.zt.textLo),
              ),
              trailing: Icon(
                Icons.chevron_right,
                size: 18,
                color: context.zt.textLo,
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const NotificationHistoryPage(),
                ),
              ),
            ),
          ),
          const Divider(indent: 66, endIndent: 14, height: 1),
          SizedBox(
            height: _settingsRowHeight,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 14),
              leading: const _SettingsIcon(Icons.notifications_active_outlined),
              title: Text(
                l10n.notifTestTitle,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              trailing: Icon(
                Icons.send_outlined,
                size: 18,
                color: context.zt.textLo,
              ),
              onTap: _sendTest,
            ),
          ),
        ],
      ),
    );
  }
}

class UpdateSettingTile extends StatefulWidget {
  const UpdateSettingTile({super.key});

  @override
  State<UpdateSettingTile> createState() => _UpdateSettingTileState();
}

class _UpdateSettingTileState extends State<UpdateSettingTile> {
  String _version = '';
  bool _checking = false;
  UpdateCheckResult? _result;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _version = info.version);
    } catch (_) {}
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    if (!Platform.isAndroid) {
      // 应用内更新链路仅 Android；iOS 侧载用户跳转 GitHub 后立即复位，
      // 否则 _checking 永久卡住，检查更新入口失效。
      await UpdateService.openReleasePage();
      if (mounted) setState(() => _checking = false);
      return;
    }
    final result = await UpdateService.instance.checkForUpdate();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _result = result;
    });
    final l10n = AppLocalizations.of(context)!;
    switch (result.status) {
      case UpdateCheckStatus.updateAvailable:
        final latest = result.latestVersion ?? '';
        if (result.canDownload) {
          await showUpdateDownloadDialog(context, result);
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.updateAvailableManual(latest))),
          );
        }
      case UpdateCheckStatus.upToDate:
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.updateLatest)));
      case UpdateCheckStatus.noRelease:
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.updateNoRelease)));
      case UpdateCheckStatus.failed:
        // v1.8.1：把机器可读原因翻成人话一起显示——只说"失败"用户无法
        // 判断是网络、镜像还是版本读取问题。
        final detail = switch (result.failureReason) {
          'version_unavailable' => '（读不到当前安装版本）',
          'api_timeout' => '（网络超时）',
          'api_error' => '（直连与镜像均不可用）',
          'api_and_mirror_failed' => '（直连与镜像均不可用）',
          _ => '',
        };
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${l10n.updateFailed}$detail')),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      child: SizedBox(
        height: _settingsRowHeight,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          leading: const _DeviceStyleSettingIcon(
            Icons.system_update_alt_outlined,
          ),
          title: Text(
            l10n.updateTitle,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            _checking
                ? l10n.updateChecking
                : _result?.status == UpdateCheckStatus.updateAvailable &&
                      _result?.latestVersion != null
                ? l10n.updateAvailable(_result!.latestVersion!)
                : _version.isEmpty
                ? l10n.updateSubtitle
                : l10n.updateCurrentVersion(_version),
            style: const TextStyle(fontSize: 12),
          ),
          trailing: _checking
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: context.zt.accent,
                  ),
                )
              : Icon(
                  _result?.canDownload == true
                      ? Icons.download_outlined
                      : Icons.refresh_outlined,
                  color: context.zt.textLo,
                ),
          onTap: _checking
              ? null
              : _result?.canDownload == true
              ? () => showUpdateDownloadDialog(context, _result!)
              : _check,
        ),
      ),
    );
  }
}

class VersionFooter extends StatelessWidget {
  const VersionFooter({super.key});

  static final _info = PackageInfo.fromPlatform();
  static const _repoUrl = 'https://github.com/daniei-chen/ZCode-App';

  Future<void> _openRepo() async {
    try {
      await launchUrl(
        Uri.parse(_repoUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return FutureBuilder<PackageInfo>(
      future: _info,
      builder: (context, snapshot) {
        final info = snapshot.data;
        if (info == null) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
            child: Text(
              l10n.unofficialDisclaimer,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: context.zt.textLo),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
          child: Column(
            children: [
              InkWell(
                onTap: _openRepo,
                customBorder: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          'ZCode v${info.version} · github.com/daniei-chen/ZCode-App',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            letterSpacing: 0.2,
                            color: context.zt.textLo,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.open_in_new_outlined,
                        size: 10,
                        color: context.zt.textLo,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 9),
              Text(
                l10n.unofficialDisclaimer,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: context.zt.textLo),
              ),
            ],
          ),
        );
      },
    );
  }
}


/// 外置通知通道（v1.8.0）。
///
/// 桌面端 ZCode 的 hook 在审批/任务结束时把消息推到用户自己的服务器，
/// 本 App 长轮询取回后弹通知。**不经过 ZCode 的 relay 终端槽位**，所以
/// 不会与页面/监控互踢——这条通道存在的理由就是绕开那个约束。
class _ExternalPushCard extends ConsumerStatefulWidget {
  const _ExternalPushCard();

  @override
  ConsumerState<_ExternalPushCard> createState() => _ExternalPushCardState();
}

class _ExternalPushCardState extends ConsumerState<_ExternalPushCard> {
  late final TextEditingController _url;
  late final TextEditingController _token;
  // 高级协议项（v1.8.1）：留空即用本项目默认的 /zpush/* 与 X-ZP-Token。
  late final TextEditingController _pollPath;
  late final TextEditingController _ackPath;
  late final TextEditingController _publishPath;
  late final TextEditingController _authHeader;
  ExternalPushAuthStyle _authStyle = ExternalPushAuthStyle.headerToken;
  bool _advancedOpen = false;
  bool _loaded = false;
  bool _busy = false;
  String? _result;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController();
    _token = TextEditingController();
    _pollPath = TextEditingController();
    _ackPath = TextEditingController();
    _publishPath = TextEditingController();
    _authHeader = TextEditingController();
    _load();
  }

  Future<void> _load() async {
    final store = DeviceStore.instance;
    final baseUrl = await store.pushBaseUrl();
    final token = await store.pushToken();
    final pollPath = await store.pushPollPath();
    final ackPath = await store.pushAckPath();
    final publishPath = await store.pushPublishPath();
    final style = await store.pushAuthStyle();
    final authHeader = await store.pushAuthHeader();
    if (!mounted) return;
    setState(() {
      _url.text = baseUrl;
      _token.text = token;
      _pollPath.text = pollPath;
      _ackPath.text = ackPath;
      _publishPath.text = publishPath;
      _authHeader.text = authHeader;
      _authStyle = switch (style) {
        'bearer' => ExternalPushAuthStyle.bearer,
        'query' => ExternalPushAuthStyle.queryToken,
        _ => ExternalPushAuthStyle.headerToken,
      };
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    _pollPath.dispose();
    _ackPath.dispose();
    _publishPath.dispose();
    _authHeader.dispose();
    super.dispose();
  }

  String get _styleKey => switch (_authStyle) {
    ExternalPushAuthStyle.bearer => 'bearer',
    ExternalPushAuthStyle.queryToken => 'query',
    ExternalPushAuthStyle.headerToken => '',
  };

  Future<void> _save({required bool test}) async {
    if (_busy) return;
    final baseUrl = _url.text.trim();
    final token = _token.text.trim();
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final store = DeviceStore.instance;
      if (baseUrl.isEmpty && token.isEmpty) {
        await store.setPushBaseUrl('');
        await store.setPushToken('');
        await store.setPushProtocol(
          pollPath: '',
          ackPath: '',
          publishPath: '',
          authStyle: '',
          authHeader: '',
        );
        if (!mounted) return;
        setState(() => _result = '已关闭外置通道');
        return;
      }
      if (!ExternalPushProtocol.isAcceptableBaseUrl(baseUrl)) {
        setState(() => _result = '服务器地址必须以 https:// 开头');
        return;
      }
      await store.setPushBaseUrl(baseUrl);
      await store.setPushToken(token);
      await store.setPushProtocol(
        pollPath: _pollPath.text,
        ackPath: _ackPath.text,
        publishPath: _publishPath.text,
        authStyle: _styleKey,
        authHeader: _authHeader.text,
      );
      final config = ExternalPushConfig(
        baseUrl: baseUrl,
        token: token,
        pollPath: _pollPath.text.trim(),
        ackPath: _ackPath.text.trim(),
        publishPath: _publishPath.text.trim(),
        authStyle: _authStyle,
        authHeaderName: _authHeader.text.trim(),
      );
      if (test) {
        final batch = await fetchExternalPushOnce(
          config: config,
          after: 0,
          timeout: const Duration(seconds: 12),
        );
        if (!mounted) return;
        setState(() {
          _result = batch.isEmpty
              ? '已保存。服务器暂时没有待收消息（通道可用）'
              : '已保存，收到 ${batch.messages.length} 条待收消息';
        });
      } else {
        if (!mounted) return;
        setState(() => _result = '已保存，重启后生效');
      }
    } catch (e) {
      if (mounted) setState(() => _result = '保存失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.zt;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bolt_outlined, size: 19, color: palette.textHi),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '外置通知通道',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: palette.textHi,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '由桌面端 ZCode 的 hook 主动推送审批/完成消息，不占用远程'
              '控制通道——这是最稳的收通知方式。填你自己的 zcode-push 服务地址。',
              style: TextStyle(fontSize: 12.5, color: palette.textLo, height: 1.45),
            ),
            if (!_loaded)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(minHeight: 2),
              )
            else ...[
              const SizedBox(height: 12),
              TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '服务器地址',
                  hintText: 'https://your-server.example.com',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _token,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '访问令牌',
                  hintText: '与服务器 /etc/zcode-push/token 一致',
                  isDense: true,
                ),
              ),
              // 高级：端点与鉴权（v1.8.1）。默认折叠——用本项目服务的
              // 人不需要看；自建服务的人可以完全自定义这一层。
              const SizedBox(height: 4),
              InkWell(
                onTap: () =>
                    setState(() => _advancedOpen = !_advancedOpen),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Icon(
                        _advancedOpen
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 18,
                        color: palette.textLo,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '高级：端点与鉴权',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: palette.textLo,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _pollPath.text.isEmpty &&
                                _ackPath.text.isEmpty &&
                                _publishPath.text.isEmpty &&
                                _authStyle ==
                                    ExternalPushAuthStyle.headerToken &&
                                _authHeader.text.isEmpty
                            ? '默认'
                            : '已自定义',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: palette.textLo,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_advancedOpen) ...[
                const SizedBox(height: 4),
                Text(
                  '用本项目自带 zcode-push 时留空即可；换成自己的服务时在这里'
                  '填端点路径（相对地址或完整 URL）与鉴权方式。',
                  style: TextStyle(
                    fontSize: 12,
                    color: palette.textLo,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _pollPath,
                  decoration: const InputDecoration(
                    labelText: '轮询端点',
                    hintText: '/zpush/poll',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _ackPath,
                  decoration: const InputDecoration(
                    labelText: '确认端点',
                    hintText: '/zpush/ack',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _publishPath,
                  decoration: const InputDecoration(
                    labelText: '上报端点（仅用于桌面端提示）',
                    hintText: '/zpush/publish',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<ExternalPushAuthStyle>(
                  initialValue: _authStyle,
                  decoration: const InputDecoration(
                    labelText: '鉴权方式',
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: ExternalPushAuthStyle.headerToken,
                      child: Text('请求头（X-ZP-Token）'),
                    ),
                    DropdownMenuItem(
                      value: ExternalPushAuthStyle.bearer,
                      child: Text('Authorization: Bearer'),
                    ),
                    DropdownMenuItem(
                      value: ExternalPushAuthStyle.queryToken,
                      child: Text('URL 查询参数（?token=）'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _authStyle = value);
                  },
                ),
                if (_authStyle == ExternalPushAuthStyle.headerToken) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _authHeader,
                    decoration: const InputDecoration(
                      labelText: '鉴权头名称（留空 = X-ZP-Token）',
                      hintText: 'X-ZP-Token',
                      isDense: true,
                    ),
                  ),
                ],
              ],
              if (_result != null) ...[
                const SizedBox(height: 10),
                Text(
                  _result!,
                  style: TextStyle(fontSize: 12.5, color: palette.textLo),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton(
                    onPressed: _busy ? null : () => _save(test: false),
                    child: const Text('保存'),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: _busy ? null : () => _save(test: true),
                    child: const Text('保存并测试'),
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

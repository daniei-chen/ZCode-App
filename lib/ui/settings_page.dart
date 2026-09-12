import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../services/app_settings.dart';
import '../services/battery_optimization.dart';
import '../services/notifier.dart';
import '../services/update_service.dart';
import '../state/app_lifecycle.dart';
import '../state/notification_prefs.dart';
import '../state/startup_target.dart';
import '../state/theme_mode.dart';
import '../theme.dart';
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
              const _BatteryTile(),
              const _StartupTargetTile(),
              const _FeedbackTile(),
              const _AuthorTile(),
              SectionLabel(l10n.settingsGroupNotifications),
              const _NotificationCard(),
            ],
          ),
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
      'https://github.com/2421873411a-rgb/ZCode-App/issues';

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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.updateFailed)));
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
  static const _repoUrl = 'https://github.com/2421873411a-rgb/ZCode-App';

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
                      Text(
                        'ZCode v${info.version} · github.com/2421873411a-rgb/ZCode-App',
                        style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 0.2,
                          color: context.zt.textLo,
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

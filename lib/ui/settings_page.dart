import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../services/app_settings.dart';
import '../services/keepalive.dart';
import '../services/notifier.dart';
import '../services/update_service.dart';
import '../state/app_lifecycle.dart';
import '../state/event_feed.dart';
import '../state/theme_mode.dart';
import 'notifications_page.dart';
import '../state/notification_prefs.dart';
import '../theme.dart';

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
    return SizedBox(
      width: 26,
      height: 26,
      child: Icon(icon, size: 21, color: color ?? context.zt.textLo),
    );
  }
}

/// 设备页卡片使用的彩色图标，和设备列表/设置入口保持同一套视觉语言。
class _DeviceStyleSettingIcon extends StatelessWidget {
  const _DeviceStyleSettingIcon(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final tint = context.zt.accent;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: tint.withValues(alpha: 0.10),
      ),
      child: Icon(icon, size: 20, color: tint),
    );
  }
}

class _SettingsSectionLabel extends StatelessWidget {
  const _SettingsSectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: context.zt.textLo,
      ),
    ),
  );
}

class _SettingsDivider extends StatelessWidget {
  const _SettingsDivider();

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    thickness: 1,
    indent: 16,
    endIndent: 16,
    color: context.zt.hairline.withValues(alpha: 0.8),
  );
}

class SettingsPage extends ConsumerWidget {
  const SettingsPage({this.embedded = false, super.key});

  /// 作为底部 Tab 嵌入时隐藏返回键。
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final settingsTheme = Theme.of(context).copyWith(
      cardTheme: CardThemeData(
        color: context.zt.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ),
      listTileTheme: ListTileThemeData(
        visualDensity: const VisualDensity(horizontal: 0, vertical: -1),
        minVerticalPadding: 0,
        iconColor: context.zt.textLo,
      ),
    );
    return Theme(
      data: settingsTheme,
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              SizedBox(
                height: 58,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Text(
                      l10n.settingsTitle,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: context.zt.textHi,
                      ),
                    ),
                    if (!embedded)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: Icon(
                            Icons.arrow_back,
                            color: context.zt.textLo,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // 原生设置只管理启动端本身；WebView 内部的 Agent、Hook、统计
              // 等选项留在远程页面自己的设置入口中。
              _SettingsSectionLabel(l10n.settingsGroupBasics),
              const _BatteryTile(),
              _SettingsSectionLabel(l10n.settingsGroupNotifications),
              const _NotificationCenterTile(),
              const _SettingsDivider(),
              const _NotificationCard(),
            ],
          ),
        ),
      ),
    );
  }
}

/// 通知历史是上下文入口，不占用根部底部导航的一个位置。
class _NotificationCenterTile extends ConsumerWidget {
  const _NotificationCenterTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final zt = context.zt;
    final feed = ref.watch(eventFeedProvider);
    final unread = feed.values.fold<int>(0, (sum, item) => sum + item.unread);
    final approval = feed.values.any((item) => item.permPending);
    final subtitle = unread == 0 && !approval
        ? l10n.notifCenterEmpty.split('\n').first
        : '$unread ${l10n.notifCenterTitle}';
    return Card(
      child: SizedBox(
        height: _settingsRowHeight,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          leading: _SettingsIcon(
            approval
                ? Icons.notifications_active_outlined
                : Icons.notifications_none_outlined,
            color: approval ? zt.danger : zt.accent,
          ),
          title: Text(
            l10n.notifCenterTitle,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
          trailing: unread > 0 || approval
              ? _NotificationBadge(count: unread, alert: approval)
              : Icon(Icons.chevron_right, color: zt.textLo),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const NotificationsPage()),
          ),
        ),
      ),
    );
  }
}

class _NotificationBadge extends StatelessWidget {
  const _NotificationBadge({required this.count, required this.alert});

  final int count;
  final bool alert;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: alert ? context.zt.danger : context.zt.accent,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      alert ? (count > 0 ? '$count!' : '!') : '$count',
      style: const TextStyle(
        color: Colors.white,
        fontSize: 11,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
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
    final service = KeepAliveService.instance;
    final results = await Future.wait([
      service.isBatteryIgnored,
      service.isBlocked,
    ]);
    if (mounted) {
      setState(() {
        _ignored = results[0];
        _blocked = results[1];
      });
    }
  }

  Future<void> _request() async {
    final service = KeepAliveService.instance;
    if (_blocked) {
      await service.requestVendorExemption();
    } else {
      await service.requestBatteryExemption();
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
          const Divider(indent: 68, endIndent: 14, height: 1),
          tile(
            l10n.notifCompleteTitle,
            prefs.complete,
            (v) => notifier.set(prefs.copyWith(complete: v)),
            Icons.check_circle_outline,
          ),
          const Divider(indent: 68, endIndent: 14, height: 1),
          tile(
            l10n.notifFailTitle,
            prefs.fail,
            (v) => notifier.set(prefs.copyWith(fail: v)),
            Icons.error_outline,
          ),
          const Divider(indent: 68, endIndent: 14, height: 1),
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
    final result = await UpdateService.instance.checkForUpdate();
    if (!mounted) return;
    setState(() => _checking = false);
    final l10n = AppLocalizations.of(context)!;
    switch (result.status) {
      case UpdateCheckStatus.updateAvailable:
        final latest = result.latestVersion ?? '';
        final opened = result.releaseUri == null
            ? false
            : await UpdateService.instance.openRelease(result.releaseUri!);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              opened
                  ? l10n.updateAvailable(latest)
                  : l10n.updateAvailableManual(latest),
            ),
          ),
        );
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
              : Icon(Icons.refresh_outlined, color: context.zt.textLo),
          onTap: _checking ? null : _check,
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

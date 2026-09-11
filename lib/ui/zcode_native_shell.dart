import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device.dart';
import '../services/device_import.dart';
import '../services/event_observer.dart';
import '../services/link_builder.dart';
import '../state/conversation.dart';
import '../state/conversation_config.dart';
import '../state/relay_source.dart';
import '../state/session_index.dart';
import '../state/session_pool.dart';
import '../state/theme_mode.dart';
import '../theme.dart';
import 'conversation_page.dart';
import 'manage_page.dart';
import 'native_model_page.dart';
import 'settings_panel_page.dart';

/// The native ZCode surface.
///
/// This is intentionally a workspace shell, not a mobile version of the old
/// device-management app.  Its hierarchy follows the installed ZCode 3.11.2
/// renderer: sidebar/task tree, conversation header, conversation canvas,
/// runtime controls and composer.  Relay state is still provided by the
/// existing native protocol layer; this widget owns the presentation only.
class ZCodeNativeShell extends ConsumerStatefulWidget {
  const ZCodeNativeShell({super.key});

  @override
  ConsumerState<ZCodeNativeShell> createState() => _ZCodeNativeShellState();
}

class _ZCodeNativeShellState extends ConsumerState<ZCodeNativeShell> {
  bool _settings = false;

  @override
  Widget build(BuildContext context) {
    if (_settings) {
      return ZCodeSettingsPage(onBack: () => setState(() => _settings = false));
    }
    return ZCodeWorkspacePage(
      onOpenSettings: () => setState(() => _settings = true),
    );
  }
}

class ZCodeWorkspacePage extends ConsumerStatefulWidget {
  const ZCodeWorkspacePage({super.key, required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  ConsumerState<ZCodeWorkspacePage> createState() => _ZCodeWorkspacePageState();
}

class _ZCodeWorkspacePageState extends ConsumerState<ZCodeWorkspacePage> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _composer = TextEditingController();
  final Set<String> _runtimeRequested = <String>{};
  bool _showStatus = true;

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';

  String _t(String zh, String en) => _zh ? zh : en;

  List<RemoteDevice> get _devices => ref.read(deviceListProvider);

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(deviceListProvider);
    final relaySources = ref.watch(relaySourceProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final veryWide = constraints.maxWidth >= 1180;
        final content = _mainContent(
          context,
          devices,
          relaySources,
          wide,
          veryWide,
        );
        if (wide) return content;
        return Scaffold(
          key: _scaffoldKey,
          backgroundColor: context.zt.bg,
          drawer: _sidebar(context, devices),
          drawerEdgeDragWidth: 32,
          body: SafeArea(child: content),
        );
      },
    );
  }

  Widget _mainContent(
    BuildContext context,
    List<RemoteDevice> devices,
    Map<String, RelaySourceState> relaySources,
    bool wide,
    bool veryWide,
  ) {
    final zt = context.zt;
    return Scaffold(
      backgroundColor: zt.bg,
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide) SizedBox(width: 272, child: _sidebar(context, devices)),
            Expanded(
              child: Column(
                children: [
                  _header(context, devices, wide),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: _conversation(context, devices, relaySources),
                        ),
                        if (veryWide && _showStatus && devices.isNotEmpty)
                          SizedBox(
                            width: 286,
                            child: _statusPanel(context, devices, relaySources),
                          ),
                      ],
                    ),
                  ),
                  _composerBar(context, devices, relaySources),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, List<RemoteDevice> devices, bool wide) {
    final zt = context.zt;
    final sessions = _sessions();
    final primary = sessions.isEmpty ? null : sessions.first;
    final source = devices.isEmpty
        ? null
        : ref.watch(relaySourceProvider)[devices.first.id];
    final title = devices.isEmpty
        ? _t('新建任务', 'New task')
        : (primary?.state.title?.trim().isNotEmpty == true
              ? primary!.state.title!.trim()
              : _t('工作区', 'Workspace'));
    final subtitle = devices.isEmpty
        ? 'ZCode'
        : (primary?.state.workspace ??
              source?.workspaceKey ??
              _t('正在同步', 'Syncing'));
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: zt.surface,
        border: Border(bottom: BorderSide(color: zt.hairline)),
      ),
      child: Row(
        children: [
          if (!wide)
            IconButton(
              tooltip: _t('打开任务栏', 'Open task list'),
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              icon: Icon(Icons.menu_rounded, color: zt.textLo),
            ),
          if (!wide) const SizedBox(width: 2),
          Image.asset('assets/brand/mark.png', width: 30, height: 30),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: zt.textHi,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: zt.textLo),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: _t('搜索任务', 'Search tasks'),
            onPressed: () => _showSearch(context),
            icon: Icon(Icons.search_rounded, color: zt.textLo, size: 20),
          ),
          IconButton(
            tooltip: _t('扫码或粘贴链接连接桌面端', 'Connect desktop by QR or link'),
            onPressed: () => _openConnectionOptions(context),
            icon: Icon(
              Icons.qr_code_scanner_rounded,
              color: zt.textLo,
              size: 19,
            ),
          ),
          IconButton(
            tooltip: _t('切换状态面板', 'Toggle status panel'),
            onPressed: () => setState(() => _showStatus = !_showStatus),
            icon: Icon(Icons.view_sidebar_outlined, color: zt.textLo, size: 19),
          ),
          IconButton(
            tooltip: _t('设置', 'Settings'),
            onPressed: widget.onOpenSettings,
            icon: Icon(Icons.settings_outlined, color: zt.textLo, size: 19),
          ),
        ],
      ),
    );
  }

  Widget _conversation(
    BuildContext context,
    List<RemoteDevice> devices,
    Map<String, RelaySourceState> relaySources,
  ) {
    final zt = context.zt;
    final sessions = _sessions();
    return Container(
      color: zt.bg,
      child: Column(
        children: [
          Expanded(
            child: devices.isEmpty
                ? _emptyCanvas(context)
                : sessions.isEmpty
                ? _connectedEmptyCanvas(
                    context,
                    devices.first,
                    relaySources[devices.first.id],
                  )
                : _taskPreview(context, devices, sessions),
          ),
        ],
      ),
    );
  }

  List<_ZCodeSessionEntry> _sessions() {
    final result = <_ZCodeSessionEntry>[];
    final indexed = ref.watch(sessionIndexProvider);
    for (final device in ref.watch(deviceListProvider)) {
      final map = indexed[device.id];
      if (map == null) continue;
      final states = map.values.toList()..sort(SessionRanking.compareSessions);
      for (final state in states) {
        result.add(_ZCodeSessionEntry(device: device, state: state));
      }
    }
    return result;
  }

  Widget _emptyCanvas(BuildContext context) {
    final zt = context.zt;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/brand/mark.png', width: 54, height: 54),
              const SizedBox(height: 18),
              Text(
                _t('开始一个新任务', 'Start a new task'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.4,
                  color: zt.textHi,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _t(
                  '从下方输入需求，或从左侧任务树打开一个已有会话。',
                  'Describe what you need below, or open a task from the sidebar.',
                ),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: zt.textLo, height: 1.5),
              ),
              const SizedBox(height: 22),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _openScanner(context),
                    icon: const Icon(Icons.qr_code_scanner_rounded, size: 17),
                    label: Text(_t('扫码连接', 'Scan QR')),
                  ),
                  TextButton.icon(
                    onPressed: () => _openImport(context),
                    icon: const Icon(Icons.content_paste_rounded, size: 17),
                    label: Text(_t('粘贴链接', 'Paste link')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _connectedEmptyCanvas(
    BuildContext context,
    RemoteDevice device,
    RelaySourceState? source,
  ) {
    final zt = context.zt;
    if (source?.kind == RelaySourceKind.failed) {
      return Center(
        child: IconButton(
          tooltip: _t('重新连接', 'Reconnect'),
          onPressed: () =>
              ref.read(relaySourceProvider.notifier).reconnect(device),
          icon: Icon(Icons.refresh_rounded, size: 22, color: zt.textLo),
        ),
      );
    }
    return Center(
      child: SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 1.6, color: zt.textLo),
      ),
    );
  }

  Widget _taskPreview(
    BuildContext context,
    List<RemoteDevice> devices,
    List<_ZCodeSessionEntry> sessions,
  ) {
    final zt = context.zt;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
      children: [
        Text(
          _t('最近会话', 'Recent conversations'),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: zt.textLo,
          ),
        ),
        const SizedBox(height: 10),
        for (final entry in sessions.take(8)) _sessionRow(context, entry),
      ],
    );
  }

  Widget _sessionRow(BuildContext context, _ZCodeSessionEntry entry) {
    final zt = context.zt;
    final state = entry.state;
    final active = state.phase == 'running' || state.permissionCount > 0;
    return InkWell(
      onTap: () => _openConversation(
        context,
        entry.device,
        sessionId: state.sessionId,
        title: state.title,
      ),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: zt.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: zt.hairline),
        ),
        child: Row(
          children: [
            Icon(
              active ? Icons.circle : Icons.forum_outlined,
              size: active ? 8 : 17,
              color: active ? zt.live : zt.textLo,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    state.title?.trim().isNotEmpty == true
                        ? state.title!.trim()
                        : _t('未命名会话', 'Untitled conversation'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: zt.textHi,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    state.description?.trim().isNotEmpty == true
                        ? state.description!.trim()
                        : (state.workspace ?? 'ZCode-Loop-Engineering'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: zt.textLo),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 18, color: zt.textLo),
          ],
        ),
      ),
    );
  }

  Widget _statusPanel(
    BuildContext context,
    List<RemoteDevice> devices,
    Map<String, RelaySourceState> relaySources,
  ) {
    final zt = context.zt;
    final source = relaySources[devices.first.id];
    if (source == null || !source.isLive || _sessions().isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: zt.surface,
          border: Border(left: BorderSide(color: zt.hairline)),
        ),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              color: zt.textLo,
            ),
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: zt.surface,
        border: Border(left: BorderSide(color: zt.hairline)),
      ),
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
      child: ListView(
        children: [
          Row(
            children: [
              Text(
                _t('目标', 'Goal'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: zt.textHi,
                ),
              ),
              const Spacer(),
              Text(
                '${_sessions().length}/${_sessions().length}',
                style: TextStyle(fontSize: 11, color: zt.live),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _statusItem(context, _t('读取任务列表', 'Read task list'), true),
          _statusItem(context, _t('同步当前工作区', 'Sync workspace'), true),
          _statusItem(
            context,
            _t('检查工具与权限', 'Check tools and permissions'),
            true,
          ),
          _statusItem(context, _t('准备下一步操作', 'Prepare next action'), true),
          const SizedBox(height: 18),
          Divider(color: zt.hairline, height: 1),
          const SizedBox(height: 16),
          Text(
            _t('当前工作区', 'Current workspace'),
            style: TextStyle(fontSize: 11, color: zt.textLo),
          ),
          const SizedBox(height: 6),
          Text(
            source.workspaceKey ?? devices.first.label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: zt.textHi),
          ),
        ],
      ),
    );
  }

  Widget _statusItem(BuildContext context, String label, bool done) {
    final zt = context.zt;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            done ? Icons.check_circle : Icons.circle_outlined,
            size: 15,
            color: done ? zt.live : zt.textLo,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: zt.textLo),
            ),
          ),
        ],
      ),
    );
  }

  Widget _composerBar(
    BuildContext context,
    List<RemoteDevice> devices,
    Map<String, RelaySourceState> relaySources,
  ) {
    final zt = context.zt;
    final primary = _primarySession();
    final runtime = _runtimeConfig(primary);
    final enabled = devices.any(
      (device) => relaySources[device.id]?.isLive == true,
    );
    final modelLabel = runtime.hasModel
        ? (runtime.modelLabel ?? runtime.modelId!)
        : _t('未连接', 'Not connected');
    final thoughtLabel = runtime.thoughtLevel == null
        ? _t('未连接', 'Not connected')
        : runtime.thoughtLevel!;
    return Material(
      color: zt.surface,
      child: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: zt.hairline)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _runtimeChip(
                      context,
                      Icons.shield_outlined,
                      _t('全部权限', 'Full access'),
                      () => _showMode(context),
                    ),
                    const SizedBox(width: 6),
                    _runtimeChip(
                      context,
                      Icons.hub_outlined,
                      modelLabel,
                      () => _showModel(context, primary, runtime),
                      enabled: primary != null,
                    ),
                    const SizedBox(width: 6),
                    _runtimeChip(
                      context,
                      Icons.psychology_outlined,
                      thoughtLabel,
                      () => _showThought(context, primary, runtime),
                      enabled: primary != null,
                    ),
                    const SizedBox(width: 6),
                    _runtimeChip(
                      context,
                      Icons.data_usage_outlined,
                      _contextLabel(runtime),
                      () => _showContext(context, runtime),
                      enabled: primary != null,
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: _t('添加附件', 'Attach'),
                      onPressed: devices.isEmpty
                          ? () => _openConnectionOptions(context)
                          : () => _showUnavailable(
                              context,
                              _t(
                                '附件选择器尚未返回原生状态',
                                'Native attachment state is not available',
                              ),
                            ),
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.attach_file_rounded,
                        size: 19,
                        color: zt.textLo,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 5),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _composer,
                      minLines: 1,
                      maxLines: 5,
                      decoration: InputDecoration(
                        hintText: enabled
                            ? _t('输入消息…', 'Message…')
                            : _t(
                                '连接桌面端后输入消息',
                                'Connect the desktop before sending…',
                              ),
                        isDense: true,
                        filled: true,
                        fillColor: zt.field,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 11,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(9),
                          borderSide: BorderSide(color: zt.hairline),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(9),
                          borderSide: BorderSide(color: zt.hairline),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(9),
                          borderSide: BorderSide(color: zt.accent),
                        ),
                      ),
                      onSubmitted: (_) => _send(context),
                    ),
                  ),
                  const SizedBox(width: 5),
                  IconButton(
                    tooltip: enabled
                        ? _t('发送', 'Send')
                        : _t('连接桌面端', 'Connect desktop'),
                    onPressed: () => _send(context),
                    icon: Icon(
                      Icons.arrow_upward_rounded,
                      color: enabled && _composer.text.trim().isNotEmpty
                          ? zt.textHi
                          : zt.textLo,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _runtimeChip(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool enabled = true,
  }) {
    final zt = context.zt;
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(7),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: zt.field,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: zt.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: enabled ? zt.textLo : zt.textLo.withValues(alpha: 0.55),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: enabled ? zt.textLo : zt.textLo.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(width: 3),
            Icon(
              Icons.expand_more_rounded,
              size: 14,
              color: enabled ? zt.textLo : zt.textLo.withValues(alpha: 0.55),
            ),
          ],
        ),
      ),
    );
  }

  Drawer _sidebar(BuildContext context, List<RemoteDevice> devices) {
    final zt = context.zt;
    return Drawer(
      width: 272,
      backgroundColor: zt.surface,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 16),
              child: Row(
                children: [
                  Image.asset('assets/brand/mark.png', width: 30, height: 30),
                  const SizedBox(width: 10),
                  Text(
                    'ZCode',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: zt.textHi,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: _t('关闭菜单', 'Close menu'),
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: Icon(Icons.chevron_left_rounded, color: zt.textLo),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(
                    child: _sideAction(
                      context,
                      Icons.add_rounded,
                      _t('新建任务', 'New task'),
                      () => Navigator.of(context).maybePop(),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _sideIcon(
                    context,
                    Icons.search_rounded,
                    _t('搜索', 'Search'),
                    () => _showSearch(context),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 7),
            _sideLine(
              context,
              Icons.storefront_outlined,
              _t('插件市场', 'Plugin market'),
              () => _showUnavailable(
                context,
                _t(
                  '插件市场会从原生插件服务加载',
                  'Plugin market will load from the native plugin service',
                ),
              ),
            ),
            const SizedBox(height: 8),
            Divider(height: 1, color: zt.hairline),
            Expanded(child: _taskTree(context, devices)),
            Divider(height: 1, color: zt.hairline),
            _sideLine(
              context,
              Icons.settings_outlined,
              _t('设置', 'Settings'),
              () {
                Navigator.of(context).maybePop();
                widget.onOpenSettings();
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: zt.surfaceHi,
                    child: Icon(
                      Icons.person_outline,
                      size: 17,
                      color: zt.textLo,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      _t('本机用户', 'Local user'),
                      style: TextStyle(fontSize: 12, color: zt.textLo),
                    ),
                  ),
                  Icon(Icons.more_horiz_rounded, size: 18, color: zt.textLo),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _taskTree(BuildContext context, List<RemoteDevice> devices) {
    final zt = context.zt;
    final sessions = _sessions();
    final items = <Widget>[
      if (devices.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 28, 18, 12),
          child: Text(
            _t(
              '连接桌面端后显示工作区和任务',
              'Workspaces and tasks appear after connecting',
            ),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, height: 1.45, color: zt.textLo),
          ),
        )
      else if (sessions.isEmpty)
        const SizedBox(
          height: 110,
          child: Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
          ),
        )
      else ...[
        for (final entry in sessions.take(10))
          _workspaceTaskGroup(context, entry, zt),
      ],
    ];
    return ListView(padding: EdgeInsets.zero, children: items);
  }

  Widget _workspaceTaskGroup(
    BuildContext context,
    _ZCodeSessionEntry entry,
    ZTPalette zt,
  ) {
    final workspace = entry.state.workspacePath?.trim().isNotEmpty == true
        ? entry.state.workspacePath!.trim()
        : (entry.state.workspace ?? entry.device.label);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 7),
          child: Row(
            children: [
              Icon(Icons.folder_open_outlined, size: 16, color: zt.textLo),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  workspace,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: zt.textHi,
                  ),
                ),
              ),
              Icon(Icons.expand_more_rounded, size: 16, color: zt.textLo),
            ],
          ),
        ),
        _taskItem(
          context,
          entry.state.title ?? _t('未命名会话', 'Untitled task'),
          connected: true,
          onTap: () => _openConversation(
            context,
            entry.device,
            sessionId: entry.state.sessionId,
            title: entry.state.title,
          ),
        ),
      ],
    );
  }

  Widget _taskItem(
    BuildContext context,
    String title, {
    required bool connected,
    VoidCallback? onTap,
  }) {
    final zt = context.zt;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(26, 9, 14, 9),
        child: Row(
          children: [
            Icon(Icons.chat_bubble_outline_rounded, size: 15, color: zt.textLo),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: zt.textLo),
              ),
            ),
            if (connected) Icon(Icons.circle, size: 5, color: zt.live),
          ],
        ),
      ),
    );
  }

  Widget _sideAction(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    final zt = context.zt;
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label, overflow: TextOverflow.ellipsis),
      style: OutlinedButton.styleFrom(
        foregroundColor: zt.textHi,
        side: BorderSide(color: zt.hairline),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        textStyle: const TextStyle(fontSize: 12),
      ),
    );
  }

  Widget _sideIcon(
    BuildContext context,
    IconData icon,
    String tooltip,
    VoidCallback onTap,
  ) => IconButton(
    tooltip: tooltip,
    onPressed: onTap,
    icon: Icon(icon, size: 18, color: context.zt.textLo),
  );

  Widget _sideLine(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    final zt = context.zt;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 9, 16, 9),
        child: Row(
          children: [
            Icon(icon, size: 17, color: zt.textLo),
            const SizedBox(width: 10),
            Text(label, style: TextStyle(fontSize: 12, color: zt.textLo)),
          ],
        ),
      ),
    );
  }

  void _openConversation(
    BuildContext context,
    RemoteDevice device, {
    String? sessionId,
    String? title,
    String? initialText,
    bool autoSendInitialText = false,
  }) {
    final workspace = ref.read(relaySourceProvider)[device.id]?.workspaceKey;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ConversationPage(
          deviceId: device.id,
          workspacePath: workspace,
          sessionId: sessionId,
          title: title,
          initialText: initialText,
          autoSendInitialText: autoSendInitialText,
        ),
      ),
    );
  }

  _ZCodeSessionEntry? _primarySession() {
    final sessions = _sessions();
    return sessions.isEmpty ? null : sessions.first;
  }

  ConversationRuntimeConfig _runtimeConfig(_ZCodeSessionEntry? entry) {
    if (entry == null) return ConversationRuntimeConfig.empty;
    final key = ConversationNotifier.keyOf(
      entry.device.id,
      entry.state.sessionId,
    );
    final config = ref.watch(
      conversationProvider.select(
        (states) =>
            states[key]?.runtimeConfig ?? ConversationRuntimeConfig.empty,
      ),
    );
    final source = ref.watch(relaySourceProvider)[entry.device.id];
    if (source?.isLive == true &&
        !config.loading &&
        !config.hasModel &&
        !config.hasContext &&
        _runtimeRequested.add(key)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(
          ref
              .read(conversationProvider.notifier)
              .loadRuntimeConfig(
                deviceId: entry.device.id,
                workspacePath: _workspaceFor(entry),
                sessionId: entry.state.sessionId,
              ),
        );
      });
    }
    return config;
  }

  String _workspaceFor(_ZCodeSessionEntry entry) {
    final fromSession = entry.state.workspacePath?.trim();
    if (fromSession != null && fromSession.isNotEmpty) return fromSession;
    final fromLabel = entry.state.workspace?.trim();
    if (fromLabel != null && fromLabel.isNotEmpty) return fromLabel;
    final fromRelay = ref
        .read(relaySourceProvider)[entry.device.id]
        ?.workspaceKey
        ?.trim();
    return fromRelay ?? '';
  }

  String _contextLabel(ConversationRuntimeConfig config) {
    if (!config.hasContext) return _t('未连接', 'Not connected');
    return '${_formatTokens(config.contextUsedTokens)} / ${_formatTokens(config.contextMaxTokens)}';
  }

  static String _formatTokens(int? value) {
    if (value == null) return '—';
    if (value < 1000) return '$value';
    if (value < 1000000) return '${(value / 1000).toStringAsFixed(1)}k';
    return '${(value / 1000000).toStringAsFixed(1)}m';
  }

  Future<void> _send(BuildContext context) async {
    final text = _composer.text.trim();
    final devices = _devices;
    if (devices.isEmpty) {
      await _openConnectionOptions(context, initial: text);
      return;
    }
    final live = devices.any(
      (device) => ref.read(relaySourceProvider)[device.id]?.isLive == true,
    );
    if (!live) return;
    if (text.isEmpty) {
      _openConversation(context, devices.first);
      return;
    }
    _composer.clear();
    _openConversation(
      context,
      devices.first,
      initialText: text,
      autoSendInitialText: true,
    );
  }

  Future<void> _openConnectionOptions(
    BuildContext context, {
    String? initial,
  }) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: context.zt.surface,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                Icons.qr_code_scanner_rounded,
                color: context.zt.accent,
              ),
              title: Text(_t('扫码连接桌面端', 'Scan desktop QR code')),
              subtitle: Text(
                _t(
                  '扫描 ZCode 桌面端显示的远控二维码',
                  'Scan the remote-control QR code shown on ZCode desktop',
                ),
              ),
              onTap: () => Navigator.pop(sheetContext, 'scan'),
            ),
            ListTile(
              leading: Icon(
                Icons.content_paste_rounded,
                color: context.zt.accent,
              ),
              title: Text(_t('粘贴远程链接', 'Paste remote link')),
              subtitle: Text(
                _t(
                  '从剪贴板读取 remote/v4 链接',
                  'Read a remote/v4 link from the clipboard',
                ),
              ),
              onTap: () => Navigator.pop(sheetContext, 'paste'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!context.mounted || action == null) return;
    if (action == 'scan') {
      await _openScanner(context);
    } else {
      await _openImport(context, initial: initial);
    }
  }

  Future<void> _openScanner(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const ScannerPage(),
      ),
    );
  }

  Future<void> _openImport(BuildContext context, {String? initial}) async {
    final controller = TextEditingController();
    try {
      if (initial != null && initial.trim().isNotEmpty) {
        controller.text = initial.trim();
      }
      final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
      if (controller.text.isEmpty &&
          clipboard?.text?.contains('zcode.z.ai/remote') == true) {
        controller.text = clipboard!.text!;
      }
      if (!context.mounted) return;
      final text = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(_t('连接 ZCode 桌面端', 'Connect ZCode desktop')),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: 'https://zcode.z.ai/remote/v4?sid=...&hash=...',
              helperText: _t(
                '链接只保存在本机安全存储中。',
                'The link stays in local secure storage.',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(_t('取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: Text(_t('连接', 'Connect')),
            ),
          ],
        ),
      );
      if (text == null || !context.mounted) return;
      final device = LinkBuilder.parse(text);
      if (device == null) {
        _showUnavailable(
          context,
          _t(
            '链接无效：需要 sid 和 hash 参数。',
            'Invalid link: sid and hash are required.',
          ),
        );
        return;
      }
      final existing = ref.read(deviceListProvider);
      final duplicate = findDuplicateBySid(existing, device);
      if (duplicate != null) {
        _showUnavailable(
          context,
          _t('这个桌面端已经连接。', 'This desktop is already connected.'),
        );
        return;
      }
      await ref.read(deviceListProvider.notifier).add(device);
    } finally {
      controller.dispose();
    }
  }

  Future<void> _showModel(
    BuildContext context,
    _ZCodeSessionEntry? primary,
    ConversationRuntimeConfig runtime,
  ) async {
    if (primary == null || runtime.models.isEmpty) return;
    final selected = await showModalBottomSheet<ConversationModelOption>(
      context: context,
      showDragHandle: true,
      backgroundColor: context.zt.surface,
      builder: (_) => _RuntimeModelSheet(runtime: runtime),
    );
    if (selected == null || !mounted) return;
    await ref
        .read(conversationProvider.notifier)
        .updateRuntimeConfig(
          deviceId: primary.device.id,
          workspacePath: _workspaceFor(primary),
          sessionId: primary.state.sessionId,
          providerId: selected.providerId,
          modelId: selected.modelId,
        );
  }

  Future<void> _showThought(
    BuildContext context,
    _ZCodeSessionEntry? primary,
    ConversationRuntimeConfig runtime,
  ) async {
    if (primary == null || runtime.thoughtOptions.isEmpty) return;
    final selected = await showModalBottomSheet<ThoughtOption>(
      context: context,
      showDragHandle: true,
      backgroundColor: context.zt.surface,
      builder: (_) => _RuntimeThoughtSheet(runtime: runtime),
    );
    if (selected == null || !mounted) return;
    await ref
        .read(conversationProvider.notifier)
        .updateRuntimeConfig(
          deviceId: primary.device.id,
          workspacePath: _workspaceFor(primary),
          sessionId: primary.state.sessionId,
          thoughtLevel: selected.value,
        );
  }

  Future<void> _showMode(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: context.zt.surface,
      builder: (_) => _InfoSheet(
        title: _t('权限模式', 'Permission mode'),
        body: _t(
          '全部权限会让桌面端按当前会话策略执行文件和命令操作。真实写入仍由桌面端确认机制决定。',
          'Full access follows the desktop session policy. Actual writes remain governed by the desktop confirmation flow.',
        ),
      ),
    );
  }

  Future<void> _showContext(
    BuildContext context,
    ConversationRuntimeConfig runtime,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: context.zt.surface,
      builder: (_) => _InfoSheet(
        title: _t('上下文', 'Context'),
        body:
            '${_contextLabel(runtime)} tokens\n\n${_t('数值来自桌面端会话快照；未连接时不填充默认模型或默认用量。', 'Values come from the desktop session snapshot; no model or usage defaults are filled before connection.')}',
      ),
    );
  }

  Future<void> _showSearch(BuildContext context) async {
    final controller = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_t('搜索任务', 'Search tasks')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: _t('输入任务标题', 'Task title')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(_t('关闭', 'Close')),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  void _showUnavailable(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }
}

class _ZCodeSessionEntry {
  const _ZCodeSessionEntry({required this.device, required this.state});

  final RemoteDevice device;
  final SessionState state;
}

class _ChoiceSheet extends StatelessWidget {
  const _ChoiceSheet({
    required this.title,
    required this.selected,
    required this.options,
  });

  final String title;
  final String selected;
  final List<String> options;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: zt.textHi,
              ),
            ),
            const SizedBox(height: 8),
            for (final option in options)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  option == selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: option == selected ? zt.accent : zt.textLo,
                ),
                title: Text(option, style: TextStyle(color: zt.textHi)),
                onTap: () => Navigator.pop(context, option),
              ),
          ],
        ),
      ),
    );
  }
}

class _RuntimeModelSheet extends StatelessWidget {
  const _RuntimeModelSheet({required this.runtime});

  final ConversationRuntimeConfig runtime;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '模型',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: zt.textHi,
              ),
            ),
            const SizedBox(height: 8),
            for (final option in runtime.models)
              ListTile(
                contentPadding: EdgeInsets.zero,
                enabled: option.enabled,
                leading: Icon(
                  option.providerId == runtime.providerId &&
                          option.modelId == runtime.modelId
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color:
                      option.providerId == runtime.providerId &&
                          option.modelId == runtime.modelId
                      ? zt.accent
                      : zt.textLo,
                ),
                title: Text(
                  option.displayName,
                  style: TextStyle(color: zt.textHi),
                ),
                subtitle: Text(
                  option.enabled
                      ? [
                          option.providerLabel ?? option.providerId,
                          if (option.contextWindow != null)
                            '${_formatRuntimeTokens(option.contextWindow!)} ctx',
                        ].join(' · ')
                      : '不可用：${option.disabledReason ?? 'disabled'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: option.enabled
                    ? () => Navigator.pop(context, option)
                    : null,
              ),
          ],
        ),
      ),
    );
  }
}

class _RuntimeThoughtSheet extends StatelessWidget {
  const _RuntimeThoughtSheet({required this.runtime});

  final ConversationRuntimeConfig runtime;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '思考强度',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: zt.textHi,
              ),
            ),
            const SizedBox(height: 8),
            for (final option in runtime.thoughtOptions)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  option.value == runtime.thoughtLevel
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: option.value == runtime.thoughtLevel
                      ? zt.accent
                      : zt.textLo,
                ),
                title: Text(
                  option.displayName,
                  style: TextStyle(color: zt.textHi),
                ),
                subtitle: option.description == null
                    ? null
                    : Text(option.description!),
                onTap: () => Navigator.pop(context, option),
              ),
          ],
        ),
      ),
    );
  }
}

String _formatRuntimeTokens(int value) {
  if (value < 1000) return '$value';
  if (value < 1000000) return '${(value / 1000).toStringAsFixed(1)}k';
  return '${(value / 1000000).toStringAsFixed(1)}m';
}

class _InfoSheet extends StatelessWidget {
  const _InfoSheet({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: zt.textHi,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              body,
              style: TextStyle(fontSize: 13, height: 1.55, color: zt.textLo),
            ),
          ],
        ),
      ),
    );
  }
}

/// Settings navigation mirrors the renderer's sidebar categories.  It is a
/// native mobile presentation of the same information architecture, so the
/// user does not land on the former generic four-tab settings page.
class ZCodeSettingsPage extends ConsumerWidget {
  const ZCodeSettingsPage({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zt = context.zt;
    return Scaffold(
      backgroundColor: zt.bg,
      appBar: AppBar(
        backgroundColor: zt.surface,
        leading: IconButton(
          onPressed: onBack,
          icon: Icon(Icons.arrow_back_rounded, color: zt.textLo),
        ),
        title: Text(
          '设置',
          style: TextStyle(color: zt.textHi, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            onPressed: () {},
            icon: Icon(Icons.more_horiz_rounded, color: zt.textLo),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: zt.hairline),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            if (constraints.maxWidth >= 800)
              SizedBox(width: 246, child: _settingsNav(context, ref)),
            Expanded(child: _settingsList(context, ref)),
          ],
        ),
      ),
    );
  }

  Widget _settingsNav(BuildContext context, WidgetRef ref) {
    final zt = context.zt;
    return Container(
      decoration: BoxDecoration(
        color: zt.surface,
        border: Border(right: BorderSide(color: zt.hairline)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 18),
            child: Text(
              'ZCode',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: zt.textHi,
              ),
            ),
          ),
          _settingsNavItem(context, Icons.settings_outlined, '设置', true),
          const Spacer(),
          Text(
            'ZCode 3.11.2',
            style: TextStyle(fontSize: 11, color: zt.textLo),
          ),
        ],
      ),
    );
  }

  Widget _settingsNavItem(
    BuildContext context,
    IconData icon,
    String label,
    bool selected,
  ) {
    final zt = context.zt;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: selected ? zt.surfaceHi : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        children: [
          Icon(icon, size: 17, color: selected ? zt.textHi : zt.textLo),
          const SizedBox(width: 9),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: selected ? zt.textHi : zt.textLo,
            ),
          ),
        ],
      ),
    );
  }

  Widget _settingsList(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
      children: [
        _settingsSection(context, '基础设置', [
          _SettingEntry(
            Icons.tune_rounded,
            '常规',
            '通知和本地行为',
            () => _openGeneral(context),
          ),
          _SettingEntry(
            Icons.palette_outlined,
            '外观',
            '浅色 / 深色 / 跟随系统',
            () => _openAppearance(context, ref),
          ),
          _SettingEntry(
            Icons.hub_outlined,
            '模型设置',
            '管理模型供应商和可选模型',
            () => _openModelSettings(context, ref),
          ),
          _SettingEntry(
            Icons.public_rounded,
            '浏览器控制',
            '浏览器工具和远程控制权限',
            () => _showInfo(context, '浏览器控制', '浏览器控制会通过原生工具服务接入。'),
          ),
        ]),
        _settingsSection(context, 'Agent 能力', [
          _SettingEntry(
            Icons.psychology_outlined,
            '记忆',
            '工作区长期上下文',
            () => _openPanel(context, ref, SettingsPanel.memory),
          ),
          _SettingEntry(
            Icons.account_tree_outlined,
            '子智能体',
            '管理已安装的子智能体',
            () => _openPanel(context, ref, SettingsPanel.subagents),
          ),
          _SettingEntry(
            Icons.widgets_outlined,
            '插件',
            '插件和市场安装项',
            () => _openPanel(context, ref, SettingsPanel.plugins),
          ),
          _SettingEntry(
            Icons.extension_outlined,
            'MCP 服务器',
            '服务器状态和启用项',
            () => _openPanel(context, ref, SettingsPanel.mcpServers),
          ),
          _SettingEntry(
            Icons.auto_awesome_outlined,
            '技能',
            '技能目录和启用状态',
            () => _openPanel(context, ref, SettingsPanel.skills),
          ),
          _SettingEntry(
            Icons.terminal_outlined,
            '命令',
            '自定义命令',
            () => _openPanel(context, ref, SettingsPanel.commands),
          ),
          _SettingEntry(
            Icons.bolt_outlined,
            '钩子',
            '会话生命周期钩子',
            () => _openPanel(context, ref, SettingsPanel.hooks),
          ),
        ]),
        _settingsSection(context, '数据与统计', [
          _SettingEntry(
            Icons.manage_search_outlined,
            '索引库',
            '记忆和代码索引状态',
            () => _openPanel(context, ref, SettingsPanel.indexing),
          ),
          _SettingEntry(
            Icons.insights_outlined,
            '使用统计',
            'Token 趋势、模型占比和活动',
            () => _openPanel(context, ref, SettingsPanel.usage),
          ),
        ]),
        const SizedBox(height: 8),
        Center(
          child: TextButton.icon(
            onPressed: () =>
                _showInfo(context, 'ZCode 使用指南', '官方桌面端的帮助入口会在原生能力接入后打开。'),
            icon: const Icon(Icons.menu_book_outlined, size: 16),
            label: const Text('使用指南'),
          ),
        ),
      ],
    );
  }

  Widget _settingsSection(
    BuildContext context,
    String title,
    List<_SettingEntry> entries,
  ) {
    final zt = context.zt;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 2, 7),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: zt.textLo,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: zt.surface,
              border: Border.all(color: zt.hairline),
              borderRadius: BorderRadius.circular(9),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < entries.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: zt.hairline),
                  _settingRow(context, entries[i]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _settingRow(BuildContext context, _SettingEntry entry) {
    final zt = context.zt;
    return InkWell(
      onTap: entry.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            Icon(entry.icon, size: 18, color: zt.textLo),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    style: TextStyle(fontSize: 13, color: zt.textHi),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    entry.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: zt.textLo),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 18, color: zt.textLo),
          ],
        ),
      ),
    );
  }

  void _openGeneral(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ZCodeGeneralPreviewPage()),
    );
  }

  Future<void> _openAppearance(BuildContext context, WidgetRef ref) async {
    final current = ref.read(themeModeProvider);
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: context.zt.surface,
      builder: (_) => _ChoiceSheet(
        title: '外观',
        selected: current,
        options: const [kThemeSystem, kThemeLight, kThemeDark],
      ),
    );
    if (selected != null) {
      await ref.read(themeModeProvider.notifier).set(selected);
    }
  }

  void _openModelSettings(BuildContext context, WidgetRef ref) {
    final target = _liveTarget(ref);
    if (target == null) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const ZCodeModelPreviewPage()),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NativeModelPage(
          deviceId: target.deviceId,
          workspacePath: target.workspacePath,
        ),
      ),
    );
  }

  void _openPanel(BuildContext context, WidgetRef ref, SettingsPanel panel) {
    final target = _liveTarget(ref);
    if (target == null) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ZCodePanelPreviewPage(panel: panel),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPanelPage(
          panel: panel,
          deviceId: target.deviceId,
          workspacePath: target.workspacePath,
        ),
      ),
    );
  }

  ({String deviceId, String workspacePath})? _liveTarget(WidgetRef ref) {
    for (final entry in ref.read(relaySourceProvider).entries) {
      if (!entry.value.isLive) continue;
      final path = entry.value.workspaceKey?.trim();
      if (path != null && path.isNotEmpty) {
        return (deviceId: entry.key, workspacePath: path);
      }
    }
    return null;
  }

  void _showInfo(BuildContext context, String title, String body) =>
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了'),
            ),
          ],
        ),
      );

  String panelTitle(SettingsPanel panel) => switch (panel) {
    SettingsPanel.memory => '记忆',
    SettingsPanel.subagents => '子智能体',
    SettingsPanel.plugins => '插件',
    SettingsPanel.mcpServers => 'MCP 服务器',
    SettingsPanel.skills => '技能',
    SettingsPanel.commands => '命令',
    SettingsPanel.hooks => '钩子',
    SettingsPanel.indexing => '索引库',
    SettingsPanel.usage => '使用统计',
    SettingsPanel.outputStyles => '输出样式',
  };
}

class _SettingEntry {
  const _SettingEntry(this.icon, this.title, this.subtitle, this.onTap);

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
}

class ZCodeModelPreviewPage extends StatelessWidget {
  const ZCodeModelPreviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Scaffold(
      backgroundColor: zt.bg,
      appBar: AppBar(title: const Text('模型设置'), backgroundColor: zt.surface),
      body: Center(
        child: SizedBox(
          width: 19,
          height: 19,
          child: CircularProgressIndicator(strokeWidth: 1.7, color: zt.textLo),
        ),
      ),
    );
  }
}

class ZCodeGeneralPreviewPage extends StatelessWidget {
  const ZCodeGeneralPreviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Scaffold(
      backgroundColor: zt.bg,
      appBar: AppBar(
        title: const Text('常规'),
        backgroundColor: zt.surface,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: zt.hairline),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
        children: [
          _PreviewSection(
            title: '应用行为',
            children: [
              _PreviewRow(
                icon: Icons.notifications_none_rounded,
                title: '通知',
                value: '已启用',
              ),
              _PreviewRow(
                icon: Icons.refresh_rounded,
                title: '启动时恢复上次会话',
                value: '已启用',
              ),
            ],
          ),
          _PreviewSection(
            title: '本地数据',
            children: [
              _PreviewRow(
                icon: Icons.storage_outlined,
                title: '缓存和索引',
                value: '保存在本机',
              ),
              _PreviewRow(
                icon: Icons.security_outlined,
                title: '凭据存储',
                value: '系统安全存储',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class ZCodePanelPreviewPage extends StatelessWidget {
  const ZCodePanelPreviewPage({super.key, required this.panel});

  final SettingsPanel panel;

  String get _title => switch (panel) {
    SettingsPanel.skills => '技能',
    SettingsPanel.mcpServers => 'MCP 服务器',
    SettingsPanel.plugins => '插件',
    SettingsPanel.commands => '命令',
    SettingsPanel.subagents => '子智能体',
    SettingsPanel.hooks => '钩子',
    SettingsPanel.memory => '记忆',
    SettingsPanel.usage => '使用统计',
    SettingsPanel.indexing => '索引库',
    SettingsPanel.outputStyles => '输出样式',
  };

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Scaffold(
      backgroundColor: zt.bg,
      appBar: AppBar(
        title: Text(_title),
        backgroundColor: zt.surface,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: zt.hairline),
        ),
      ),
      body: Center(
        child: SizedBox(
          width: 19,
          height: 19,
          child: CircularProgressIndicator(strokeWidth: 1.7, color: zt.textLo),
        ),
      ),
    );
  }
}

class _PreviewSection extends StatelessWidget {
  const _PreviewSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 2, 7),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 11,
                color: zt.textLo,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: zt.surface,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: zt.hairline),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: zt.hairline),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: zt.textLo),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: TextStyle(fontSize: 13, color: zt.textHi),
            ),
          ),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 11, color: zt.textLo),
            ),
          ),
        ],
      ),
    );
  }
}

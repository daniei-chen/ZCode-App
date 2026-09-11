import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/plugin_status.dart';
import '../native/bootstrap/native_bootstrap_coordinator.dart';
import '../state/plugins.dart';
import '../theme.dart';
import 'resource_list_view.dart';

/// 插件面板。
///
/// 目录来自 `plugins.getOverview`，注册的 MCP 服务状态来自
/// `plugin-management.getPluginsOverview`。两个响应分开解析，避免把一个
/// “服务列表”误当成“已安装插件列表”，也是之前页面看起来像空壳的主要原因。
class PluginsPage extends ConsumerStatefulWidget {
  const PluginsPage({
    super.key,
    required this.deviceId,
    required this.workspacePath,
  });

  final String deviceId;
  final String workspacePath;

  @override
  ConsumerState<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends ConsumerState<PluginsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    // Pending intent: if the page opened before the agent handshake finished,
    // run the load once the device becomes ready instead of leaving a stale
    // error that asks the user to retry by hand.
    ref.listenManual(
      nativeBootstrapProvider((deviceId: widget.deviceId, sessionId: null)),
      (prev, next) {
        if (!(prev?.draftCreateReady ?? false) && next.draftCreateReady) {
          _load();
        }
      },
    );
  }

  void _load({bool refresh = false}) => ref
      .read(pluginStatusProvider.notifier)
      .load(
        deviceId: widget.deviceId,
        workspacePath: widget.workspacePath,
        refresh: refresh,
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final st = ref.watch(
      pluginStatusProvider.select(
        (m) =>
            m[PluginStatusNotifier.keyOf(
              widget.deviceId,
              widget.workspacePath,
            )] ??
            const PluginStatusState(),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.panelPluginsTitle),
        actions: [
          IconButton(
            tooltip: l10n.conversationRefresh,
            icon: const Icon(Icons.refresh_rounded, size: 19),
            color: context.zt.textLo,
            onPressed: () => _load(refresh: true),
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ResourceListView(
              items: st.displayItems,
              loading: st.loading,
              error: st.error,
              phase: st.phase,
              sourceMethod: st.method,
              onRetry: _load,
              leadingIcon: Icons.widgets_outlined,
              emptyText: l10n.resourceEmpty,
              emptyHint: l10n.pluginsEmptyHint,
              onToggle: (entry, enabled) {
                final plugin = entry is PluginPackageEntry ? entry : null;
                if (plugin == null || !plugin.installed) return;
                _setEnabled(plugin, enabled);
              },
              readOnlyNote: (entry) => entry is PluginPackageEntry
                  ? entry.installed
                        ? ''
                        : '目录读取成功；安装操作需桌面端确认'
                  : l10n.pluginsReadOnly,
              showStatusFilter: true,
            ),
          ),
          _ScopeNote(
            text: l10n.pluginsScopeNote,
            connected: st.connectedCount,
            total: st.items.length,
            installed: st.installedCount,
            available: st.availableCount,
            marketplaces: st.marketplaceCount,
          ),
        ],
      ),
    );
  }

  Future<void> _setEnabled(PluginPackageEntry plugin, bool enabled) async {
    final result = await ref
        .read(pluginStatusProvider.notifier)
        .setEnabled(
          deviceId: widget.deviceId,
          workspacePath: widget.workspacePath,
          id: plugin.id,
          enabled: enabled,
        );
    if (!mounted || result.ok) return;
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          isZh
              ? '插件状态未改变 · ${result.safeLabel}'
              : 'Plugin state was not changed · ${result.safeLabel}',
        ),
      ),
    );
  }
}

/// 底部范围说明。写清「这只是插件提供的那部分」，
/// 免得让人以为整个插件/MCP 面板就这些。
class _ScopeNote extends StatelessWidget {
  const _ScopeNote({
    required this.text,
    required this.connected,
    required this.total,
    required this.installed,
    required this.available,
    required this.marketplaces,
  });

  final String text;
  final int connected;
  final int total;
  final int installed;
  final int available;
  final int marketplaces;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final zt = context.zt;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: zt.hairline)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (installed > 0 || available > 0 || marketplaces > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '插件 $installed 已安装 · $available 可用 · $marketplaces 个市场',
                style: TextStyle(fontSize: 11.5, color: zt.textLo),
              ),
            ),
          if (total > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                l10n.pluginsConnectedSummary(connected, total),
                style: TextStyle(fontSize: 11.5, color: zt.textLo),
              ),
            ),
          Text(
            text,
            style: TextStyle(fontSize: 11, height: 1.5, color: zt.textLo),
          ),
        ],
      ),
    );
  }
}

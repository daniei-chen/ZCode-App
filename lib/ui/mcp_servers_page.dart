import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/mcp_server.dart';
import '../native/bootstrap/native_bootstrap_coordinator.dart';
import '../state/mcp_servers.dart';
import '../theme.dart';
import 'resource_list_view.dart';

/// MCP 服务器面板。
///
/// 当前接入的是桌面端本地用户目录候选列表。配置中的 headers / token
/// 不进入列表模型；本地条目用桌面端安全写接口切换启用状态，远端镜像只读。
class McpServersPage extends ConsumerStatefulWidget {
  const McpServersPage({
    super.key,
    required this.deviceId,
    required this.workspacePath,
  });

  final String deviceId;
  final String workspacePath;

  @override
  ConsumerState<McpServersPage> createState() => _McpServersPageState();
}

class _McpServersPageState extends ConsumerState<McpServersPage> {
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
      .read(mcpServerProvider.notifier)
      .load(
        deviceId: widget.deviceId,
        workspacePath: widget.workspacePath,
        refresh: refresh,
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(
      mcpServerProvider.select(
        (m) =>
            m[McpServerNotifier.keyOf(widget.deviceId, widget.workspacePath)] ??
            const McpServerState(),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.panelMcpTitle),
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
              items: state.displayItems,
              loading: state.loading,
              error: state.error,
              phase: state.phase,
              sourceMethod: state.method,
              onRetry: _load,
              leadingIcon: Icons.extension_outlined,
              emptyText: l10n.resourceEmpty,
              emptyHint: l10n.panelMcpEmptyHint,
              onToggle: (entry, enabled) {
                final item = entry is McpServerEntry ? entry : null;
                if (item == null || item.remote) return;
                _setEnabled(item, enabled);
              },
              readOnlyNote: (entry) => entry is McpServerEntry && entry.remote
                  ? l10n.mcpReadOnly
                  : '',
              showStatusFilter: true,
            ),
          ),
          _ScopeNote(text: l10n.mcpScopeNote, total: state.displayItems.length),
        ],
      ),
    );
  }

  Future<void> _setEnabled(McpServerEntry item, bool enabled) async {
    final result = await ref
        .read(mcpServerProvider.notifier)
        .setEnabled(
          deviceId: widget.deviceId,
          workspacePath: widget.workspacePath,
          id: item.id,
          enabled: enabled,
        );
    if (!mounted || result.ok) return;
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          isZh
              ? 'MCP 状态未改变 · ${result.safeLabel}'
              : 'MCP state was not changed · ${result.safeLabel}',
        ),
      ),
    );
  }
}

class _ScopeNote extends StatelessWidget {
  const _ScopeNote({required this.text, required this.total});

  final String text;
  final int total;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: zt.hairline)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      child: Text(
        total == 0 ? text : '$total · $text',
        style: TextStyle(fontSize: 11, height: 1.5, color: zt.textLo),
      ),
    );
  }
}

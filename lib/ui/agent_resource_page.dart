import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../native/bootstrap/native_bootstrap_coordinator.dart';
import '../state/agent_capabilities.dart';
import '../theme.dart';
import 'resource_list_view.dart';

/// 独立 Agent service 的原生资源页。
///
/// 页面只显示白名单字段，写操作暂不凭猜测接入。这样即使某个桌面版本
/// 缺少列表方法，也会得到明确错误，而不是回落到嵌套 WebView 或假数据。
class AgentResourcePage extends ConsumerStatefulWidget {
  const AgentResourcePage({
    super.key,
    required this.deviceId,
    required this.workspacePath,
    required this.capability,
    required this.title,
    required this.emptyHint,
    required this.icon,
  });

  final String deviceId;
  final String workspacePath;
  final AgentCapability capability;
  final String title;
  final String emptyHint;
  final IconData icon;

  @override
  ConsumerState<AgentResourcePage> createState() => _AgentResourcePageState();
}

class _AgentResourcePageState extends ConsumerState<AgentResourcePage> {
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
      .read(agentCapabilityProvider.notifier)
      .load(
        deviceId: widget.deviceId,
        workspacePath: widget.workspacePath,
        capability: widget.capability,
        refresh: refresh,
      );

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(
      agentCapabilityProvider.select(
        (m) =>
            m[AgentCapabilityNotifier.keyOf(
              widget.deviceId,
              widget.workspacePath,
              widget.capability,
            )] ??
            const AgentCapabilityState(),
      ),
    );
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: l10n.conversationRefresh,
            icon: const Icon(Icons.refresh_rounded, size: 19),
            color: context.zt.textLo,
            onPressed: state.loading ? null : () => _load(refresh: true),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: context.zt.hairline),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ResourceListView(
              items: state.items,
              loading: state.loading,
              error: state.error,
              phase: state.phase,
              sourceMethod: state.method,
              onRetry: () => _load(refresh: true),
              leadingIcon: widget.icon,
              emptyText: l10n.resourceEmpty,
              emptyHint: widget.emptyHint,
              showStatusFilter: widget.capability != AgentCapability.memory,
              readOnlyNote: (_) => '原生通道只读展示',
            ),
          ),
          _CapabilityFootnote(method: state.method, icon: widget.icon),
        ],
      ),
    );
  }
}

class _CapabilityFootnote extends StatelessWidget {
  const _CapabilityFootnote({required this.method, required this.icon});

  final String? method;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 9, 14, 13),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: zt.hairline)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: zt.textLo),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              method == null
                  ? '等待原生 Agent service 响应'
                  : '原生已接入 · $method · 写操作保持显式确认',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: zt.textLo),
            ),
          ),
        ],
      ),
    );
  }
}

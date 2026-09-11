import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/feature_catalog.dart';
import '../state/agent_capabilities.dart';
import '../state/relay_source.dart';
import '../state/session_pool.dart';
import '../theme.dart';
import 'agent_resource_page.dart';
import 'panels_page.dart';
import 'settings_panel_page.dart';

/// Native capability map for the mobile app.
///
/// This page is deliberately a status surface, not a fake marketplace: a
/// service that is not wired says why, while a wired resource opens the real
/// native page.  It makes the boundary visible instead of hiding it behind a
/// blank loading spinner.
class FeatureCatalogPage extends ConsumerStatefulWidget {
  const FeatureCatalogPage({super.key});

  @override
  ConsumerState<FeatureCatalogPage> createState() => _FeatureCatalogPageState();
}

enum _FeatureFilter { all, wired, readOnly, pending, restricted }

class _FeatureCatalogPageState extends ConsumerState<FeatureCatalogPage> {
  final _search = TextEditingController();
  _FeatureFilter _filter = _FeatureFilter.all;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final devices = ref.watch(deviceListProvider);
    final relay = ref.watch(relaySourceProvider);
    final scope = PanelsPage.nativeScope(devices, relay);
    final query = _search.text.trim().toLowerCase();
    final filtered = NativeFeatureCatalog.all.where((item) {
      final matchesQuery =
          query.isEmpty ||
          item.service.toLowerCase().contains(query) ||
          item.titleZh.toLowerCase().contains(query) ||
          item.titleEn.toLowerCase().contains(query) ||
          item.summaryZh.toLowerCase().contains(query);
      return matchesQuery && _matchesFilter(item);
    }).toList();
    final grouped = <String, List<NativeFeatureSpec>>{};
    for (final item in filtered) {
      final group = isZh ? item.groupZh : item.groupEn;
      grouped.putIfAbsent(group, () => []).add(item);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(isZh ? '功能与兼容' : 'Features and compatibility'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: Column(
        children: [
          _Header(
            isZh: isZh,
            connected: scope?.ready == true,
            wired: NativeFeatureCatalog.count(NativeFeatureAccess.native),
            readOnly: NativeFeatureCatalog.count(NativeFeatureAccess.readOnly),
            pending: NativeFeatureCatalog.count(NativeFeatureAccess.pending),
            restricted: NativeFeatureCatalog.count(
              NativeFeatureAccess.restricted,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: isZh ? '搜索服务或功能' : 'Search services or features',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: isZh ? '清除' : 'Clear',
                        onPressed: () {
                          _search.clear();
                          setState(() {});
                        },
                        icon: const Icon(Icons.close),
                      ),
              ),
            ),
          ),
          _FilterBar(
            isZh: isZh,
            selected: _filter,
            onSelected: (value) => setState(() => _filter = value),
          ),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Text(
                      isZh ? '没有匹配的功能' : 'No matching features',
                      style: TextStyle(color: context.zt.textLo),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 28),
                    children: [
                      for (final group in grouped.entries) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 14, 4, 7),
                          child: Text(
                            group.key,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: context.zt.textLo,
                            ),
                          ),
                        ),
                        _FeatureSection(
                          items: group.value,
                          isZh: isZh,
                          connected: scope?.ready == true,
                          onOpen: (item) => _openFeature(item, scope),
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  bool _matchesFilter(NativeFeatureSpec item) => switch (_filter) {
    _FeatureFilter.all => true,
    _FeatureFilter.wired => item.access == NativeFeatureAccess.native,
    _FeatureFilter.readOnly => item.access == NativeFeatureAccess.readOnly,
    _FeatureFilter.pending => item.access == NativeFeatureAccess.pending,
    _FeatureFilter.restricted => item.access == NativeFeatureAccess.restricted,
  };

  void _openFeature(NativeFeatureSpec item, NativeWorkbenchScope? scope) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    if (item.panel == 'system') {
      if (scope == null || !scope.ready) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isZh
                  ? '请先连接并等待桌面 Agent 就绪'
                  : 'Connect and wait for the desktop Agent',
            ),
          ),
        );
        return;
      }
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AgentResourcePage(
            deviceId: scope.deviceId,
            workspacePath: scope.workspacePath,
            capability: AgentCapability.system,
            title: isZh ? '系统信息' : 'System diagnostics',
            emptyHint: isZh
                ? '桌面端未返回安全诊断信息'
                : 'The desktop returned no safe diagnostic fields',
            icon: Icons.info_outline,
          ),
        ),
      );
      return;
    }
    final panel = _panelFor(item.panel);
    if (panel == null) {
      _showDetails(item, isZh);
      return;
    }
    if (scope == null || !scope.ready || scope.workspacePath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isZh
                ? '请先连接并等待桌面 Agent 就绪'
                : 'Connect and wait for the desktop Agent',
          ),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPanelPage(
          panel: panel,
          deviceId: scope.deviceId,
          workspacePath: scope.workspacePath,
        ),
      ),
    );
  }

  SettingsPanel? _panelFor(String? value) => switch (value) {
    'skills' => SettingsPanel.skills,
    'mcpServers' => SettingsPanel.mcpServers,
    'plugins' => SettingsPanel.plugins,
    'commands' => SettingsPanel.commands,
    'subagents' => SettingsPanel.subagents,
    'hooks' => SettingsPanel.hooks,
    'memory' => SettingsPanel.memory,
    'usage' => SettingsPanel.usage,
    'indexing' => SettingsPanel.indexing,
    'outputStyles' => SettingsPanel.outputStyles,
    _ => null,
  };

  void _showDetails(NativeFeatureSpec item, bool isZh) {
    final zt = context.zt;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isZh ? item.titleZh : item.titleEn,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                item.service,
                style: TextStyle(
                  fontSize: 12,
                  color: zt.textLo,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(height: 16),
              Text(
                isZh ? item.summaryZh : item.summaryEn,
                style: TextStyle(fontSize: 14, height: 1.5, color: zt.textHi),
              ),
              const SizedBox(height: 14),
              Text(
                '${isZh ? '方法范围' : 'Method surface'}: ${item.methods.join(' · ')}',
                style: TextStyle(fontSize: 12, height: 1.5, color: zt.textLo),
              ),
              const SizedBox(height: 16),
              Text(
                isZh
                    ? '未显示操作按钮：当前项目尚未验证该写入协议或设备权限。'
                    : 'No action button is shown until the write protocol or device permission is verified.',
                style: TextStyle(fontSize: 12, height: 1.5, color: zt.warn),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.isZh,
    required this.connected,
    required this.wired,
    required this.readOnly,
    required this.pending,
    required this.restricted,
  });

  final bool isZh;
  final bool connected;
  final int wired;
  final int readOnly;
  final int pending;
  final int restricted;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Row(
        children: [
          Icon(
            connected ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
            size: 22,
            color: connected ? zt.live : zt.textLo,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isZh
                  ? '${NativeFeatureCatalog.all.length} 个桌面服务 · 已接入 $wired · 只读 $readOnly · 待接入 $pending · 受限制 $restricted'
                  : '${NativeFeatureCatalog.all.length} desktop services · $wired native · $readOnly read-only · $pending pending · $restricted restricted',
              style: TextStyle(fontSize: 12.5, color: zt.textLo),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.isZh,
    required this.selected,
    required this.onSelected,
  });

  final bool isZh;
  final _FeatureFilter selected;
  final ValueChanged<_FeatureFilter> onSelected;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
    child: Row(
      children: [
        for (final filter in _FeatureFilter.values)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: Text(_label(filter)),
              selected: selected == filter,
              onSelected: (_) => onSelected(filter),
            ),
          ),
      ],
    ),
  );

  String _label(_FeatureFilter filter) => switch (filter) {
    _FeatureFilter.all => isZh ? '全部' : 'All',
    _FeatureFilter.wired => isZh ? '已接入' : 'Native',
    _FeatureFilter.readOnly => isZh ? '只读' : 'Read-only',
    _FeatureFilter.pending => isZh ? '待接入' : 'Pending',
    _FeatureFilter.restricted => isZh ? '受限制' : 'Restricted',
  };
}

class _FeatureSection extends StatelessWidget {
  const _FeatureSection({
    required this.items,
    required this.isZh,
    required this.connected,
    required this.onOpen,
  });

  final List<NativeFeatureSpec> items;
  final bool isZh;
  final bool connected;
  final ValueChanged<NativeFeatureSpec> onOpen;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(14),
    child: Container(
      decoration: BoxDecoration(
        color: context.zt.surface,
        border: Border.all(color: context.zt.hairline),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++)
            _FeatureRow(
              item: items[i],
              isZh: isZh,
              connected: connected,
              showDivider: i < items.length - 1,
              onTap: () => onOpen(items[i]),
            ),
        ],
      ),
    ),
  );
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.item,
    required this.isZh,
    required this.connected,
    required this.showDivider,
    required this.onTap,
  });

  final NativeFeatureSpec item;
  final bool isZh;
  final bool connected;
  final bool showDivider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    final status = _status(zt);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          decoration: BoxDecoration(
            border: showDivider
                ? Border(bottom: BorderSide(color: zt.hairline))
                : null,
          ),
          child: Row(
            children: [
              Icon(_icon, size: 21, color: status.color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isZh ? item.titleZh : item.titleEn,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: zt.textHi,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      isZh ? item.summaryZh : item.summaryEn,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.45,
                        color: zt.textLo,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.service,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: zt.textLo,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    status.label,
                    style: TextStyle(
                      fontSize: 11,
                      color: status.color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Icon(
                    item.panel != null
                        ? Icons.chevron_right
                        : Icons.info_outline,
                    size: 18,
                    color: zt.textLo,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData get _icon => switch (item.access) {
    NativeFeatureAccess.native => Icons.check_circle_outline,
    NativeFeatureAccess.readOnly => Icons.visibility_outlined,
    NativeFeatureAccess.pending => Icons.hourglass_empty,
    NativeFeatureAccess.restricted => Icons.lock_outline,
  };

  ({String label, Color color}) _status(ZTPalette zt) {
    if (!connected &&
        (item.access == NativeFeatureAccess.native ||
            item.access == NativeFeatureAccess.readOnly)) {
      return (label: isZh ? '待连接' : 'Offline', color: zt.textLo);
    }
    return switch (item.access) {
      NativeFeatureAccess.native => (
        label: isZh ? '已接入' : 'Native',
        color: zt.live,
      ),
      NativeFeatureAccess.readOnly => (
        label: isZh ? '只读' : 'Read-only',
        color: zt.accent,
      ),
      NativeFeatureAccess.pending => (
        label: isZh ? '待接入' : 'Pending',
        color: zt.warn,
      ),
      NativeFeatureAccess.restricted => (
        label: isZh ? '受限制' : 'Restricted',
        color: zt.danger,
      ),
    };
  }
}

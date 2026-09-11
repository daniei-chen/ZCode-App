import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../state/agent_capabilities.dart';
import '../theme.dart';
import 'agent_resource_page.dart';
import 'agent_usage_page.dart';
import 'mcp_servers_page.dart';
import 'plugins_page.dart';
import 'skills_page.dart';

/// 设置里「Agent 能力 / 数据与统计」下的各个面板。
///
/// 分组与命名对齐官方侧边栏（`settings.sidebar.group.*`）：
/// 基础设置 / Agent 能力 / 数据与统计。
enum SettingsPanel {
  skills,
  mcpServers,
  plugins,
  commands,
  subagents,
  hooks,
  memory,
  usage,
  indexing,
  outputStyles;

  bool get isWired => true;

  IconData get icon => switch (this) {
    SettingsPanel.skills => Icons.auto_awesome_outlined,
    SettingsPanel.mcpServers => Icons.extension_outlined,
    SettingsPanel.plugins => Icons.widgets_outlined,
    SettingsPanel.commands => Icons.terminal_outlined,
    SettingsPanel.subagents => Icons.hub_outlined,
    SettingsPanel.hooks => Icons.bolt_outlined,
    SettingsPanel.memory => Icons.psychology_outlined,
    SettingsPanel.usage => Icons.insights_outlined,
    SettingsPanel.indexing => Icons.manage_search_outlined,
    SettingsPanel.outputStyles => Icons.style_outlined,
  };

  String title(AppLocalizations l10n) => switch (this) {
    SettingsPanel.skills => l10n.skillsTitle,
    SettingsPanel.mcpServers => l10n.panelMcpTitle,
    SettingsPanel.plugins => l10n.panelPluginsTitle,
    SettingsPanel.commands => l10n.panelCommandsTitle,
    SettingsPanel.subagents => l10n.panelSubagentsTitle,
    SettingsPanel.hooks => l10n.panelHooksTitle,
    SettingsPanel.memory => l10n.panelMemoryTitle,
    SettingsPanel.usage => l10n.panelUsageTitle,
    SettingsPanel.indexing => l10n.panelIndexingTitle,
    SettingsPanel.outputStyles => l10n.panelOutputStylesTitle,
  };

  String subtitle(AppLocalizations l10n) => switch (this) {
    SettingsPanel.skills => l10n.skillsSubtitle,
    SettingsPanel.mcpServers => l10n.panelMcpSubtitle,
    SettingsPanel.plugins => l10n.panelPluginsSubtitle,
    SettingsPanel.commands => l10n.panelCommandsSubtitle,
    SettingsPanel.subagents => l10n.panelSubagentsSubtitle,
    SettingsPanel.hooks => l10n.panelHooksSubtitle,
    SettingsPanel.memory => l10n.panelMemorySubtitle,
    SettingsPanel.usage => l10n.panelUsageSubtitle,
    SettingsPanel.indexing => l10n.panelIndexingSubtitle,
    SettingsPanel.outputStyles => l10n.panelOutputStylesSubtitle,
  };

  /// 该面板对应官方哪个服务/方法（占位页会展示，便于对照）。
  String get backing => switch (this) {
    SettingsPanel.skills => 'skills.list',
    SettingsPanel.mcpServers => 'mcp-sync.listLocalUserMcpCandidates',
    SettingsPanel.plugins => 'plugin-management.getPluginsOverview',
    SettingsPanel.commands => 'commands.generateCommandFileContent',
    SettingsPanel.subagents => 'subagents.list',
    SettingsPanel.hooks => 'hooks.loadHooks',
    SettingsPanel.memory => 'memory.loadMemory / memory.listProjectMemories',
    SettingsPanel.usage => 'usage-stats.getAppUsageStats',
    SettingsPanel.indexing => 'setting.get / setting.update（索引库是设置项，无独立服务）',
    SettingsPanel.outputStyles => 'output-style.listStyles',
  };
}

/// 面板路由：全部进入原生数据层；接口没有可靠实现时显示明确的原生错误。
class SettingsPanelPage extends StatelessWidget {
  const SettingsPanelPage({
    super.key,
    required this.panel,
    required this.deviceId,
    required this.workspacePath,
  });

  final SettingsPanel panel;
  final String deviceId;
  final String workspacePath;

  @override
  Widget build(BuildContext context) {
    if (panel.isWired) {
      return switch (panel) {
        SettingsPanel.skills => SkillsPage(
          deviceId: deviceId,
          workspacePath: workspacePath,
        ),
        SettingsPanel.mcpServers => McpServersPage(
          deviceId: deviceId,
          workspacePath: workspacePath,
        ),
        SettingsPanel.plugins => PluginsPage(
          deviceId: deviceId,
          workspacePath: workspacePath,
        ),
        SettingsPanel.commands => AgentResourcePage(
          deviceId: deviceId,
          workspacePath: workspacePath,
          capability: AgentCapability.commands,
          title: panel.title(AppLocalizations.of(context)!),
          emptyHint: AppLocalizations.of(context)!.panelCommandsEmptyHint,
          icon: panel.icon,
        ),
        SettingsPanel.subagents => AgentResourcePage(
          deviceId: deviceId,
          workspacePath: workspacePath,
          capability: AgentCapability.subagents,
          title: panel.title(AppLocalizations.of(context)!),
          emptyHint: AppLocalizations.of(context)!.panelSubagentsEmptyHint,
          icon: panel.icon,
        ),
        SettingsPanel.hooks => AgentResourcePage(
          deviceId: deviceId,
          workspacePath: workspacePath,
          capability: AgentCapability.hooks,
          title: panel.title(AppLocalizations.of(context)!),
          emptyHint: AppLocalizations.of(context)!.panelHooksEmptyHint,
          icon: panel.icon,
        ),
        SettingsPanel.memory => AgentResourcePage(
          deviceId: deviceId,
          workspacePath: workspacePath,
          capability: AgentCapability.memory,
          title: panel.title(AppLocalizations.of(context)!),
          emptyHint: AppLocalizations.of(context)!.panelMemoryEmptyHint,
          icon: panel.icon,
        ),
        SettingsPanel.indexing => AgentResourcePage(
          deviceId: deviceId,
          workspacePath: workspacePath,
          capability: AgentCapability.indexing,
          title: panel.title(AppLocalizations.of(context)!),
          emptyHint: '原生 setting.get 未返回索引相关设置',
          icon: panel.icon,
        ),
        SettingsPanel.outputStyles => AgentResourcePage(
          deviceId: deviceId,
          workspacePath: workspacePath,
          capability: AgentCapability.outputStyles,
          title: panel.title(AppLocalizations.of(context)!),
          emptyHint: AppLocalizations.of(context)!.panelOutputStylesEmptyHint,
          icon: panel.icon,
        ),
        SettingsPanel.usage => AgentUsagePage(
          deviceId: deviceId,
          workspacePath: workspacePath,
        ),
      };
    }
    return _NotWiredPage(panel: panel);
  }
}

/// 未接入面板的说明页。
///
/// 刻意不做成空白页或假数据：写清楚这里**将会**有什么、对应官方哪个接口，
/// 以及为什么现在还没有。空壳界面比"没有入口"更让人困惑。
class _NotWiredPage extends StatelessWidget {
  const _NotWiredPage({required this.panel});

  final SettingsPanel panel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final zt = context.zt;

    return Scaffold(
      appBar: AppBar(
        title: Text(panel.title(l10n)),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(panel.icon, size: 26, color: zt.textLo),
              const SizedBox(height: 14),
              Text(
                panel.subtitle(l10n),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, height: 1.5, color: zt.textHi),
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: zt.field,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: zt.hairline),
                ),
                child: Text(
                  panel.backing,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                    color: zt.textLo,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                l10n.panelNotWiredBody,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, height: 1.6, color: zt.textLo),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

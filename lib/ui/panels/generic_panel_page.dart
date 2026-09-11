import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/panel_state.dart';
import '../../theme.dart';

/// 通用列表面板：技能 / MCP / 插件 / 命令 / 钩子 / 记忆 共用模板。
class GenericPanelPage extends ConsumerWidget {
  const GenericPanelPage({required this.panelKey, super.key});

  final String panelKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final snapshots = ref.watch(panelDataProvider);
    var items = const <PanelItem>[];
    for (final s in snapshots.values) {
      final list = s.listPanels[panelKey];
      if (list != null && list.length > items.length) items = list;
    }

    final (title, icon, hue) = _styleOf(l10n);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: items.isEmpty
          ? _GuideEmpty(icon: icon, hue: hue, hint: _emptyHint(l10n))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                  child: Text(
                    l10n.panelsCount(items.length),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: context.zt.textLo,
                    ),
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.zt.surface,
                    border: Border.all(color: context.zt.hairline),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Column(
                      children: [
                        for (var i = 0; i < items.length; i++)
                          _ItemCard(
                            item: items[i],
                            hue: hue,
                            icon: icon,
                            showDivider: i < items.length - 1,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  (String, IconData, Color) _styleOf(AppLocalizations l10n) =>
      switch (panelKey) {
        PanelKeys.skills => (
          l10n.panelSkillsTitle,
          Icons.bolt_outlined,
          const Color(0xFFFFB35C),
        ),
        PanelKeys.mcp => (
          l10n.panelMcpTitle,
          Icons.extension_outlined,
          const Color(0xFF6FA8FF),
        ),
        PanelKeys.plugins => (
          l10n.panelPluginsTitle,
          Icons.widgets_outlined,
          const Color(0xFFFF8FB8),
        ),
        PanelKeys.commands => (
          l10n.panelCommandsTitle,
          Icons.terminal_outlined,
          const Color(0xFF7FE0C3),
        ),
        PanelKeys.hooks => (
          l10n.panelHooksTitle,
          Icons.settings_input_component_outlined,
          const Color(0xFFC9A86A),
        ),
        PanelKeys.outputStyles => (
          l10n.panelOutputStylesTitle,
          Icons.style_outlined,
          const Color(0xFFD7A7FF),
        ),
        _ => (
          l10n.panelMemoryTitle,
          Icons.psychology_outlined,
          const Color(0xFF9DB4FF),
        ),
      };

  String _emptyHint(AppLocalizations l10n) => switch (panelKey) {
    PanelKeys.skills => l10n.panelSkillsEmptyHint,
    PanelKeys.mcp => l10n.panelMcpEmptyHint,
    PanelKeys.plugins => l10n.panelPluginsEmptyHint,
    PanelKeys.commands => l10n.panelCommandsEmptyHint,
    PanelKeys.hooks => l10n.panelHooksEmptyHint,
    PanelKeys.outputStyles => l10n.panelOutputStylesEmptyHint,
    _ => l10n.panelMemoryEmptyHint,
  };
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({
    required this.item,
    required this.hue,
    required this.icon,
    required this.showDivider,
  });

  final PanelItem item;

  final Color hue;

  final IconData icon;

  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        border: showDivider
            ? Border(bottom: BorderSide(color: context.zt.hairline))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: hue),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: context.zt.textHi,
                  ),
                ),
              ),
              if (item.tag != null && item.tag!.isNotEmpty)
                Text(
                  item.tag!,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: hue,
                  ),
                ),
              if (item.enabled != null) ...[
                const SizedBox(width: 8),
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: item.enabled!
                        ? context.zt.live
                        : context.zt.textLo.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ],
          ),
          if (item.description != null && item.description!.isNotEmpty) ...[
            const SizedBox(height: 7),
            Text(
              item.description!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: context.zt.textLo,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _GuideEmpty extends StatelessWidget {
  const _GuideEmpty({
    required this.icon,
    required this.hue,
    required this.hint,
  });

  final IconData icon;

  final Color hue;

  final String hint;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: hue.withValues(alpha: 0.10),
              ),
              child: Icon(icon, size: 30, color: hue),
            ),
            const SizedBox(height: 14),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: context.zt.textLo,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

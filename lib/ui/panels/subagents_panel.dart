import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/panel_state.dart';
import '../../theme.dart';

/// 子代理面板：桌面端各子代理（subagent）的卡片视图。
class SubagentsPanelPage extends ConsumerWidget {
  const SubagentsPanelPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final snapshots = ref.watch(panelDataProvider);
    var subagents = const <SubagentInfo>[];
    for (final s in snapshots.values) {
      if (s.subagents.length > subagents.length) subagents = s.subagents;
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.panelSubagentsTitle)),
      body: subagents.isEmpty
          ? const _GuideEmpty()
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                  child: Text(
                    l10n.panelSubagentsCount(subagents.length),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: context.zt.textLo,
                    ),
                  ),
                ),
                for (final a in subagents) _AgentCard(agent: a),
              ],
            ),
    );
  }
}

class _AgentCard extends StatelessWidget {
  const _AgentCard({required this.agent});

  final SubagentInfo agent;

  @override
  Widget build(BuildContext context) {
    final hue = _hueOf(agent.name);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        hue.withValues(alpha: 0.30),
                        hue.withValues(alpha: 0.10),
                      ],
                    ),
                  ),
                  child: Icon(Icons.smart_toy_outlined, size: 18, color: hue),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    agent.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: context.zt.textHi,
                    ),
                  ),
                ),
                if (agent.model != null && agent.model!.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: context.zt.accent.withValues(alpha: 0.12),
                    ),
                    child: Text(
                      agent.model!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: context.zt.accent,
                      ),
                    ),
                  ),
              ],
            ),
            if (agent.description != null && agent.description!.isNotEmpty) ...[
              const SizedBox(height: 9),
              Text(
                agent.description!,
                maxLines: 3,
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
      ),
    );
  }

  static const _hues = [
    Color(0xFFB48CFF),
    Color(0xFF35D0E0),
    Color(0xFF3DDC85),
    Color(0xFFFFB35C),
    Color(0xFFFF8FB8),
    Color(0xFF6FA8FF),
  ];

  static Color _hueOf(String name) {
    var h = 0;
    for (final c in name.codeUnits) {
      h = (h * 31 + c) & 0xFFFF;
    }
    return _hues[h % _hues.length];
  }
}

class _GuideEmpty extends StatelessWidget {
  const _GuideEmpty();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
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
                color: const Color(0xFFB48CFF).withValues(alpha: 0.10),
              ),
              child: const Icon(
                Icons.groups_2_outlined,
                size: 30,
                color: Color(0xFFB48CFF),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              l10n.panelSubagentsEmptyHint,
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

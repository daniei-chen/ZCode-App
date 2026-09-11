import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/skill.dart';
import '../native/bootstrap/native_bootstrap_coordinator.dart';
import '../state/skills.dart';
import '../theme.dart';
import 'resource_list_view.dart';

/// 技能面板。
///
/// 数据来自 `zcode-agent.listSkills({workspacePath})`。
/// 这是「通用资源列表」的第一个真实接入 —— 其余面板
/// （MCP / 插件 / 命令 / 子智能体 / 钩子）后续套同一个组件即可。
class SkillsPage extends ConsumerStatefulWidget {
  const SkillsPage({
    super.key,
    required this.deviceId,
    required this.workspacePath,
  });

  final String deviceId;
  final String workspacePath;

  @override
  ConsumerState<SkillsPage> createState() => _SkillsPageState();
}

class _SkillsPageState extends ConsumerState<SkillsPage> {
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
      .read(skillsProvider.notifier)
      .load(
        deviceId: widget.deviceId,
        workspacePath: widget.workspacePath,
        refresh: refresh,
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final st = ref.watch(
      skillsProvider.select(
        (m) =>
            m[SkillsNotifier.keyOf(widget.deviceId, widget.workspacePath)] ??
            const SkillsState(),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.skillsTitle),
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
      body: ResourceListView(
        items: st.items,
        loading: st.loading,
        error: st.error,
        phase: st.phase,
        sourceMethod: st.method,
        onRetry: _load,
        leadingIcon: Icons.auto_awesome_outlined,
        emptyText: l10n.resourceEmpty,
        emptyHint: l10n.skillsEmptyHint,
        onToggle: (entry, enabled) {
          final skill = entry is SkillEntry ? entry : null;
          if (skill == null) return;
          _setEnabled(skill, enabled);
        },
        readOnlyNote: (entry) =>
            entry.readOnly ? l10n.skillsReadOnly : l10n.skillsToggleUnsupported,
      ),
    );
  }

  Future<void> _setEnabled(SkillEntry skill, bool enabled) async {
    final result = await ref
        .read(skillsProvider.notifier)
        .setEnabled(
          deviceId: widget.deviceId,
          workspacePath: widget.workspacePath,
          id: skill.id,
          enabled: enabled,
        );
    if (!mounted || result.ok) return;
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          isZh
              ? '技能状态未改变 · ${result.safeLabel}'
              : 'Skill state was not changed · ${result.safeLabel}',
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../state/panel_state.dart';
import '../state/relay_source.dart';
import '../state/session_pool.dart';
import '../theme.dart';
import 'native_model_page.dart';
import 'panels/generic_panel_page.dart';
import 'panels/model_panel.dart';
import 'panels/subagents_panel.dart';
import 'panels/usage_panel.dart';
import 'settings_panel_page.dart';

/// The device + workspace a native workbench page reads from.
typedef NativeWorkbenchScope = ({
  String deviceId,
  String workspacePath,
  bool ready,
  String statusLabel,
});

/// 工作台：ZCode 桌面端设置面板的原生移动版。
///
/// 支持 Relay 的设备走原生 service RPC 页面，数据严格按设备/工作区隔离；
/// 只有不支持 Relay 的旧设备才回落到远控页桥接流量的被动解析。
class PanelsPage extends ConsumerWidget {
  const PanelsPage({super.key});

  /// Pick the relay device the workbench shows. Prefer the active device when
  /// it supports Relay; otherwise use a ready relay device, then the first
  /// relay-capable device so pages can auto-load once it is ready.
  static NativeWorkbenchScope? nativeScope(
    List<RemoteDevice> devices,
    Map<String, RelaySourceState> relay, {
    String? preferredDeviceId,
  }) {
    if (preferredDeviceId != null) {
      RemoteDevice? selected;
      for (final device in devices) {
        if (device.id == preferredDeviceId) {
          selected = device;
          break;
        }
      }
      if (selected == null || !RelaySourceNotifier.supports(selected)) {
        return null;
      }
      return _scopeFor(selected, relay[selected.id]);
    }
    RemoteDevice? fallback;
    for (final d in devices) {
      if (!RelaySourceNotifier.supports(d)) continue;
      fallback ??= d;
      final st = relay[d.id];
      final ws = st?.workspaceKey?.trim();
      if (st != null && st.agentReady && ws != null && ws.isNotEmpty) {
        return _scopeFor(d, st);
      }
    }
    if (fallback == null) return null;
    return _scopeFor(fallback, relay[fallback.id]);
  }

  static NativeWorkbenchScope _scopeFor(
    RemoteDevice device,
    RelaySourceState? source,
  ) {
    final st = source ?? const RelaySourceState();
    return (
      deviceId: device.id,
      workspacePath: st.workspaceKey?.trim() ?? '',
      ready: st.agentReady && st.workspaceKey?.trim().isNotEmpty == true,
      statusLabel: st.bootstrap.status.labelZh,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final devices = ref.watch(deviceListProvider);
    final relay = ref.watch(relaySourceProvider);
    final active = ref.watch(activeTabProvider);
    final preferredDeviceId = active < devices.length
        ? devices[active].id
        : null;
    final scope = nativeScope(
      devices,
      relay,
      preferredDeviceId: preferredDeviceId,
    );
    final snapshots = ref.watch(panelDataProvider);
    // Never fold several devices into one snapshot: a legacy device's
    // passive data is only shown when no relay device exists at all.
    // Legacy (no relay device): never fold several devices into one
    // snapshot; show the single freshest one (review P2-5).
    final merged = scope != null
        ? PanelSnapshot.empty
        : _snapshotFor(snapshots, preferredDeviceId);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 14, 4, 2),
              child: Text(
                l10n.panelsTitle,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                  color: context.zt.textHi,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
              child: Text(
                scope != null
                    ? scope.statusLabel
                    : merged.updatedAt == null
                    ? l10n.panelsSubtitleIdle
                    : l10n.panelsSubtitleSynced(
                        _relative(merged.updatedAt!, l10n),
                      ),
                style: TextStyle(
                  fontSize: 12,
                  color: scope != null && !scope.ready
                      ? context.zt.warn
                      : context.zt.textLo,
                ),
              ),
            ),
            if (scope == null &&
                (merged.quotas.isNotEmpty || merged.plan != null))
              _PlanHeaderCard(plan: merged.plan, quotas: merged.quotas),
            const SizedBox(height: 12),
            _PanelGrid(
              snapshot: merged,
              hasDevices: devices.isNotEmpty,
              scope: scope,
            ),
          ],
        ),
      ),
    );
  }

  /// Prefer the active device's complete snapshot. If it has no snapshot,
  /// use the newest complete snapshot without mixing fields across devices.
  static PanelSnapshot _snapshotFor(
    Map<String, PanelSnapshot> snapshots,
    String? preferredDeviceId,
  ) {
    if (preferredDeviceId != null) {
      final selected = snapshots[preferredDeviceId];
      if (selected != null) return selected;
    }
    return _freshest(snapshots.values);
  }

  /// The snapshot with the newest updatedAt; ties keep the first device in
  /// map order. Mixing fields across devices is what produced
  /// "model from A, usage from B".
  static PanelSnapshot _freshest(Iterable<PanelSnapshot> snapshots) {
    PanelSnapshot? best;
    for (final s in snapshots) {
      if (best == null || (s.updatedAt ?? 0) > (best.updatedAt ?? 0)) best = s;
    }
    return best ?? PanelSnapshot.empty;
  }

  static String _relative(int at, AppLocalizations l10n) {
    final diff = DateTime.now().millisecondsSinceEpoch - at;
    if (diff < 60 * 1000) return l10n.sessionTimeNow;
    if (diff < 3600 * 1000) return l10n.sessionTimeMinutes(diff ~/ 60000);
    if (diff < 24 * 3600 * 1000) return l10n.sessionTimeHours(diff ~/ 3600000);
    return l10n.sessionTimeDays(diff ~/ 86400000);
  }
}

class _PlanHeaderCard extends StatelessWidget {
  const _PlanHeaderCard({required this.plan, required this.quotas});

  final PlanInfo? plan;
  final List<QuotaInfo> quotas;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF13343C), Color(0xFF121A23)],
        ),
        border: Border.all(color: context.zt.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: context.zt.accent.withValues(alpha: 0.14),
                  border: Border.all(
                    color: context.zt.accent.withValues(alpha: 0.5),
                  ),
                ),
                child: Text(
                  plan?.audience ?? l10n.panelsPlanDefault,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: context.zt.accent,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  plan?.name ?? l10n.panelsPlanDefault,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: context.zt.textHi,
                  ),
                ),
              ),
              if (plan?.expiresAt != null)
                Text(
                  l10n.panelsPlanExpires(plan!.expiresAt!),
                  style: TextStyle(fontSize: 11, color: context.zt.textLo),
                ),
            ],
          ),
          const SizedBox(height: 14),
          for (final q in quotas.take(3)) ...[
            _QuotaBar(quota: q),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _QuotaBar extends StatelessWidget {
  const _QuotaBar({required this.quota});

  final QuotaInfo quota;

  @override
  Widget build(BuildContext context) {
    final pct = quota.percent.clamp(0, 100);
    final color = pct > 50
        ? context.zt.live
        : pct > 20
        ? const Color(0xFFFFB35C)
        : context.zt.danger;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                quota.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: context.zt.textLo),
              ),
            ),
            Text(
              '${pct.toStringAsFixed(pct == pct.roundToDouble() ? 0 : 1)}%',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            if (quota.resetLabel != null) ...[
              Text(
                ' · ${quota.resetLabel}',
                style: TextStyle(fontSize: 11, color: context.zt.textLo),
              ),
            ],
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: pct / 100,
            minHeight: 5,
            backgroundColor: context.zt.surfaceHi,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
      ],
    );
  }
}

class _PanelDef {
  const _PanelDef({
    required this.key,
    required this.icon,
    required this.hue,
    required this.route,
  });

  final String key;

  final IconData icon;

  final Color hue;

  final PanelRoute route;
}

enum PanelRoute {
  model,
  usage,
  subagents,
  skills,
  mcp,
  plugins,
  commands,
  hooks,
  memory,
  outputStyles,
}

class _PanelGrid extends StatelessWidget {
  const _PanelGrid({
    required this.snapshot,
    required this.hasDevices,
    this.scope,
  });

  final PanelSnapshot snapshot;

  final bool hasDevices;

  /// Non-null for relay devices: cards open native pages.
  final NativeWorkbenchScope? scope;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final defs = [
      _PanelDef(
        key: 'model',
        icon: Icons.hub_outlined,
        hue: const Color(0xFF35D0E0),
        route: PanelRoute.model,
      ),
      _PanelDef(
        key: 'usage',
        icon: Icons.query_stats,
        hue: const Color(0xFF3DDC85),
        route: PanelRoute.usage,
      ),
      _PanelDef(
        key: 'subagents',
        icon: Icons.groups_2_outlined,
        hue: const Color(0xFFB48CFF),
        route: PanelRoute.subagents,
      ),
      _PanelDef(
        key: 'skills',
        icon: Icons.bolt_outlined,
        hue: const Color(0xFFFFB35C),
        route: PanelRoute.skills,
      ),
      _PanelDef(
        key: 'mcp',
        icon: Icons.extension_outlined,
        hue: const Color(0xFF6FA8FF),
        route: PanelRoute.mcp,
      ),
      _PanelDef(
        key: 'plugins',
        icon: Icons.widgets_outlined,
        hue: const Color(0xFFFF8FB8),
        route: PanelRoute.plugins,
      ),
      _PanelDef(
        key: 'commands',
        icon: Icons.terminal_outlined,
        hue: const Color(0xFF7FE0C3),
        route: PanelRoute.commands,
      ),
      _PanelDef(
        key: 'hooks',
        icon: Icons.settings_input_component_outlined,
        hue: const Color(0xFFC9A86A),
        route: PanelRoute.hooks,
      ),
      _PanelDef(
        key: 'memory',
        icon: Icons.psychology_outlined,
        hue: const Color(0xFF9DB4FF),
        route: PanelRoute.memory,
      ),
      _PanelDef(
        key: 'outputStyles',
        icon: Icons.style_outlined,
        hue: const Color(0xFFD7A7FF),
        route: PanelRoute.outputStyles,
      ),
    ];

    String? statusOf(_PanelDef d) {
      if (scope != null) return scope!.ready ? '原生' : null;
      switch (d.route) {
        case PanelRoute.model:
          final cur = snapshot.providers.where((p) => p.isCurrent).toList();
          if (cur.isNotEmpty) return cur.first.name;
          return snapshot.providers.isEmpty
              ? null
              : l10n.panelsCount(snapshot.providers.length);
        case PanelRoute.usage:
          if (snapshot.quotas.isNotEmpty) {
            return '${snapshot.quotas.first.percent.round()}%';
          }
          return snapshot.usage.isEmpty
              ? null
              : l10n.panelsCount(snapshot.usage.length);
        case PanelRoute.subagents:
          return snapshot.subagents.isEmpty
              ? null
              : l10n.panelsCount(snapshot.subagents.length);
        case PanelRoute.skills:
        case PanelRoute.mcp:
        case PanelRoute.plugins:
        case PanelRoute.commands:
        case PanelRoute.hooks:
        case PanelRoute.memory:
        case PanelRoute.outputStyles:
          final list = snapshot.listPanels[d.key];
          return list == null || list.isEmpty
              ? null
              : l10n.panelsCount(list.length);
      }
    }

    final groups = <String, List<_PanelDef>>{
      '会话与数据': defs
          .where(
            (d) => d.route == PanelRoute.model || d.route == PanelRoute.usage,
          )
          .toList(),
      'Agent 能力': defs
          .where(
            (d) =>
                d.route != PanelRoute.model &&
                d.route != PanelRoute.usage &&
                d.route != PanelRoute.outputStyles,
          )
          .toList(),
      '输出': defs.where((d) => d.route == PanelRoute.outputStyles).toList(),
    };

    return Column(
      children: [
        for (final group in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 7),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                group.key,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.zt.textLo,
                ),
              ),
            ),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              decoration: BoxDecoration(
                color: context.zt.surface,
                border: Border.all(color: context.zt.hairline),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  for (final d in group.value)
                    _PanelCard(
                      def: d,
                      title: _titleOf(d.route, l10n),
                      status: statusOf(d),
                      hasData: statusOf(d) != null,
                      onTap: () => _open(context, d.route, scope),
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Native, per-device pages.  Every one of them reads through a service
  /// RPC and auto-loads when the agent handshake completes; none of them
  /// can open the remote web page.
  static Widget _nativePage(PanelRoute r, NativeWorkbenchScope scope) {
    SettingsPanelPage settings(SettingsPanel panel) => SettingsPanelPage(
      panel: panel,
      deviceId: scope.deviceId,
      workspacePath: scope.workspacePath,
    );
    return switch (r) {
      PanelRoute.model => NativeModelPage(
        deviceId: scope.deviceId,
        workspacePath: scope.workspacePath,
      ),
      PanelRoute.usage => settings(SettingsPanel.usage),
      PanelRoute.subagents => settings(SettingsPanel.subagents),
      PanelRoute.skills => settings(SettingsPanel.skills),
      PanelRoute.mcp => settings(SettingsPanel.mcpServers),
      PanelRoute.plugins => settings(SettingsPanel.plugins),
      PanelRoute.commands => settings(SettingsPanel.commands),
      PanelRoute.hooks => settings(SettingsPanel.hooks),
      PanelRoute.memory => settings(SettingsPanel.memory),
      PanelRoute.outputStyles => settings(SettingsPanel.outputStyles),
    };
  }

  static String _titleOf(PanelRoute r, AppLocalizations l10n) => switch (r) {
    PanelRoute.model => l10n.panelModelTitle,
    PanelRoute.usage => l10n.panelUsageTitle,
    PanelRoute.subagents => l10n.panelSubagentsTitle,
    PanelRoute.skills => l10n.panelSkillsTitle,
    PanelRoute.mcp => l10n.panelMcpTitle,
    PanelRoute.plugins => l10n.panelPluginsTitle,
    PanelRoute.commands => l10n.panelCommandsTitle,
    PanelRoute.hooks => l10n.panelHooksTitle,
    PanelRoute.memory => l10n.panelMemoryTitle,
    PanelRoute.outputStyles => l10n.panelOutputStylesTitle,
  };

  static void _open(
    BuildContext context,
    PanelRoute r,
    NativeWorkbenchScope? scope,
  ) {
    final Widget page = scope != null
        ? _nativePage(r, scope)
        : switch (r) {
            PanelRoute.model => const ModelPanelPage(),
            PanelRoute.usage => const UsagePanelPage(),
            PanelRoute.subagents => const SubagentsPanelPage(),
            PanelRoute.skills => const GenericPanelPage(
              panelKey: PanelKeys.skills,
            ),
            PanelRoute.mcp => const GenericPanelPage(panelKey: PanelKeys.mcp),
            PanelRoute.plugins => const GenericPanelPage(
              panelKey: PanelKeys.plugins,
            ),
            PanelRoute.commands => const GenericPanelPage(
              panelKey: PanelKeys.commands,
            ),
            PanelRoute.hooks => const GenericPanelPage(
              panelKey: PanelKeys.hooks,
            ),
            PanelRoute.memory => const GenericPanelPage(
              panelKey: PanelKeys.memory,
            ),
            PanelRoute.outputStyles => const GenericPanelPage(
              panelKey: PanelKeys.outputStyles,
            ),
          };
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => page,
        transitionsBuilder: (_, anim, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.03), end: Offset.zero)
                .animate(
                  CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
                ),
            child: child,
          ),
        ),
        transitionDuration: const Duration(milliseconds: 260),
      ),
    );
  }
}

class _PanelCard extends StatelessWidget {
  const _PanelCard({
    required this.def,
    required this.title,
    required this.status,
    required this.hasData,
    required this.onTap,
  });

  final _PanelDef def;

  final String title;

  final String? status;

  final bool hasData;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: context.zt.hairline)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: def.hue.withValues(alpha: hasData ? 0.14 : 0.08),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(
                  def.icon,
                  size: 18,
                  color: hasData ? def.hue : context.zt.textLo,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: context.zt.textHi,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      hasData ? (status ?? '') : l10n.panelsCardIdle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: hasData ? def.hue : context.zt.textLo,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 20, color: context.zt.textLo),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/panel_state.dart';
import '../../theme.dart';

/// 模型面板：供应商列表 + 编程套餐 + 额度。复刻桌面端「模型设置」的信息结构，
/// 视觉按移动端重新设计。
class ModelPanelPage extends ConsumerWidget {
  const ModelPanelPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final snapshots = ref.watch(panelDataProvider);
    var providers = const <ModelProviderInfo>[];
    PlanInfo? plan;
    var quotas = const <QuotaInfo>[];
    for (final s in snapshots.values) {
      if (s.providers.length > providers.length) providers = s.providers;
      plan ??= s.plan;
      if (quotas.isEmpty && s.quotas.isNotEmpty) quotas = s.quotas;
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.panelModelTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (quotas.isNotEmpty || plan != null) ...[
            _PlanCard(plan: plan, quotas: quotas),
            const SizedBox(height: 16),
          ],
          if (providers.isEmpty)
            const _GuideEmpty()
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text(
                l10n.panelModelProviders(providers.length),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.zt.textLo,
                ),
              ),
            ),
            for (final p in providers) _ProviderCard(provider: p),
          ],
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.plan, required this.quotas});

  final PlanInfo? plan;

  final List<QuotaInfo> quotas;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(16),
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
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      context.zt.accent.withValues(alpha: 0.35),
                      context.zt.accent.withValues(alpha: 0.10),
                    ],
                  ),
                ),
                child: Icon(
                  Icons.auto_awesome,
                  size: 20,
                  color: context.zt.accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      plan?.name ?? l10n.panelModelNoPlan,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: context.zt.textHi,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      plan?.expiresAt != null
                          ? l10n.panelsPlanExpires(plan!.expiresAt!)
                          : (plan?.audience ?? l10n.panelModelPlanSubtitle),
                      style: TextStyle(fontSize: 12, color: context.zt.textLo),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (quotas.isNotEmpty) ...[
            const SizedBox(height: 16),
            for (final q in quotas.take(4)) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      q.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: context.zt.textLo),
                    ),
                  ),
                  Text(
                    '${q.percent.round()}%',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _barColor(context.zt, q.percent),
                    ),
                  ),
                  if (q.resetLabel != null)
                    Text(
                      ' · ${q.resetLabel}',
                      style: TextStyle(fontSize: 11, color: context.zt.textLo),
                    ),
                ],
              ),
              const SizedBox(height: 5),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: q.percent.clamp(0, 100) / 100,
                  minHeight: 5,
                  backgroundColor: context.zt.surfaceHi,
                  valueColor: AlwaysStoppedAnimation(
                    _barColor(context.zt, q.percent),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ],
        ],
      ),
    );
  }

  static Color _barColor(ZTPalette zt, double pct) => pct > 50
      ? zt.live
      : pct > 20
      ? zt.warn
      : zt.danger;
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({required this.provider});

  final ModelProviderInfo provider;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: provider.models.isEmpty ? null : () => _showModels(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(11),
                  color: context.zt.surfaceHi,
                  border: Border.all(color: context.zt.hairline),
                ),
                child: Text(
                  provider.name.isEmpty
                      ? '?'
                      : provider.name.characters.first.toUpperCase(),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: context.zt.accent,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            provider.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: context.zt.textHi,
                            ),
                          ),
                        ),
                        if (provider.isCurrent) ...[
                          const SizedBox(width: 6),
                          const _Badge(label: '当前', accent: true),
                        ] else if (provider.enabled == true) ...[
                          const SizedBox(width: 6),
                          _Badge(label: l10n.panelModelEnabled, accent: true),
                        ] else if (provider.enabled == false) ...[
                          const SizedBox(width: 6),
                          _Badge(label: l10n.panelModelDisabled, accent: false),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      provider.models.isEmpty
                          ? l10n.panelModelNoModels
                          : l10n.panelModelModels(provider.models.length),
                      style: TextStyle(fontSize: 12, color: context.zt.textLo),
                    ),
                  ],
                ),
              ),
              if (provider.models.isNotEmpty)
                Icon(Icons.chevron_right, size: 20, color: context.zt.textLo),
            ],
          ),
        ),
      ),
    );
  }

  void _showModels(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: context.zt.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                provider.name,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: context.zt.textHi,
                ),
              ),
            ),
            for (final m in provider.models)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(
                  children: [
                    Icon(Icons.circle, size: 6, color: context.zt.accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        m,
                        style: TextStyle(
                          fontSize: 13.5,
                          color: context.zt.textHi,
                        ),
                      ),
                    ),
                    if (m == provider.models.first)
                      const _Badge(label: '默认', accent: true),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.accent});

  final String label;

  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: accent
            ? context.zt.live.withValues(alpha: 0.14)
            : context.zt.textLo.withValues(alpha: 0.12),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: accent ? context.zt.live : context.zt.textLo,
        ),
      ),
    );
  }
}

class _GuideEmpty extends StatelessWidget {
  const _GuideEmpty();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: context.zt.accent.withValues(alpha: 0.10),
            ),
            child: Icon(Icons.hub_outlined, size: 30, color: context.zt.accent),
          ),
          const SizedBox(height: 14),
          Text(
            l10n.panelModelEmptyHint,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.6,
              color: context.zt.textLo,
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/resource_list.dart';
import '../theme.dart';

/// 设置面板里「资源列表」的通用呈现。
///
/// 官方 12 个设置面板里有 8 个是同一套骨架（技能 / MCP / 插件 / 命令 /
/// 子智能体 / 钩子 …），差异只在数据源。这里把骨架抽出来，
/// 各面板只提供条目与回调。
///
/// 设计上继续沿用既定取向：细线 + 留白做结构，不用阴影；
/// 开关用系统组件（用户熟悉），状态用文字而不是彩色徽章。
class ResourceListView extends StatefulWidget {
  const ResourceListView({
    super.key,
    required this.items,
    this.onToggle,
    this.onTap,
    this.loading = false,
    this.error,
    this.phase,
    this.sourceMethod,
    this.onRetry,
    this.emptyText,
    this.emptyHint,
    this.leadingIcon,
    this.showStatusFilter = true,
    this.readOnlyNote,
  });

  final List<ResourceEntry> items;

  /// 切换启用。为 null 表示该列表不支持开关（只读）。
  final void Function(ResourceEntry entry, bool enabled)? onToggle;

  final void Function(ResourceEntry entry)? onTap;

  final bool loading;
  final String? error;

  /// Optional explicit lifecycle state.  Existing callers may continue to
  /// provide `loading`/`error`; when omitted the widget derives the legacy
  /// state so the migration can happen one panel at a time.
  final ResourcePhase? phase;

  /// Safe provenance text such as `plugins.getOverview`.  It is deliberately
  /// a method name only; callers must not pass raw responses or credentials.
  final String? sourceMethod;
  final VoidCallback? onRetry;

  final String? emptyText;
  final String? emptyHint;

  /// 条目左侧图标。
  final IconData? leadingIcon;

  /// 是否显示启用状态筛选。
  final bool showStatusFilter;

  /// 对只读条目的说明（例如"由插件注册"）。
  final String Function(ResourceEntry entry)? readOnlyNote;

  @override
  State<ResourceListView> createState() => _ResourceListViewState();
}

class _ResourceListViewState extends State<ResourceListView> {
  final _controller = TextEditingController();
  ResourceFilter _filter = const ResourceFilter();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final zt = context.zt;
    final currentPhase = widget.phase ?? _legacyPhase;

    if (currentPhase == ResourcePhase.loading && widget.items.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 1.6),
        ),
      );
    }

    if ((currentPhase == ResourcePhase.error ||
            currentPhase == ResourcePhase.unsupported ||
            currentPhase == ResourcePhase.permissionDenied) &&
        widget.items.isEmpty) {
      return _Notice(
        text: widget.error ?? _phaseText(currentPhase),
        actionLabel: widget.onRetry == null ? null : l10n.commonRetry,
        onAction: widget.onRetry,
        hint: widget.sourceMethod == null ? null : '来源 ${widget.sourceMethod}',
      );
    }

    final sections = ResourceListing.apply(widget.items, filter: _filter);
    final counts = ResourceListing.counts(widget.items);
    final showHeaders = ResourceListing.needsGroupHeaders(sections);

    return Column(
      children: [
        if (currentPhase == ResourcePhase.loading && widget.items.isNotEmpty)
          const LinearProgressIndicator(minHeight: 2),
        if ((currentPhase == ResourcePhase.stale || widget.error != null) &&
            widget.items.isNotEmpty)
          _StaleNotice(
            error: widget.error ?? '原生通道暂时不可用',
            onRetry: widget.onRetry,
          ),
        _Toolbar(
          controller: _controller,
          filter: _filter,
          showStatusFilter: widget.showStatusFilter,
          onQuery: (q) => setState(() => _filter = _filter.copyWith(query: q)),
          onStatus: (s) =>
              setState(() => _filter = _filter.copyWith(status: s)),
        ),
        Expanded(
          child: sections.isEmpty
              ? _Notice(
                  text: _filter.isActive
                      ? l10n.resourceNoMatch
                      : (widget.emptyText ?? l10n.resourceEmpty),
                  actionLabel: _filter.isActive
                      ? l10n.resourceClearFilter
                      : null,
                  onAction: _filter.isActive
                      ? () {
                          _controller.clear();
                          setState(() => _filter = const ResourceFilter());
                        }
                      : null,
                  hint: _filter.isActive ? null : widget.emptyHint,
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
                  children: [
                    for (final s in sections) ...[
                      if (showHeaders && s.label != null)
                        _SectionLabel(
                          label: _groupLabel(l10n, s.label!),
                          count: s.count,
                        ),
                      for (final e in s.items)
                        _ResourceTile(
                          entry: e,
                          icon: widget.leadingIcon,
                          onToggle: widget.onToggle,
                          onTap: widget.onTap,
                          readOnlyNote: widget.readOnlyNote,
                        ),
                    ],
                    const SizedBox(height: 14),
                    Center(
                      child: Column(
                        children: [
                          Text(
                            l10n.resourceFooterCount(
                              counts.total,
                              counts.enabled,
                            ),
                            style: TextStyle(fontSize: 11.5, color: zt.textLo),
                          ),
                          if (widget.sourceMethod != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              '原生 · ${widget.sourceMethod}',
                              style: TextStyle(
                                fontSize: 10.5,
                                color: zt.textLo,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  ResourcePhase get _legacyPhase {
    if (widget.loading) return ResourcePhase.loading;
    if (widget.error != null) {
      return widget.items.isEmpty ? ResourcePhase.error : ResourcePhase.stale;
    }
    return widget.items.isEmpty ? ResourcePhase.empty : ResourcePhase.ready;
  }

  static String _phaseText(ResourcePhase phase) => switch (phase) {
    ResourcePhase.unsupported => '当前桌面版本未提供此原生接口',
    ResourcePhase.permissionDenied => '桌面端拒绝了读取请求',
    ResourcePhase.error => '未能读取原生资源',
    _ => '暂无内容',
  };

  static String _groupLabel(AppLocalizations l10n, String key) => switch (key) {
    'local' => l10n.resourceGroupLocal,
    'plugin' => l10n.resourceGroupPlugin,
    'builtin' => l10n.resourceGroupBuiltin,
    _ => key,
  };
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.controller,
    required this.filter,
    required this.showStatusFilter,
    required this.onQuery,
    required this.onStatus,
  });

  final TextEditingController controller;
  final ResourceFilter filter;
  final bool showStatusFilter;
  final ValueChanged<String> onQuery;
  final ValueChanged<ResourceStatusFilter> onStatus;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final zt = context.zt;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Column(
        children: [
          TextField(
            controller: controller,
            onChanged: onQuery,
            style: const TextStyle(fontSize: 13.5),
            decoration: InputDecoration(
              isDense: true,
              hintText: l10n.resourceSearchHint,
              prefixIcon: Icon(Icons.search, size: 17, color: zt.textLo),
              prefixIconConstraints: const BoxConstraints(
                minWidth: 34,
                minHeight: 34,
              ),
              suffixIcon: controller.text.isEmpty
                  ? null
                  : IconButton(
                      icon: Icon(Icons.close, size: 15, color: zt.textLo),
                      onPressed: () {
                        controller.clear();
                        onQuery('');
                      },
                    ),
            ),
          ),
          if (showStatusFilter) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 6,
                children: [
                  for (final s in ResourceStatusFilter.values)
                    _Chip(
                      label: switch (s) {
                        ResourceStatusFilter.all => l10n.resourceFilterAll,
                        ResourceStatusFilter.enabled =>
                          l10n.resourceFilterEnabled,
                        ResourceStatusFilter.disabled =>
                          l10n.resourceFilterDisabled,
                      },
                      selected: filter.status == s,
                      onTap: () => onStatus(s),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A refresh failure must not throw away a previously verified list. Keep the
/// list visible, but make the stale/error state explicit and actionable.
class _StaleNotice extends StatelessWidget {
  const _StaleNotice({required this.error, this.onRetry});

  final String error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final zt = context.zt;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: zt.warn.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: zt.warn.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.sync_problem_outlined, size: 17, color: zt.warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${isZh ? '显示上次同步的数据 · ' : 'Showing last synced data · '}$error',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: zt.textHi),
            ),
          ),
          if (onRetry != null)
            IconButton(
              tooltip: isZh ? '重试' : 'Retry',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.refresh_rounded, size: 18, color: zt.warn),
              onPressed: onRetry,
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? zt.accent.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: selected ? zt.accent : zt.hairline),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected ? zt.accent : zt.textLo,
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 12, 2, 6),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.3,
              color: zt.textLo,
            ),
          ),
          const SizedBox(width: 6),
          Text('$count', style: TextStyle(fontSize: 11, color: zt.textLo)),
        ],
      ),
    );
  }
}

class _ResourceTile extends StatelessWidget {
  const _ResourceTile({
    required this.entry,
    this.icon,
    this.onToggle,
    this.onTap,
    this.readOnlyNote,
  });

  final ResourceEntry entry;
  final IconData? icon;
  final void Function(ResourceEntry entry, bool enabled)? onToggle;
  final void Function(ResourceEntry entry)? onTap;
  final String Function(ResourceEntry entry)? readOnlyNote;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    final desc = entry.description;
    final note = entry.readOnly || onToggle == null
        ? readOnlyNote?.call(entry)
        : null;

    return Material(
      color: zt.surface,
      child: InkWell(
        onTap: onTap == null ? null : () => onTap!(entry),
        child: Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: zt.hairline)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (icon != null) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(icon, size: 16, color: zt.textLo),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: zt.textHi,
                      ),
                    ),
                    if (desc != null && desc.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        desc,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.45,
                          color: zt.textLo,
                        ),
                      ),
                    ],
                    if (note != null && note.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        note,
                        style: TextStyle(fontSize: 11, color: zt.textLo),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (entry.readOnly)
                Padding(
                  padding: const EdgeInsets.only(top: 3, right: 6),
                  child: Text(
                    '—',
                    style: TextStyle(fontSize: 13, color: zt.textLo),
                  ),
                )
              else if (onToggle != null)
                Switch(
                  value: entry.enabled,
                  onChanged: (v) => onToggle!(entry, v),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.text,
    this.actionLabel,
    this.onAction,
    this.hint,
  });

  final String text;
  final String? hint;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: zt.textLo),
            ),
            if (hint != null) ...[
              const SizedBox(height: 6),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: zt.textLo),
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(
                  foregroundColor: zt.textHi,
                  side: BorderSide(color: zt.hairline),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                ),
                child: Text(actionLabel!, style: const TextStyle(fontSize: 13)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

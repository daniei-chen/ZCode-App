import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../native/bootstrap/native_bootstrap_coordinator.dart';
import '../native/bootstrap/native_bootstrap_state.dart';
import '../state/active_session.dart';
import '../state/conversation.dart';
import '../state/conversation_config.dart';
import '../state/session_index.dart';
import '../theme.dart';

/// Workbench "模型" entry backed by the verified session snapshot.
///
/// The desktop exposes the model catalogue per session
/// (`zcode-session.readSession` → `settings.model.available[]`), so this page
/// reads the device's active (or most recent) session through the same
/// runtime-config path the composer uses.  Nothing here comes from passive
/// WebView payload scanning, and no state invites the user to open the remote
/// web page.
class NativeModelPage extends ConsumerStatefulWidget {
  const NativeModelPage({
    super.key,
    required this.deviceId,
    required this.workspacePath,
  });

  final String deviceId;
  final String workspacePath;

  @override
  ConsumerState<NativeModelPage> createState() => _NativeModelPageState();
}

class _NativeModelPageState extends ConsumerState<NativeModelPage> {
  String? _sessionId;
  bool _requested = false;

  Future<void> _selectModel(ConversationModelOption option) async {
    final sessionId = _sessionId;
    if (sessionId == null || !option.enabled) return;
    await ref
        .read(conversationProvider.notifier)
        .updateRuntimeConfig(
          deviceId: widget.deviceId,
          workspacePath: widget.workspacePath,
          sessionId: sessionId,
          providerId: option.providerId,
          modelId: option.modelId,
        );
  }

  Future<void> _selectThought(ThoughtOption option) async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    await ref
        .read(conversationProvider.notifier)
        .updateRuntimeConfig(
          deviceId: widget.deviceId,
          workspacePath: widget.workspacePath,
          sessionId: sessionId,
          thoughtLevel: option.value,
        );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    // Auto-run once the agent handshake completes if we opened too early.
    ref.listenManual(
      nativeBootstrapProvider((deviceId: widget.deviceId, sessionId: null)),
      (prev, next) {
        if (!(prev?.draftCreateReady ?? false) && next.draftCreateReady) {
          _load(refresh: true);
        }
      },
    );
  }

  String? _resolveSession() {
    final active = ref.read(activeSessionProvider)[widget.deviceId];
    if (active != null && active.isNotEmpty) return active;
    final sessions =
        ref.read(sessionIndexProvider)[widget.deviceId]?.values.toList() ??
        const [];
    if (sessions.isEmpty) return null;
    sessions.sort(SessionRanking.compareSessions);
    return sessions.first.sessionId;
  }

  void _load({bool refresh = false}) {
    final sessionId = _resolveSession();
    if (!mounted) return;
    setState(() {
      _sessionId = sessionId;
      _requested = sessionId != null;
    });
    if (sessionId == null) return;
    ref
        .read(conversationProvider.notifier)
        .loadRuntimeConfig(
          deviceId: widget.deviceId,
          workspacePath: widget.workspacePath,
          sessionId: sessionId,
          refresh: refresh,
        );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final zt = context.zt;
    final ready = ref.watch(
      nativeBootstrapProvider((deviceId: widget.deviceId, sessionId: null)),
    );
    final sessionId = _sessionId;
    final config = sessionId == null
        ? ConversationRuntimeConfig.empty
        : ref.watch(
            conversationProvider.select(
              (m) =>
                  m[ConversationNotifier.keyOf(widget.deviceId, sessionId)]
                      ?.runtimeConfig ??
                  ConversationRuntimeConfig.empty,
            ),
          );

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.panelModelTitle),
        actions: [
          IconButton(
            tooltip: l10n.conversationRefresh,
            onPressed: config.loading ? null : () => _load(refresh: true),
            icon: const Icon(Icons.refresh_rounded, size: 19),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: zt.hairline),
        ),
      ),
      body: _body(context, l10n, ready, config),
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    NativeBootstrapState ready,
    ConversationRuntimeConfig config,
  ) {
    final zt = context.zt;
    if (_sessionId == null) {
      return _Message(
        icon: Icons.hub_outlined,
        title: ready.draftCreateReady ? '暂无会话，无法读取模型目录' : ready.status.labelZh,
        detail: '模型目录随会话快照返回；创建或打开一个会话后这里会自动读取。',
        onRetry: ready.draftCreateReady ? null : () => _load(refresh: true),
      );
    }
    if (config.loading && !config.hasModel) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 1.6),
        ),
      );
    }
    if (config.error != null && !config.hasModel) {
      return _Message(
        icon: Icons.error_outline,
        title: '本机没有返回会话配置',
        detail: config.error,
        onRetry: () => _load(refresh: true),
      );
    }
    if (!_requested) {
      return const SizedBox.shrink();
    }

    final current = config.currentModel;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _Section(
          title: '当前会话',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _KV('模型', config.modelLabel ?? config.modelId ?? '未返回'),
              _KV('供应商', current?.providerLabel ?? config.providerId ?? '未返回'),
              _KV('思考级别', config.thoughtLevel ?? '未返回'),
              _KV('上下文', _contextLabel(config)),
              if (config.fetchedAt != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '来源 zcode-session.readSession · ${_relative(config.fetchedAt!)}',
                    style: TextStyle(fontSize: 11, color: zt.textLo),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Section(
          title: '思考强度',
          trailing: config.thoughtOptions.isEmpty
              ? null
              : '${config.thoughtOptions.length}',
          child: config.thoughtOptions.isEmpty
              ? Text(
                  config.thoughtEnabled == false
                      ? '当前模型不提供思考强度'
                      : '桌面端未返回可选思考强度',
                  style: TextStyle(fontSize: 13, color: zt.textLo),
                )
              : Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final option in config.thoughtOptions)
                      ChoiceChip(
                        label: Text(option.displayName),
                        selected: option.value == config.thoughtLevel,
                        onSelected: (_) => _selectThought(option),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        _Section(
          title: '可选模型',
          trailing: config.catalogState == ConfigFieldState.returned
              ? '${config.models.length}'
              : null,
          child: switch (config.catalogState) {
            ConfigFieldState.notReturned => Text(
              l10n.conversationModelUnavailable,
              style: TextStyle(fontSize: 13, color: zt.textLo),
            ),
            ConfigFieldState.empty => Text(
              '桌面端返回了空的模型目录',
              style: TextStyle(fontSize: 13, color: zt.textLo),
            ),
            ConfigFieldState.returned => Column(
              children: [
                for (final m in config.models)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    enabled: m.enabled,
                    leading: Icon(
                      m.modelId == config.modelId &&
                              m.providerId == config.providerId
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color:
                          m.modelId == config.modelId &&
                              m.providerId == config.providerId
                          ? zt.accent
                          : zt.textLo,
                    ),
                    title: Text(m.displayName),
                    onTap: m.enabled ? () => _selectModel(m) : null,
                    subtitle: Text(
                      m.enabled
                          ? [
                              m.providerLabel ?? m.providerId,
                              if (m.contextWindow != null)
                                '${m.contextWindow} ctx',
                              if (m.reasoningLevels.isNotEmpty)
                                '思考 ${m.reasoningLevels.map((o) => o.value).join('/')}',
                            ].join(' · ')
                          : '不可用：${m.disabledReason ?? 'disabled'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          },
        ),
      ],
    );
  }

  static String _relative(int at) {
    final diff = DateTime.now().millisecondsSinceEpoch - at;
    if (diff < 60 * 1000) return '刚刚';
    if (diff < 3600 * 1000) return '${diff ~/ 60000} 分钟前';
    return '${diff ~/ 3600000} 小时前';
  }

  static String _contextLabel(ConversationRuntimeConfig config) {
    final used = config.contextUsedTokens;
    final max = config.contextMaxTokens;
    if (used == null && max == null) return '未返回';
    return '${used == null ? '—' : _formatTokens(used)} / '
        '${max == null ? '—' : _formatTokens(max)}';
  }

  static String _formatTokens(int value) {
    if (value < 1000) return '$value';
    if (value < 1000000) return '${(value / 1000).toStringAsFixed(1)}k';
    return '${(value / 1000000).toStringAsFixed(1)}m';
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                color: zt.textLo,
              ),
            ),
            const Spacer(),
            if (trailing != null)
              Text(trailing!, style: TextStyle(fontSize: 12, color: zt.textLo)),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: zt.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: zt.hairline),
          ),
          child: child,
        ),
      ],
    );
  }
}

class _KV extends StatelessWidget {
  const _KV(this.k, this.v);

  final String k;
  final String v;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(k, style: TextStyle(fontSize: 13, color: zt.textLo)),
          ),
          Expanded(
            child: Text(
              v,
              style: TextStyle(fontSize: 13, color: zt.textHi),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    this.detail,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: zt.textLo),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: zt.textHi),
            ),
            if (detail != null) ...[
              const SizedBox(height: 6),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: zt.textLo),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 14),
              OutlinedButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ],
        ),
      ),
    );
  }
}

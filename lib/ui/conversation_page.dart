import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../models/device_label.dart';
import '../native/bootstrap/native_bootstrap_coordinator.dart';
import '../native/bootstrap/native_bootstrap_state.dart';
import '../relay/conversation_attachment.dart';
import '../relay/conversation_row.dart';
import '../services/event_observer.dart';
import '../state/conversation.dart';
import '../state/conversation_config.dart';
import '../state/create_recovery.dart';
import '../state/relay_source.dart';
import '../state/root_tabs.dart';
import '../state/session_index.dart';
import '../state/session_pool.dart';
import '../theme.dart';

/// 原生会话正文页。
///
/// 设计取向（刻意规避"AI 味"）：
/// - 不用大圆角卡片 + 投影堆叠，改用**细分隔线与留白**做结构
/// - 单一强调色，只用在"进行中"与用户消息的左侧细线
/// - 工具调用是**紧凑的行**，不是一个一个卡片；连续调用合并成一组
/// - 思考过程默认折叠、降饱和，不抢正文
/// - 不用 emoji；状态用小圆点 + 文字
class ConversationPage extends ConsumerStatefulWidget {
  /// The unified conversation shell.  With a null [sessionId] it is a draft:
  /// the same header, drawer and composer are shown, the desktop creates the
  /// session on the first send, and the identity is updated in place without
  /// pushing a second page.
  const ConversationPage({
    super.key,
    required this.deviceId,
    this.workspacePath,
    this.sessionId,
    this.title,
    this.initialText,
    this.autoSendInitialText = false,
    this.onOpenWebView,
  });

  final String deviceId;

  /// Null while a draft has not resolved its workspace yet.
  final String? workspacePath;

  /// Null for a draft.
  final String? sessionId;
  final String? title;

  /// Optional text handed off by the native shell's composer.  Keeping this
  /// on the route prevents a first message from being lost when the shell
  /// opens the real conversation page.
  final String? initialText;
  final bool autoSendInitialText;

  /// 原生通道不可用时的降级入口。
  final VoidCallback? onOpenWebView;

  @override
  ConsumerState<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends ConsumerState<ConversationPage> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  late final TextEditingController _composer;
  late final ScrollController _scrollController;
  final List<ConversationAttachment> _attachments = [];

  /// Shell identity.  Mutable so a draft can become an existing session (and
  /// a drawer tap can switch sessions) without a route change.
  String? _sessionId;
  String? _workspacePath;
  String? _title;

  /// Draft create in flight; the same operation id is reused on retry so the
  /// desktop answers `duplicate` rather than creating a second session.
  bool _creating = false;
  String? _createOperationId;
  String? _draftError;

  bool get _isDraft => _sessionId == null;

  /// Workspace for requests.  A draft falls back to the desktop's active
  /// workspace (authoritative per protocol) and then to any known path.
  String get _wp {
    final explicit = _workspacePath?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final live = ref
        .read(relaySourceProvider)[widget.deviceId]
        ?.workspaceKey
        ?.trim();
    if (live != null && live.isNotEmpty) return live;
    final paths = _knownWorkspaces();
    return paths.isEmpty ? '' : paths.first;
  }

  List<String> _knownWorkspaces() {
    final sessions =
        ref.read(sessionIndexProvider)[widget.deviceId]?.values ??
        const <SessionState>[];
    final paths = <String>{};
    for (final session in sessions) {
      final path = session.workspacePath?.trim().isNotEmpty == true
          ? session.workspacePath!.trim()
          : session.workspace?.trim();
      if (path != null && path.isNotEmpty) paths.add(path);
    }
    final connected = ref
        .read(relaySourceProvider)[widget.deviceId]
        ?.workspaceKey
        ?.trim();
    if (connected != null && connected.isNotEmpty) paths.add(connected);
    return paths.toList()..sort();
  }

  @override
  void initState() {
    super.initState();
    _sessionId = widget.sessionId;
    _workspacePath = widget.workspacePath;
    _title = widget.title;
    _composer = TextEditingController();
    _scrollController = ScrollController()..addListener(_onScroll);
    // Notification / task-card deep link: open the referenced session in
    // this shell (only this device's jumps apply here).
    ref.listenManual(pendingSessionJumpProvider, (prev, next) {
      if (!mounted || next == null || next.deviceId != widget.deviceId) {
        return;
      }
      if (next.sessionId == _sessionId) {
        ref.read(pendingSessionJumpProvider.notifier).clear();
        return;
      }
      final session = ref.read(
        sessionIndexProvider,
      )[widget.deviceId]?[next.sessionId];
      final workspace = session?.workspacePath?.trim().isNotEmpty == true
          ? session!.workspacePath!.trim()
          : _wp;
      ref.read(pendingSessionJumpProvider.notifier).clear();
      _switchIdentity(
        sessionId: next.sessionId,
        workspacePath: workspace,
        title: session?.title,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_isDraft) {
        _load();
        unawaited(_loadRuntimeConfig());
      }
      final initial = widget.initialText?.trim();
      if (initial == null || initial.isEmpty) return;
      _composer.text = initial;
      if (widget.autoSendInitialText) unawaited(_sendInitialText());
    });
  }

  Future<void> _sendInitialText() async {
    for (var attempt = 0; attempt < 40; attempt++) {
      if (!mounted) return;
      final ready = ref.read(
        nativeBootstrapProvider((
          deviceId: widget.deviceId,
          sessionId: _sessionId,
        )),
      );
      final canSend = _isDraft ? ready.draftCreateReady : ready.canSend;
      if (canSend) {
        _send();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  @override
  void didUpdateWidget(covariant ConversationPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId ||
        oldWidget.deviceId != widget.deviceId) {
      _switchIdentity(
        sessionId: widget.sessionId,
        workspacePath: widget.workspacePath,
        title: widget.title,
      );
    }
  }

  /// Point the shell at another session (or back to a draft) in place.
  void _switchIdentity({
    required String? sessionId,
    required String? workspacePath,
    required String? title,
  }) {
    setState(() {
      _sessionId = sessionId;
      _workspacePath = workspacePath;
      _title = title;
      _draftError = null;
      _creating = false;
      _createOperationId = null;
    });
    if (sessionId == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _sessionId != sessionId) return;
      _load();
      unawaited(_loadRuntimeConfig());
    });
  }

  @override
  void dispose() {
    _composer.dispose();
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _load({bool refresh = false}) {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    ref
        .read(conversationProvider.notifier)
        .load(
          deviceId: widget.deviceId,
          workspacePath: _wp,
          sessionId: sessionId,
          refresh: refresh,
        );
  }

  Future<void> _loadRuntimeConfig({bool refresh = false}) async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    await ref
        .read(conversationProvider.notifier)
        .loadRuntimeConfig(
          deviceId: widget.deviceId,
          workspacePath: _wp,
          sessionId: sessionId,
          refresh: refresh,
        );
  }

  Future<void> _pickModel(ConversationRuntimeConfig config) async {
    final l10n = AppLocalizations.of(context)!;
    final selected = await showModalBottomSheet<ConversationModelOption>(
      context: context,
      backgroundColor: context.zt.surface,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          child: config.models.isEmpty
              ? _RuntimeEmptySheet(
                  icon: Icons.hub_outlined,
                  // "not returned" and "returned empty" are different facts.
                  text: config.catalogState == ConfigFieldState.empty
                      ? '桌面端返回了空的模型目录'
                      : l10n.conversationModelUnavailable,
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    Text(
                      l10n.conversationModel,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: context.zt.textHi,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final option in config.models)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        enabled: option.enabled,
                        leading: Icon(
                          option.providerId == config.providerId &&
                                  option.modelId == config.modelId
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          color:
                              option.providerId == config.providerId &&
                                  option.modelId == config.modelId
                              ? context.zt.accent
                              : context.zt.textLo,
                        ),
                        title: Text(option.displayName),
                        subtitle: Text(
                          option.enabled
                              ? [
                                  option.providerLabel ?? option.providerId,
                                  option.modelId,
                                  if (option.contextWindow != null)
                                    '${_formatTokens(option.contextWindow!)} ctx',
                                ].join(' · ')
                              : '不可用：${option.disabledReason ?? 'disabled'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: option.enabled
                            ? () => Navigator.pop(sheetContext, option)
                            : null,
                      ),
                  ],
                ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    unawaited(
      ref
          .read(conversationProvider.notifier)
          .updateRuntimeConfig(
            deviceId: widget.deviceId,
            workspacePath: _wp,
            sessionId: _sessionId!,
            providerId: selected.providerId,
            modelId: selected.modelId,
          ),
    );
  }

  Future<void> _pickThought(ConversationRuntimeConfig config) async {
    final l10n = AppLocalizations.of(context)!;
    // Options come only from the desktop snapshot (settings.thoughtLevel.
    // available[] or the selected model's reasoning.levels[]).  When none
    // were returned the sheet is read-only: the current value is shown but
    // there is nothing the user can pick.
    final levels = config.thoughtSelectable
        ? config.thoughtOptions
        : const <ThoughtOption>[];
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: context.zt.surface,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.conversationThought,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: context.zt.textHi,
                ),
              ),
              const SizedBox(height: 8),
              if (levels.isEmpty) ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.radio_button_checked,
                    color: context.zt.accent,
                  ),
                  title: Text(
                    config.thoughtLevel == null
                        ? '桌面端未返回当前思考级别'
                        : _thoughtLabel(config, config.thoughtLevel!),
                  ),
                  subtitle: Text(
                    config.thoughtOptionsState == ConfigFieldState.empty
                        ? '桌面端返回了空的级别列表，当前值只读'
                        : '可选级别未返回，当前值只读',
                  ),
                ),
              ] else
                for (final level in levels)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      level.value == config.thoughtLevel
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: level.value == config.thoughtLevel
                          ? context.zt.accent
                          : context.zt.textLo,
                    ),
                    title: Text(level.displayName),
                    subtitle: Text(level.description ?? level.value),
                    onTap: () => Navigator.pop(sheetContext, level.value),
                  ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    unawaited(
      ref
          .read(conversationProvider.notifier)
          .updateRuntimeConfig(
            deviceId: widget.deviceId,
            workspacePath: _wp,
            sessionId: _sessionId!,
            thoughtLevel: selected,
          ),
    );
  }

  Future<void> _showContext(ConversationRuntimeConfig config) async {
    final l10n = AppLocalizations.of(context)!;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.zt.surface,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.conversationContext,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: context.zt.textHi,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _contextLabel(config, l10n),
                style: TextStyle(fontSize: 14, color: context.zt.textHi),
              ),
              if (config.autoCompactThresholdTokens != null) ...[
                const SizedBox(height: 6),
                Text(
                  '自动压缩阈值：${_formatTokens(config.autoCompactThresholdTokens!)}',
                  style: TextStyle(fontSize: 12, color: context.zt.textLo),
                ),
              ],
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    unawaited(_loadRuntimeConfig(refresh: true));
                  },
                  icon: const Icon(Icons.refresh_rounded, size: 17),
                  label: Text(l10n.conversationRefresh),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 提交一次交互回应。**写操作**：由用户点按钮触发，不自动进行。
  void _resolve(PermissionBlock block, PermissionOption? option) {
    final interactionId = block.interactionId;
    if (interactionId == null || interactionId.isEmpty || _isDraft) return;
    ref
        .read(conversationProvider.notifier)
        .resolveInteraction(
          deviceId: widget.deviceId,
          workspacePath: _wp,
          sessionId: _sessionId!,
          interactionId: interactionId,
          optionId: option?.optionId,
        );
  }

  void _onScroll() {
    if (_isDraft ||
        !_scrollController.hasClients ||
        _scrollController.position.pixels <
            _scrollController.position.maxScrollExtent - 120) {
      return;
    }
    final st = ref.read(
      conversationProvider.select(
        (m) =>
            m[ConversationNotifier.keyOf(widget.deviceId, _sessionId ?? '')] ??
            const ConversationState(),
      ),
    );
    if (!st.loadingOlder && st.hasMore) _loadOlder();
  }

  void _loadOlder() {
    if (_isDraft) return;
    unawaited(
      ref
          .read(conversationProvider.notifier)
          .loadOlder(
            deviceId: widget.deviceId,
            workspacePath: _wp,
            sessionId: _sessionId!,
          ),
    );
  }

  void _send() {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    if (_isDraft) {
      unawaited(_createFromDraft(text));
      return;
    }
    final attachments = List<ConversationAttachment>.unmodifiable(_attachments);
    _composer.clear();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(_attachments.clear);
    unawaited(_sendAndRestore(text, attachments));
  }

  /// Create the session from the draft.  One write per operation id; a lost
  /// receipt is recovered from the task index before any retry is offered.
  Future<void> _createFromDraft(String text) async {
    if (_creating) return;
    final workspace = _wp;
    if (workspace.isEmpty) {
      setState(
        () => _draftError = AppLocalizations.of(
          context,
        )!.conversationWorkspaceUnavailable,
      );
      return;
    }
    final operationId = _createOperationId ??= 'zr-create-${_newOpId()}';
    final knownBefore = {
      for (final s
          in ref.read(sessionIndexProvider)[widget.deviceId]?.values ??
              const <SessionState>[])
        s.sessionId,
    };
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    setState(() {
      _creating = true;
      _draftError = null;
    });
    FocusManager.instance.primaryFocus?.unfocus();

    var sessionId = await ref
        .read(relaySourceProvider.notifier)
        .createConversation(
          deviceId: widget.deviceId,
          workspacePath: workspace,
          text: text,
          clientOperationId: operationId,
        );
    if (!mounted) return;

    if (sessionId == null || sessionId.isEmpty) {
      // Receipt lost?  The desktop may still have created it.
      final source = ref.read(relaySourceProvider.notifier);
      final bridge = source.bridgeOf(widget.deviceId);
      await bridge?.refreshTasks();
      if (!mounted) return;
      sessionId = CreateRecovery.findCreatedSession(
        sessions:
            ref.read(sessionIndexProvider)[widget.deviceId]?.values ??
            const <SessionState>[],
        workspacePath: workspace,
        firstInput: text,
        sinceMs: startedAt - 5000,
        knownBefore: knownBefore,
      );
    }

    if (sessionId == null || sessionId.isEmpty) {
      final receipt = ref
          .read(relaySourceProvider.notifier)
          .lastCommandReceipt(widget.deviceId);
      setState(() {
        _creating = false;
        _draftError = receipt != null && receipt.isRefusal
            ? '桌面端拒绝创建：${receipt.safeLabel}'
            : AppLocalizations.of(context)!.conversationCreateFailed;
      });
      return;
    }

    // Success: same route, new identity.  The draft text is the first turn,
    // so the composer is cleared only now.
    _composer.clear();
    setState(() {
      _creating = false;
      _createOperationId = null;
      _draftError = null;
      _attachments.clear();
    });
    _switchIdentity(
      sessionId: sessionId,
      workspacePath: workspace,
      title: text,
    );
  }

  static int _opSeq = 0;
  static String _newOpId() =>
      '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-${++_opSeq}';

  Future<void> _sendAndRestore(
    String text,
    List<ConversationAttachment> attachments,
  ) async {
    final sent = await ref
        .read(conversationProvider.notifier)
        .sendMessage(
          deviceId: widget.deviceId,
          workspacePath: _wp,
          sessionId: _sessionId!,
          text: text,
          attachments: attachments,
        );
    // A failed receipt must not destroy the user's draft. The composer is
    // disabled while the request is in flight, so restoring here is safe.
    if (!mounted || sent) return;
    _composer.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() {
      _attachments
        ..clear()
        ..addAll(attachments);
    });
  }

  Future<void> _pickAttachment() async {
    final l10n = AppLocalizations.of(context)!;
    if (_attachments.length >= 5) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('最多添加 5 个文件')));
      return;
    }
    try {
      final files = await openFiles();
      for (final file in files) {
        if (!mounted || _attachments.length >= 5) break;
        final bytes = await file.readAsBytes();
        if (!mounted) break;
        if (bytes.length > 20 * 1024 * 1024) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('${file.name} 超过 20 MB，已跳过')));
          continue;
        }
        _attachments.add(
          ConversationAttachment(
            fileName: file.name,
            mime: file.mimeType ?? 'application/octet-stream',
            bytes: bytes,
          ),
        );
      }
      if (mounted) setState(() {});
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${l10n.conversationAttach}：$error')),
      );
    }
  }

  /// Stop is pre-authorised by the user: no confirmation dialog.  Double
  /// taps are absorbed by the notifier's per-epoch guard, not by a modal.
  void _stop() {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    unawaited(HapticFeedback.mediumImpact());
    unawaited(
      ref
          .read(conversationProvider.notifier)
          .stopConversation(
            deviceId: widget.deviceId,
            workspacePath: _wp,
            sessionId: sessionId,
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final st = ref.watch(
      conversationProvider.select(
        (m) =>
            m[ConversationNotifier.keyOf(widget.deviceId, _sessionId ?? '')] ??
            const ConversationState(),
      ),
    );
    // Layered readiness: transport, agent handshake, workspace and the
    // session subscription ack must all be ready before sending is offered.
    final ready = ref.watch(
      nativeBootstrapProvider((
        deviceId: widget.deviceId,
        sessionId: _sessionId,
      )),
    );

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: context.zt.bg,
      drawer: ConversationDrawer(
        deviceId: widget.deviceId,
        sessionId: _sessionId ?? '',
        workspacePath: _wp,
        onNewConversation: () => _switchIdentity(
          sessionId: null,
          workspacePath: _workspacePath,
          title: null,
        ),
        onSelectSession: (deviceId, sessionId, workspacePath, title) {
          if (deviceId != widget.deviceId) {
            // Another device: that device's own shell tab owns it.
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ConversationPage(
                  deviceId: deviceId,
                  workspacePath: workspacePath,
                  sessionId: sessionId,
                  title: title,
                ),
              ),
            );
            return;
          }
          _switchIdentity(
            sessionId: sessionId,
            workspacePath: workspacePath,
            title: title,
          );
        },
      ),
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _isDraft
                  ? l10n.conversationNew
                  : (_title?.trim().isNotEmpty == true
                        ? _title!.trim()
                        : l10n.conversationUntitled),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
                color: context.zt.textHi,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              '${_basename(_wp)} · ${ready.status.labelZh}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: (_isDraft ? ready.draftCreateReady : ready.canSend)
                    ? context.zt.textLo
                    : context.zt.warn,
              ),
            ),
          ],
        ),
        actions: [
          if (!_isDraft)
            IconButton(
              tooltip: l10n.conversationRefresh,
              icon: const Icon(Icons.refresh_rounded, size: 19),
              color: context.zt.textLo,
              onPressed: () => _load(refresh: true),
            ),
          if (widget.onOpenWebView != null)
            IconButton(
              tooltip: l10n.conversationOpenWeb,
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              color: context.zt.textLo,
              onPressed: widget.onOpenWebView,
            ),
        ],
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: context.zt.hairline),
        ),
      ),
      body: _body(context, l10n, st, ready),
    );
  }

  /// Draft: the same shell, a compact hint instead of a timeline, and a
  /// composer that creates the session on the first send.  No large
  /// welcome artwork; the space belongs to the input.
  Widget _draftBody(
    BuildContext context,
    AppLocalizations l10n,
    NativeBootstrapState ready,
  ) {
    final workspace = _wp;
    final canCreate = ready.draftCreateReady && workspace.isNotEmpty;
    return Column(
      children: [
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    workspace.isEmpty
                        ? l10n.conversationWorkspaceUnavailable
                        : _basename(workspace),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: context.zt.textHi,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l10n.conversationNewHint,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12.5, color: context.zt.textLo),
                  ),
                  if (_draftError != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _draftError!,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: context.zt.danger),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        _ComposerBar(
          controller: _composer,
          enabled: canCreate && !_creating,
          sending: _creating,
          stopping: false,
          onSend: _send,
          onStop: () {},
          canStop: false,
          disabledHint: workspace.isEmpty
              ? l10n.conversationWorkspaceUnavailable
              : ready.status.labelZh,
          showRuntimeChips: false,
          leading: _ComposerChip(
            icon: Icons.folder_open_outlined,
            label: workspace.isEmpty
                ? l10n.conversationWorkspace
                : SessionGrouping.workspaceLabel(workspace),
            onTap: _creating ? () {} : _pickWorkspace,
          ),
          runtimeConfig: ConversationRuntimeConfig.empty,
          onModel: () {},
          onThought: () {},
          onContext: () {},
          onAttach: _pickAttachment,
          attachments: _attachments,
          onRemoveAttachment: (index) =>
              setState(() => _attachments.removeAt(index)),
        ),
      ],
    );
  }

  Future<void> _pickWorkspace() async {
    final l10n = AppLocalizations.of(context)!;
    final paths = _knownWorkspaces();
    if (paths.isEmpty) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: context.zt.surface,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          children: [
            Text(
              l10n.conversationWorkspace,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: context.zt.textHi,
              ),
            ),
            const SizedBox(height: 8),
            for (final path in paths)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  path == _wp
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: path == _wp ? context.zt.accent : context.zt.textLo,
                ),
                title: Text(
                  SessionGrouping.workspaceLabel(path),
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(sheetContext, path),
              ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => _workspacePath = selected);
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    ConversationState st,
    NativeBootstrapState ready,
  ) {
    if (_isDraft) return _draftBody(context, l10n, ready);
    if (st.loading && st.rows.isEmpty) {
      return Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 1.6,
            color: context.zt.accent,
          ),
        ),
      );
    }

    if (st.error != null) {
      return _Notice(
        text: st.error!,
        actionLabel: widget.onOpenWebView == null
            ? null
            : l10n.conversationOpenWeb,
        onAction: widget.onOpenWebView,
      );
    }

    final blocks = st.blocks;
    return Column(
      children: [
        if (st.actionError != null) _ActionErrorBanner(text: st.actionError!),
        Expanded(
          child: Column(
            children: [
              if (st.loading)
                LinearProgressIndicator(
                  minHeight: 1.5,
                  color: context.zt.accent,
                  backgroundColor: Colors.transparent,
                ),
              Expanded(
                child: blocks.isEmpty
                    ? _Notice(text: l10n.conversationEmpty)
                    : NotificationListener<ScrollNotification>(
                        onNotification: (notification) {
                          if (notification is ScrollUpdateNotification) {
                            _onScroll();
                          }
                          return false;
                        },
                        child: ListView.builder(
                          controller: _scrollController,
                          reverse: true,
                          padding: const EdgeInsets.fromLTRB(16, 40, 16, 8),
                          // reverse 后 index 0 是最新块，加载更早放在视觉顶部。
                          itemCount: blocks.length + 1,
                          itemBuilder: (context, i) {
                            if (i == blocks.length) {
                              return _LoadOlder(
                                hasMore: st.hasMore,
                                loading: st.loadingOlder,
                                onTap: _loadOlder,
                              );
                            }
                            return _BlockView(
                              block: blocks[blocks.length - 1 - i],
                              onResolve: _resolve,
                              sending: st.sending,
                            );
                          },
                        ),
                      ),
              ),
            ],
          ),
        ),
        _ComposerBar(
          controller: _composer,
          // Sending requires transport + agent + workspace + subscription
          // ack; a live relay alone is not enough.
          enabled: ready.canSend && !st.sendingMessage && !st.stopping,
          sending: st.sendingMessage,
          stopping: st.stopping,
          onSend: _send,
          onStop: _stop,
          // The stop square replaces send only while the desktop is really
          // running (streaming after our send, a running phase in the index,
          // or a pending approval).
          // Real desktop signals only: the session index phase, or a
          // permission waiting for the user.  sendPhase is a local
          // send-lifecycle view and must never pin the stop square
          // (review P0-1).
          canStop:
              ready.canSend &&
              (st.hasPendingAction ||
                  ref.watch(
                        sessionIndexProvider.select(
                          (m) => m[widget.deviceId]?[_sessionId]?.phase,
                        ),
                      ) ==
                      'running'),
          disabledHint: ready.status.labelZh,
          showRuntimeChips: true,
          runtimeConfig: st.runtimeConfig,
          onModel: () => _pickModel(st.runtimeConfig),
          onThought: () => _pickThought(st.runtimeConfig),
          onContext: () => _showContext(st.runtimeConfig),
          onAttach: _pickAttachment,
          attachments: _attachments,
          onRemoveAttachment: (index) =>
              setState(() => _attachments.removeAt(index)),
        ),
      ],
    );
  }
}

class _ActionErrorBanner extends StatelessWidget {
  const _ActionErrorBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: context.zt.danger.withValues(alpha: 0.10),
      border: Border.all(color: context.zt.danger.withValues(alpha: 0.28)),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(text, style: TextStyle(fontSize: 12, color: context.zt.danger)),
  );
}

class _ComposerBar extends StatelessWidget {
  const _ComposerBar({
    required this.controller,
    required this.enabled,
    required this.sending,
    required this.stopping,
    required this.onSend,
    required this.onStop,
    required this.canStop,
    required this.runtimeConfig,
    required this.onModel,
    required this.onThought,
    required this.onContext,
    required this.onAttach,
    required this.attachments,
    required this.onRemoveAttachment,
    this.disabledHint,
    this.showRuntimeChips = true,
    this.leading,
  });

  final TextEditingController controller;
  final bool enabled;

  /// Layer-specific reason the composer is disabled (e.g. "正在初始化 Agent").
  final String? disabledHint;

  /// Model / thought / context chips need a session snapshot; a draft has
  /// none yet and shows its workspace chip via [leading] instead.
  final bool showRuntimeChips;
  final Widget? leading;
  final bool sending;
  final bool stopping;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final bool canStop;

  final ConversationRuntimeConfig runtimeConfig;

  final VoidCallback onModel;

  final VoidCallback onThought;

  final VoidCallback onContext;

  final VoidCallback onAttach;

  final List<ConversationAttachment> attachments;

  final ValueChanged<int> onRemoveAttachment;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Material(
      color: zt.surface,
      child: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: zt.hairline)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (attachments.isNotEmpty) ...[
                SizedBox(
                  width: double.infinity,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (var i = 0; i < attachments.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: _AttachmentChip(
                              attachment: attachments[i],
                              onRemove: () => onRemoveAttachment(i),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 5),
              ],
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (leading != null) ...[
                      leading!,
                      const SizedBox(width: 6),
                    ],
                    if (showRuntimeChips) ...[
                      _ComposerChip(
                        icon: Icons.hub_outlined,
                        label:
                            runtimeConfig.modelLabel ??
                            runtimeConfig.modelId ??
                            AppLocalizations.of(context)!.conversationModel,
                        onTap: onModel,
                        loading: runtimeConfig.loading,
                      ),
                      const SizedBox(width: 6),
                      _ComposerChip(
                        icon: Icons.psychology_outlined,
                        label: runtimeConfig.thoughtLevel == null
                            ? AppLocalizations.of(context)!.conversationThought
                            : _thoughtLabel(
                                runtimeConfig,
                                runtimeConfig.thoughtLevel!,
                              ),
                        onTap: onThought,
                        loading: runtimeConfig.loading,
                      ),
                      const SizedBox(width: 6),
                      _ComposerChip(
                        icon: Icons.data_usage_outlined,
                        label: _contextLabel(
                          runtimeConfig,
                          AppLocalizations.of(context)!,
                        ),
                        onTap: onContext,
                        loading: runtimeConfig.loading,
                      ),
                      const SizedBox(width: 6),
                    ],
                    IconButton(
                      tooltip: AppLocalizations.of(context)!.conversationAttach,
                      onPressed: enabled ? onAttach : null,
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.attach_file_rounded, color: zt.textLo),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      enabled: enabled,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: enabled
                            ? '输入消息…'
                            : (disabledHint ?? '等待桌面端就绪'),
                        isDense: true,
                        filled: true,
                        fillColor: zt.field,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: (_) {
                        if (enabled) _sendFromKeyboard();
                      },
                    ),
                  ),
                  // One primary action slot (UX spec §5.1).  Exactly one of
                  // stopping / stop / sending / send / attach is rendered.
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (context, value, _) => _PrimaryAction(
                      state: composerPrimaryAction(
                        enabled: enabled,
                        sending: sending,
                        stopping: stopping,
                        canStop: canStop,
                        hasContent:
                            value.text.trim().isNotEmpty ||
                            attachments.isNotEmpty,
                      ),
                      onSend: onSend,
                      onStop: onStop,
                      onAttach: onAttach,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _sendFromKeyboard() => onSend();
}

/// Which single control occupies the composer's primary slot.
enum PrimaryActionState { attach, send, sending, stop, stopping, disabled }

/// Pure decision table for the composer's single primary action.  Exposed so
/// the "exactly one control at a time" contract is unit-testable without a
/// widget tree.
PrimaryActionState composerPrimaryAction({
  required bool enabled,
  required bool sending,
  required bool stopping,
  required bool canStop,
  required bool hasContent,
}) {
  if (stopping) return PrimaryActionState.stopping;
  if (canStop) return PrimaryActionState.stop;
  if (sending) return PrimaryActionState.sending;
  if (!enabled) return PrimaryActionState.disabled;
  return hasContent ? PrimaryActionState.send : PrimaryActionState.attach;
}

class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({
    required this.state,
    required this.onSend,
    required this.onStop,
    required this.onAttach,
  });

  final PrimaryActionState state;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onAttach;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    Widget spinner(Color color) => SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 1.6, color: color),
    );
    final (
      String tooltip,
      Widget icon,
      VoidCallback? onPressed,
    ) = switch (state) {
      PrimaryActionState.stopping => ('正在停止', spinner(zt.danger), null),
      PrimaryActionState.stop => (
        '停止执行',
        Icon(Icons.stop_rounded, color: zt.danger),
        onStop,
      ),
      PrimaryActionState.sending => ('正在发送', spinner(zt.accent), null),
      PrimaryActionState.send => (
        '发送消息',
        Icon(Icons.arrow_upward_rounded, color: zt.accent),
        onSend,
      ),
      PrimaryActionState.attach => (
        '添加附件',
        Icon(Icons.add_rounded, color: zt.textLo),
        onAttach,
      ),
      PrimaryActionState.disabled => (
        '等待桌面端就绪',
        Icon(
          Icons.arrow_upward_rounded,
          color: zt.textLo.withValues(alpha: 0.4),
        ),
        null,
      ),
    };
    return Semantics(
      key: ValueKey('primary-action-${state.name}'),
      button: true,
      label: tooltip,
      child: SizedBox(
        width: 44,
        height: 44,
        child: IconButton(tooltip: tooltip, onPressed: onPressed, icon: icon),
      ),
    );
  }
}

class _ComposerChip extends StatelessWidget {
  const _ComposerChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.loading = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 180),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: zt.field,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: zt.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            loading
                ? SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.4,
                      color: zt.accent,
                    ),
                  )
                : Icon(icon, size: 14, color: zt.textLo),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: zt.textLo),
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.expand_more_rounded, size: 14, color: zt.textLo),
          ],
        ),
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({required this.attachment, required this.onRemove});

  final ConversationAttachment attachment;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Container(
      constraints: const BoxConstraints(maxWidth: 210),
      padding: const EdgeInsets.fromLTRB(8, 5, 4, 5),
      decoration: BoxDecoration(
        color: zt.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: zt.accent.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insert_drive_file_outlined, size: 14, color: zt.accent),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              attachment.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: zt.textHi),
            ),
          ),
          IconButton(
            onPressed: onRemove,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            icon: Icon(Icons.close_rounded, size: 15, color: zt.textLo),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 块渲染

class _BlockView extends StatelessWidget {
  const _BlockView({required this.block, this.onResolve, this.sending = false});

  final ConversationBlock block;

  /// 交互回应回调（写操作）。为空表示只读展示。
  final void Function(PermissionBlock block, PermissionOption? option)?
  onResolve;

  final bool sending;

  @override
  Widget build(BuildContext context) => switch (block) {
    TextBlock b => _TextBlockView(block: b),
    ReasoningBlock b => _ReasoningView(block: b),
    ToolCallGroup b => _ToolGroupView(group: b),
    HookBlock b => _HookView(block: b),
    TodoBlock b => _TodoView(block: b),
    MarkerBlock b => _MarkerView(block: b),
    TurnHeaderBlock b => _TurnHeaderView(block: b),
    PermissionBlock b => _PermissionView(
      block: b,
      onResolve: onResolve,
      sending: sending,
    ),
  };
}

/// 正文段落。用户消息用左侧细线区分，不做气泡。
class _TextBlockView extends StatelessWidget {
  const _TextBlockView({required this.block});

  final TextBlock block;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final zt = context.zt;
    final isUser = block.isUser;
    // 只有真人发言才用强调色标出来；后台结果 / 目标续跑只标记来源，
    // 否则会让人误以为是用户自己说的话。
    final isRealUser = block.isRealUser;
    final origin = block.userOrigin;

    return Padding(
      padding: EdgeInsets.only(top: isUser ? 18 : 10, bottom: isUser ? 4 : 6),
      child: Container(
        decoration: isRealUser
            ? BoxDecoration(
                border: Border(left: BorderSide(color: zt.accent, width: 2)),
              )
            : null,
        padding: isRealUser ? const EdgeInsets.only(left: 12) : EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (origin != null) ...[
              Row(
                children: [
                  Icon(
                    Icons.subdirectory_arrow_right,
                    size: 12,
                    color: zt.textLo,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    _originLabel(l10n, origin),
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 0.3,
                      color: zt.textLo,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
            ],
            SelectableText(
              block.text,
              style: TextStyle(
                fontSize: 14.5,
                height: 1.62,
                letterSpacing: 0.1,
                color: origin != null
                    ? zt.textLo
                    : (isUser ? zt.textHi : zt.textHi.withValues(alpha: 0.92)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 非真人来源的说明文案。
  static String _originLabel(AppLocalizations l10n, String origin) =>
      switch (origin) {
        'backgroundResult' => l10n.conversationSourceBackground,
        'goalContinuation' => l10n.conversationSourceGoal,
        'mailbox' => l10n.conversationSourceMailbox,
        'synthetic' => l10n.conversationSourceSynthetic,
        _ => origin,
      };
}

/// 思考过程：默认折叠，降饱和。
class _ReasoningView extends StatefulWidget {
  const _ReasoningView({required this.block});

  final ReasoningBlock block;

  @override
  State<_ReasoningView> createState() => _ReasoningViewState();
}

class _ReasoningViewState extends State<_ReasoningView> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = widget.block.text;
    if (text.isEmpty) return const SizedBox.shrink();

    final preview = text.length > 60 ? '${text.substring(0, 60)}…' : text;

    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: InkWell(
        onTap: () => setState(() => _open = !_open),
        borderRadius: BorderRadius.circular(4),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: context.zt.hairline, width: 2),
            ),
          ),
          padding: const EdgeInsets.only(left: 10, top: 2, bottom: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    widget.block.durationMs == null
                        ? l10n.conversationThinking
                        : l10n.conversationThinkingDuration(
                            _durationLabel(widget.block.durationMs!),
                          ),
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 0.3,
                      color: context.zt.textLo,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    _open
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 14,
                    color: context.zt.textLo,
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                _open ? text : preview,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.5,
                  color: context.zt.textLo,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一组工具调用。标题一行，展开后逐条列出。
class _ToolGroupView extends StatefulWidget {
  const _ToolGroupView({required this.group});

  final ToolCallGroup group;

  @override
  State<_ToolGroupView> createState() => _ToolGroupViewState();
}

class _ToolGroupViewState extends State<_ToolGroupView> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final g = widget.group;
    final names = g.toolNames.join(' · ');
    final hue = g.anyFailed ? context.zt.danger : context.zt.textLo;

    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: g.anyFailed ? context.zt.danger : context.zt.live,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      names.isEmpty ? l10n.conversationToolCall : names,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.1,
                        color: hue,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l10n.conversationStepCount(g.rows.length),
                    style: TextStyle(fontSize: 11, color: context.zt.textLo),
                  ),
                  if (g.skillsLoaded > 0) ...[
                    const SizedBox(width: 7),
                    Text(
                      l10n.conversationSkillCount(g.skillsLoaded),
                      style: TextStyle(fontSize: 11, color: context.zt.textLo),
                    ),
                  ],
                  const SizedBox(width: 4),
                  Icon(
                    _open
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 15,
                    color: context.zt.textLo,
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.only(left: 13, top: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [for (final r in g.rows) _ToolRow(row: r)],
              ),
            ),
        ],
      ),
    );
  }
}

/// 单条工具调用：工具名 + 一句摘要，可展开看入参。
class _ToolRow extends StatefulWidget {
  const _ToolRow({required this.row});

  final ConversationRow row;

  @override
  State<_ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<_ToolRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final failed = row.status == 'error';
    final summary = row.summary;

    return Container(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: context.zt.hairline, width: 1)),
      ),
      padding: const EdgeInsets.only(left: 10, top: 4, bottom: 4),
      margin: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.toolName ?? 'tool',
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                    color: failed
                        ? context.zt.danger
                        : context.zt.textHi.withValues(alpha: 0.85),
                  ),
                ),
                if (summary.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: context.zt.textLo,
                      ),
                    ),
                  ),
                ] else
                  const Spacer(),
                if (failed)
                  Text(
                    '失败',
                    style: TextStyle(fontSize: 11, color: context.zt.danger),
                  ),
              ],
            ),
          ),
          if (_open && (row.inputText?.isNotEmpty ?? false))
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 4),
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: context.zt.field,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: context.zt.hairline),
                ),
                padding: const EdgeInsets.all(10),
                child: SelectableText(
                  row.prettyInput,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.5,
                    fontFamily: 'monospace',
                    color: context.zt.textLo,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 钩子调用：一行带过，不抢戏。
class _HookView extends StatelessWidget {
  const _HookView({required this.block});

  final HookBlock block;

  @override
  Widget build(BuildContext context) {
    final label = block.label;
    if (label.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Row(
        children: [
          Icon(Icons.bolt_outlined, size: 13, color: context.zt.textLo),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontFamily: 'monospace',
                color: context.zt.textLo,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 小部件

class _LoadOlder extends StatelessWidget {
  const _LoadOlder({
    required this.hasMore,
    required this.loading,
    required this.onTap,
  });

  final bool hasMore;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (!hasMore && !loading) return const SizedBox(height: 4);
    return InkWell(
      onTap: loading ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: loading
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.4,
                    color: context.zt.accent,
                  ),
                )
              : Text(
                  l10n.conversationLoadOlder,
                  style: TextStyle(fontSize: 12, color: context.zt.textLo),
                ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.actionLabel, this.onAction});

  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: context.zt.textLo),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.zt.textHi,
                  side: BorderSide(color: context.zt.hairline),
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

class _RuntimeEmptySheet extends StatelessWidget {
  const _RuntimeEmptySheet({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: context.zt.textLo),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 13, color: context.zt.textLo),
          ),
        ),
      ],
    ),
  );
}

/// Native conversation navigation.  On a phone it is a left drawer; the
/// same hierarchy can later be promoted to a permanent pane on wide screens.
typedef ConversationSelect =
    void Function(
      String deviceId,
      String sessionId,
      String workspacePath,
      String? title,
    );

class ConversationDrawer extends ConsumerWidget {
  const ConversationDrawer({
    super.key,
    required this.deviceId,
    required this.sessionId,
    required this.workspacePath,
    required this.onNewConversation,
    required this.onSelectSession,
  });

  final String deviceId;

  /// Empty string for a draft.
  final String sessionId;
  final String workspacePath;

  /// Switch the current shell back to a draft (no route push).
  final VoidCallback onNewConversation;

  /// Open a session in the current shell (no route push for the same device).
  final ConversationSelect onSelectSession;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final devices = ref.watch(deviceListProvider);
    final index = ref.watch(sessionIndexProvider);
    // Device → workspace → session hierarchy (UX spec §3.2).  Sessions of
    // two devices that happen to share a workspace path must never merge
    // into one group (review P1-1); the device header shows only when more
    // than one device has sessions.
    final sessionsOf = <RemoteDevice, List<SessionState>>{};
    for (final device in devices) {
      final sessions =
          index[device.id]?.values.toList() ?? const <SessionState>[];
      if (sessions.isEmpty) continue;
      sessions.sort(SessionRanking.compareSessions);
      sessionsOf[device] = sessions;
    }
    final multipleDevices = sessionsOf.length > 1;

    return Drawer(
      backgroundColor: context.zt.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 16, 12),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: context.zt.accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(Icons.forum_outlined, color: context.zt.accent),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l10n.conversationNew,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: context.zt.textHi,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.conversationNew,
                    onPressed: () {
                      Navigator.pop(context);
                      onNewConversation();
                    },
                    icon: Icon(Icons.add_rounded, color: context.zt.accent),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: context.zt.hairline),
            Expanded(
              child: sessionsOf.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Text(
                          l10n.sessionsPanelEmpty,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: context.zt.textLo,
                          ),
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(10, 12, 10, 20),
                      children: [
                        for (final de in sessionsOf.entries) ...[
                          if (multipleDevices) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.desktop_windows_outlined,
                                    size: 13,
                                    color: context.zt.textLo,
                                  ),
                                  const SizedBox(width: 5),
                                  Expanded(
                                    child: Text(
                                      de.key.displayName(l10n),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: context.zt.textLo,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          for (final key in _workspaceOrder(de.value)) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(10, 8, 10, 5),
                              child: Text(
                                SessionGrouping.workspaceLabel(key),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.3,
                                  color: context.zt.textLo,
                                ),
                              ),
                            ),
                            for (final session
                                in de.value
                                    .where(
                                      (s) =>
                                          SessionGrouping.workspaceKey(s) ==
                                          key,
                                    )
                                    .toList())
                              _ConversationDrawerItem(
                                device: de.key,
                                session: session,
                                selected:
                                    de.key.id == deviceId &&
                                    session.sessionId == sessionId,
                                onTap: () {
                                  Navigator.pop(context);
                                  if (de.key.id == deviceId &&
                                      session.sessionId == sessionId) {
                                    return;
                                  }
                                  final path = session.workspacePath?.trim();
                                  final fallback = ref
                                      .read(relaySourceProvider)[de.key.id]
                                      ?.workspaceKey;
                                  onSelectSession(
                                    de.key.id,
                                    session.sessionId,
                                    path?.isNotEmpty == true
                                        ? path!
                                        : (fallback ?? ''),
                                    session.title,
                                  );
                                },
                              ),
                          ],
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Workspace keys in first-seen order after the per-device ranking sort
/// (stable across refreshes; no second sort that could jump).
List<String> _workspaceOrder(List<SessionState> sessions) {
  final order = <String>[];
  for (final s in sessions) {
    final key = SessionGrouping.workspaceKey(s);
    if (!order.contains(key)) order.add(key);
  }
  return order;
}

class _ConversationDrawerItem extends StatelessWidget {
  const _ConversationDrawerItem({
    required this.device,
    required this.session,
    required this.selected,
    required this.onTap,
  });

  final RemoteDevice device;
  final SessionState session;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final title = session.title?.trim().isNotEmpty == true
        ? session.title!.trim()
        : session.sessionId;
    return Material(
      color: selected
          ? context.zt.accent.withValues(alpha: 0.12)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 9, 8, 9),
          child: Row(
            children: [
              Icon(
                session.phase == 'running'
                    ? Icons.radio_button_checked
                    : Icons.chat_bubble_outline_rounded,
                size: 15,
                color: session.phase == 'running'
                    ? context.zt.live
                    : context.zt.textLo,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: context.zt.textHi,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      device.displayName(l10n),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: context.zt.textLo,
                      ),
                    ),
                  ],
                ),
              ),
              if (session.permissionCount > 0)
                _DrawerBadge(
                  label: '${session.permissionCount}',
                  color: context.zt.danger,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DrawerBadge extends StatelessWidget {
  const _DrawerBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        color: context.zt.onAccent,
      ),
    ),
  );
}

// ---------------------------------------------------------------- 工具函数

String _durationLabel(int milliseconds) {
  final seconds = milliseconds / 1000;
  if (seconds < 1) return '${milliseconds}ms';
  if (seconds < 60) return '${seconds.toStringAsFixed(seconds < 10 ? 1 : 0)}s';
  final minutes = seconds ~/ 60;
  return '${minutes}m ${seconds.toInt() % 60}s';
}

/// Display name for a thought level: the desktop's own label when it was
/// returned, otherwise the raw value.  No hard-coded level table.
String _thoughtLabel(ConversationRuntimeConfig config, String value) {
  for (final option in config.thoughtOptions) {
    if (option.value == value) return option.displayName;
  }
  return value;
}

String _formatTokens(int value) {
  if (value < 1000) return '$value';
  if (value < 1000000) return '${(value / 1000).toStringAsFixed(1)}k';
  return '${(value / 1000000).toStringAsFixed(1)}m';
}

String _contextLabel(ConversationRuntimeConfig config, AppLocalizations l10n) {
  final used = config.contextUsedTokens;
  final max = config.contextMaxTokens;
  if (used == null && max == null) return l10n.conversationContext;
  return l10n.conversationContextTokens(
    used == null ? '—' : _formatTokens(used),
    max == null ? '—' : _formatTokens(max),
  );
}

String _basename(String path) {
  final p = path.replaceAll('\\', '/');
  final i = p.lastIndexOf('/');
  return i >= 0 && i + 1 < p.length ? p.substring(i + 1) : path;
}

/// 待办清单。
///
/// 不做成大卡片：待办是过程信息，一条一行最省地方，
/// 完成项降饱和 + 删除线，和未完成项一眼分得开。
class _TodoView extends StatelessWidget {
  const _TodoView({required this.block});

  final TodoBlock block;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final items = block.items;
    if (items.isEmpty) return const SizedBox.shrink();
    final zt = context.zt;
    final p = block.progress;

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                l10n.conversationTodo,
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.3,
                  color: zt.textLo,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${p.done}/${p.total}',
                style: TextStyle(
                  fontSize: 11,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: zt.textLo,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final t in items) _TodoRow(item: t),
        ],
      ),
    );
  }
}

class _TodoRow extends StatelessWidget {
  const _TodoRow({required this.item});

  final TodoItem item;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    final done = item.isDone;
    final active = item.isActive;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 14,
            height: 17,
            child: done
                ? Icon(Icons.check, size: 12, color: zt.textLo)
                : Center(
                    child: Container(
                      width: active ? 6 : 5,
                      height: active ? 6 : 5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: active ? zt.accent : Colors.transparent,
                        border: active
                            ? null
                            : Border.all(color: zt.hairline, width: 1.2),
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              item.title,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: done ? zt.textLo : zt.textHi,
                decoration: done ? TextDecoration.lineThrough : null,
                decorationColor: zt.textLo,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 待用户确认的交互。远程控制里最需要「看得见、点得到」的东西。
///
/// 视觉上刻意比普通块更实：左侧 2px 强调线 + 底色 + 边框，
/// 因为它是阻塞性的 —— 用户不处理，桌面端就一直等。
class _PermissionView extends StatelessWidget {
  const _PermissionView({
    required this.block,
    this.onResolve,
    this.sending = false,
  });

  final PermissionBlock block;
  final void Function(PermissionBlock block, PermissionOption? option)?
  onResolve;
  final bool sending;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final zt = context.zt;
    final options = block.options;
    final summary = block.summary;

    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6),
      child: Container(
        decoration: BoxDecoration(
          color: zt.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: zt.hairline),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 2, color: zt.accent),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (block.toolName.isNotEmpty)
                          Text(
                            block.toolName,
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w600,
                              color: zt.textHi,
                            ),
                          ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.conversationNeedsConfirm,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11.5, color: zt.accent),
                          ),
                        ),
                      ],
                    ),
                    if (summary.isNotEmpty) ...[
                      const SizedBox(height: 7),
                      SelectableText(
                        summary,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: zt.textHi,
                        ),
                      ),
                    ],
                    const SizedBox(height: 11),
                    if (sending)
                      Row(
                        children: [
                          SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.4,
                              color: zt.accent,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            l10n.conversationSubmitting,
                            style: TextStyle(fontSize: 12, color: zt.textLo),
                          ),
                        ],
                      )
                    else if (options.isEmpty)
                      Text(
                        l10n.conversationNoOptions,
                        style: TextStyle(fontSize: 12, color: zt.textLo),
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final o in options)
                            _OptionButton(
                              option: o,
                              onTap: onResolve == null
                                  ? null
                                  : () => onResolve!(block, o),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 授权选项按钮。允许类用实心，拒绝类用描边 + 危险色。
class _OptionButton extends StatelessWidget {
  const _OptionButton({required this.option, this.onTap});

  final PermissionOption option;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    final base = const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500);
    final radius = BorderRadius.circular(7);

    if (option.isAllow) {
      return FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: zt.accent,
          foregroundColor: zt.onAccent,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: radius),
        ),
        child: Text(option.label, style: base),
      );
    }

    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: option.isDeny ? zt.danger : zt.textHi,
        side: BorderSide(color: option.isDeny ? zt.danger : zt.hairline),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
      child: Text(option.label, style: base),
    );
  }
}

/// 轮次分隔。只在有信息可给时才出现（文件改动），否则退化成一条细线。
class _TurnHeaderView extends StatelessWidget {
  const _TurnHeaderView({required this.block});

  final TurnHeaderBlock block;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final zt = context.zt;
    final fc = block.fileChanges;

    if (fc == null || fc.files == 0) {
      return Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 4),
        child: Container(height: 1, color: zt.hairline),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Row(
        children: [
          Expanded(child: Container(height: 1, color: zt.hairline)),
          const SizedBox(width: 10),
          Text(
            l10n.conversationFileChanges(fc.files),
            style: TextStyle(fontSize: 11, color: zt.textLo),
          ),
          const SizedBox(width: 7),
          Text(
            '+${fc.additions}',
            style: TextStyle(fontSize: 11, color: zt.live),
          ),
          const SizedBox(width: 5),
          Text(
            '-${fc.deletions}',
            style: TextStyle(fontSize: 11, color: zt.danger),
          ),
          const SizedBox(width: 10),
          Expanded(child: Container(height: 1, color: zt.hairline)),
        ],
      ),
    );
  }
}

/// 时间线标记。实测用于「切换模型」——显示成一条细线 + 说明，
/// 不抢正文，但让"什么时候换的模型"有迹可循。
class _MarkerView extends StatelessWidget {
  const _MarkerView({required this.block});

  final MarkerBlock block;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final zt = context.zt;

    final label = block.isModelChange && block.toModel != null
        ? l10n.conversationModelSwitch(block.toModel!)
        : null;
    if (label == null) return const SizedBox(height: 6);

    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 2),
      child: Row(
        children: [
          Expanded(child: Container(height: 1, color: zt.hairline)),
          const SizedBox(width: 10),
          Icon(Icons.swap_horiz, size: 12, color: zt.textLo),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 11, color: zt.textLo)),
          const SizedBox(width: 10),
          Expanded(child: Container(height: 1, color: zt.hairline)),
        ],
      ),
    );
  }
}

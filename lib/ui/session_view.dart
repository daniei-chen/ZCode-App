import 'dart:async';
import 'dart:convert';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../services/event_observer.dart';
import '../services/link_builder.dart';
import '../services/notifier.dart';
import '../services/session_jump.dart';
import '../services/warmup.dart';
import '../state/active_session.dart';
import '../state/app_lifecycle.dart';
import '../state/event_feed.dart';
import '../state/notification_prefs.dart';
import '../state/panel_state.dart';
import '../state/root_tabs.dart';
import '../state/session_index.dart';
import '../state/session_pool.dart';
import '../state/session_status.dart';
import '../theme.dart';
import '../models/device_label.dart';
import 'session_panel.dart';
import 'unread_badge.dart';

class SessionView extends ConsumerStatefulWidget {
  final RemoteDevice device;

  const SessionView({super.key, required this.device});

  @override
  ConsumerState<SessionView> createState() => _SessionViewState();
}

class _SessionViewState extends ConsumerState<SessionView> {
  InAppWebViewController? _controller;
  bool _loading = true;
  bool _errorShown = false;
  DateTime _lastAutoReload = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _warmupTimer;

  SessionStatusNotifier? _statusNotifier;
  EventFeedNotifier? _feedNotifier;
  SessionIndexNotifier? _sessionIndexNotifier;
  ActiveSessionNotifier? _activeSessionNotifier;
  PanelDataNotifier? _panelDataNotifier;
  WarmupMemoryNotifier? _warmupNotifier;

  final StateDiffer _stateDiffer = StateDiffer();

  String? _activeSessionId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _statusNotifier ??= ref.read(sessionStatusProvider.notifier);
    _feedNotifier ??= ref.read(eventFeedProvider.notifier);
    _sessionIndexNotifier ??= ref.read(sessionIndexProvider.notifier);
    _activeSessionNotifier ??= ref.read(activeSessionProvider.notifier);
    _panelDataNotifier ??= ref.read(panelDataProvider.notifier);
    _warmupNotifier ??= ref.read(warmupMemoryProvider.notifier);
    unawaited(_warmupNotifier?.load(widget.device.id));
  }

  @override
  void didUpdateWidget(covariant SessionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldDev = oldWidget.device;
    final newDev = widget.device;
    if (oldDev.id == newDev.id &&
        (oldDev.baseUrl != newDev.baseUrl ||
            !mapEquals(oldDev.params, newDev.params))) {
      unawaited(_resetWarmupAfterLinkChange());
      _manualReload();
    }
  }

  Future<void> _resetWarmupAfterLinkChange() async {
    _warmupTimer?.cancel();
    await _warmupNotifier?.forget(widget.device.id);
    if (mounted) await _warmupNotifier?.load(widget.device.id);
  }

  void _scheduleWarmupReplay() {
    _warmupTimer?.cancel();
    _warmupTimer = Timer(const Duration(milliseconds: 1800), () async {
      if (!mounted || !_isTrustedDevice) return;
      await _warmupNotifier?.load(widget.device.id);
      final requests =
          ref.read(warmupMemoryProvider)[widget.device.id] ??
          const <WarmupRequest>[];
      final script = WarmupReplay.script(requests);
      if (script.isEmpty) return;
      try {
        await _controller?.evaluateJavascript(source: script);
      } catch (e, st) {
        debugPrint('[ZR] warmup replay failed: $e\n$st');
      }
    });
  }

  bool get _isTrustedDevice => LinkBuilder.isTrustedDevice(widget.device);

  void _report(SessionStatus status) =>
      _statusNotifier?.report(widget.device.id, status);

  void _onWsEvent(String body) {
    if (!mounted) return;
    try {
      final event = jsonDecode(body);
      if (event is Map<String, dynamic>) {
        final status = RelayLedPolicy.onWsEvent(event);
        if (status != null) _report(status);
      }
    } catch (_) {}
  }

  void _goHome() => ref
      .read(activeTabProvider.notifier)
      .set(RootTabs.tasks(ref.read(deviceListProvider).length));

  void _onBridgeMessage(String body) {
    if (!mounted) return;
    // 面板数据（模型/额度/子代理/技能等）与事件共用同一桥接流。
    _panelDataNotifier?.ingest(widget.device.id, body);
    dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      root = null;
    }
    final frameLed = RelayLedPolicy.onFrameRoot(root);
    if (frameLed != null) _report(frameLed);

    final activeSession = ActiveSessionExtractor.parseRoot(root);
    if (activeSession != null) {
      _activeSessionId = activeSession;
      _activeSessionNotifier?.report(widget.device.id, activeSession);
    }
    final states = SessionStateExtractor.parseRoot(root);
    final removed = [
      ...SessionStateExtractor.parseRemovedRoot(root),
      ...TaskIndexExtractor.parseRemovedRoot(root),
      ...TaskIndexExtractor.parseArchivedRoot(root),
    ];
    _sessionIndexNotifier?.upsertAll(widget.device.id, states);
    _sessionIndexNotifier?.removeSessions(widget.device.id, removed);
    final snapshotTasks = TaskIndexExtractor.parseSnapshotRoot(root);
    if (snapshotTasks != null) {
      _sessionIndexNotifier?.replaceTasks(widget.device.id, snapshotTasks);
    } else {
      final taskEntries = TaskIndexExtractor.parseRoot(root);
      _sessionIndexNotifier?.upsertTasks(widget.device.id, taskEntries);
    }
    final resultTasks = TaskIndexExtractor.parseResultTasksRoot(root);
    if (resultTasks != null && resultTasks.isNotEmpty) {
      if (TaskIndexExtractor.isBootstrapResult(root)) {
        _sessionIndexNotifier?.replaceTasks(
          widget.device.id,
          resultTasks,
          preservePinned: true,
        );
      } else {
        _sessionIndexNotifier?.upsertTasks(widget.device.id, resultTasks);
      }
    }

    final events = EventParser.dedupe([
      // Do not promote nested streaming/tool `completed` or `error` values to
      // notifications. StateDiffer is the terminal-state authority.
      ...EventParser.parseUserActionRoot(root),
      ..._stateDiffer.apply([
        ...states,
        ...TaskIndexExtractor.parseRoot(root),
      ], removed: removed),
    ]);
    if (events.isEmpty) return;
    final devices = ref.read(deviceListProvider);
    final active = ref.read(activeTabProvider);
    final visibleId = active < devices.length ? devices[active].id : null;
    final appForeground =
        ref.read(appLifecycleProvider) == AppLifecycleState.resumed;
    final prefs = ref.read(notificationPrefsProvider);
    for (final event in events) {
      if (event.type == 'resolved') {
        final taskId = event.taskId;
        if (taskId != null) {
          NotifierService.instance.cancelPending(widget.device, taskId);
        }
        _feedNotifier?.ingest(widget.device.id, event);
        continue;
      }
      if (!prefs.enabled(event.type)) continue;
      // The floating in-app notice and notification center should still see
      // events from the session that is currently open. Only the OS-level
      // duplicate is gated below.
      _feedNotifier?.ingest(widget.device.id, event);
      final notify = NotificationGate.shouldNotify(
        appForeground: appForeground,
        visibleDeviceId: visibleId,
        eventDeviceId: widget.device.id,
        activeSessionId: _activeSessionId,
        eventSessionId: event.taskId,
      );
      if (!notify) continue;
      unawaited(
        NotifierService.instance.notifyFrom(
          widget.device,
          event,
          l10n: AppLocalizations.of(context),
        ),
      );
    }
  }

  void _onViewStateSync(String body) {
    if (!mounted) return;
    final r = MobileViewStateSync.parse(body);
    if (!r.valid) return;
    _activeSessionId = r.taskId;
    _activeSessionNotifier?.report(widget.device.id, r.taskId);
  }

  /// 面板请求录制（预热重放的数据源）。
  void _onSeen(String body) {
    _warmupNotifier?.ingestSeen(widget.device.id, body);
  }

  URLRequest _freshRequest() =>
      URLRequest(url: WebUri(LinkBuilder.buildUrl(widget.device).toString()));

  Future<void> _manualReload() async {
    setState(() {
      _loading = true;
      _errorShown = false;
    });
    _report(SessionStatus.loading);
    await _controller?.loadUrl(urlRequest: _freshRequest());
  }

  Future<void> _onLoadError() async {
    final now = DateTime.now();
    if (now.difference(_lastAutoReload).inSeconds >= 30) {
      _lastAutoReload = now;
      _report(SessionStatus.loading);
      await _controller?.loadUrl(urlRequest: _freshRequest());
      return;
    }
    if (mounted) {
      setState(() => _errorShown = true);
      _report(SessionStatus.error);
    }
  }

  Future<void> _showSwitcher() async {
    final devices = ref.read(deviceListProvider);
    final l10n = AppLocalizations.of(context)!;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.zt.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: context.zt.hairline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 8),
              for (final d in devices)
                ListTile(
                  leading: _Led(status: ref.read(sessionStatusProvider)[d.id]),
                  title: Text(
                    d.displayName(l10n),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      UnreadBadge(feed: ref.read(eventFeedProvider)[d.id]),
                      if (d.id == widget.device.id) ...[
                        const SizedBox(width: 8),
                        Icon(Icons.check, color: context.zt.accent, size: 20),
                      ],
                    ],
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    final index = ref.read(deviceListProvider).indexOf(d);
                    ref.read(activeTabProvider.notifier).set(index);
                  },
                ),
              const Divider(indent: 16, endIndent: 16),
              ListTile(
                leading: Icon(Icons.tune, color: context.zt.textLo),
                title: Text(l10n.manageTitle),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _goHome();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showSessionPanel() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.zt.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: context.zt.hairline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: Consumer(
                  builder: (context, ref, _) {
                    final sessionsMap = ref.watch(
                      sessionIndexProvider,
                    )[widget.device.id];
                    final sorted =
                        (sessionsMap?.values.toList() ?? <SessionState>[])
                          ..sort(SessionRanking.compareSessions);
                    final activeId = ref.watch(
                      activeSessionProvider,
                    )[widget.device.id];
                    return SessionPanelSheet(
                      sessions: sorted,
                      activeSessionId: activeId,
                      onSessionTap: (sessionId) {
                        Navigator.pop(sheetContext);
                        _jumpToSession(sessionId);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _jumpToSession(String sessionId) async {
    final controller = _controller;
    if (controller == null) return;
    final workspace = ref
        .read(sessionIndexProvider)[widget.device.id]?[sessionId]
        ?.workspace;
    try {
      await controller.evaluateJavascript(
        source: SessionJump.jumpScript(sessionId, workspace: workspace),
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _warmupTimer?.cancel();
    _statusNotifier?.forget(widget.device.id);
    _feedNotifier?.forget(widget.device.id);
    _sessionIndexNotifier?.forget(widget.device.id);
    _activeSessionNotifier?.forget(widget.device.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(sessionStatusProvider)[widget.device.id];
    final l10n = AppLocalizations.of(context)!;

    // 消费跨页跳转：任务卡/通知卡指定了本设备的会话，切到 WebView 内定位。
    ref.listen(pendingSessionJumpProvider, (prev, next) {
      if (next == null || next.deviceId != widget.device.id) return;
      final sessionId = next.sessionId;
      ref.read(pendingSessionJumpProvider.notifier).clear();
      _jumpToSession(sessionId);
    });

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.tune),
          tooltip: l10n.manageTitle,
          onPressed: _goHome,
        ),
        title: Tooltip(
          message: l10n.switchDevice,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: _showSwitcher,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Led(status: status),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      widget.device.displayName(l10n),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    Icons.arrow_drop_down,
                    size: 22,
                    color: context.zt.textLo,
                  ),
                ],
              ),
            ),
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: _loading
              ? const LinearProgressIndicator(
                  minHeight: 2,
                  backgroundColor: Colors.transparent,
                )
              : const SizedBox(height: 2, width: double.infinity),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.article_outlined),
            tooltip: l10n.sessionsPanelTooltip,
            onPressed: _showSessionPanel,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n.refreshTooltip,
            onPressed: _manualReload,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_errorShown)
            Container(
              width: double.infinity,
              color: context.zt.danger.withValues(alpha: 0.10),
              padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 20,
                    color: context.zt.danger,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.statusError,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: context.zt.danger,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          l10n.errorBannerDetail,
                          style: TextStyle(
                            fontSize: 12,
                            color: context.zt.textLo,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.refresh,
                      color: context.zt.textLo,
                      size: 20,
                    ),
                    tooltip: l10n.retry,
                    onPressed: _manualReload,
                  ),
                ],
              ),
            ),
          Expanded(
            child: !_isTrustedDevice
                ? const _UntrustedOriginView()
                : InAppWebView(
                    initialUrlRequest: _freshRequest(),
                    initialUserScripts: UnmodifiableListView([
                      UserScript(
                        source: EventObserver.hookScript,
                        injectionTime:
                            UserScriptInjectionTime.AT_DOCUMENT_START,
                      ),
                    ]),
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      domStorageEnabled: true,
                      supportZoom: false,
                      useHybridComposition: false,
                      // Keep the widget in the IndexedStack, but let the OS lower
                      // priority/reclaim hidden Chromium renderers. The native
                      // relay remains the background data path.
                      rendererPriorityPolicy: RendererPriorityPolicy(
                        rendererRequestedPriority:
                            RendererPriority.RENDERER_PRIORITY_IMPORTANT,
                        // The native relay remains the data source for background
                        // devices; do not keep every hidden Chromium renderer at
                        // foreground priority.
                        waivedWhenNotVisible: false,
                      ),
                    ),
                    onWebViewCreated: (controller) {
                      _controller = controller;
                      controller.addJavaScriptHandler(
                        handlerName: 'zrEvents',
                        callback: (args) {
                          final body = args.isNotEmpty ? args.first : null;
                          if (body is String) _onBridgeMessage(body);
                          return null;
                        },
                      );
                      controller.addJavaScriptHandler(
                        handlerName: 'zrViewState',
                        callback: (args) {
                          final body = args.isNotEmpty ? args.first : null;
                          if (body is String) _onViewStateSync(body);
                          return null;
                        },
                      );
                      controller.addJavaScriptHandler(
                        handlerName: 'zrSeen',
                        callback: (args) {
                          final body = args.isNotEmpty ? args.first : null;
                          if (body is String) _onSeen(body);
                          return null;
                        },
                      );
                      controller.addJavaScriptHandler(
                        handlerName: 'zrWs',
                        callback: (args) {
                          final body = args.isNotEmpty ? args.first : null;
                          if (body is String) _onWsEvent(body);
                          return null;
                        },
                      );
                    },
                    onLoadStart: (_, _) {
                      if (mounted) {
                        setState(() {
                          _loading = true;
                          _errorShown = false;
                        });
                        _report(SessionStatus.loading);
                      }
                    },
                    onLoadStop: (_, _) {
                      if (mounted) {
                        setState(() => _loading = false);
                        _scheduleWarmupReplay();
                      }
                    },
                    shouldOverrideUrlLoading: (controller, action) async {
                      final raw = action.request.url?.toString();
                      final uri = raw == null ? null : Uri.tryParse(raw);
                      return LinkBuilder.isTrustedUri(uri)
                          ? NavigationActionPolicy.ALLOW
                          : NavigationActionPolicy.CANCEL;
                    },
                    onReceivedError: (controller, request, error) async {
                      if (!mounted) return;
                      if (!PageLoadPolicy.isMainDocFailure(
                        request.isForMainFrame,
                      )) {
                        return;
                      }
                      setState(() => _loading = false);
                      await _onLoadError();
                    },
                    onReceivedHttpError:
                        (controller, request, errorResponse) async {
                          if (!mounted) return;
                          if (!PageLoadPolicy.isHttpFailure(
                            request.isForMainFrame,
                            errorResponse.statusCode,
                          )) {
                            return;
                          }
                          setState(() => _loading = false);
                          await _onLoadError();
                        },
                  ),
          ),
        ],
      ),
    );
  }
}

class _Led extends StatelessWidget {
  const _Led({required this.status});

  final SessionStatus? status;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: context.zt.statusColor(status),
      ),
    );
  }
}

class _UntrustedOriginView extends StatelessWidget {
  const _UntrustedOriginView();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          l10n.untrustedOriginBlocked,
          textAlign: TextAlign.center,
          style: TextStyle(color: context.zt.textLo),
        ),
      ),
    );
  }
}

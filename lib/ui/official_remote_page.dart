import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter/services.dart';

import '../models/device.dart';
import '../services/link_builder.dart';
import '../services/session_jump.dart';
import '../services/event_observer.dart';
import '../services/warmup.dart';
import '../services/webview_sync.dart';
import '../state/root_tabs.dart';
import '../state/session_status.dart';
import '../state/theme_mode.dart';
import '../theme.dart';

/// Hosts the official ZCode remote page without recreating its visual layer.
///
/// The native app owns the trusted link lifecycle and the launcher. Once a
/// desktop link exists, every visible control, model selector, conversation,
/// setting and loading state still comes from the official `/remote/v4` page.
/// The page is also observed in-place so the launcher can keep a local cache
/// without opening a second WebView or a second remote connection.
class OfficialRemotePage extends ConsumerStatefulWidget {
  const OfficialRemotePage({super.key, required this.device});

  final RemoteDevice device;

  @override
  ConsumerState<OfficialRemotePage> createState() => _OfficialRemotePageState();
}

class _OfficialRemotePageState extends ConsumerState<OfficialRemotePage>
    with WidgetsBindingObserver {
  static const _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/152.0.7977.83 Safari/537.36';

  /// The official page owns the remote UI, including its connection state.
  /// Hide only the temporary handshake card so a slow sync is a quiet blank
  /// surface; the native error card below is still reserved for real failures.
  static const _hideHandshakeOverlayScript = r'''
(function () {
  if (window.__zcodeHandshakeMaskInstalled) return;
  window.__zcodeHandshakeMaskInstalled = true;

  function normalizedText(node) {
    return String(node.innerText || node.textContent || '')
      .replace(/\s+/g, ' ')
      .trim();
  }

  function isHandshake(text) {
    var lower = text.toLowerCase();
    var chinese = text.indexOf('正在加载工作区') >= 0 ||
      text.indexOf('同步桌面端工作区') >= 0 ||
      text.indexOf('等待桌面端配对') >= 0;
    var english = (lower.indexOf('loading workspace') >= 0 ||
      lower.indexOf('syncing workspace') >= 0 ||
      lower.indexOf('syncing desktop workspace') >= 0) &&
      (lower.indexOf('paired') >= 0 ||
       lower.indexOf('connection established') >= 0);
    var waiting = lower.indexOf('waiting for desktop pairing') >= 0 ||
      lower.indexOf('phone is ready') >= 0 ||
      (lower.indexOf('connect to relay service') >= 0 &&
       lower.indexOf('authenticate device') >= 0);
    return chinese || english || waiting;
  }

  function hide() {
    if (!document.body) return;
    var viewportWidth = window.innerWidth || document.documentElement.clientWidth;
    var viewportHeight = window.innerHeight || document.documentElement.clientHeight;
    var candidates = Array.prototype.slice.call(document.body.querySelectorAll('*'))
      .filter(function (node) {
        if (!(node instanceof HTMLElement)) return false;
        var text = normalizedText(node);
        if (!text || text.length > 800 || !isHandshake(text)) return false;
        var rect = node.getBoundingClientRect();
        var style = window.getComputedStyle(node);
        var isOverlay = style.position === 'fixed' || style.position === 'absolute';
        var isCard = rect.width >= Math.min(260, viewportWidth * 0.35) &&
          rect.height >= 100 &&
          rect.width < viewportWidth * 0.98 &&
          rect.height < viewportHeight * 0.90;
        return isOverlay || isCard;
      });
    if (!candidates.length) return;

    // Prefer the outermost card, not each individual line inside it.
    var roots = candidates.filter(function (node) {
      return !candidates.some(function (other) {
        return other !== node && other.contains(node);
      });
    });
    roots.forEach(function (node) {
      node.style.setProperty('display', 'none', 'important');
    });
  }

  hide();
  new MutationObserver(hide).observe(document.documentElement, {
    childList: true,
    subtree: true,
    characterData: true
  });
  window.setTimeout(hide, 0);
  window.setTimeout(hide, 250);
  window.setTimeout(hide, 1000);
})();
''';

  static String _themeSyncScript(bool dark) =>
      '''
(function () {
  var requestedDark = ${dark ? 'true' : 'false'};
  var requestedTheme = requestedDark ? 'dark' : 'light';
  // ZCode's renderer does not key its palette from a generic data-theme
  // attribute. It persists `zcode-theme` and derives these two theme classes
  // from the effective value. Mirror that contract so the WebView follows the
  // native app's light/dark decision instead of only changing form controls.
  var officialTheme = requestedDark ? 'zai-dark' : 'zai-light';
  // Keep the latest native decision in mutable state. The observer below can
  // outlive this injection, so it must not close over an older theme value.
  window.__zcodeControlThemeState = {
    theme: requestedTheme,
    dark: requestedDark,
    officialTheme: officialTheme
  };

  function applyTheme() {
    var state = window.__zcodeControlThemeState;
    var currentRoot = document.documentElement;
    if (!state || !currentRoot) return;

    var theme = state.theme;
    var dark = state.dark;
    var rendererTheme = state.officialTheme;

    // These are the selectors used by the official ZCode renderer.
    currentRoot.classList.toggle('dark', dark);
    currentRoot.classList.toggle('theme-zai-light', rendererTheme === 'zai-light');
    currentRoot.classList.toggle('theme-zai-dark', rendererTheme === 'zai-dark');
    if (currentRoot.getAttribute('data-zcode-browser-theme-surface') !== theme) {
      currentRoot.setAttribute('data-zcode-browser-theme-surface', theme);
    }
    // Keep generic selectors in sync for embedded controls/components that do
    // not use the renderer's utility classes.
    if (currentRoot.style.getPropertyValue('color-scheme') !== theme) {
      currentRoot.style.setProperty('color-scheme', theme);
    }
    if (currentRoot.getAttribute('data-theme') !== rendererTheme) {
      currentRoot.setAttribute('data-theme', rendererTheme);
    }
    if (document.body) {
      document.body.classList.toggle('dark', dark);
      document.body.classList.toggle('theme-zai-light', rendererTheme === 'zai-light');
      document.body.classList.toggle('theme-zai-dark', rendererTheme === 'zai-dark');
    }

    // Let Chromium form controls and any color-scheme-aware code follow the
    // same decision as the page surface. At document-start <head> can still
    // be absent; the mutation observer retries when it is created.
    var meta = document.querySelector('meta[name="color-scheme"]');
    if (!meta && document.head) {
      meta = document.createElement('meta');
      meta.name = 'color-scheme';
      document.head.appendChild(meta);
    }
    if (meta && meta.content !== theme) {
      meta.content = theme;
    }

    // The official bootstrap reads this key before React mounts. Persisting
    // the effective value here prevents its first render from flashing the
    // opposite palette. System mode is re-injected on platform brightness
    // changes by the native state owner.
    try {
      window.localStorage.setItem('zcode-theme', rendererTheme);
    } catch (e) {}

    var previous = window.__zcodeControlAppliedTheme;
    window.__zcodeControlAppliedTheme = rendererTheme;
    if (previous !== rendererTheme && typeof window.dispatchEvent === 'function') {
      window.dispatchEvent(new CustomEvent('zcode-control-theme-change', {
        detail: { theme: theme, dark: dark, officialTheme: rendererTheme }
      }));
    }
  }

  window.__zcodeControlTheme = requestedTheme;
  function install() {
    var root = document.documentElement;
    if (!root) {
      window.setTimeout(install, 0);
      return;
    }
    applyTheme();
    if (!window.__zcodeControlThemeObserver) {
      window.__zcodeControlThemeObserver = new MutationObserver(applyTheme);
      window.__zcodeControlThemeObserver.observe(root, {
        attributes: true,
        childList: true,
        subtree: true,
        characterData: true
      });
    }
  }
  install();
})();
''';

  InAppWebViewController? _controller;
  bool _failed = false;
  bool _loading = true;
  DateTime _lastAutoReload = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _warmupTimer;
  String? _pendingSessionId;
  WebViewSyncController? _sync;
  WarmupMemoryNotifier? _warmup;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    if (!mounted || ref.read(themeModeProvider) != kThemeSystem) return;
    final dark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
    unawaited(_applyWebTheme(dark));
  }

  URLRequest get _request =>
      URLRequest(url: WebUri(LinkBuilder.buildUrl(widget.device).toString()));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync ??= WebViewSyncController(device: widget.device, ref: ref);
    _warmup ??= ref.read(warmupMemoryProvider.notifier);
    unawaited(_warmup?.load(widget.device.id));
  }

  @override
  void didUpdateWidget(covariant OfficialRemotePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.device.id != widget.device.id ||
        oldWidget.device.baseUrl != widget.device.baseUrl ||
        oldWidget.device.params.toString() != widget.device.params.toString()) {
      _reload();
    }
  }

  Future<void> _reload() async {
    setState(() => _failed = false);
    ref
        .read(sessionStatusProvider.notifier)
        .report(widget.device.id, SessionStatus.loading);
    await _controller?.loadUrl(urlRequest: _request);
  }

  Future<void> _hideHandshakeOverlay() async {
    try {
      await _controller?.evaluateJavascript(
        source: _hideHandshakeOverlayScript,
      );
    } catch (_) {}
  }

  Future<void> _applyWebTheme(bool dark) async {
    try {
      await _controller?.evaluateJavascript(source: _themeSyncScript(dark));
    } catch (_) {}
  }

  bool _currentDark(BuildContext context) => themeModeIsDark(
    ref.read(themeModeProvider),
    MediaQuery.platformBrightnessOf(context),
  );

  Future<void> _onLoadError() async {
    final now = DateTime.now();
    if (now.difference(_lastAutoReload).inSeconds >= 30) {
      _lastAutoReload = now;
      ref
          .read(sessionStatusProvider.notifier)
          .report(widget.device.id, SessionStatus.loading);
      await _controller?.loadUrl(urlRequest: _request);
      return;
    }
    if (mounted) {
      setState(() {
        _loading = false;
        _failed = true;
      });
      ref
          .read(sessionStatusProvider.notifier)
          .report(widget.device.id, SessionStatus.error);
    }
  }

  void _scheduleWarmupReplay() {
    _warmupTimer?.cancel();
    _warmupTimer = Timer(const Duration(milliseconds: 1800), () async {
      if (!mounted || !LinkBuilder.isTrustedDevice(widget.device)) return;
      await _warmup?.load(widget.device.id);
      final requests =
          ref.read(warmupMemoryProvider)[widget.device.id] ??
          const <WarmupRequest>[];
      final script = WarmupReplay.script(requests);
      if (script.isEmpty) return;
      try {
        await _controller?.evaluateJavascript(source: script);
      } catch (_) {}
    });
  }

  void _jumpToSession(String sessionId) {
    final controller = _controller;
    if (controller == null || _loading) {
      _pendingSessionId = sessionId;
      return;
    }
    unawaited(
      controller.evaluateJavascript(source: SessionJump.jumpScript(sessionId)),
    );
  }

  void _applyPendingJump() {
    final sessionId = _pendingSessionId;
    if (sessionId == null || _loading) return;
    _pendingSessionId = null;
    // Let the official task list finish its first render before using its DOM
    // selectors. This does not reload the page or open another WebView.
    Future<void>.delayed(const Duration(milliseconds: 180), () {
      if (mounted) _jumpToSession(sessionId);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _warmupTimer?.cancel();
    _sync?.forget();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(themeModeProvider);
    final dark = themeModeIsDark(
      mode,
      MediaQuery.platformBrightnessOf(context),
    );
    ref.listen<String>(themeModeProvider, (_, _) {
      if (!mounted) return;
      unawaited(_applyWebTheme(_currentDark(context)));
    });
    ref.listen<PendingSessionJump?>(pendingSessionJumpProvider, (_, next) {
      if (next == null || next.deviceId != widget.device.id) return;
      ref.read(pendingSessionJumpProvider.notifier).clear();
      _jumpToSession(next.sessionId);
    });

    final trusted = LinkBuilder.isTrustedDevice(widget.device);
    final overlayStyle = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: context.zt.isDark
          ? Brightness.light
          : Brightness.dark,
      statusBarBrightness: context.zt.isDark
          ? Brightness.dark
          : Brightness.light,
      // Match the WebView's page background so the gesture/navigation area
      // does not become a bright strip below the desktop surface.
      systemNavigationBarColor: context.zt.bg,
      systemNavigationBarIconBrightness: context.zt.isDark
          ? Brightness.light
          : Brightness.dark,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarContrastEnforced: false,
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
        backgroundColor: context.zt.bg,
        body: SafeArea(
          // The desktop page should reach the lower edge. The system gesture
          // area uses the same color, so it no longer reads as an extra bar.
          top: true,
          bottom: false,
          child: !trusted
              ? _RemotePageError(
                  onRetry: null,
                  message: '此链接不是受信任的 ZCode 官方远控链接。',
                )
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    InAppWebView(
                      initialUrlRequest: _request,
                      initialUserScripts: UnmodifiableListView([
                        UserScript(
                          source: EventObserver.hookScript,
                          injectionTime:
                              UserScriptInjectionTime.AT_DOCUMENT_START,
                        ),
                        UserScript(
                          source: _themeSyncScript(dark),
                          injectionTime:
                              UserScriptInjectionTime.AT_DOCUMENT_START,
                        ),
                        UserScript(
                          source: _hideHandshakeOverlayScript,
                          injectionTime:
                              UserScriptInjectionTime.AT_DOCUMENT_START,
                        ),
                      ]),
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        domStorageEnabled: true,
                        cacheEnabled: true,
                        thirdPartyCookiesEnabled: true,
                        userAgent: _desktopUserAgent,
                        useWideViewPort: true,
                        supportZoom: false,
                        // Hybrid composition is required for reliable Android
                        // rendering of the desktop-sized remote surface. The
                        // virtual-display path can stay white on API 35 even
                        // while Chromium has loaded the document.
                        useHybridComposition: true,
                        mediaPlaybackRequiresUserGesture: false,
                        rendererPriorityPolicy: RendererPriorityPolicy(
                          rendererRequestedPriority:
                              RendererPriority.RENDERER_PRIORITY_IMPORTANT,
                          waivedWhenNotVisible: true,
                        ),
                      ),
                      onWebViewCreated: (controller) {
                        _controller = controller;
                        unawaited(_applyWebTheme(_currentDark(context)));
                        controller.addJavaScriptHandler(
                          handlerName: 'zrEvents',
                          callback: (args) {
                            final body = args.isNotEmpty ? args.first : null;
                            if (mounted && body is String) {
                              _sync?.ingestMessage(body, context);
                            }
                            return null;
                          },
                        );
                        controller.addJavaScriptHandler(
                          handlerName: 'zrViewState',
                          callback: (args) {
                            final body = args.isNotEmpty ? args.first : null;
                            if (body is String) _sync?.ingestViewState(body);
                            return null;
                          },
                        );
                        controller.addJavaScriptHandler(
                          handlerName: 'zrSeen',
                          callback: (args) {
                            final body = args.isNotEmpty ? args.first : null;
                            if (body is String) _sync?.ingestSeen(body);
                            return null;
                          },
                        );
                        controller.addJavaScriptHandler(
                          handlerName: 'zrWs',
                          callback: (args) {
                            final body = args.isNotEmpty ? args.first : null;
                            if (body is String) {
                              _sync?.ingestWebSocketEvent(body);
                            }
                            return null;
                          },
                        );
                      },
                      onLoadStart: (_, uri) {
                        debugPrint('[ZR][WebView] load start ${uri?.path}');
                        if (!mounted) return;
                        setState(() {
                          _loading = true;
                          _failed = false;
                        });
                        ref
                            .read(sessionStatusProvider.notifier)
                            .report(widget.device.id, SessionStatus.loading);
                        unawaited(_applyWebTheme(_currentDark(context)));
                      },
                      onLoadStop: (_, uri) {
                        debugPrint('[ZR][WebView] load stop ${uri?.path}');
                        if (!mounted) return;
                        setState(() {
                          _loading = false;
                          _failed = false;
                        });
                        unawaited(_hideHandshakeOverlay());
                        unawaited(_applyWebTheme(_currentDark(context)));
                        ref
                            .read(sessionStatusProvider.notifier)
                            .report(widget.device.id, SessionStatus.live);
                        _scheduleWarmupReplay();
                        _applyPendingJump();
                      },
                      shouldOverrideUrlLoading: (_, action) async {
                        final uri = action.request.url;
                        return LinkBuilder.isTrustedUri(uri)
                            ? NavigationActionPolicy.ALLOW
                            : NavigationActionPolicy.CANCEL;
                      },
                      onReceivedError: (_, request, error) {
                        if (request.isForMainFrame != true || !mounted) return;
                        debugPrint(
                          '[ZR][WebView] load error ${error.type}: '
                          '${error.description}',
                        );
                        unawaited(_onLoadError());
                      },
                      onReceivedHttpError: (_, request, response) {
                        if (request.isForMainFrame != true || !mounted) return;
                        if ((response.statusCode ?? 0) >= 400) {
                          debugPrint(
                            '[ZR][WebView] http error ${response.statusCode}',
                          );
                          unawaited(_onLoadError());
                        }
                      },
                      onConsoleMessage: (_, message) {
                        final text = message.message.trim();
                        if (text.isNotEmpty) {
                          debugPrint('[ZR][WebView] console $text');
                        }
                      },
                    ),
                    if (_failed)
                      Positioned.fill(
                        child: _RemotePageError(
                          onRetry: _reload,
                          message: '官方远程页面暂时无法打开。',
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _RemotePageError extends StatelessWidget {
  const _RemotePageError({required this.onRetry, required this.message});

  final VoidCallback? onRetry;
  final String message;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return ColoredBox(
      color: zt.bg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 28, color: zt.textLo),
            const SizedBox(height: 10),
            Text(message, style: TextStyle(color: zt.textLo, fontSize: 13)),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ],
        ),
      ),
    );
  }
}

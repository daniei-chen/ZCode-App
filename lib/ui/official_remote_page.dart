import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show kDebugMode, mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../services/in_page_back.dart';
import '../services/link_builder.dart';
import '../services/session_jump.dart';
import '../services/event_observer.dart';
import '../services/warmup.dart';
import '../services/webview_sync.dart';
import '../state/bridge_health.dart';
import '../state/observer_stats.dart';
import '../state/root_tabs.dart';
import '../state/session_index.dart';
import '../state/session_status.dart';
import '../state/theme_mode.dart';
import '../theme.dart';
import '../services/app_log.dart';
import '../services/bridge_schema.dart';
import '../services/bridge_token.dart';
import '../services/structured_log.dart';
import '../services/webview_storage.dart';

/// Bridge used by the app shell to give a mounted WebView the first chance
/// to handle Android back.  The WebView remains in the IndexedStack, so this
/// is intentionally a small imperative controller rather than a Navigator
/// route.
class OfficialRemotePageController {
  Future<bool> Function()? _backHandler;

  void attach(Future<bool> Function() handler) {
    _backHandler = handler;
  }

  void detach() {
    _backHandler = null;
  }

  Future<bool> handleBack() async {
    final handler = _backHandler;
    if (handler == null) return false;
    try {
      return await handler();
    } catch (error) {
      AppLog.failure(LogEvent.webviewBackFailed, error, fields: {
        LogField.reason: 'controller_exception',
      });
      return false;
    }
  }
}

/// Hosts the official ZCode remote page without recreating its visual layer.
///
/// The native app owns the trusted link lifecycle and the launcher. Once a
/// desktop link exists, every visible control, model selector, conversation,
/// setting and loading state still comes from the official `/remote/v4` page.
/// The page is also observed in-place so the launcher can keep a local cache
/// without opening a second WebView or a second remote connection.
class OfficialRemotePage extends ConsumerStatefulWidget {
  const OfficialRemotePage({
    super.key,
    required this.device,
    this.backController,
  });

  final RemoteDevice device;
  final OfficialRemotePageController? backController;

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
    var candidates = Array.prototype.slice.call(document.body.querySelectorAll('div,section,main,aside,form,dialog'))
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
    if (!candidates.length) return false;

    // Prefer the outermost card, not each individual line inside it.
    var roots = candidates.filter(function (node) {
      return !candidates.some(function (other) {
        return other !== node && other.contains(node);
      });
    });
    roots.forEach(function (node) {
      node.style.setProperty('display', 'none', 'important');
    });
    return roots.length > 0;
  }

  // 握手卡片的观察是**有界**的（F17）：命中即断开；最多观察 5 秒；
  // 去抖 150ms。页面进入流式输出后这里已经不再有任何 DOM 扫描。
  var deadline = Date.now() + 5000;
  var observer = null;
  var debounce = null;
  function stopWatching() {
    if (observer) {
      try { observer.disconnect(); } catch (e) {}
      observer = null;
    }
    if (debounce) {
      clearTimeout(debounce);
      debounce = null;
    }
  }
  function runHide() {
    if (observer === null) return;
    if (Date.now() > deadline) { stopWatching(); return; }
    if (hide()) stopWatching();
  }
  function schedule() {
    if (observer === null || debounce) return;
    debounce = window.setTimeout(function () {
      debounce = null;
      runHide();
    }, 150);
  }
  runHide();
  observer = new MutationObserver(schedule);
  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
    characterData: true
  });
  window.setTimeout(schedule, 0);
  window.setTimeout(schedule, 250);
  window.setTimeout(schedule, 1000);
  window.setTimeout(stopWatching, 5000);
})();
''';

  static String _themeSyncScript(bool dark) =>
      '''
(function () {
  var requestedDark = ${dark ? 'true' : 'false'};
  var requestedTheme = requestedDark ? 'dark' : 'light';
  // Native/app-driven changes are never reported back as if they were a
  // human click inside the WebView. The user-gesture observer below checks
  // this deadline before sending a theme change to Flutter.
  window.__zcodeControlThemeSuppressUntil = Date.now() + 800;
  // This injection is an app-owned decision. If it follows a manual choice
  // from the WebView, it must be allowed to win immediately; the gesture
  // window is only for the page's own DOM/storage mutations to settle.
  window.__zcodeControlUserThemeGestureUntil = 0;
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

    // A theme menu click in the official page changes its DOM and/or storage
    // asynchronously. Do not race that change by immediately painting the
    // old native theme back over it. The user observer below will report the
    // settled value to Flutter, which then reinjects this script with the new
    // app-owned decision.
    if (Date.now() <= (window.__zcodeControlUserThemeGestureUntil || 0)) {
      return;
    }

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
    // Reset the observer baseline for every native/app-driven update. Without
    // this, a later ordinary click could mistake the already-applied native
    // theme for a manual WebView change.
    window.__zcodeControlUserThemeLast = requestedTheme;

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
      // 主题只体现在 <html> 的属性/类名上：只观察 attributes（并限定了
      // 属性名），不再监听整棵子树的 childList/characterData（F17）。
      window.__zcodeControlThemeObserver.observe(root, {
        attributes: true,
        attributeFilter: ['class', 'data-theme', 'style']
      });
    }
  }
  install();

  // The official page remains the source of the WebView UI, but its manual
  // light/dark choice should also become the app-wide choice. Watch the
  // renderer's persisted value and classes only after a real pointer/touch
  // or keyboard gesture. This keeps page/bootstrap mutations and system
  // brightness changes from rewriting the native setting by themselves.
  if (!window.__zcodeControlUserThemeObserverInstalled) {
    window.__zcodeControlUserThemeObserverInstalled = true;
    window.__zcodeControlUserThemeGestureUntil = 0;

    function normalizeUserTheme(raw) {
      if (raw === null || raw === undefined) return null;
      var value = String(raw).toLowerCase().trim();
      if (value.indexOf('dark') >= 0) return 'dark';
      if (value.indexOf('light') >= 0) return 'light';
      if (value === 'system' || value === 'auto' ||
          value.indexOf('system') >= 0) return 'system';
      return null;
    }

    function currentUserTheme() {
      var root = document.documentElement;
      if (!root) return null;
      try {
        var stored = normalizeUserTheme(
          window.localStorage.getItem('zcode-theme')
        );
        if (stored) return stored;
      } catch (e) {}
      if (root.classList.contains('theme-zai-dark') ||
          root.classList.contains('dark')) return 'dark';
      if (root.classList.contains('theme-zai-light') ||
          root.classList.contains('light')) return 'light';
      return normalizeUserTheme(root.getAttribute('data-theme')) ||
        normalizeUserTheme(root.getAttribute('data-zcode-browser-theme-surface'));
    }

    window.__zcodeControlUserThemeLast =
      currentUserTheme() || window.__zcodeControlThemeState.theme;

    function notifyUserThemeIfChanged() {
      if (Date.now() > window.__zcodeControlUserThemeGestureUntil) return;
      if (Date.now() < (window.__zcodeControlThemeSuppressUntil || 0)) return;
      var theme = currentUserTheme();
      if (!theme || theme === window.__zcodeControlUserThemeLast) return;
      var bridge = window.flutter_inappwebview;
      if (!bridge || typeof bridge.callHandler !== 'function') return;
      window.__zcodeControlUserThemeLast = theme;
      try {
        bridge.callHandler('zrTheme', JSON.stringify({
          theme: theme,
          source: 'user'
        }));
      } catch (e) {}
    }

    function scheduleUserThemeCheck() {
      [0, 80, 260, 700, 1400].forEach(function (delay) {
        window.setTimeout(notifyUserThemeIfChanged, delay);
      });
    }

    function markUserThemeGesture() {
      window.__zcodeControlUserThemeGestureUntil = Date.now() + 2200;
      scheduleUserThemeCheck();
    }

    ['click', 'pointerup', 'touchend'].forEach(function (eventName) {
      document.addEventListener(eventName, markUserThemeGesture, true);
    });
    document.addEventListener('keydown', function (event) {
      if (event.key === 'Enter' || event.key === ' ' ||
          event.key === 'Spacebar') {
        markUserThemeGesture();
      }
    }, true);

    function installUserThemeObserver() {
      var root = document.documentElement;
      if (!root) {
        window.setTimeout(installUserThemeObserver, 0);
        return;
      }
      try {
        new MutationObserver(function () {
          if (Date.now() <= window.__zcodeControlUserThemeGestureUntil) {
            scheduleUserThemeCheck();
          }
        }).observe(root, {
          attributes: true,
          attributeFilter: ['class', 'data-theme',
            'data-zcode-browser-theme-surface'],
          subtree: true
        });
      } catch (e) {}
    }
    installUserThemeObserver();

    window.addEventListener('storage', function (event) {
      if (event.key === 'zcode-theme') scheduleUserThemeCheck();
    }, true);
  }
})();
''';

  /// 首帧空白探测：body 没有子元素，或既无可见文本也无任何媒体/框架根节点，
  /// 视为页面未绘制成功。
  static const String _blankProbeScript = '''
(() => {
  const body = document.body;
  if (!body || body.childElementCount === 0) return "empty";
  const text = (body.innerText || "").trim();
  if (text.length > 0) return "ok";
  if (body.querySelector("canvas,svg,img,video,iframe,app-root,#root,#app")) return "ok";
  return "empty";
})();
''';

  InAppWebViewController? _controller;
  bool _failed = false;
  bool _loading = true;
  // 黑屏守卫（用户上报：升级后首启 WebView 可能长时间黑屏，滑返回才恢复）。
  // 首次加载 20s 内没有 onLoadStop，或 stop 后页面持续空白，就静默 reload
  // 一次；只自动重试一次，之后交给错误卡与手动重试。
  bool _firstLoadSettled = false;
  bool _silentRetried = false;
  bool _firstPaintProbed = false;
  Timer? _firstLoadWatchdog;
  Timer? _warmupTimer;
  String? _pendingSessionId;
  // 跳转确认（F12）：页面内脚本的搜索预算 20s，这里留出余量做兜底看门狗，
  // 保证"点了通知没反应"至少会变成一条有原因的可解释结果。
  int _jumpAttempt = 0;
  int _reportedJumpAttempt = -1;
  Timer? _jumpWatchdog;
  String? _inFlightJumpTask;
  // 页内返回（用户上报回归）：每次返回一个尝试号，只接受这一代的回执。
  int _backAttempt = 0;
  Completer<InPageBackOutcome?>? _pendingBack;
  WebViewSyncController? _sync;
  WarmupMemoryNotifier? _warmup;
  // Renderer 恢复（v1.2.0）：Chromium 渲染进程被系统回收后，同一个 WebView
  // 无法自愈；重试时用新的 generation 重建整个 WebView。
  bool _rendererGone = false;
  int _webviewGeneration = 0;

  /// 主 frame 令牌（F03）：每个 WebView generation 一个，只在主 frame 注入。
  String _bridgeToken = '';

  /// 令牌是否已确认落地（read-back 一致才为 true）；诊断页可见。
  bool _bridgeTokenReady = false;

  void _rotateBridgeToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    _bridgeToken = base64Url.encode(bytes);
    _bridgeTokenReady = false;
    // 本方法会在 initState/didUpdateWidget 里被调用：那里**不能**改 provider
    // （Flutter 会抛 "Tried to modify a provider while the widget tree was
    // building"，真机/模拟器实测红屏）。延到帧后再上报。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(bridgeHealthProvider.notifier)
          .report(widget.device.id, _webviewGeneration, ready: false);
    });
  }

  /// 把令牌注入主 frame 并**确认落地**（evaluateJavascript 只在主 frame 执行）。
  ///
  /// 现场证据（Android 16 / WebView 151）：`onLoadStop` 时钩子可能还没执行完，
  /// 一次注入会打空 → 钩子按 fail-closed 规则把事件/遥测/返回回执全部排队，
  /// 用户看到的是"返回没反应、通知不来"。所以这里按退避重试直到读回同一个令牌。
  Future<bool> _injectBridgeToken({bool log = true}) async {
    final token = _bridgeToken;
    if (token.isEmpty) return false;
    for (var attempt = 0; BridgeTokenPolicy.shouldRetry(attempt); attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(BridgeTokenPolicy.delayFor(attempt));
      }
      if (!mounted || _bridgeToken != token) return false;
      try {
        final readBack = await _controller?.evaluateJavascript(
          source: BridgeTokenPolicy.injectScript(token),
        );
        if (BridgeTokenPolicy.isReady(readBack, token)) {
          _markBridgeTokenReady();
          return true;
        }
      } catch (_) {}
    }
    if (log) {
      await _logTokenMissing('inject_failed');
    }
    return false;
  }

  /// 令牌确认到位：更新诊断状态，并按 generation 只报一次成功日志。
  void _markBridgeTokenReady() {
    _bridgeTokenReady = true;
    ref
        .read(bridgeHealthProvider.notifier)
        .report(widget.device.id, _webviewGeneration, ready: true);
    AppLog.event(LogEvent.bridgeTokenReady, level: LogLevel.debug, fields: {
      LogField.device: widget.device.id,
      LogField.generation: _webviewGeneration,
    });
  }

  Future<void> _logTokenMissing(String reason) async {
    var hookReady = 'unknown';
    try {
      final value = await _controller?.evaluateJavascript(
        source: BridgeTokenPolicy.hookReadyScript,
      );
      hookReady = BridgeTokenPolicy.normalize(value) ?? 'unknown';
    } catch (_) {}
    _bridgeTokenReady = false;
    ref
        .read(bridgeHealthProvider.notifier)
        .report(widget.device.id, _webviewGeneration, ready: false);
    // release 可见：这条日志是"观测/返回为什么不动"的第一现场。
    AppLog.event(LogEvent.bridgeTokenMissing, level: LogLevel.warn, fields: {
      LogField.device: widget.device.id,
      LogField.generation: _webviewGeneration,
      LogField.reason: reason,
      LogField.route: hookReady,
    });
  }

  /// 在预算内等令牌到位（返回键/跳转这类需要桥的操作前调用）。
  Future<bool> _ensureBridgeToken({Duration budget = BridgeTokenPolicy.backBudget}) async {
    if (_bridgeTokenReady && _bridgeToken.isNotEmpty) return true;
    final deadline = DateTime.now().add(budget);
    final injected = await _injectBridgeToken();
    while (!injected || !_bridgeTokenReady) {
      if (!mounted || DateTime.now().isAfter(deadline)) return _bridgeTokenReady;
      if (_bridgeTokenReady && _bridgeToken.isNotEmpty) return true;
      await Future<void>.delayed(BridgeTokenPolicy.pollInterval);
      await _injectBridgeToken();
      if (_bridgeTokenReady) return true;
      if (DateTime.now().isAfter(deadline)) return _bridgeTokenReady;
    }
    return _bridgeTokenReady;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.backController?.attach(_handleBack);
    _rotateBridgeToken();
    _armFirstLoadWatchdog();
  }

  void _armFirstLoadWatchdog() {
    _firstLoadWatchdog?.cancel();
    _firstLoadWatchdog = Timer(const Duration(seconds: 20), () {
      if (!mounted || _firstLoadSettled || _failed) return;
      // 静默重载预算用尽仍没有 loadStop：给出明确的失败出口，
      // 而不是让用户对着空白页无限等待（F05/R01）。
      if (PageLoadPolicy.retryBudgetExhausted(
        silentRetried: _silentRetried,
        settled: _firstLoadSettled,
        failed: _failed,
      )) {
        _failFirstLoad('first load timeout (retry budget exhausted)');
        return;
      }
      unawaited(_silentReloadOnce('first load timeout'));
    });
  }

  /// 首载失败出口：进入错误卡（可重试 / 可回设备中心），并同步设备状态。
  void _failFirstLoad(String reason) {
    if (!mounted) return;
    AppLog.event(LogEvent.webviewFirstLoadFailed, level: LogLevel.warn, fields: {
      LogField.device: widget.device.id,
      LogField.generation: _webviewGeneration,
      LogField.reason: reason,
    });
    _firstLoadWatchdog?.cancel();
    setState(() {
      _failed = true;
      _loading = false;
    });
    ref
        .read(sessionStatusProvider.notifier)
        .report(widget.device.id, SessionStatus.error);
  }

  Future<void> _silentReloadOnce(String reason) async {
    if (_silentRetried || !mounted || _failed) return;
    _silentRetried = true;
    // release 可见：黑屏守卫触发是真实故障信号，需要在诊断页/日志可查。
    AppLog.event(LogEvent.webviewSilentReload, level: LogLevel.warn, fields: {
      LogField.device: widget.device.id,
      LogField.generation: _webviewGeneration,
      LogField.reason: reason,
    });
    _firstLoadSettled = false;
    _armFirstLoadWatchdog();
    await _controller?.reload();
  }

  /// onLoadStop 后复核首帧：Chromium 可能已 stop 但页面持续空白。静默刷新
  /// 一次，避免用户对着黑屏。
  Future<void> _verifyFirstPaint() async {
    if (_silentRetried || _failed || _firstPaintProbed) return;
    _firstPaintProbed = true;
    if (!await _probeBlank()) return;
    // SPA 可能仍在挂载：3 秒后复核，仍空白才刷新。
    await Future<void>.delayed(const Duration(seconds: 3));
    if (!mounted || _failed || !await _probeBlank()) return;
    await _silentReloadOnce('blank first frame');
  }

  Future<bool> _probeBlank() async {
    try {
      final result = await _controller?.evaluateJavascript(
        source: _blankProbeScript,
      );
      // 不同插件版本对字符串返回值的 JSON 编码不一致，统一剥引号比较。
      return result?.toString().replaceAll('"', '') == 'empty';
    } catch (_) {
      return false; // 探测失败不触发刷新，交给超时/错误路径。
    }
  }

  /// W1 defense-in-depth：高权限 bridge 回调在被信任前，Dart 侧再次确认
  /// 当前主文档仍位于官方远控页面——不能只依赖"能调用 handler 的页面
  /// 一定可信"（UserScript origin 限制之外的第二道防线）。
  ///
  /// PR04（F03）：同时校验主 frame 令牌。原生桥对象对子 frame 同样可见，
  /// URL 检查只能证明"顶层文档可信"，不能证明"这条消息来自主 frame"。
  Future<bool> _bridgeAllowed(List<dynamic> args) async {
    if (!BridgeAuthPolicy.tokenMatches(
      args.length > 1 ? args[1] : null,
      _bridgeToken,
    )) {
      return false;
    }
    try {
      final url = await _controller?.getUrl();
      return LinkBuilder.isTrustedRemotePage(url);
    } catch (_) {
      return false;
    }
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
    if (oldWidget.backController != widget.backController) {
      oldWidget.backController?.detach();
      widget.backController?.attach(_handleBack);
    }
    if (oldWidget.device.id != widget.device.id ||
        oldWidget.device.baseUrl != widget.device.baseUrl ||
        !mapEquals(oldWidget.device.params, widget.device.params)) {
      // 换链接 = 换凭证（F10）：旧页面的 JS 上下文、sync 基线（旧 device 对象、
      // StateDiffer、activeSessionId）与桥令牌都不能沿用，也不能只做 reload——
      // 用新 generation 重建 WebView，再让 warmup 记录在旧凭证下失效。
      // Warmup requests recorded under the old link must not replay against
      // the new credential.
      _warmup?.forget(widget.device.id);
      _sync?.forget();
      _sync = null;
      _invalidateInFlightJump();
      // 换凭证同时是本地存储的清理触发点（PR20/F19）：旧凭证下的 Cookie、
      // DOM storage 与缓存不能留给新凭证继续使用。
      unawaited(
        WebViewStorage.clearForCredentialChange(
          controller: _controller,
          deviceId: oldWidget.device.id,
        ),
      );
      ref.read(observerStatsProvider.notifier).forget(oldWidget.device.id);
      setState(() {
        _webviewGeneration++;
        _failed = false;
        _loading = true;
        _firstLoadSettled = false;
        _silentRetried = false;
        _firstPaintProbed = false;
      });
      _rotateBridgeToken();
      _armFirstLoadWatchdog();
    }
  }

  void _handleRendererGone(String detail) {
    AppLog.event(LogEvent.webviewRendererGone, level: LogLevel.warn, fields: {
      LogField.device: widget.device.id,
      LogField.generation: _webviewGeneration,
      LogField.reason: 'renderer_process_gone',
      LogField.error: detail,
    });
    if (!mounted) return;
    _invalidateInFlightJump();
    setState(() {
      _rendererGone = true;
      _failed = true;
      _loading = false;
    });
    // 渲染进程已死不是"连接中"：把设备状态同步为异常，避免画布显示假在线。
    ref
        .read(sessionStatusProvider.notifier)
        .report(widget.device.id, SessionStatus.error);
  }

  Future<void> _reload() async {
    _invalidateInFlightJump();
    if (_rendererGone && mounted) {
      // 渲染进程已死：原地 loadUrl 无法恢复，用新 generation 重建 WebView。
      AppLog.event(LogEvent.webviewRebuilt, level: LogLevel.warn, fields: {
        LogField.device: widget.device.id,
        LogField.generation: _webviewGeneration + 1,
        LogField.reason: 'renderer_death',
      });
      setState(() {
        _rendererGone = false;
        _webviewGeneration++;
        _failed = false;
        _loading = true;
        _firstLoadSettled = false;
        _silentRetried = false;
        _firstPaintProbed = false;
      });
      // 新 WebView = 新 JS 上下文：令牌必须同步轮换（旧令牌随旧文档一起失效）。
      _rotateBridgeToken();
      _armFirstLoadWatchdog();
      return;
    }
    if (_controller == null) {
      // No WebView (e.g. untrusted link): retrying cannot navigate anywhere,
      // so keep the error card instead of getting stuck on a blank spinner.
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
      // 手动重试 = 完整重开一轮：重置首载标志与重试预算，并重新计时（R03）。
      _firstLoadSettled = false;
      _silentRetried = false;
      _firstPaintProbed = false;
    });
    _armFirstLoadWatchdog();
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

  void _onWebThemeChange(Object? raw) {
    if (!mounted || raw is! String) return;
    try {
      final payload = jsonDecode(raw);
      if (payload is! Map || payload['source'] != 'user') return;
      final selected = payload['theme'];
      final mode = switch (selected) {
        'light' => kThemeLight,
        'dark' => kThemeDark,
        'system' => kThemeSystem,
        _ => null,
      };
      if (mode == null || ref.read(themeModeProvider) == mode) return;
      unawaited(ref.read(themeModeProvider.notifier).set(mode));
    } catch (_) {}
  }

  bool _currentDark(BuildContext context) => themeModeIsDark(
    ref.read(themeModeProvider),
    MediaQuery.platformBrightnessOf(context),
  );

  void _onLoadError() {
    if (!mounted || _failed) return;
    // Never reload on a document error. A reload would discard the WebView
    // input buffer and repeatedly interrupt a message being typed.
    setState(() {
      _loading = false;
      _failed = true;
    });
    ref
        .read(sessionStatusProvider.notifier)
        .report(widget.device.id, SessionStatus.error);
  }

  /// 系统返回键：先让官方页面自己处理"对话页 → 对话列表"这类页内路由，
  /// 页面确实没动（或没有返回控件）才交回 Dart 决定是否露出设备页。
  ///
  /// 手机与平板走同一条路径：平板只是布局不同（对话与列表同屏），
  /// 但官方页面自己的返回控件一样要能被系统返回键触发。
  Future<bool> _handleBack() async {
    if (!mounted) return false;
    final controller = _controller;
    if (controller == null) return false;

    // 令牌没到位时脚本会按 fail-closed 拒绝回执，返回键看起来"没反应"：
    // 先给它一个短预算把令牌确认下来（真机诊断包里的 WV109/unavailable 根因）。
    final bridgeReady = await _ensureBridgeToken();
    if (!mounted) return false;

    _backAttempt++;
    final attempt = _backAttempt;
    final completer = Completer<InPageBackOutcome?>();
    _pendingBack = completer;
    InPageBackOutcome? outcome;
    try {
      await controller.evaluateJavascript(source: InPageBack.script(attempt));
      outcome = await completer.future.timeout(
        InPageBack.dartTimeout,
        onTimeout: () => null,
      );
    } catch (error) {
      AppLog.failure(LogEvent.webviewBackFailed, error, fields: {
        LogField.reason: 'in_page_back_script',
        LogField.device: widget.device.id,
        LogField.generation: _webviewGeneration,
      });
    } finally {
      _pendingBack = null;
    }

    if (outcome?.ok == true) {
      AppLog.event(LogEvent.webviewBackHandled, level: LogLevel.debug, fields: {
        LogField.device: widget.device.id,
        LogField.generation: _webviewGeneration,
        LogField.reason: outcome!.reason,
        LogField.count: outcome.attemptId,
      });
      return true;
    }
    if (outcome == null) {
      // 页面没回执（脚本没跑起来/桥不可用）：留一条可见日志便于真机诊断，
      // 但仍继续走历史兜底。
      AppLog.event(LogEvent.webviewBackFailed, level: LogLevel.warn, fields: {
        LogField.device: widget.device.id,
        LogField.generation: _webviewGeneration,
        LogField.reason: InPageBackOutcome.reasonUnavailable,
        LogField.ok: bridgeReady,
      });
    }

    // 兜底：真实文档导航产生的历史条目（页内路由不会有）。
    try {
      if (await controller.canGoBack()) {
        await controller.goBack();
        return true;
      }
    } catch (error) {
      AppLog.failure(LogEvent.webviewBackFailed, error, fields: {
        LogField.reason: 'browser_back',
        LogField.device: widget.device.id,
      });
    }
    if (outcome != null && !outcome.ok) {
      AppLog.event(LogEvent.webviewBackFailed, level: LogLevel.warn, fields: {
        LogField.device: widget.device.id,
        LogField.generation: _webviewGeneration,
        LogField.reason: outcome.reason,
        LogField.count: outcome.attemptId,
      });
    }
    return false;
  }

  /// 页面内返回的回执（`zrBack`）：只接受当前这一代尝试的结果。
  void _onBackOutcome(InPageBackOutcome outcome) {
    if (outcome.attemptId != _backAttempt) return;
    final pending = _pendingBack;
    if (pending == null || pending.isCompleted) return;
    pending.complete(outcome);
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
    // Collapsed workspace groups expand only when the jump script knows the
    // workspace label; without it the probe never finds the target session.
    final workspace =
        ref.read(sessionIndexProvider)[widget.device.id]?[sessionId]?.workspace;
    _jumpAttempt++;
    final attempt = _jumpAttempt;
    _inFlightJumpTask = sessionId;
    _jumpWatchdog?.cancel();
    _jumpWatchdog = Timer(const Duration(seconds: 24), () {
      // 页面脚本没有回传（令牌缺失/主 frame 未跑）：本地兜底判定，
      // 让这次跳转也有一个可解释的结局。
      _onJumpOutcome(
        JumpOutcome(
          attemptId: attempt,
          ok: false,
          reason: JumpOutcome.reasonUndelivered,
          taskId: sessionId,
        ),
      );
    });
    unawaited(
      controller.evaluateJavascript(
        source: SessionJump.jumpScript(
          sessionId,
          workspace: workspace,
          attemptId: attempt,
        ),
      ),
    );
  }

  /// 页面回执（F12）：只有最新一代的结果算数，且每次尝试只报一次。
  void _onJumpOutcome(JumpOutcome outcome) {
    if (!mounted) return;
    if (outcome.attemptId != _jumpAttempt) return;
    _jumpWatchdog?.cancel();
    _inFlightJumpTask = null;
    if (_reportedJumpAttempt == outcome.attemptId) return;
    _reportedJumpAttempt = outcome.attemptId;
    if (outcome.ok) {
      AppLog.event(LogEvent.jumpSucceeded, level: LogLevel.debug, fields: {
        LogField.device: widget.device.id,
        LogField.generation: _webviewGeneration,
        LogField.count: outcome.attemptId,
        LogField.reason: 'found',
      });
      return;
    }
    AppLog.event(LogEvent.jumpFailed, level: LogLevel.warn, fields: {
      LogField.device: widget.device.id,
      LogField.generation: _webviewGeneration,
      LogField.count: outcome.attemptId,
      LogField.reason: outcome.reason,
    });
    _showJumpFailure(outcome);
  }

  void _showJumpFailure(JumpOutcome outcome) {
    final l10n = AppLocalizations.of(context);
    if (l10n == null) return;
    final message = switch (outcome.reason) {
      JumpOutcome.reasonTimeout => l10n.sessionJumpTimeout,
      JumpOutcome.reasonUndelivered => l10n.sessionJumpPageNotReady,
      JumpOutcome.reasonSuperseded => l10n.sessionJumpSuperseded,
      _ => l10n.sessionJumpNotFound,
    };
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
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

  /// JS 上下文被替换（重建/reload/凭证变更）时，在途的跳转尝试随旧文档一起
  /// 消失：取消看门狗、作废这一代尝试，并把它记为待跳转，在新页面 settle
  /// 后重放一次——既不误报"未找到"，也不静默丢弃用户的那次点击。
  void _invalidateInFlightJump() {
    _jumpWatchdog?.cancel();
    if (_inFlightJumpTask != null && _jumpAttempt > _reportedJumpAttempt) {
      _pendingSessionId ??= _inFlightJumpTask;
    }
    _inFlightJumpTask = null;
    _jumpAttempt++;
  }

  @override
  void dispose() {
    widget.backController?.detach();
    WidgetsBinding.instance.removeObserver(this);
    _warmupTimer?.cancel();
    _firstLoadWatchdog?.cancel();
    _jumpWatchdog?.cancel();
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
                  message: AppLocalizations.of(context)!.untrustedLinkMessage,
                )
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    InAppWebView(
                      key: ValueKey(
                        'zr-webview-${widget.device.id}-$_webviewGeneration',
                      ),
                      initialUrlRequest: _request,
                      initialUserScripts: UnmodifiableListView([
                        // 令牌引导（现场修复）：document-start 就把令牌放进主 frame，
                        // 钩子在同一个时刻安装时直接读它——不再依赖"load stop 后
                        // 用 evaluateJavascript 注入"，彻底消除真机上出现的
                        // BR200 竞态（钩子未就绪 → 事件/返回回执全被 fail-closed 拦住）。
                        // 必须排在钩子之前。
                        UserScript(
                          source: BridgeTokenPolicy.bootstrapScript(_bridgeToken),
                          injectionTime:
                              UserScriptInjectionTime.AT_DOCUMENT_START,
                          allowedOriginRules: {'https://zcode.z.ai'},
                        ),
                        UserScript(
                          source: EventObserver.hookScript,
                          injectionTime:
                              UserScriptInjectionTime.AT_DOCUMENT_START,
                          allowedOriginRules: {'https://zcode.z.ai'},
                        ),
                        UserScript(
                          source: _themeSyncScript(dark),
                          injectionTime:
                              UserScriptInjectionTime.AT_DOCUMENT_START,
                          allowedOriginRules: {'https://zcode.z.ai'},
                        ),
                        UserScript(
                          source: _hideHandshakeOverlayScript,
                          injectionTime:
                              UserScriptInjectionTime.AT_DOCUMENT_START,
                          allowedOriginRules: {'https://zcode.z.ai'},
                        ),
                      ]),
                      initialSettings: InAppWebViewSettings(
                        // 必须显式开启：插件默认 false 时 shouldOverrideUrlLoading
        // 回调根本不会触发，导航白名单会变成死代码（安全审计 S-1）。
                        useShouldOverrideUrlLoading: true,
                        javaScriptEnabled: true,
                        domStorageEnabled: true,
                        cacheEnabled: true,
                        // W3：没有证据表明需要第三方 Cookie，先最小化关闭；
                        // 真机全流程 smoke（导入/重连/切换/发送/刷新/前后台）
                        // 通过后永久保持 false，失败则记录依赖流程再评估。
                        thirdPartyCookiesEnabled: false,
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
                          // The official page owns the WebSocket that carries
                          // updates for every conversation. This WebView is
                          // deliberately kept mounted under the native
                          // launcher, so lowering Chromium priority whenever
                          // the launcher covers it would silently pause the
                          // only live event source and make background alerts
                          // appear unreliable.
                          waivedWhenNotVisible: false,
                        ),
                      ),
                      onWebViewCreated: (controller) {
                        _controller = controller;
                        unawaited(_applyWebTheme(_currentDark(context)));
                        controller.addJavaScriptHandler(
                          handlerName: 'zrTheme',
                          callback: (args) async {
                            if (!await _bridgeAllowed(args)) return null;
                            final body = BridgeSchema.acceptString(
                              args.isNotEmpty ? args.first : null,
                              maxBytes: BridgeSchema.maxThemeBytes,
                            );
                            if (body != null) _onWebThemeChange(body);
                            return null;
                          },
                        );
                        controller.addJavaScriptHandler(
                          handlerName: 'zrEvents',
                          callback: (args) async {
                            if (!await _bridgeAllowed(args)) return null;
                            if (!context.mounted) return null;
                            final body = BridgeSchema.acceptString(
                              args.isNotEmpty ? args.first : null,
                              maxBytes: BridgeSchema.maxEventBytes,
                            );
                            if (body != null) {
                              _sync?.ingestMessage(body, context);
                            }
                            return null;
                          },
                        );
                        controller.addJavaScriptHandler(
                          handlerName: 'zrViewState',
                          callback: (args) async {
                            if (!await _bridgeAllowed(args)) return null;
                            final body = BridgeSchema.acceptString(
                              args.isNotEmpty ? args.first : null,
                              maxBytes: BridgeSchema.maxViewStateBytes,
                            );
                            if (body != null) _sync?.ingestViewState(body);
                            return null;
                          },
                        );
                        controller.addJavaScriptHandler(
                          handlerName: 'zrSeen',
                          callback: (args) async {
                            if (!await _bridgeAllowed(args)) return null;
                            final body = BridgeSchema.acceptString(
                              args.isNotEmpty ? args.first : null,
                              maxBytes: BridgeSchema.maxSeenBytes,
                            );
                            if (body != null) _sync?.ingestSeen(body);
                            return null;
                          },
                        );
                        controller.addJavaScriptHandler(
                          handlerName: 'zrStats',
                          callback: (args) async {
                            if (!await _bridgeAllowed(args)) return null;
                            final body = args.isNotEmpty ? args.first : null;
                            if (body is! String) return null;
                            // 解析前先限长（F04）：遥测本身很小，超限直接丢弃，
                            // 绝不先 jsonDecode 一个未知大小的字符串。
                            if (body.length > BridgeSchema.maxStatsChars) {
                              BridgeSchema.droppedMessages++;
                              return null;
                            }
                            try {
                              final stats = BridgeSchema.acceptStats(
                                jsonDecode(body),
                              );
                              if (stats != null) {
                                // F18：遥测按 设备 + generation 存，两台设备
                                // 交错上报不会互相覆盖；旧 generation 的迟到
                                // 消息也不会把新页面的计数写回去。
                                ref
                                    .read(observerStatsProvider.notifier)
                                    .update(
                                      widget.device.id,
                                      _webviewGeneration,
                                      stats,
                                    );
                              }
                            } catch (_) {}
                            return null;
                          },
                        );
                        controller.addJavaScriptHandler(
                          handlerName: 'zrWs',
                          callback: (args) async {
                            if (!await _bridgeAllowed(args)) return null;
                            final body = BridgeSchema.acceptString(
                              args.isNotEmpty ? args.first : null,
                              maxBytes: BridgeSchema.maxWsEventBytes,
                            );
                            if (body != null) {
                              _sync?.ingestWebSocketEvent(body);
                            }
                            return null;
                          },
                        );
                        // 页内返回回执（用户上报回归）：脚本点了什么、页面到底
                        // 有没有换，都从这里回到 Dart。
                        controller.addJavaScriptHandler(
                          handlerName: 'zrBack',
                          callback: (args) async {
                            if (!await _bridgeAllowed(args)) return null;
                            final body = BridgeSchema.acceptString(
                              args.isNotEmpty ? args.first : null,
                              maxBytes: BridgeSchema.maxBackBytes,
                            );
                            if (body == null) return null;
                            final outcome = InPageBackOutcome.parse(body);
                            if (outcome == null) {
                              BridgeSchema.droppedMessages++;
                              return null;
                            }
                            _onBackOutcome(outcome);
                            return null;
                          },
                        );
                        // 跳转回执（F12）：脚本在页面内点了什么、有没有点到、
                        // 为什么没点到，都从这里回到 Dart。
                        controller.addJavaScriptHandler(
                          handlerName: 'zrJump',
                          callback: (args) async {
                            if (!await _bridgeAllowed(args)) return null;
                            final body = BridgeSchema.acceptString(
                              args.isNotEmpty ? args.first : null,
                              maxBytes: BridgeSchema.maxJumpBytes,
                            );
                            if (body == null) return null;
                            final outcome = JumpOutcome.parse(body);
                            if (outcome == null) {
                              BridgeSchema.droppedMessages++;
                              return null;
                            }
                            _onJumpOutcome(outcome);
                            return null;
                          },
                        );
                      },
                      onLoadStart: (_, uri) {
                        AppLog.event(LogEvent.webviewLoadStart, level: LogLevel.debug, fields: {
                          LogField.device: widget.device.id,
                          LogField.generation: _webviewGeneration,
                          LogField.route: uri?.toString(),
                        });
                        if (!mounted) return;
                        setState(() {
                          _loading = true;
                          _failed = false;
                        });
                        ref
                            .read(sessionStatusProvider.notifier)
                            .report(widget.device.id, SessionStatus.loading);
                        unawaited(_injectBridgeToken());
                        unawaited(_applyWebTheme(_currentDark(context)));
                      },
                      onLoadStop: (_, uri) {
                        AppLog.event(LogEvent.webviewLoadStop, level: LogLevel.debug, fields: {
                          LogField.device: widget.device.id,
                          LogField.generation: _webviewGeneration,
                          LogField.route: uri?.toString(),
                        });
                        if (!mounted) return;
                        // Android fires onLoadStop even when the main document
                        // failed (the error page still "finishes"). Only
                        // onLoadStart resets _failed, so the retry card stays.
                        setState(() {
                          _loading = false;
                        });
                        _firstLoadSettled = true;
                        _firstLoadWatchdog?.cancel();
                        unawaited(_hideHandshakeOverlay());
                        unawaited(_injectBridgeToken());
                        unawaited(_applyWebTheme(_currentDark(context)));
                        if (!_failed) {
                          // 文档加载完成 ≠ 远控可用（F06）：桌面离线、凭证失效
                          // 时页面照样 loadStop。这里先记"连接中"，只有 relay
                          // 证据（RelayLedPolicy：data 帧 / 终态错误）才改判。
                          ref
                              .read(sessionStatusProvider.notifier)
                              .report(widget.device.id, SessionStatus.loading);
                          _scheduleWarmupReplay();
                          _applyPendingJump();
                          unawaited(_verifyFirstPaint());
                        }
                      },
                      shouldOverrideUrlLoading: (_, action) async {
                        final uri = action.request.url;
                        final isMainFrame = action.isForMainFrame;
                        if (!isMainFrame) {
                          // 子 frame 只需官方 origin，不要求远控路径。
                          return LinkBuilder.isTrustedOrigin(uri)
                              ? NavigationActionPolicy.ALLOW
                              : NavigationActionPolicy.CANCEL;
                        }
                        // W1：只有官方远控页面可以留在高权限容器里；官方站
                        // 其他页面与外站一律拦截。只记录 path，不记录
                        // query/fragment（凭证都在 query 里）。
                        final trusted = LinkBuilder.isTrustedRemotePage(uri);
                        if (!trusted) {
                          // release 可见（AppLog.warn）：真机 smoke 需要靠这条
                          // 日志发现被误拦的合法导航，再把路由加进策略。
                          // 只记 scheme/host/path——凭证都在 query 里。
                          AppLog.event(LogEvent.webviewNavBlocked, level: LogLevel.warn, fields: {
                            LogField.device: widget.device.id,
                            LogField.generation: _webviewGeneration,
                            LogField.route: uri?.toString(),
                          });
                        }
                        return trusted
                            ? NavigationActionPolicy.ALLOW
                            : NavigationActionPolicy.CANCEL;
                      },
                      onReceivedError: (_, request, error) {
                        if (request.isForMainFrame != true || !mounted) return;
                        AppLog.event(LogEvent.webviewLoadError, level: LogLevel.debug, fields: {
                          LogField.device: widget.device.id,
                          LogField.generation: _webviewGeneration,
                          LogField.reason: error.type.toString(),
                          LogField.error: error.description,
                        });
                        _onLoadError();
                      },
                      onReceivedHttpError: (_, request, response) {
                        if (request.isForMainFrame != true || !mounted) return;
                        if ((response.statusCode ?? 0) >= 400) {
                          AppLog.event(LogEvent.webviewLoadError, level: LogLevel.debug, fields: {
                            LogField.device: widget.device.id,
                            LogField.generation: _webviewGeneration,
                            LogField.reason: 'http_error',
                            LogField.count: response.statusCode,
                          });
                          _onLoadError();
                        }
                      },
                      onConsoleMessage: (_, message) {
                        final text = message.message.trim();
                        // release 构建不把页面 console 透传到 logcat（可能
                        // 带会话内容片段）。
                        if (kDebugMode && text.isNotEmpty) {
                          AppLog.event(LogEvent.webviewConsoleDropped, level: LogLevel.debug, fields: {
                            LogField.device: widget.device.id,
                            LogField.generation: _webviewGeneration,
                            LogField.error: text,
                          });
                        }
                      },
                      // v1.2.0 renderer 恢复：进程被系统回收后进入错误卡，
                      // 重试走 generation 重建；无响应是"黑屏卡死"信号，
                      // release 可见以便真机诊断。
                      onRenderProcessGone: (_, detail) {
                        _handleRendererGone(detail.toString());
                      },
                      onRenderProcessUnresponsive: (_, uri) async {
                        AppLog.event(LogEvent.webviewRendererUnresponsive, level: LogLevel.warn, fields: {
                          LogField.device: widget.device.id,
                          LogField.generation: _webviewGeneration,
                          LogField.route: uri?.toString(),
                        });
                        return null;
                      },
                      onRenderProcessResponsive: (_, uri) async => null,
                    ),
                    if (_failed)
                      Positioned.fill(
                        child: _RemotePageError(
                          onRetry: _reload,
                          message: AppLocalizations.of(context)!.remotePageErrorTitle,
                          retryLabel: AppLocalizations.of(context)!.retry,
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
  const _RemotePageError({
    required this.onRetry,
    required this.message,
    this.retryLabel,
  });

  final VoidCallback? onRetry;
  final String message;
  final String? retryLabel;

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
              OutlinedButton(onPressed: onRetry, child: Text(retryLabel ?? '重试')),
            ],
          ],
        ),
      ),
    );
  }
}

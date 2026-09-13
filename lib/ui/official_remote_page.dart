import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode, mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../services/link_builder.dart';
import '../services/session_jump.dart';
import '../services/event_observer.dart';
import '../services/warmup.dart';
import '../services/webview_sync.dart';
import '../state/observer_stats.dart';
import '../state/root_tabs.dart';
import '../state/session_index.dart';
import '../state/session_status.dart';
import '../state/theme_mode.dart';
import '../theme.dart';
import '../services/app_log.dart';
import '../services/bridge_schema.dart';

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
    } catch (error, stackTrace) {
      AppLog.warn('[ZR][WebView] back handling failed: $error\n$stackTrace');
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

  /// ZCode's mobile conversation view is an in-page route.  Prefer its own
  /// back control/history so the first Android back returns to the mobile
  /// workspace/task overview instead of exposing the device launcher.
  static const _mobileBackScript = r'''
(function () {
  function visible(node) {
    if (!node || !(node instanceof HTMLElement)) return false;
    var rect = node.getBoundingClientRect();
    var style = window.getComputedStyle(node);
    return style.display !== 'none' && style.visibility !== 'hidden' &&
      style.pointerEvents !== 'none' && rect.width > 0 && rect.height > 0 &&
      rect.bottom > 0 && rect.top < Math.max(220, window.innerHeight * 0.30);
  }

  function isBackLabel(value) {
    var text = String(value || '').trim();
    // Substring matching against long message text would tap wrong elements;
    // only short, label-like text qualifies.
    if (text.length > 24) return false;
    return /^(返回|返回上一级|back|go back)$/i.test(text) ||
      /(^|[\s_-])(back|go-back)([\s_-]|$)/i.test(text);
  }

  function isBackToTop(value) {
    var text = String(value || '').toLowerCase();
    return text.indexOf('返回顶部') !== -1 ||
      text.indexOf('back to top') !== -1;
  }

  var selectors = [
    '[aria-label*="返回"]',
    '[aria-label*="Back"]',
    '[title*="返回"]',
    '[title*="Back"]',
    '[data-testid*="back"]',
    '[data-testid*="Back"]',
    '[data-test*="back"]',
    '[data-test*="Back"]'
  ];
  // 会话页内的官方返回控件有稳定命名：优先点它回到对话列表，
  // 而不是一路退出到设备启动器。
  var backSel = [
    'button[aria-label="返回任务首页"]',
    'button[aria-label="Back to task home"]',
    'button[aria-label="返回会话列表"]',
    'button[aria-label^="Back to"]'
  ];
  for (var b = 0; b < backSel.length; b++) {
    var els = document.querySelectorAll(backSel[b]);
    for (var k = 0; k < els.length; k++) {
      if (isBackToTop(els[k].getAttribute('aria-label'))) continue;
      if (!visible(els[k])) continue;
      els[k].click();
      return true;
    }
  }
  var candidates = [];
  selectors.forEach(function (selector) {
    try {
      document.querySelectorAll(selector).forEach(function (node) {
        if (isBackToTop(node.getAttribute('aria-label')) ||
            isBackToTop(node.getAttribute('title')) ||
            isBackToTop(node.textContent)) {
          return;
        }
        if (candidates.indexOf(node) < 0) candidates.push(node);
      });
    } catch (e) {}
  });
  document.querySelectorAll('button, [role="button"], a').forEach(function (node) {
    if (isBackToTop(node.getAttribute('aria-label')) ||
        isBackToTop(node.textContent)) {
      return;
    }
    if (isBackLabel(node.getAttribute('aria-label')) ||
        isBackLabel(node.getAttribute('title')) ||
        isBackLabel(node.textContent)) {
      if (candidates.indexOf(node) < 0) candidates.push(node);
    }
  });

  for (var i = 0; i < candidates.length; i++) {
    if (!visible(candidates[i])) continue;
    candidates[i].click();
    return true;
  }

  if (window.history && window.history.length > 1) {
    // history.length also counts forward entries, so back() here can be a
    // silent no-op that would swallow the back key forever. Report back and
    // let the Dart side decide via canGoBack().
    return 'history';
  }
  return false;
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
      window.__zcodeControlThemeObserver.observe(root, {
        attributes: true,
        childList: true,
        subtree: true,
        characterData: true
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
  WebViewSyncController? _sync;
  WarmupMemoryNotifier? _warmup;
  // Renderer 恢复（v1.2.0）：Chromium 渲染进程被系统回收后，同一个 WebView
  // 无法自愈；重试时用新的 generation 重建整个 WebView。
  bool _rendererGone = false;
  int _webviewGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.backController?.attach(_handleBack);
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
    AppLog.warn('[ZR][WebView] first load failed: $reason');
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
    AppLog.warn('[ZR][WebView] silent reload: $reason');
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
  Future<bool> _bridgeAllowed() async {
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
      // Warmup requests recorded under the old link must not replay against
      // the new credential.
      _warmup?.forget(widget.device.id);
      _reload();
    }
  }

  void _handleRendererGone(String detail) {
    AppLog.warn('[ZR][WebView] renderer gone: $detail');
    if (!mounted) return;
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
    if (_rendererGone && mounted) {
      // 渲染进程已死：原地 loadUrl 无法恢复，用新 generation 重建 WebView。
      AppLog.warn('[ZR][WebView] rebuilding webview after renderer death');
      setState(() {
        _rendererGone = false;
        _webviewGeneration++;
        _failed = false;
        _loading = true;
        _firstLoadSettled = false;
        _silentRetried = false;
        _firstPaintProbed = false;
      });
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

  bool get _isPhone => MediaQuery.sizeOf(context).shortestSide < 600;

  Future<bool> _handleBack() async {
    if (!mounted || !_isPhone) return false;
    final controller = _controller;
    if (controller == null) return false;

    // The official page may keep the conversation transition inside its SPA;
    // let its visible back control or history handle that first.
    try {
      final result = await controller.evaluateJavascript(
        source: _mobileBackScript,
      );
      // Only a tapped in-page back control counts as handled. 'history' (and
      // anything else) falls through to the canGoBack() check below, which
      // knows whether a real back entry exists.
      if (result == true) return true;
    } catch (error, stackTrace) {
      AppLog.warn(
        '[ZR][WebView] mobile back script failed: $error\n$stackTrace',
      );
    }

    // Fallback for navigations Chromium exposes even if JavaScript returned
    // no value (for example, a redirect-created history entry).
    try {
      if (await controller.canGoBack()) {
        await controller.goBack();
        return true;
      }
    } catch (error, stackTrace) {
      AppLog.warn('[ZR][WebView] browser back failed: $error\n$stackTrace');
    }
    return false;
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
    unawaited(
      controller.evaluateJavascript(
        source: SessionJump.jumpScript(sessionId, workspace: workspace),
      ),
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
    widget.backController?.detach();
    WidgetsBinding.instance.removeObserver(this);
    _warmupTimer?.cancel();
    _firstLoadWatchdog?.cancel();
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
                            if (!await _bridgeAllowed()) return null;
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
                            if (!await _bridgeAllowed()) return null;
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
                            if (!await _bridgeAllowed()) return null;
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
                            if (!await _bridgeAllowed()) return null;
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
                            if (!await _bridgeAllowed()) return null;
                            final body = args.isNotEmpty ? args.first : null;
                            if (body is! String) return null;
                            try {
                              final stats = BridgeSchema.acceptStats(
                                jsonDecode(body),
                              );
                              if (stats != null) {
                                ref
                                    .read(observerStatsProvider.notifier)
                                    .update(stats);
                                AppLog.debug('[ZR][Observer] stats $body');
                              }
                            } catch (_) {}
                            return null;
                          },
                        );
                        controller.addJavaScriptHandler(
                          handlerName: 'zrWs',
                          callback: (args) async {
                            if (!await _bridgeAllowed()) return null;
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
                      },
                      onLoadStart: (_, uri) {
                        AppLog.debug('[ZR][WebView] load start ${uri?.path}');
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
                        AppLog.debug('[ZR][WebView] load stop ${uri?.path}');
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
                          AppLog.warn(
                            '[ZR][WebView] nav blocked '
                            '${uri?.scheme}://${uri?.host}${uri?.path}',
                          );
                        }
                        return trusted
                            ? NavigationActionPolicy.ALLOW
                            : NavigationActionPolicy.CANCEL;
                      },
                      onReceivedError: (_, request, error) {
                        if (request.isForMainFrame != true || !mounted) return;
                        AppLog.debug(
                          '[ZR][WebView] load error ${error.type}: '
                          '${error.description}',
                        );
                        _onLoadError();
                      },
                      onReceivedHttpError: (_, request, response) {
                        if (request.isForMainFrame != true || !mounted) return;
                        if ((response.statusCode ?? 0) >= 400) {
                          AppLog.debug(
                            '[ZR][WebView] http error ${response.statusCode}',
                          );
                          _onLoadError();
                        }
                      },
                      onConsoleMessage: (_, message) {
                        final text = message.message.trim();
                        // release 构建不把页面 console 透传到 logcat（可能
                        // 带会话内容片段）。
                        if (kDebugMode && text.isNotEmpty) {
                          AppLog.debug('[ZR][WebView] console $text');
                        }
                      },
                      // v1.2.0 renderer 恢复：进程被系统回收后进入错误卡，
                      // 重试走 generation 重建；无响应是"黑屏卡死"信号，
                      // release 可见以便真机诊断。
                      onRenderProcessGone: (_, detail) {
                        _handleRendererGone(detail.toString());
                      },
                      onRenderProcessUnresponsive: (_, uri) async {
                        AppLog.warn(
                          '[ZR][WebView] renderer unresponsive ${uri?.path}',
                        );
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

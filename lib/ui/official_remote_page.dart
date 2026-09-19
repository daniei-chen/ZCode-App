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
import '../services/page_refresh_policy.dart';
import '../services/session_jump.dart';
import '../services/event_observer.dart';
import '../services/warmup.dart';
import '../services/webview_sync.dart';
import '../state/bridge_health.dart';
import '../state/observer_stats.dart';
import '../state/pending_session_jump.dart';
import '../state/session_index.dart';
import '../state/session_pool.dart';
import '../state/session_status.dart';
import '../state/subframe_stats.dart';
import '../state/theme_mode.dart';
import '../theme.dart';
import '../services/app_log.dart';
import '../services/bridge_schema.dart';
import '../services/bridge_token.dart';
import '../services/structured_log.dart';
import '../services/webview_storage.dart';

/// 盖板是否应该盖住官方页（纯函数，便于单测锁定真机上复现过的状态机）。
///
/// 输入来自 `_workspaceReadyProbeScript` 探针：
/// * [rows] 任务列表行数；[composer] 输入区是否挂上；
/// * [handshake] 是否处于"配对中/加载工作区/英文中转连接"过渡态；
/// * [loadingRow] 左栏是否挂着"加载中..."占位行；
/// * [takeover] 页面是否已进入"被顶号"终态；
/// * [blank] 页面是否空白。
///
/// 规则：只有"页面已有真实内容（任务行或输入区）**且**不在任何过渡态"
/// 才揭盖；被顶号是终态信息，永远揭盖让用户读到原因。
///
/// 真机教训（v1.0.0+21 及之前）：旧规则 `(handshake && !hasContent) || blank`
/// 里 `hasContent` 只看"有任务行或输入区"，而官方页在列表数据回来之前就
/// 先挂输入区——盖板提前揭开，用户看到左栏"加载中..."的半成品页面。
bool shouldCoverOfficialPage({
  required int rows,
  required bool composer,
  required bool handshake,
  required bool loadingRow,
  required bool takeover,
  required bool blank,
}) {
  if (takeover) return false;
  final ready = (rows > 0 || composer) && !handshake && !loadingRow;
  return !ready || blank;
}

/// Bridge used by the app shell to give a mounted WebView the first chance
/// to handle Android back.  The WebView remains in the IndexedStack, so this
/// is intentionally a small imperative controller rather than a Navigator
/// route.
class OfficialRemotePageController {
  Future<bool> Function()? _backHandler;
  Future<bool> Function()? _layoutProbe;
  void Function(bool covered)? _coverObserver;
  bool _covered = false;

  void attach(Future<bool> Function() handler) {
    _backHandler = handler;
  }

  /// 由页面挂上"当前是否为对话+列表同屏布局"的探测（设置返回的落地决策
  /// 按页面**实际布局**判断，不再靠屏幕尺寸猜——真机两次误判的最终修正）。
  void attachLayoutProbe(Future<bool> Function() probe) {
    _layoutProbe = probe;
  }

  /// 由页面挂上"遮盖状态变化"回调（重新可见且过期时静默刷新，见
  /// `PageRefreshPolicy`）。只在**变化**时回调：外壳 build 里的幂等
  /// `setCovered(同值)` 不触发。
  void attachCoverObserver(void Function(bool covered) observer) {
    _coverObserver = observer;
  }

  /// 外壳告知当前是否被设备页/启动器遮盖（主题变更的整页重载据此选择时机；
  /// 页面据此记录"不可见起点"）。
  void setCovered(bool covered) {
    if (_covered == covered) return;
    _covered = covered;
    _coverObserver?.call(covered);
  }

  bool get covered => _covered;

  void detach() {
    _backHandler = null;
    _layoutProbe = null;
    _coverObserver = null;
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

  /// 返回 null 表示无法探测（页面未就绪/脚本失败），调用方回退到尺寸启发。
  Future<bool?> probeCombinedLayout() async {
    final probe = _layoutProbe;
    if (probe == null) return null;
    try {
      return await probe();
    } catch (_) {
      return null;
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

  // 隐藏由**长生命周期扫描**驱动（用户真机多轮反馈的最终形态）：
  //   1. 1 秒节拍、30 分钟上限——卡片在任意时刻出现（冷启动、切换会话、
  //      重连）都会被冷处理；旧实现用 60s deadline + 观察器，到点即死，
  //      之后出现的卡片没人处理（本地注入实验实锤：卡片存活）。
  //   2. 文本节点级定位（TreeWalker）替代逐元素 innerText——整页扫描在
  //      流式输出期也只有 O(text nodes) 的字符串比较，且限制在 4000 个
  //      文本节点内（F17 有界预算）。
  //   3. 卡片判定要求命中 **≥2 个不同关键词**（卡片自身文本包含"加载工作区
  //      +同步桌面端工作区+等待桌面端配对"多个），避免聊天正文里引用单个
  //      词时误伤消息气泡。
  var KEYS = ['加载工作区', '配对工作区', '同步桌面端工作区', '等待桌面端配对',
    '同步工作区', '连接中转服务', '设备鉴权'];
  var EN_KEYS = ['loading workspace', 'syncing workspace', 'pairing workspace',
    'syncing desktop workspace', 'waiting for desktop pairing'];

  function markerCount(text) {
    if (!text) return 0;
    var n = 0;
    for (var i = 0; i < KEYS.length; i++) {
      if (text.indexOf(KEYS[i]) >= 0) n++;
    }
    var lower = text.toLowerCase();
    for (var j = 0; j < EN_KEYS.length; j++) {
      if (lower.indexOf(EN_KEYS[j]) >= 0) n++;
    }
    return n;
  }

  function hideFromElement(startEl) {
    var el = startEl;
    var vw = window.innerWidth || document.documentElement.clientWidth;
    for (var i = 0; i < 8 && el && el !== document.documentElement; i++) {
      if (!(el instanceof HTMLElement)) break;
      try {
        var style = window.getComputedStyle(el);
        if (style.display === 'none') return false;
        if (markerCount(String(el.textContent || '').slice(0, 800)) >= 2) {
          var rect = el.getBoundingClientRect();
          if (rect.height >= 60 && rect.width >= Math.min(200, vw * 0.25) &&
              rect.width <= vw * 0.995) {
            el.style.setProperty('display', 'none', 'important');
            return true;
          }
        }
      } catch (e) {}
      el = el.parentElement;
    }
    return false;
  }

  function hideCardFrom(node) {
    return hideFromElement(node.parentElement);
  }

  // 左栏任务列表的"加载中..."占位行（真机实测：文本恰为 "加载中..."，
  // 约 232x29，位于左栏）。它不是内容、也不是握手卡，会被 ≥2 关键词规则
  // 放过，真机上表现为"盖板揭开后列表里挂着一行加载中"。判定收紧到
  // **精确文本 + 小尺寸 + 左半屏**，聊天正文里的"加载中"不会命中
  // （消息气泡远宽于 40% 视口或不在左栏窄条内）。
  function hideLoadingRows() {
    var hits = 0;
    var vw = window.innerWidth || document.documentElement.clientWidth;
    var nodes = document.querySelectorAll('div,span,p,button');
    var limit = Math.min(nodes.length, 4000);
    for (var i = 0; i < limit; i++) {
      var el = nodes[i];
      if (!(el instanceof HTMLElement)) continue;
      var t = String(el.textContent || '').trim();
      if (t !== '加载中...' && t !== '加载中…' && t !== 'Loading...' && t !== 'Loading…') continue;
      var rect = el.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) continue;
      if (rect.width >= vw * 0.4 || rect.height >= 60) continue;
      if (rect.left > vw * 0.45) continue;
      el.style.setProperty('display', 'none', 'important');
      hits++;
    }
    return hits;
  }

  // 第二层探测（不依赖文本节点结构）：在屏幕九宫格采样点做命中测试，
  // 卡片/覆盖层必然覆盖其中若干点；对其元素链做同样的标记+尺寸判定。
  // 解决"正文是单个超长文本节点 / 文本被包裹在闭包容器里"等结构差异。
  function sweepPoints() {
    var hits = 0;
    var vw = window.innerWidth || document.documentElement.clientWidth;
    var vh = window.innerHeight || document.documentElement.clientHeight;
    var xs = [vw * 0.5, vw * 0.25, vw * 0.75];
    var ys = [vh * 0.32, vh * 0.5, vh * 0.64];
    var seen = [];
    for (var xi = 0; xi < xs.length; xi++) {
      for (var yi = 0; yi < ys.length; yi++) {
        var stack;
        try {
          stack = document.elementsFromPoint(xs[xi], ys[yi]) || [];
        } catch (e) {
          continue;
        }
        for (var s = 0; s < stack.length; s++) {
          var el = stack[s];
          if (seen.indexOf(el) >= 0) continue;
          seen.push(el);
          try {
            if (markerCount(String(el.textContent || '').slice(0, 800)) < 2) continue;
          } catch (e) {
            continue;
          }
          if (hideFromElement(el)) hits++;
        }
      }
    }
    return hits;
  }

  function sweep() {
    if (!document.body) return 0;
    var hits = sweepPoints() + hideLoadingRows();
    var scanned = 0;
    var walker;
    try {
      walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
    } catch (e) {
      return hits;
    }
    var node;
    while ((node = walker.nextNode())) {
      scanned++;
      if (scanned > 4000) break;
      var value = node.nodeValue;
      // 上限 600：卡片正文（标题+说明+4 个步骤）常被渲染成**单个文本节点**
      // （约 130–180 字符）——120 的旧上限会把它整段跳过，导致真机永不隐藏
      // （本地仿制卡片恰为约 75 字符，测试因此漏过；真机双端都弹卡的实锤）。
      if (!value || value.length > 600) continue;
      if (markerCount(value) === 0) continue;
      if (hideCardFrom(node)) hits++;
    }
    return hits;
  }

  var deadline = Date.now() + 30 * 60 * 1000;
  var timer = window.setInterval(function () {
    if (Date.now() > deadline) {
      window.clearInterval(timer);
      return;
    }
    sweep();
  }, 1000);
  sweep();
  [0, 250, 600, 1200, 2500, 5000].forEach(function (delay) {
    window.setTimeout(sweep, delay);
  });
  // 冷启动前 90 秒叠加 mutation 触发（及时性）；之后靠 1s 节拍兜底，
  // 避免长时间挂着高噪声观察（流式输出持续触发 childList）。
  try {
    var observer = new MutationObserver(function () {
      if (Date.now() > deadline) {
        try { observer.disconnect(); } catch (e) {}
        observer = null;
        return;
      }
      if (observer.__pending) return;
      observer.__pending = window.setTimeout(function () {
        observer.__pending = null;
        sweep();
      }, 200);
    });
    observer.observe(document.documentElement, {
      childList: true,
      subtree: true
    });
    window.setTimeout(function () {
      if (observer) {
        try { observer.disconnect(); } catch (e) {}
        observer = null;
      }
    }, 90000);
  } catch (e) {}
})();
''';

  static String _themeSyncScript(bool dark) =>
      '''
(function () {
  var requestedDark = ${dark ? 'true' : 'false'};
  var requestedTheme = requestedDark ? 'dark' : 'light';
  // 双向同步（2026-09 用户口径）：应用的决定在这里**一次性**生效并打上
  // __zcodeControlAppliedTheme 基准；页面里手动切换主题时由观察者上报应用，
  // 应用重新注入同一决定——不再有"强制回写/手势时间窗"把页面锁死。
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
    // Reset the observer baseline for every native/app-driven update. Without
    // this, a later ordinary click could mistake the already-applied native
    // theme for a manual WebView change.
    window.__zcodeControlUserThemeLast = requestedTheme;

    var previous = window.__zcodeControlAppliedTheme;
    // 基准存**归一化**值（dark/light），与观察者的 currentUserTheme() 同一
    // 口径，页面自己的变更才能被识别为"与基准不一致"。
    window.__zcodeControlAppliedTheme = theme;
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
  }
  install();

  // 双向同步的"页面 → 应用"方向：官方页里手动切换主题后，页面的
  // localStorage / <html> 类名会变化。这里做**确定性比较**——生效主题与
  // 应用最后一次写入的基准（__zcodeControlAppliedTheme）不一致时上报
  // zrTheme，应用更新后重新注入同一决定（此时比较相等，天然收敛）。
  // 不再使用手势时间窗：旧机制要求"点击后 2.2 秒内完成"，官方页的主题
  // 菜单是两步异步操作，窗口一过就会把用户的选择改回去（真机反馈"被
  // 强制锁定"的根因）。
  if (!window.__zcodeControlUserThemeObserverInstalled) {
    window.__zcodeControlUserThemeObserverInstalled = true;

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

    var reportTimer = null;
    function scheduleReportIfChanged() {
      if (reportTimer) return;
      reportTimer = window.setTimeout(function () {
        reportTimer = null;
        if (!window.__zcodeControlThemeState) return;
        var theme = currentUserTheme();
        if (!theme) return;
        // 与应用基准一致（包括应用自己写入触发的变更）：只校准基线，不上报。
        if (theme === window.__zcodeControlAppliedTheme) {
          window.__zcodeControlUserThemeLast = theme;
          return;
        }
        // 页面自己的变更：与上次已上报值相同就不重复报。
        if (theme === window.__zcodeControlUserThemeLast) return;
        window.__zcodeControlUserThemeLast = theme;
        var bridge = window.flutter_inappwebview;
        if (!bridge || typeof bridge.callHandler !== 'function') return;
        try {
          // 第 3 参数是主 frame 令牌：Dart 侧 _bridgeAllowed 会校验，
          // 缺令牌的回执一律被拒（v1.1.4 真机"主题不同步"的根因）。
          bridge.callHandler('zrTheme', JSON.stringify({
            theme: theme,
            source: 'user'
          }), window.__zrToken);
        } catch (e) {}
      }, 120);
    }

    function installUserThemeObserver() {
      var root = document.documentElement;
      if (!root) {
        window.setTimeout(installUserThemeObserver, 0);
        return;
      }
      try {
        // 只观察 <html> 的属性（F17 有界原则），不监听整棵子树。
        new MutationObserver(scheduleReportIfChanged).observe(root, {
          attributes: true,
          attributeFilter: ['class', 'data-theme',
            'data-zcode-browser-theme-surface']
        });
      } catch (e) {}
      window.addEventListener('storage', function (event) {
        if (event.key === 'zcode-theme') scheduleReportIfChanged();
      }, true);
    }
    installUserThemeObserver();
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

  /// 工作区就绪探测：任务列表行、输入区或会话正文任一出现即算真实内容，
  /// 品牌盖板可以揭开了（对齐用户口径：盖住"配对/加载工作区"启动过程）。
  static const String _workspaceReadyProbeScript = '''
(() => {
  const body = document.body;
  const text = body && body.innerText ? body.innerText : '';
  const lower = text.toLowerCase();
  const rows = document.querySelectorAll('[data-testid^="task-item-"]').length;
  const composer = !!document.querySelector('textarea, [contenteditable="true"], [data-testid*="composer"]');
  const vw = window.innerWidth || document.documentElement.clientWidth;
  const vh = window.innerHeight || document.documentElement.clientHeight;
  const CN_WORDS = ['加载工作区', '配对工作区', '同步桌面端工作区', '等待桌面端配对',
    '连接中转服务', '设备鉴权'];
  const EN_WORDS = ['connecting relay service', 'establishing a connection between',
    'loading workspace', 'pairing workspace'];
  const hasWord = (value) => {
    const l = String(value || '').toLowerCase();
    for (let i = 0; i < CN_WORDS.length; i++) {
      if (l.indexOf(CN_WORDS[i]) >= 0) return true;
    }
    for (let j = 0; j < EN_WORDS.length; j++) {
      if (l.indexOf(EN_WORDS[j]) >= 0) return true;
    }
    return false;
  };
  // 聊天时间线里的同名字样不算过渡态：用户在对话里讨论"加载工作区"时，
  // 正文命中关键词不该把整页盖住（真机上确实发生过这种讨论）。
  const CONV_SELECTOR = '[data-testid="conversation"], [data-testid="conversation-column"],' +
    '[data-testid^="v4-timeline"], [data-testid^="v4-row-"], [data-testid^="chat-"]';
  // 1) 列表还没加载：过渡屏（配对卡 / 英文中转连接屏）就是整页文案。
  let handshake = rows === 0 && hasWord(text);
  // 2) 列表已加载：过渡卡是叠在页面上的居中面板（真机"切换会话又出现卡片"
  //    的场景），按几何形态识别——宽度占视口 40%~99.5%、高度 12%~92%，
  //    且在聊天时间线之外。消息气泡在时间线内，因此不会被误判。
  if (!handshake) {
    const boxes = document.querySelectorAll('div,section,main,aside');
    const limit = Math.min(boxes.length, 3000);
    for (let i = 0; i < limit; i++) {
      const el = boxes[i];
      if (el.closest && el.closest(CONV_SELECTOR)) continue;
      const own = String(el.textContent || '').slice(0, 600);
      if (!own || !hasWord(own)) continue;
      const r = el.getBoundingClientRect();
      if (r.width < vw * 0.4 || r.width > vw * 0.995) continue;
      if (r.height < vh * 0.12 || r.height > vh * 0.92) continue;
      handshake = true;
      break;
    }
  }
  // 左栏任务列表的加载占位行（真机实测：文本恰为 "加载中..."，约 232x29，
  // 位于左栏）。它出现时列表还没有真实内容，属于过渡态——旧探针对它完全
  // 无感，盖板提前揭开，用户就看到半加载的列表（"加载中还是能看到"）。
  let loadingRow = false;
  const nodes = document.querySelectorAll('div,span,button,p');
  const rowLimit = Math.min(nodes.length, 4000);
  for (let i = 0; i < rowLimit; i++) {
    const el = nodes[i];
    const t = (el.textContent || '').trim();
    if (t !== '加载中...' && t !== '加载中…' && t !== 'Loading...' && t !== 'Loading…') continue;
    const rect = el.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) continue;
    if (rect.width < vw * 0.4 && rect.height < 60) { loadingRow = true; break; }
  }
  // 被顶号是**终态**信息（"另一台控制端接管"）：盖板必须立刻揭开让用户看到
  // 原因，否则用户面对永远盖着的品牌页，比看到英文卡片更糟。
  const takeover = text.indexOf('Taken Over By Another Device') >= 0 ||
    text.indexOf('Device takeover') >= 0;
  const blank = !text.trim() && rows === 0 && !composer;
  return JSON.stringify({
    rows: rows,
    composer: composer,
    handshake: handshake,
    loadingRow: loadingRow,
    takeover: takeover,
    textLen: text.length,
    blank: blank
  });
})()
''';

  /// 同屏布局探测（设置返回的落地决策依据）。
  ///
  /// 两条独立信号，任一成立即判同屏：
  /// 1. `wide`：视口宽度 ≥768 CSS px——官方页自身的布局断点，最稳；
  ///    任务列表打开子面板（如 web 设置）时列表行消失，宽度信号仍有效
  ///    （真机反馈"有时闪回设备列表页"的场景）。
  /// 2. `narrow`：任务列表行存在且呈侧栏窄条（<60% 视口）。
  static const String _combinedLayoutProbeScript = '''
(() => {
  const vw = window.innerWidth || document.documentElement.clientWidth;
  const wide = vw >= 768;
  const rows = document.querySelectorAll('[data-testid^="task-item-"]');
  let narrow = false;
  if (rows.length) {
    const rect = rows[0].getBoundingClientRect();
    narrow = rect.width > 0 && rect.width < vw * 0.6;
  }
  return JSON.stringify({ rows: rows.length, wide: wide, narrow: narrow,
    combined: wide || narrow });
})()
''';

  InAppWebViewController? _controller;
  bool _failed = false;
  bool _loading = true;
  // 静默刷新（用户反馈"打开页面半天都是缓存"）：页面常驻 IndexedStack，
  // 记录"不可见起点"，重新可见时由 [PageRefreshPolicy] 判定是否重载。
  DateTime? _hiddenSince;
  // 品牌启动覆盖层（用户口径：首次加载用应用图标页盖住官方页的
  // "正在配对工作区 / 加载工作区中"，不露出 web 的启动过程）。
  // onLoadStop 只代表文档就绪，工作区 UI 还在挂载——用探针确认真实内容
  // （任务列表/输入区出现）才揭盖；超时兜底防止离线时永久遮盖。
  bool _bootCover = true;
  Timer? _pageStateTimer;

  /// 盖板纪元：每次揭盖（[_disarmCoverWatch]）或重挂（[_armBootCover]）都
  /// 递增（iter12 复核 P2）。在途探针按发起时的纪元作废——否则 deadline
  /// 揭盖后返回的陈旧探针可以把盖板重新盖上，而计时器已停，无人再揭
  /// （弱网/离线场景下的永久品牌盖）；同理堵住同 generation 重挂后被
  /// 陈旧探针立即揭盖的窗口。
  // R-16：盖板 deadline 使用独立 wall-clock 计时器（不依赖 DOM 探针成功），
  // 到点必揭盖并只记一次事件；探针在途锁防止 800ms 节拍叠加调用。
  Timer? _coverDeadlineTimer;
  bool _coverProbeInFlight = false;
  bool _coverTimeoutLogged = false;
  // 被顶号日志只报一次（800ms 节拍会反复命中同一状态）。
  bool _takeoverLogged = false;

  int _coverEpoch = 0;
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
    // 单点守卫（安全审计 S-5/N-2）：无论调用方是 load 事件、返回手势退避
    // 循环还是初始化路径，都不向非受信主文档注入 frame-origin 证明。POST
    // 主框架导航不经 shouldOverrideUrlLoading，敌对文档可能正在驻留。
    if (!LinkBuilder.isTrustedRemotePage(await _controller?.getUrl())) {
      return false;
    }
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
    widget.backController?.attachLayoutProbe(_probeCombinedLayout);
    widget.backController?.attachCoverObserver(_onCoverChanged);
    // 回放当前遮盖状态：控制器可能在页面挂载前就已 setCovered（冷启动
    // 落在启动器，iter6 F-2），那次变化没有观察者接收。
    if (widget.backController?.covered ?? false) _onCoverChanged(true);
    _rotateBridgeToken();
    _armFirstLoadWatchdog();
  }

  /// 页面**实际布局**探测：任务列表行存在且只占视口的一部分宽度
  /// （对话与列表同屏的侧栏形态）= 同屏布局。手机形态下列表占满全宽，
  /// 打开对话后列表消失——两种情况都判 false。这样"列表页也算同一个
  /// 页面"（用户口径：平板设置返回回到对话**或列表**里）。
  Future<bool> _probeCombinedLayout() async {
    final controller = _controller;
    if (controller == null) return false;
    final result = await controller.evaluateJavascript(
      source: _combinedLayoutProbeScript,
    );
    final payload = jsonDecode(result?.toString() ?? '{}');
    if (payload is! Map) return false;
    return payload['combined'] == true;
  }

  void _armFirstLoadWatchdog() {
    _armBootCover();
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

  /// 品牌盖板（重新）挂上：任何一次全新文档加载（首启/静默重载/渲染进程
  /// 重建）都会经过这里。盖板不再"到点必揭"——由 [_startPageStateWatch]
  /// 持续跟随页面状态：官方页只要处于"配对/加载工作区"状态或空白，盖板就在。
  void _armBootCover() {
    if (!mounted) return;
    // 新一轮加载：重置 deadline 与日志节流（R-16），旧计时器作废。
    _coverDeadlineTimer?.cancel();
    _coverDeadlineTimer = null;
    _coverTimeoutLogged = false;
    // 顶号日志节流同样按"新一轮加载"重置（iter12 N-P1-1）：它此前只在置位
    // 处出现，跨 generation/换凭证不重置——同一台设备第二次被顶号时
    // webviewTakeoverDetected 不再落日志，排障第一现场凭空消失。
    _takeoverLogged = false;
    // initState 路径下字段初始就是 true，避免"构造期 setState"；只有
    // reload/重建路径（盖板已被揭开过）才需要重新挂上。
    if (!_bootCover) setState(() => _bootCover = true);
    _coverEpoch++;
    _startPageStateWatch();
  }

  /// 页面状态跟随（用户口径：卡片"要么冷处理、要么盖住"——这里用纯图标
  /// 盖板覆盖官方页的"配对 / 中转连接 / 列表加载中"过渡态，只要页面还处于
  /// 任一过渡态就继续盖；只有页面真正可用（有任务行或输入区，且无过渡信号）
  /// 才揭盖。切换会话/重连时的过渡态同样被覆盖，不依赖对页面 DOM 结构的
  /// 完美识别。
  ///
  /// R-16：deadline 由独立 wall-clock 计时器兜底（不依赖探针成功）——旧实现
  /// 把 20 秒超时判在"探针返回成功"分支里，探针长期报错（JSON 解析失败、
  /// payload 非 Map、controller 断开）时 return 直接跳过 deadline，品牌盖板
  /// 可以永久盖住页面。另：同一时刻只允许一个在途探针（in-flight 锁）。
  void _startPageStateWatch() {
    _pageStateTimer ??= Timer.periodic(const Duration(milliseconds: 800), (_) {
      unawaited(_syncCoverWithPage());
    });
    _coverDeadlineTimer ??= Timer(const Duration(seconds: 20), () {
      if (!mounted) return;
      if (!_bootCover) return;
      // 到点仍在盖：记录一次（只一次）并揭盖，让用户看到页面真实状态
      // 或明确失败，而不是永远的品牌图标。
      if (!_coverTimeoutLogged) {
        _coverTimeoutLogged = true;
        AppLog.event(
          LogEvent.webviewBootCoverTimeout,
          level: LogLevel.warn,
          fields: {
            LogField.device: widget.device.id,
            LogField.generation: _webviewGeneration,
            LogField.reason: 'deadline_watchdog',
          },
        );
      }
      setState(() => _bootCover = false);
      _disarmCoverWatch();
    });
    unawaited(_syncCoverWithPage());
  }

  /// 揭盖后停掉跟随与 deadline 计时器（iter12 N-P2-1）：页面在 IndexedStack
  /// 里永不销毁，800ms 周期探针若一直空转，N 台设备 = N 个后台定时器，App
  /// 退后台也不停。揭盖即停，重新挂盖时由 [_armBootCover] 经 `??=` 重建。
  void _disarmCoverWatch() {
    _coverEpoch++;
    _pageStateTimer?.cancel();
    _pageStateTimer = null;
    _coverDeadlineTimer?.cancel();
    _coverDeadlineTimer = null;
  }

  Future<void> _syncCoverWithPage() async {
    if (!mounted) return;
    final controller = _controller;
    if (controller == null || _failed) {
      if (_bootCover && _failed) {
        setState(() => _bootCover = false);
        _disarmCoverWatch();
      }
      return;
    }
    if (!_bootCover) return;
    // R-16：单次 in-flight 锁——上一轮探针还悬着时不叠加新调用。
    if (_coverProbeInFlight) return;
    _coverProbeInFlight = true;
    final generationAtProbe = _webviewGeneration;
    final epochAtProbe = _coverEpoch;
    late bool showCover;
    try {
      final result = await controller.evaluateJavascript(
        source: _workspaceReadyProbeScript,
      );
      final payload = jsonDecode(result?.toString() ?? '{}');
      if (payload is! Map) return;
      final rows = payload['rows'] as int? ?? 0;
      final composer = payload['composer'] == true;
      final handshake = payload['handshake'] == true;
      final loadingRow = payload['loadingRow'] == true;
      final takeover = payload['takeover'] == true;
      final blank = payload['blank'] == true;
      if (takeover) {
        // 被顶号：终态信息优先于"美观"——立刻揭盖让用户读到原因。
        if (!_takeoverLogged) {
          _takeoverLogged = true;
          AppLog.event(LogEvent.webviewTakeoverDetected, level: LogLevel.warn,
              fields: {
                LogField.device: widget.device.id,
                LogField.generation: _webviewGeneration,
              });
        }
        showCover = false;
      } else {
        // 规则见 [shouldCoverOfficialPage]：过渡态本身就是"不揭盖"的理由，
        // 与内容是否部分就绪无关。
        showCover = shouldCoverOfficialPage(
          rows: rows,
          composer: composer,
          handshake: handshake,
          loadingRow: loadingRow,
          takeover: false,
          blank: blank,
        );
      }
    } catch (_) {
      // 探针失败（页面上没有脚本执行环境 / 返回非法 JSON / 上下文正在替换）：
      // 不改变盖板状态——揭盖与否由 wall-clock deadline 兜底（R-16），
      // 不再出现"探针一直失败 → 永远盖着"的路径。
      return;
    } finally {
      _coverProbeInFlight = false;
    }
    if (!mounted) return;
    // R-16：探针期间页面已换代 → 丢弃这次陈旧结果。
    if (generationAtProbe != _webviewGeneration) return;
    // iter12 复核 P2：探针期间盖板已揭/重挂（纪元变化）→ 同样丢弃，
    // 陈旧探针不得逆转揭盖决定，也不得抢在重挂前揭盖。
    if (epochAtProbe != _coverEpoch) return;
    if (showCover != _bootCover) {
      setState(() => _bootCover = showCover);
      if (!showCover) _disarmCoverWatch();
    }
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

  /// 页面重新可见（解除盖板 / App 回前台 / 切到本设备）时的静默刷新：
  /// 不可见超过 `PageRefreshPolicy.staleAfter` 且本页是当前设备页、没有
  /// 加载/错误在途，就走既有 `_reload()` 全新加载——用户看到的是既有的
  /// 加载盖板，而不是几小时前的缓存画面。
  void _onCoverChanged(bool covered) {
    if (covered) {
      _hiddenSince ??= DateTime.now();
      return;
    }
    // 外壳可能在 build 里幂等回调：刷新动作推到帧后，避免 build 期间 setState。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeSilentRefresh();
    });
  }

  void _maybeSilentRefresh() {
    if (!mounted) return;
    // 仍被盖住：还不是"可见"（iter6 复核 F-8）。launcher 覆盖下的 resume
    // 在这里早退，保留不可见起点，等真正揭开时再判定——否则用户停在设备
    // 中心时每次解锁都会后台整页重载当前设备。
    if (widget.backController?.covered ?? false) return;
    final devices = ref.read(deviceListProvider);
    final myIndex = devices.indexWhere((d) => d.id == widget.device.id);
    final isCurrent = myIndex >= 0 && ref.read(activeTabProvider) == myIndex;
    final hiddenSince = _hiddenSince;
    final hiddenFor = hiddenSince == null
        ? null
        : DateTime.now().difference(hiddenSince);
    final shouldRefresh = PageRefreshPolicy.shouldRefreshOnVisible(
      hiddenFor: hiddenFor,
      isCurrentDevice: isCurrent,
      loadInFlight: _loading || _rendererGone,
      failed: _failed,
    );
    // 非当前设备页：**有意保留**不可见起点（不清空），等真正切到它再判定；
    // 其余不满足时清空——在途加载完成后没有再触发点，保旧时间戳反而会让
    // 下次揭盖算出虚假的"长时间不可见"而刚加载完又被无谓重载。
    if (!isCurrent) return;
    _hiddenSince = null;
    if (!shouldRefresh) return;
    // release 可见：静默刷新代表"用户回来看到的是重载"，field 排查需要它。
    AppLog.event(LogEvent.webviewSilentReload, level: LogLevel.warn, fields: {
      LogField.device: widget.device.id,
      LogField.generation: _webviewGeneration,
      LogField.reason: 'stale_on_visible',
    });
    unawaited(_reload());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 页面常驻 IndexedStack：切后台不销毁，回来就是旧画面。记录不可见起点，
    // resumed 时统一交给 [PageRefreshPolicy] 判定（仍被盖住时不抢跑）。
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _hiddenSince ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeSilentRefresh();
      });
    }
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
      widget.backController?.attachLayoutProbe(_probeCombinedLayout);
      widget.backController?.attachCoverObserver(_onCoverChanged);
      if (widget.backController?.covered ?? false) _onCoverChanged(true);
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
      // R-15：用**新** device 原子重建同步控制器。旧实现只置 null，
      // `didUpdateWidget` 不会再次触发 `didChangeDependencies`，后续桥消息
      // （`_sync?.ingestMessage(...)`）会静默丢弃新凭证下的事件与状态。
      _sync = WebViewSyncController(device: widget.device, ref: ref);
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
      ref.read(subFrameStatsProvider.notifier).forget(oldWidget.device.id);
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

  /// 系统返回键：先让官方页面自己处理页内路由——手机上是"对话页 → 对话列表"，
  /// 平板/大屏上是设置面板的「返回工作区」等页面自带返回控件；页面确实没动
  /// （或没有返回控件）才交回 Dart 决定是否露出设备页。
  ///
  /// 手机与平板走同一条路径（2026-09-14 口径修订：平板上跳过页内脚本会让
  /// web 设置页的返回直接退出到设备页，与用户预期相反；同屏页没有返回控件
  /// 时脚本如实报 not_found，仍是一次返回露出设备页）。
  Future<bool> _handleBack() async {
    if (!mounted) return false;
    final controller = _controller;
    if (controller == null) return false;
    // 平板与手机同一条路径（2026-09-14 用户口径修订）：系统返回先让官方页面
    // 自己处理——有返回控件就点它（如设置面板的「返回工作区」），
    // 没有控件（对话+列表同屏页）则脚本立刻报 not_found，由外壳露出设备页。
    // 早前"平板上跳过页内脚本"的规则已撤销：它会让 web 设置页的返回直接
    // 退出到设备页，与用户预期相反。误点风险由脚本自身的守卫兜底
    // （只认标签/图标键 + 点击后内容签名自证，点不动即 no_change → 露设备页）。

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
    // taskId 格式白名单（安全审计 S-8/W-016）：畸形 id 不进跳转脚本，
    // 按既有 invalid 语义短路（直接回执，不设看门狗——看门狗只产生
    // undelivered；UI 落入默认支显示 sessionJumpNotFound）。
    if (!SessionJump.taskIdWellFormed(sessionId)) {
      _onJumpOutcome(
        JumpOutcome(
          attemptId: ++_jumpAttempt,
          ok: false,
          reason: JumpOutcome.reasonInvalid,
          taskId: sessionId,
        ),
      );
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
    _pageStateTimer?.cancel();
    _coverDeadlineTimer?.cancel();
    _jumpWatchdog?.cancel();
    _sync?.forget();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(themeModeProvider);
    // 应用内切换设备（通知深链/浮动卡：启动器已隐藏时 covered 不发生变化）：
    // 切到本设备也算"打开页面"，同样按策略判定静默刷新（iter6 F-3）。
    ref.listen<int>(activeTabProvider, (_, next) {
      if (!mounted) return;
      final devices = ref.read(deviceListProvider);
      if (devices.indexWhere((d) => d.id == widget.device.id) == next) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _maybeSilentRefresh();
        });
      }
    });
    final dark = themeModeIsDark(
      mode,
      MediaQuery.platformBrightnessOf(context),
    );
    ref.listen<String>(themeModeProvider, (_, _) {
      if (!mounted) return;
      final controller = widget.backController;
      if (controller != null && controller.covered) {
        // 设备页遮盖着远控页时切换主题：**整页重载**而不是刷 DOM——官方页
        // 自己的主题选择按钮状态只在挂载时读一次，就地改类名会让"页面是
        // 夜间、按钮还写着日间"（用户真机反馈）。重载发生在不可见时，
        // 重新挂载后按钮与实际主题一致。
        unawaited(_reload());
        return;
      }
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
                        // 令牌只注入受信主文档（安全审计 S-5）：Android 下
                        // POST 主框架导航不经过 shouldOverrideUrlLoading，
                        // 非官方文档可能短暂驻留高权限容器——无条件注入会把
                        // frame-origin 证明送给它。主题同理只对官方页下发。
                        if (LinkBuilder.isTrustedRemotePage(uri)) {
                          unawaited(_injectBridgeToken());
                          unawaited(_applyWebTheme(_currentDark(context)));
                        }
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
                        unawaited(_syncCoverWithPage());
                        // 与 onLoadStart 同口径：只对受信主文档注入令牌/主题
                        //（安全审计 S-5）。
                        if (LinkBuilder.isTrustedRemotePage(uri)) {
                          unawaited(_injectBridgeToken());
                          unawaited(_applyWebTheme(_currentDark(context)));
                        }
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
                          final subFrameTrusted =
                              LinkBuilder.isTrustedOrigin(uri);
                          // ADR-002 步骤 1：取证只记类别计数，不记 URL/host
                          // ——"官方页是否真用 iframe"只能靠真机数据回答。
                          // 换凭证/页面重建后，残余子 frame 回调仍会到达
                          // （iter1 复审 F-1）：决策无条件返回，W1 白名单语义
                          // 不依赖 State 存活；计数只在挂载时记。
                          if (mounted) {
                            ref
                                .read(subFrameStatsProvider.notifier)
                                .record(
                                  widget.device.id,
                                  trusted: subFrameTrusted,
                                );
                          }
                          return subFrameTrusted
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
                          // 源头只给 path（D-20260917-01），不依赖
                          // LogRedactor.route 对全 URL 做去 query 兜底。
                          AppLog.event(LogEvent.webviewNavBlocked, level: LogLevel.warn, fields: {
                            LogField.device: widget.device.id,
                            LogField.generation: _webviewGeneration,
                            LogField.route: uri?.path,
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
                        // release 可见的 warn：与 webviewNavBlocked 同口径，
                        // 源头只给 path（D-20260918-01，D-20260917-01 同类）。
                        AppLog.event(LogEvent.webviewRendererUnresponsive, level: LogLevel.warn, fields: {
                          LogField.device: widget.device.id,
                          LogField.generation: _webviewGeneration,
                          LogField.route: uri?.path,
                        });
                        return null;
                      },
                      onRenderProcessResponsive: (_, uri) async => null,
                    ),
                    if (_bootCover && !_failed)
                      Positioned.fill(
                        // 品牌启动盖板（用户口径）：**纯图标**，不带转圈——
                        // 盖住官方页的"正在配对工作区 / 加载工作区中"启动
                        // 过程，探针确认真实内容或 12s 超时后揭开。
                        child: ColoredBox(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          child: Center(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: Image.asset(
                                'assets/brand/mark.png',
                                width: 72,
                                height: 72,
                              ),
                            ),
                          ),
                        ),
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

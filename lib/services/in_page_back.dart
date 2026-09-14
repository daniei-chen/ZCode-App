import 'dart:convert';

/// 页面内返回的结果（v1.1.1 / 用户上报回归）。
///
/// 修复的是一次真实回归：手机端在对话页按返回，应该回到对话列表页，但实际
/// 要么没反应、要么直接跳回设备页。原因在于旧脚本"点一下就算完"：
///   * 只认 aria-label/title 里的"返回/Back"字样——官方页面只要把按钮换成
///     纯图标（无 aria-label）或改了文案，就再也匹配不到；
///   * 点完不校验是否真的换了页面，脚本返回一个字符串，Dart 无法判断成败；
///   * 平板上被 `_isPhone` 直接短路，返回键根本不会交给页面处理。
///
/// 现在：脚本用多策略找候选（标签 → 结构 → 左上角几何启发式），点击后用
/// "内容签名"轮询验证是否真的发生了页面切换，并把结果经 bridge 回传；
/// Dart 侧据此决定是"算作已处理"还是"退回设备页"，并且平板走同一条路径。
class InPageBackOutcome {
  const InPageBackOutcome({
    required this.attemptId,
    required this.ok,
    required this.reason,
  });

  final int attemptId;
  final bool ok;
  final String reason;

  /// 点到了返回控件并且页面内容确实变了。
  static const reasonClicked = 'clicked';

  /// 找遍了候选也没有可点的返回控件（Dart 会再试浏览器历史，然后退回设备页）。
  static const reasonNotFound = 'not_found';

  /// 点到了候选，但页面内容没有变化（不是返回控件）。
  static const reasonNoChange = 'no_change';

  /// 页面里没有可用的 bridge（令牌缺失等）：由 Dart 超时兜底。
  static const reasonUnavailable = 'unavailable';

  static const maxReasonChars = 32;

  static InPageBackOutcome? parse(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final id = decoded['id'];
    if (id is! num || id < 0) return null;
    final ok = decoded['ok'];
    if (ok is! bool) return null;
    final reason = decoded['reason'];
    if (reason is! String || reason.isEmpty || reason.length > maxReasonChars) {
      return null;
    }
    return InPageBackOutcome(attemptId: id.toInt(), ok: ok, reason: reason);
  }

  @override
  String toString() => 'InPageBackOutcome(#$attemptId ok=$ok reason=$reason)';
}

abstract final class InPageBack {
  /// 单次尝试的最长等待（脚本内部逐候选验证 600ms，最多试若干候选）。
  static const Duration budget = Duration(milliseconds: 2600);

  /// Dart 侧兜底超时：比脚本预算略长，页面完全没回执时也能继续走历史/设备页。
  static const Duration dartTimeout = Duration(milliseconds: 3200);

  /// 进入"返回"脚本前，最多尝试的候选数量（避免在异常页面上扫太久）。
  static const int maxCandidates = 6;

  /// 令牌未就绪时的短促重试次数。
  static const int reportRetryMax = 12;

  static String script(int attemptId) => '''
(function () {
  var attempt = $attemptId;
  var MAX = $maxCandidates;
  var GEN = '__zrBackGen';
  var myGen = (window[GEN] = (window[GEN] || 0) + 1);
  var cancelled = function () { return window[GEN] !== myGen; };
  var reported = false;
  var reportTries = 0;
  var deliver = function (ok, reason) {
    var h = window.flutter_inappwebview;
    if (!h || typeof h.callHandler !== 'function') return false;
    if (!window.__zrToken) return false;
    try {
      h.callHandler('zrBack', JSON.stringify({
        id: attempt,
        ok: ok,
        reason: reason
      }), window.__zrToken);
    } catch (e) {
      return false;
    }
    reported = true;
    return true;
  };
  var report = function (ok, reason) {
    if (reported) return;
    if (deliver(ok, reason)) return;
    if (reportTries >= $reportRetryMax) return;
    reportTries++;
    setTimeout(function () { report(ok, reason); }, 150);
  };
  var lower = function (value) { return String(value || '').toLowerCase(); };
  var isBackToTop = function (value) {
    var t = lower(value);
    return t.indexOf('返回顶部') >= 0 || t.indexOf('back to top') >= 0;
  };
  // 明确不是"返回"的控件（真机 no_change 实锤：平板上误点到折叠/菜单类图标
  // 导致页面无变化、返回键看起来闪一下又回设备页）。命中即跳过。
  var isNotBack = function (value) {
    var t = lower(value);
    return t.indexOf('收起') >= 0 || t.indexOf('展开') >= 0 ||
      t.indexOf('侧边') >= 0 || t.indexOf('侧栏') >= 0 ||
      t.indexOf('菜单') >= 0 || t.indexOf('搜索') >= 0 ||
      t.indexOf('主题') >= 0 || t.indexOf('设置') >= 0 ||
      t.indexOf('折叠') >= 0 || t.indexOf('更多') >= 0 ||
      t.indexOf('collapse') >= 0 || t.indexOf('expand') >= 0 ||
      t.indexOf('menu') >= 0 || t.indexOf('search') >= 0 ||
      t.indexOf('theme') >= 0 || t.indexOf('settings') >= 0;
  };
  var labelOf = function (el) {
    return [
      el.getAttribute('aria-label'),
      el.getAttribute('title'),
      el.getAttribute('data-testid'),
      el.textContent
    ].filter(Boolean).join(' ').trim();
  };
  var isBackLabel = function (value) {
    var text = String(value || '').trim();
    if (!text) return false;
    if (text.length > 24) return false;
    if (isBackToTop(text)) return false;
    if (isNotBack(text)) return false;
    var t = lower(text);
    if (/^(返回|返回上一级|back|go back)\$/.test(t)) return true;
    return /(^|[\\s_-])(back|go-back)([\\s_-]|\$)/.test(t);
  };
  var visible = function (el) {
    if (!el || !el.getBoundingClientRect) return false;
    var rect = el.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return false;
    var style = window.getComputedStyle(el);
    if (style.display === 'none' || style.visibility === 'hidden') return false;
    if (style.pointerEvents === 'none') return false;
    if (el.disabled) return false;
    return true;
  };
  var collect = function () {
    var out = [];
    var push = function (el) {
      if (!el || out.indexOf(el) >= 0) return;
      if (!visible(el)) return;
      out.push(el);
    };
    var selectors = [
      'button[aria-label="返回任务首页"]',
      'button[aria-label="Back to task home"]',
      'button[aria-label="返回会话列表"]',
      'button[aria-label*="返回"]',
      'button[aria-label^="Back to"]',
      '[aria-label*="返回"]',
      '[title*="返回"]',
      '[data-testid*="back"]',
      '[data-testid*="Back"]',
      '[data-test*="back"]'
    ];
    for (var s = 0; s < selectors.length; s++) {
      var hits = document.querySelectorAll(selectors[s]);
      for (var i = 0; i < hits.length; i++) {
        if (isBackToTop(labelOf(hits[i]))) continue;
        if (isNotBack(labelOf(hits[i]))) continue;
        push(hits[i]);
      }
    }
    var generic = document.querySelectorAll('button,[role="button"],a');
    for (var g = 0; g < generic.length; g++) {
      var el = generic[g];
      if (isBackToTop(labelOf(el))) continue;
      if (!isBackLabel(el.getAttribute('aria-label'))) continue;
      if (!visible(el)) continue;
      push(el);
    }
    // 结构/几何兜底：只认**左上角小方块里的纯图标按钮**。
    //
    // 真机实测教训：官方页面列表页左上角没有任何返回控件，早期"左上 96px 内"
    // 的宽规则会把列表页的工作区选择器/新建按钮当成返回键点掉，表现为
    // "越返回越往里走"。对话页的真实返回键在 (8,10,24,24)，因此这里收紧到
    // 左上 56×40 的小角落，并要求是图标型（有 svg 或无文本）。
    var cornerRight = 56;
    var cornerBottom = 40;
    var minSize = 20;
    var maxSize = 40;
    var nodes = document.querySelectorAll(
      'button,[role="button"],a,[tabindex]'
    );
    var scored = [];
    for (var n = 0; n < nodes.length; n++) {
      var node = nodes[n];
      if (isBackToTop(labelOf(node))) continue;
      if (isNotBack(labelOf(node))) continue;
      // 折叠/开关类控件带 aria-expanded/aria-pressed：绝不当作返回键。
      if (node.getAttribute('aria-expanded') !== null) continue;
      if (node.getAttribute('aria-pressed') !== null) continue;
      if (!visible(node)) continue;
      var rect = node.getBoundingClientRect();
      if (rect.width < minSize || rect.width > maxSize) continue;
      if (rect.height < minSize || rect.height > maxSize) continue;
      if (rect.top < 0 || rect.top > cornerBottom) continue;
      if (rect.left < 0 || rect.left + rect.width > cornerRight) continue;
      var iconOnly = node.querySelector('svg') ||
        String(node.textContent || '').trim().length === 0;
      if (!iconOnly) continue;
      scored.push({ el: node, score: rect.top * 2 + rect.left });
    }
    scored.sort(function (a, b) { return a.score - b.score; });
    for (var k = 0; k < scored.length; k++) push(scored[k].el);
    return out;
  };
  // 内容签名：URL + 可见的 data-testid 序列 + 主容器首个子元素。
  // 只要能区分"页面真的换了"就够，不做任何内容留存。
  var signature = function () {
    var parts = [String(location.href), String(document.title || '')];
    var nodes = document.querySelectorAll('[data-testid]');
    var n = Math.min(nodes.length, 40);
    for (var i = 0; i < n; i++) {
      parts.push(String(nodes[i].getAttribute('data-testid')));
    }
    var main = document.querySelector('main') || document.body;
    if (main && main.firstElementChild) {
      parts.push(String(main.firstElementChild.className || main.firstElementChild.tagName));
    }
    return parts.join('|');
  };
  var before = signature();
  var done = function (ok, reason) {
    report(ok, reason);
  };
  var tryAt = function (queue, index) {
    if (cancelled()) return;
    if (index >= queue.length) {
      // 走到这里说明至少点过一个候选：点到东西了，但页面没换
      // （多是点到了不该点的图标），比"没找到"更准确的结论。
      done(false, 'no_change');
      return;
    }
    var el = queue[index];
    try {
      if (el.scrollIntoView) el.scrollIntoView({ block: 'nearest' });
      el.click();
    } catch (e) {}
    var deadline = Date.now() + 600;
    var poll = function () {
      if (cancelled()) return;
      if (signature() !== before) {
        done(true, 'clicked');
        return;
      }
      if (Date.now() > deadline) {
        tryAt(queue, index + 1);
        return;
      }
      setTimeout(poll, 80);
    };
    setTimeout(poll, 120);
  };
  // 候选可能是"刚刚才挂上来"的：用户点开对话后立刻按返回时，返回键还没渲染完，
  // 直接判 not_found 会让返回键闪回设备页（长跑实测偶发）。给它一个 1.2s 的重试窗口。
  // 窗口只在页面刚加载的几秒内生效：稳定状态下列表页永远没有返回控件，
  // 每次返回都白等 1.2s，用户感知就是"返回键卡一秒"（真机诊断包实锤）。
  var searchSince = null;
  var start = function () {
    if (cancelled()) return;
    var queue = collect().slice(0, MAX);
    if (queue.length) {
      tryAt(queue, 0);
      return;
    }
    if (window.performance && performance.now && performance.now() > 6000) {
      done(false, 'not_found');
      return;
    }
    if (searchSince === null) searchSince = Date.now();
    if (Date.now() - searchSince > 1200) {
      done(false, 'not_found');
      return;
    }
    setTimeout(start, 150);
  };
  start();
  return 'async';
})()''';
}

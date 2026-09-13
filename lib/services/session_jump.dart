import 'dart:convert';

/// 页面内跳转的结果（F12 / N07–N08）。
///
/// 旧实现是"点火即忘"：脚本在 20 秒预算里点不到目标就静默收工，Dart 侧永远
/// 不知道这次跳转是否成功——用户点了通知，最后停在任务列表上，没有任何解释。
/// 现在脚本把结果经 bridge 回传（带主 frame 令牌），Dart 侧据此给出可解释的
/// 失败提示。
class JumpOutcome {
  const JumpOutcome({
    required this.attemptId,
    required this.ok,
    required this.reason,
    this.taskId,
    this.resolvedTaskId,
  });

  /// 本次跳转的序号：页面可能同时存在多代脚本，只有最新一代的结果算数。
  final int attemptId;

  final bool ok;

  /// 见下面的 `reason*` 常量。
  final String reason;

  /// 请求定位的会话 id。
  final String? taskId;

  /// 页面里命中的任务把手（通常形如 `xxx-<taskId>`）；失败时为 null。
  final String? resolvedTaskId;

  /// 命中并点击了目标。
  static const reasonFound = 'found';

  /// 页面内 20 秒预算耗尽仍未出现目标。
  static const reasonTimeout = 'timeout';

  /// 更新的跳转取代了本次尝试。
  static const reasonSuperseded = 'superseded';

  /// 请求本身非法（空 taskId）。
  static const reasonInvalid = 'invalid';

  /// 页面始终没有回传结果（令牌未就绪/主 frame 未执行），由 Dart 看门狗判定。
  static const reasonUndelivered = 'undelivered';

  static const maxReasonChars = 32;
  static const maxIdChars = 256;

  /// 解析页面回传的 JSON；结构不符一律返回 null（调用方计入丢弃计数）。
  static JumpOutcome? parse(Object? raw) {
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
    final taskId = _id(decoded['taskId']);
    if (decoded['taskId'] != null && taskId == null) return null;
    final resolved = _id(decoded['resolvedTaskId']);
    if (decoded['resolvedTaskId'] != null && resolved == null) return null;
    return JumpOutcome(
      attemptId: id.toInt(),
      ok: ok,
      reason: reason,
      taskId: taskId,
      resolvedTaskId: resolved,
    );
  }

  static String? _id(Object? value) {
    if (value == null) return null;
    if (value is! String) return null;
    if (value.isEmpty || value.length > maxIdChars) return null;
    return value;
  }

  @override
  String toString() =>
      'JumpOutcome(#$attemptId ok=$ok reason=$reason task=$taskId '
      'handle=$resolvedTaskId)';
}

abstract final class SessionJump {
  /// 主 frame 令牌到位前的报告重试次数与间隔（20 × 150ms = 3s）。
  static const reportRetryMax = 20;

  static String jumpScript(String taskId, {String? workspace, int attemptId = 0}) {
    final tidLiteral = jsonEncode(taskId);
    final wsLiteral = workspace == null ? 'null' : jsonEncode(workspace);
    return '''
(function() {
  var tid = $tidLiteral;
  var ws = $wsLiteral;
  var attempt = $attemptId;
  var GEN = '__zrJumpGen';
  var myGen = (window[GEN] = (window[GEN] || 0) + 1);
  var stale = function() { return window[GEN] !== myGen; };
  var deadline = Date.now() + 20000;
  var clicked = new WeakSet();
  var tried = new WeakSet();
  var mine = new WeakSet();
  var backTries = 0;
  var reported = false;
  var reportTries = 0;
  var reportTimer = null;
  var deliver = function(ok, reason, handle) {
    var bridge = window.flutter_inappwebview;
    if (!bridge || typeof bridge.callHandler !== 'function') return false;
    // 令牌由 Dart 用 evaluateJavascript 注入主 frame；没有它这条消息会在
    // Dart 侧被 _bridgeAllowed 拒绝，发了等于没发。
    if (!window.__zrToken) return false;
    try {
      bridge.callHandler('zrJump', JSON.stringify({
        id: attempt,
        ok: ok,
        reason: reason,
        taskId: tid,
        resolvedTaskId: handle || null
      }), window.__zrToken);
    } catch (e) {
      return false;
    }
    reported = true;
    return true;
  };
  // 注入可能比这次跳转晚一点到位：先短促重试。全部失败也不永久沉默——
  // Dart 侧另有独立看门狗，会把没有结果的尝试判为 undelivered。
  var report = function(ok, reason, handle) {
    if (reported) return;
    if (deliver(ok, reason, handle)) return;
    if (reportTries >= $reportRetryMax) return;
    reportTries++;
    reportTimer = setTimeout(function() { report(ok, reason, handle); }, 150);
  };
  var isIdChar = function(ch) { return /[0-9A-Za-z_-]/.test(ch); };
  var handleOf = function(testid) {
    var at = testid.indexOf(tid);
    if (at === -1) return tid;
    var left = at, right = at + tid.length;
    while (left > 0 && isIdChar(testid.charAt(left - 1))) left--;
    while (right < testid.length && isIdChar(testid.charAt(right))) right++;
    return testid.slice(left, right) || tid;
  };
  var find = function() {
    var els = document.querySelectorAll('[data-testid]');
    for (var i = 0; i < els.length; i++) {
      var t = els[i].getAttribute('data-testid') || '';
      if (t.indexOf(tid) === -1) continue;
      if (els[i].getClientRects().length === 0) continue;
      if (!els[i].isConnected) continue;
      els[i].scrollIntoView({block: 'center'});
      els[i].click();
      return handleOf(t);
    }
    return null;
  };
  var matchWs = function(label) {
    if (!ws || !label) return false;
    var a = label.toLowerCase();
    var b = ws.toLowerCase();
    return a.indexOf(b) !== -1 || b.indexOf(a) !== -1;
  };
  var backSel = [
    'button[aria-label="返回任务首页"]',
    'button[aria-label="Back to task home"]',
    'button[aria-label*="返回"]',
    'button[aria-label^="Back to"]'
  ];
  var findBack = function() {
    for (var s = 0; s < backSel.length; s++) {
      var b = document.querySelector(backSel[s]);
      if (b) return b;
    }
    return null;
  };
  var expandTarget = function() {
    var heads = document.querySelectorAll('button[aria-expanded="false"]');
    for (var i = 0; i < heads.length; i++) {
      if (tried.has(heads[i])) continue;
      if (!matchWs(heads[i].textContent || '')) continue;
      tried.add(heads[i]);
      heads[i].click();
      return true;
    }
    return false;
  };
  var restoreProbe = function() {
    var heads = document.querySelectorAll('button[aria-expanded="true"]');
    for (var i = 0; i < heads.length; i++) {
      if (!mine.has(heads[i])) continue;
      mine.delete(heads[i]);
      heads[i].click();
      return true;
    }
    return false;
  };
  var probeExpand = function() {
    var heads = document.querySelectorAll('button[aria-expanded="false"]');
    for (var i = 0; i < heads.length; i++) {
      if (tried.has(heads[i])) continue;
      tried.add(heads[i]);
      mine.add(heads[i]);
      heads[i].click();
      return true;
    }
    return false;
  };
  if (!tid) { report(false, 'invalid', null); return false; }
  var first = find();
  if (first) { report(true, 'found', first); return true; }
  var iv = null, mo = null, deb = null;
  var stop = function() {
    if (iv) clearInterval(iv);
    if (mo) mo.disconnect();
    if (deb) clearTimeout(deb);
    iv = null; mo = null; deb = null;
  };
  var tick = function() {
    if (stale()) {
      report(false, 'superseded', null);
      for (; restoreProbe(); ) {}
      stop();
      return;
    }
    var hit = find();
    if (hit) { report(true, 'found', hit); stop(); return; }
    if (Date.now() > deadline) {
      report(false, 'timeout', null);
      for (; restoreProbe(); ) {}
      stop();
      return;
    }
    var back = findBack();
    if (back) {
      if (!clicked.has(back)) { clicked.add(back); back.click(); backTries = 1; return; }
      backTries++;
      if (backTries <= 5) return;
    }
    if (expandTarget()) return;
    if (restoreProbe()) return;
    probeExpand();
  };
  var schedule = function() {
    if (deb || stale()) return;
    deb = setTimeout(function() { deb = null; tick(); }, 120);
  };
  iv = setInterval(tick, 400);
  if (document.body) {
    mo = new MutationObserver(schedule);
    mo.observe(document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['aria-expanded']
    });
  }
  return 'async';
})()''';
  }
}

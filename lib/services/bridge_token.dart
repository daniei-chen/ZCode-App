/// 主 frame 令牌的注入策略（F03 的可靠性补丁）。
///
/// 现场证据（v1.1.2 真机诊断包）：Android 16 / WebView 151 上，
/// `onLoadStop` 时 `window.__zrToken` 还没落地 →
///   * 页面钩子按 fail-closed 规则**排队不发**（事件、遥测、返回回执全都上不来）；
///   * 返回脚本点到了控件也报不回结果 → Dart 超时判 `unavailable` → 回退设备页。
/// 根因是"注入一次就当成功"：文档刚 ready 时钩子可能尚未执行（`__zrSetToken`
/// 还不存在），而 read-back 校验也直接把带引号的结果当成失败。
///
/// 这里把三件事拆成可测的纯逻辑：
///   1. [normalize]：`evaluateJavascript` 的返回值在不同实现下可能带引号；
///   2. [isReady]：只认"读回来的令牌与期望完全一致"；
///   3. [retryDelays]：注入后按退避重试若干次，覆盖钩子晚于 load stop 执行的情况。
abstract final class BridgeTokenPolicy {
  /// 注入后的重试时刻（毫秒，相对首次尝试）。合计约 2.6 秒，覆盖慢设备。
  static const List<int> retryDelays = <int>[0, 120, 300, 700, 1500];

  /// 返回键前"等令牌到位"的预算：等不到就照旧走历史/设备页兜底，不无限等。
  static const Duration backBudget = Duration(milliseconds: 1400);

  /// 轮询间隔。
  static const Duration pollInterval = Duration(milliseconds: 150);

  /// 规范化 read-back 结果：去引号、去空白。非字符串返回 null。
  static String? normalize(Object? raw) {
    if (raw is! String) return null;
    var value = raw.trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1).trim();
    }
    return value.isEmpty ? null : value;
  }

  /// 令牌是否确认到位：期望值非空，且读回来的值与之完全一致。
  static bool isReady(Object? raw, String expected) {
    if (expected.isEmpty) return false;
    final value = normalize(raw);
    return value != null && value == expected;
  }

  /// 是否还值得再试（已用次数 < 计划次数）。
  static bool shouldRetry(int attempts) => attempts < retryDelays.length;

  /// 第 [attempts] 次重试前的等待时长（attempts 从 0 起）。
  static Duration delayFor(int attempts) {
    final index = attempts.clamp(0, retryDelays.length - 1);
    return Duration(milliseconds: retryDelays[index]);
  }

  /// 读取令牌的 JS 片段：缺失时返回空串（便于 Dart 判空，且不暴露期望值）。
  static const String readScript = 'window.__zrToken || ""';

  /// 注入脚本：只在钩子就绪时调用，且回读同一个表达式以便校验。
  static String injectScript(String token) =>
      'window.__zrSetToken && window.__zrSetToken("$token"); '
      'window.__zrToken || ""';

  /// document-start 引导脚本：在钩子安装之前把令牌放进主 frame。
  /// 令牌只含 base64url 字符（A-Za-z0-9-_），可安全内联在单引号里。
  static String bootstrapScript(String token) {
    if (token.isEmpty) return 'void 0;';
    return "window.__zrToken = '$token';"
        "window.__zrTokenSource = 'document-start';"
        "void 0;";
  }

  /// 钩子是否已安装（用于诊断：区分"钩子没跑"与"钩子跑了但令牌没给"）。
  static const String hookReadyScript = 'window.__zrHookReady ? "ready" : "absent"';
}

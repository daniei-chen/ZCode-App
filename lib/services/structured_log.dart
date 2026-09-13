/// 结构化日志与统一脱敏（v1.1.0 / PR20，F18/F19）。
///
/// 旧实现是自由文本：`AppLog.warn('[ZR][WebView] load error ...')`。约定靠人守，
/// 一次手滑就可能把控制链接、sid 或页面正文写进日志，而诊断页会把日志交给用户
/// 复制出去。这里把"能写什么"变成类型问题：
///
/// * 每条日志都必须由 [LogEvent] 事件码标识（白名单，机器可聚合）；
/// * 字段只能来自 [LogField]（route/device/reason/数字），**没有自由文本字段**——
///   写不进用户名、会话标题、正文或 payload；
/// * 值在写入环形缓冲前统一过 [LogRedactor]（第二道防线，防调用点手拼字符串）；
/// * 日志行格式固定：`时间 级别 事件码 k=v ...`，便于机器解析与人工核对。
library;

/// 事件码白名单。新增事件必须同时更新这里与 `test/log_redactor_test.dart`，
/// 让"日志面"的扩张留下痕迹。
enum LogEvent {
  // WebView 生命周期
  webviewLoadStart('WV100'),
  webviewLoadStop('WV101'),
  webviewLoadError('WV102'),
  webviewNavBlocked('WV103'),
  webviewRendererGone('WV104'),
  webviewRendererUnresponsive('WV105'),
  webviewRebuilt('WV106'),
  webviewSilentReload('WV107'),
  webviewFirstLoadFailed('WV108'),
  webviewBackFailed('WV109'),
  webviewBackHandled('WV112'),
  webviewConsoleDropped('WV110'),
  webviewStorageCleared('WV111'),

  // bridge / 观测
  bridgeTokenMissing('BR200'),
  bridgeTokenRotated('BR201'),
  bridgeMessageDropped('BR202'),
  observerStatsSkipped('BR203'),

  // 跳转
  jumpRequested('JP300'),
  jumpSucceeded('JP301'),
  jumpFailed('JP302'),

  // 通知
  notificationInitFailed('NT500'),
  notificationShowFailed('NT501'),
  notificationTestFailed('NT502'),
  notificationSuppressed('NT503'),

  // 更新
  updateCheckFailed('UP600'),
  updateDownloadRejected('UP601'),

  // 本地状态
  deviceStoreUnavailable('DS700'),
  deviceLastUsedPersistFailed('DS701'),
  warmupLoadFailed('DS702'),
  warmupPersistFailed('DS703'),
  biometricAuthFailed('LC800'),
  biometricUnlockFailed('LC801'),
  protectedDataWipeFailed('LC802'),

  // 安全门禁开关（PR21/F24）：开关本身是敏感操作，两种结果都要留痕。
  securityLockEnabled('SL900'),
  securityLockDisabled('SL901'),
  securityLockRejected('SL902'),

  // 扫码（PR21/F24）：相机故障要能说明原因，不再只有黑屏。
  cameraFailed('CM910');

  const LogEvent(this.code);

  /// 稳定的事件码（写进日志与诊断包，不要随意改）。
  final String code;
}

/// 允许的字段。没有自由文本字段是刻意设计：需要描述性内容时用 [LogField.reason]
/// 的短标签（只允许 `[a-z0-9_.:-]`），或新增一个枚举值。
enum LogField {
  /// 设备短 id（前 8 位，便于多设备关联，不足以反查凭证）。
  device('dev'),

  /// WebView generation（重建计数）。
  generation('gen'),

  /// 只保留路由类型，例如 `/remote/v4`（丢弃 query/fragment）。
  route('route'),

  /// 机器可读的原因标签。
  reason('reason'),

  /// 异常/错误摘要：先整体脱敏，再压成单行并截断（有界，不能塞正文）。
  error('err'),

  /// 计数/耗时等整数。
  count('n'),
  size('size'),
  durationMs('ms'),

  /// 布尔状态。
  ok('ok');

  const LogField(this.key);

  final String key;
}

/// 统一脱敏。任何进入日志或诊断包的字符串都要先过这里。
abstract final class LogRedactor {
  static const String replacement = '<redacted>';

  /// 凭证参数（`sid=...`、`hash=...`、`token=...` 等）。
  /// Dart 的 RegExp 不支持 `(?i)` 内联修饰符，大小写不敏感靠 caseSensitive。
  static final RegExp _credentialParam = RegExp(
    r'\b(sid|hash|token|remotecontroltoken|remote_control_token|code|secret|'
    r'password|passwd|pwd|apikey|api_key|access_token|refresh_token|authorization|'
    "bearer)=([^&\\s,;\"']*)",
    caseSensitive: false,
  );

  /// JWT / 长 base64url / 长十六进制串（控制链接里的 hash、token 常见形态）。
  static final List<RegExp> _opaque = [
    RegExp(r'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]+)?'),
    RegExp(r'\b[A-Fa-f0-9]{24,}\b'),
    RegExp(r'\b[A-Za-z0-9_-]{32,}\b'),
  ];

  /// 带 query/fragment/userinfo 的 URL（凭证优先藏在 query 里）。
  static final RegExp _url = RegExp(r'\b([a-zA-Z][a-zA-Z0-9+.-]*://[^\s]+)');

  /// 只保留 `scheme://host/path`，丢掉 query/fragment/userinfo。
  static String route(String? url) {
    if (url == null || url.isEmpty) return '-';
    final trimmed = url.trim();
    // 已经是相对路由：只保留 pathname。
    if (!trimmed.contains('://')) {
      final base = trimmed.split('?').first.split('#').first;
      return base.isEmpty ? '-' : base;
    }
    try {
      final uri = Uri.parse(trimmed);
      if (uri.host.isEmpty) return replacement;
      final path = uri.path.isEmpty ? '/' : uri.path;
      return '${uri.scheme}://${uri.host}$path';
    } catch (_) {
      return replacement;
    }
  }

  /// 设备 id 只保留前 8 位：足够在多设备间关联，不足以反查完整标识。
  static String shortId(String? id, {int keep = 8}) {
    if (id == null || id.isEmpty) return '-';
    final cleaned = id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (cleaned.isEmpty) return '-';
    return cleaned.length <= keep ? cleaned : cleaned.substring(0, keep);
  }

  /// 原因标签：只允许小写字母/数字/点/冒号/连字符/下划线，最长 40。
  static String reason(Object? value) {
    if (value == null) return '-';
    final cleaned = value
        .toString()
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_.:-]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (cleaned.isEmpty) return '-';
    return cleaned.length <= 40 ? cleaned : cleaned.substring(0, 40);
  }

  /// 异常摘要：脱敏 → 压成单行 → 截断到 [maxErrorChars]。
  /// 异常消息里最常见的凭证泄漏面是 URL 与请求参数，脱敏优先处理它们。
  static const int maxErrorChars = 120;

  static String errorText(Object? value) {
    if (value == null) return '-';
    var text = redact(value.toString())
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.isEmpty) return '-';
    // 异常类型名也在里面，保留以便聚合（`ClientException: ...`）。
    if (text.length > maxErrorChars) {
      text = '${text.substring(0, maxErrorChars)}…';
    }
    return text;
  }

  /// 对整行文本做脱敏（第二道防线；调用点本身已受 [LogField] 限制）。
  static String redact(String input) {
    if (input.isEmpty) return input;
    var output = input.replaceAllMapped(
      _credentialParam,
      (match) => '${match.group(1)}=$replacement',
    );
    for (final pattern in _opaque) {
      output = output.replaceAll(pattern, replacement);
    }
    output = output.replaceAllMapped(_url, (match) => route(match.group(1)));
    return output;
  }
}

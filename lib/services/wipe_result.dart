/// 受保护状态擦除的逐项结果（R-17 / b4 复审）。
///
/// 复审指认：旧实现的"任一环节失败保持锁定"只对磁盘路径成立——
/// `clearAllSiteData` 与 `cancelAll` 各自吞掉失败、只写日志，然后
/// `_authed` 照样被置 true，与交接报告"任一环节失败都保持锁定"的表述不符。
///
/// 这里把"每个域到底成没成功"变成**返回值**：调用方按
/// [WipeResult.allRequiredSucceeded] 决定是否放行；失败项带机器可读的
/// 原因标签（不含任何正文/凭证，只进结构化日志）。
library;

/// 擦除事务的步骤。**全部为必需项**：任一项失败即不放行（fail-closed）。
enum WipeStep {
  /// 内存态 Provider（同步执行；正常路径必然成功，异常也按未完成处理）。
  providers('providers'),

  /// 安全存储：设备凭证、索引、warmup 脚本。
  secureStorage('secure_storage'),

  /// "最近设备"指针偏好（与设备凭证同生命周期）。
  lastDevice('last_device'),

  /// WebView 站点数据（localStorage / IndexedDB 等；`deleteAllData`）。
  siteData('site_data'),

  /// WebView HTTP 缓存。
  cache('cache'),

  /// WebView Cookie（官方站点会话）。
  cookies('cookies'),

  /// 系统通知撤销（payload 含设备/会话 id）。
  ///
  /// **契约（b4 复审要求写明）**：插件没有"当前通知栏"的查询 API，
  /// 本步成功只证明**撤销请求已提交**，不能证明系统通知已不存在；
  /// 调用抛错则按未完成处理——保持锁定并允许重试，不谎报"通知已清"。
  notifications('notifications');

  const WipeStep(this.tag);

  /// 日志/报告用的机器标签（不含内容，可安全进入诊断包）。
  final String tag;
}

/// 单个步骤的结果。
class WipeStepResult {
  const WipeStepResult({required this.step, required this.ok, this.reason});

  final WipeStep step;
  final bool ok;

  /// 机器可读的失败原因标签（如 `site_data_failed`），**不含**任何正文。
  final String? reason;

  @override
  String toString() =>
      'WipeStepResult(${step.tag} ok=$ok${reason == null ? '' : ' reason=$reason'})';
}

/// 擦除事务的整体结果。
class WipeResult {
  const WipeResult(this.steps);

  final List<WipeStepResult> steps;

  bool isOk(WipeStep step) =>
      steps.any((s) => s.step == step && s.ok);

  /// 未成功的步骤（供日志与 UI 重试提示使用）。
  List<WipeStep> get failedSteps => [
    for (final s in steps)
      if (!s.ok) s.step,
  ];

  /// 是否全部必需项成功——生产恢复路径**只有**在该值为 true 时才关闭门禁。
  bool get allRequiredSucceeded =>
      steps.isNotEmpty && steps.every((s) => s.ok);

  @override
  String toString() =>
      'WipeResult(failed=${failedSteps.map((s) => s.tag).join('|')})';
}

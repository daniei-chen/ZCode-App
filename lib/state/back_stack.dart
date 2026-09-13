/// 系统返回键的层级决策（用户上报回归）。
///
/// 返回键要按"最上面那一层"逐级退出，顺序固定：
///
///   1. 推入的原生页面（设置、诊断、扫码、对话框）——由 Navigator 弹栈处理，
///      回到进入它之前的那一页（手机上是对话页/设备页，平板同理）；
///   2. 官方远控页内部的页内路由（对话页 → 对话列表）——交给页面自己处理，
///      由 `lib/services/in_page_back.dart` 的脚本点它的返回控件并自证；
///   3. 设备页（启动器）——把设备页露出来；
///   4. 设备页已经可见——放行给系统，正常退出应用。
///
/// 第 1 步是 Navigator 的默认行为；第 2–4 步由这里决策，便于单测覆盖
/// （WebView 插件在单元测试里不可用，页面侧的行为由注入脚本的断言覆盖）。
library;

enum BackDecision {
  /// 页面自己处理掉了这次返回（例如对话页回到了对话列表）。
  handledByPage,

  /// 页面无能为力：露出设备页，下一次返回才退出应用。
  revealLauncher,

  /// 设备页已经可见：放行，让系统按正常方式退出应用。
  allowExit,
}

BackDecision decideSystemBack({
  required bool launcherVisible,
  required bool pageHandled,
}) {
  if (launcherVisible) return BackDecision.allowExit;
  return pageHandled ? BackDecision.handledByPage : BackDecision.revealLauncher;
}

/// 系统返回键的层级决策（用户上报回归）。
///
/// 返回键要按"最上面那一层"逐级退出，顺序固定：
///
///   1. 推入的原生页面（设置、诊断、扫码、对话框）——由 Navigator 弹栈处理，
///      回到进入它之前的那一页（设备列表页）；
///   2. 官方远控页内部的页内路由（对话页 → 对话列表）——交给页面自己处理，
///      由 `lib/services/in_page_back.dart` 的脚本点它的返回控件并自证
///      （仅手机；平板同屏布局直接跳过这一层，见 [isTabletLayout]）；
///   3. 设备页（启动器）——把设备页露出来；
///   4. 设备页已经可见——放行给系统，正常退出应用。
///
/// 第 1 步是 Navigator 的默认行为；第 2–4 步由这里决策，便于单测覆盖
/// （WebView 插件在单元测试里不可用，页面侧的行为由注入脚本的断言覆盖）。
library;

import 'dart:ui';

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

/// 平板形态判定。
///
/// 用户规则：平板上官方页面是"对话 + 列表同屏"，页内没有返回可控件，
/// 系统返回应当**一次到位**直接露出设备页——页内返回脚本在平板上不跑
/// （真机实测它会误触对话区控件，表现为"点赞动了一下但没返回"）。
///
/// 阈值取 **700dp**（真机反馈修正）：Android 传统分界是 600dp，但用户
/// 的折叠屏手机最短边约 606dp，被 600 误判成平板（设置返回/页内返回
/// 全部走错路径）。700 恰好把 606dp 的大屏手机分回手机、800dp 的
/// Pixel Tablet 分回平板。
bool isTabletLayout(Size size) => size.shortestSide >= 700;

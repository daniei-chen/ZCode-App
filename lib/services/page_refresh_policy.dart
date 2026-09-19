/// 远控页"回显静默刷新"决策（用户反馈：打开页面半天都是缓存）。
///
/// 页面常驻 `IndexedStack`，切后台/被启动器盖住都不会销毁——官方 SPA 自己
/// 不做可见性重取，回来看到的是几小时前的画面。策略：**重新可见且本页是
/// 当前设备页时，若不可见超过 [staleAfter] 且没有加载/错误在途，就走既有
/// `_reload()` 全新加载**（用户看到的是既有的加载盖板，而不是卡死的旧缓存）。
///
/// `isCurrentDevice` 是关键守卫（iter6 评审 F-1）：启动器揭盖是**全体**
/// 控制器一起解盖，不收敛到当前页的话，N 台设备会同时整页重载 N 次。
/// 阈值取 60 秒：贴近"每次打开都要新鲜"的诉求，又避免快速来回反复重载。
abstract final class PageRefreshPolicy {
  /// 不可见多久之后，重新可见时需要静默刷新。
  static const Duration staleAfter = Duration(seconds: 60);

  static bool shouldRefreshOnVisible({
    required Duration? hiddenFor,
    required bool isCurrentDevice,
    required bool loadInFlight,
    required bool failed,
  }) {
    // 非当前设备页：保留不可见起点（调用方不得清空），等真正切到它再判定。
    if (!isCurrentDevice) return false;
    // 在途加载与错误卡各有自己的恢复路径（首载看门狗 / 手动重试），不抢。
    if (loadInFlight || failed) return false;
    if (hiddenFor == null) return false;
    return hiddenFor >= staleAfter;
  }
}

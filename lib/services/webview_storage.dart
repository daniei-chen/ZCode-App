import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'app_log.dart';
import 'structured_log.dart';

/// WebView 本地存储清单与清理策略（PR20 / F19；2026-10 V2 账号流修订）。
///
/// 审计指出：Cookie / DOM storage / cache 从未进入数据流清单，也没有清理触发点。
/// 这里把清单和清理动作放在同一处，避免文档与实现各说各话。
///
/// V2 修订（桌面端 3.16.3 起）：配对凭证改为官方页的**账号登录态**——实测
/// 落在 localStorage（`zcodejwttoken`、`oauth:*:access_token`、
/// `oauth:active_provider`）+ Cookie。链接里只剩设备身份 sid。因此**换链接
 /// 不再清 Cookie 和 DOM storage**：两者合起来就是登录态，清掉等于每次
/// 重扫/桌面端升级（QR 的 app_version/name 变化）都要重新登录；
/// 锁定擦除仍全部清空。
abstract final class WebViewStorage {
  /// 数据流清单：类型 → 存什么、何时清。
  static const Map<String, String> inventory = {
    'cookies': '官方页账号登录态（V2 配对凭证）；锁定擦除时清空，换链接保留',
    'domStorage':
        'localStorage 保存账号登录态（zcodejwttoken/oauth:*）与主题等偏好；锁定擦除时清空，换链接保留',
    'sessionStorage': '页面会话级状态；随 WebView generation 重建消失',
    'httpCache': '静态资源缓存，不含业务凭证；换凭证/移除设备/擦除时清空',
    'indexedDb': '官方页面自行使用；随站点数据清理（锁定擦除）',
  };

  /// 诊断包里的单行摘要（不展开细节，避免诊断文本膨胀）。
  static const String policySummary =
      'httpCache：换凭证/锁定擦除；cookies+domStorage（账号登录态）：仅锁定擦除';

  /// 换控制链接时的清理：只清 HTTP 缓存。账号登录态（Cookie + DOM
  /// storage）跨链接有效，必须保留——用户登录一次，之后重扫/换设备/桌面端
  /// 升级都不再需要重新登录。
  static Future<void> clearForCredentialChange({
    InAppWebViewController? controller,
    String? deviceId,
  }) async {
    var cacheCleared = false;
    if (controller != null) {
      try {
        // 插件把缓存清理暴露为静态方法（WebView 已销毁时也适用）。
        await InAppWebViewController.clearAllCache();
        cacheCleared = true;
      } catch (_) {}
    }
    AppLog.event(
      LogEvent.webviewStorageCleared,
      fields: {
        LogField.device: deviceId,
        LogField.reason: 'cache_keep_auth',
        LogField.ok: cacheCleared,
      },
    );
  }

  /// 锁定擦除：清空全部本地存储（Cookie、DOM storage、缓存）。
  /// 用于"清除本机数据"——设备都删了，账号登录态不能留在磁盘上。
  static Future<void> wipeAll({
    InAppWebViewController? controller,
    String? deviceId,
  }) async {
    var domCleared = false;
    if (controller != null) {
      try {
        await controller.evaluateJavascript(
          source:
              "(function(){try{window.localStorage.clear();"
              "window.sessionStorage.clear();}catch(e){}})();",
        );
        domCleared = true;
      } catch (_) {
        domCleared = false;
      }
    }
    try {
      await InAppWebViewController.clearAllCache();
    } catch (_) {}
    var cookiesCleared = false;
    try {
      await CookieManager.instance().deleteAllCookies();
      cookiesCleared = true;
    } catch (_) {}
    AppLog.event(
      LogEvent.webviewStorageCleared,
      fields: {
        LogField.device: deviceId,
        LogField.reason: domCleared ? 'dom_cookie_cache' : 'cookie_cache',
        LogField.ok: cookiesCleared,
      },
    );
  }
}

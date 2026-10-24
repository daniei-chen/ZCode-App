import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'app_log.dart';
import 'structured_log.dart';

/// WebView 本地存储清单与清理策略（PR20 / F19；2026-10 V2 账号流修订）。
///
/// 审计指出：Cookie / DOM storage / cache 从未进入数据流清单，也没有清理触发点。
/// 这里把清单和清理动作放在同一处，避免文档与实现各说各话。
///
/// V2 修订（桌面端 3.16.3 起）：配对凭证改为官方页的账号登录态（Cookie）+
/// 服务端设备注册，链接里只剩设备身份 sid。因此**换链接不再清 Cookie**——
/// 否则每次重扫二维码都会把登录态一起抹掉，所有设备都得重新登录；
/// 锁定擦除仍全部清空。
abstract final class WebViewStorage {
  /// 数据流清单：类型 → 存什么、何时清。
  static const Map<String, String> inventory = {
    'cookies': '官方页账号登录态（V2 配对凭证）；锁定擦除时清空，换链接保留',
    'domStorage': 'localStorage 保存 zcode-theme 等偏好；换凭证/移除设备/擦除时清空',
    'sessionStorage': '页面会话级状态；随 WebView generation 重建消失',
    'httpCache': '静态资源缓存，不含业务凭证；换凭证/移除设备/擦除时清空',
    'indexedDb': '官方页面自行使用；随站点数据清理（换凭证/擦除）',
  };

  /// 诊断包里的单行摘要（不展开细节，避免诊断文本膨胀）。
  static const String policySummary =
      'domStorage+httpCache：换凭证/锁定擦除；cookies：仅锁定擦除';

  /// 清理 WebView 本地存储。[preserveCookies] 供"换控制链接"路径使用：
  /// V2 的账号登录态（Cookie）跨链接有效，保留它用户才不必每次换链接都
  /// 重新登录。锁定擦除走默认 false，全部清空。
  ///
  /// 顺序刻意如此：先在当前页面里清 DOM storage（需要 JS 上下文），再清
  /// HTTP 缓存与（按需）Cookie，最后记一条结构化日志（只记动作，不记内容）。
  static Future<void> clearForCredentialChange({
    InAppWebViewController? controller,
    String? deviceId,
    bool preserveCookies = false,
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
      try {
        // 插件把缓存清理暴露为静态方法（WebView 已销毁时也适用）。
        await InAppWebViewController.clearAllCache();
      } catch (_) {}
    }
    var cookiesCleared = !preserveCookies;
    if (!preserveCookies) {
      try {
        await CookieManager.instance().deleteAllCookies();
      } catch (_) {
        cookiesCleared = false;
      }
    }
    AppLog.event(
      LogEvent.webviewStorageCleared,
      fields: {
        LogField.device: deviceId,
        LogField.reason: domCleared
            ? (preserveCookies ? 'dom_cache_keep_cookies' : 'dom_cookie_cache')
            : (preserveCookies ? 'cache_keep_cookies' : 'cookie_cache'),
        LogField.ok: cookiesCleared,
      },
    );
  }
}

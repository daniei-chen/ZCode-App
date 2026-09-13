import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'app_log.dart';
import 'structured_log.dart';

/// WebView 本地存储清单与清理策略（PR20 / F19）。
///
/// 审计指出：Cookie / DOM storage / cache 从未进入数据流清单，也没有清理触发点。
/// 这里把清单和清理动作放在同一处，避免文档与实现各说各话。
abstract final class WebViewStorage {
  /// 数据流清单：类型 → 存什么、何时清。
  static const Map<String, String> inventory = {
    'cookies': '远控页会话语义（无第三方 Cookie）；换凭证/移除设备/擦除时清空',
    'domStorage': 'localStorage 保存 zcode-theme 等偏好；换凭证/移除设备/擦除时清空',
    'sessionStorage': '页面会话级状态；随 WebView generation 重建消失',
    'httpCache': '静态资源缓存，不含业务凭证；换凭证/移除设备/擦除时清空',
    'indexedDb': '官方页面自行使用；随站点数据清理（换凭证/擦除）',
  };

  /// 诊断包里的单行摘要（不展开细节，避免诊断文本膨胀）。
  static String get policySummary =>
      'cookies+domStorage+httpCache；触发：换凭证/移除设备/锁定擦除';

  /// 清理所有本地存储。`controller` 为空时仍会清 Cookie（用于设备已被移除、
  /// 页面已销毁的场景）。
  ///
  /// 顺序刻意如此：先在当前页面里清 DOM storage（需要 JS 上下文），再清 Cookie
  /// 与 HTTP 缓存，最后记一条结构化日志（只记动作，不记内容）。
  static Future<void> clearForCredentialChange({
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
      try {
        // 插件把缓存清理暴露为静态方法（WebView 已销毁时也适用）。
        await InAppWebViewController.clearAllCache();
      } catch (_) {}
    }
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

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'app_log.dart';
import 'structured_log.dart';
import 'wipe_result.dart';

/// WebView 本地存储清单与清理策略（PR20 / F19）。
///
/// 审计指出：Cookie / DOM storage / cache 从未进入数据流清单，也没有清理触发点。
/// 这里把清单和清理动作放在同一处，避免文档与实现各说各话。
///
/// R-17 修正：清单里声明的 IndexedDB 以前没有任何清理动作（只写在文档里）；
/// 现在 [clearForCredentialChange] 在页面上下文里请求删除全部数据库，
/// [clearAllSiteData] 另走插件的 `WebStorageManager.deleteAllData()`。
///
/// iter16 修正：**设备删除不清站点数据**。存储按 origin（`zcode.z.ai`）共享，
/// 删除单台设备无法只清它那一份 cookie/DOM storage，全清反而会波及仍共存的
/// 其他设备；因此触发点只有"换凭证"（页面重建时）与"锁定擦除"（全量清理）。
/// 清单与 policySummary 的措辞按实现收紧。
abstract final class WebViewStorage {
  /// 数据流清单：类型 → 存什么、何时清。
  static const Map<String, String> inventory = {
    'cookies': '远控页会话语义（无第三方 Cookie）；换凭证/锁定擦除时清空',
    'domStorage': 'localStorage 保存 zcode-theme 等偏好；换凭证/锁定擦除时清空',
    'sessionStorage': '页面会话级状态；随 WebView generation 重建消失',
    'httpCache': '静态资源缓存，不含业务凭证；换凭证/锁定擦除时清空',
    'indexedDb': '官方页面自行使用；换凭证/擦除时逐库清理（deleteDatabase / deleteAllData）',
  };

  /// 诊断包里的单行摘要（不展开细节，避免诊断文本膨胀）。
  static String get policySummary =>
      'cookies+domStorage+indexedDb+httpCache；触发：换凭证/锁定擦除';

  /// JS 片段：清 localStorage/sessionStorage 并请求删除全部 IndexedDB。
  /// IndexedDB 删除是异步回调式，evaluate 不等回调——发出请求即尽力而为，
  /// 不阻塞页面（删除在后台完成）。
  static const String _clearDomScript =
      "(function(){try{window.localStorage.clear();"
      "window.sessionStorage.clear();}catch(e){}"
      "try{"
      "if(window.indexedDB&&indexedDB.databases){"
      "indexedDB.databases().then(function(list){"
      "(list||[]).forEach(function(db){try{indexedDB.deleteDatabase(db.name)}catch(e){}});"
      "});"
      "}else if(window.indexedDB&&indexedDB.webkitGetDatabaseNames){"
      "var req=indexedDB.webkitGetDatabaseNames();"
      "req.onsuccess=function(){var names=req.result;"
      "for(var i=0;i<names.length;i++){try{indexedDB.deleteDatabase(names[i])}catch(e){}}}}"
      "}catch(e){}})();";

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
        await controller.evaluateJavascript(source: _clearDomScript);
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

  /// 站点数据全量清理（擦除事务 / R-04、R-17）。
  ///
  /// 与 [clearForCredentialChange] 的差别：不需要页面 controller，面向
  /// "设备都删了、页面已销毁"的最终清理；额外走插件的
  /// `WebStorageManager.deleteAllData()`（按域清 localStorage/IndexedDB 等）
  /// 与全局 HTTP 缓存。
  ///
  /// **b4 复审修正（R-17）**：旧实现把三个域各自 catch、只写一条日志就返回，
  /// 调用方无法区分"全清干净"与"一个域都没清成"——与"任一失败保持锁定"的
  /// 声明不符。现在**返回逐域结果**（[WipeStepResult]），由擦除事务汇总后
  /// 决定是否放行；失败原因只记机器标签，不记录内容。
  static Future<List<WipeStepResult>> clearAllSiteData({String? reason}) async {
    final steps = <WipeStepResult>[];
    var siteDataOk = false;
    try {
      await WebStorageManager.instance().deleteAllData();
      siteDataOk = true;
    } catch (_) {
      siteDataOk = false;
    }
    steps.add(WipeStepResult(
      step: WipeStep.siteData,
      ok: siteDataOk,
      reason: siteDataOk ? null : 'delete_all_data_failed',
    ));
    var cacheOk = false;
    try {
      await InAppWebViewController.clearAllCache();
      cacheOk = true;
    } catch (_) {}
    steps.add(WipeStepResult(
      step: WipeStep.cache,
      ok: cacheOk,
      reason: cacheOk ? null : 'clear_cache_failed',
    ));
    var cookiesOk = false;
    try {
      await CookieManager.instance().deleteAllCookies();
      cookiesOk = true;
    } catch (_) {}
    steps.add(WipeStepResult(
      step: WipeStep.cookies,
      ok: cookiesOk,
      reason: cookiesOk ? null : 'delete_cookies_failed',
    ));
    final allOk = siteDataOk && cacheOk && cookiesOk;
    AppLog.event(
      LogEvent.webviewStorageCleared,
      fields: {
        LogField.reason:
            reason ?? (allOk ? 'all_site_data' : 'site_data_partial'),
        LogField.ok: allOk,
      },
    );
    return steps;
  }
}

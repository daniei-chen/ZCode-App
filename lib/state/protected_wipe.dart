import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/app_log.dart';
import '../services/device_store.dart';
import '../services/notifier.dart';
import '../services/structured_log.dart';
import '../services/warmup.dart';
import '../services/webview_storage.dart';
import 'active_session.dart';
import 'bridge_health.dart';
import 'event_feed.dart';
import 'observer_stats.dart';
import 'root_tabs.dart';
import 'session_index.dart';
import 'session_pool.dart';
import 'session_status.dart';

/// 受保护状态擦除事务（R-04）。
///
/// 审计复现：`DeviceStore.clearAll()` 只删磁盘与"最近设备"偏好；门禁之上
/// 的 ProviderScope 依然存活——`deviceListProvider` 等仍持有带控制链接的
/// 设备对象与全部会话/事件状态，形成"清了磁盘、内存还在"的半完成状态。
///
/// 这里把"清除全部受保护数据"收敛成一个事务，顺序固定：
///
///   1. 先清内存态（同步执行，在任何 await 之前让凭证从 state 不可达）；
///   2. 再清磁盘（secure storage / 索引 / warmup 脚本 / 最近设备指针）；
///   3. 清 WebView 站点数据（localStorage/IndexedDB/Cookie/缓存）；
///   4. 撤掉系统通知（payload 带设备与会话 id）。
///
/// **失败语义（fail-closed）**：secure storage（凭证本体）或通知撤销失败时
/// 事务抛出异常，调用方必须保持锁定，不得把"部分清除"当成已清除。
/// WebView 站点数据逐域尝试，失败原因如实写日志（不谎报成功）。
///
/// 入参用 [ProviderContainer]：生产从 `ProviderScope.containerOf(context)`
/// 取，单测直接构造容器——两条路径执行同一份逻辑。
abstract final class ProtectedStateWipe {
  /// 被擦除覆盖的 Provider 清单（诊断/测试对照用）。
  static const List<String> coveredProviders = [
    'deviceListProvider',
    'activeTabProvider',
    'activeSessionProvider',
    'sessionIndexProvider',
    'sessionStatusProvider',
    'eventFeedProvider',
    'observerStatsProvider',
    'bridgeHealthProvider',
    'warmupMemoryProvider',
    'pendingSessionJumpProvider',
  ];

  /// 执行擦除；任一步失败即抛出（调用方保持锁定）。
  static Future<void> run(ProviderContainer container) async {
    // 1) 内存态：同步执行，await 之前凭证已从所有 state 不可达。
    container.read(deviceListProvider.notifier).clearAll();
    container.read(activeSessionProvider.notifier).clearAll();
    container.read(sessionIndexProvider.notifier).clearAll();
    container.read(sessionStatusProvider.notifier).clearAll();
    container.read(eventFeedProvider.notifier).clearAll();
    container.read(observerStatsProvider.notifier).clear();
    container.read(bridgeHealthProvider.notifier).clear();
    container.read(pendingSessionJumpProvider.notifier).clear();
    container.read(warmupMemoryProvider.notifier).clearAll();
    container.read(activeTabProvider.notifier).reset();

    // 2) 磁盘：设备凭证、索引、warmup 脚本、最近设备指针。
    //    失败即抛出（secure storage 是凭证本体，必须证明删除完成）。
    await DeviceStore.instance.clearAll();

    // 3) WebView 站点数据：逐域清理、如实记录，不谎报。
    await WebViewStorage.clearAllSiteData(reason: 'protected_wipe');

    // 4) 系统通知（payload 带设备/会话 id）：尽力撤销 + 如实记录。
    //
    //    为什么这里不做硬失败：插件没有任何"查询当前通知栏"的 API，撤销
    //    结果在 Dart 侧**本来就无法复核**；把它当硬失败只会在"唯一免验证
    //    出路"上制造新的死锁（通知插件不可用的环境里用户将被永久锁死，
    //    与 R-02/R-03 要修的问题同类）。失败按原因留痕，残余风险记为
    //    "旧通知可能留在通知栏直至用户清除/系统回收"。
    try {
      await NotifierService.instance.cancelAll();
    } catch (e) {
      logWipeFailure(e, 'notify_cancel');
    }
  }
}

/// 擦除失败的结构化记录（只记原因标签与异常摘要，不记内容）。
void logWipeFailure(Object error, String reason) {
  AppLog.failure(
    LogEvent.protectedDataWipeFailed,
    error,
    fields: {LogField.reason: reason},
  );
}

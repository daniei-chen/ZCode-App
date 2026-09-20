import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/app_log.dart';
import '../services/device_connectivity.dart';
import '../services/device_store.dart';
import '../services/notifier.dart';
import '../services/structured_log.dart';
import '../services/warmup.dart';
import '../services/webview_storage.dart';
import '../services/wipe_result.dart';
import 'active_session.dart';
import 'bridge_health.dart';
import 'event_feed.dart';
import 'event_history.dart';
import 'observer_stats.dart';
import 'pending_session_jump.dart';
import 'session_index.dart';
import 'session_pool.dart';
import 'session_status.dart';
import 'subframe_stats.dart';

/// 受保护状态擦除事务（R-04，失败语义按 R-17 / b4 复审修正）。
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
/// **失败语义（fail-closed，b4 复审修正）**：每一步都产出
/// [WipeStepResult]；调用方**只有**在 [WipeResult.allRequiredSucceeded]
/// 为 true 时才允许关闭门禁。旧实现只对磁盘路径 fail-closed——站点数据与
/// 通知撤销各自吞掉失败后照样放行，与交接报告的表述不符（复审 P1-03）。
/// 失败原因只记机器标签，不记录任何正文/凭证。
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
    'eventHistoryProvider',
    'observerStatsProvider',
    'subFrameStatsProvider',
    'bridgeHealthProvider',
    'warmupMemoryProvider',
    'pendingSessionJumpProvider',
    'deviceConnectivityProvider',
    'deviceStoreIntegrityProvider',
  ];

  /// 执行擦除并返回逐项结果；**不抛异常**（失败在返回值里）。
  ///
  /// 调用方必须检查 [WipeResult.allRequiredSucceeded]：false 意味着存在
  /// 残留（或无法证明已清除），保持锁定并允许重试。
  static Future<WipeResult> run(ProviderContainer container) async {
    final steps = <WipeStepResult>[];

    // 1) 内存态：同步执行，await 之前凭证已从所有 state 不可达。
    //    这一步异常极少（state 赋值），但同样如实记账。
    var providersOk = false;
    try {
      container.read(deviceListProvider.notifier).clearAll();
      container.read(activeSessionProvider.notifier).clearAll();
      container.read(sessionIndexProvider.notifier).clearAll();
      container.read(sessionStatusProvider.notifier).clearAll();
      container.read(eventFeedProvider.notifier).clearAll();
      // 事件历史含会话标题/摘要（升级路线图待处理中心），随擦除事务清除。
      container.read(eventHistoryProvider.notifier).clearAll();
      container.read(observerStatsProvider.notifier).clear();
      container.read(subFrameStatsProvider.notifier).clear();
      container.read(bridgeHealthProvider.notifier).clear();
      container.read(pendingSessionJumpProvider.notifier).clear();
      container.read(warmupMemoryProvider.notifier).clearAll();
      container.read(deviceConnectivityProvider.notifier).clear();
      // 设备库完整性计数同生命周期（iter12 复核 P3）：擦除后不带上一轮的
      // repaired/隔离计数。
      container.read(deviceStoreIntegrityProvider.notifier).clear();
      container.read(activeTabProvider.notifier).reset();
      providersOk = true;
    } catch (_) {
      providersOk = false;
    }
    steps.add(WipeStepResult(
      step: WipeStep.providers,
      ok: providersOk,
      reason: providersOk ? null : 'providers_clear_failed',
    ));

    // 2) 磁盘：设备凭证、索引、warmup 脚本、最近设备指针。
    //    clearAll 内部已把两者都删；这里按"凭证本体"与"最近设备指针"分别
    //    记账（指针由同一调用覆盖，失败一并反映）。
    var storeOk = false;
    try {
      await DeviceStore.instance.clearAll();
      storeOk = true;
    } catch (_) {
      storeOk = false;
    }
    steps.add(WipeStepResult(
      step: WipeStep.secureStorage,
      ok: storeOk,
      reason: storeOk ? null : 'secure_storage_clear_failed',
    ));
    steps.add(WipeStepResult(
      step: WipeStep.lastDevice,
      ok: storeOk,
      reason: storeOk ? null : 'last_device_clear_failed',
    ));

    // 3) WebView 站点数据：逐域结果（R-17）。
    final siteSteps = await WebViewStorage.clearAllSiteData(
      reason: 'protected_wipe',
    );
    steps.addAll(siteSteps);

    // 4) 系统通知（payload 带设备/会话 id）。
    //    契约：成功 = 撤销**请求已提交**（插件无查询 API，无法证明系统通知
    //    已不存在）；抛错 = 未完成 → 保持锁定并可重试。
    var notifyOk = false;
    try {
      await NotifierService.instance.cancelAll();
      notifyOk = true;
    } catch (e) {
      notifyOk = false;
      logWipeFailure(e, 'notify_cancel');
    }
    steps.add(WipeStepResult(
      step: WipeStep.notifications,
      ok: notifyOk,
      reason: notifyOk ? null : 'notify_cancel_failed',
    ));

    final result = WipeResult(steps);
    if (!result.allRequiredSucceeded) {
      AppLog.event(
        LogEvent.protectedDataWipeFailed,
        level: LogLevel.warn,
        fields: {
          LogField.reason: 'wipe_incomplete',
          LogField.count: result.failedSteps.length,
        },
      );
    }
    return result;
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

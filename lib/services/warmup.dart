import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'device_store.dart';
import 'event_observer.dart';
import 'link_builder.dart';
import 'app_log.dart';
import 'structured_log.dart';

/// 预热请求签名 —— 从远控页面录到的 fetch 调用（面板数据都是按需拉取的，
/// 录下来下次进 App 时重放，让工作台打开即有数据）。
class WarmupRequest {
  const WarmupRequest({required this.url, required this.method, this.body});

  final String url;

  final String method;

  final String? body;

  Map<String, dynamic> toJson() => {'u': url, 'm': method, 'b': body};

  static WarmupRequest? fromJson(Map<String, dynamic> json) {
    final u = json['u'];
    final m = json['m'];
    if (u is! String || u.isEmpty) return null;
    if (m is! String || m.isEmpty) return null;
    final b = json['b'];
    return WarmupRequest(
      url: u,
      method: m,
      body: b is String && b.isNotEmpty ? b : null,
    );
  }

  String get dedupeKey => '$method $url ${body ?? ''}';
}

/// 允许预热的只读面板路径段。
///
/// 这是有意比面板解析器更窄的名单：解析器可以容错扫描任意事件，
/// 预热却会主动发请求，不能因为 URL 中出现一个模糊关键词就重放。
const _readOnlyPanelSegments = <String>{
  'provider',
  'providers',
  'model',
  'models',
  'model-provider',
  'model-providers',
  'entitlement',
  'entitlements',
  'quota',
  'quotas',
  'usage',
  'usage-stats',
  'codingplan',
  'coding-plan',
  'subagent',
  'subagents',
  'skill',
  'skills',
  'mcp',
  'mcp-sync',
  'plugin',
  'plugins',
  'command',
  'commands',
  'hook',
  'hooks',
  'memory',
  'memories',
};

const int _maxRequests = 48;
const int _maxBodyBytes = 16 * 1024;

/// 按设备累积录制到的面板请求；进 App 后在页面加载完成时重放。
class WarmupMemoryNotifier extends Notifier<Map<String, List<WarmupRequest>>> {
  final Map<String, Timer> _persistTimers = {};

  /// 每设备写纪元（iter16 复核返修）：[forget]（设备删除）时递增。
  /// `load` 的存储读跨越"该设备已被删除"边界时作废——擦除纪元只挡住
  /// wipe，remove→forget 期间在途的读仍会把已删设备的预热脚本写回内存。
  final Map<String, int> _deviceEpoch = {};

  /// 擦除纪元（iter16）：[clearAll] 递增。`load` 的存储读结果跨越擦除
  /// 边界时作废——否则擦除清空内存态之后到达的读结果会把已清除设备的
  /// 预热脚本重新写回内存（预热脚本按敏感数据对待，见 DeviceStore）。
  int _wipeEpoch = 0;

  @override
  Map<String, List<WarmupRequest>> build() => const {};

  /// 恢复上次录制的内容（页面加载前调用）。
  Future<void> load(String deviceId) async {
    if (state.containsKey(deviceId)) return;
    final epoch = _wipeEpoch;
    final deviceEpoch = _deviceEpoch[deviceId] ?? 0;
    final raw = await DeviceStore.instance.warmupScript(deviceId);
    // await 之后、写 state 之前的三道守卫（iter16；与 session_pool/
    // device_connectivity 的 await 后守卫同口径）：
    // 1) provider 已销毁不得写 state；2) 读期间发生过擦除则整个结果作废；
    // 3) 读期间该设备被删除（forget 推了它的纪元）同样作废。
    if (!ref.mounted) return;
    if (epoch != _wipeEpoch) return;
    if ((_deviceEpoch[deviceId] ?? 0) != deviceEpoch) return;
    if (raw == null || raw.isEmpty) return;
    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => WarmupRequest.fromJson(e as Map<String, dynamic>))
          .whereType<WarmupRequest>()
          .where(_shouldRecord)
          .toList();
      if (list.isEmpty) return;
      state = {...state, deviceId: list};
    } catch (e) {
      AppLog.failure(
        LogEvent.warmupLoadFailed,
        e,
        fields: {LogField.reason: 'warmup_load'},
      );
    }
  }

  /// 接收页面钩子录到的请求签名（zrSeen 通道）。
  void ingestSeen(String deviceId, String body) {
    if (body.isEmpty) return;
    if (!seenBatchWithinBudget(body)) return;
    List<dynamic> raw;
    try {
      raw = jsonDecode(body) as List<dynamic>;
    } catch (_) {
      return;
    }
    final current = state[deviceId] ?? const <WarmupRequest>[];
    final seen = {for (final r in current) r.dedupeKey};
    final merged = [...current];
    var changed = false;
    for (final item in raw) {
      if (item is! Map) continue;
      final req = WarmupRequest.fromJson(Map<String, dynamic>.from(item));
      if (req == null) continue;
      if (!_shouldRecord(req)) continue;
      if (seen.contains(req.dedupeKey)) continue;
      seen.add(req.dedupeKey);
      // 新请求放最前面：重放时优先覆盖旧响应。
      merged.insert(0, req);
      changed = true;
    }
    if (!changed) return;
    final trimmed = merged.take(_maxRequests).toList();
    state = {...state, deviceId: trimmed};
    _schedulePersist(deviceId, trimmed);
  }

  Future<void> forget(String deviceId) async {
    // 推纪元：作废在途 load 的写回（iter16 复核返修）。
    _deviceEpoch[deviceId] = (_deviceEpoch[deviceId] ?? 0) + 1;
    _persistTimers.remove(deviceId)?.cancel();
    if (state.containsKey(deviceId)) {
      state = Map.of(state)..remove(deviceId);
    }
    try {
      await DeviceStore.instance.setWarmupScript(deviceId, null);
    } catch (e) {
      if (e is DeviceStoreSuperseded) {
        // 被擦除作废是预期行为（iter10 F-4）：记 info 留痕即可，不是失败。
        AppLog.event(
          LogEvent.warmupPersistFailed,
          fields: {LogField.reason: 'superseded_by_wipe'},
        );
        return;
      }
      // 内存态已清除；安全存储删除失败只影响持久化残留，不阻塞调用方。
      AppLog.failure(
        LogEvent.warmupPersistFailed,
        e,
        fields: {LogField.reason: 'warmup_forget'},
      );
    }
  }

  /// 擦除事务（R-04）：取消**全部**待写定时器并清空内存态。
  ///
  /// 必须同步执行：任何在途的 3 秒延时写入都要作废，否则擦除后计时器到期
  /// 会把已删除设备的 warmup 脚本（含请求签名）重新写回安全存储。
  /// 磁盘侧 warmup 键由 `DeviceStore.clearAll` 在同一事务里删除。
  void clearAll() {
    _wipeEpoch++;
    for (final timer in _persistTimers.values) {
      timer.cancel();
    }
    _persistTimers.clear();
    if (state.isEmpty) return;
    state = const {};
  }

  /// zrSeen 批次预算的第二道门（iter16）：钩子侧 `recordSeen` 保证单批
  /// JSON 的 UTF-8 字节 ≤ [kMaxSeenBatchBytes]，这里用**同一常量**复核；
  /// 旧实现三处口径各写一份（旧桥侧 512 KiB / 本处 256 KiB / 钩子 4 MiB），
  /// 超限批次会在桥侧被整批丢弃。边界含等号（预算内放行）。
  static bool seenBatchWithinBudget(String body) =>
      utf8.encode(body).length <= kMaxSeenBatchBytes;

  static bool _shouldRecord(WarmupRequest req) {
    if (req.url.length > 2048) return false;
    if (req.body != null && req.body!.length > _maxBodyBytes) return false;

    // Warmup 只能重放明确的只读 GET/HEAD。尤其不能把“看起来像面板”的
    // POST 当成读取接口：面板请求签名不稳定，误判后可能重复执行写操作。
    final method = req.method.toUpperCase();
    if (method != 'GET' && method != 'HEAD') return false;
    if (req.body != null) return false;

    final uri = Uri.tryParse(req.url);
    if (uri == null) return false;
    if (uri.hasScheme && !LinkBuilder.isTrustedUri(uri)) return false;
    if ((!uri.hasScheme && !uri.path.startsWith('/')) ||
        uri.path.startsWith('//')) {
      return false;
    }
    // query/fragment 不收录（iter12 N-P3-2）：query 会随 URL 原样进安全
    // 存储并被重放，语义上超出"只读资源路径"的建档范围（搜索词、分页
    // 参数等用户输入都在这里）。损失部分面板资源的预热覆盖，换取建档
    // 面与项目"只存路径不存内容"的红线一致。
    if (uri.query.isNotEmpty || uri.fragment.isNotEmpty) return false;

    // 只收录路径中包含明确面板资源段的只读资源；settings/config 以及
    // 其他模糊命中故意不在名单内，避免把配置接口误认为读取接口。
    final segments = uri.path
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map((segment) => segment.toLowerCase())
        .toSet();
    return segments.any(_readOnlyPanelSegments.contains);
  }

  void _schedulePersist(String deviceId, List<WarmupRequest> list) {
    _persistTimers.remove(deviceId)?.cancel();
    _persistTimers[deviceId] = Timer(const Duration(seconds: 3), () async {
      try {
        final json = jsonEncode([for (final r in list) r.toJson()]);
        await DeviceStore.instance.setWarmupScript(deviceId, json);
      } catch (e) {
        if (e is DeviceStoreSuperseded) {
          // 被擦除作废是预期行为（iter10 N-1，与 forget 的 catch 同口径）：
          // 记 info 留痕即可，不是持久化失败。
          AppLog.event(
            LogEvent.warmupPersistFailed,
            fields: {LogField.reason: 'superseded_by_wipe'},
          );
          return;
        }
        AppLog.failure(
          LogEvent.warmupPersistFailed,
          e,
          fields: {LogField.reason: 'warmup_persist'},
        );
      }
    });
  }
}

final warmupMemoryProvider =
    NotifierProvider<WarmupMemoryNotifier, Map<String, List<WarmupRequest>>>(
      WarmupMemoryNotifier.new,
    );

/// 重放脚本：在页面上下文里按录制顺序补发面板请求。
/// 相对路径自动落在当前 origin，凭证走 cookie（credentials: include）。
abstract final class WarmupReplay {
  static String script(List<WarmupRequest> requests) {
    final safe = requests.where(WarmupMemoryNotifier._shouldRecord).toList();
    if (safe.isEmpty) return '';
    final payload = jsonEncode([
      for (final r in safe) {'u': r.url, 'm': r.method, 'b': r.body},
    ]);
    return '''
(function(reqs){
  if (window.__zrWarmed) return;
  window.__zrWarmed = true;
  var i = 0;
  var next = function(){
    if (i >= reqs.length) return;
    var r = reqs[i++];
    try {
      var target = new URL(r.u, location.href);
      var method = String(r.m || 'GET').toUpperCase();
      if (target.origin !== location.origin || (method !== 'GET' && method !== 'HEAD')) {
        return;
      }
      fetch(target.href, { method: method, credentials: 'include' }).catch(function(){});
    } catch (e) {}
    setTimeout(next, 140);
  };
  setTimeout(next, 1800);
})($payload);
''';
  }
}

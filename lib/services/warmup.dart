import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'device_store.dart';
import 'link_builder.dart';

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

  @override
  Map<String, List<WarmupRequest>> build() => const {};

  /// 恢复上次录制的内容（页面加载前调用）。
  Future<void> load(String deviceId) async {
    if (state.containsKey(deviceId)) return;
    final raw = await DeviceStore.instance.warmupScript(deviceId);
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
      debugPrint('[ZR] warmup load failed: $e');
    }
  }

  /// 接收页面钩子录到的请求签名（zrSeen 通道）。
  void ingestSeen(String deviceId, String body) {
    if (body.isEmpty || body.length > 256 * 1024) return;
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
    _persistTimers.remove(deviceId)?.cancel();
    if (state.containsKey(deviceId)) {
      state = Map.of(state)..remove(deviceId);
    }
    await DeviceStore.instance.setWarmupScript(deviceId, null);
  }

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
        debugPrint('[ZR] warmup persist failed: $e');
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

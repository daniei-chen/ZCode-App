/// 设备列表连通性指示（用户需求：可联通绿点 / 不可联通橙点）。
///
/// 两个信号源，强信号优先：
/// 1. **relay 实流**（`SessionStatus.live`）：观察面真的收到该设备的
///    数据帧——这是"可联通"的最强证据，无需再探测；
/// 2. **源站探测**：对控制链接同路径（去 query）发一次无凭证 GET（任何
///    HTTP 响应都算可达——只验证网络链路，不验证鉴权、不建立会话）。
///
/// 都没有（页面从未打开、探测尚未完成）→ `unknown`，UI 保持原有
/// "连接中"色。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device.dart';
import 'link_builder.dart';
import '../state/session_status.dart';

enum DeviceLinkState { reachable, unreachable, unknown }

enum ProbeOutcome { ok, failed }

abstract final class DeviceConnectivityPolicy {
  /// 组合两个信号源为链路状态。relay 实流优先于探测结果。
  static DeviceLinkState state({
    required SessionStatus? sessionStatus,
    required ProbeOutcome? probe,
  }) {
    if (sessionStatus == SessionStatus.live) {
      return DeviceLinkState.reachable;
    }
    if (probe == ProbeOutcome.ok) return DeviceLinkState.reachable;
    if (probe == ProbeOutcome.failed) return DeviceLinkState.unreachable;
    return DeviceLinkState.unknown;
  }

  /// 探测目标 = 控制链接本身的路径（`https://host/remote/vN`），**不带**
  /// query/fragment（sid/hash 等凭证不随探测发送）。host 与端口来自导入时
  /// 已校验的白名单链接（isTrustedOrigin 恒 https+443）。iter12 N-P2-2：
  /// 此前打的是裸 host 根路径，官方若下线 /remote/v4 但保留站点根，绿点会
  /// 与真实远控页可用性背离——探测目标跟随设备语义。
  static Uri probeUri(RemoteDevice device) {
    final base = Uri.tryParse(device.baseUrl);
    if (base == null || !LinkBuilder.isTrustedOrigin(base)) {
      return Uri.https('invalid.probe', '/');
    }
    return Uri(
      scheme: 'https',
      host: base.host,
      port: 443,
      path: base.path.isEmpty ? '/' : base.path,
    );
  }
}

class ConnectivityProbe {
  ConnectivityProbe({Future<ProbeOutcome> Function(Uri uri)? fetch})
    : _fetch = fetch ?? defaultFetch;

  final Future<ProbeOutcome> Function(Uri uri) _fetch;

  /// 单次探测超时：连接 + 响应各自受它约束。
  static const timeout = Duration(seconds: 5);

  Future<ProbeOutcome> probe(RemoteDevice device) =>
      _fetch(DeviceConnectivityPolicy.probeUri(device));

  /// 默认实现：任何 HTTP 响应（含 4xx/5xx）= 网络可达；超时/DNS/TLS
  /// 错误 = 不可达。credentials 不参与探测。坏证书默认拒绝（不设回调）。
  static Future<ProbeOutcome> defaultFetch(Uri uri) async {
    if (!LinkBuilder.isTrustedOrigin(uri)) return ProbeOutcome.failed;
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client
          .openUrl('GET', uri)
          .timeout(timeout);
      final response = await request.close().timeout(timeout);
      await response.drain<void>().timeout(timeout);
      return ProbeOutcome.ok;
    } catch (_) {
      return ProbeOutcome.failed;
    } finally {
      client.close(force: true);
    }
  }
}

/// 设备 id → 最近一次探测结果。UI 用 [DeviceConnectivityPolicy.state]
/// 与 relay 状态组合出点的颜色。
class DeviceConnectivityNotifier
    extends Notifier<Map<String, ProbeOutcome>> {
  @override
  Map<String, ProbeOutcome> build() => const {};

  ConnectivityProbe probe = ConnectivityProbe();

  bool _inFlight = false;

  /// 本轮探测期间被 forget 的设备（iter16）：写回时跳过，否则 remove 的
  /// 清理之后旧轮次会把已删设备的结果重新插回 provider。轮次结束清空。
  final Set<String> _forgottenInFlight = {};

  /// 本轮探测期间发生过 clear()（擦除事务）：写回整体作废（iter16 复核
  /// 返修——擦除后不得再落任何探测结果）。
  bool _wipedInFlight = false;

  /// 对设备清单做一轮探测。relay 已 live 的设备直接记可达（不发探测）；
  /// 其余并发探测（设备数上限受导入约束，量级个位数）。
  ///
  /// in-flight 去重（iter10 复核 F-6/W-024）：5 秒超时窗口内快速进出
  /// 启动器会重挂触发器，重叠轮只浪费网络且后到结果会覆盖更新的——
  /// 已有轮在跑时本轮直接跳过（下一轮揭盖会再触发）。
  Future<void> probeAll(
    List<RemoteDevice> devices,
    Map<String, SessionStatus> statuses,
  ) async {
    if (_inFlight) return;
    _inFlight = true;
    try {
      final results = await Future.wait([
        for (final device in devices) _probeOne(device, statuses[device.id]),
      ]);
      if (!ref.mounted) return;
      // 擦除事务在探测期间到达：本轮结果整体作废（不得写回任何设备）。
      if (_wipedInFlight) return;
      final merged = Map.of(state);
      for (final r in results) {
        if (_forgottenInFlight.remove(r.$1)) continue;
        merged[r.$1] = r.$2;
      }
      state = merged;
    } finally {
      _forgottenInFlight.clear();
      _wipedInFlight = false;
      _inFlight = false;
    }
  }

  Future<(String, ProbeOutcome)> _probeOne(
    RemoteDevice device,
    SessionStatus? status,
  ) async {
    if (status == SessionStatus.live) {
      return (device.id, ProbeOutcome.ok);
    }
    final outcome = await probe.probe(device);
    return (device.id, outcome);
  }

  /// 设备删除/换凭证时同步清理（与其它遥测同生命周期）。
  ///
  /// 两个调用点：`session_pool.remove`（删除）与 `session_pool.replaceLink`
  /// （换凭证后 probeUri 的 path 可能变化，旧结果不再代表当前链接）。
  /// 在途轮次的写回也要跳过（iter16）：标记后由本轮合并时丢弃。
  void forget(String deviceId) {
    if (_inFlight) _forgottenInFlight.add(deviceId);
    if (!state.containsKey(deviceId)) return;
    state = Map.of(state)..remove(deviceId);
  }

  /// 擦除事务（R-04）：清空全部探测结果。在途轮次同样作废（iter16 复核
  /// 返修）：擦除之后到达的结果不得把已删设备写回 provider。
  void clear() {
    if (_inFlight) _wipedInFlight = true;
    state = const {};
  }
}

final deviceConnectivityProvider =
    NotifierProvider<DeviceConnectivityNotifier, Map<String, ProbeOutcome>>(
      DeviceConnectivityNotifier.new,
    );

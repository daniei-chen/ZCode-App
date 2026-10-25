import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../services/app_log.dart';
import '../services/relay_credentials.dart';
import '../services/structured_log.dart';

/// 账号设备目录（v1.5.0）——官方"选择电脑"页的同款数据源。
///
/// 端点与响应形状逆向自官方 3.16.3 页面 bundle（zod schema 模块）：
/// `GET https://zcode.z.ai/api/v1/remote/device`，`Authorization: Bearer <JWT>`
/// → `{code:0, msg, data:[{device_sid, device_mid, online, created_at,
///    meta:{name?, platform?, version?}}]}`
///
/// 官方页面按 `online` 分组在线/离线并显示绿点——同一个字段就是首页
/// "探活"的权威来源。401 = 登录过期（authExpired 态，UI 引导重新登录）。
class AccountDevice {
  const AccountDevice({
    required this.sid,
    required this.mid,
    required this.online,
    this.createdAt,
    this.name,
    this.platform,
  });

  final String sid;
  final String mid;
  final bool online;

  final int? createdAt;
  final String? name;
  final String? platform;

  String get displayName => (name ?? '').trim().isNotEmpty
      ? name!.trim()
      : 'PC ${mid.length >= 8 ? mid.substring(0, 8) : mid}';

  static AccountDevice? fromJson(Map<dynamic, dynamic> json) {
    final sid = json['device_sid'];
    final mid = json['device_mid'];
    if (sid is! String || sid.isEmpty || mid is! String || mid.isEmpty) {
      return null;
    }
    final meta = json['meta'];
    String? metaString(String key) => meta is Map && meta[key] is String
        ? meta[key] as String
        : null;
    final created = json['created_at'];
    return AccountDevice(
      sid: sid,
      mid: mid,
      online: json['online'] == true,
      createdAt: created is int ? created : null,
      name: metaString('name'),
      platform: metaString('platform'),
    );
  }
}

enum DeviceDirectoryStatus {
  /// 还没登录过（无 JWT）。
  signedOut,

  loading,

  ready,

  /// JWT 失效（服务端 401）——UI 引导重新登录。
  authExpired,

  error,
}

class DeviceDirectoryState {
  const DeviceDirectoryState({
    required this.status,
    this.devices = const [],
    this.updatedAt,
  });

  final DeviceDirectoryStatus status;
  final List<AccountDevice> devices;
  final DateTime? updatedAt;

  DeviceDirectoryState copyWith({
    DeviceDirectoryStatus? status,
    List<AccountDevice>? devices,
    DateTime? updatedAt,
  }) => DeviceDirectoryState(
    status: status ?? this.status,
    devices: devices ?? this.devices,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

class DeviceDirectoryNotifier
    extends Notifier<DeviceDirectoryState> {
  Timer? _timer;

  static const _endpoint = 'https://zcode.z.ai/api/v1/remote/device';

  /// 探活轮询间隔：官方页 visibilitychange 即刷；原生端固定 30s 折中。
  static const pollInterval = Duration(seconds: 30);

  @override
  DeviceDirectoryState build() {
    ref.onDispose(() => _timer?.cancel());
    unawaited(refresh());
    _timer = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
    return const DeviceDirectoryState(status: DeviceDirectoryStatus.loading);
  }

  Future<void> refresh() async {
    final jwt = await RelayCredentials.loadJwt();
    if (jwt == null || jwt.isEmpty) {
      if (state.status != DeviceDirectoryStatus.signedOut) {
        state = state.copyWith(status: DeviceDirectoryStatus.signedOut);
      }
      return;
    }
    try {
      final response = await http
          .get(
            Uri.parse(_endpoint),
            headers: {'Authorization': 'Bearer $jwt'},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 401) {
        state = state.copyWith(status: DeviceDirectoryStatus.authExpired);
        return;
      }
      if (response.statusCode != 200) {
        state = state.copyWith(status: DeviceDirectoryStatus.error);
        return;
      }
      final devices = parse(response.body);
      if (devices == null) {
        state = state.copyWith(status: DeviceDirectoryStatus.error);
        return;
      }
      state = DeviceDirectoryState(
        status: DeviceDirectoryStatus.ready,
        devices: devices,
        updatedAt: DateTime.now(),
      );
    } catch (e) {
      AppLog.failure(LogEvent.directoryFetchFailed, e, fields: {
        LogField.reason: 'device_list',
      });
      if (state.status == DeviceDirectoryStatus.ready) {
        // 已有数据时网络抖动不清列表（探活绿点保持旧值，下次轮询自愈）。
        return;
      }
      state = state.copyWith(status: DeviceDirectoryStatus.error);
    }
  }

  /// 解析 `{code:0, data:[…]}`；code≠0 或结构不符返回 null。
  @visibleForTesting
  static List<AccountDevice>? parse(String body) {
    try {
      final root = jsonDecode(body);
      if (root is! Map) return null;
      final code = root['code'];
      final data = root['data'];
      if (code != 0 || data is! List) return null;
      final devices = <AccountDevice>[];
      for (final item in data) {
        if (item is Map) {
          final device = AccountDevice.fromJson(item);
          if (device != null) devices.add(device);
        }
      }
      return devices;
    } catch (_) {
      return null;
    }
  }
}

final deviceDirectoryProvider =
    NotifierProvider<DeviceDirectoryNotifier, DeviceDirectoryState>(
      DeviceDirectoryNotifier.new,
    );

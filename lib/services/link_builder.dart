import 'dart:core';

import 'package:uuid/uuid.dart';

import '../models/device.dart';

class LinkBuilder {
  static const _sidKey = 'sid';
  static const _hashKey = 'hash';
  static const _tKey = 't';
  static const _nameKey = 'name';

  /// WebView/Native bridge 目前只信任官方远控 origin。
  ///
  /// 自定义 relay 仍可在底层协议测试中显式构造 [RelayLink]，但不能通过
  /// 用户可触发的扫码/粘贴入口获得同等的高权限 WebView bridge。
  static const trustedHosts = <String>{'zcode.z.ai'};

  static bool isTrustedUri(Uri? uri) {
    if (uri == null || uri.scheme.toLowerCase() != 'https') return false;
    if (uri.host.isEmpty || uri.userInfo.isNotEmpty) return false;
    return trustedHosts.contains(uri.host.toLowerCase());
  }

  static bool isTrustedOrigin(String raw) {
    final uri = Uri.tryParse(raw.trim());
    return isTrustedUri(uri);
  }

  static bool isTrustedDevice(RemoteDevice device) {
    final base = Uri.tryParse(device.baseUrl);
    if (!isTrustedUri(base)) return false;
    for (final key in const ['origin', 'relayOrigin']) {
      final value = device.params[key];
      if (value != null && value.isNotEmpty && !isTrustedOrigin(value)) {
        return false;
      }
    }
    return true;
  }

  static RemoteDevice? parse(
    String input, {
    String? id,
    DateTime? now,
    bool allowCustomOrigin = false,
  }) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (uri.host.isEmpty) return null;
    if (!allowCustomOrigin && !isTrustedUri(uri)) return null;

    final params = <String, String>{};
    uri.queryParameters.forEach((k, v) {
      if (k.isNotEmpty && v.isNotEmpty) params[k] = v;
    });

    final sid = params[_sidKey];
    final hash = params[_hashKey];
    final token = params['remoteControlToken'];
    final hasPair =
        sid != null && sid.isNotEmpty && hash != null && hash.isNotEmpty;
    final hasToken = token != null && token.isNotEmpty;
    if (!hasPair && !hasToken) return null;

    final base = uri.hasPort
        ? Uri(
            scheme: uri.scheme,
            userInfo: uri.userInfo,
            host: uri.host,
            port: uri.port,
            path: uri.path,
          )
        : Uri(
            scheme: uri.scheme,
            userInfo: uri.userInfo,
            host: uri.host,
            path: uri.path,
          );

    final label = params[_nameKey];
    return RemoteDevice(
      id: id ?? const Uuid().v4(),
      baseUrl: base.toString(),
      params: params,
      label: label ?? '',
      createdAt: now ?? DateTime.now(),
    );
  }

  static Uri buildUrl(RemoteDevice device, {DateTime? now}) {
    final params = Map<String, String>.of(device.params);
    params[_tKey] = (now ?? DateTime.now()).millisecondsSinceEpoch.toString();
    return Uri.parse(device.baseUrl).replace(queryParameters: params);
  }
}

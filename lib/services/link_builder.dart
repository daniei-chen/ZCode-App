import 'dart:core';
import 'dart:io';

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

  /// 出站端点的第二道防线：拒绝环回、私网与保留地址。
  ///
  /// [trustedHosts] 精确白名单已把可导入设备限制在官方 origin；本检查
  /// 独立于白名单，保证将来白名单放宽（或自定义 origin 被显式打开）时，
  /// relay 连接也到不了本机/内网/保留地址。
  static bool isPublicEndpoint(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'wss') return false;
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return false;
    if (host == 'localhost' || host.endsWith('.localhost')) return false;
    final address = InternetAddress.tryParse(host);
    if (address == null) return true;
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return false;
    }
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) return _isPublicIPv4(bytes);
    // IPv4-mapped IPv6（::ffff:0:0/96）按内嵌 IPv4 判定。
    var v4Mapped = true;
    for (var i = 0; i < 12; i++) {
      if (bytes[i] != (i < 10 ? 0 : 0xff)) {
        v4Mapped = false;
        break;
      }
    }
    if (v4Mapped) return _isPublicIPv4(bytes.sublist(12));
    // 未指定地址 ::
    if (bytes.every((b) => b == 0)) return false;
    // 唯一本地 fc00::/7
    if ((bytes[0] & 0xfe) == 0xfc) return false;
    // 文档段 2001:db8::/32
    if (bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d &&
        bytes[3] == 0xb8) {
      return false;
    }
    return true;
  }

  static bool _isPublicIPv4(List<int> bytes) {
    final o1 = bytes[0];
    final o2 = bytes[1];
    final o3 = bytes[2];
    return o1 != 0 &&
        o1 != 10 &&
        o1 != 127 &&
        !(o1 == 100 && o2 >= 64 && o2 < 128) &&
        !(o1 == 169 && o2 == 254) &&
        !(o1 == 172 && o2 >= 16 && o2 < 32) &&
        !(o1 == 192 && o2 == 168) &&
        !(o1 == 192 && o2 == 0 && o3 == 2) &&
        !(o1 == 198 && o2 >= 18 && o2 < 20) &&
        !(o1 == 198 && o2 == 51 && o3 == 100) &&
        !(o1 == 203 && o2 == 0 && o3 == 113) &&
        o1 < 224;
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

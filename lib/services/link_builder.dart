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

  /// 官方远控页面的 path 命名空间：/remote/v4、/remote/v5…（允许版本递进，
  /// 但不接受该命名空间以外的任何官方页面）。
  static final _remotePagePath = RegExp(r'^/remote/v\d+(/|$)');

  /// 可接受的链接文本上限（字符）：远超真实链接长度，同时挡住"粘贴一整篇
  /// 文档"这类输入（解析前的成本门禁，不是格式校验）。
  static const int maxLinkLength = 8192;

  /// Level 1：是否属于官方 origin。
  ///
  /// https + 官方 host + 无 userInfo + 默认端口（443；显式 :443 等价）。
  /// 只回答"是不是官方站点"，**不代表它可以拥有原生 bridge**。
  static bool isTrustedOrigin(Uri? uri) {
    if (uri == null || uri.scheme.toLowerCase() != 'https') return false;
    if (uri.host.isEmpty || uri.userInfo.isNotEmpty) return false;
    if (!trustedHosts.contains(uri.host.toLowerCase())) return false;
    // 拒绝显式非 443 端口；https 未写端口时 Uri.port 归一为 443。
    if (uri.port != 443) return false;
    return true;
  }

  /// 兼容旧调用名：Level 1 origin 检查。
  static bool isTrustedUri(Uri? uri) => isTrustedOrigin(uri);

  static bool isTrustedOriginString(String raw) {
    final uri = Uri.tryParse(raw.trim());
    return isTrustedOrigin(uri);
  }

  /// Level 2：是否是可以拥有原生 bridge 的官方远控页面（W1）。
  ///
  /// origin 合法 + path 落在 /remote/v<数字> 命名空间。官方站其他页面
  /// （首页、登录、帮助等）不得进入高权限容器——即使它们同属一个域。
  static bool isTrustedRemotePage(Uri? uri) {
    if (!isTrustedOrigin(uri)) return false;
    final path = uri!.path;
    // 防 path 归一化绕过：点段/空段一律拒绝（Uri 已做一次归一化，
    // 这里再兜一层防御）。
    if (path.contains('..') || path.contains('//')) return false;
    return _remotePagePath.hasMatch(path);
  }

  static bool isTrustedDevice(RemoteDevice device) {
    final base = Uri.tryParse(device.baseUrl);
    // 设备必须指向官方远控页面本身，而不只是官方 origin。
    if (!isTrustedRemotePage(base)) return false;
    for (final key in const ['origin', 'relayOrigin']) {
      final value = device.params[key];
      if (value != null && value.isNotEmpty && !isTrustedOriginString(value)) {
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
    // 长度门禁（F24）：真实控制链接只有几十到几百字符。粘贴/扫码入口不该
    // 接受任意大小的文本再去做 URI 解析与 query 展开。
    if (trimmed.length > maxLinkLength) return null;

    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (uri.host.isEmpty) return null;
    if (!allowCustomOrigin && !isTrustedRemotePage(uri)) return null;

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

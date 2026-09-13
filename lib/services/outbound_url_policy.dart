import 'link_builder.dart';

/// 出站请求 URL 策略（安全约束，适用于所有由应用发起的服务端请求）。
///
/// 规则（顺序即校验顺序）：
/// 1. 只允许 **https**（本应用的出站目标全部是 HTTPS；http 一律拒绝）；
/// 2. host 必须在白名单内（GitHub 官方域与其发布资产 CDN），不做通配；
/// 3. 若 host 是 IP 字面量（或 `localhost`），必须不是环回/私有/保留/链路本地/
///    组播/未指定地址——`LinkBuilder.isPublicEndpoint` 负责这一层（IPv4、
///    IPv4-mapped IPv6、ULA、文档段都覆盖）；
/// 4. **重定向逐跳校验**：调用方必须关掉客户端的自动跟随，用 [resolveRedirect]
///    验证每一跳，任一跳不合规就整体拒绝（否则白名单只挡得住第一跳）。
///
/// 说明：Dart 的 HTTP 客户端没有暴露"解析后的地址"，因此这里能证明的是
/// "host 是白名单域且不是私网 IP 字面量"；完整 DNS pinning 需要自定义
/// HttpClient/连接层，不在当前实现范围内（记为已知边界）。
abstract final class OutboundUrlPolicy {
  /// 允许的 host（全小写）。
  static const Set<String> allowedHosts = {
    'github.com',
    'api.github.com',
    'objects.githubusercontent.com',
    'release-assets.githubusercontent.com',
  };

  /// 单次请求允许的最大重定向跳数。
  static const int maxRedirects = 5;

  static bool isAllowed(Uri? uri) {
    if (uri == null) return false;
    if (uri.scheme.toLowerCase() != 'https') return false;
    if (!allowedHosts.contains(uri.host.toLowerCase())) return false;
    if (uri.userInfo.isNotEmpty) return false;
    if (uri.port != 443) return false;
    // 地址层：拒绝 localhost / IP 字面量里的环回、私有、保留、链路本地地址。
    return LinkBuilder.isPublicEndpoint(uri);
  }

  static String? rejectionReason(Uri? uri) {
    if (uri == null) return 'url_missing';
    if (uri.scheme.toLowerCase() != 'https') return 'scheme_not_https';
    if (!allowedHosts.contains(uri.host.toLowerCase())) return 'host_not_allowed';
    if (uri.userInfo.isNotEmpty) return 'userinfo_present';
    if (uri.port != 443) return 'port_not_443';
    if (!LinkBuilder.isPublicEndpoint(uri)) return 'address_not_public';
    return null;
  }

  /// 重定向跳转：只接受同一策略下的绝对/相对 Location；不可解析或不合规返回 null。
  static Uri? resolveRedirect(Uri current, Object? location) {
    if (location is! String || location.trim().isEmpty) return null;
    final raw = location.trim();
    final next = Uri.tryParse(raw);
    final resolved = next == null
        ? null
        : next.hasScheme
        ? next
        : current.resolve(raw);
    if (resolved == null) return null;
    return isAllowed(resolved) ? resolved : null;
  }
}

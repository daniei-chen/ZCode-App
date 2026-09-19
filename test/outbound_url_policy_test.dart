import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/outbound_url_policy.dart';

/// 出站请求 URL 策略：只允许 https + 白名单 host，并拒绝环回/私有/保留地址。
/// 任何"应用自己发起的服务端请求"都必须先过这里（更新检查、APK 下载、重定向）。
void main() {
  group('允许的目标', () {
    test('GitHub 官方域与其发布资产 CDN', () {
      for (final url in const [
        'https://github.com/2421873411a-rgb/ZCode-App/releases/download/v1.1.0/ZCode-v1.1.0.apk',
        'https://api.github.com/repos/2421873411a-rgb/ZCode-App/releases/latest',
        'https://objects.githubusercontent.com/github-production-release-asset/x?sig=y',
        'https://release-assets.githubusercontent.com/github-production-release-asset/x',
      ]) {
        expect(OutboundUrlPolicy.isAllowed(Uri.parse(url)), isTrue, reason: url);
        expect(OutboundUrlPolicy.rejectionReason(Uri.parse(url)), isNull);
      }
    });
  });

  group('拒绝的目标', () {
    test('非 https', () {
      expect(OutboundUrlPolicy.isAllowed(Uri.parse('http://github.com/x')), isFalse);
      expect(
        OutboundUrlPolicy.rejectionReason(Uri.parse('http://github.com/x')),
        'scheme_not_https',
      );
      expect(OutboundUrlPolicy.isAllowed(Uri.parse('ftp://github.com/x')), isFalse);
      // 显式 :443 的明文 scheme 不得因端口检查通过而蒙混（iter7 独立验收：
      // 删掉 scheme 检查时既有用例全绿——端口恰好掩盖了协议）。
      expect(
        OutboundUrlPolicy.isAllowed(Uri.parse('http://github.com:443/x')),
        isFalse,
      );
      expect(
        OutboundUrlPolicy.rejectionReason(Uri.parse('http://github.com:443/x')),
        'scheme_not_https',
      );
    });

    test('白名单之外的 host（含相似域与子域）', () {
      for (final url in const [
        'https://evil.com/x',
        'https://github.com.evil.com/x',
        'https://notgithub.com/x',
        'https://raw.githubusercontent.com/x',
        'https://codeload.github.com/x',
      ]) {
        expect(OutboundUrlPolicy.isAllowed(Uri.parse(url)), isFalse, reason: url);
        expect(
          OutboundUrlPolicy.rejectionReason(Uri.parse(url)),
          'host_not_allowed',
        );
      }
    });

    test('环回 / 私网 / 保留地址（即使 host 白名单里也没有这种写法）', () {
      for (final url in const [
        'https://127.0.0.1/x',
        'https://127.1.2.3:443/x',
        'https://10.0.0.1/x',
        'https://192.168.1.10/x',
        'https://172.16.5.5/x',
        'https://169.254.10.10/x',
        'https://100.64.1.1/x',
        'https://198.18.0.1/x',
        'https://0.0.0.0/x',
        'https://localhost/x',
        'https://localhost:443/x',
      ]) {
        expect(OutboundUrlPolicy.isAllowed(Uri.parse(url)), isFalse, reason: url);
      }
    });

    test('userinfo 与显式非 443 端口', () {
      expect(
        OutboundUrlPolicy.rejectionReason(
          Uri.parse('https://user:pw@github.com/x'),
        ),
        'userinfo_present',
      );
      expect(
        OutboundUrlPolicy.rejectionReason(
          Uri.parse('https://github.com:8443/x'),
        ),
        'port_not_443',
      );
    });

    test('null / 空 Location', () {
      expect(OutboundUrlPolicy.isAllowed(null), isFalse);
      expect(OutboundUrlPolicy.rejectionReason(null), 'url_missing');
      expect(
        OutboundUrlPolicy.resolveRedirect(Uri.parse('https://github.com/a'), null),
        isNull,
      );
      expect(
        OutboundUrlPolicy.resolveRedirect(Uri.parse('https://github.com/a'), ''),
        isNull,
      );
    });
  });

  group('重定向逐跳校验', () {
    test('相对 Location 按当前地址解析并放行', () {
      final next = OutboundUrlPolicy.resolveRedirect(
        Uri.parse('https://github.com/a/b'),
        '/c/d',
      );
      expect(next, Uri.parse('https://github.com/c/d'));
    });

    test('允许的重定向目标（GitHub → 资产 CDN）', () {
      final next = OutboundUrlPolicy.resolveRedirect(
        Uri.parse('https://github.com/x/y'),
        'https://objects.githubusercontent.com/github-production-release-asset/x?sig=y',
      );
      expect(next, isNotNull);
    });

    test('重定向到非白名单 / 私网地址一律拒绝', () {
      for (final location in const [
        'https://evil.com/payload.apk',
        'http://github.com/x',
        'https://127.0.0.1:443/x',
        'https://192.168.0.9/x',
        'https://localhost/x',
        'https://github.com:8443/x',
      ]) {
        expect(
          OutboundUrlPolicy.resolveRedirect(
            Uri.parse('https://github.com/a'),
            location,
          ),
          isNull,
          reason: location,
        );
      }
    });

    test('跳数上限是正数且有限（防止重定向环）', () {
      expect(OutboundUrlPolicy.maxRedirects, greaterThanOrEqualTo(1));
      expect(OutboundUrlPolicy.maxRedirects, lessThanOrEqualTo(10));
    });
  });
}

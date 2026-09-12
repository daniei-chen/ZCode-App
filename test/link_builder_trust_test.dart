import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/link_builder.dart';

/// W1 页面级信任模型测试：origin（Level 1）与远控页面（Level 2）分离。
void main() {
  Uri u(String s) => Uri.parse(s);

  group('Level 1 isTrustedOrigin', () {
    test('官方 origin 的合法形态', () {
      expect(
        LinkBuilder.isTrustedOrigin(u('https://zcode.z.ai/remote/v4')),
        isTrue,
      );
      expect(
        LinkBuilder.isTrustedOrigin(u('https://ZCODE.Z.AI/remote/v4')),
        isTrue,
      );
      expect(
        LinkBuilder.isTrustedOrigin(u('https://zcode.z.ai:443/remote/v4')),
        isTrue,
      );
    });

    test('非 https / 别家 host / userInfo / 非默认端口一律拒绝', () {
      expect(
        LinkBuilder.isTrustedOrigin(u('http://zcode.z.ai/remote/v4')),
        isFalse,
      );
      expect(
        LinkBuilder.isTrustedOrigin(u('https://evil.com/remote/v4')),
        isFalse,
      );
      expect(
        LinkBuilder.isTrustedOrigin(u('https://user@zcode.z.ai/remote/v4')),
        isFalse,
      );
      expect(
        LinkBuilder.isTrustedOrigin(u('https://zcode.z.ai:8443/remote/v4')),
        isFalse,
      );
      expect(LinkBuilder.isTrustedOrigin(null), isFalse);
    });
  });

  group('Level 2 isTrustedRemotePage', () {
    test('远控页面命名空间内的路径通过', () {
      for (final s in [
        'https://zcode.z.ai/remote/v4',
        'https://zcode.z.ai/remote/v4/',
        'https://zcode.z.ai/remote/v4/session/abc',
        'https://zcode.z.ai/remote/v4?sid=x&hash=y',
        'https://zcode.z.ai/remote/v4#frag',
        'https://zcode.z.ai/remote/v5',
      ]) {
        expect(LinkBuilder.isTrustedRemotePage(u(s)), isTrue, reason: s);
      }
    });

    test('官方站其他页面不享有高权限容器', () {
      for (final s in [
        'https://zcode.z.ai/',
        'https://zcode.z.ai/login',
        'https://zcode.z.ai/anything',
        'https://zcode.z.ai/remote',
        'https://zcode.z.ai/remote/v',
        'https://zcode.z.ai/remote/v4x',
      ]) {
        expect(LinkBuilder.isTrustedRemotePage(u(s)), isFalse, reason: s);
      }
    });

    test('归一化绕过一律拒绝', () {
      expect(
        LinkBuilder.isTrustedRemotePage(u('https://zcode.z.ai//remote/v4')),
        isFalse,
      );
      expect(
        LinkBuilder.isTrustedRemotePage(
          u('https://zcode.z.ai/remote/v4/../login'),
        ),
        isFalse,
      );
      expect(
        LinkBuilder.isTrustedRemotePage(u('https://zcode.z.ai/remote%2Fv4')),
        isFalse,
      );
      expect(
        LinkBuilder.isTrustedRemotePage(u('https://zcode.z.ai/REMOTE/V4')),
        isFalse,
      );
    });
  });

  group('isTrustedDevice 采用页面级判定', () {
    RemoteDevice dev(String baseUrl) => RemoteDevice(
      id: 'd',
      baseUrl: baseUrl,
      params: const {},
      label: '',
      createdAt: DateTime(2026),
    );

    test('远控页面 baseUrl 通过；官方站其他页面拒绝', () {
      expect(
        LinkBuilder.isTrustedDevice(dev('https://zcode.z.ai/remote/v4')),
        isTrue,
      );
      expect(LinkBuilder.isTrustedDevice(dev('https://zcode.z.ai/')), isFalse);
      expect(
        LinkBuilder.isTrustedDevice(dev('https://zcode.z.ai/login')),
        isFalse,
      );
    });
  });

  group('parse 只接受远控页面链接', () {
    test('远控链接通过', () {
      expect(
        LinkBuilder.parse('https://zcode.z.ai/remote/v4?sid=s&hash=h'),
        isNotNull,
      );
    });

    test('官方站非远控页面拒绝', () {
      expect(LinkBuilder.parse('https://zcode.z.ai/?sid=s&hash=h'), isNull);
      expect(
        LinkBuilder.parse('https://zcode.z.ai/login?sid=s&hash=h'),
        isNull,
      );
    });
  });
}

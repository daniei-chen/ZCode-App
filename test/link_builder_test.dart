import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/link_builder.dart';

void main() {
  const sampleUrl =
      'https://zcode.z.ai/remote/v4?sid=d_TestSid000000000000'
      '&hash=AbCdEf123%3D&t=1788059173414'
      '&mid=00000000-0000-4000-8000-000000000000'
      '&name=DESKTOP-ABC123&app_version=3.10.1';

  group('LinkBuilder.parse', () {
    test('官方链接：全部参数入库，label 取 name', () {
      final d = LinkBuilder.parse(sampleUrl)!;
      expect(d.sid, 'd_TestSid000000000000');
      expect(d.params['hash'], 'AbCdEf123=');
      expect(d.params['mid'], '00000000-0000-4000-8000-000000000000');
      expect(d.params['app_version'], '3.10.1');
      expect(d.label, 'DESKTOP-ABC123');
      expect(d.baseUrl, 'https://zcode.z.ai/remote/v4');
    });

    test('缺 sid 拒收', () {
      const url = 'https://zcode.z.ai/remote/v4?hash=x&t=1&mid=m&name=n';
      expect(LinkBuilder.parse(url), isNull);
    });

    test('V2 官方二维码：只有 sid（无 hash/t）可导入（2026-10 协议改版）', () {
      // 桌面端 3.16.3 `buildWebRemoteControlExternalQrUrl` 的实际输出形态：
      // sid + mid + name + app_version，hash/t 已删除。
      const url = 'https://zcode.z.ai/remote/v4'
          '?sid=d_V2Device0000000000'
          '&mid=00000000-0000-4000-8000-000000000000'
          '&name=PC-20260816OWHB&app_version=3.16.3';
      final d = LinkBuilder.parse(url)!;
      expect(d.sid, 'd_V2Device0000000000');
      expect(d.params.containsKey('hash'), isFalse);
      expect(d.label, 'PC-20260816OWHB');
      expect(d.baseUrl, 'https://zcode.z.ai/remote/v4');
    });

    test('V2 链接 buildUrl 不注入 t，其余参数原样', () {
      const url =
          'https://zcode.z.ai/remote/v4?sid=v2sid&mid=m&name=n&app_version=3.16.3';
      final d = LinkBuilder.parse(url)!;
      final uri = LinkBuilder.buildUrl(
        d,
        now: DateTime.fromMillisecondsSinceEpoch(1790000000000),
      );
      expect(uri.queryParameters.containsKey('t'), isFalse);
      expect(uri.queryParameters['sid'], 'v2sid');
      expect(uri.queryParameters['mid'], 'm');
    });

    test('空参数值视同缺失', () {
      const url = 'https://zcode.z.ai/remote/v4?sid=&hash=x';
      expect(LinkBuilder.parse(url), isNull);
    });

    test('非 http(s) 拒收', () {
      expect(LinkBuilder.parse('zcode://oauth/callback?sid=s&hash=h'), isNull);
      expect(LinkBuilder.parse('javascript:alert(1)?sid=s&hash=h'), isNull);
    });

    test('超长输入在解析前被拒（F24 长度门禁）', () {
      const prefix = 'https://zcode.z.ai/remote/v4?sid=s&hash=h&pad=';
      final okLength = prefix.length + 100;
      expect(LinkBuilder.parse('$prefix${'x' * 100}'), isNotNull);
      expect(
        LinkBuilder.parse(
          '$prefix${'x' * (LinkBuilder.maxLinkLength - prefix.length + 1)}',
        ),
        isNull,
        reason: '超过 maxLinkLength 的文本不得进入解析路径',
      );
      expect(
        LinkBuilder.parse('x' * (LinkBuilder.maxLinkLength + 1024)),
        isNull,
      );
      expect(okLength, lessThanOrEqualTo(LinkBuilder.maxLinkLength));
    });

    test('垃圾输入拒收', () {
      expect(LinkBuilder.parse(''), isNull);
      expect(LinkBuilder.parse('   '), isNull);
      expect(LinkBuilder.parse('随便什么文字'), isNull);
      expect(LinkBuilder.parse('http://'), isNull);
    });

    test('宽松：多余参数保留，name 缺省存空（默认名在渲染层本地化）', () {
      const url = 'https://zcode.z.ai/remote/v5?sid=s1&hash=h1&future=xyz';
      final d = LinkBuilder.parse(url)!;
      expect(d.params['future'], 'xyz');
      expect(d.label, '');
    });

    test('不受信任 origin 默认拒收', () {
      const url = 'https://relay.example.com:8443/remote/v4?sid=s&hash=h';
      expect(LinkBuilder.parse(url), isNull);
    });

    test('自定义 origin 只能通过显式开发者入口放行', () {
      const url = 'https://relay.example.com:8443/remote/v4?sid=s&hash=h';
      final d = LinkBuilder.parse(url, allowCustomOrigin: true)!;
      expect(d.baseUrl, 'https://relay.example.com:8443/remote/v4');
    });

    test('token-only 控制链接可导入', () {
      final d = LinkBuilder.parse(
        'https://zcode.z.ai/remote/v4?remoteControlToken=token-1&name=Desk',
      )!;
      expect(d.params['remoteControlToken'], 'token-1');
      expect(d.sid, isEmpty);
    });
  });

  group('LinkBuilder.isTrustedSignInTarget（V2 登录中转域，2026-10 实测）', () {
    test('官方 origin 与两个登录域放行', () {
      expect(
        LinkBuilder.isTrustedSignInTarget(
          Uri.parse('https://zcode.z.ai/web-remote'),
        ),
        isTrue,
      );
      expect(
        LinkBuilder.isTrustedSignInTarget(
          Uri.parse(
            'https://chat.z.ai/api/oauth/authorize?client_id=c&state=s',
          ),
        ),
        isTrue,
      );
      expect(
        LinkBuilder.isTrustedSignInTarget(
          Uri.parse('https://bigmodel.cn/login?redirect=x&appId=zcode'),
        ),
        isTrue,
      );
      expect(
        LinkBuilder.isTrustedSignInTarget(
          Uri.parse('https://www.bigmodel.cn/login'),
        ),
        isTrue,
      );
    });

    test('外站 / 明文 http / 非默认端口 / userInfo 一律拒绝', () {
      expect(
        LinkBuilder.isTrustedSignInTarget(Uri.parse('https://evil.com/login')),
        isFalse,
      );
      expect(
        LinkBuilder.isTrustedSignInTarget(
          Uri.parse('http://chat.z.ai/api/oauth/authorize'),
        ),
        isFalse,
      );
      expect(
        LinkBuilder.isTrustedSignInTarget(
          Uri.parse('https://chat.z.ai:8443/auth'),
        ),
        isFalse,
      );
      expect(
        LinkBuilder.isTrustedSignInTarget(
          Uri.parse('https://zcode.z.ai@evil.com/login'),
        ),
        isFalse,
      );
      expect(LinkBuilder.isTrustedSignInTarget(null), isFalse);
    });
  });

  group('LinkBuilder.buildUrl', () {
    test('t 刷新为指定时刻，其余参数与顺序原样', () {
      final d = LinkBuilder.parse(sampleUrl)!;
      final now = DateTime.fromMillisecondsSinceEpoch(1790000000000);
      final uri = LinkBuilder.buildUrl(d, now: now);

      expect(uri.queryParameters['t'], '1790000000000');
      expect(uri.queryParameters['sid'], d.sid);
      expect(uri.queryParameters['hash'], 'AbCdEf123=');
      expect(uri.queryParameters['mid'], d.params['mid']);
      expect(uri.queryParameters['name'], 'DESKTOP-ABC123');
      expect(uri.queryParameters['app_version'], '3.10.1');
      expect(uri.toString(), contains('hash=AbCdEf123%3D'));
      expect(uri.toString(), startsWith('https://zcode.z.ai/remote/v4?'));
      expect(uri.toString(), isNot(endsWith('?')));
    });

    test('不修改原设备对象（不可变性）', () {
      final d = LinkBuilder.parse(sampleUrl)!;
      final before = Map.of(d.params);
      LinkBuilder.buildUrl(d, now: DateTime.fromMillisecondsSinceEpoch(1));
      expect(d.params, before);
      expect(d.params.containsKey('t'), isTrue);
    });
  });

  group('RemoteDevice', () {
    test('JSON 往返无损', () {
      final d = LinkBuilder.parse(sampleUrl)!;
      final restored = RemoteDevice.fromJson(d.toJson());
      expect(restored.id, d.id);
      expect(restored.baseUrl, d.baseUrl);
      expect(restored.params, d.params);
      expect(restored.label, d.label);
      expect(restored.createdAt, d.createdAt);
    });

    test('sidSuffix 取尾部 6 位', () {
      final d = LinkBuilder.parse(sampleUrl)!;
      expect(d.sidSuffix, '000000');
    });

    test('rename 只改 label', () {
      final d = LinkBuilder.parse(sampleUrl)!;
      final r = d.copyWith(label: '工作机');
      expect(r.label, '工作机');
      expect(r.id, d.id);
      expect(r.params, d.params);
    });
  });

group('LinkBuilder.isPublicEndpoint（出站端点第二道防线）', () {
  test('官方 origin 放行', () {
    expect(
      LinkBuilder.isPublicEndpoint(Uri.parse('https://zcode.z.ai')),
      isTrue,
    );
  });

  test('环回 / 私网 / 保留地址一律拒绝', () {
    expect(
      LinkBuilder.isPublicEndpoint(Uri.parse('https://localhost')),
      isFalse,
    );
    expect(
      LinkBuilder.isPublicEndpoint(Uri.parse('https://127.0.0.1/x')),
      isFalse,
    );
    expect(
      LinkBuilder.isPublicEndpoint(Uri.parse('https://10.1.2.3/x')),
      isFalse,
    );
    expect(
      LinkBuilder.isPublicEndpoint(Uri.parse('https://192.168.1.1/x')),
      isFalse,
    );
    expect(
      LinkBuilder.isPublicEndpoint(Uri.parse('https://172.16.0.9/x')),
      isFalse,
    );
    expect(
      LinkBuilder.isPublicEndpoint(Uri.parse('https://169.254.9.9/x')),
      isFalse,
    );
    expect(
      LinkBuilder.isPublicEndpoint(Uri.parse('https://100.64.0.1/x')),
      isFalse,
    );
    expect(
      LinkBuilder.isPublicEndpoint(Uri.parse('https://[::1]/x')),
      isFalse,
    );
    expect(
      LinkBuilder.isPublicEndpoint(Uri.parse('https://[fe80::1]/x')),
      isFalse,
    );
    expect(
      LinkBuilder.isPublicEndpoint(Uri.parse('https://[fc00::1]/x')),
      isFalse,
    );
    expect(
      LinkBuilder.isPublicEndpoint(Uri.parse('https://[::ffff:192.168.0.1]/x')),
      isFalse,
    );
  });

  test('非 https/wss scheme 拒绝', () {
    expect(
      LinkBuilder.isPublicEndpoint(Uri.parse('http://zcode.z.ai')),
      isFalse,
    );
  });
});
}

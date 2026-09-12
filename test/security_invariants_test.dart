import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 安全硬不变量门禁（T2）：这些断言不测功能，而是防止未来的重构把已经
/// 修好的安全策略悄悄改回去。每条都对应一次真实审计结论。
void main() {
  final root = Directory.current.path;
  String read(String path) => File('$root/$path').readAsStringSync();

  group('security invariants：WebView 信任边界', () {
    test('导航白名单必须显式开启 useShouldOverrideUrlLoading（插件默认 false）', () {
      final src = read('lib/ui/official_remote_page.dart');
      expect(src.contains('useShouldOverrideUrlLoading: true'), isTrue);
    });

    test('三个注入 UserScript 全部限定官方 origin', () {
      final src = read('lib/ui/official_remote_page.dart');
      expect(
        "allowedOriginRules: {'https://zcode.z.ai'}".allMatches(src).length,
        greaterThanOrEqualTo(3),
      );
    });

    test('页面 console 只能在 debug 构建转发（kDebugMode 守卫）', () {
      expect(read('lib/ui/official_remote_page.dart').contains('kDebugMode'), isTrue);
    });

    test('主框架导航必须使用页面级信任 isTrustedRemotePage（W1）', () {
      expect(
        read('lib/ui/official_remote_page.dart').contains(
          'LinkBuilder.isTrustedRemotePage',
        ),
        isTrue,
      );
      expect(
        read('lib/services/link_builder.dart').contains(
          'static bool isTrustedRemotePage',
        ),
        isTrue,
      );
    });

    test('信任模型拒绝显式非 443 端口（W1）', () {
      expect(
        read('lib/services/link_builder.dart').contains('uri.port != 443'),
        isTrue,
      );
    });

    test('高权限 bridge 回调必须经过 _bridgeAllowed 守卫（W1 纵深防御）', () {
      final src = read('lib/ui/official_remote_page.dart');
      expect(
        RegExp(r'await _bridgeAllowed\(\)').allMatches(src).length,
        greaterThanOrEqualTo(5),
      );
    });

    test('第三方 Cookie 保持最小化关闭（W3）', () {
      expect(
        read('lib/ui/official_remote_page.dart').contains(
          'thirdPartyCookiesEnabled: false',
        ),
        isTrue,
      );
    });

    test('控制链接只接受 https 官方 host（拒绝明文与任意域）', () {
      final src = read('lib/services/link_builder.dart');
      expect(src.contains("scheme.toLowerCase() != 'https'"), isTrue);
      expect(src.contains("{'zcode.z.ai'}"), isTrue);
    });
  });

  group('security invariants：更新链', () {
    test('下载 URL 钉死官方仓库 release/download 路径', () {
      final src = read('lib/services/update_service.dart');
      expect(src.contains('/2421873411a-rgb/zcode-app/releases/download/'), isTrue);
    });

    test('无 digest 不允许自动下载（U1 fail-closed）', () {
      final src = read('lib/services/update_service.dart');
      expect(src.contains('assetDigest != null'), isTrue);
      expect(src.contains('assetDigest!.isNotEmpty'), isTrue);
    });

    test('资产命名契约：只认 ZCode-v<版本>.apk 精确名（U2）', () {
      final src = read('lib/services/update_service.dart');
      expect(src.contains(r'zcode-v$latest.apk'), isTrue);
      expect(src.contains('_apkName'), isFalse);
    });

    test('安装前预校验覆盖包名与签名（precheckApk fail-closed）', () {
      final src = read('lib/services/update_service.dart');
      expect(src.contains('ApkPrecheckIssue.unreadable'), isTrue);
      expect(src.contains('ApkPrecheckIssue.signerMismatch'), isTrue);
    });
  });

  group('security invariants：Android 原生面', () {
    test('不允许明文流量', () {
      expect(
        read('android/app/src/main/AndroidManifest.xml').contains(
          'usesCleartextTraffic',
        ),
        isFalse,
      );
    });

    test('不允许备份（凭证只进 secure storage）', () {
      expect(
        read('android/app/src/main/AndroidManifest.xml').contains(
          'android:allowBackup="false"',
        ),
        isTrue,
      );
    });

    test('FileProvider 不导出', () {
      expect(
        read('android/app/src/main/AndroidManifest.xml').contains(
          'android:exported="false"',
        ),
        isTrue,
      );
    });

    test('FileProvider 只暴露 updates/ 子目录，不暴露整个 cache', () {
      final paths = read('android/app/src/main/res/xml/file_paths.xml');
      expect(paths.contains('updates/'), isTrue);
      expect(paths.contains('path="."'), isFalse);
    });

    test('KeepAlive 历史实现必须已删除，且不得复活常驻服务（K1）', () {
      expect(
        read('android/app/src/main/AndroidManifest.xml').contains('<service'),
        isFalse,
      );
      expect(
        File(
          '$root/android/app/src/main/kotlin/com/zcode/app/KeepAliveService.kt',
        ).existsSync(),
        isFalse,
      );
      expect(File('$root/lib/services/keepalive.dart').existsSync(), isFalse);
    });

    test('Release 构建禁止 debug 签名回退（缺 keystore 即失败）', () {
      expect(
        read('android/app/build.gradle.kts').contains(
          'refusing a release build',
        ),
        isTrue,
      );
    });
  });
}

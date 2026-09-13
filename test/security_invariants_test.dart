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
        RegExp(r'await _bridgeAllowed\(args\)').allMatches(src).length,
        greaterThanOrEqualTo(5),
      );
    });

    test('bridge 守卫必须校验主 frame 令牌（PR04/F03）', () {
      final page = read('lib/ui/official_remote_page.dart');
      final hook = read('lib/services/event_observer.dart');
      final token = read('lib/services/bridge_token.dart');
      expect(page.contains('BridgeAuthPolicy.tokenMatches'), isTrue);
      // 令牌有两条注入路径，都必须经过同一套"确认落地"逻辑：
      //   1. document-start UserScript 预置 window.__zrToken（钩子安装时直接读）；
      //   2. 运行期 __zrSetToken + read-back 校验 + 退避重试（bridge_token.dart）。
      expect(page.contains('BridgeTokenPolicy.bootstrapScript'), isTrue);
      expect(page.contains('_ensureBridgeToken'), isTrue);
      expect(token.contains('window.__zrSetToken'), isTrue);
      expect(token.contains('window.__zrToken'), isTrue);
      expect(hook.contains('window.__zrSetToken'), isTrue);
      expect(hook.contains('tokenOf'), isTrue);
      expect(hook.contains('zrToken'), isTrue);
    });

    test('跳转回执同样受令牌与尺寸门禁约束（PR13b/F12）', () {
      final page = read('lib/ui/official_remote_page.dart');
      final jump = read('lib/services/session_jump.dart');
      // 页面侧：只有拿到主 frame 令牌才发回执。
      expect(jump.contains('if (!window.__zrToken) return false;'), isTrue);
      expect(jump.contains('bridge.callHandler('), isTrue);
      // Dart 侧：先过 _bridgeAllowed，再过字节门禁，最后才是业务解析。
      expect(page.contains("handlerName: 'zrJump'"), isTrue);
      expect(page.contains('BridgeSchema.maxJumpBytes'), isTrue);
      expect(
        read('lib/services/bridge_schema.dart').contains('maxJumpBytes'),
        isTrue,
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

    test('WS/SSE 白名单（W2）：只观察官方 relay 端点，其余透明计数', () {
      final hook = read('lib/services/event_observer.dart');
      expect(hook.contains("u.pathname === '/ws'"), isTrue);
      expect(hook.contains('wsIgnored'), isTrue);
      expect(hook.contains('sseIgnored'), isTrue);
    });

    test('Renderer 崩溃恢复接入（v1.2.0）：generation 重建 WebView', () {
      final page = read('lib/ui/official_remote_page.dart');
      expect(page.contains('onRenderProcessGone'), isTrue);
      expect(page.contains('_webviewGeneration'), isTrue);
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

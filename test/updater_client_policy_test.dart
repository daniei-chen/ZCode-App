import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/services/update_service.dart';

/// R-10/R-11 回归：更新器的 client 生命周期与 sidecar 请求策略。
///
/// 审计反例：
///   * R-10：API 超时分支不 await 回退就 return，`finally` 立即关闭 owned
///     client → 回退观察到 closed client（`fallbackObservedClosed == true`）。
///   * R-11：sidecar 用 `client.get(uri)` 默认自动跟随重定向，绕过 `_get`
///     的逐跳白名单（`followRedirects == true`）。
/// 记录是否观察到"client 已关闭"，并可模拟 API 超时。
class TimeoutThenOkClient extends http.BaseClient {
  bool closed = false;
  bool fallbackObservedClosed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.host == 'api.github.com') {
      throw TimeoutException('AUDIT_API_TIMEOUT');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (closed) {
      fallbackObservedClosed = true;
      throw http.ClientException('AUDIT_CLIENT_ALREADY_CLOSED');
    }
    if (request.url.path.endsWith('.sha256')) {
      return http.StreamedResponse(
        Stream.value(utf8.encode('${'a' * 64}  ZCode-v2.0.0.apk')),
        200,
      );
    }
    return http.StreamedResponse(const Stream.empty(), 302, headers: {
      'location':
          'https://github.com/2421873411a-rgb/ZCode-App/releases/tag/v2.0.0',
    });
  }

  @override
  void close() => closed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('R-10：API 超时后回退必须完成，owned client 不得提前关闭', () async {
    final owned = TimeoutThenOkClient();
    final result = await http.runWithClient(
      () => UpdateService.instance.checkForUpdate(currentVersion: '1.0.0'),
      () => owned,
    );
    expect(
      owned.fallbackObservedClosed,
      isFalse,
      reason: '回退请求期间 client 必须是打开的（旧实现在此复现为 true）',
    );
    // 回退通道真的走通了：发布页重定向 + sidecar 摘要都拿到 → 可下载。
    expect(result.canDownload, isTrue);
    expect(result.latestVersion, '2.0.0');
  });

  test('R-10：借入的 client 不受影响，调用方负责关闭', () async {
    final borrowed = TimeoutThenOkClient();
    final result = await UpdateService.instance.checkForUpdate(
      client: borrowed,
      currentVersion: '1.0.0',
    );
    expect(result.canDownload, isTrue);
    expect(borrowed.fallbackObservedClosed, isFalse);
    expect(borrowed.closed, isFalse, reason: '借入的 client 不得由服务关闭');
    borrowed.close();
  });

  test('R-11：sidecar 请求不得自动跟随重定向（走逐跳校验）', () async {
    bool? sidecarFollowsRedirects;
    final client = MockClient((request) async {
      if (request.url.host == 'api.github.com') {
        return http.Response('', 403);
      }
      if (request.url.path.endsWith('.sha256')) {
        sidecarFollowsRedirects = request.followRedirects;
        return http.Response('${'a' * 64}  ZCode-v2.0.0.apk', 200);
      }
      return http.Response('', 302, headers: {
        'location':
            'https://github.com/2421873411a-rgb/ZCode-App/releases/tag/v2.0.0',
      });
    });
    final result = await UpdateService.instance.checkForUpdate(
      client: client,
      currentVersion: '1.0.0',
    );
    expect(result.canDownload, isTrue);
    expect(
      sidecarFollowsRedirects,
      isFalse,
      reason: 'sidecar 必须显式禁止自动重定向，由 _get 逐跳校验（旧实现为 true）',
    );
  });

  test('R-11：sidecar 重定向到非白名单主机 → 摘要取不到，退化为"引导页面"', () async {
    final client = MockClient((request) async {
      if (request.url.host == 'api.github.com') {
        return http.Response('', 403);
      }
      if (request.url.path.endsWith('.sha256')) {
        return http.Response('', 302, headers: {
          'location': 'https://evil.example/ZCode-v2.0.0.apk.sha256',
        });
      }
      return http.Response('', 302, headers: {
        'location':
            'https://github.com/2421873411a-rgb/ZCode-App/releases/tag/v2.0.0',
      });
    });
    final result = await UpdateService.instance.checkForUpdate(
      client: client,
      currentVersion: '1.0.0',
    );
    expect(
      result.canDownload,
      isFalse,
      reason: '拿不到可信摘要时不得自动下载（fail-closed）',
    );
    expect(result.latestVersion, '2.0.0', reason: '版本识别仍然可用，只是不能自动装');
  });

  // 复审回归（H1）：GitHub 的 release 资产首跳必是 302 到
  // release-assets.githubusercontent.com（白名单内）。sidecar 必须在这种
  // 真实链路上完成逐跳校验并跟随到 200；旧修复误传 followRedirects:false
  // 会让 sidecar 永远拿不到摘要、自动下载失效。
  test('H1 回归：sidecar 经 302 → 白名单 CDN → 200，摘要取到且可下载', () async {
    var sidecarHops = 0;
    final client = MockClient((request) async {
      if (request.url.host == 'api.github.com') {
        return http.Response('', 403);
      }
      if (request.url.path.endsWith('.sha256')) {
        sidecarHops++;
        if (request.url.host == 'github.com') {
          // 首跳：GitHub → 资产 CDN。
          return http.Response('', 302, headers: {
            'location':
                'https://release-assets.githubusercontent.com/github-production-release-asset/1/ZCode-v2.0.0.apk.sha256',
          });
        }
        // 第二跳：白名单 CDN 返回正式内容。
        return http.Response('${'a' * 64}  ZCode-v2.0.0.apk', 200);
      }
      return http.Response('', 302, headers: {
        'location':
            'https://github.com/2421873411a-rgb/ZCode-App/releases/tag/v2.0.0',
      });
    });
    final result = await UpdateService.instance.checkForUpdate(
      client: client,
      currentVersion: '1.0.0',
    );
    expect(sidecarHops, 2, reason: '必须真实跟随到第二跳（旧实现只发一跳就判失败）');
    expect(result.assetDigest, 'sha256:${'a' * 64}');
    expect(result.canDownload, isTrue, reason: 'H1 修复后自动下载链路可用');
  });
}

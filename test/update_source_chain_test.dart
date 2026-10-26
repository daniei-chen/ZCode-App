// 检查更新源链真实联调（默认跳过；UPD_INTEGRATION=1 启用）。
//
// 2026-10-26 实测结论（国内网络）：
//   gh-proxy.com    ~0.6s  ✅
//   cdn.jsdelivr.net ~1.9s ✅
//   raw.githubusercontent.com 直连 ❌（立即失败）
//   api.github.com  本机偶通、用户环境 403 限流
//
// 因此 App 的源链顺序是 gh-proxy → jsDelivr → 直连 → 自有镜像 → API。
// 本测试验证「前两家必有至少一家可用」，并验证解析器能吃下真实响应。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/outbound_url_policy.dart';
import 'package:zremote/services/update_service.dart';

final _enabled = Platform.environment['UPD_INTEGRATION'] == '1';

void main() {
  group('检查更新源链', () {
    test('三个反代域都在出站白名单内', () {
      for (final url in const [
        'https://gh-proxy.com/https://raw.githubusercontent.com/a/b/main/x.json',
        'https://cdn.jsdelivr.net/gh/a/b@main/x.json',
        'https://ghproxy.net/https://api.github.com/repos/a/b/releases/latest',
      ]) {
        expect(
          OutboundUrlPolicy.rejectionReason(Uri.parse(url)),
          isNull,
          reason: '$url 被策略拒绝',
        );
      }
    });

    test('源链顺序：gh-proxy 首选、jsDelivr 次选、自有镜像垫底', () {
      final sources = UpdateService.manifestSources();
      expect(sources, isNotEmpty);
      expect(sources.first.host, 'gh-proxy.com');
      expect(sources[1].host, 'cdn.jsdelivr.net');
      expect(sources.last.host, 'zhihui.kaogong.art');
    });

    test('下载代理前缀顺序：gh-proxy → ghproxy.net → 直连', () {
      final prefixes = UpdateService.downloadProxyPrefixes;
      expect(prefixes.first, contains('gh-proxy.com'));
      expect(prefixes[1], contains('ghproxy.net'));
      expect(prefixes.last, isEmpty, reason: '最后一项必须是直连兜底');
    });

    test('真实检查更新：至少一家 manifest 源可用并解析出结果', () async {
      final result = await UpdateService.instance.checkForUpdate(
        currentVersion: '1.0.0',
        timeout: const Duration(seconds: 15),
      );
      expect(
        result.status,
        isNot(UpdateCheckStatus.failed),
        reason: '检查更新失败（reason=${result.failureReason}）——所有源都不可用',
      );
      expect(result.latestVersion, isNotNull);
      // manifest 主链路必须带着 sha256（否则 canDownload 为假，用户只能手动去
      // GitHub 下载——那不是我们想要的默认体验）。
      expect(
        result.assetDigest,
        isNotNull,
        reason: '主链路应提供 sha256 摘要',
      );
      expect(result.assetDigest, startsWith('sha256:'));
      expect(result.downloadFileName, contains('ZCode-'));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('以最新版检查 → upToDate', () async {
      final probe = await UpdateService.instance.checkForUpdate(
        currentVersion: '1.0.0',
        timeout: const Duration(seconds: 15),
      );
      if (probe.latestVersion == null) {
        markTestSkipped('拿不到最新版');
        return;
      }
      final result = await UpdateService.instance.checkForUpdate(
        currentVersion: probe.latestVersion!,
        timeout: const Duration(seconds: 15),
      );
      expect(result.status, UpdateCheckStatus.upToDate);
    }, timeout: const Timeout(Duration(minutes: 2)));
  }, skip: _enabled ? false : '联调测试默认跳过（UPD_INTEGRATION=1）');
}

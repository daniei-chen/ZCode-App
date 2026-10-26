// 检查更新链路真实联调（默认跳过；设 UPD_INTEGRATION=1 启用）。
//
// 目的：验证 App 的真实更新检查代码（不是 mock）能打通三条链路：
//   1) api.github.com 直连
//   2) 自有镜像 zhihui.kaogong.art/zcode-release-latest
//   3) 发布页回退
// 并确认出站白名单不会误拦镜像域。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/outbound_url_policy.dart';
import 'package:zremote/services/update_service.dart';

final _enabled = Platform.environment['UPD_INTEGRATION'] == '1';

void main() {
  group('检查更新真实链路', () {
    test('镜像地址通过出站白名单', () {
      final reason = OutboundUrlPolicy.rejectionReason(
        Uri.parse('https://zhihui.kaogong.art/zcode-release-latest'),
      );
      expect(reason, isNull, reason: '镜像地址被策略拒绝：$reason');
    });

    test('真实检查更新：应返回可用结果（不是 failed）', () async {
      // currentVersion 显式给一个较旧版本，确保走到"有新版"分支，
      // 从而验证完整的 tag/资产解析，而不是仅仅 upToDate。
      final result = await UpdateService.instance.checkForUpdate(
        currentVersion: '1.0.0',
        timeout: const Duration(seconds: 20),
      );
      expect(
        result.status,
        isNot(UpdateCheckStatus.failed),
        reason: '检查更新失败（status=failed）——三条链路都不可用',
      );
      expect(result.latestVersion, isNotNull);
      // 资产命名契约：ZCode-v<版本>.apk
      if (result.downloadUri != null) {
        expect(result.downloadFileName, contains('ZCode-v'));
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('当前已是最新版 → upToDate', () async {
      // 先用上面拿到的真实最新版，再以它为当前版本检查。
      final probe = await UpdateService.instance.checkForUpdate(
        currentVersion: '1.0.0',
        timeout: const Duration(seconds: 20),
      );
      if (probe.latestVersion == null) {
        markTestSkipped('拿不到最新版，跳过');
        return;
      }
      final result = await UpdateService.instance.checkForUpdate(
        currentVersion: probe.latestVersion!,
        timeout: const Duration(seconds: 20),
      );
      expect(result.status, UpdateCheckStatus.upToDate);
    }, timeout: const Timeout(Duration(minutes: 2)));
  }, skip: _enabled ? false : '联调测试默认跳过（UPD_INTEGRATION=1）');
}

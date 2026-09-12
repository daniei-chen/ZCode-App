import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/update_installer.dart';
import 'package:zremote/services/update_service.dart';

void main() {
  group('precheckApk 安装前预校验', () {
    const good = ApkArchiveInfo(
      packageName: 'com.zcode.app',
      versionName: '1.0.7',
      versionCode: 8,
    );

    test('包名一致且 versionCode 更高 → 通过', () {
      expect(
        precheckApk(
          archive: good,
          expectedPackage: 'com.zcode.app',
          installedVersionCode: 7,
        ),
        isNull,
      );
    });

    test('读不出元数据（下载不完整）→ unreadable', () {
      expect(
        precheckApk(
          archive: null,
          expectedPackage: 'com.zcode.app',
          installedVersionCode: 7,
        ),
        ApkPrecheckIssue.unreadable,
      );
    });

    test('包名不符 → wrongPackage，拒绝张冠李戴的包', () {
      const fake = ApkArchiveInfo(
        packageName: 'com.other.app',
        versionName: '9.9',
        versionCode: 999,
      );
      expect(
        precheckApk(
          archive: fake,
          expectedPackage: 'com.zcode.app',
          installedVersionCode: 7,
        ),
        ApkPrecheckIssue.wrongPackage,
      );
    });

    test('versionCode 低于已装（官方 7 对设备上的 2006）→ downgrade，正是 -25 场景', () {
      const v106 = ApkArchiveInfo(
        packageName: 'com.zcode.app',
        versionName: '1.0.6',
        versionCode: 7,
      );
      expect(
        precheckApk(
          archive: v106,
          expectedPackage: 'com.zcode.app',
          installedVersionCode: 2006,
        ),
        ApkPrecheckIssue.downgrade,
      );
    });

    test('versionCode 相等 → 允许同版本重装，不拦', () {
      expect(
        precheckApk(
          archive: good,
          expectedPackage: 'com.zcode.app',
          installedVersionCode: 8,
        ),
        isNull,
      );
    });
  });
}

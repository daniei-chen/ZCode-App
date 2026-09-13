import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:zremote/services/biometric.dart';
import 'package:zremote/services/security_lock.dart';

/// 门禁开关验证策略（PR21/F24）：开启与关闭都必须先验证身份，且验证失败
/// 绝不能改变状态；关闭路径允许在生物识别不可用时退回系统锁屏凭据。
void main() {
  const reason = 'reason';

  Future<bool> Function(String) ok() => (_) async => true;
  Future<bool> Function(String) cancelled() => (_) async => false;
  Future<bool> Function(String) unavailable() =>
      (_) async => throw const BiometricUnavailableException(
        LocalAuthException(code: LocalAuthExceptionCode.noBiometricsEnrolled),
      );

  group('开启路径', () {
    test('生物识别验证通过 → 允许开启', () async {
      expect(
        await SecurityLockPolicy.verifyToggle(
          enabling: true,
          reason: reason,
          biometric: ok(),
          deviceCredential: ok(),
        ),
        isTrue,
      );
    });

    test('用户取消 → 拒绝，且不再退回设备凭据（避免变成免验证入口）', () async {
      var deviceCredentialCalled = false;
      expect(
        await SecurityLockPolicy.verifyToggle(
          enabling: true,
          reason: reason,
          biometric: cancelled(),
          deviceCredential: (_) async {
            deviceCredentialCalled = true;
            return true;
          },
        ),
        isFalse,
      );
      expect(deviceCredentialCalled, isFalse);
    });

    test('设备无可用生物识别 → 拒绝开启（绝不因"验证不了"就打开保护）', () async {
      expect(
        await SecurityLockPolicy.verifyToggle(
          enabling: true,
          reason: reason,
          biometric: unavailable(),
          deviceCredential: ok(),
        ),
        isFalse,
      );
    });
  });

  group('关闭路径', () {
    test('生物识别验证通过 → 允许关闭', () async {
      expect(
        await SecurityLockPolicy.verifyToggle(
          enabling: false,
          reason: reason,
          biometric: ok(),
          deviceCredential: ok(),
        ),
        isTrue,
      );
    });

    test('用户取消 → 拒绝关闭，状态不变', () async {
      expect(
        await SecurityLockPolicy.verifyToggle(
          enabling: false,
          reason: reason,
          biometric: cancelled(),
          deviceCredential: ok(),
        ),
        isFalse,
      );
    });

    test('生物识别不可用 → 退回系统锁屏凭据，成功则允许关闭', () async {
      expect(
        await SecurityLockPolicy.verifyToggle(
          enabling: false,
          reason: reason,
          biometric: unavailable(),
          deviceCredential: ok(),
        ),
        isTrue,
      );
    });

    test('生物识别与设备凭据都不可用 → 拒绝关闭', () async {
      expect(
        await SecurityLockPolicy.verifyToggle(
          enabling: false,
          reason: reason,
          biometric: unavailable(),
          deviceCredential: unavailable(),
        ),
        isFalse,
      );
    });

    test('设备凭据取消 → 拒绝关闭', () async {
      expect(
        await SecurityLockPolicy.verifyToggle(
          enabling: false,
          reason: reason,
          biometric: unavailable(),
          deviceCredential: cancelled(),
        ),
        isFalse,
      );
    });
  });
}

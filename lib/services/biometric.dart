import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

class BiometricService {
  BiometricService._() : _auth = LocalAuthentication();

  @visibleForTesting
  BiometricService.forTesting(LocalAuthentication auth) : _auth = auth;

  static final BiometricService instance = BiometricService._();

  final LocalAuthentication _auth;

  DateTime? _lastSuccess;

  DateTime? get lastSuccessAt => _lastSuccess;

  static const cancelCodes = {
    LocalAuthExceptionCode.userCanceled,
    LocalAuthExceptionCode.systemCanceled,
    LocalAuthExceptionCode.timeout,
    LocalAuthExceptionCode.userRequestedFallback,
    LocalAuthExceptionCode.authInProgress,
  };

  static const unavailableCodes = {
    LocalAuthExceptionCode.noCredentialsSet,
    LocalAuthExceptionCode.noBiometricsEnrolled,
    LocalAuthExceptionCode.noBiometricHardware,
    LocalAuthExceptionCode.uiUnavailable,
  };

  Future<bool> isAvailable() async {
    final canBio = await _auth.canCheckBiometrics;
    if (!canBio) return false;
    final enrolled = await _auth.getAvailableBiometrics();
    return enrolled.isNotEmpty;
  }

  Future<bool> authenticate(String reason) async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        // The app advertises a biometric gate; do not silently downgrade to
        // the device PIN/password when the user expects biometric-only access.
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
      if (ok) _lastSuccess = DateTime.now();
      return ok;
    } on LocalAuthException catch (e) {
      if (cancelCodes.contains(e.code)) return false;
      if (unavailableCodes.contains(e.code)) {
        throw BiometricUnavailableException(e);
      }
      rethrow;
    }
  }

  /// 恢复路径专用：允许用系统锁屏凭据（PIN/图案/密码）证明身份。
  ///
  /// 与 [authenticate] 的 `biometricOnly: true` 不同，这条路径只在生物识别
  /// 已经不可用时使用；它仍然必须由使用者完成一次系统验证才能解锁，
  /// 绝不允许"只能免验证放行"。取消/超时一律返回 false（保持锁定）。
  Future<bool> authenticateWithDeviceCredential(String reason) async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
      if (ok) _lastSuccess = DateTime.now();
      return ok;
    } on LocalAuthException catch (e) {
      if (cancelCodes.contains(e.code)) return false;
      if (unavailableCodes.contains(e.code)) {
        throw BiometricUnavailableException(e);
      }
      rethrow;
    }
  }
}

class BiometricUnavailableException implements Exception {
  const BiometricUnavailableException(this.cause);

  final LocalAuthException cause;

  @override
  String toString() => cause.toString();
}

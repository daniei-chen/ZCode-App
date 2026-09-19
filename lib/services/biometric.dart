import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

class BiometricService {
  BiometricService._() : _auth = LocalAuthentication();

  @visibleForTesting
  BiometricService.forTesting(LocalAuthentication auth) : _auth = auth;

  static final BiometricService instance = BiometricService._();

  final LocalAuthentication _auth;

  DateTime? _lastSuccess;

  /// 墙钟成功时刻：仅供 [relockEvidence] 与测试断言使用，**不得**单独
  /// 参与解锁窗口比较（防回拨，见 [relockEvidence]）。
  DateTime? get lastSuccessAt => _lastSuccess;

  /// 距最近一次成功验证的单调时长（iter12 W-021）。
  ///
  /// 解锁窗口判定必须用**单调时钟**（[Stopwatch]，基于系统运行时长）而不是
  /// `DateTime.now()` 差值：墙钟可被用户/NTP 回拨——回拨后 `now - lastSuccess`
  /// 变小，本应过期的解锁窗口被"续期"，门禁在墙钟操纵下保持开启。内存态
  /// 不跨进程重启，Stopwatch 覆盖了全部需要比较的窗口。
  final Stopwatch _sinceSuccess = Stopwatch();

  Duration? get sinceLastSuccess =>
      _lastSuccess == null ? null : _sinceSuccess.elapsed;

  /// 解锁证据 = max(单调时长, 墙钟时长)（iter12 复核 P2）。
  ///
  /// 单调钟（Stopwatch）在设备深睡期冻结（不含 suspend 时间）——息屏数小时
  /// 后 elapsed 几乎停在睡前值，relock 窗口被"续期"；墙钟可被回拨/NTP 步进——
  /// 回拨后差值缩小，同样续期窗口。两者各自在一种场景下**失真且方向互补**：
  /// 取大者，两类场景都 fail-closed。残余边界：回拨恰好发生在深睡期间（两者
  /// 同时失真）——此时设备本就在系统锁屏之下，攻击者需先过系统锁，不构成
  /// App 门禁的独立攻击面。
  /// 双参皆 null 时返回 [Duration.zero]，调用方须先判"有无记录"。
  static Duration relockEvidence({
    Duration? monotonic,
    DateTime? wallSince,
    required DateTime now,
  }) {
    var best = monotonic ?? Duration.zero;
    if (wallSince != null) {
      final wall = now.difference(wallSince);
      if (wall > best) best = wall;
    }
    return best;
  }

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
      if (ok) {
        _lastSuccess = DateTime.now();
        _sinceSuccess
          ..reset()
          ..start();
      }
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
      if (ok) {
        _lastSuccess = DateTime.now();
        _sinceSuccess
          ..reset()
          ..start();
      }
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

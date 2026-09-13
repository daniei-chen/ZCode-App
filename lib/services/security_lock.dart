import 'biometric.dart';

/// 安全门禁开关的验证策略（PR21 / F24）。
///
/// 单独抽出来是因为它是**规则**而不是 UI 细节：
/// * 开启：只接受生物识别验证。设备没有可用生物识别时直接拒绝——
///   绝不能因为"验证不了"就把保护打开（那等于给用户一个打不开的壳）。
/// * 关闭：同样必须先验证身份；生物识别不可用时允许退回系统锁屏凭据
///   （PIN/图案/密码），因为保护已经装上了，必须留一条本人可走的出路。
/// * 取消/超时：一律 `false`，调用方保持原状态不变。
///
/// 验证函数由调用方注入，便于单测覆盖两条路径；生产代码传
/// `BiometricService` 的对应方法。
abstract final class SecurityLockPolicy {
  static Future<bool> verifyToggle({
    required bool enabling,
    required String reason,
    required Future<bool> Function(String reason) biometric,
    required Future<bool> Function(String reason) deviceCredential,
  }) async {
    try {
      if (await biometric(reason)) return true;
    } on BiometricUnavailableException {
      if (!enabling) {
        try {
          return await deviceCredential(reason);
        } on BiometricUnavailableException {
          return false;
        }
      }
      return false;
    }
    // 生物识别可用但用户取消/超时：不再退回设备凭据（关闭路径也一样）——
    // "验证失败"不等于"可以换一种方式再试一次"，避免变成免验证入口。
    return false;
  }
}

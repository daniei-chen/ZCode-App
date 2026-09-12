import 'package:flutter/services.dart';

/// Opens Android's package installer for an APK downloaded by the app.
///
/// The browser is never involved. Android may still show its own install
/// confirmation or unknown-sources settings because those are OS safeguards.
abstract final class UpdateInstaller {
  static const MethodChannel _channel = MethodChannel('zremote/update');

  /// 读取 APK 归档的包名、版本与签名证书元数据，供安装前预校验使用。
  /// 文件损坏、不完整或系统读不出时返回 null。
  static Future<ApkArchiveInfo?> inspectApk(String path) async {
    try {
      final raw = await _channel
          .invokeMethod<Map<Object?, Object?>>('inspectApk', {'path': path});
      final pkg = raw?['packageName'];
      final code = raw?['versionCode'];
      if (pkg is! String || code is! int) return null;
      return ApkArchiveInfo(
        packageName: pkg,
        versionName: raw?['versionName'] as String?,
        versionCode: code,
        signerSha256: raw?['signerSha256'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// 已安装应用自身的签名证书 SHA256；读不到时返回 null（U3）。
  static Future<String?> installedSignerSha256() async {
    try {
      return await _channel.invokeMethod<String>('installedSignerSha256');
    } catch (_) {
      return null;
    }
  }

  /// Android 8+ 是否已授予"安装未知应用"权限（更低版本恒为 true）。
  static Future<bool> canRequestInstall() async {
    try {
      return await _channel.invokeMethod<bool>('canRequestInstall') ?? true;
    } catch (_) {
      return false;
    }
  }

  /// 跳转系统的"安装未知应用"授权页；授权返回后由用户再次点安装（U4）。
  static Future<void> requestInstallPermission() async {
    try {
      await _channel.invokeMethod<void>('requestInstallPermission');
    } catch (_) {}
  }

  static Future<bool> installApk(String path) async {
    try {
      return await _channel.invokeMethod<bool>('installApk', {'path': path}) ??
          false;
    } catch (_) {
      return false;
    }
  }
}

/// APK 归档元数据（来自 PackageManager.getPackageArchiveInfo）。
class ApkArchiveInfo {
  const ApkArchiveInfo({
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    this.signerSha256,
  });

  final String packageName;

  final String? versionName;

  final int versionCode;

  /// 签名证书 SHA256（十六进制小写）；读不到时为 null。
  final String? signerSha256;
}

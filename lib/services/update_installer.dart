import 'package:flutter/services.dart';

/// Opens Android's package installer for an APK downloaded by the app.
///
/// The browser is never involved. Android may still show its own install
/// confirmation or unknown-sources settings because those are OS safeguards.
abstract final class UpdateInstaller {
  static const MethodChannel _channel = MethodChannel('zremote/update');

  /// 读取 APK 归档的包名与版本元数据，供安装前预校验使用。
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
      );
    } catch (_) {
      return null;
    }
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
  });

  final String packageName;

  final String? versionName;

  final int versionCode;
}

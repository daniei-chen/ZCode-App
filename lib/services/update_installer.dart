import 'package:flutter/services.dart';

/// Opens Android's package installer for an APK downloaded by the app.
///
/// The browser is never involved. Android may still show its own install
/// confirmation or unknown-sources settings because those are OS safeguards.
abstract final class UpdateInstaller {
  static const MethodChannel _channel = MethodChannel('zremote/update');

  static Future<bool> installApk(String path) async {
    try {
      return await _channel.invokeMethod<bool>('installApk', {'path': path}) ??
          false;
    } catch (_) {
      return false;
    }
  }
}

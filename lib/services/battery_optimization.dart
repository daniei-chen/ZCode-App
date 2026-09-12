import 'package:flutter/services.dart';

/// 电池优化白名单通道（K1/K2 重命名：不再叫 KeepAlive）。
///
/// 本应用没有常驻前台服务，这里只做两件事：查询系统电池优化状态、引导
/// 用户把应用加入白名单。这是"提高后台存活概率"的尽力而为，**不承诺**
/// 后台一定运行——系统仍可能因资源压力回收应用进程。
abstract final class BatteryOptimizationService {
  static const MethodChannel _channel = MethodChannel('zremote/battery');

  /// 系统是否已忽略本应用的电池优化（即已在白名单里）。
  static Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      return await _channel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ==
          true;
    } catch (_) {
      return false;
    }
  }

  /// 厂商 ROM（MIUI 等）是否额外限制后台；原生侧目前恒为 false。
  static Future<bool> isVendorBlocked() async {
    try {
      return await _channel.invokeMethod<bool>('isVendorBlocked') == true;
    } catch (_) {
      return false;
    }
  }

  /// 请求系统忽略电池优化（标准 Android 入口）。
  static Future<void> requestIgnoreBatteryOptimizations() async {
    try {
      await _channel.invokeMethod<void>('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }

  /// 打开厂商自启动/功耗管理页（MIUI 等），失败时原生侧回退应用详情页。
  static Future<void> requestVendorExemption() async {
    try {
      await _channel.invokeMethod<void>('requestVendorExemption');
    } catch (_) {}
  }
}

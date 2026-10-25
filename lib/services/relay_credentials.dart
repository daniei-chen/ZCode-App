import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 原生监控通道的凭证仓（v1.3.1）。
///
/// V2 终端连接需要账号 JWT（`wss://zcode.z.ai/ws?token=<JWT>&mid=<mid>`，
/// 官方页面 bundle 实证：`r.searchParams.set('token', await getToken())`）。
/// JWT 在用户打开过一次远控页后由页面探针从 localStorage 捕获，落安全存储；
/// 监控连接每次（重）连时现读——登录态刷新后下一次重连自然用上新令牌。
abstract final class RelayCredentials {
  static const _storage = FlutterSecureStorage();

  static const _jwtKey = 'zremote.relay.jwt.v1';

  static Future<void> storeJwt(String jwt) async {
    final trimmed = jwt.trim();
    if (trimmed.isEmpty || trimmed.length > 8192) return;
    try {
      final existing = await _storage.read(key: _jwtKey);
      if (existing == trimmed) return;
      await _storage.write(key: _jwtKey, value: trimmed);
    } catch (_) {}
  }

  static Future<String?> loadJwt() async {
    try {
      return await _storage.read(key: _jwtKey);
    } catch (_) {
      return null;
    }
  }

  /// 锁定擦除（wipeAll）时一并清除，令牌不得留在擦除后的设备上。
  static Future<void> wipe() async {
    try {
      await _storage.delete(key: _jwtKey);
    } catch (_) {}
  }
}

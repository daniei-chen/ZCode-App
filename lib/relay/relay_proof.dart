import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Relay 挑战应答的 proof 计算。
///
/// 对端（服务端页面）的实现等价于：
/// ```js
/// const key = await crypto.subtle.importKey('raw', utf8(passHash),
///     {name:'HMAC', hash:'SHA-256'}, false, ['sign']);
/// const sig = await crypto.subtle.sign('HMAC', key, utf8(`${nonce}|${role}|${deviceSid}`));
/// return base64url(new Uint8Array(sig));   // 无填充
/// ```
abstract final class RelayProof {
  /// 角色字面量：手机端为 `terminal`，桌面端为 `device`。
  static const String roleTerminal = 'terminal';
  static const String roleDevice = 'device';

  /// base64url 无填充（`+`→`-`、`/`→`_`、去掉 `=`）。
  static String base64UrlNoPad(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  /// 计算 proof：`base64url(HMAC-SHA256(passHash, "{nonce}|{role}|{deviceSid}"))`。
  static String calculate({
    required String passHash,
    required String nonce,
    required String role,
    required String deviceSid,
  }) {
    final key = utf8.encode(passHash);
    final message = utf8.encode('$nonce|$role|$deviceSid');
    final digest = Hmac(sha256, key).convert(message);
    return base64UrlNoPad(digest.bytes);
  }

  /// 手机端便捷入口。
  static String forTerminal({
    required String passHash,
    required String nonce,
    required String deviceSid,
  }) => calculate(
    passHash: passHash,
    nonce: nonce,
    role: roleTerminal,
    deviceSid: deviceSid,
  );
}

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/device.dart';

/// 凭证指纹（F24 / F08）：把一段控制链接的凭证归一化成一个不可逆摘要，
/// 用来判断"这两条链接是不是同一把钥匙"。
///
/// 为什么需要它：
/// * 旧去重只看 `sid`，而链接可能只带 `t`/`token`（没有 sid）——这类链接
///   完全无法去重，扫描同一条链接会重复添加设备；
/// * 去重比较必须避免在内存里到处传递明文凭证：这里只保留 SHA-256 摘要，
///   比较的是摘要，日志/诊断包里也只允许出现摘要前缀。
///
/// 指纹只覆盖凭证本身（sid/hash/t/token 等键 + baseUrl），不含设备名与创建
/// 时间——同一个控制链接重新导入必须得到同一个指纹。
abstract final class CredentialFingerprint {
  /// 参与指纹的凭证键（顺序无关，键名统一小写后排序）。
  static const credentialKeys = {'sid', 'hash', 't', 'token', 'key', 'code'};

  /// 指纹前缀长度（用于界面/日志展示；完整摘要只用于比较）。
  static const displayLength = 8;

  /// 全零/空凭证返回 null：无法判断，就不要去重。
  static String? of(RemoteDevice device) {
    final pairs = <String>[];
    for (final entry in device.params.entries) {
      final key = entry.key.trim().toLowerCase();
      final value = entry.value.trim();
      if (!credentialKeys.contains(key)) continue;
      if (value.isEmpty) continue;
      pairs.add('$key=$value');
    }
    if (pairs.isEmpty) return null;
    pairs.sort();
    final material = '${device.baseUrl}\u0000${pairs.join('\u0000')}';
    return sha256.convert(utf8.encode(material)).toString();
  }

  /// 是否可以参与去重。
  static bool isUsable(RemoteDevice device) => of(device) != null;

  /// 展示用前缀（例如设备卡片上的凭证提示）；不可判定时返回 null。
  static String? display(RemoteDevice device) {
    final fingerprint = of(device);
    if (fingerprint == null) return null;
    return fingerprint.substring(0, displayLength);
  }
}

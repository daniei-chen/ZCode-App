import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 登录账号展示名（v1.3.0，账号中心化的第一片）。
///
/// V2 账号流里所有设备天然属于同一个已登录账号（WebView 共享同一份
/// localStorage），设备列表页头部显示"登录账号：<名>"让这件事可见。
/// 名称从页面 localStorage 里的 JWT 载荷解出（email/name 等），只在本机
/// 展示，不进日志、不进诊断包。
class AccountLabelNotifier extends Notifier<String> {
  @override
  String build() => '';

  void report(String label) {
    final next = label.trim();
    if (next.isEmpty || next == state) return;
    state = next;
  }
}

final accountLabelProvider =
    NotifierProvider<AccountLabelNotifier, String>(AccountLabelNotifier.new);

abstract final class AccountLabel {
  /// 从受信任页面读登录令牌的探针脚本。key 列表覆盖实测 key 与可能的
  /// 变体；读不到返回空串（调用方静默跳过）。
  static const probeScript = '''
(function() {
  try {
    var keys = ['zcodejwttoken', 'zcode:jwt', 'zcode_jwt'];
    for (var i = 0; i < keys.length; i++) {
      var t = null;
      try { t = localStorage.getItem(keys[i]); } catch (e2) {}
      if (typeof t === 'string' && t.length > 0 && t.length < 8192) return t;
    }
  } catch (e) {}
  return '';
})()
''';

  /// 从探针返回值提取登录令牌本体（剥引号、限长）；解析不出返回 null。
  static String? extractToken(String raw) {
    var token = raw.trim();
    if (token.length >= 2 && token.startsWith('"') && token.endsWith('"')) {
      token = token.substring(1, token.length - 1);
    }
    if (token.isEmpty || token.length > 8192) return null;
    return token;
  }

  /// 从探针返回值解出账号展示名；解析不出返回 null，绝不显示原始令牌。
  static String? displayNameFromToken(String raw) {
    final token = extractToken(raw);
    if (token == null) return null;
    if (token.startsWith('{')) {
      try {
        final map = jsonDecode(token);
        if (map is Map) {
          for (final key in const ['token', 'jwt', 'access_token', 'value']) {
            final v = map[key];
            if (v is String && v.isNotEmpty) {
              final nested = displayNameFromJwt(v);
              if (nested != null) return nested;
            }
          }
        }
      } catch (_) {}
      return null;
    }
    return displayNameFromJwt(token);
  }

  /// JWT 载荷里取第一个非空的展示字段。解析失败返回 null。
  static String? displayNameFromJwt(String token) {
    final parts = token.split('.');
    if (parts.length < 2) return null;
    final payload = _decodeBase64Url(parts[1]);
    if (payload == null) return null;
    try {
      final map = jsonDecode(payload);
      if (map is! Map) return null;
      for (final key in const [
        'email',
        'name',
        'nickname',
        'preferred_username',
        'user_name',
        'userName',
      ]) {
        final value = map[key];
        if (value is String && value.trim().isNotEmpty) {
          final clean = value.trim().replaceAll(RegExp(r'\s+'), ' ');
          return clean.length > 64 ? '${clean.substring(0, 64)}…' : clean;
        }
      }
    } catch (_) {}
    return null;
  }

  static String? _decodeBase64Url(String segment) {
    try {
      var normalized = segment.replaceAll('-', '+').replaceAll('_', '/');
      while (normalized.length % 4 != 0) {
        normalized += '=';
      }
      return utf8.decode(base64.decode(normalized), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/device_store.dart';

/// 登录账号资料（v1.7.0）：展示名 + 头像 URL。
///
/// 都来自官方页 localStorage 的 `oauth:*:user_info`（JSON：id/username/
/// displayName/avatarUrl，bundle 实证字段）。头像只在可信图床白名单内
/// 加载——原生侧不因展示需求新增任意第三方网络面。
class AccountProfile {
  const AccountProfile({this.name = '', this.avatarUrl});

  final String name;
  final String? avatarUrl;

  bool get isEmpty => name.isEmpty && (avatarUrl == null || avatarUrl!.isEmpty);

  @override
  bool operator ==(Object other) =>
      other is AccountProfile &&
      other.name == name &&
      other.avatarUrl == avatarUrl;

  @override
  int get hashCode => Object.hash(name, avatarUrl);
}

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

/// 账号资料（名字 + 头像，v1.7.0）：探针读到即持久化，重启后仍在——
/// 账号行不再依赖"进过一次远控页"才有名字。
class AccountProfileNotifier extends Notifier<AccountProfile> {
  @override
  AccountProfile build() {
    _load();
    return const AccountProfile();
  }

  Future<void> _load() async {
    final stored = await DeviceStore.instance.accountDisplayName();
    final storedAvatar = await DeviceStore.instance.accountAvatarUrl();
    if (!ref.mounted) return;
    if (stored.isEmpty && (storedAvatar == null || storedAvatar.isEmpty)) {
      return;
    }
    if (state.isEmpty) {
      state = AccountProfile(name: stored, avatarUrl: storedAvatar);
    }
  }

  /// 探针/登录页上报。名字与头像分开补充（不同入口可能只拿到一部分）；
  /// 只在本机展示与存储，不进日志、不进诊断包。
  void report(AccountProfile profile) {
    if (profile.isEmpty) return;
    final name = profile.name.trim();
    final avatar = profile.avatarUrl;
    final next = AccountProfile(
      name: name.isNotEmpty ? name : state.name,
      avatarUrl: (avatar != null && avatar.isNotEmpty) ? avatar : state.avatarUrl,
    );
    if (next == state) return;
    state = next;
    unawaited(DeviceStore.instance.setAccountDisplayName(next.name));
    unawaited(DeviceStore.instance.setAccountAvatarUrl(next.avatarUrl));
  }
}

final accountProfileProvider =
    NotifierProvider<AccountProfileNotifier, AccountProfile>(
      AccountProfileNotifier.new,
    );

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

  /// 账号展示名探针（v1.6.3）：官方把用户信息存 oauth:*:user_info
  /// （JSON，含 displayName/username）——JWT claims 里没有名字字段。
  static const userInfoScript = '''
(function() {
  try {
    var keys = ['oauth:bigmodel:user_info', 'oauth:zai:user_info'];
    for (var i = 0; i < keys.length; i++) {
      var t = null;
      try { t = localStorage.getItem(keys[i]); } catch (e2) {}
      if (typeof t === 'string' && t.length > 0 && t.length < 8192) return t;
    }
  } catch (e) {}
  return '';
})()
''';

  /// 从 user_info JSON 解展示名（displayName → username → email）。
  static String? displayNameFromUserInfo(String raw) {
    final map = _userInfoMap(raw);
    if (map == null) return null;
    for (final key in const ['displayName', 'username', 'email', 'name']) {
      final v = map[key];
      if (v is String && v.trim().isNotEmpty) {
        final clean = v.trim().replaceAll(RegExp(r'\s+'), ' ');
        return clean.length > 64 ? '${clean.substring(0, 64)}…' : clean;
      }
    }
    return null;
  }

  /// 从 user_info JSON 解完整资料（v1.7.0）：名字 + 头像（官方 bundle
  /// 字段实证：id/username/displayName/avatarUrl）。头像必须在可信
  /// 图床白名单内，否则不返回（UI 回退字母头像）。
  static AccountProfile profileFromUserInfo(String raw) {
    final map = _userInfoMap(raw);
    if (map == null) return const AccountProfile();
    final name = displayNameFromUserInfo(raw) ?? '';
    final avatarRaw = map['avatarUrl'];
    final avatar = avatarRaw is String ? avatarRaw.trim() : '';
    return AccountProfile(
      name: name,
      avatarUrl: isTrustedAvatarUrl(avatar) ? avatar : null,
    );
  }

  /// 头像图床白名单：官方 OAuth 资料的 avatarUrl 只可能指向官方/登录
  /// 供应商的静态资源域。不在名单内的 URL 一律不加载。
  static const _avatarHostSuffixes = <String>[
    'zcode.z.ai',
    'z.ai',
    'bigmodel.cn',
    'zhipuai.cn',
    'zhipu.ai',
    'chatglm.cn',
  ];

  /// https + 可信图床后缀（按 label 匹配，防止 `evil-z.ai attacker`）。
  static bool isTrustedAvatarUrl(String? url) {
    final candidate = url?.trim() ?? '';
    if (candidate.isEmpty || candidate.length > 2048) return false;
    final uri = Uri.tryParse(candidate);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return false;
    final host = uri.host.toLowerCase();
    return _avatarHostSuffixes.any(
      (suffix) => host == suffix || host.endsWith('.$suffix'),
    );
  }

  static Map<String, dynamic>? _userInfoMap(String raw) {
    var text = raw.trim();
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      text = text.substring(1, text.length - 1);
    }
    if (text.isEmpty || !text.startsWith('{')) return null;
    try {
      final map = jsonDecode(text);
      return map is Map ? map.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

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

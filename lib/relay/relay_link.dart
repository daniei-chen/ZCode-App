/// 从设备记录（扫码链接）解析出 relay 远控所需的全部参数。
///
/// 实测的 v4 链接形态（ZCode 3.11.2）：
/// ```
/// https://zcode.z.ai/remote/v4?sid=<deviceSid>&hash=<passHash urlencoded>
///   &t=<毫秒时间戳>&mid=<deviceMid>&name=<主机名>&app_version=3.11.2
/// ```
/// 其中 `hash` 是标准 base64（含 `+` `/` `=`），需要 URL 解码后作为 HMAC 密钥的
/// 原始 UTF-8 字节。链接里**没有** `relayOrigin`，此时取链接自身 origin。
///
/// 另有一种带 `remoteControlToken` 的形态（网页控制台登录后跳转用），走 REST 端点，
/// 与二维码凭证是两套不同的授权模型；这里两种都解析，由 [canAuthenticate] /
/// [hasRestApi] 区分。
library;

class RelayLink {
  const RelayLink({
    required this.origin,
    this.token,
    this.deviceSid,
    this.passHash,
    this.deviceMid,
    this.appVersion,
    this.deviceName,
    this.issuedAt,
    this.theme,
    this.remoteId,
  });

  /// 中继服务地址，如 `https://zcode.z.ai`。
  final String origin;

  /// `remoteControlToken` —— 仅网页控制台形态使用，走 REST。
  final String? token;

  /// `sid`：设备会话标识，Model B 凭证之一。
  final String? deviceSid;

  /// `hash`：HMAC 密钥（已 URL 解码），Model B 凭证之一。
  final String? passHash;

  /// `mid`：设备机器标识，作为 WS 的 `?mid=` 参数。
  final String? deviceMid;

  final String? appVersion;

  /// `name`：桌面端主机名，仅用于展示。
  final String? deviceName;

  /// `t`：链接签发时间（毫秒）。
  final int? issuedAt;

  final String? theme;

  /// 链接里若带 `remote=<id>`，走 `/ws/remote/<id>` 这条通道。
  final String? remoteId;

  /// 能否完成 HMAC 握手（Model B 的必要条件）。
  bool get canAuthenticate => deviceSid != null && passHash != null;

  /// 是否具备 REST 端点所需的 token（Model A）。
  bool get hasRestApi => token != null;

  static bool _notBlank(String? v) => v != null && v.trim().isNotEmpty;

  static String? _pick(String? v) => _notBlank(v) ? v!.trim() : null;

  static int? _pickInt(String? v) => int.tryParse(v?.trim() ?? '');

  /// 归一化 origin：补 scheme、剥掉路径与尾斜杠，只留 `scheme://host[:port]`。
  static String normalizeOrigin(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return s;
    if (!s.contains('://')) s = 'https://$s';
    final u = Uri.tryParse(s);
    if (u != null && u.host.isNotEmpty) {
      final port = u.hasPort ? ':${u.port}' : '';
      return '${u.scheme}://${u.host}$port';
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Uri get httpBase => Uri.parse(origin);

  /// 把 http(s) 换成 ws(s)，保留 host 与端口。
  Uri get wsBase {
    final u = httpBase;
    return u.replace(scheme: u.scheme == 'https' ? 'wss' : 'ws');
  }

  /// **Model B 主通道**：`wss://<origin>/ws`（连接时另加 `?mid=`）。
  Uri get relaySocketUrl => wsBase.replace(path: '/ws');

  /// 带 `?remote=` 时的直连通道。
  Uri? get remoteSocketUrl =>
      remoteId == null ? null : wsBase.replace(path: '/ws/remote/$remoteId');

  // ---- 以下为 Model A（网页控制台）的 REST 端点，token 缺失时返回 null ----

  Uri? get bootstrapUrl =>
      _withToken((t) => '$origin/api/remote-control/windows/bootstrap/$t');

  Uri? get windowSocketUrl => _withToken(
    (t) => wsBase.replace(path: '/ws/remote-control/window/$t').toString(),
  );

  Uri? get workspaceBridgeUrl => _withToken(
    (t) => '$origin/api/remote-control/windows/$t/workspace-bridge',
  );

  Uri? get viewStateUrl => _withToken(
    (t) => '$origin/api/remote-control/windows/$t/mobile-view-state',
  );

  Uri? get platformUrl =>
      _withToken((t) => '$origin/api/remote-control/platform/$t');

  Uri? _withToken(String Function(String token) build) {
    final t = token;
    if (t == null) return null;
    return Uri.parse(build(t));
  }

  /// 从已保存的设备字段解析。返回 null 表示这不是一条 relay 远控记录。
  static RelayLink? from({
    required String baseUrl,
    required Map<String, String> params,
  }) {
    final originRaw =
        _pick(params['relayOrigin']) ?? _pick(params['origin']) ?? baseUrl;
    return _build(params, originRaw, baseUrl);
  }

  /// 从任意 URL 解析（扫码结果可能整条是链接）。
  static RelayLink? fromUri(Uri uri) => _build(
    uri.queryParameters,
    // 显式 relayOrigin 优先；否则落到链接自身 origin。
    _pick(uri.queryParameters['relayOrigin']) ??
        _pick(uri.queryParameters['origin']) ??
        '${uri.scheme}://${uri.authority}',
    uri.toString(),
  );

  static RelayLink? _build(
    Map<String, String> qp,
    String originRaw,
    String fallback,
  ) {
    final deviceSid =
        _pick(qp['sid']) ?? _pick(qp['deviceSid']) ?? _pick(qp['device_sid']);
    final token = _pick(qp['remoteControlToken']);
    // 两个凭证都没有，就不是远控链接。
    if (deviceSid == null && token == null) return null;

    final origin = _notBlank(originRaw)
        ? originRaw
        : (Uri.tryParse(fallback)?.origin ?? '');
    if (!_notBlank(origin)) return null;

    return RelayLink(
      origin: normalizeOrigin(origin),
      token: token,
      deviceSid: deviceSid,
      passHash:
          _pick(qp['hash']) ?? _pick(qp['passHash']) ?? _pick(qp['pass_hash']),
      deviceMid: _pick(qp['mid']) ?? _pick(qp['deviceMid']),
      appVersion: _pick(qp['app_version']) ?? _pick(qp['appVersion']),
      deviceName: _pick(qp['name']),
      issuedAt: _pickInt(qp['t']),
      theme: _pick(qp['theme']),
      remoteId: _pick(qp['remote']),
    );
  }

  /// 解析扫码/粘贴得到的一整条链接。
  static RelayLink? parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    return fromUri(uri);
  }

  /// 是否达到 v4 门槛（服务端据此决定 /remote/v4 还是 /remote/v3）。
  /// 阈值与桌面端实现一致：主版本 > 3，或 3.x 且 x ≥ 4 走 v4。
  static bool usesV4(String? appVersion) {
    if (appVersion == null) return false;
    final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)').firstMatch(appVersion.trim());
    if (m == null) return false;
    final major = int.tryParse(m.group(1)!) ?? 0;
    final minor = int.tryParse(m.group(2)!) ?? 0;
    if (major != 3) return major > 3;
    return minor >= 4;
  }
}

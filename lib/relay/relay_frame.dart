import 'dart:convert';

/// 传输层上限，取自桌面端 `ao` 常量对象。
abstract final class RelayLimits {
  /// 单物理帧上限（`Ho.maxFrameBytes`）。
  static const int maxPhysicalFrameBytes = 1024 * 1024;

  /// 单逻辑消息上限。
  static const int maxMessageBytes = 16 * 1024 * 1024;

  /// 单消息最大分片数。
  static const int maxFragments = 64;

  /// 分片组装超时。
  static const Duration assemblyTimeout = Duration(seconds: 30);

  /// `bridgeSessionId` / `recoveryId` 最大长度。
  static const int transportIdMaxChars = 256;
}

/// 组包身份：同一逻辑帧必须三者一致才算同一条桥。
class RelayIdentity {
  const RelayIdentity({
    required this.bridgeSessionId,
    this.bridgeGeneration,
    this.recoveryId,
  });

  final String bridgeSessionId;
  final int? bridgeGeneration;
  final String? recoveryId;

  bool matches(RelayIdentity other) =>
      bridgeSessionId == other.bridgeSessionId &&
      bridgeGeneration == other.bridgeGeneration &&
      recoveryId == other.recoveryId;

  /// 空身份表示"尚未锁定"，任何帧都可接受并锁定它。
  bool get isEmpty => bridgeSessionId.isEmpty;

  @override
  String toString() =>
      'RelayIdentity($bridgeSessionId, gen=$bridgeGeneration, rec=$recoveryId)';
}

/// 外层信封：`{ type, payload, client_ts, server_ts }`。
///
/// 实测握手消息的字段是**平铺在顶层**的，而不是塞在 `payload` 里，例如：
/// `{"type":"auth_challenge","server_ts":1789014078,"nonce":"…"}`
/// 所以这里同时保留原始根对象 [raw]，供解析器「先看 payload 再看顶层」。
class RelayEnvelope {
  const RelayEnvelope({
    required this.type,
    required this.raw,
    this.payload,
    this.clientTs,
    this.serverTs,
  });

  final String type;

  /// 原始根对象（含平铺字段）。
  final Map<String, dynamic> raw;

  final Map<String, dynamic>? payload;
  final int? clientTs;
  final int? serverTs;

  /// 先取 `payload` 里的字段，取不到再看顶层。
  Object? field(String key) => payload?[key] ?? raw[key];

  static int? _asInt(dynamic v) => v is int ? v : (v is num ? v.toInt() : null);

  static RelayEnvelope? tryParse(String raw) {
    final dynamic root;
    try {
      root = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (root is! Map) return null;
    final map = Map<String, dynamic>.from(root);
    final type = map['type'];
    if (type is! String || type.isEmpty) return null;
    final payload = map['payload'];
    return RelayEnvelope(
      type: type,
      raw: map,
      payload: payload is Map ? Map<String, dynamic>.from(payload) : null,
      clientTs: _asInt(map['client_ts']),
      serverTs: _asInt(map['server_ts']),
    );
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    if (payload != null) 'payload': payload,
    if (clientTs != null) 'client_ts': clientTs,
    if (serverTs != null) 'server_ts': serverTs,
  };
}

/// 握手阶段的若干控制消息（只取我们需要的字段）。
class RelayHandshake {
  const RelayHandshake({
    required this.type,
    this.nonce,
    this.deviceSid,
    this.pairStatus,
  });

  final String type;
  final String? nonce;
  final String? deviceSid;
  final Map<String, dynamic>? pairStatus;

  static RelayHandshake? from(RelayEnvelope env) {
    switch (env.type) {
      case 'auth_challenge':
        // 实测 nonce 在顶层；兼容塞进 payload 的实现。
        final n = env.field('nonce');
        return RelayHandshake(type: env.type, nonce: n is String ? n : null);
      case 'device_register_ack':
        final sid = env.field('device_sid') ?? env.field('deviceSid');
        return RelayHandshake(
          type: env.type,
          deviceSid: sid is String ? sid : null,
        );
      case 'auth_ack':
      case 'pair_status_ack':
        final ps = env.field('pair_status') ?? env.field('pairStatus');
        return RelayHandshake(
          type: env.type,
          pairStatus: ps is Map ? Map<String, dynamic>.from(ps) : null,
        );
      case 'auth_init':
      case 'auth_response':
      case 'device_register':
      case 'pair_status_query':
      case 'data':
      case 'error':
        return RelayHandshake(type: env.type);
    }
    return null;
  }

  bool get isAck => type == 'auth_ack';
}

/// `rpc-frame` / `rpc-frame-ack` 负载。
class RpcFrame {
  const RpcFrame({
    required this.bridgeSessionId,
    this.bridgeGeneration,
    this.recoveryId,
    this.seq,
    this.messageSeq,
    this.fragmentIndex = 0,
    this.fragmentCount = 1,
    this.messageBytes,
    this.checksum,
    this.checksumAlgorithm,
    this.dataBase64,
    this.ackMessageSeq,
    this.isAck = false,
  });

  final String bridgeSessionId;
  final int? bridgeGeneration;
  final String? recoveryId;
  final int? seq;
  final int? messageSeq;
  final int fragmentIndex;
  final int fragmentCount;
  final int? messageBytes;
  final String? checksum;
  final String? checksumAlgorithm;
  final String? dataBase64;
  final int? ackMessageSeq;
  final bool isAck;

  RelayIdentity get identity => RelayIdentity(
    bridgeSessionId: bridgeSessionId,
    bridgeGeneration: bridgeGeneration,
    recoveryId: recoveryId,
  );

  /// 是否是本协议认识的原始传输候选。
  static bool isCandidate(dynamic payload) {
    if (payload is! Map) return false;
    final t = payload['zcode_type'];
    return t == 'rpc-frame' || t == 'rpc-frame-ack';
  }

  static int? _asInt(dynamic v) => v is int ? v : (v is num ? v.toInt() : null);

  /// 严格解析：形状不符返回 null，宁可丢弃不崩。
  static RpcFrame? tryParse(dynamic payload) {
    if (payload is! Map) return null;
    final t = payload['zcode_type'];
    if (t != 'rpc-frame' && t != 'rpc-frame-ack') return null;
    final sid = payload['bridgeSessionId'];
    if (sid is! String ||
        sid.isEmpty ||
        sid.length > RelayLimits.transportIdMaxChars) {
      return null;
    }
    final rec = payload['recoveryId'];
    if (rec != null &&
        (rec is! String || rec.length > RelayLimits.transportIdMaxChars)) {
      return null;
    }
    final fragCount = _asInt(payload['fragmentCount']) ?? 1;
    final fragIndex = _asInt(payload['fragmentIndex']) ?? 0;
    if (fragCount < 1 || fragCount > RelayLimits.maxFragments) return null;
    if (fragIndex < 0 || fragIndex >= fragCount) return null;

    final data = payload['dataBase64'];
    if (t == 'rpc-frame') {
      if (data is! String || data.isEmpty) return null;
      final bytesHint = _asInt(payload['messageBytes']);
      if (bytesHint != null &&
          (bytesHint <= 0 || bytesHint > RelayLimits.maxMessageBytes)) {
        return null;
      }
      // Base64 expands bytes by roughly 4/3. Reject obviously oversized
      // fragments before allocating/decoding them.
      final maxEncoded =
          (RelayLimits.maxPhysicalFrameBytes * 4 ~/ 3) + 16 * 1024;
      if (data.length > maxEncoded) return null;
    }

    final checksum = payload['checksum'];
    final checksumMap = checksum is Map
        ? Map<String, dynamic>.from(checksum)
        : null;

    return RpcFrame(
      bridgeSessionId: sid,
      bridgeGeneration: _asInt(payload['bridgeGeneration']),
      recoveryId: rec is String ? rec : null,
      seq: _asInt(payload['seq']),
      messageSeq: _asInt(payload['messageSeq']),
      fragmentIndex: fragIndex,
      fragmentCount: fragCount,
      messageBytes: _asInt(payload['messageBytes']),
      checksum:
          checksumMap?['value']?.toString() ??
          (checksum is String ? checksum : null),
      checksumAlgorithm:
          checksumMap?['algorithm']?.toString() ??
          payload['checksumAlgorithm']?.toString(),
      dataBase64: data is String ? data : null,
      ackMessageSeq: _asInt(payload['ackMessageSeq']),
      isAck: t == 'rpc-frame-ack',
    );
  }
}

/// 上游用一套 URL 安全、容忍缺失填充的 base64 编解码器（`decodeWireBase64`）。
///
/// ⚠️ **实测两种字母表都要接受**：桌面端下行的 `dataBase64` 用的是**标准 base64**
/// （含 `+` `/` `=`），而我们自己上行时用 URL-safe 无填充。早先只认 URL-safe，
/// 结果把桌面端 1000+ 字节的正文帧整条拒掉了（`tryDecode` 返回 null）。
abstract final class WireBase64 {
  /// 标准与 URL-safe 合并字母表：索引 62/63 同时映射 `+`/`-` 与 `/`/`_`。
  static const String _std =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
      'abcdefghijklmnopqrstuvwxyz'
      '0123456789+/';
  static const String _url =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
      'abcdefghijklmnopqrstuvwxyz'
      '0123456789-_';

  static int _indexOf(int codeUnit) {
    if (codeUnit == 0x2B || codeUnit == 0x2D) return 62; // '+' or '-'
    if (codeUnit == 0x2F || codeUnit == 0x5F) return 63; // '/' or '_'
    final i = _std.indexOf(String.fromCharCode(codeUnit));
    if (i >= 0) return i;
    return _url.indexOf(String.fromCharCode(codeUnit));
  }

  /// 解码；含非法字符返回 null。接受标准/URL-safe 两种字母表，容忍填充。
  static List<int>? tryDecode(String input) {
    if (input.isEmpty) return null;
    final out = <int>[];
    var i = 0;
    while (i < input.length) {
      // 跳过填充
      while (i < input.length && input.codeUnitAt(i) == 0x3D) {
        i++;
      }
      if (i >= input.length) break;
      final remain = input.length - i;
      final c0 = _indexOf(input.codeUnitAt(i));
      final c1 = remain > 1 ? _indexOf(input.codeUnitAt(i + 1)) : -1;
      final c2 = remain > 2 ? _indexOf(input.codeUnitAt(i + 2)) : -1;
      final c3 = remain > 3 ? _indexOf(input.codeUnitAt(i + 3)) : -1;
      if (c0 < 0 || c1 < 0) return null;
      out.add(((c0 << 2) | (c1 >> 4)) & 0xFF);
      if (c2 >= 0) {
        out.add(((c1 << 4) | (c2 >> 2)) & 0xFF);
        if (c3 >= 0) out.add(((c2 << 6) | c3) & 0xFF);
      }
      i += 4;
    }
    return out;
  }

  /// 解码为 UTF-8 文本；失败返回 null。
  static String? tryDecodeUtf8(String input) {
    final bytes = tryDecode(input);
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }
}

/// CRC-32（IEEE 802.3），用于校验重组后的逻辑帧。
abstract final class Crc32 {
  static final List<int> _table = _buildTable();

  static List<int> _buildTable() {
    final t = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
      }
      t[i] = c;
    }
    return t;
  }

  static int of(List<int> bytes) {
    var crc = 0xFFFFFFFF;
    for (final b in bytes) {
      crc = _table[(crc ^ b) & 0xFF] ^ (crc >> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}

/// zcode 二进制 agentService RPC 编解码（v1.4.0）。
///
/// 格式来自 `docs/RELAY-PROTOCOL-VERIFIED.md` §8.2/§8.4（V1 时代对官方
/// 117 帧上行逐字节验证过；2026-10 又与 3.16.3 bundle 交叉核对）：
///
/// ```
/// 请求 04 04 06 64 06 <varint seq> 01 <len> <service> 01 <len> <method> <args>
/// 响应 04 02 06 <type> 01 06 <varint seq> 05 <varint len> <json>
/// ```
///
/// * 请求 kind：0x64('d') 方法调用；args = `04 <varint 个数> <值…>`；
/// * 值标签：0x01 字符串、0x05 JSON（对象/列表直接传，勿先 jsonEncode）；
/// * `dataBase64` 是**标准 base64 带填充**（URL-safe 会被拒）；
/// * `checksum.value` 是标准 IEEE CRC-32 的十六进制；
/// * 响应 `seq` 是桌面端自己的计数器，**不回显请求序号**——按内容配对。
library;

import 'dart:convert';
import 'dart:typed_data';

abstract final class AgentWire {
  static const int _tagString = 0x01;
  static const int _tagJson = 0x05;

  // ---- varint ----

  static void writeVarint(BytesBuilder out, int value) {
    var v = value;
    while (v >= 0x80) {
      out.addByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    out.addByte(v);
  }

  static int readVarint(Uint8List bytes, int offset, List<int> cursor) {
    var result = 0;
    var shift = 0;
    var i = offset;
    while (i < bytes.length) {
      final b = bytes[i];
      i += 1;
      result |= (b & 0x7F) << shift;
      if (b & 0x80 == 0) break;
      shift += 7;
      if (shift > 35) break; // 防御：varint 最多 5 字节
    }
    cursor[0] = i;
    return result;
  }

  // ---- 值编码 ----

  static void writeString(BytesBuilder out, String value) {
    final bytes = utf8.encode(value);
    out.addByte(_tagString);
    writeVarint(out, bytes.length);
    out.add(bytes);
  }

  static void writeJson(BytesBuilder out, Object? value) {
    final bytes = utf8.encode(jsonEncode(value));
    out.addByte(_tagJson);
    writeVarint(out, bytes.length);
    out.add(bytes);
  }

  /// 按声明顺序编码参数值（字符串→string 标签；Map/List→JSON 标签）。
  static void writeArgs(BytesBuilder out, List<Object?> args) {
    out.addByte(0x04);
    writeVarint(out, args.length);
    for (final arg in args) {
      if (arg is String) {
        writeString(out, arg);
      } else {
        writeJson(out, arg);
      }
    }
  }

  // ---- 请求帧 ----

  /// 编码一条方法调用（'d' 帧）。返回请求体（不含外层 rpc-frame 信封）。
  static Uint8List encodeRequest({
    required int seq,
    required String service,
    required String method,
    List<Object?> args = const [],
  }) {
    final out = BytesBuilder();
    out.addByte(0x04);
    out.addByte(0x04); // 请求方向
    out.addByte(0x06);
    out.addByte(0x64); // 'd' 方法调用
    out.addByte(0x06);
    writeVarint(out, seq);
    out.addByte(0x01);
    writeVarint(out, utf8.encode(service).length);
    out.add(utf8.encode(service));
    out.addByte(0x01);
    writeVarint(out, utf8.encode(method).length);
    out.add(utf8.encode(method));
    writeArgs(out, args);
    return out.toBytes();
  }

  // ---- 响应帧 ----

  /// 解码响应：成功时返回 JSON（String/Map/List），失败返回 null（type 0xCA）。
  /// 头不合法（非 04 02 / 截断）也返回 null。
  static Object? tryDecodeResponse(Uint8List bytes) {
    if (bytes.length < 4) return null;
    if (bytes[0] != 0x04 || bytes[1] != 0x02) return null;
    final type = bytes[3]; // bytes[2] == 0x06 标签
    final cursor = [4];
    // bytes[4] == 0x01 标签；然后 0x06；然后 varint seq。
    if (bytes.length <= cursor[0] || bytes[cursor[0]] != 0x01) return null;
    cursor[0] += 1;
    if (bytes.length <= cursor[0] || bytes[cursor[0]] != 0x06) return null;
    cursor[0] += 1;
    readVarint(bytes, cursor[0], cursor); // seq（桌面端计数器，忽略）
    if (bytes.length <= cursor[0] || bytes[cursor[0]] != 0x05) return null;
    cursor[0] += 1;
    final len = readVarint(bytes, cursor[0], cursor);
    if (len < 0 || cursor[0] + len > bytes.length) return null;
    final jsonText = utf8.decode(
      bytes.sublist(cursor[0], cursor[0] + len),
      allowMalformed: true,
    );
    if (type == 0xCA) return null; // 失败体 {"message":"fault.…"}，调用方按超时处理
    try {
      return jsonDecode(jsonText);
    } catch (_) {
      return null;
    }
  }

  // ---- CRC-32（IEEE，多项式 0xEDB88320）----

  static final Uint32List _crcTable = _buildCrcTable();

  static Uint32List _buildCrcTable() {
    final table = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
      }
      table[i] = c;
    }
    return table;
  }

  static int crc32(List<int> data) {
    // 全程按无符号 32 位掩码（Int32 表格带符号，高位异或必错）。
    var crc = 0xFFFFFFFF;
    for (final b in data) {
      crc = (_crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8)) & 0xFFFFFFFF;
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  /// 十六进制小写、8 位补零（帧信封 checksum.value 的形态，如 "b4ff6360"）。
  static String crc32Hex(List<int> data) =>
      crc32(data).toRadixString(16).padLeft(8, '0');

  // ---- rpc-frame 信封 ----

  /// 标准 base64 **带填充**（官方 117 帧实测：URL-safe 会被判 rpc-transport-fault）。
  static String encodePayloadBase64(List<int> bytes) => base64.encode(bytes);

  static Uint8List decodePayloadBase64(String text) => base64.decode(
    text.replaceAll('-', '+').replaceAll('_', '/'),
  );

  /// 组装一条上行 rpc-frame 信封（单片；监控写路径的命令都很小，不分片）。
  static Map<String, Object?> rpcFrameEnvelope({
    required String bridgeSessionId,
    required int bridgeGeneration,
    required int messageSeq,
    required Uint8List payload,
  }) => {
    'zcode_type': 'rpc-frame',
    'bridgeSessionId': bridgeSessionId,
    'bridgeGeneration': bridgeGeneration,
    'checksum': {'algorithm': 'crc32', 'value': crc32Hex(payload)},
    'dataBase64': encodePayloadBase64(payload),
    'fragmentCount': 1,
    'fragmentIndex': 0,
    'messageBytes': payload.length,
    'messageSeq': messageSeq,
    'seq': messageSeq,
  };

  /// 回执信封：不回 ack 会被同 messageSeq 反复重传（V1 实测）。
  static Map<String, Object?> ackEnvelope({
    required String bridgeSessionId,
    required int bridgeGeneration,
    required int ackMessageSeq,
  }) => {
    'zcode_type': 'rpc-frame-ack',
    'bridgeSessionId': bridgeSessionId,
    'bridgeGeneration': bridgeGeneration,
    'ackMessageSeq': ackMessageSeq,
  };

  // ---- 命令信封（页面 Bl() 的等价实现，bundle 实证）----

  static Map<String, Object?> commandEnvelope({
    required String commandId,
    required String clientId,
    required String type,
    String? sessionId,
    Object? payload,
  }) => {
    'commandId': commandId,
    'clientId': clientId,
    if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
    'type': type,
    'payload': payload ?? <String, Object?>{},
    'issuedAt': DateTime.now().millisecondsSinceEpoch,
  };
}

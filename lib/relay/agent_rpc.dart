/// agentService RPC 的二进制编解码。
///
/// 这是 `rpc-frame.dataBase64` 里真正装的东西——**不是 JSON**。
/// 通过抓取官方页面在真实远控会话中的上行（114 帧）逆向得出，样本全部可解析。
///
/// 帧结构：
/// ```
/// 04 04 06 <kind> 06 <varint seq> 01 <varint len> <service>
///          01 <varint len> <method> <args>
/// ```
/// - `kind`：`0x64`('d') = 方法调用；`0x66`('f') = 事件订阅/回调注册
/// - `service` / `method`：UTF-8，长度用 varint 前缀
/// - `args`：
///   - 'd'：`04 <varint 参数个数>` 后跟若干「带类型标签的值」
///   - 'f'：直接是单个值，或 `00` 表示无参
/// - 值标签：`0x01` = 字符串，`0x05` = JSON
library;

import 'dart:convert';
import 'dart:typed_data';

/// 一条 RPC 响应。
///
/// 与请求**头部不同**（这是踩过的坑）：
/// ```
/// 请求 04 04 06 <kind> 06 <varint seq> 01 <len> <service> 01 <len> <method> <args>
/// 响应 04 02 06 <type> 01 06 <varint seq> 05 <varint len> <json>
/// ```
/// 实测两条响应仅第 6 字节不同（`01`/`02` 即 seq），据此定出字段位置。
///
/// ⚠️ 响应的 `seq` 是**桌面端自己的计数器**，不会回显我们的请求序号，
/// 所以按 seq 配对并不可靠——按内容（如 `kind`）匹配更稳。
class AgentResponse {
  const AgentResponse({required this.type, required this.seq, this.value});

  /// 类型字节。实测 `0xC9`(201) 为正常响应。
  final int type;

  /// 序号。
  final int seq;

  /// 响应体（通常是 JSON）。
  final Object? value;

  bool get isOk => type == AgentResponseType.ok;

  bool get isError => type == AgentResponseType.error;

  /// 失败时的 `fault.*` 原因（形如 `fault.connection.clientChanged`）。
  String? get faultReason {
    final v = value;
    if (v is Map) {
      final m = v['message'];
      if (m is String && m.isNotEmpty) return m;
    }
    return null;
  }

  @override
  String toString() => 'response(type=$type, seq=$seq)';
}

/// 响应类型字节。
abstract final class AgentResponseType {
  /// 成功（实测 `0xC9`）。
  static const int ok = 0xC9;

  /// 失败（实测 `0xCA`）。响应体形如
  /// `{"message":"fault.…","name":"Error","stack":[…]}`。
  static const int error = 0xCA;
}

/// 帧种类。
enum AgentFrameKind {
  /// 方法调用（'d'）。
  call(0x64),

  /// 事件订阅 / 回调注册（'f'）。
  subscribe(0x66);

  const AgentFrameKind(this.code);
  final int code;

  static AgentFrameKind? fromCode(int c) => switch (c) {
    0x64 => AgentFrameKind.call,
    0x66 => AgentFrameKind.subscribe,
    _ => null,
  };
}

/// 值标签。
abstract final class _Tag {
  static const int string = 0x01;
  static const int argsArray = 0x04;
  static const int json = 0x05;
}

/// 一条 agentService RPC。
class AgentRpc {
  const AgentRpc({
    required this.kind,
    required this.seq,
    required this.service,
    required this.method,
    this.args = const [],
  });

  final AgentFrameKind kind;
  final int seq;
  final String service;
  final String method;

  /// 参数。
  ///
  /// ⚠️ **`String` 会按「字符串标签」编码，其余按「JSON 标签」编码。**
  /// 想把一个对象当 JSON 传，**必须传 Map/List，不要自己 `jsonEncode`**，
  /// 否则对端会当成普通字符串。
  final List<Object?> args;

  /// 构造一条方法调用（kind = 'd'）。
  factory AgentRpc.call({
    required int seq,
    required String service,
    required String method,
    List<Object?> args = const [],
  }) => AgentRpc(
    kind: AgentFrameKind.call,
    seq: seq,
    service: service,
    method: method,
    args: args,
  );

  /// 构造一条事件订阅（kind = 'f'）。订阅帧只接受单个参数。
  factory AgentRpc.subscribe({
    required int seq,
    required String service,
    required String method,
    Object? arg,
  }) => AgentRpc(
    kind: AgentFrameKind.subscribe,
    seq: seq,
    service: service,
    method: method,
    args: arg == null ? const [] : [arg],
  );

  @override
  String toString() =>
      '${kind.name} $service.$method(seq=$seq, args=${args.length})';
}

/// 编码器。
abstract final class AgentRpcCodec {
  static const int _header0 = 0x04;
  static const int _header1 = 0x04;

  /// 响应帧的第二字节（请求是 `0x04`）。
  static const int _responseHeader1 = 0x02;

  /// 响应头里 `type` 之后的固定标记字节（实测恒为 `0x06`）。
  static const int _responseMarker = 0x06;

  static const int _header2 = 0x06;
  static const int _sep = 0x01;

  /// varint（LEB128，无符号）。
  static void writeVarint(BytesBuilder out, int value) {
    var v = value;
    if (v < 0) throw ArgumentError('varint 不接受负数: $value');
    while (true) {
      final b = v & 0x7F;
      v >>>= 7;
      if (v == 0) {
        out.addByte(b);
        return;
      }
      out.addByte(b | 0x80);
    }
  }

  /// 读取 varint，返回 (值, 下一个位置)。越界返回 null。
  static ({int value, int next})? tryReadVarint(Uint8List b, int i) {
    var value = 0;
    var shift = 0;
    var idx = i;
    while (idx < b.length) {
      final x = b[idx++];
      value |= (x & 0x7F) << shift;
      if ((x & 0x80) == 0) return (value: value, next: idx);
      shift += 7;
      if (shift > 56) return null;
    }
    return null;
  }

  static void _writeString(BytesBuilder out, String s) {
    final bytes = utf8.encode(s);
    writeVarint(out, bytes.length);
    out.add(bytes);
  }

  /// 编码一条 RPC 为字节。
  static Uint8List encode(AgentRpc rpc) {
    final out = BytesBuilder(copy: false);
    out.addByte(_header0);
    out.addByte(_header1);
    out.addByte(_header2);
    out.addByte(rpc.kind.code);
    out.addByte(_header2);
    writeVarint(out, rpc.seq);
    out.addByte(_sep);
    _writeString(out, rpc.service);
    out.addByte(_sep);
    _writeString(out, rpc.method);

    switch (rpc.kind) {
      case AgentFrameKind.call:
        if (rpc.args.isEmpty) {
          out.addByte(_Tag.argsArray);
          writeVarint(out, 0);
        } else {
          out.addByte(_Tag.argsArray);
          writeVarint(out, rpc.args.length);
          for (final a in rpc.args) {
            _writeValue(out, a);
          }
        }
      case AgentFrameKind.subscribe:
        if (rpc.args.isEmpty) {
          out.addByte(0x00);
        } else {
          // 订阅帧不套参数数组，直接写单个值。
          _writeValue(out, rpc.args.first);
        }
    }
    return out.toBytes();
  }

  static void _writeValue(BytesBuilder out, Object? value) {
    if (value is String) {
      out.addByte(_Tag.string);
      _writeString(out, value);
      return;
    }
    out.addByte(_Tag.json);
    _writeString(out, jsonEncode(value));
  }

  /// 解码一条 RPC。形状不符返回 null（宁可丢弃不崩）。
  static AgentRpc? tryDecode(Uint8List b) {
    if (b.length < 8) return null;
    if (b[0] != _header0 || b[1] != _header1 || b[2] != _header2) return null;
    final kind = AgentFrameKind.fromCode(b[3]);
    if (kind == null) return null;
    if (b[4] != _header2) return null;

    var i = 5;
    final seqR = tryReadVarint(b, i);
    if (seqR == null) return null;
    i = seqR.next;
    if (i >= b.length || b[i] != _sep) return null;
    i++;

    final svcR = _readString(b, i);
    if (svcR == null) return null;
    i = svcR.next;
    if (i >= b.length || b[i] != _sep) return null;
    i++;

    final mR = _readString(b, i);
    if (mR == null) return null;
    i = mR.next;

    final args = <Object?>[];
    if (i < b.length) {
      if (kind == AgentFrameKind.call) {
        if (b[i] != _Tag.argsArray) return null;
        i++;
        final nR = tryReadVarint(b, i);
        if (nR == null) return null;
        i = nR.next;
        for (var k = 0; k < nR.value; k++) {
          final v = _readValue(b, i);
          if (v == null) return null;
          args.add(v.value);
          i = v.next;
        }
      } else {
        if (b[i] == 0x00) {
          i++;
        } else {
          final v = _readValue(b, i);
          if (v == null) return null;
          args.add(v.value);
          i = v.next;
        }
      }
    }

    return AgentRpc(
      kind: kind,
      seq: seqR.value,
      service: svcR.value,
      method: mR.value,
      args: args,
    );
  }

  static ({String value, int next})? _readString(Uint8List b, int i) {
    final r = tryReadVarint(b, i);
    if (r == null) return null;
    final end = r.next + r.value;
    if (end > b.length) return null;
    return (
      value: utf8.decode(b.sublist(r.next, end), allowMalformed: true),
      next: end,
    );
  }

  static ({Object? value, int next})? _readValue(Uint8List b, int i) {
    if (i >= b.length) return null;
    final tag = b[i];
    final r = tryReadVarint(b, i + 1);
    if (r == null) return null;
    final end = r.next + r.value;
    if (end > b.length) return null;
    final raw = b.sublist(r.next, end);
    switch (tag) {
      case _Tag.string:
        return (value: utf8.decode(raw, allowMalformed: true), next: end);
      case _Tag.json:
        try {
          return (value: jsonDecode(utf8.decode(raw)), next: end);
        } catch (_) {
          // JSON 解析失败也把原文带出去，便于诊断。
          return (value: utf8.decode(raw, allowMalformed: true), next: end);
        }
      default:
        return null;
    }
  }

  /// 解码一条 RPC 响应。形状不符返回 null。
  static AgentResponse? tryDecodeResponse(Uint8List b) {
    if (b.length < 8) return null;
    if (b[0] != _header0 || b[1] != _responseHeader1 || b[2] != _header2) {
      return null;
    }
    final type = b[3];
    var i = 4;
    // 实测固定前缀：01 06
    if (i < b.length && b[i] == _sep) i++;
    if (i < b.length && b[i] == _responseMarker) i++;

    final seqR = tryReadVarint(b, i);
    if (seqR == null) return null;
    i = seqR.next;

    if (i >= b.length) {
      return AgentResponse(type: type, seq: seqR.value);
    }
    // 无响应体
    if (b[i] == 0x00) {
      return AgentResponse(type: type, seq: seqR.value);
    }
    if (b[i] == _sep) i++;
    if (i >= b.length) {
      return AgentResponse(type: type, seq: seqR.value);
    }

    final v = _readValue(b, i);
    if (v == null) return null;
    return AgentResponse(type: type, seq: seqR.value, value: v.value);
  }

  /// 该字节序列是否是响应（`04 02`）。
  static bool looksLikeResponse(Uint8List b) =>
      b.length >= 4 && b[0] == _header0 && b[1] == _responseHeader1;

  /// 调试用：把字节渲染成 hex + 可读 ASCII。
  static String describe(Uint8List b) {
    final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');
    final asc = b
        .map((x) => x >= 32 && x < 127 ? String.fromCharCode(x) : '.')
        .join();
    return 'hex=$hex\ntxt=$asc';
  }
}

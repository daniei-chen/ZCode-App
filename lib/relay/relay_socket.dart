import 'dart:async';
import 'dart:io';

/// WebSocket 抽象：把 `dart:io` 依赖挡在边界外，便于单测替换。
abstract interface class RelaySocket {
  Stream<String> get messages;

  void send(String data);

  Future<void> close([int? code, String? reason]);
}

abstract interface class RelaySocketFactory {
  Future<RelaySocket> connect(
    Uri url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 20),
  });
}

/// 生产实现：`dart:io` WebSocket。
///
/// [httpClient] 可选注入，用于需要走系统/自定义代理的环境（例如桌面端抓包调试）；
/// 手机端正常运行时留空即可。
class IoRelaySocketFactory implements RelaySocketFactory {
  const IoRelaySocketFactory({this.httpClient});

  final HttpClient? httpClient;

  @override
  Future<RelaySocket> connect(
    Uri url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final ws = await WebSocket.connect(
      url.toString(),
      headers: headers,
      customClient: httpClient,
    ).timeout(timeout);
    ws.pingInterval = const Duration(seconds: 30);
    return _IoRelaySocket(ws);
  }
}

class _IoRelaySocket implements RelaySocket {
  _IoRelaySocket(this._ws);

  final WebSocket _ws;

  @override
  Stream<String> get messages => _ws.map((e) => e is String ? e : e.toString());

  @override
  void send(String data) {
    if (_ws.readyState == WebSocket.open) _ws.add(data);
  }

  @override
  Future<void> close([int? code, String? reason]) =>
      _ws.close(code ?? WebSocketStatus.normalClosure, reason);
}

/// 测试用：内存 socket，可手动注入消息。
class FakeRelaySocket implements RelaySocket {
  FakeRelaySocket({this.onSend});

  /// 收到上行时的回调，可在测试中途替换。
  void Function(String data)? onSend;
  final _controller = StreamController<String>.broadcast();
  final List<String> sent = [];
  bool closed = false;

  @override
  Stream<String> get messages => _controller.stream;

  @override
  void send(String data) {
    sent.add(data);
    onSend?.call(data);
  }

  /// 注入一条服务端消息。
  void emit(String data) => _controller.add(data);

  /// 注入一条 JSON 消息。
  void emitJson(Map<String, dynamic> data) => emit(_encode(data));

  static String _encode(Map<String, dynamic> data) {
    final buf = StringBuffer('{');
    var first = true;
    for (final e in data.entries) {
      if (!first) buf.write(',');
      first = false;
      buf.write('"${e.key}":${_jsonValue(e.value)}');
    }
    buf.write('}');
    return buf.toString();
  }

  static String _jsonValue(Object? v) {
    if (v == null) return 'null';
    if (v is num || v is bool) return '$v';
    if (v is String) {
      final escaped = v
          .replaceAll(r'\', r'\\')
          .replaceAll('"', r'\"')
          .replaceAll('\n', r'\n');
      return '"$escaped"';
    }
    if (v is Map) {
      final buf = StringBuffer('{');
      var first = true;
      for (final e in v.entries) {
        if (!first) buf.write(',');
        first = false;
        buf.write('"${e.key}":${_jsonValue(e.value)}');
      }
      buf.write('}');
      return buf.toString();
    }
    if (v is List) {
      return '[${v.map(_jsonValue).join(',')}]';
    }
    return '"${v.toString()}"';
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    closed = true;
    await _controller.close();
  }
}

/// 测试用：可编排连接结果与句柄。
class FakeRelaySocketFactory implements RelaySocketFactory {
  FakeRelaySocketFactory({this.socket, this.error});

  FakeRelaySocket? socket;
  Object? error;
  final List<Uri> connected = [];
  final List<Map<String, String>?> headerSets = [];

  @override
  Future<RelaySocket> connect(
    Uri url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    connected.add(url);
    headerSets.add(headers);
    if (error != null) throw error!;
    return socket ?? FakeRelaySocket();
  }
}

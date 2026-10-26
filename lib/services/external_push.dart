import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/monitor_state_store.dart';

/// 外置通知通道客户端（v1.8.0）。
///
/// 背景：ZCode 的中继是"单控制端"语义——同一台电脑同时只允许一个手机
/// 终端。App 内已经有两条终端（会话页 / 后台监控），它们与"另一个自己"
/// 抢槽位时表现为"一直被其他设备接管"。再开终端只会加剧冲突。
///
/// 本通道换了一条完全不同的路：**桌面端在事件发生时主动把消息推出来**
/// （ZCode hook 的 `PermissionRequest` / `Stop` 事件 → HTTP POST →
/// zcode-push 服务 → 本客户端长轮询）。全程不碰 relay 终端槽位，因此
/// 与页面、监控引擎天然互不干扰。
///
/// 三条设计约束：
/// * **游标持久化**：UI 引擎与头无引擎都会轮询，共享 `zr.push.cursor`，
///   谁先取到谁发通知，不会双响；
/// * **失败静默降级**：服务器不可达只是"这条备用通道暂不可用"，绝不影响
///   既有的 relay 链路（不抛、不重试风暴——固定 5s 退避）；
/// * **内容有界**：消息体在服务端已截断（标题 200 / 正文 600），客户端
///   再截一次，防止异常服务端把通知撑爆。
class ExternalPushMessage {
  const ExternalPushMessage({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    this.sessionId = '',
    this.device = '',
    this.ts = 0,
  });

  final int id;

  /// `permission` = 审批请求；`completed` = 任务结束；其余按信息处理。
  final String kind;
  final String title;
  final String body;
  final String sessionId;
  final String device;
  final int ts;

  static ExternalPushMessage? fromJson(Map<dynamic, dynamic> json) {
    final id = json['id'];
    if (id is! int) return null;
    String read(String key, int limit) {
      final value = json[key];
      if (value is! String) return '';
      final text = value.replaceAll('\u0000', ' ').trim();
      return text.length > limit ? text.substring(0, limit) : text;
    }

    final title = read('title', 200);
    final body = read('body', 600);
    if (title.isEmpty && body.isEmpty) return null;
    final ts = json['ts'];
    return ExternalPushMessage(
      id: id,
      kind: read('kind', 40).isEmpty ? 'info' : read('kind', 40),
      title: title,
      body: body,
      sessionId: read('sessionId', 120),
      device: read('device', 120),
      ts: ts is int ? ts : 0,
    );
  }

  /// 通知标题：优先用 hook 给的标题，缺省按类型给中文文案。
  String get notifTitle {
    if (title.isNotEmpty) return title;
    return switch (kind) {
      'permission' => '需要你的审批',
      'completed' => '任务已完成',
      _ => 'ZCode',
    };
  }
}

/// 客户端配置（服务地址 + 令牌）。两者都为空 = 未启用。
class ExternalPushConfig {
  const ExternalPushConfig({this.baseUrl = '', this.token = ''});

  /// 例如 `https://zhihui.kaogong.art`（不带尾部斜杠、不含 /zpush）。
  final String baseUrl;
  final String token;

  bool get enabled =>
      baseUrl.isNotEmpty && token.isNotEmpty && token.length >= 16;

  bool get isEmpty => baseUrl.isEmpty && token.isEmpty;

  String get pollUrl =>
      '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/zpush/poll';

  String get ackUrl => '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/zpush/ack';
}

/// 轮询结果：成功时带回新消息与「下一个游标」；失败为空。
class ExternalPushBatch {
  const ExternalPushBatch({this.messages = const [], this.nextCursor});

  final List<ExternalPushMessage> messages;

  /// 服务端视角的游标（最大 id）。取不到时用最后一条消息的 id 兜底。
  final int? nextCursor;

  bool get isEmpty => messages.isEmpty;
}

/// 纯协议层（可单测）：解析轮询响应、合并游标。
abstract final class ExternalPushProtocol {
  /// 解析 `/zpush/poll` 响应；结构不符返回空批次而不是抛异常。
  static ExternalPushBatch parsePoll(String body, {required int after}) {
    try {
      final root = jsonDecode(body);
      if (root is! Map || root['ok'] != true) return const ExternalPushBatch();
      final raw = root['messages'];
      if (raw is! List) return const ExternalPushBatch();
      final messages = <ExternalPushMessage>[];
      var maxId = after;
      for (final item in raw) {
        if (item is! Map) continue;
        final message = ExternalPushMessage.fromJson(item);
        if (message == null) continue;
        if (message.id <= after) continue;
        messages.add(message);
        if (message.id > maxId) maxId = message.id;
      }
      messages.sort((a, b) => a.id.compareTo(b.id));
      return ExternalPushBatch(
        messages: messages,
        nextCursor: messages.isEmpty ? null : maxId,
      );
    } catch (_) {
      return const ExternalPushBatch();
    }
  }

  /// 至少 1 条才提交 ack；返回去重后的 id 列表。
  static List<int> ackIds(Iterable<int> ids) => ids.toSet().toList()..sort();

  /// 只接受 https（令牌走 header，但明文 http 仍不可接受）。
  static bool isAcceptableBaseUrl(String raw) {
    final text = raw.trim();
    if (text.isEmpty || text.length > 300) return false;
    final uri = Uri.tryParse(text);
    if (uri == null) return false;
    return uri.scheme == 'https' && uri.host.isNotEmpty;
  }
}

/// 拉取一次（长轮询，最长 25s）。失败返回空批次，绝不抛。
Future<ExternalPushBatch> fetchExternalPushOnce({
  required ExternalPushConfig config,
  required int after,
  Duration timeout = const Duration(seconds: 30),
}) async {
  if (!config.enabled) return const ExternalPushBatch();
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);
  try {
    final uri = Uri.parse('${config.pollUrl}?after=$after');
    final request = await client.getUrl(uri).timeout(timeout);
    request.headers.set('X-ZP-Token', config.token);
    request.headers.set('Accept', 'application/json');
    final response = await request.close().timeout(timeout);
    if (response.statusCode != 200) return const ExternalPushBatch();
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(timeout);
    return ExternalPushProtocol.parsePoll(body, after: after);
  } catch (_) {
    return const ExternalPushBatch();
  } finally {
    client.close(force: true);
  }
}

/// 提交已投递确认。失败无妨（服务端 7 天 / 2000 条上限兜底）。
Future<void> ackExternalPush({
  required ExternalPushConfig config,
  required List<int> ids,
}) async {
  if (!config.enabled) return;
  final clean = ExternalPushProtocol.ackIds(ids);
  if (clean.isEmpty) return;
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client
        .postUrl(Uri.parse(config.ackUrl))
        .timeout(const Duration(seconds: 15));
    request.headers.set('X-ZP-Token', config.token);
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode({'ids': clean})));
    final response = await request.close().timeout(
      const Duration(seconds: 15),
    );
    await response.drain<void>();
  } catch (_) {
  } finally {
    client.close(force: true);
  }
}

/// 游标存储（跨隔离体）：UI 引擎与头无引擎共用，保证不双响。
abstract final class ExternalPushCursor {
  static const _key = 'zr.push.cursor';

  static Future<int> read() async {
    try {
      final prefs = await MonitorStateStore.preferences();
      return prefs.getInt(_key) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> write(int value) async {
    try {
      final prefs = await MonitorStateStore.preferences();
      await prefs.setInt(_key, value);
    } catch (_) {}
  }
}

/// 后台轮询器（头无引擎用；UI 前台时由页面侧 provider 承担）。
class ExternalPushPoller {
  ExternalPushPoller({required this.config, required this.onMessage});

  final ExternalPushConfig config;

  /// 每条新消息回调（调用方负责发通知）。同一批内按 id 升序。
  final void Function(ExternalPushMessage message) onMessage;

  Timer? _timer;
  bool _running = false;
  bool _inFlight = false;

  static const interval = Duration(seconds: 5);

  void start() {
    if (_running || !config.enabled) return;
    _running = true;
    _schedule(Duration.zero);
  }

  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    if (!_running) return;
    _timer = Timer(delay, _tick);
  }

  Future<void> _tick() async {
    if (!_running) return;
    if (_inFlight) {
      _schedule(interval);
      return;
    }
    _inFlight = true;
    try {
      final cursor = await ExternalPushCursor.read();
      final batch = await fetchExternalPushOnce(config: config, after: cursor);
      if (!_running) return;
      if (!batch.isEmpty) {
        for (final message in batch.messages) {
          try {
            onMessage(message);
          } catch (_) {}
        }
        final next = batch.nextCursor ?? cursor;
        await ExternalPushCursor.write(next);
        unawaited(
          ackExternalPush(
            config: config,
            ids: batch.messages.map((m) => m.id).toList(),
          ),
        );
      }
    } finally {
      _inFlight = false;
    }
    if (_running) _schedule(interval);
  }
}

/// UI 引擎侧的前台轮询（后台由头无引擎的 [ExternalPushPoller] 接手）。
///
/// 只在「UI 真的可见」时轮询：`appLifecycleProvider == resumed`。这样既
/// 不会与头无引擎双跑，也不至于让前台页面在后台消耗流量。
class ExternalPushNotifier extends Notifier<ExternalPushConfig> {
  Timer? _timer;
  bool _running = false;
  bool _inFlight = false;

  @override
  ExternalPushConfig build() {
    ref.onDispose(() {
      _running = false;
      _timer?.cancel();
      _timer = null;
    });
    return const ExternalPushConfig();
  }

  /// 配置变更（设置页保存时调用）：立即生效，无需重启。
  void configure(ExternalPushConfig next) {
    if (next.baseUrl == state.baseUrl && next.token == state.token) return;
    state = next;
    _timer?.cancel();
    _timer = null;
    _running = false;
    if (next.enabled) startPolling();
  }

  void startPolling() {
    if (_running || !state.enabled) return;
    _running = true;
    _schedule(Duration.zero);
  }

  void stopPolling() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    if (!_running) return;
    _timer = Timer(delay, _tick);
  }

  /// 单次拉取（供诊断页/一键体检手动触发）。返回拉到的条数。
  Future<int> pollNow() async {
    final batch = await _fetch();
    return batch.messages.length;
  }

  Future<ExternalPushBatch> _fetch() async {
    final cursor = await ExternalPushCursor.read();
    return fetchExternalPushOnce(config: state, after: cursor);
  }

  Future<void> _tick() async {
    if (!_running) return;
    if (_inFlight) {
      _schedule(_interval);
      return;
    }
    _inFlight = true;
    try {
      final batch = await _fetch();
      if (!_running) return;
      if (!batch.isEmpty) {
        for (final message in batch.messages) {
          if (_onMessage != null) _onMessage!(message);
        }
        final next = batch.nextCursor ?? await ExternalPushCursor.read();
        await ExternalPushCursor.write(next);
        unawaited(
          ackExternalPush(
            config: state,
            ids: batch.messages.map((m) => m.id).toList(),
          ),
        );
      }
    } finally {
      _inFlight = false;
    }
    if (_running) _schedule(_interval);
  }

  /// 消息消费者（由 app 启动时注入：UI 引擎里负责发系统通知与进历史）。
  void Function(ExternalPushMessage message)? _onMessage;

  void setHandler(void Function(ExternalPushMessage message) handler) {
    _onMessage = handler;
  }

  static const _interval = Duration(seconds: 5);
}

final externalPushProvider =
    NotifierProvider<ExternalPushNotifier, ExternalPushConfig>(
      ExternalPushNotifier.new,
    );

/// 启动时读到的配置（main.dart 覆盖）；UI 各处只读不改，改配置走设置页。
final externalPushConfigProvider = Provider<ExternalPushConfig>(
  (ref) => const ExternalPushConfig(),
);

// 真实服务器联调测试（默认跳过；显式传 --dart-define=ZPUSH_INTEGRATION=1 才跑）。
//
// 目的：验证 App 的 HTTP 客户端代码（不是 mock）能正确与已部署的
// zcode-push 服务对话——包括真实 TLS、nginx 反代、鉴权头、长轮询超时、
// ack 语义。协议解析单测覆盖不到这些。
//
// 用法：
//   flutter test test/external_push_integration_test.dart \
//     --dart-define=ZPUSH_INTEGRATION=1 \
//     --dart-define=ZPUSH_BASE_URL=https://zhihui.kaogong.art \
//     --dart-define=ZPUSH_TOKEN=<token>
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/external_push.dart';

// 用运行期环境变量（flutter test 不把 --dart-define 传给测试进程的
// const 求值；Platform.environment 在 VM 测试里可靠）。
final _enabled = Platform.environment['ZPUSH_INTEGRATION'] == '1';
final _baseUrl = Platform.environment['ZPUSH_BASE_URL'] ?? '';
final _token = Platform.environment['ZPUSH_TOKEN'] ?? '';

void main() {
  group('外置通道真实服务器联调', () {
    late ExternalPushConfig config;

    setUpAll(() {
      config = ExternalPushConfig(baseUrl: _baseUrl, token: _token);
    });

    test('配置可用', () {
      expect(_enabled, isTrue, reason: '需环境变量 ZPUSH_INTEGRATION=1');
      expect(
        ExternalPushProtocol.isAcceptableBaseUrl(_baseUrl),
        isTrue,
        reason: '需环境变量 ZPUSH_BASE_URL=https://…',
      );
      expect(config.enabled, isTrue, reason: '需环境变量 ZPUSH_TOKEN=…');
    });

    test('错误令牌拉取返回空批次（不抛、不产生假通知）', () async {
      final wrong = ExternalPushConfig(
        baseUrl: _baseUrl,
        token: 'definitely-wrong-token-000000',
      );
      final batch = await fetchExternalPushOnce(
        config: wrong,
        after: 0,
        timeout: const Duration(seconds: 15),
      );
      expect(batch.isEmpty, isTrue);
    });

    test('上报 → 长轮询取回 → ack 后消失（完整往返）', () async {
      // 1) 用真实 HTTP 上报一条消息（走服务器的 publish 端点）。
      final marker = 'it-${DateTime.now().millisecondsSinceEpoch}';
      final client = HttpClient();
      final publishRequest = await client.postUrl(
        Uri.parse('${_baseUrl.replaceAll(RegExp(r'/+$'), '')}/zpush/publish'),
      );
      publishRequest.headers.set('X-ZP-Token', _token);
      publishRequest.headers.contentType = ContentType.json;
      publishRequest.add(
        utf8.encode(
          jsonEncode({
            'kind': 'permission',
            'title': marker,
            'body': '联调测试正文',
            'sessionId': 'it-session',
            'device': 'PC-IT',
          }),
        ),
      );
      final publishResponse = await publishRequest.close();
      expect(publishResponse.statusCode, 200);
      await publishResponse.drain<void>();

      // 2) 用 App 的客户端代码拉取（这是被测代码本身）。
      var found = false;
      ExternalPushBatch batch = const ExternalPushBatch();
      for (var attempt = 0; attempt < 6 && !found; attempt++) {
        batch = await fetchExternalPushOnce(
          config: config,
          after: 0,
          timeout: const Duration(seconds: 30),
        );
        found = batch.messages.any((m) => m.title == marker);
      }
      expect(found, isTrue, reason: '客户端应能解析服务器返回的这条消息');

      final message = batch.messages.firstWhere((m) => m.title == marker);
      expect(message.kind, 'permission');
      expect(message.sessionId, 'it-session');

      // 3) ack 后同一条不再返回。
      await ackExternalPush(config: config, ids: [message.id]);
      // 服务端删除是同步的；立刻再查一次。
      final afterAck = await fetchExternalPushOnce(
        config: config,
        after: 0,
        timeout: const Duration(seconds: 10),
      );
      expect(
        afterAck.messages.any((m) => m.id == message.id),
        isFalse,
        reason: 'ack 之后该消息应已被服务端删除',
      );
      client.close(force: true);
    }, timeout: const Timeout(Duration(minutes: 3)));
  }, skip: _enabled ? false : '联调测试默认跳过（见文件头用法）');
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zremote/services/bridge_message_pipeline.dart';
import 'package:zremote/services/link_builder.dart';
import 'package:zremote/services/update_service.dart';

/// v1.3.0 D：Bridge/解析器模糊测试。目标：不崩溃、不无限循环、fail-closed。
void main() {
  String repeat(String unit, int count) => List.filled(count, unit).join();

  group('BridgeMessagePipeline.decode 模糊输入', () {
    test('畸形 JSON 一律返回 null 或解析结果，绝不抛异常', () {
      final inputs = <String>[
        '',
        '   ',
        'not json',
        '{',
        '[',
        '}]]',
        '\u0000',
        '{"a":\u0000}',
        '{"key": "值\u2028unicode"}',
        '[]',
        '{}',
        'null',
        'true',
        '42',
        '"just a string"',
        '{"a": [1, 2, {"b": [3]}]}',
        repeat('[', 30) + repeat(']', 30), // 深层数组
        [repeat('{"n":', 30), '0', repeat('}', 30)].join(), // 深层对象
        '{"big": "${repeat('x', 100000)}"}',
      ];
      for (final input in inputs) {
        expect(() => BridgeMessagePipeline.decode(input), returnsNormally,
            reason: 'decode(${input.length} chars)');
      }
    });
  });

  group('BridgeMessagePipeline.parseRemoved 模糊输入', () {
    test('各种根类型与畸形结构都返回三元组，绝不抛异常', () {
      final inputs = <Object?>[
        null,
        '',
        '[]',
        '{}',
        '{"type":"session.removed","address":{"sessionId":"s1"}}',
        '{"type":"task.removed","address":{"taskId":"t1"}}',
        '{"type":"task.upserted","task":{"id":"x","membership":{"archived":true}}}',
        '{"type":"session.removed"}',
        '{"type":"task.removed","address":"not-a-map"}',
        '[[[[[[[[[[{"type":"session.removed","address":{"sessionId":"deep"}}]]]]]]]]]]',
        '{"payload":{"frame":{"data":{"type":"session.removed","address":{"sessionId":"s2"}}}}}',
        jsonEncode({
          'items': [
            for (var i = 0; i < 5000; i++)
              {'type': 'task.removed', 'address': {'taskId': 't$i'}},
          ],
        }),
      ];
      for (final input in inputs) {
        final decoded = input is String ? BridgeMessagePipeline.decode(input) : input;
        expect(
          () => BridgeMessagePipeline.parseRemoved(decoded),
          returnsNormally,
          reason: 'parseRemoved(${input.runtimeType})',
        );
      }
      // 深层结构不应被无限遍历（maxDepth=8）：第 10 层的事件不应被提取。
      final deep = BridgeMessagePipeline.decode(
        '[{"payload":{"payload":{"payload":{"payload":{"payload":{"payload":'
        '{"payload":{"payload":{"payload":{"type":"session.removed",'
        '"address":{"sessionId":"too-deep"}}}}}}}}}}}]',
      );
      final result = BridgeMessagePipeline.parseRemoved(deep);
      expect(result.sessions, isEmpty);
    });
  });

  group('LinkBuilder.parse 敌对输入', () {
    test('畸形/恶意输入返回 null 或合法设备，绝不抛异常', () {
      final hostile = <String>[
        '',
        ' ',
        '\u0000',
        'javascript:alert(1)?sid=s&hash=h',
        'file:///etc/passwd?sid=s&hash=h',
        'data:text/plain,hi?sid=s&hash=h',
        'http://zcode.z.ai/remote/v4?sid=s&hash=h', // 明文拒绝
        'https://zcode.z.ai.evil.com/remote/v4?sid=s&hash=h',
        'https://zcode.z.ai@evil.com/remote/v4?sid=s&hash=h',
        'https://zcode.z.ai:8443/remote/v4?sid=s&hash=h',
        'https://[::1]/remote/v4?sid=s&hash=h',
        'https://zcode.z.ai/remote/v4?sid=${'s' * 10000}&hash=h',
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&sid=dup',
        'https://zcode.z.ai/remote/v4?sid=%00&hash=h',
        'https://zcode.z.ai/remote/v4?sid=s&hash=h%',
        'https://ZCODE.Z.AI/remote/v4?sid=s&hash=h',
        'https://zcode.z.ai//remote/v4?sid=s&hash=h',
        'https://zcode.z.ai/remote/v4/../../login?sid=s&hash=h',
        'x' * 100000,
      ];
      for (final input in hostile) {
        expect(
          () => LinkBuilder.parse(input),
          returnsNormally,
          reason: 'parse(${input.length} chars)',
        );
      }
      // 大小写 host 合法大小写归一后仍可信
      final ok = LinkBuilder.parse(
        'https://ZCODE.Z.AI/remote/v4?sid=s&hash=h',
      );
      expect(ok, isNotNull);
      expect(LinkBuilder.isTrustedDevice(ok!), isTrue);
    });
  });

  group('更新 sidecar 摘要解析模糊输入', () {
    Future<UpdateCheckResult> checkWithSidecar(String body) async {
      final client = _Client((request) async {
        if (request.url == UpdateService.latestReleaseApi) {
          return http.StreamedResponse(
            Stream.value(utf8.encode('rate limited')),
            403,
          );
        }
        if (request.url == UpdateService.latestReleasePage) {
          return http.StreamedResponse(
            const Stream<List<int>>.empty(),
            302,
            headers: {
              'location':
                  'https://github.com/2421873411a-rgb/ZCode-App/releases/tag/v9.9.9',
            },
          );
        }
        return http.StreamedResponse(Stream.value(utf8.encode(body)), 200);
      });
      return UpdateService.instance.checkForUpdate(
        client: client,
        currentVersion: '1.0.8',
      );
    }

    test('合法摘要（含 CRLF / 星号 / 大写）通过', () async {
      final hex = 'A' * 64;
      for (final body in ['$hex  ZCode-v9.9.9.apk\n', '$hex *ZCode-v9.9.9.apk\r\n']) {
        final result = await checkWithSidecar(body);
        expect(result.canDownload, isTrue, reason: body);
        expect(result.assetDigest, 'sha256:${'a' * 64}');
      }
    });

    test('畸形摘要一律 fail-closed（不自动下载）', () async {
      final bad = <String>[
        '',
        'not a checksum',
        '${'a' * 63}  ZCode-v9.9.9.apk', // 长度不足
        '${'a' * 65}  ZCode-v9.9.9.apk', // 长度超出
        '${'z' * 64}  ZCode-v9.9.9.apk', // 非十六进制
        repeat('a', 64), // 缺文件名
        '${'a' * 64}  other.apk', // 文件名不符
        '${'a' * 64}  ZCode-v9.9.9.apk\n${'b' * 64}  ZCode-v9.9.9.apk', // 多行
        '${'a' * 64}\tZCode-v9.9.9.apk extra',
      ];
      for (final body in bad) {
        final result = await checkWithSidecar(body);
        expect(result.canDownload, isFalse, reason: body);
        expect(result.downloadUri, isNull);
      }
    });
  });
}

class _Client extends http.BaseClient {
  _Client(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/external_push.dart';

void main() {
  group('ExternalPushMessage.fromJson', () {
    test('完整字段解析，超长正文按 600 截断', () {
      final message = ExternalPushMessage.fromJson({
        'id': 7,
        'kind': 'permission',
        'title': '需要审批',
        'body': 'x' * 900,
        'sessionId': 's-1',
        'device': 'PC-1',
        'ts': 1792979952560,
      });
      expect(message, isNotNull);
      expect(message!.id, 7);
      expect(message.kind, 'permission');
      expect(message.title, '需要审批');
      expect(message.body.length, 600);
      expect(message.sessionId, 's-1');
    });

    test('缺 id 或内容全空 → null（不产生空通知）', () {
      expect(ExternalPushMessage.fromJson({'title': 'x'}), isNull);
      expect(ExternalPushMessage.fromJson({'id': 1}), isNull);
      expect(
        ExternalPushMessage.fromJson({'id': 1, 'title': '  ', 'body': ''}),
        isNull,
      );
    });

    test('kind 缺省为 info；notifTitle 按类型给中文兜底', () {
      final message = ExternalPushMessage.fromJson({
        'id': 2,
        'body': '任务跑完了',
      })!;
      expect(message.kind, 'info');
      expect(ExternalPushMessage.fromJson({'id': 3, 'body': 'x'})!.notifTitle, 'ZCode');
      expect(
        ExternalPushMessage.fromJson({
          'id': 4,
          'kind': 'permission',
          'body': 'x',
        })!.notifTitle,
        '需要你的审批',
      );
      expect(
        ExternalPushMessage.fromJson({
          'id': 5,
          'kind': 'completed',
          'body': 'x',
        })!.notifTitle,
        '任务已完成',
      );
    });

    test('控制字符被清掉（防止通知正文被注入换行）', () {
      final message = ExternalPushMessage.fromJson({
        'id': 6,
        'title': 'a\u0000b',
        'body': 'c\u0000d',
      })!;
      expect(message.title.contains('\u0000'), isFalse);
      expect(message.body.contains('\u0000'), isFalse);
    });
  });

  group('ExternalPushProtocol.parsePoll', () {
    test('正常批次按 id 升序，游标取最大 id', () {
      final batch = ExternalPushProtocol.parsePoll(
        jsonEncode({
          'ok': true,
          'messages': [
            {'id': 5, 'title': 'b', 'body': 'b'},
            {'id': 3, 'title': 'a', 'body': 'a'},
          ],
        }),
        after: 2,
      );
      expect(batch.messages.map((m) => m.id).toList(), [3, 5]);
      expect(batch.nextCursor, 5);
    });

    test('丢弃 <= after 的重复投递（服务端重放防护）', () {
      final batch = ExternalPushProtocol.parsePoll(
        jsonEncode({
          'ok': true,
          'messages': [
            {'id': 2, 'title': 'dup', 'body': 'dup'},
            {'id': 9, 'title': 'new', 'body': 'new'},
          ],
        }),
        after: 2,
      );
      expect(batch.messages.single.id, 9);
      expect(batch.nextCursor, 9);
    });

    test('空批次 / ok=false / 坏 JSON 一律空批次不抛', () {
      expect(
        ExternalPushProtocol.parsePoll('{"ok":true,"messages":[]}', after: 0)
            .isEmpty,
        isTrue,
      );
      expect(
        ExternalPushProtocol.parsePoll('{"ok":false}', after: 0).isEmpty,
        isTrue,
      );
      expect(
        ExternalPushProtocol.parsePoll('not-json', after: 0).isEmpty,
        isTrue,
      );
      expect(ExternalPushProtocol.parsePoll('[]', after: 0).isEmpty, isTrue);
    });

    test('401 风格的错误响应不会变成通知', () {
      final batch = ExternalPushProtocol.parsePoll(
        '{"error":"unauthorized"}',
        after: 0,
      );
      expect(batch.isEmpty, isTrue);
      expect(batch.nextCursor, isNull);
    });
  });

  group('ExternalPushProtocol.isAcceptableBaseUrl', () {
    test('只接受 https', () {
      expect(
        ExternalPushProtocol.isAcceptableBaseUrl('https://zhihui.kaogong.art'),
        isTrue,
      );
      expect(
        ExternalPushProtocol.isAcceptableBaseUrl('http://zhihui.kaogong.art'),
        isFalse,
      );
      expect(ExternalPushProtocol.isAcceptableBaseUrl('zhihui.kaogong.art'),
          isFalse);
      expect(ExternalPushProtocol.isAcceptableBaseUrl(''), isFalse);
    });

    test('超长地址拒绝', () {
      final long = 'https://${'a' * 400}.com';
      expect(ExternalPushProtocol.isAcceptableBaseUrl(long), isFalse);
    });
  });

  group('ExternalPushConfig', () {
    test('地址去尾斜杠后拼出 poll/ack 端点', () {
      const config = ExternalPushConfig(
        baseUrl: 'https://example.com///',
        token: 'abcdefghijklmnop',
      );
      expect(config.pollUrl, 'https://example.com/zpush/poll');
      expect(config.ackUrl, 'https://example.com/zpush/ack');
    });

    test('令牌过短视为未启用（避免误配置后静默失败）', () {
      expect(
        const ExternalPushConfig(baseUrl: 'https://a.com', token: 'short')
            .enabled,
        isFalse,
      );
      expect(
        const ExternalPushConfig(
          baseUrl: 'https://a.com',
          token: 'abcdefghijklmnop',
        ).enabled,
        isTrue,
      );
    });
  });

  group('自定义端点与鉴权（v1.8.1）', () {
    test('默认值 = 本项目自带服务的约定', () {
      const config = ExternalPushConfig(
        baseUrl: 'https://a.com',
        token: 'abcdefghijklmnop',
      );
      expect(config.pollUrl, 'https://a.com/zpush/poll');
      expect(config.ackUrl, 'https://a.com/zpush/ack');
      expect(config.publishUrl, 'https://a.com/zpush/publish');
      expect(config.isDefaultProtocol, isTrue);
    });

    test('自定义路径（相对）拼到 baseUrl 上', () {
      const config = ExternalPushConfig(
        baseUrl: 'https://my.host',
        token: 'abcdefghijklmnop',
        pollPath: '/api/notify/next',
        ackPath: 'api/notify/ack',
      );
      expect(config.pollUrl, 'https://my.host/api/notify/next');
      expect(config.ackUrl, 'https://my.host/api/notify/ack');
      expect(config.isDefaultProtocol, isFalse);
    });

    test('绝对 URL 端点原样使用（完全脱离 baseUrl）', () {
      const config = ExternalPushConfig(
        baseUrl: 'https://ignored.host',
        token: 'abcdefghijklmnop',
        pollPath: 'https://other.host/queue/next',
      );
      expect(config.pollUrl, 'https://other.host/queue/next');
    });

    test('查询参数鉴权把 token 加到 URL', () {
      const config = ExternalPushConfig(
        baseUrl: 'https://a.com',
        token: 'secret-token-123456',
        authStyle: ExternalPushAuthStyle.queryToken,
      );
      expect(
        config.withQueryToken('https://a.com/zpush/poll?after=5'),
        'https://a.com/zpush/poll?after=5&token=secret-token-123456',
      );
      // 非 query 风格不动 URL。
      expect(
        const ExternalPushConfig(
          baseUrl: 'https://a.com',
          token: 'secret-token-123456',
        ).withQueryToken('https://a.com/x'),
        'https://a.com/x',
      );
    });

    test('copyWith 只改指定项', () {
      const base = ExternalPushConfig(
        baseUrl: 'https://a.com',
        token: 'abcdefghijklmnop',
        pollPath: '/p',
      );
      final bearer = base.copyWith(authStyle: ExternalPushAuthStyle.bearer);
      expect(bearer.authStyle, ExternalPushAuthStyle.bearer);
      expect(bearer.pollPath, '/p');
      expect(bearer.baseUrl, 'https://a.com');
    });

    test('自定义头名生效（留空回退默认）', () {
      const custom = ExternalPushConfig(
        baseUrl: 'https://a.com',
        token: 't',
        authHeaderName: 'X-My-Auth',
      );
      expect(custom.authHeaderName, 'X-My-Auth');
      const empty = ExternalPushConfig(
        baseUrl: 'https://a.com',
        token: 't',
        authHeaderName: '',
      );
      expect(
        empty.authHeaderName.isEmpty ? ExternalPushConfig.defaultAuthHeader : '',
        'X-ZP-Token',
      );
    });
  });

  group('ackIds', () {
    test('去重并升序', () {
      expect(ExternalPushProtocol.ackIds([3, 1, 3, 2]), [1, 2, 3]);
      expect(ExternalPushProtocol.ackIds([]), isEmpty);
    });
  });
}

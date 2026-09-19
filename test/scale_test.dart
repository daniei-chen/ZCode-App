import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/bridge_schema.dart';
import 'package:zremote/services/diagnostics_bundle.dart';
import 'package:zremote/services/event_observer.dart';
import 'package:zremote/services/structured_log.dart';
import 'package:zremote/state/event_feed.dart';
import 'package:zremote/state/subframe_stats.dart';

/// W-008 规模测试（SCALE_DATA）。
///
/// 每条断言的是**有界性**（条目数/长度/幂等），不是性能数字。Stopwatch 上限
/// 只作为"灾难性退化"绊线（比预期慢一个数量级以上才会触发），刻意放得很宽，
/// 以免在慢机器/CI 上抖动——真正的上界是条目数与结构，不是毫秒。
void main() {
  const tripwire = Duration(seconds: 20);

  ObservedEvent ev(String type, String taskId, {int? total}) =>
      ObservedEvent(type: type, taskId: taskId, pendingTotal: total);

  group('EventDedupeGate 有界', () {
    test('2e4 个互不相同的事件：表被淘汰到上限，最早的键会被逐出', () {
      // 注入单调时钟：淘汰按时间排序，用假时钟让"最旧"完全确定（不依赖
      // DateTime.now 在同一毫秒内的平局行为）。2e4 ms < 2 min 窗口，不会过期。
      // N 取 2e4 而非 1e5：远超 maxEntries 即可证明有界；更大的 N 只会让
      // "去掉淘汰"的变异跑成二次方（1e5 时 291 s），拖慢整套语料。
      var tick = 0;
      final gate = EventDedupeGate(maxEntries: 256)
        ..clock = () => DateTime(2026, 1, 1).add(Duration(milliseconds: tick++));
      final first = ev('completed', 'task-0');
      final watch = Stopwatch()..start();
      expect(gate.allow(first), isTrue);
      for (var i = 1; i < 20000; i++) {
        expect(gate.allow(ev('completed', 'task-$i')), isTrue);
      }
      watch.stop();
      // 最早的键早已被有界淘汰：再次到达按"新一轮"放行，证明表没有无限增长。
      expect(gate.allow(first), isTrue, reason: 'task-0 应已被淘汰而不是仍被抑制');
      expect(watch.elapsed, lessThan(tripwire));
    });

    test('1e5 次同一事件重放：只放行一次', () {
      final gate = EventDedupeGate();
      final same = ev('permission_request', 't1');
      var allowed = 0;
      for (var i = 0; i < 100000; i++) {
        if (gate.allow(same)) allowed++;
      }
      expect(allowed, 1);
    });
  });

  group('EventParser.dedupe 有界与幂等', () {
    test('1e4 个事件、100 个键：结果恰 100 条且再次 dedupe 不变', () {
      final input = [
        for (var i = 0; i < 10000; i++)
          ev('completed', 'task-${i % 100}', total: i % 3),
      ];
      final watch = Stopwatch()..start();
      final once = EventParser.dedupe(input);
      final twice = EventParser.dedupe(once);
      watch.stop();
      expect(once, hasLength(100));
      // 唯一键直接保留原实例：整列表恒等比较连 type/pendingTotal 一起钉住。
      expect(twice, once);
      expect(watch.elapsed, lessThan(tripwire));
    });
  });

  group('EventFeedNotifier 有界记账', () {
    test('1e4 条审批请求落到 100 个任务：pendingByTask 恰 100、末值生效、unread 逐条累加', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final feed = container.read(eventFeedProvider.notifier);
      // 同一任务的计数随批次递增：首次写入 1，末次写入 5——首值生效（putIfAbsent
      // 回退）与末值生效（权威计数）在这里可区分。
      for (var i = 0; i < 10000; i++) {
        feed.ingest('dev', ev('permission_request', 'task-${i % 100}', total: 1 + (i ~/ 100) % 5));
      }
      final state = container.read(eventFeedProvider)['dev']!;
      expect(state.pendingByTask, hasLength(100));
      expect(state.unread, 10000);
      for (var k = 0; k < 100; k++) {
        expect(state.pendingByTask['task-$k'], 5, reason: 'task-$k 末次 pendingTotal 为 5');
      }
    });
  });

  group('BridgeSchema 边界', () {
    test('acceptStats：1e4 个垃圾键只留白名单，且不超过 maxStatsKeys', () {
      final decoded = <String, Object?>{
        for (var i = 0; i < 10000; i++) 'junk$i': i,
        for (final k in BridgeSchema.statsKeys) k: 7,
      };
      final out = BridgeSchema.acceptStats(decoded)!;
      expect(out.keys.toSet(), BridgeSchema.statsKeys);
      expect(out.length, lessThanOrEqualTo(BridgeSchema.maxStatsKeys));
      expect(out.values.every((v) => v == 7), isTrue);
    });

    test('acceptString：按真实 UTF-8 字节判定，多字节字符不能靠 length 蒙混', () {
      const maxBytes = 300;
      final exact = '中' * (maxBytes ~/ 3); // 每个 3 字节，恰好 maxBytes
      final over = '${'中' * (maxBytes ~/ 3)}a'; // 多 1 字节
      expect(utf8.encode(exact).length, maxBytes);
      expect(BridgeSchema.acceptString(exact, maxBytes: maxBytes), exact);
      expect(BridgeSchema.acceptString(over, maxBytes: maxBytes), isNull);
      // length 远小于 maxBytes 但字节数超限（F04 的原始缺陷形态）。
      final sneaky = '😀' * (maxBytes ~/ 4 + 1); // 每个 2 code unit / 4 字节
      expect(sneaky.length, lessThan(maxBytes));
      expect(BridgeSchema.acceptString(sneaky, maxBytes: maxBytes), isNull);
    });

    test('遥测 JSON 上限常量自洽：恰好 maxStatsChars 长的合法 JSON 可解析（生产侧超限丢弃在 WebView handler，单测不覆盖）', () {
      // 构造恰好 maxStatsChars 长的合法 JSON（用空白填充），证明上限值本身可用。
      final base = jsonEncode({'wsMessages': 1});
      final padded = base.padRight(BridgeSchema.maxStatsChars);
      expect(padded.length, BridgeSchema.maxStatsChars);
      expect(BridgeSchema.acceptStats(jsonDecode(padded)), {'wsMessages': 1});
    });
  });

  group('LogRedactor 长输入', () {
    test('≥1 MiB 混合凭证/长令牌/URL：无原始令牌泄漏、输出只会变短，且不发生灾难性回溯', () {
      final buffer = StringBuffer();
      for (var i = 0; i < 6000; i++) {
        buffer
          ..write('sid=SECRET${i.toString().padLeft(6, '0')}SECRETSECRETSECRET ')
          ..write('https://zcode.z.ai/remote/v4?token=TOK${i}TOKTOKTOKTOKTOKTOKTOKTOK&x=1 ')
          ..write('${'a' * 40}${i % 10} ')
          ..write('deadbeefcafebabe0123456789abcdef$i ');
      }
      final input = buffer.toString();
      expect(input.length, greaterThan(1024 * 1024));
      final watch = Stopwatch()..start();
      final output = LogRedactor.redact(input);
      watch.stop();
      expect(output, isNot(contains('SECRET')));
      expect(output, isNot(contains('TOK1TOK')));
      expect(output, isNot(contains('token=TOK')));
      expect(output, isNot(contains('deadbeefcafebabe')));
      // 本夹具的每种替换（凭证参数、opaque 串、URL 去 query）都只会缩短文本。
      expect(output.length, lessThan(input.length));
      expect(watch.elapsed, lessThan(tripwire));
    });

    test('1e6 个连续字母：单次整体替换，长度收敛到占位符', () {
      final output = LogRedactor.redact('x' * 1000000);
      expect(output, LogRedactor.replacement);
    });
  });

  group('SubFrameStats 与诊断包规模', () {
    test('1e5 次子 frame 记账：计数精确，无回绕', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(subFrameStatsProvider.notifier);
      for (var i = 0; i < 100000; i++) {
        notifier.record('dev', trusted: i % 4 != 0);
      }
      final stats = container.read(subFrameStatsProvider)['dev']!;
      expect(stats.total, 100000);
      expect(stats.allowed, 75000);
      expect(stats.cancelled, 25000);
    });

    test('1000 台设备 × 全部计数键：诊断包行数与告警行数按设备线性，且可渲染', () {
      // 短 id 取清洗后前 8 位：'d0000000'..'d0000999' 两两不同，避免撞名把
      // "按设备线性"的寓意变成"按前缀合并"。
      final ids = [for (var i = 0; i < 1000; i++) 'd${i.toString().padLeft(7, '0')}'];
      final inputs = DiagnosticsInputs(
        generatedAt: DateTime.utc(2026, 9, 18),
        appVersion: '1.1.0',
        buildNumber: '30',
        platform: const {'android': '14'},
        deviceIds: ids,
        statuses: const {},
        settings: const {},
        stats: {
          for (final id in ids) id: {for (final k in BridgeSchema.statsKeys) k: 1},
        },
        bridgeHealth: const {},
        droppedMessages: 0,
        droppedDebugLines: 0,
        logs: const [],
      );
      final sections = DiagnosticsBundle.sections(inputs);
      final observer = sections.firstWhere((s) => s.title == 'observer');
      final alerts = sections.firstWhere((s) => s.title == 'alerts');
      expect(observer.rows.length, 2 + 1000 * BridgeSchema.statsKeys.length);
      expect(alerts.rows.length, 1 + 1000);
      expect(alerts.rows.skip(1).map((r) => r.key).toSet(), hasLength(1000),
          reason: '短 id 两两不同');
      // 全键为 1 时每台设备至少触发 OB201（sseIgnored=1）与 OB205（queueDropped=1）。
      expect(alerts.rows.skip(1).every((r) => r.value.contains('OB201') && r.value.contains('OB205')), isTrue);
      final text = DiagnosticsBundle.render(inputs);
      expect(text, contains('[alerts]'));
      // 约 15k 行 × 有界行宽：2 MiB 是数倍余量的量级上界。
      expect(text.length, lessThan(2 * 1024 * 1024));
    });
  });
}

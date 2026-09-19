import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/bridge_schema.dart';
import 'package:zremote/services/diagnostics_bundle.dart';
import 'package:zremote/services/observer_alerts.dart';

/// W-005 观察面变化自动告警：纯策略的阈值边界、敌对输入与诊断红线。
void main() {
  List<ObserverAlertCode> codes(Map<String, int> counters) =>
      ObserverAlertPolicy.evaluate(counters).map((a) => a.code).toList();

  group('ObserverAlertPolicy.evaluate 阈值边界', () {
    test('全零 / 空计数 → 无告警', () {
      expect(ObserverAlertPolicy.evaluate(const {}), isEmpty);
      expect(
        ObserverAlertPolicy.evaluate({
          for (final k in BridgeSchema.statsKeys) k: 0,
          'subFrameTotal': 0,
          'subFrameAllowed': 0,
          'subFrameCancelled': 0,
        }),
        isEmpty,
      );
    });

    test('SSE：任一 SSE 计数 ≥1 即告警，值为两键之和（OB201）', () {
      expect(codes(const {'sseIgnored': 1}), [ObserverAlertCode.sseAppeared]);
      expect(
        ObserverAlertPolicy.evaluate(const {'sseMessages': 2, 'sseIgnored': 3}),
        [const ObserverAlert(ObserverAlertCode.sseAppeared, 5)],
      );
    });

    test('WS 未命中：样本地板 20 与 >50% 占比同时满足才告警（OB202）', () {
      expect(codes(const {'wsIgnored': 19}), isEmpty, reason: '样本不足');
      expect(codes(const {'wsIgnored': 20}), [ObserverAlertCode.wsMissHigh]);
      expect(
        codes(const {'wsIgnored': 20, 'wsMessages': 20}),
        isEmpty,
        reason: '恰好 50% 不算高',
      );
      expect(
        ObserverAlertPolicy.evaluate(const {'wsIgnored': 21, 'wsMessages': 20}),
        [const ObserverAlert(ObserverAlertCode.wsMissHigh, 21)],
      );
    });

    test('fetch 未命中：同样的地板与占比规则（OB203）', () {
      expect(codes(const {'fetchSkipped': 19, 'fetch200': 0}), isEmpty);
      expect(
        codes(const {'fetchSkipped': 20, 'fetch200': 19}),
        [ObserverAlertCode.fetchMissHigh],
      );
      expect(codes(const {'fetchSkipped': 20, 'fetch200': 20}), isEmpty);
    });

    test('分片异常：无效 + 过期累计 ≥5（OB204）', () {
      expect(
        codes(const {'invalidFragments': 2, 'expiredFragments': 2}),
        isEmpty,
      );
      expect(
        ObserverAlertPolicy.evaluate(const {
          'invalidFragments': 3,
          'expiredFragments': 2,
        }),
        [const ObserverAlert(ObserverAlertCode.fragmentAnomaly, 5)],
      );
    });

    test('预算丢弃：队列或已见集合任一丢弃即告警（OB205）', () {
      expect(codes(const {'queueDropped': 1}), [ObserverAlertCode.budgetDrop]);
      expect(codes(const {'seenDropped': 1}), [ObserverAlertCode.budgetDrop]);
      expect(
        ObserverAlertPolicy.evaluate(const {'queueDropped': 2, 'seenDropped': 3}),
        [const ObserverAlert(ObserverAlertCode.budgetDrop, 5)],
      );
    });

    test('子 frame：只有 cancelled 触发（OB207），total/allowed 不触发', () {
      expect(codes(const {'subFrameTotal': 9, 'subFrameAllowed': 9}), isEmpty);
      expect(
        ObserverAlertPolicy.evaluate(const {
          'subFrameTotal': 3,
          'subFrameAllowed': 2,
          'subFrameCancelled': 1,
        }),
        [const ObserverAlert(ObserverAlertCode.subFrameBlocked, 1)],
      );
    });

    test('多条告警按固定规则顺序输出，与 Map 插入顺序无关', () {
      final a = codes(const {'subFrameCancelled': 1, 'queueDropped': 1, 'sseIgnored': 1});
      final b = codes(const {'sseIgnored': 1, 'queueDropped': 1, 'subFrameCancelled': 1});
      expect(a, b);
      expect(a, [
        ObserverAlertCode.sseAppeared,
        ObserverAlertCode.budgetDrop,
        ObserverAlertCode.subFrameBlocked,
      ]);
    });

    test('键集合护栏：消费键 ∪ 忽略键 == 白名单 ∪ 子 frame 三键，且两者不交', () {
      const subFrameKeys = {'subFrameTotal', 'subFrameAllowed', 'subFrameCancelled'};
      final known = {...BridgeSchema.statsKeys, ...subFrameKeys};
      expect(
        ObserverAlertPolicy.consumedKeys.intersection(ObserverAlertPolicy.ignoredKeys),
        isEmpty,
      );
      expect(
        {...ObserverAlertPolicy.consumedKeys, ...ObserverAlertPolicy.ignoredKeys},
        known,
        reason: '新增计数键必须显式决定：消费它，或写进 ignoredKeys',
      );
      // 每个消费键单独探针：异常键喂一个能触发的值；两个分母键（wsMessages /
      // fetch200）反过来喂"大量命中"证明它们真的压低了占比（抑制探针）。
      for (final key in ObserverAlertPolicy.consumedKeys) {
        switch (key) {
          case 'wsMessages':
            expect(
              codes(const {'wsIgnored': 20, 'wsMessages': 100}),
              isEmpty,
              reason: 'wsMessages 未被当作分母读取',
            );
          case 'fetch200':
            expect(
              codes(const {'fetchSkipped': 20, 'fetch200': 100}),
              isEmpty,
              reason: 'fetch200 未被当作分母读取',
            );
          default:
            expect(
              ObserverAlertPolicy.evaluate({key: 100}),
              isNotEmpty,
              reason: '$key 在消费集合里但单独喂值不触发任何告警',
            );
        }
      }
    });
  });

  group('ObserverAlertPolicy.evaluate 敌对输入', () {
    test('负数按 0：不告警也不抛，且不会抵消同组的正计数', () {
      expect(codes(const {'sseIgnored': -1, 'wsIgnored': -50}), isEmpty);
      // 负数若不钳位会把 2 + (-3) 算成 -1 从而吞掉真实信号。
      expect(
        ObserverAlertPolicy.evaluate(const {'sseMessages': 2, 'sseIgnored': -3}),
        [const ObserverAlert(ObserverAlertCode.sseAppeared, 2)],
      );
    });

    test('非白名单键被忽略（页面塞不进自定义告警）', () {
      expect(codes(const {'evil': 999, 'OB201': 1, 'sse': 1}), isEmpty);
    });

    test('超上限值钳到 maxStatValue：乘法不溢出，仍能告警', () {
      final alerts = ObserverAlertPolicy.evaluate({'wsIgnored': 1 << 62});
      expect(alerts, [
        ObserverAlert(ObserverAlertCode.wsMissHigh, BridgeSchema.maxStatValue),
      ]);
      // 钳位后的对照：极大未命中 + 极大命中，占比恰 50% → 不告警，且不会因溢出误判。
      expect(
        codes({'wsIgnored': 1 << 62, 'wsMessages': 1 << 62}),
        isEmpty,
      );
    });

    test('返回值不可变', () {
      final alerts = ObserverAlertPolicy.evaluate(const {'sseIgnored': 1});
      expect(
        () => alerts.add(const ObserverAlert(ObserverAlertCode.budgetDrop, 1)),
        throwsUnsupportedError,
      );
    });
  });

  group('应用级告警与诊断包', () {
    test('桥丢弃计数 ≥1 → OB206；0/负数 → 无', () {
      expect(ObserverAlertPolicy.evaluateApp(droppedMessages: 0), isEmpty);
      expect(ObserverAlertPolicy.evaluateApp(droppedMessages: -3), isEmpty);
      expect(
        ObserverAlertPolicy.evaluateApp(droppedMessages: 1),
        [const ObserverAlert(ObserverAlertCode.bridgeDrop, 1)],
        reason: '边界值 1 必须触发（变异 iter3-app-bridge-drop-threshold 曾存活）',
      );
      expect(
        ObserverAlertPolicy.evaluateApp(droppedMessages: 3),
        [const ObserverAlert(ObserverAlertCode.bridgeDrop, 3)],
      );
    });

    test('codesLine：空 → none；多条按顺序逗号拼接，只含告警码', () {
      expect(ObserverAlertPolicy.codesLine(const []), 'none');
      final line = ObserverAlertPolicy.codesLine(
        ObserverAlertPolicy.evaluate(const {'sseIgnored': 1, 'seenDropped': 2}),
      );
      expect(line, 'OB201,OB205');
      expect(RegExp(r'^[A-Z0-9,]+$').hasMatch(line), isTrue, reason: '诊断红线：只有码');
    });

    test('诊断包 alerts 分节：app 行 + 每设备短 id 行，只含告警码或 none', () {
      final inputs = DiagnosticsInputs(
        generatedAt: DateTime.utc(2026, 9, 18),
        appVersion: '1.1.0',
        buildNumber: '30',
        platform: const {'android': '14'},
        deviceIds: const ['3f2a1b9c-1234-5678-9abc-def012345678'],
        statuses: const {},
        settings: const {},
        stats: const {
          '3f2a1b9c-1234-5678-9abc-def012345678': {
            'sseIgnored': 1,
            'subFrameCancelled': 2,
            'wsMessages': 40,
          },
        },
        bridgeHealth: const {},
        droppedMessages: 0,
        droppedDebugLines: 0,
        logs: const [],
      );
      final section = DiagnosticsBundle.sections(inputs).firstWhere(
        (s) => s.title == 'alerts',
      );
      final rows = {for (final r in section.rows) r.key: r.value};
      expect(rows['app'], 'none');
      expect(rows['3f2a1b9c'], 'OB201,OB207');
      expect(rows.keys, isNot(contains('3f2a1b9c-1234-5678-9abc-def012345678')),
          reason: '设备只以短 id 出现');
      expect(DiagnosticsBundle.render(inputs), contains('[alerts]'));
    });
  });
}

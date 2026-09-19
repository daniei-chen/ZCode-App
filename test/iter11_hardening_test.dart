import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/observer_alerts.dart';
import 'package:zremote/services/device_connectivity.dart';
import 'package:zremote/services/session_jump.dart';

/// ITERATION 11：W-014 分母抗伪造 / W-016 跳转白名单与段匹配 / W-024 探测去重。
void main() {
  group('W-014 未命中占比分母抗伪造', () {
    test('wsMessages 灌大不再稀释占比：framesDecoded 封顶后 OB202 照常触发', () {
      final alerts = ObserverAlertPolicy.evaluate({
        'wsIgnored': 20,
        'wsMessages': 1 << 40, // 敌对虚报：旧实现分母被抬到天上去
        'framesDecoded': 10, // 真实只解码 10 帧 → 封顶后 total=30，20*2>30 触发
      });
      expect(
        alerts.map((a) => a.code),
        contains(ObserverAlertCode.wsMissHigh),
        reason: '虚报命中不得把 50% 未命中率稀释成静默',
      );
    });

    test('framesDecoded 正常（≥ wsMessages）时行为不变：不误报', () {
      // 真实 80% 未命中（超阈值）→ 告警；
      expect(
        ObserverAlertPolicy.evaluate({
          'wsIgnored': 40,
          'wsMessages': 10,
          'framesDecoded': 10,
        }).map((a) => a.code),
        contains(ObserverAlertCode.wsMissHigh),
      );
      // 真实 20% 未命中（低于阈值）→ 不告警。
      expect(
        ObserverAlertPolicy.evaluate({
          'wsIgnored': 20,
          'wsMessages': 80,
          'framesDecoded': 80,
        }).map((a) => a.code),
        isNot(contains(ObserverAlertCode.wsMissHigh)),
      );
    });

    test('fetch200 虚报用 fetchCloned 封顶：OB203 同口径', () {
      expect(
        ObserverAlertPolicy.evaluate({
          'fetchSkipped': 20,
          'fetch200': 1 << 40,
          'fetchCloned': 10,
        }).map((a) => a.code),
        contains(ObserverAlertCode.fetchMissHigh),
      );
      // fetchCloned 缺席（0）→ 退回旧行为，不因封顶缺席而误报。
      expect(
        ObserverAlertPolicy.evaluate({
          'fetchSkipped': 20,
          'fetch200': 20,
        }).map((a) => a.code),
        isNot(contains(ObserverAlertCode.fetchMissHigh)),
      );
    });
  });

  group('W-016 跳转 taskId 白名单与段匹配', () {
    test('taskIdWellFormed：合法 id 通过；空/超长/非法字符拒绝', () {
      expect(SessionJump.taskIdWellFormed('sess_fb'), isTrue);
      expect(SessionJump.taskIdWellFormed('task-item-1a_-'), isTrue);
      expect(SessionJump.taskIdWellFormed(''), isFalse);
      expect(SessionJump.taskIdWellFormed('a' * 129), isFalse);
      expect(SessionJump.taskIdWellFormed('sess fb'), isFalse, reason: '空格');
      expect(SessionJump.taskIdWellFormed("sess'fb"), isFalse, reason: '引号');
      expect(SessionJump.taskIdWellFormed('sess/fb'), isFalse, reason: '斜杠');
      expect(SessionJump.taskIdWellFormed('sess;fb'), isFalse, reason: '分号');
    });

    test('跳转脚本包含段匹配契约：testid 精确等于 tid 或 task-item- 前缀', () {
      final script = SessionJump.jumpScript('sess_fb');
      expect(script.contains("t !== tid && t.indexOf('task-item-' + tid) !== 0"), isTrue,
          reason: '任意子串命中会把查看手势劫持成对任意元素的点击（S-8）');
      expect(script.contains("if (t.indexOf(tid) === -1) continue;"), isFalse,
          reason: '旧的纯子串匹配必须移除');
    });
  });

  group('W-024 探测 in-flight 去重', () {
    test('重叠轮跳过：第一轮在跑时第二轮不发探测、不覆盖结果', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(deviceConnectivityProvider.notifier);
      final gate = Completer<void>();
      var fetchCalls = 0;
      notifier.probe = ConnectivityProbe(fetch: (_) async {
        fetchCalls++;
        await gate.future; // 第一轮挂起，模拟 5s 超时窗口
        return ProbeOutcome.ok;
      });
      final d = RemoteDevice(
        id: 'd1',
        baseUrl: 'https://zcode.z.ai/remote/v4',
        params: const {'sid': 's', 'hash': 'h'},
        label: '',
        createdAt: DateTime(2026),
      );
      final first = notifier.probeAll([d], const {});
      await pumpEventQueue();
      final second = notifier.probeAll([d], const {}); // 重叠轮
      expect(fetchCalls, 1, reason: '已有轮在跑时重叠轮必须跳过');
      gate.complete();
      await first;
      await second;
      expect(container.read(deviceConnectivityProvider)['d1'], ProbeOutcome.ok);
      // 第一轮结束后新的一轮正常执行（去重不是永久锁死）。
      notifier.probe = ConnectivityProbe(fetch: (_) async {
        fetchCalls++;
        return ProbeOutcome.failed;
      });
      await notifier.probeAll([d], const {});
      expect(fetchCalls, 2);
      expect(container.read(deviceConnectivityProvider)['d1'], ProbeOutcome.failed);
    });
  });
}

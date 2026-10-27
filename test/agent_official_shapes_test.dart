// 用官方实测形状逐帧验证 agent 引导链（不依赖模拟器）。

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/relay/agent_layer.dart';

void main() {
  test('官方形状：activeWorkspaceKey 在 result 内 + bridge-ready 只回 bridgeSessionId', () async {
    final sent = <Map<String, Object?>>[];
    var ready = false;
    final layer = RelayAgentLayer(
      deviceId: 'd1',
      deviceSid: 's1',
      appVersion: '3.16.3',
      sendJson: sent.add,
      onEvent: (_, _) {},
      onReady: (_, r) => ready = r,
    );

    layer.onPaired();
    // 引导链是 async 的：等微任务跑完再断言。
    await Future<void>.delayed(Duration.zero);
    // 第 1 步：workspace-list-request
    expect(
      sent.any((m) => '${(m['payload'] as Map?)?['zcode_type']}' == 'workspace-list-request'),
      isTrue,
    );

    // 服务端按官方形状回复（result 嵌套）
    layer.handleDataPayload({
      'zcode_type': 'workspace-list-response',
      'requestId': 'agent-1',
      'result': {
        'activeWorkspaceKey': 'D:/ws',
        'tasks': <Object>[],
      },
    });
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // 第 2 步：bridge-open（说明 workspace 取到了）
    final openMsg = sent.lastWhere(
      (m) => '${(m['payload'] as Map?)?['zcode_type']}' == 'workspace-bridge-open',
    );
    final bridgeId = '${(openMsg['payload'] as Map)['bridgeSessionId']}';
    expect(bridgeId, isNotEmpty);

    // 服务端只回 bridgeSessionId（官方谓词，无 requestId）
    layer.handleDataPayload({
      'zcode_type': 'workspace-bridge-ready',
      'bridgeSessionId': bridgeId,
      'bridgeGeneration': 1,
    });
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // 第 3 步：应该发出了 hello rpc（说明开桥被接受）
    expect(
      sent.any((m) => '${(m['payload'] as Map?)?['zcode_type']}' == 'rpc-frame'),
      isTrue,
      reason: '开桥被接受后应继续 hello/initialize 引导',
    );
    expect(ready, isFalse, reason: '还没走到 subscribe，不应就绪');
  });
}

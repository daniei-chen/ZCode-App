import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/ui/official_remote_page.dart';

/// 盖板状态机（[shouldCoverOfficialPage]）的锁定测试。
///
/// 这些用例逐条对应真机上实际看到过的状态；任何一条回归都意味着用户又会
/// 看到官方页的半成品界面（"加载工作区 / 加载中..."），所以这里必须钉死。
void main() {
  group('shouldCoverOfficialPage', () {
    test('冷启动过渡屏（配对卡/英文中转屏）：盖住', () {
      expect(
        shouldCoverOfficialPage(
          rows: 0,
          composer: false,
          handshake: true,
          loadingRow: false,
          takeover: false,
          blank: false,
        ),
        isTrue,
      );
    });

    test('半加载：输入区已挂、左栏还挂着"加载中..."占位行 → 仍盖住（旧规则的漏洞）', () {
      // 真机 v1.0.0+21 实测：composer 早于任务行出现，旧规则
      // (handshake && !hasContent) 因 hasContent=true 提前揭盖，用户看到
      // 半加载列表 + "加载中..."。过渡态本身必须是否决揭盖的理由。
      expect(
        shouldCoverOfficialPage(
          rows: 0,
          composer: true,
          handshake: false,
          loadingRow: true,
          takeover: false,
          blank: false,
        ),
        isTrue,
      );
    });

    test('列表已加载但过渡卡叠在上面（切换会话场景）：盖住', () {
      expect(
        shouldCoverOfficialPage(
          rows: 9,
          composer: true,
          handshake: true,
          loadingRow: false,
          takeover: false,
          blank: false,
        ),
        isTrue,
      );
    });

    test('工作区就绪（任务行 + 输入区，无过渡信号）：揭开', () {
      expect(
        shouldCoverOfficialPage(
          rows: 9,
          composer: true,
          handshake: false,
          loadingRow: false,
          takeover: false,
          blank: false,
        ),
        isFalse,
      );
    });

    test('零任务的工作区（只有输入区，无过渡信号）：揭开', () {
      expect(
        shouldCoverOfficialPage(
          rows: 0,
          composer: true,
          handshake: false,
          loadingRow: false,
          takeover: false,
          blank: false,
        ),
        isFalse,
      );
    });

    test('页面空白：盖住', () {
      expect(
        shouldCoverOfficialPage(
          rows: 0,
          composer: false,
          handshake: false,
          loadingRow: false,
          takeover: false,
          blank: true,
        ),
        isTrue,
      );
    });

    test('被顶号（终态）：优先揭盖，让用户读到原因', () {
      expect(
        shouldCoverOfficialPage(
          rows: 0,
          composer: false,
          handshake: true,
          loadingRow: true,
          takeover: true,
          blank: false,
        ),
        isFalse,
      );
    });
  });
}

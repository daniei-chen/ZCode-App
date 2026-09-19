import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/ui/official_remote_page.dart';

/// iter6 F-6：`OfficialRemotePageController` 的遮盖观察者契约。
/// 静默刷新依赖"只在值变化时回调"——外壳 build 里的幂等 setCovered 不能刷屏。
void main() {
  test('同值 setCovered 不回调（外壳 build 幂等调用不刷屏）', () {
    final controller = OfficialRemotePageController();
    var calls = 0;
    controller.attachCoverObserver((_) => calls++);
    controller.setCovered(false); // 初始就是 false
    controller.setCovered(false);
    expect(calls, 0);
  });

  test('值变化回调一次并携带新值', () {
    final controller = OfficialRemotePageController();
    final seen = <bool>[];
    controller.attachCoverObserver(seen.add);
    controller.setCovered(true);
    controller.setCovered(true); // 幂等
    controller.setCovered(false);
    expect(seen, [true, false]);
    expect(controller.covered, isFalse);
  });

  test('detach 后不再回调', () {
    final controller = OfficialRemotePageController();
    var calls = 0;
    controller.attachCoverObserver((_) => calls++);
    controller.setCovered(true);
    expect(calls, 1);
    controller.detach();
    controller.setCovered(false);
    expect(calls, 1, reason: 'detach 必须清掉观察者，防止页面销毁后悬挂回调');
  });
}

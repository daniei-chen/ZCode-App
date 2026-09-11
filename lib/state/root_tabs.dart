import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 根部导航布局：
/// IndexedStack 的子项依次为
/// [设备会话 × N, 任务页, 工作台(面板)页, 设备页, 设置页]。
/// 设备会话永远保持挂载（切换不重连的关键），其余四个是底部 Tab 页。
abstract final class RootTabs {
  static const int count = 4;

  static int tasks(int deviceCount) => deviceCount;

  static int panels(int deviceCount) => deviceCount + 1;

  static int devices(int deviceCount) => deviceCount + 2;

  static int settings(int deviceCount) => deviceCount + 3;

  static int children(int deviceCount) => deviceCount + count;

  /// 是否位于四个根 Tab 之一（而非某台设备的会话详情）。
  static bool onRoot(int active, int deviceCount) =>
      active >= deviceCount && active < deviceCount + count;
}

/// 任务卡/通知卡点击后，希望在目标设备的会话页内进一步定位到某个会话。
class PendingSessionJump {
  const PendingSessionJump({required this.deviceId, required this.sessionId});

  final String deviceId;

  final String sessionId;
}

class PendingSessionJumpNotifier extends Notifier<PendingSessionJump?> {
  @override
  PendingSessionJump? build() => null;

  void set(PendingSessionJump jump) => state = jump;

  void clear() {
    if (state == null) return;
    state = null;
  }
}

final pendingSessionJumpProvider =
    NotifierProvider<PendingSessionJumpNotifier, PendingSessionJump?>(
      PendingSessionJumpNotifier.new,
    );

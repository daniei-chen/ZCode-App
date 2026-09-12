import 'package:flutter_riverpod/flutter_riverpod.dart';

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

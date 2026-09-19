import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 主 frame 桥令牌的健康状态（F03 的诊断面 / 真机定位用）。
///
/// 现场教训：v1.1.2 的真机诊断包里只有 `bridgeTokenMissing` 一条告警，看不出
/// "钩子没执行"还是"令牌没给"还是"给了但读回不一致"——诊断页现在直接展示
/// 每台设备（每个 generation）的令牌状态，下一次用户贴诊断包就能一眼定位。
class BridgeHealth {
  const BridgeHealth({
    required this.deviceId,
    required this.generation,
    required this.ready,
  });

  final String deviceId;
  final int generation;

  /// 令牌是否已确认落地（read-back 与注入值一致）。
  final bool ready;

  @override
  String toString() => 'BridgeHealth($deviceId gen=$generation ready=$ready)';
}

class BridgeHealthNotifier extends Notifier<Map<String, BridgeHealth>> {
  @override
  Map<String, BridgeHealth> build() => const {};

  void report(String deviceId, int generation, {required bool ready}) {
    if (deviceId.isEmpty) return;
    final current = state[deviceId];
    // 旧 generation 的迟到状态不得覆盖新代（iter12 W-021：原先这里有两个
    // 相邻 if，第一个被第二个完全包含——任何 generation 更旧的状态一律
    // 丢弃，与 ready 是否一致无关）。
    if (current != null && current.generation > generation) return;
    state = {
      ...state,
      deviceId: BridgeHealth(
        deviceId: deviceId,
        generation: generation,
        ready: ready,
      ),
    };
  }

  void forget(String deviceId) {
    if (!state.containsKey(deviceId)) return;
    state = {...state}..remove(deviceId);
  }

  void clear() => state = const {};

  /// 擦除事务（R-04）：与 `clear` 同义，保留别名便于与其他 state 统一命名。
  void clearAll() => clear();
}

final bridgeHealthProvider =
    NotifierProvider<BridgeHealthNotifier, Map<String, BridgeHealth>>(
      BridgeHealthNotifier.new,
    );

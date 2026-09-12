import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/device_store.dart';

/// 原生 Relay 增强层总开关（内部开关，默认关）。
///
/// 关闭：App 行为与历史版本一致（全部设备 WebView 常驻，无原生桥）。
/// 开启：设备生命周期协调器接管每台设备的通道仲裁（见
/// [DeviceRelayCoordinator]）——活动设备由 WebView 持有配对，其余设备
/// 由原生桥供数（任务列表、事件流、通知门控）。
class NativeChannelNotifier extends Notifier<bool> {
  NativeChannelNotifier({this.initial = false});

  final bool initial;

  @override
  bool build() => initial;

  Future<void> set(bool value) async {
    state = value;
    await DeviceStore.instance.setNativeChannelEnabled(value);
  }
}

final nativeChannelProvider =
    NotifierProvider<NativeChannelNotifier, bool>(NativeChannelNotifier.new);

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/device_store.dart';

/// 启动进入页：'lastDevice'（恢复最近使用的设备）或 'launcher'（设备中心）。
class StartupTargetNotifier extends Notifier<String> {
  StartupTargetNotifier({this.initial = 'lastDevice'});

  final String initial;

  @override
  String build() => initial;

  Future<void> set(String value) async {
    state = value;
    await DeviceStore.instance.setStartupTarget(value);
  }
}

final startupTargetProvider =
    NotifierProvider<StartupTargetNotifier, String>(StartupTargetNotifier.new);

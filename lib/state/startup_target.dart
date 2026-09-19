import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/device_store.dart';

/// 启动进入页：'lastDevice'（恢复最近使用的设备）或 'launcher'（设备中心）。
class StartupTargetNotifier extends Notifier<String> {
  StartupTargetNotifier({this.initial = 'lastDevice'});

  final String initial;

  @override
  String build() => initial;

  Future<void> set(String value) async {
    // 持久化成功后再发布 state（iter7 R-2，与 ThemeModeNotifier 同口径），
    // 写失败回读磁盘真实值，UI 弹回而不是显示假成功。
    try {
      await DeviceStore.instance.setStartupTarget(value);
      state = value;
    } catch (_) {
      state = initial;
    }
  }
}

final startupTargetProvider =
    NotifierProvider<StartupTargetNotifier, String>(StartupTargetNotifier.new);

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'services/notifier.dart';
import 'state/app_lifecycle.dart';
import 'state/connection_status.dart';
import 'state/relay_monitor.dart';

/// 头无监控隔离体的入口（v1.3.1，由 MonitorKeepAliveService 宿主）。
///
/// 背景：通知管线原本全部活在 Activity 的 Flutter 引擎里——用户划掉
/// 最近任务或系统回收 Activity 时引擎随之销毁，Dart 侧全部停止，前台
/// 服务只保住进程保不住通知。本入口让常驻服务自持一个**没有 UI 的
/// Flutter 引擎**，专跑原生监控通道（relay monitor）+ 系统通知：
/// * Activity 被回收 → 引擎仍在服务里活着，完成/失败/断连照常提醒；
/// * 系统按 START_STICKY 重建服务 → onCreate 重新拉起本入口，监控自愈；
/// * UI 前台时被 suspend（见 [RelayMonitorNotifier.suspend]），事件交给
///   WebView 路径，避免双源重复。
@pragma('vm:entry-point')
Future<void> monitorMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 断连/恢复通知只在此隔离体发出（UI 引擎同款评估器只做状态聚合）。
  ConnectionStatusNotifier.emitSystemNotifications = true;
  final container = ProviderContainer(
    overrides: [
      // 头无隔离体收不到 Activity 生命周期回调，而 Notifier 默认值是
      // resumed——NotificationGate 会把它当前台并吞掉提醒。固定为
      // paused：后台口径，一律放行。
      appLifecycleProvider.overrideWith(() => _HeadlessLifecycle()),
    ],
  );
  await NotifierService.instance.init();
  const control = MethodChannel('zremote/monitor_control');
  control.setMethodCallHandler((call) async {
    final monitor = container.read(relayMonitorProvider.notifier);
    switch (call.method) {
      case 'suspend':
        await monitor.suspend();
      case 'resume':
        await monitor.resume();
    }
    return null;
  });
  // 设备表无 seed 构建 = 从存储异步加载；relayMonitorProvider 监听它，
  // 载入完成后自动为每台设备建连。
  container.read(relayMonitorProvider.notifier);
  // 服务持有引擎即持有隔离体；这里永不返回作为双保险。
  await Completer<void>().future;
}

class _HeadlessLifecycle extends AppLifecycleNotifier {
  @override
  AppLifecycleState build() => AppLifecycleState.paused;
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/notification_prefs.dart';

export '../models/notification_prefs.dart';
import '../services/app_log.dart';
import '../services/device_store.dart';
import '../services/structured_log.dart';

class NotificationPrefsNotifier extends Notifier<NotificationPrefs> {
  @override
  NotificationPrefs build() {
    // 启动加载失败（存储损坏/插件异常）不得成为 unhandled zone error：
    // 留痕后停在默认值，用户拨动开关时走 set() 的持久化优先兜底（iter8 U-3）。
    _load().catchError((Object e) {
      AppLog.failure(LogEvent.notificationPrefsPersistFailed, e,
          fields: {LogField.reason: 'prefs_load_failed'});
    });
    return const NotificationPrefs();
  }

  Future<void> _load() async {
    state = await DeviceStore.instance.notificationPrefs();
  }

  Future<void> set(NotificationPrefs prefs) async {
    // 持久化成功后再发布 state（iter7 R-2，与 ThemeModeNotifier 同口径）：
    // 乐观更新会在写失败时"UI 已改、重启回滚"。失败时留痕并回读磁盘真实
    // 值，UI 弹回而不是显示假成功；后端持续损坏时回退默认值兜底。
    try {
      await DeviceStore.instance.setNotificationPrefs(prefs);
      state = prefs;
    } catch (e) {
      AppLog.failure(LogEvent.notificationPrefsPersistFailed, e,
          fields: {LogField.reason: 'prefs_persist_failed'});
      try {
        await _load();
      } catch (_) {
        state = const NotificationPrefs();
      }
    }
  }
}

final notificationPrefsProvider =
    NotifierProvider<NotificationPrefsNotifier, NotificationPrefs>(
      NotificationPrefsNotifier.new,
    );

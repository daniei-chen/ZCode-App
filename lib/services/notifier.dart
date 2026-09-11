import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../models/device_label.dart';
import 'event_observer.dart';

class NotificationSpec {
  const NotificationSpec({
    required this.channelId,
    required this.channelName,
    required this.importance,
    required this.priority,
    required this.title,
    required this.body,
    required this.payload,
  });

  final String channelId;
  final String channelName;
  final Importance importance;
  final Priority priority;
  final String title;
  final String body;

  final String payload;

  static int stableId(RemoteDevice device, ObservedEvent event) =>
      (device.id.hashCode ^
          event.type.hashCode ^
          (event.taskId?.hashCode ?? 0)) &
      0x7FFFFFFF;

  // These channels are deliberately separate from the previous custom-sound
  // channels. Android persists channel sound settings, so a new id guarantees
  // that an outside-app alert starts with the system default sound.
  static const _approvalChannel = 'zr_perm_alert_v5';
  static const _failureChannel = 'zr_fail_alert_v5';
  static const _completeChannel = 'zr_done_alert_v5';

  static Set<int> cancellableIds(RemoteDevice device, String taskId) => {
    stableId(device, ObservedEvent(type: 'permission_request', taskId: taskId)),
    stableId(
      device,
      ObservedEvent(type: 'elicitation_request', taskId: taskId),
    ),
  };

  /// 通知标题只保留会话名。事件类型放在系统通知频道和正文里，避免用户
  /// 看到一串没有上下文的“任务完成通知”。
  static String titleFor(
    RemoteDevice device,
    String? sessionTitle,
    AppLocalizations l10n,
  ) {
    final title = _clean(sessionTitle);
    return title.isNotEmpty ? title : device.displayName(l10n);
  }

  /// 正文优先使用事件/会话恢复出来的内容；老版本桌面端没有附带摘要时，
  /// 才使用可点击的状态提示作为兜底。
  static String bodyFor(String type, String? summary, AppLocalizations l10n) {
    final content = _clean(summary);
    if (content.isNotEmpty && content != type) return _clip(content, 180);
    return switch (type) {
      'permission_request' => l10n.notifPermBody,
      'elicitation_request' => l10n.notifElicitBody,
      'completed' => l10n.notifDoneBody,
      'error' => l10n.notifErrorBody,
      _ => '点击打开对话',
    };
  }

  static String _clean(String? value) =>
      (value ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _clip(String value, int max) =>
      value.length > max ? '${value.substring(0, max)}…' : value;

  static NotificationSpec? from(
    RemoteDevice device,
    ObservedEvent event, [
    AppLocalizations? l10n,
  ]) => _from(device, event, l10n ?? l10nZh);

  static NotificationSpec? _from(
    RemoteDevice device,
    ObservedEvent event,
    AppLocalizations l,
  ) {
    final title = titleFor(device, event.sessionTitle, l);
    final body = bodyFor(event.type, event.summary, l);
    switch (event.type) {
      case 'permission_request':
        return NotificationSpec(
          channelId: _approvalChannel,
          channelName: l.notifChannelApproval,
          importance: Importance.high,
          priority: Priority.high,
          title: title,
          body: body,
          payload: _payload(device, event.taskId),
        );
      case 'elicitation_request':
        return NotificationSpec(
          channelId: _approvalChannel,
          channelName: l.notifChannelApproval,
          importance: Importance.high,
          priority: Priority.high,
          title: title,
          body: body,
          payload: _payload(device, event.taskId),
        );
      case 'error':
        return NotificationSpec(
          channelId: _failureChannel,
          channelName: l.notifChannelFail,
          importance: Importance.high,
          priority: Priority.high,
          title: title,
          body: body,
          payload: _payload(device, event.taskId),
        );
      case 'completed':
        return NotificationSpec(
          channelId: _completeChannel,
          channelName: l.notifChannelDone,
          importance: Importance.high,
          priority: Priority.high,
          title: title,
          body: body,
          payload: _payload(device, event.taskId),
        );
      default:
        return null;
    }
  }
}

/// Notification payload: 'deviceId' or 'deviceId|sessionId'.  The session
/// part lets the tap deep-link straight into the conversation shell for
/// that session (backward compatible with the plain device id).
String _payload(RemoteDevice device, String? taskId) =>
    taskId == null || taskId.isEmpty ? device.id : '${device.id}|$taskId';

abstract final class NotificationTap {
  static String? _pending;
  static void Function(String deviceId)? _onTap;

  static void bind(void Function(String deviceId)? onTap) => _onTap = onTap;

  static void route(String? payload) {
    if (payload == null || payload.isEmpty) return;
    final onTap = _onTap;
    if (onTap != null) {
      onTap(payload);
    } else {
      _pending = payload;
    }
  }

  static String? consumePending() {
    final pending = _pending;
    _pending = null;
    return pending;
  }
}

NotificationVisibility lockScreenVisibility({required bool lockEnabled}) =>
    lockEnabled
    ? NotificationVisibility.private
    : NotificationVisibility.public;

class NotifierService {
  NotifierService._();

  static final NotifierService instance = NotifierService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const MethodChannel _soundChannel = MethodChannel(
    'zremote/notification_sound',
  );

  Future<void>? _initFuture;
  bool _permissionAsked = false;
  bool _lockScreenRedact = false;

  void setLockScreenRedact(bool value) => _lockScreenRedact = value;

  Future<void> ensurePermission() async {
    if (_permissionAsked) return;
    _permissionAsked = true;
    try {
      // Initialization is intentionally allowed to run in parallel with the
      // first Flutter frame. Wait here before touching the plugin so startup
      // never has to block on notification setup.
      await init();
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } catch (_) {}
  }

  Future<void> init() => _initFuture ??= _initialize();

  Future<void> _initialize() async {
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          // flutter_local_notifications resolves the small notification icon
          // from drawable resources. The adaptive launcher icon is a mipmap
          // and is not accepted by the plugin on Android 12+.
          android: AndroidInitializationSettings('ic_notification'),
        ),
        onDidReceiveNotificationResponse: (response) =>
            NotificationTap.route(response.payload),
      );
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp ?? false) {
        NotificationTap.route(details?.notificationResponse?.payload);
      }
    } catch (e) {
      debugPrint('[ZR] notification init failed: $e');
    }
  }

  Future<void> playInAppSound() async {
    try {
      await _soundChannel.invokeMethod<void>('playDefault');
    } catch (_) {
      // Non-Android platforms and test environments still get a short alert
      // where Flutter exposes one.
      try {
        await SystemSound.play(SystemSoundType.alert);
      } catch (_) {}
    }
  }

  Future<void> notifyFrom(
    RemoteDevice device,
    ObservedEvent event, {
    AppLocalizations? l10n,
  }) async {
    // Both in-app and outside-app alerts intentionally use the Android system
    // default notification sound. Custom sound choices are not stored.
    final spec = NotificationSpec.from(device, event, l10n);
    if (spec == null) return;
    try {
      if (!_permissionAsked) await ensurePermission();
      final id = NotificationSpec.stableId(device, event);
      await _plugin.show(
        id: id,
        title: spec.title,
        body: spec.body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            spec.channelId,
            spec.channelName,
            icon: 'ic_notification',
            importance: spec.importance,
            priority: spec.priority,
            channelShowBadge: true,
            playSound: true,
            sound: null,
            enableVibration: true,
            silent: false,
            onlyAlertOnce: true,
            visibility: lockScreenVisibility(lockEnabled: _lockScreenRedact),
          ),
        ),
        payload: spec.payload,
      );
    } catch (e) {
      debugPrint('[ZR] notification show failed: $e');
    }
  }

  Future<bool> showTest() async {
    try {
      if (!_permissionAsked) await ensurePermission();
      await _plugin.show(
        id: 0x5A5254,
        title: 'ZCode',
        body: l10nZh.notifTestBody,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'zr_done_alert_v5',
            l10nZh.notifChannelDone,
            icon: 'ic_notification',
            importance: Importance.high,
            priority: Priority.high,
            channelShowBadge: true,
            playSound: true,
            // This button exercises the outside-app OS notification path, so
            // it deliberately uses the Android system default sound too.
            sound: null,
            enableVibration: true,
            silent: false,
            onlyAlertOnce: true,
          ),
        ),
      );
      return true;
    } catch (e) {
      debugPrint('[ZR] notification test failed: $e');
      return false;
    }
  }

  Future<void> cancelPending(RemoteDevice device, String taskId) async {
    for (final id in NotificationSpec.cancellableIds(device, taskId)) {
      try {
        await _plugin.cancel(id: id);
      } catch (_) {}
    }
  }
}

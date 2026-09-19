import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../models/device_label.dart';
import '../models/notification_prefs.dart';
import 'event_observer.dart';
import 'app_log.dart';
import 'structured_log.dart';

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

  /// Dart 的 hashCode 跨进程不保证稳定（重启后可能变化），通知 ID 必须
  /// 跨进程/跨版本一致，否则撤不掉旧通知。改用固定算法：SHA256 前 31 bit。
  static int stableId(RemoteDevice device, ObservedEvent event) {
    final key = utf8
        .encode('${device.id}\x00${event.type}\x00${event.taskId ?? ''}');
    final digest = sha256.convert(key).bytes;
    return ((digest[0] << 24) |
            (digest[1] << 16) |
            (digest[2] << 8) |
            digest[3]) &
        0x7FFFFFFF;
  }

  // Android persists a channel's sound choice forever. Bump the channel ids so
  // upgrades from the old silent/custom-sound experiments get a fresh channel
  // whose `sound: null` + `playSound: true` resolves to the system default.
  static const _approvalChannel = 'zr_perm_alert_v6';
  static const _failureChannel = 'zr_fail_alert_v6';
  static const _completeChannel = 'zr_done_alert_v6';

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
    // 标题与正文（180）同上限：会话标题来自页面数据，无界标题会原样走进
    // 系统通知通道、DeviceFeed 与 UI（安全审计 S-7）。
    return title.isNotEmpty ? _clip(title, 120) : device.displayName(l10n);
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
  Future<void>? _permissionFuture;
  bool _lockScreenRedact = false;
  String _alertMode = NotificationPrefs.kAlertSound;

  void setLockScreenRedact(bool value) => _lockScreenRedact = value;

  /// 提醒方式（声音/仅振动/静音）。Android 渠道创建后声音不可再改，
  /// 因此通知按模式投递到不同的渠道族（见 [_channelId]）。
  void setAlertMode(String mode) => _alertMode = mode;

  // ignore: avoid_shadowing_type_parameters
  String _channelId(String base) => '${base}_$_alertMode';

  Future<void> ensurePermission() => _permissionFuture ??= _requestPermission();

  Future<void> _requestPermission() async {
    try {
      // A launch-time init is started in parallel with the first Flutter
      // frame. Every event awaits this shared future, so the first alert
      // cannot race plugin initialization or Android 13+ permission setup.
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
      AppLog.failure(
        LogEvent.notificationInitFailed,
        e,
        fields: {LogField.reason: 'init'},
      );
    }
  }

  Future<void> playInAppSound() async {
    // 仅振动/静音模式下应用内提示音一并停掉；悬浮卡本身已是视觉反馈。
    if (_alertMode != NotificationPrefs.kAlertSound) return;
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
    NotificationSpec? spec;
    try {
      // NotificationSpec.from 会在兜底路径取本地化文案（l10nZh）——本地化未
      // 就绪或脏 summary 都可能抛错。notifyFrom 走 unawaited 调用链，抛出去
      // 就是 unhandled zone error，必须受捕（D-20260916-15）。构造与 show
      // 分开留痕：reason=spec / reason=show，triage 不被带偏（iter1 复审 F-2）。
      spec = NotificationSpec.from(device, event, l10n);
    } catch (e) {
      AppLog.failure(
        LogEvent.notificationShowFailed,
        e,
        fields: {LogField.reason: 'spec'},
      );
      return;
    }
    if (spec == null) return;
    try {
      await ensurePermission();
      final id = NotificationSpec.stableId(device, event);
      await _plugin.show(
        id: id,
        title: spec.title,
        body: spec.body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId(spec.channelId),
            spec.channelName,
            icon: 'ic_notification',
            importance: spec.importance,
            priority: spec.priority,
            channelShowBadge: true,
            playSound: _alertMode == NotificationPrefs.kAlertSound,
            sound: null,
            enableVibration: _alertMode != NotificationPrefs.kAlertSilent,
            silent: _alertMode == NotificationPrefs.kAlertSilent,
            // A new terminal event must alert even when Android reuses the
            // stable device/type/session notification id.
            onlyAlertOnce: false,
            visibility: lockScreenVisibility(lockEnabled: _lockScreenRedact),
          ),
        ),
        payload: spec.payload,
      );
    } catch (e) {
      AppLog.failure(
        LogEvent.notificationShowFailed,
        e,
        fields: {LogField.reason: 'show'},
      );
    }
  }

  Future<bool> showTest() async {
    try {
      await ensurePermission();
      await _plugin.show(
        id: 0x5A5254,
        title: 'ZCode',
        body: l10nZh.notifTestBody,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            // 测试按钮模拟的是真实告警路径，同样跟随提醒方式。
            _channelId('zr_done_alert_v6'),
            l10nZh.notifChannelDone,
            icon: 'ic_notification',
            importance: Importance.high,
            priority: Priority.high,
            channelShowBadge: true,
            playSound: _alertMode == NotificationPrefs.kAlertSound,
            sound: null,
            enableVibration: _alertMode != NotificationPrefs.kAlertSilent,
            silent: _alertMode == NotificationPrefs.kAlertSilent,
            onlyAlertOnce: false,
          ),
        ),
      );
      return true;
    } catch (e) {
      AppLog.failure(
        LogEvent.notificationTestFailed,
        e,
        fields: {LogField.reason: 'test'},
      );
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

  /// 擦除事务（R-04）：撤销所有已展示/待展示的通知。
  ///
  /// 通知 payload 里带着设备与会话 id，凭证都被清掉后它们不能继续留在
  /// 系统通知栏，否则点开还会带着已删除设备的跳转目标。失败只影响撤销，
  /// 由调用方决定是否视为擦除失败。
  ///
  /// b5 评审 H-2：插件通道的**瞬时**故障不应把"擦除失败"永久化（对没有系统
  /// 锁屏凭据的用户，这会同时堵死两条恢复路径）。这里做一次短退避重试，
  /// 仍失败才如实上报；成功语义不变（= 撤销请求已提交，插件无查询 API）。
  Future<void> cancelAll() async {
    try {
      await _plugin.cancelAll();
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await _plugin.cancelAll(); // 第二次失败即向上抛，由擦除事务如实记账。
    }
  }
}

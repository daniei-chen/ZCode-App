import 'dart:async';
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
import 'notification_history.dart';
import 'structured_log.dart';
import '../state/relay_agent.dart' show notificationActionDispatcher;

/// 通知动作按钮 id（v1.3.0）：与点按通知体同语义（深链直达会话）。
const String kOpenActionId = 'zr_open';

/// 连接状态渠道（v1.3.0，仿 DeepSeek-Harness 的"连接状态"类别）：
/// 断连/恢复通知走这条 IMPORTANCE_LOW 静默渠道，不随提醒方式变化。
const String kConnectionChannel = 'zr_conn_v8';

/// 通知动作按钮 id（v1.4.0）：原生接收器按 id 分派允许/拒绝/回复。
const String kAllowActionId = 'zr_allow';
const String kDenyActionId = 'zr_deny';
const String kReplyActionId = 'zr_reply';

/// 按事件类型挂动作按钮（v1.4.0）：
/// * 审批：拿到选项 id 才挂"允许/拒绝"（answer={optionId}，bundle 实证）；
///   没拿到选项时退化为"打开会话"——宁可少按钮，不可点了报错；
/// * 提问/完成：直接回复（RemoteInput → freeText / sendText）。
List<AndroidNotificationAction> _actionsFor(
  ObservedEvent event,
  AppLocalizations l10n,
) {
  final open = AndroidNotificationAction(kOpenActionId, l10n.notifActionOpen);
  AndroidNotificationAction reply() => AndroidNotificationAction(
    kReplyActionId,
    l10n.notifActionReply,
    showsUserInterface: false,
    inputs: [
      AndroidNotificationActionInput(
        label: l10n.notifActionReplyHint,
        allowFreeFormInput: true,
      ),
    ],
  );
  switch (event.type) {
    case 'permission_request':
      final allow = event.allowOptionId;
      final deny = event.denyOptionId;
      if (allow != null &&
          allow.isNotEmpty &&
          deny != null &&
          deny.isNotEmpty) {
        return [
          AndroidNotificationAction(kAllowActionId, l10n.notifActionAllow),
          AndroidNotificationAction(kDenyActionId, l10n.notifActionDeny),
        ];
      }
      return [open];
    case 'elicitation_request':
    case 'completed':
      return [reply(), open];
    default:
      return [open];
  }
}

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
  static const _approvalChannel = 'zr_perm_alert_v7';
  static const _failureChannel = 'zr_fail_alert_v7';
  static const _completeChannel = 'zr_done_alert_v7';

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
      case 'elicitation_request':
        return NotificationSpec(
          channelId: _approvalChannel,
          channelName: l.notifChannelApproval,
          importance: Importance.high,
          priority: Priority.high,
          title: title,
          body: body,
          payload: actionPayload(device, event),
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

/// v1.4.0 审批/回复事件的扩展载荷：
/// 'deviceId|sessionId|interactionId|allowOptionId|denyOptionId'——前缀
/// 向后兼容（点按深链只取前两段），后段供通知动作按钮执行
/// resolveInteraction（允许/拒绝）与 sendText（回复）。
String actionPayload(RemoteDevice device, ObservedEvent event) => [
  device.id,
  if (event.taskId?.isNotEmpty == true) event.taskId,
  if (event.interactionId?.isNotEmpty == true) event.interactionId,
  if (event.allowOptionId?.isNotEmpty == true) event.allowOptionId,
  if (event.denyOptionId?.isNotEmpty == true) event.denyOptionId,
].join('|');

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

  static const MethodChannel _channelsChannel = MethodChannel(
    'zremote/notification_channels',
  );

  /// 提醒方式（声音/仅振动/静音）。Android 渠道创建后声音不可再改，
  /// 因此通知按模式投递到不同的渠道族（见 [_channelId]）。
  void setAlertMode(String mode) {
    _alertMode = mode;
    // 模式切换即重建渠道族并清掉旧渠道，系统"通知类别"列表保持干净
    // （对齐 DeepSeek-Harness 的分类形态）；失败静默，不影响功能。
    unawaited(_ensureNativeChannels(mode));
  }

  /// 启动时预建全部告警渠道（v1.2.2，对齐 DSH）：渠道只在首条通知时创建
  /// 的话，用户在系统设置里永远看不到"失败/需要你的操作"这两个类别。
  /// 预建让三个类别装好即可见、可单独调。
  Future<void> _ensureNativeChannels(String mode) async {
    try {
      await _channelsChannel.invokeMethod<void>('ensureChannels', {
        'mode': mode,
      });
    } catch (_) {}
  }

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
        // 动作按钮（允许/拒绝/回复，v1.4.0）：插件在独立后台 isolate 里
        // 分发——不依赖两个引擎谁活着，`@pragma('vm:entry-point')` 保底。
        onDidReceiveBackgroundNotificationResponse:
            notificationActionDispatcher,
      );
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp ?? false) {
        NotificationTap.route(details?.notificationResponse?.payload);
      }
      await _ensureNativeChannels(_alertMode);
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
    final spec = NotificationSpec.from(device, event, l10n);
    if (spec == null) return;
    final effectiveL10n = l10n ?? l10nZh;
    // 系统通知的本地留底（v1.3.0）：投递前记录，错过弹窗可在"通知历史"
    // 回看。历史只含展示文本与深链载荷，与通知内容同源，无新增敏感面。
    unawaited(
      NotificationHistory.record(
        NotificationHistoryEntry(
          id: NotificationSpec.stableId(device, event),
          at: DateTime.now(),
          deviceId: device.id,
          deviceName: device.displayName(effectiveL10n),
          type: event.type,
          title: spec.title,
          body: spec.body,
          payload: spec.payload,
        ),
      ),
    );
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
            // 动作按钮（v1.4.0）：审批=允许/拒绝（有选项时）、完成/提问=
            // 直接回复，其余=打开会话。见 [_actionsFor]。
            actions: _actionsFor(event, effectiveL10n),
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

  /// 连接状态通知（v1.3.0）：断连/恢复用 IMPORTANCE_LOW 静默渠道，
  /// 不打扰但要留痕。恢复通知与断连通知共用每设备稳定 id，互相替换不堆叠。
  Future<void> showConnection({
    required RemoteDevice device,
    required bool connected,
    AppLocalizations? l10n,
  }) async {
    final effectiveL10n = l10n ?? l10nZh;
    final title = device.displayName(effectiveL10n);
    final body = connected
        ? effectiveL10n.notifConnRestored
        : effectiveL10n.notifConnDisconnected;
    try {
      await ensurePermission();
      await _plugin.show(
        id: 0x5A4301 + (stableDeviceKey(device.id) & 0xFF),
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            kConnectionChannel,
            effectiveL10n.notifChannelConn,
            icon: 'ic_notification',
            importance: Importance.low,
            priority: Priority.low,
            channelShowBadge: false,
            playSound: false,
            enableVibration: false,
            onlyAlertOnce: true,
          ),
        ),
        payload: device.id,
      );
      AppLog.event(
        LogEvent.connectionStateNotified,
        level: LogLevel.debug,
        fields: {LogField.ok: connected},
      );
    } catch (_) {}
  }

  /// 跨进程稳定的设备通知键（Dart hashCode 重启后不保证一致，见
  /// [NotificationSpec.stableId] 的同一约束）。
  static int stableDeviceKey(String deviceId) {
    final digest = sha256.convert(utf8.encode(deviceId)).bytes;
    return ((digest[0] << 24) |
            (digest[1] << 16) |
            (digest[2] << 8) |
            digest[3]) &
        0x7FFFFFFF;
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
            // 测试按钮模拟的是真实告警路径，同样跟随提醒方式。渠道基名必须
            // 与 NotificationSpec 的常量一致（v6 已被渠道清理删除）。
            _channelId('zr_done_alert_v7'),
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
}

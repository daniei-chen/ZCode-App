import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../models/device_label.dart';
import 'device_store.dart';
import 'event_observer.dart';

class NotificationSoundOption {
  const NotificationSoundOption({
    required this.id,
    required this.title,
    this.uri,
  });

  const NotificationSoundOption.systemDefault()
    : id = 'default',
      title = '系统默认',
      uri = null;

  final String id;
  final String title;
  final String? uri;
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
    this.soundUri,
  });

  final String channelId;
  final String channelName;
  final Importance importance;
  final Priority priority;
  final String title;
  final String body;

  final String payload;
  final String? soundUri;

  static int stableId(RemoteDevice device, ObservedEvent event) =>
      (device.id.hashCode ^
          event.type.hashCode ^
          (event.taskId?.hashCode ?? 0)) &
      0x7FFFFFFF;

  // These channels are deliberately separate from the previous custom-sound
  // channels. Android persists channel sound settings, so a new id guarantees
  // that an outside-app alert starts with the system default sound.
  static const _approvalChannel = 'zr_perm_alert_v4';
  static const _failureChannel = 'zr_fail_alert_v4';
  static const _completeChannel = 'zr_done_alert_v4';

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

  static String channelIdFor(String base, String? soundUri) {
    final normalized = _clean(soundUri);
    if (normalized.isEmpty) return base;
    final token = sha1
        .convert(utf8.encode(normalized))
        .toString()
        .substring(0, 10);
    return '${base}_$token';
  }

  static String _clean(String? value) =>
      (value ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _clip(String value, int max) =>
      value.length > max ? '${value.substring(0, max)}…' : value;

  static NotificationSpec? from(
    RemoteDevice device,
    ObservedEvent event, [
    AppLocalizations? l10n,
  ]) => _fromWithSound(device, event, l10n ?? l10nZh, null);

  static NotificationSpec? fromWithSound(
    RemoteDevice device,
    ObservedEvent event, {
    AppLocalizations? l10n,
    String? soundUri,
  }) => _fromWithSound(device, event, l10n ?? l10nZh, soundUri);

  static NotificationSpec? _fromWithSound(
    RemoteDevice device,
    ObservedEvent event,
    AppLocalizations l,
    String? selectedSoundUri,
  ) {
    final soundUri = _clean(selectedSoundUri).isEmpty
        ? null
        : _clean(selectedSoundUri);
    final title = titleFor(device, event.sessionTitle, l);
    final body = bodyFor(event.type, event.summary, l);
    switch (event.type) {
      case 'permission_request':
        return NotificationSpec(
          // Android 会持久化通道的优先级；使用新的 id 让旧版静默通道
          // 不会把新版的声音/悬浮提醒继续压掉。
          channelId: channelIdFor(_approvalChannel, soundUri),
          channelName: l.notifChannelApproval,
          importance: Importance.high,
          priority: Priority.high,
          title: title,
          body: body,
          payload: _payload(device, event.taskId),
          soundUri: soundUri,
        );
      case 'elicitation_request':
        return NotificationSpec(
          channelId: channelIdFor(_approvalChannel, soundUri),
          channelName: l.notifChannelApproval,
          importance: Importance.high,
          priority: Priority.high,
          title: title,
          body: body,
          payload: _payload(device, event.taskId),
          soundUri: soundUri,
        );
      case 'error':
        return NotificationSpec(
          channelId: channelIdFor(_failureChannel, soundUri),
          channelName: l.notifChannelFail,
          importance: Importance.high,
          priority: Priority.high,
          title: title,
          body: body,
          payload: _payload(device, event.taskId),
          soundUri: soundUri,
        );
      case 'completed':
        return NotificationSpec(
          channelId: channelIdFor(_completeChannel, soundUri),
          channelName: l.notifChannelDone,
          importance: Importance.high,
          priority: Priority.high,
          title: title,
          body: body,
          payload: _payload(device, event.taskId),
          soundUri: soundUri,
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
  Future<void>? _soundLoadFuture;
  bool _permissionAsked = false;
  bool _lockScreenRedact = false;
  String? _soundUri;

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
      await _loadSoundPreference();
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

  Future<void> _loadSoundPreference() async {
    _soundLoadFuture ??= () async {
      try {
        final prefs = await DeviceStore.instance.notificationPrefs();
        final value = prefs.soundUri.trim();
        _soundUri = value.isEmpty ? null : value;
      } catch (_) {}
    }();
    await _soundLoadFuture;
  }

  Future<List<NotificationSoundOption>> availableSounds() async {
    try {
      final raw = await _soundChannel.invokeMethod<List<dynamic>>('list');
      final values = <NotificationSoundOption>[
        const NotificationSoundOption.systemDefault(),
      ];
      for (final item in raw ?? const <dynamic>[]) {
        if (item is! Map) continue;
        final uri = (item['uri'] as String?)?.trim();
        final title = (item['title'] as String?)?.trim();
        if (uri == null || uri.isEmpty || title == null || title.isEmpty) {
          continue;
        }
        if (values.any((option) => option.uri == uri)) continue;
        values.add(
          NotificationSoundOption(
            id: (item['id'] as String?)?.trim() ?? uri,
            title: title,
            uri: uri,
          ),
        );
      }
      return values;
    } catch (_) {
      return const [NotificationSoundOption.systemDefault()];
    }
  }

  /// Applies a choice immediately. The settings provider persists it; this
  /// in-memory update makes the next foreground/background event use it too.
  void setSound(NotificationSoundOption option) {
    final uri = option.uri?.trim();
    _soundUri = uri == null || uri.isEmpty ? null : uri;
  }

  Future<void> playInAppSound() async {
    await _loadSoundPreference();
    try {
      await _soundChannel.invokeMethod<void>('play', _soundUri);
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
    // The selected sound is intentionally an in-app-only preference. Outside
    // the app Android uses its own default notification sound; custom content
    // URIs are not reliable across devices/ROMs.
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
            'zr_done_alert_v4',
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

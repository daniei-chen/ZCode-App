class NotificationPrefs {
  static const kAlertSound = 'sound';
  static const kAlertVibrate = 'vibrate';
  static const kAlertSilent = 'silent';

  const NotificationPrefs({
    this.approval = true,
    this.complete = true,
    this.fail = true,
    this.alertMode = kAlertSound,
  });

  final bool approval;

  final bool complete;

  final bool fail;

  /// 通知提醒方式：'sound'（系统声音+振动）/ 'vibrate'（仅振动）/ 'silent'（静音）。
  final String alertMode;

  NotificationPrefs copyWith({
    bool? approval,
    bool? complete,
    bool? fail,
    String? alertMode,
  }) => NotificationPrefs(
    approval: approval ?? this.approval,
    complete: complete ?? this.complete,
    fail: fail ?? this.fail,
    alertMode: alertMode ?? this.alertMode,
  );

  bool enabled(String eventType) => switch (eventType) {
    'permission_request' || 'elicitation_request' => approval,
    'completed' => complete,
    'error' => fail,
    _ => false,
  };
}

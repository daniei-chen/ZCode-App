class NotificationPrefs {
  const NotificationPrefs({
    this.approval = true,
    this.complete = true,
    this.fail = true,
    this.soundUri = '',
  });

  final bool approval;

  final bool complete;

  final bool fail;

  /// Empty means the Android system's current default notification sound.
  /// A full content URI is stored for a user-selected system tone.
  final String soundUri;

  NotificationPrefs copyWith({
    bool? approval,
    bool? complete,
    bool? fail,
    String? soundUri,
  }) => NotificationPrefs(
    approval: approval ?? this.approval,
    complete: complete ?? this.complete,
    fail: fail ?? this.fail,
    soundUri: soundUri ?? this.soundUri,
  );

  bool enabled(String eventType) => switch (eventType) {
    'permission_request' || 'elicitation_request' => approval,
    'completed' => complete,
    'error' => fail,
    _ => false,
  };
}

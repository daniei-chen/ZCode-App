/// Verified v4 command receipt (`sendConversationCommandV4` response).
///
/// Desktop schema (2026-09-11, see docs/PROTOCOL-DELTA-20260911.md):
/// `{commandId, status, reasonCode?, message?, revisionAtDecision, result?}`
/// where `status` is one of accepted / rejected / stale / duplicate / noop /
/// failed.  Only these six values are treated as a receipt; anything else is
/// an unknown shape and must not be mistaken for success.
enum CommandReceiptStatus {
  accepted,
  rejected,
  stale,
  duplicate,
  noop,
  failed,
  unknown;

  static CommandReceiptStatus parse(Object? raw) => switch (raw?.toString()) {
    'accepted' => accepted,
    'rejected' => rejected,
    'stale' => stale,
    'duplicate' => duplicate,
    'noop' => noop,
    'failed' => failed,
    _ => unknown,
  };

  /// The desktop applied (or had already applied) the command.
  ///
  /// `duplicate` means the same commandId was seen before, so the write is
  /// idempotent-success rather than an error the user must act on.
  bool get isSuccess => this == accepted || this == noop || this == duplicate;

  /// The desktop explicitly refused.  The previous local value must stay.
  bool get isRefusal => this == rejected || this == stale || this == failed;
}

class CommandReceipt {
  const CommandReceipt({
    required this.commandId,
    required this.status,
    this.reasonCode,
    this.message,
    this.revisionAtDecision,
    this.result,
    this.raw = const {},
  });

  final String commandId;
  final CommandReceiptStatus status;

  /// Machine-readable refusal reason (e.g. `thought_level_unsupported`).
  final String? reasonCode;

  /// Human-readable detail from the desktop; may contain nothing sensitive
  /// by contract, but callers must still not log it verbatim at info level.
  final String? message;
  final int? revisionAtDecision;
  final Map<String, dynamic>? result;
  final Map<String, dynamic> raw;

  bool get isSuccess => status.isSuccess;
  bool get isRefusal => status.isRefusal;

  /// `result.sessionId` for `createSession` style receipts.
  String? get createdSessionId {
    final r = result;
    if (r == null) return null;
    if (r['type']?.toString() == 'createSession') {
      final id = r['sessionId']?.toString();
      if (id != null && id.isNotEmpty) return id;
    }
    return null;
  }

  /// Short safe label for UI/banners: `status[:reasonCode]`.
  String get safeLabel => reasonCode == null || reasonCode!.isEmpty
      ? status.name
      : '${status.name}:$reasonCode';

  static CommandReceipt? tryParse(Object? value) {
    if (value is! Map) return null;
    final map = Map<String, dynamic>.from(value);
    final commandId = map['commandId']?.toString();
    if (commandId == null || commandId.isEmpty) return null;
    final status = CommandReceiptStatus.parse(map['status']);
    if (status == CommandReceiptStatus.unknown) return null;
    final result = map['result'];
    final revision = map['revisionAtDecision'];
    return CommandReceipt(
      commandId: commandId,
      status: status,
      reasonCode: _nonEmpty(map['reasonCode']),
      message: _nonEmpty(map['message']),
      revisionAtDecision: revision is num ? revision.toInt() : null,
      result: result is Map ? Map<String, dynamic>.from(result) : null,
      raw: map,
    );
  }

  static String? _nonEmpty(Object? v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }
}

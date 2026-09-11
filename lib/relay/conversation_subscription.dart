/// Acknowledgement returned by `zcode-agent.subscribeConversationV4`.
///
/// Verified desktop schema (2026-09-11):
/// `{ack: {subscriptionId: string, mode: 'snapshot' | 'resume', logEpoch: string}}`
///
/// A subscription is only real once this arrives.  Sending the RPC is not a
/// subscription; the previous implementation treated it as one and produced
/// the "subscribed but no rows" contradiction.
class ConversationSubscriptionAck {
  const ConversationSubscriptionAck({
    required this.subscriptionId,
    required this.mode,
    required this.logEpoch,
  });

  final String subscriptionId;

  /// `snapshot` when the desktop will replay from scratch, `resume` when it
  /// continues from the `base` we supplied.
  final String mode;
  final String logEpoch;

  bool get isSnapshot => mode == 'snapshot';
  bool get isResume => mode == 'resume';

  /// True when [value] has the ack envelope shape; used as the response
  /// predicate so the ack is consumed by its own request slot and can never
  /// be mistaken for the reply to a later call.
  static bool matches(Object? value) {
    if (value is! Map) return false;
    final ack = value['ack'];
    return ack is Map && ack['subscriptionId'] != null;
  }

  static ConversationSubscriptionAck? tryParse(Object? value) {
    if (!matches(value)) return null;
    final ack = Map<String, dynamic>.from((value as Map)['ack'] as Map);
    final id = ack['subscriptionId']?.toString() ?? '';
    if (id.isEmpty) return null;
    return ConversationSubscriptionAck(
      subscriptionId: id,
      mode: ack['mode']?.toString() ?? '',
      logEpoch: ack['logEpoch']?.toString() ?? '',
    );
  }
}

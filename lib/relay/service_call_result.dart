/// Outcome of one native service call with the failure reason preserved.
///
/// The previous helpers collapsed every failure into `null`, which is why the
/// UI could only say "桌面端拒绝了会话配置变更" without the real cause.
class ServiceCallResult {
  const ServiceCallResult.success(this.value) : error = null;

  const ServiceCallResult.failure(String this.error) : value = null;

  final Map<String, dynamic>? value;

  /// `fault.*` code from the desktop, or a local code such as `timeout`,
  /// `bridge_unavailable`, `agent_not_ready`.  Never a raw payload.
  final String? error;

  bool get ok => error == null;

  bool get isMethodNotFound =>
      error != null && error!.toLowerCase().contains('method_not_found');

  /// Short label safe for a banner: the code only.
  String get safeLabel => error ?? 'ok';
}

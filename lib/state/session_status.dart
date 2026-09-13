import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

enum SessionStatus { loading, live, error }

class RelayLedPolicy {
  RelayLedPolicy._();

  static const terminalReasons = <String>[
    'desktop-disconnected',
    'desktop-bootstrap-timeout',
    'connection-recovery-timeout',
    'session-not-found',
    'session-expired',
    'session-conflict',
    'workspace-closed',
    'invalid-mobile-connection',
    'kicked',
  ];

  static const _recoverableErrorCodes = <String>{'DEVICE_OFFLINE', 'INTERNAL'};

  static SessionStatus? onFrame(String body) {
    if (!body.startsWith('{')) return null;
    try {
      return onFrameRoot(jsonDecode(body));
    } catch (_) {
      return null;
    }
  }

  static SessionStatus? onFrameRoot(dynamic root) {
    if (root is! Map) return null;
    switch (root['type']) {
      case 'data':
        return SessionStatus.live;
      case 'error':
        final code = '${root['code'] ?? ''}';
        return _recoverableErrorCodes.contains(code)
            ? null
            : SessionStatus.error;
      default:
        return null;
    }
  }

  static bool isRelayTransport(String? url) {
    if (url == null || url.isEmpty) return false;
    final path = Uri.tryParse(url)?.path ?? '';
    if (path == '/ws') return true;
    if (path.startsWith('/ws/remote-control/')) return false;
    return path.startsWith('/ws/remote/');
  }

  static SessionStatus? onWsEvent(Map<String, dynamic> event) {
    if (!isRelayTransport(event['u'] as String?)) return null;
    switch (event['s']) {
      case 'open':
        return SessionStatus.loading;
      case 'closed':
        final reason = '${event['r'] ?? ''}';
        for (final terminal in terminalReasons) {
          if (reason.contains(terminal)) return SessionStatus.error;
        }
        return SessionStatus.loading;
    }
    return null;
  }
}

abstract final class PageLoadPolicy {
  static bool isMainDocFailure(bool? isForMainFrame) => isForMainFrame == true;

  static bool isHttpFailure(bool? isForMainFrame, int? statusCode) =>
      isForMainFrame == true && (statusCode ?? 0) >= 400;

  /// 首载静默重载预算已用尽（已经静默重试过一次、仍未 loadStop、也未进入
  /// 失败）：此时必须走明确的失败出口（错误卡 + 可重试），不能继续等待（R01）。
  static bool retryBudgetExhausted({
    required bool silentRetried,
    required bool settled,
    required bool failed,
  }) => silentRetried && !settled && !failed;
}

class SessionStatusNotifier extends Notifier<Map<String, SessionStatus>> {
  @override
  Map<String, SessionStatus> build() => const {};

  void report(String deviceId, SessionStatus status) {
    if (state[deviceId] == status) return;
    state = {...state, deviceId: status};
  }

  void forget(String deviceId) {
    if (!state.containsKey(deviceId)) return;
    state = Map.of(state)..remove(deviceId);
  }
}

final sessionStatusProvider =
    NotifierProvider<SessionStatusNotifier, Map<String, SessionStatus>>(
      SessionStatusNotifier.new,
    );

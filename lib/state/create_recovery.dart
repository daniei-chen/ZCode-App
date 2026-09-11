import '../services/event_observer.dart';

/// Recovers a session the desktop created when the `createSession` receipt
/// never reached us (timeout, reconnect mid-request).
///
/// The desktop titles a new session from its first input, so a session in
/// the same workspace whose title equals the submitted text and whose
/// activity falls inside the retry window is the one we created.  Anything
/// less specific (workspace only, or title only) is refused: guessing here
/// would attach the composer to someone else's session.
abstract final class CreateRecovery {
  /// Default window: a create that took longer than this is not ours.
  static const Duration window = Duration(seconds: 60);

  static String? findCreatedSession({
    required Iterable<SessionState> sessions,
    required String workspacePath,
    required String firstInput,
    required int sinceMs,
    Set<String> knownBefore = const {},
  }) {
    final text = firstInput.trim();
    if (text.isEmpty) return null;
    final workspace = _normalizePath(workspacePath);
    SessionState? best;
    for (final session in sessions) {
      if (knownBefore.contains(session.sessionId)) continue;
      final path = _normalizePath(session.workspacePath ?? session.workspace);
      if (workspace.isNotEmpty && path.isNotEmpty && path != workspace) {
        continue;
      }
      final title = session.title?.trim() ?? '';
      if (title.isEmpty || !_titleMatches(title, text)) continue;
      final at = session.createdAt ?? session.lastActivityAt;
      if (at == null || at < sinceMs) continue;
      if (best == null ||
          (session.createdAt ?? session.lastActivityAt ?? 0) >
              (best.createdAt ?? best.lastActivityAt ?? 0)) {
        best = session;
      }
    }
    return best?.sessionId;
  }

  /// Desktop titles may be truncated; accept an exact match or a prefix of
  /// at least 12 characters so short greetings still have to match fully.
  static bool _titleMatches(String title, String text) {
    if (title == text) return true;
    if (title.length >= 12 && text.startsWith(title)) return true;
    return false;
  }

  static String _normalizePath(String? raw) {
    var p = (raw ?? '').trim().replaceAll('\\', '/');
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p.toLowerCase();
  }
}

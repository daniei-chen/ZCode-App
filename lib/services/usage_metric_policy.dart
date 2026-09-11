/// Which `usage-stats` fields may be rendered on the phone (P1-USAGE-011).
///
/// The desktop's usage payload mixes counters with identifiers and account
/// metadata.  Only numeric/boolean counters whose key is a known metric or
/// ends with a metric suffix are shown; identifier-like keys are refused even
/// when numeric, and strings are never rendered, so a sessionId, accountId,
/// path or token can not reach the screen.
abstract final class UsageMetricPolicy {
  static const Set<String> metricKeys = {
    'totaltokens',
    'inputtokens',
    'outputtokens',
    'cachedtokens',
    'tokensused',
    'tokenbudget',
    'contextused',
    'contextwindow',
    'requestcount',
    'requests',
    'messagecount',
    'messages',
    'sessioncount',
    'sessions',
    'toolcallcount',
    'toolcalls',
    'iterationcount',
    'turncount',
    'usedpercent',
    'remainingpercent',
    'quotaused',
    'quotaremaining',
    'quotatotal',
    'remaining',
    'used',
    'total',
    'count',
    'cost',
    'costusd',
    'timeusedseconds',
    'durationms',
  };

  static const List<String> metricSuffixes = [
    'tokens',
    'count',
    'percent',
    'seconds',
    'ms',
    'total',
    'used',
    'remaining',
    'budget',
    'enabled',
  ];

  static const List<String> identifierFragments = [
    'sessionid',
    'userid',
    'accountid',
    'deviceid',
    'workspaceid',
    'clientid',
    'apikey',
    'secret',
    'hash',
    'accesstoken',
    'refreshtoken',
    'path',
    'email',
    'name',
    'url',
    'uuid',
  ];

  static bool isMetricKey(String rawKey) {
    final key = rawKey.toLowerCase();
    if (key.endsWith('id') || key.endsWith('ids')) return false;
    if (identifierFragments.any(key.contains)) return false;
    if (metricKeys.contains(key)) return true;
    return metricSuffixes.any(key.endsWith);
  }

  static bool isSafeScalar(Object? value) => value is num || value is bool;

  static bool isSafeMetric(String key, Object? value) =>
      isMetricKey(key) && isSafeScalar(value);
}

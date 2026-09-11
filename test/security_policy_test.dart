import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/usage_metric_policy.dart';
import 'package:zremote/state/keepalive.dart';

Iterable<File> _dartFiles(String root) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart') || f.path.endsWith('.kt'));

void main() {
  group('UsageMetricPolicy (P1-USAGE-011)', () {
    test('numeric counters with metric keys are shown', () {
      expect(UsageMetricPolicy.isSafeMetric('totalTokens', 1200), isTrue);
      expect(UsageMetricPolicy.isSafeMetric('requestCount', 3), isTrue);
      expect(UsageMetricPolicy.isSafeMetric('usedPercent', 42.5), isTrue);
      expect(UsageMetricPolicy.isSafeMetric('sessionCount', 7), isTrue);
      expect(UsageMetricPolicy.isSafeMetric('cacheEnabled', true), isTrue);
    });

    test('identifiers are refused even when the key mentions a metric', () {
      expect(UsageMetricPolicy.isSafeMetric('sessionId', 'sess_1'), isFalse);
      expect(UsageMetricPolicy.isSafeMetric('sessionId', 12345), isFalse);
      expect(UsageMetricPolicy.isSafeMetric('accountId', 9), isFalse);
      expect(UsageMetricPolicy.isSafeMetric('workspacePath', '/x'), isFalse);
      expect(UsageMetricPolicy.isSafeMetric('userName', 'a'), isFalse);
      expect(UsageMetricPolicy.isSafeMetric('requestIds', 3), isFalse);
      expect(UsageMetricPolicy.isSafeMetric('tokenHash', 1), isFalse);
    });

    test('strings are never rendered, whatever the key', () {
      expect(UsageMetricPolicy.isSafeMetric('totalTokens', '1200'), isFalse);
      expect(UsageMetricPolicy.isSafeMetric('usage', 'short'), isFalse);
      expect(UsageMetricPolicy.isSafeMetric('count', 'a' * 79), isFalse);
    });
  });

  group('background policy (P1-NOTIFY-014)', () {
    test('persistent connection mode is off unless the user enabled it', () {
      expect(KeepAliveEnabledNotifier().initial, isFalse);
      expect(
        keepAliveDecision(enabled: false, hasDevices: true),
        KeepAliveDecision.stop,
      );
      expect(
        keepAliveDecision(enabled: true, hasDevices: true),
        KeepAliveDecision.stop,
      );
      expect(
        keepAliveDecision(enabled: true, hasDevices: false),
        KeepAliveDecision.stop,
      );
    });
  });

  group('screenshot policy (P1-PRIVACY-013)', () {
    test('no global FLAG_SECURE anywhere in the app sources', () {
      final pattern = RegExp(r'FLAG_SECURE|setSecure\(|WINDOW_SECURE');
      final hits = <String>[];
      for (final f in [
        ..._dartFiles('lib'),
        ..._dartFiles('android/app/src'),
      ]) {
        final text = f.readAsStringSync();
        if (pattern.hasMatch(text)) hits.add(f.path);
      }
      expect(
        hits,
        isEmpty,
        reason:
            'ordinary screens must stay screenshot-able; protect '
            'secrets by redaction, not by a global secure flag',
      );
    });
  });

  group('logging policy', () {
    test('relay layer never prints raw payloads or credentials', () {
      final risky = RegExp(
        r'(debugPrint|print)\([^;]*(payload|dataBase64|passHash|args|\$body)',
      );
      final hits = <String>[];
      for (final f in _dartFiles('lib/relay')) {
        if (risky.hasMatch(f.readAsStringSync())) hits.add(f.path);
      }
      final source = File('lib/state/relay_source.dart').readAsStringSync();
      if (risky.hasMatch(source)) hits.add('lib/state/relay_source.dart');
      expect(hits, isEmpty);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:zremote/services/update_service.dart';

void main() {
  test('normalizes GitHub tags and compares release versions', () {
    expect(UpdateService.normalizeVersion('v1.6.0'), '1.6.0');
    expect(UpdateService.normalizeVersion('release-2026'), isNull);
    expect(UpdateService.compareVersions('v1.6.0', '1.5.0'), greaterThan(0));
    expect(UpdateService.compareVersions('1.5', '1.5.0'), 0);
    expect(UpdateService.compareVersions('1.4.9', '1.5.0'), lessThan(0));
  });

  test('reads the latest release from GitHub page redirect', () async {
    final client = MockClient((request) async {
      expect(request.url, UpdateService.latestReleasePage);
      return http.Response(
        '',
        302,
        headers: {
          'location':
              'https://github.com/2421873411a-rgb/ZCode-App/releases/tag/v1.0.1',
        },
      );
    });

    final result = await UpdateService.instance.checkForUpdate(
      client: client,
      currentVersion: '1.0.0',
    );

    expect(result.status, UpdateCheckStatus.updateAvailable);
    expect(result.latestVersion, '1.0.1');
    expect(
      result.releaseUri.toString(),
      'https://github.com/2421873411a-rgb/ZCode-App/releases/tag/v1.0.1',
    );
  });

  test('empty GitHub releases page is reported as no release', () async {
    final client = MockClient((_) async => http.Response('No releases', 200));
    final result = await UpdateService.instance.checkForUpdate(
      client: client,
      currentVersion: '1.0.0',
    );

    expect(result.status, UpdateCheckStatus.noRelease);
  });
}

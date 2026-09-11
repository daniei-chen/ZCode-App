import 'package:flutter_test/flutter_test.dart';

import 'package:zremote/services/update_service.dart';

void main() {
  test('normalizes GitHub tags and compares release versions', () {
    expect(UpdateService.normalizeVersion('v1.6.0'), '1.6.0');
    expect(UpdateService.normalizeVersion('release-2026'), isNull);
    expect(UpdateService.compareVersions('v1.6.0', '1.5.0'), greaterThan(0));
    expect(UpdateService.compareVersions('1.5', '1.5.0'), 0);
    expect(UpdateService.compareVersions('1.4.9', '1.5.0'), lessThan(0));
  });
}

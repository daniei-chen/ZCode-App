import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/warmup.dart';

void main() {
  test('warmup replay only contains allowlisted read-only panel requests', () {
    final script = WarmupReplay.script([
      const WarmupRequest(url: '/api/v1/usage-stats', method: 'GET'),
      const WarmupRequest(
        url: '/api/v1/plugins/install',
        method: 'POST',
        body: '{"plugin":"unsafe"}',
      ),
      const WarmupRequest(
        url: 'https://example.com/api/v1/models',
        method: 'GET',
      ),
      const WarmupRequest(url: '/api/v1/settings', method: 'GET'),
    ]);

    expect(script, contains('/api/v1/usage-stats'));
    expect(script, isNot(contains('plugins/install')));
    expect(script, isNot(contains('example.com')));
    expect(script, isNot(contains('/api/v1/settings')));
    expect(script, contains("target.origin !== location.origin"));
  });
}

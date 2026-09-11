import 'package:flutter_test/flutter_test.dart';

import 'package:zremote/models/feature_catalog.dart';

void main() {
  test('catalog covers every documented desktop service exactly once', () {
    final services = NativeFeatureCatalog.all
        .map((item) => item.service)
        .toList();
    expect(services.length, 38);
    expect(services.toSet().length, services.length);
    expect(
      NativeFeatureCatalog.byService('zcode-session')?.methods,
      contains('readSession'),
    );
    expect(
      NativeFeatureCatalog.byService('coding-plan-subscription')?.isRestricted,
      isTrue,
    );
    expect(NativeFeatureCatalog.byService('system')?.panel, 'system');
    expect(
      NativeFeatureCatalog.byService('system')?.access,
      NativeFeatureAccess.readOnly,
    );
  });

  test('catalog keeps native and read-only counts separate', () {
    expect(
      NativeFeatureCatalog.count(NativeFeatureAccess.native),
      greaterThan(0),
    );
    expect(
      NativeFeatureCatalog.count(NativeFeatureAccess.readOnly),
      greaterThan(0),
    );
    expect(
      NativeFeatureCatalog.count(NativeFeatureAccess.pending),
      greaterThan(0),
    );
    expect(
      NativeFeatureCatalog.count(NativeFeatureAccess.restricted),
      greaterThan(0),
    );
  });
}

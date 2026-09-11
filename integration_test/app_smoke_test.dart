import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zremote/main.dart';
import 'package:zremote/state/session_pool.dart';

class _DisabledBiometricNotifier extends BiometricNotifier {
  @override
  bool build() => false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app starts with the protected session tree available', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          biometricProvider.overrideWith(_DisabledBiometricNotifier.new),
        ],
        child: const ZCodeControlApp(),
      ),
    );
    await tester.pump(const Duration(seconds: 2));

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

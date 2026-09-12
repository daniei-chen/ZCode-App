import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zremote/main.dart';
import 'package:zremote/services/app_settings.dart';
import 'package:zremote/services/update_installer.dart';
import 'package:zremote/state/session_pool.dart';

class _DisabledBiometricNotifier extends BiometricNotifier {
  @override
  bool build() => false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          biometricProvider.overrideWith(_DisabledBiometricNotifier.new),
        ],
        child: const ZCodeControlApp(),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('冷启动：受保护会话树可用（通知插件初始化随应用启动完成）', (tester) async {
    await pumpApp(tester);

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('MethodChannel zremote/app 可用：系统通知开关状态可读', (tester) async {
    await pumpApp(tester);

    final enabled = await AppSettings.notificationsEnabled();
    expect(enabled, isA<bool>());
  });

  testWidgets('已安装应用的签名证书 SHA256 可读（U3 通道接通）', (tester) async {
    await pumpApp(tester);

    final signer = await UpdateInstaller.installedSignerSha256();
    expect(signer, isNotNull);
    expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(signer!), isTrue);
  });

  testWidgets('inspectApk 对损坏文件返回 null（fail-closed + 通道接通）', (tester) async {
    await pumpApp(tester);

    final dir = await Directory.systemTemp.createTemp('zcode-e2e');
    final bad = File('${dir.path}${Platform.pathSeparator}bad.apk');
    await bad.writeAsBytes([0, 1, 2, 3]);
    addTearDown(() async {
      if (await bad.exists()) await bad.delete();
      if (await dir.exists()) await dir.delete();
    });

    expect(await UpdateInstaller.inspectApk(bad.path), isNull);
  });

  testWidgets('后台 → 前台生命周期切换不崩溃', (tester) async {
    await pumpApp(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 200));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

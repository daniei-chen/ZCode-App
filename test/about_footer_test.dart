import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/ui/settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const keepaliveChannel = MethodChannel('zremote/keepalive');
  const packageInfoChannel = MethodChannel(
    'dev.fluttercommunity.plus/package_info',
  );
  const urlLauncherChannel = MethodChannel('plugins.flutter.io/url_launcher');

  testWidgets('页尾点 GitHub 地址外开仓库；通道抛错被吞不崩', (tester) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(keepaliveChannel, (call) async => false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          packageInfoChannel,
          (call) async => {
            'appName': 'ZCode',
            'packageName': 'com.zcode.app',
            'version': '1.4.0',
            'buildNumber': '7',
            'buildSignature': '',
          },
        );
    addTearDown(() {
      for (final channel in [
        keepaliveChannel,
        packageInfoChannel,
        urlLauncherChannel,
      ]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      }
    });

    tester.view.physicalSize = const Size(760, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final launches = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(urlLauncherChannel, (call) async {
          launches.add(call);
          return true;
        });

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ListView(children: [const VersionFooter()])),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final repoLink = find.text(
      'ZCode v1.4.0 · github.com/2421873411a-rgb/ZCode-App',
    );
    await tester.tap(repoLink);
    await tester.pump();

    expect(launches, hasLength(1));
    expect(launches.single.method, 'launch');
    expect(
      launches.single.arguments['url'],
      'https://github.com/2421873411a-rgb/ZCode-App',
    );
    expect(launches.single.arguments['useWebView'], isFalse);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          urlLauncherChannel,
          (call) async => throw PlatformException(code: 'no_activity'),
        );
    await tester.tap(repoLink);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(repoLink, findsOneWidget);
  });

  testWidgets('窄屏（320dp）页尾不溢出（X06 / G10-63）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(keepaliveChannel, (call) async => false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          packageInfoChannel,
          (call) async => {
            'appName': 'ZCode',
            'packageName': 'com.zcode.app',
            'version': '1.1.0',
            'buildNumber': '11',
            'buildSignature': '',
          },
        );
    addTearDown(() {
      for (final channel in [keepaliveChannel, packageInfoChannel]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      }
    });

    // 模拟器实测：这一行在 228dp 可用宽度下溢出 49px（版本号 + 仓库地址）。
    tester.view.physicalSize = const Size(320, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ListView(children: const [VersionFooter()])),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.takeException(),
      isNull,
      reason: '窄屏不得出现 RenderFlex 溢出（应折行/省略号）',
    );
    expect(find.byType(VersionFooter), findsOneWidget);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/state/back_stack.dart';
import 'package:zremote/state/session_pool.dart';
import 'package:zremote/ui/diagnostics_page.dart';
import 'package:zremote/ui/manage_page.dart';
import 'package:zremote/ui/official_remote_page.dart';
import 'package:zremote/ui/settings_page.dart';

/// 系统返回键的层级（2026-09-15 用户口径，双端区分）：
///
///   推入的页面（设置/诊断/扫码）→ 返回先弹掉它。
///     手机：停在设备列表页（一次到位）。
///     平板：设置返回先回"对话 + 列表同屏"页，再一次返回才到设备页。
///   对话页 → 返回交给官方页面（页内路由）：对话 → 对话列表（仅手机）
///   对话列表 → 返回露出设备页（页面稳定后立即返回，无重试等待）
///   平板（shortestSide ≥ 600）：对话 + 列表同屏，页内没有返回可控件——
///     返回一次直接露出设备页，页内脚本根本不跑（避免误触对话区控件）
///   设备页 → 返回退出应用
///
/// "对话页 → 对话列表"由 `lib/services/in_page_back.dart` 的脚本完成，
/// 行为断言在 `scripts/check_injected_js.mjs`（含纯图标返回键、返回顶部排除、
/// 点击后内容签名验证、令牌迟到补发、重试窗口仅页面刚加载时生效）；
/// 这里覆盖 Dart 侧的层级决策与原生页面栈的弹栈行为（WebView 插件在
/// widget 测试里无实现，因此不渲染远控页）。
class _StubDevices extends DeviceListNotifier {
  _StubDevices(this.seed);

  final List<RemoteDevice> seed;

  @override
  List<RemoteDevice> build() => seed;
}

RemoteDevice _device(String id) => RemoteDevice(
  id: id,
  baseUrl: 'https://zcode.z.ai/remote/v4',
  params: {'sid': 'sid-$id', 'hash': 'h-$id'},
  label: '设备 $id',
  createdAt: DateTime(2026, 1, 1),
);

/// 模拟 Android 系统返回键（`flutter/navigation` 的 popRoute）。
Future<void> _pressSystemBack(WidgetTester tester) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute')),
    (_) {},
  );
  // 不用 pumpAndSettle：诊断页有持续转圈的加载态，settle 永远不收敛。
  // 固定泵三帧足够让弹栈动画走完并销毁路由。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _pumpLauncher(
  WidgetTester tester, [
  VoidCallback? onSettingsReturned,
]) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        deviceListProvider.overrideWith(() => _StubDevices([_device('a')])),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // 关掉墨水扩散动画：Windows 测试引擎缺 ink_sparkle.frag 着色器，
        // 点击会抛环境异常（与代码无关）；CI 上不受影响。
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: ManagePage(onSettingsReturned: onSettingsReturned),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const keepalive = MethodChannel('zremote/keepalive');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(keepalive, (call) async => false);
  });

  group('层级决策（back_stack）', () {
    test('页面处理了 → 不再往下走（对话页 → 对话列表）', () {
      expect(
        decideSystemBack(launcherVisible: false, pageHandled: true),
        BackDecision.handledByPage,
      );
    });

    test('页面处理不了 → 露出设备页（对话列表 → 设备页）', () {
      expect(
        decideSystemBack(launcherVisible: false, pageHandled: false),
        BackDecision.revealLauncher,
      );
    });

    test('设备页已可见 → 放行系统退出应用', () {
      expect(
        decideSystemBack(launcherVisible: true, pageHandled: true),
        BackDecision.allowExit,
      );
      expect(
        decideSystemBack(launcherVisible: true, pageHandled: false),
        BackDecision.allowExit,
      );
    });
  });

  group('平板同屏布局判定（isTabletLayout）', () {
    test('最短边 ≥600dp 为平板：返回一次直接露出设备页，页内脚本不跑', () {
      expect(isTabletLayout(const Size(800, 1280)), isTrue, reason: '平板竖屏');
      expect(isTabletLayout(const Size(1280, 800)), isTrue, reason: '平板横屏');
      expect(isTabletLayout(const Size(1600, 2560)), isTrue, reason: '大平板');
    });

    test('手机正常走页内返回：对话页 → 对话列表', () {
      expect(isTabletLayout(const Size(320, 640)), isFalse);
      expect(isTabletLayout(const Size(411, 900)), isFalse);
      expect(isTabletLayout(const Size(411, 900).flipped), isFalse);
    });
  });

  group('OfficialRemotePageController 契约', () {
    test('页面报告"已处理"时，返回键不再往下走', () async {
      final controller = OfficialRemotePageController();
      controller.attach(() async => true);
      expect(await controller.handleBack(), isTrue);
      controller.attach(() async => false);
      expect(await controller.handleBack(), isFalse);
    });

    test('页面处理器抛错时按"未处理"返回，不把异常抛给返回键', () async {
      final controller = OfficialRemotePageController();
      controller.attach(() async => throw StateError('boom'));
      expect(await controller.handleBack(), isFalse);
    });

    test('未挂载处理器（页面尚未建立）时返回 false', () async {
      expect(await OfficialRemotePageController().handleBack(), isFalse);
    });
  });

  group('设置返回 = 普通弹栈，一次回到设备列表页（不经过对话页）', () {
    testWidgets('从设置返回停在设备页，外壳不会收到"回到对话页"的请求', (tester) async {
      await _pumpLauncher(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('设置'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SettingsPage), findsOneWidget);

      await _pressSystemBack(tester);

      expect(find.byType(SettingsPage), findsNothing);
      expect(find.byType(ManagePage), findsOneWidget, reason: '一次返回即回设备列表页');
      expect(tester.takeException(), isNull);
    });

    testWidgets('从设置里进诊断页：返回只回设置，再返回回设备页', (tester) async {
      await _pumpLauncher(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('诊断信息'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await _pressSystemBack(tester);
      expect(find.byType(SettingsPage), findsOneWidget, reason: '第一层返回回设置');

      await _pressSystemBack(tester);
      expect(find.byType(ManagePage), findsOneWidget, reason: '第二层返回回设备页');
      expect(
        find.byType(OfficialRemotePage),
        findsNothing,
        reason: '设置链路的返回不应把远控页带出来（2026-09-14 口径回归点）',
      );
    });
  });

  group('平板设置返回 = 回到对话/列表同屏页（2026-09-15 用户口径）', () {
    testWidgets('平板尺寸下设置返回触发 onSettingsReturned（外壳揭示远控页）', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(800, 1280);
      addTearDown(tester.view.reset);
      var calls = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            deviceListProvider.overrideWith(() => _StubDevices([_device('a')])),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(splashFactory: NoSplash.splashFactory),
            home: ManagePage(onSettingsReturned: () => calls++),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('设置'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(calls, 0, reason: '还在设置页不该触发');

      await _pressSystemBack(tester);

      expect(find.byType(SettingsPage), findsNothing);
      expect(calls, 1, reason: '平板：设置返回 = 对话/列表同屏页，再返回才是设备页');
    });

    testWidgets('手机尺寸下设置返回不触发 onSettingsReturned', (tester) async {
      // 显式设为手机尺寸：默认测试视口 800×600 的最短边恰好 600，
      // 会被 isTabletLayout 判成平板。
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(411, 900);
      addTearDown(tester.view.reset);
      var calls = 0;
      await _pumpLauncher(tester, () => calls++);
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _pressSystemBack(tester);
      expect(find.byType(SettingsPage), findsNothing);
      expect(calls, 0, reason: '手机：设置返回停在设备列表页，不揭示远控页');
    });
  });

  group('原生页面栈：返回先弹掉推入的页面', () {
    testWidgets('设备页 → 设置 → 返回回到设备页', (tester) async {
      await _pumpLauncher(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('设置'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SettingsPage), findsOneWidget);

      await _pressSystemBack(tester);

      expect(find.byType(SettingsPage), findsNothing, reason: '返回必须先关掉设置页');
      expect(find.byType(ManagePage), findsOneWidget, reason: '回到上一个页面（设备页）');
      expect(tester.takeException(), isNull);
    });

    testWidgets('设置 → 诊断：连续返回依次回到设置、再回到设备页', (tester) async {
      await _pumpLauncher(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('设置'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('诊断信息'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(DiagnosticsPage), findsOneWidget);

      await _pressSystemBack(tester);
      expect(find.byType(SettingsPage), findsOneWidget, reason: '第一层返回回到设置页');

      await _pressSystemBack(tester);
      expect(find.byType(SettingsPage), findsNothing);
      expect(find.byType(ManagePage), findsOneWidget, reason: '第二层返回回到设备页');
      expect(tester.takeException(), isNull);
    });

    testWidgets('设置页返回时不会触发远控页/启动器的额外跳转', (tester) async {
      await _pumpLauncher(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 设置页在栈顶时，返回只应该弹栈：设备页仍在下面且没有多出别的页面。
      await _pressSystemBack(tester);
      expect(find.byType(ManagePage), findsOneWidget);
      expect(find.byType(OfficialRemotePage), findsNothing);
    });
  });
}

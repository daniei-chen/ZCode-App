import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:zremote/main.dart';
import 'package:zremote/services/biometric.dart';
import 'package:zremote/state/session_pool.dart';

/// 恢复路径要写"确认标记"到安全存储：这里给 secure storage 通道一个内存
/// 替身，避免平台通道无实现时 await 悬住（R-03 测试需要真实走完写入）。
const _secureChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);
final _secureBacking = <String, String>{};

class _FakeBiometricNotifier extends BiometricNotifier {
  _FakeBiometricNotifier(this.value);

  final bool value;

  @override
  bool build() => value;
}

class _MutableBiometricNotifier extends BiometricNotifier {
  _MutableBiometricNotifier(this._value, {this.reloadSucceeds = false});

  bool _value;
  final bool reloadSucceeds;

  bool get value => _value;

  @override
  bool build() => _value;

  @override
  Future<void> set(bool value) async {
    _value = value;
    state = value;
  }

  @override
  Future<bool> reload() async => reloadSucceeds;
}

class _FakeSecurityPrefNotifier extends SecurityPrefNotifier {
  _FakeSecurityPrefNotifier(this.value);

  final bool value;

  @override
  bool build() => value;
}

class _MutableSecurityPrefNotifier extends SecurityPrefNotifier {
  _MutableSecurityPrefNotifier(this._value);

  bool _value;

  bool get value => _value;

  @override
  bool build() => _value;

  @override
  void setUnreadable(bool value) {
    _value = value;
    state = value;
  }
}

Future<void> pumpGate(
  WidgetTester tester, {
  required bool enabled,
  required Duration relockAfter,
  required Future<bool> Function(String reason) authenticate,
  BiometricNotifier Function()? notifier,
  bool prefUnreadable = false,
  SecurityPrefNotifier Function()? securityPrefNotifier,
  Future<bool> Function(String reason)? authenticateWithDeviceCredential,
  Future<void> Function()? wipeProtectedData,
  Widget child = const Text('SECRET'),
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        biometricProvider.overrideWith(
          () => notifier?.call() ?? _FakeBiometricNotifier(enabled),
        ),
        securityPrefUnreadableProvider.overrideWith(
          () =>
              securityPrefNotifier?.call() ??
              _FakeSecurityPrefNotifier(prefUnreadable),
        ),
      ],
      child: MaterialApp(
        // Windows 本地测试引擎缺 ink_sparkle.frag 着色器：点按钮的水波纹
        // 会抛环境异常（与代码无关，CI 不受影响）。关掉墨水扩散动画。
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: BiometricGate(
          relockAfter: relockAfter,
          authenticate: authenticate,
          authenticateWithDeviceCredential:
              authenticateWithDeviceCredential ?? (reason) async => false,
          // 只有显式传入才注入替身；否则交给生产默认（测试应避免走到）。
          wipeProtectedData: wipeProtectedData,
          child: child,
        ),
      ),
    ),
  );
}

Finder get visibleSecret => find.text('SECRET').hitTestable();
Finder get visibleLock => find.text('已锁定').hitTestable();

void main() {
  setUp(() {
    _secureBacking.clear();
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, (call) async {
      final args = call.arguments as Map<Object?, Object?>;
      switch (call.method) {
        case 'read':
          return _secureBacking[args['key'] as String];
        case 'readAll':
          return Map<String, String>.of(_secureBacking);
        case 'write':
          _secureBacking[args['key'] as String] = args['value'] as String;
          return null;
        case 'delete':
          _secureBacking.remove(args['key'] as String);
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, null);
  });

  testWidgets('冷启动首帧后自动验证，通过则进入内容', (tester) async {
    var calls = 0;
    await pumpGate(
      tester,
      enabled: true,
      relockAfter: const Duration(seconds: 10),
      authenticate: (reason) async {
        calls++;
        return true;
      },
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(visibleSecret, findsOneWidget);
    expect(visibleLock, findsNothing);
    expect(calls, 1);
  });

  testWidgets('验证被取消：停在锁屏，且不自动重弹', (tester) async {
    var calls = 0;
    await pumpGate(
      tester,
      enabled: true,
      relockAfter: const Duration(seconds: 10),
      authenticate: (reason) async {
        calls++;
        return false;
      },
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(seconds: 2));
    expect(visibleLock, findsOneWidget);
    expect(visibleSecret, findsNothing);
    expect(calls, 1, reason: '取消后不得循环重弹验证框');
  });

  testWidgets('短暂离开回前台免验证', (tester) async {
    var calls = 0;
    await pumpGate(
      tester,
      enabled: true,
      relockAfter: const Duration(hours: 1),
      authenticate: (reason) async {
        calls++;
        return true;
      },
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(calls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(milliseconds: 100));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(visibleSecret, findsOneWidget);
    expect(calls, 1, reason: '宽限期内不得二次验证');
  });

  testWidgets('超时离开回前台重新上锁并验证', (tester) async {
    var calls = 0;
    await pumpGate(
      tester,
      enabled: true,
      relockAfter: Duration.zero,
      authenticate: (reason) async {
        calls++;
        return true;
      },
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(calls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(calls, 2, reason: '超过宽限期应重新验证');
    expect(visibleSecret, findsOneWidget);
  });

  testWidgets('验证 UI 引起的 inactive 不算离开（防慢速验证后二次弹框）', (tester) async {
    var calls = 0;
    final gate = Completer<bool>();
    await pumpGate(
      tester,
      enabled: true,
      relockAfter: const Duration(seconds: 10),
      authenticate: (reason) async {
        calls++;
        return gate.future;
      },
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(visibleLock, findsOneWidget);
    expect(calls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(calls, 1, reason: '被自身验证 UI 盖住不算离开');

    gate.complete(true);
    await tester.pump();
    await tester.pump();
    expect(visibleSecret, findsOneWidget);
    expect(calls, 1);
  });

  testWidgets('永久不可用：保持锁定；恢复必须经系统凭据验证，绝不免验证放行', (tester) async {
    final mutable = _MutableBiometricNotifier(true);
    var deviceCredentialCalls = 0;
    await pumpGate(
      tester,
      enabled: true,
      relockAfter: const Duration(seconds: 10),
      authenticate: (reason) => throw BiometricUnavailableException(
        const LocalAuthException(
          code: LocalAuthExceptionCode.noBiometricsEnrolled,
        ),
      ),
      authenticateWithDeviceCredential: (reason) async {
        deviceCredentialCalls++;
        return true;
      },
      notifier: () => mutable,
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();

    expect(visibleSecret, findsNothing);
    expect(visibleLock, findsOneWidget);
    expect(
      find.text('确认关闭门禁'),
      findsNothing,
      reason: '免验证关闭门禁的入口必须不存在（F01）',
    );
    expect(mutable._value, isTrue);

    await tester.tap(find.text('使用系统锁屏凭据解锁'));
    await tester.pump();
    await tester.pump();
    expect(deviceCredentialCalls, 1);
    expect(visibleSecret, findsOneWidget);
    expect(mutable._value, isTrue, reason: '验证通过只解锁本次，不改写偏好');
  });

  testWidgets('恢复验证被取消：停在锁屏，不放行', (tester) async {
    final mutable = _MutableBiometricNotifier(true);
    await pumpGate(
      tester,
      enabled: true,
      relockAfter: const Duration(seconds: 10),
      authenticate: (reason) => throw BiometricUnavailableException(
        const LocalAuthException(
          code: LocalAuthExceptionCode.noBiometricsEnrolled,
        ),
      ),
      authenticateWithDeviceCredential: (reason) async => false,
      notifier: () => mutable,
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();

    await tester.tap(find.text('使用系统锁屏凭据解锁'));
    await tester.pump();
    await tester.pump();
    expect(visibleSecret, findsNothing);
    expect(visibleLock, findsOneWidget);
    expect(mutable._value, isTrue);
  });

  testWidgets('无系统凭据可用：明确告知只能清除本机数据', (tester) async {
    await pumpGate(
      tester,
      enabled: true,
      relockAfter: const Duration(seconds: 10),
      authenticate: (reason) => throw BiometricUnavailableException(
        const LocalAuthException(
          code: LocalAuthExceptionCode.noBiometricsEnrolled,
        ),
      ),
      authenticateWithDeviceCredential: (reason) =>
          throw BiometricUnavailableException(
            const LocalAuthException(
              code: LocalAuthExceptionCode.noCredentialsSet,
            ),
          ),
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();

    await tester.tap(find.text('使用系统锁屏凭据解锁'));
    await tester.pump();
    await tester.pump();
    expect(
      find.text('本机未设置可用的屏幕锁凭据，无法验证身份；只能清除本机数据后重新接入。'),
      findsOneWidget,
    );
    expect(visibleSecret, findsNothing);
  });

  testWidgets('清除本机数据：必须确认；确认后清除并关闭门禁', (tester) async {
    final mutable = _MutableBiometricNotifier(true);
    var wipeCalls = 0;
    await pumpGate(
      tester,
      enabled: true,
      relockAfter: const Duration(seconds: 10),
      authenticate: (reason) => throw BiometricUnavailableException(
        const LocalAuthException(
          code: LocalAuthExceptionCode.noBiometricsEnrolled,
        ),
      ),
      wipeProtectedData: () async => wipeCalls++,
      notifier: () => mutable,
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();

    await tester.tap(find.text('清除本机数据并关闭门禁'));
    await tester.pumpAndSettle();
    expect(wipeCalls, 0, reason: '确认之前不得删除任何数据');

    await tester.tap(find.text('清除并关闭'));
    await tester.pumpAndSettle();
    expect(wipeCalls, 1);
    expect(mutable._value, isFalse);
    expect(visibleSecret, findsOneWidget);
  });

  testWidgets('清除本机数据：取消后保持锁定且不删除', (tester) async {
    final mutable = _MutableBiometricNotifier(true);
    var wipeCalls = 0;
    await pumpGate(
      tester,
      enabled: true,
      relockAfter: const Duration(seconds: 10),
      authenticate: (reason) => throw BiometricUnavailableException(
        const LocalAuthException(
          code: LocalAuthExceptionCode.noBiometricsEnrolled,
        ),
      ),
      wipeProtectedData: () async => wipeCalls++,
      notifier: () => mutable,
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();

    await tester.tap(find.text('清除本机数据并关闭门禁'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(wipeCalls, 0);
    expect(visibleSecret, findsNothing);
    expect(mutable._value, isTrue);
  });

  testWidgets('安全偏好读取失败：保持锁定；重试成功后回到正常解锁', (tester) async {
    final mutable = _MutableBiometricNotifier(true, reloadSucceeds: true);
    final securityPref = _MutableSecurityPrefNotifier(true);
    await pumpGate(
      tester,
      enabled: true,
      relockAfter: const Duration(seconds: 10),
      authenticate: (reason) async => true,
      securityPrefNotifier: () => securityPref,
      notifier: () => mutable,
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();

    expect(visibleSecret, findsNothing, reason: '读不到安全偏好时必须 fail-closed');
    expect(
      find.text('安全设置读取失败，已保持锁定以避免暴露数据。恢复系统存储后点击重试。'),
      findsOneWidget,
    );

    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();
    expect(securityPref.value, isFalse);
    expect(
      find.text('安全设置读取失败，已保持锁定以避免暴露数据。恢复系统存储后点击重试。'),
      findsNothing,
    );
  });

  testWidgets('读取失败时锁屏必须有恢复出口；验证身份后关闭门禁并进入（R-03）', (tester) async {
    final mutable = _MutableBiometricNotifier(true);
    final securityPref = _MutableSecurityPrefNotifier(true);
    var verifyCalls = 0;
    await pumpGate(
      tester,
      enabled: true,
      relockAfter: const Duration(seconds: 10),
      authenticate: (reason) async => true,
      authenticateWithDeviceCredential: (reason) async {
        verifyCalls++;
        return true;
      },
      securityPrefNotifier: () => securityPref,
      notifier: () => mutable,
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();

    // 死锁场景：重试永远失败 → 必须有出路，而不是永久锁死。
    expect(visibleSecret, findsNothing);
    expect(find.text('验证身份并关闭指纹锁'), findsOneWidget);

    await tester.tap(find.text('验证身份并关闭指纹锁'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // R-02：确认是锁屏内联面板（不是 dialog route），生产拓扑下也能用。
    expect(find.text('验证身份并关闭指纹锁？'), findsOneWidget, reason: '破坏性操作需二次确认');

    await tester.tap(find.text('验证并关闭'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(verifyCalls, 1, reason: '必须先经过系统凭据验证身份（R-03）');
    expect(securityPref.value, isFalse, reason: '确认后解除"读取失败"状态');
    expect(mutable.value, isFalse, reason: '指纹锁被明确关闭（写回 prefs）');
    expect(visibleSecret, findsOneWidget, reason: '用户得以进入应用');
  });

  testWidgets('恢复出口可取消：取消后保持锁定', (tester) async {
    final securityPref = _MutableSecurityPrefNotifier(true);
    var verifyCalls = 0;
    await pumpGate(
      tester,
      enabled: true,
      relockAfter: const Duration(seconds: 10),
      authenticate: (reason) async => true,
      authenticateWithDeviceCredential: (reason) async {
        verifyCalls++;
        return true;
      },
      securityPrefNotifier: () => securityPref,
      notifier: () => _MutableBiometricNotifier(true),
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();

    await tester.tap(find.text('验证身份并关闭指纹锁'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(visibleSecret, findsNothing, reason: '取消 = 什么都不做，保持 fail-closed');
    expect(securityPref.value, isTrue);
    expect(verifyCalls, 0, reason: '取消不得触发任何身份验证或状态变更');
  });

  testWidgets('重锁遮断已 push 的路由与对话框（F02）', (tester) async {
    var calls = 0;
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          biometricProvider.overrideWith(() => _FakeBiometricNotifier(true)),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          // 与 main.dart 的接线一致：门禁在 builder 里包住整个 Navigator。
          builder: (context, child) => BiometricGate(
            relockAfter: Duration.zero,
            authenticate: (reason) async => ++calls == 1,
            child: child ?? const SizedBox.shrink(),
          ),
          home: const Text('HOME'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(find.text('HOME').hitTestable(), findsOneWidget);

    // 模拟"粘贴控制链接"这类已 push 的敏感页面。
    unawaited(
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('SENSITIVE')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('SENSITIVE').hitTestable(), findsOneWidget);

    // 后台超过重锁时间后回前台，本次验证被取消 → 应停在锁屏。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(
      find.text('SENSITIVE'),
      findsNothing,
      reason: '锁屏之上不得残留敏感路由或对话框',
    );
    expect(find.text('HOME'), findsNothing);
    expect(visibleLock, findsOneWidget);
    expect(calls, 2);
  });

  testWidgets('锁定时不构建受保护的 AppShell 子树', (tester) async {
    var builds = 0;
    await pumpGate(
      tester,
      enabled: true,
      relockAfter: const Duration(seconds: 10),
      authenticate: (reason) async => false,
      child: Builder(
        builder: (context) {
          builds++;
          return const Text('SECRET');
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(builds, 0);
    expect(visibleSecret, findsNothing);
  });

  testWidgets('生产拓扑（builder 中的 Gate）：恢复确认不再依赖 Navigator（R-02 回归）', (tester) async {
    // 审计复现：Gate 在 MaterialApp.builder 时 Navigator.maybeOf(Gate context)
    // 为 null，旧实现用 showDialog 会抛 FlutterError（恢复按钮完全不可用）。
    // 修复后确认改为锁屏内联面板：这里用真实 ZCodeControlApp 拓扑验证
    // 点"验证身份并关闭指纹锁"不抛错且确认面板可见。
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          biometricProvider.overrideWith(() => _FakeBiometricNotifier(true)),
          securityPrefUnreadableProvider.overrideWith(
            () => _FakeSecurityPrefNotifier(true),
          ),
        ],
        child: const ZCodeControlApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();

    expect(find.text('已锁定'), findsOneWidget);
    final gateContext = tester.element(find.byType(BiometricGate));
    expect(
      Navigator.maybeOf(gateContext),
      isNull,
      reason: '复现前提：Gate context 上没有 Navigator',
    );

    await tester.tap(find.text('验证身份并关闭指纹锁'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.text('验证身份并关闭指纹锁？'),
      findsOneWidget,
      reason: '内联确认面板必须可见（旧实现在此抛 FlutterError）',
    );
    expect(visibleSecret, findsNothing, reason: '确认前不得放行');

    // 清除并关闭数据路径同样必须是内联面板。
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('清除本机数据并关闭门禁'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('清除本机远控数据？'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

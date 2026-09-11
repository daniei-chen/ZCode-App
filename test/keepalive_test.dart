import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/keepalive.dart';
import 'package:zremote/state/app_lifecycle.dart';
import 'package:zremote/state/keepalive.dart';
import 'package:zremote/state/session_pool.dart';

class _ScriptedChannel {
  _ScriptedChannel(this.behavior);

  final Object? Function(String method) behavior;
  final calls = <String>[];

  Future<Object?> invoke(String method) async {
    calls.add(method);
    return behavior(method);
  }
}

class _StubSwitch extends KeepAliveEnabledNotifier {
  _StubSwitch(bool initial) : super(initial: initial);

  @override
  bool build() => initial;
}

class _StubDevices extends DeviceListNotifier {
  _StubDevices(this.devices);

  final List<RemoteDevice> devices;

  @override
  List<RemoteDevice> build() => devices;
}

RemoteDevice _device(String id) => RemoteDevice(
  id: id,
  baseUrl: 'https://example.invalid',
  params: const {},
  label: 'lab',
  createdAt: DateTime(2026),
);

void main() {
  group('keepAliveDecision 策略表', () {
    test('即使开关开 + 有设备也不启动常驻服务', () {
      expect(
        keepAliveDecision(enabled: true, hasDevices: true),
        KeepAliveDecision.stop,
      );
    });

    test('无设备不启动（新装机零打扰）', () {
      expect(
        keepAliveDecision(enabled: true, hasDevices: false),
        KeepAliveDecision.stop,
      );
    });

    test('开关关闭 → 停', () {
      expect(
        keepAliveDecision(enabled: false, hasDevices: true),
        KeepAliveDecision.stop,
      );
    });

    test('全关 → 停', () {
      expect(
        keepAliveDecision(enabled: false, hasDevices: false),
        KeepAliveDecision.stop,
      );
    });
  });

  group('KeepAliveService 包装', () {
    test('start/stop 走通道且吞错', () async {
      final fail = _ScriptedChannel(
        (m) => throw PlatformException(code: 'unavailable'),
      );
      final service = KeepAliveService.forTesting(fail.invoke);
      await service.start();
      await service.stop();
      expect(fail.calls, ['start', 'stop']);
    });

    test('isRunning 直通', () async {
      final channel = _ScriptedChannel((m) => m == 'isRunning');
      final service = KeepAliveService.forTesting(channel.invoke);
      expect(await service.isRunning, isTrue);
    });

    test('isRunning 通道故障 → false（不炸主流程）', () async {
      final fail = _ScriptedChannel(
        (m) => throw PlatformException(code: 'unavailable'),
      );
      final service = KeepAliveService.forTesting(fail.invoke);
      expect(await service.isRunning, isFalse);
    });

    test('isBatteryIgnored 直通与吞错', () async {
      final ok = _ScriptedChannel((m) => m == 'isBatteryIgnored');
      expect(
        await KeepAliveService.forTesting(ok.invoke).isBatteryIgnored,
        isTrue,
      );

      final fail = _ScriptedChannel(
        (m) => throw PlatformException(code: 'unavailable'),
      );
      expect(
        await KeepAliveService.forTesting(fail.invoke).isBatteryIgnored,
        isFalse,
      );
    });

    test('requestBatteryExemption 走通道且吞错', () async {
      final fail = _ScriptedChannel(
        (m) => throw PlatformException(code: 'unavailable'),
      );
      await KeepAliveService.forTesting(fail.invoke).requestBatteryExemption();
      expect(fail.calls, ['requestBatteryIgnore']);
    });

    test('isBlocked 直通与吞错', () async {
      final ok = _ScriptedChannel((m) => m == 'isBlocked');
      expect(await KeepAliveService.forTesting(ok.invoke).isBlocked, isTrue);

      final fail = _ScriptedChannel(
        (m) => throw PlatformException(code: 'unavailable'),
      );
      expect(await KeepAliveService.forTesting(fail.invoke).isBlocked, isFalse);
    });

    test('requestVendorExemption 走通道且吞错', () async {
      final fail = _ScriptedChannel(
        (m) => throw PlatformException(code: 'unavailable'),
      );
      await KeepAliveService.forTesting(fail.invoke).requestVendorExemption();
      expect(fail.calls, ['requestVendorExemption']);
    });
  });

  group('控制器同步（真实 provider + channel mock）', () {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('zremote/keepalive');
    final log = <String>[];

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      log.clear();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        log.add(call.method);
        return call.method == 'isRunning' ? true : null;
      });
    });

    tearDown(() {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    Future<void> drain() =>
        Future<void>.delayed(const Duration(milliseconds: 20));

    ProviderContainer container({
      bool enabled = true,
      bool hasDevices = true,
    }) => ProviderContainer(
      overrides: [
        keepAliveEnabledProvider.overrideWith(() => _StubSwitch(enabled)),
        deviceListProvider.overrideWith(
          () => _StubDevices(hasDevices ? [_device('d1')] : const []),
        ),
      ],
    );

    test('开关开 + 有设备：激活也只停止服务', () async {
      final c = container();
      addTearDown(c.dispose);
      c.read(keepAliveControllerProvider);
      await drain();
      expect(log, contains('stop'));
      expect(log, isNot(contains('start')));
    });

    test('快速关→开：不会重新启动常驻服务', () async {
      final c = container();
      addTearDown(c.dispose);
      c.read(keepAliveControllerProvider);
      await drain();
      log.clear();
      await c.read(keepAliveEnabledProvider.notifier).set(false);
      await c.read(keepAliveEnabledProvider.notifier).set(true);
      await drain();
      expect(log, isNot(contains('start')));
      expect(log, isNotEmpty);
    });

    test('无设备：决策停，绝不拉起', () async {
      final c = container(hasDevices: false);
      addTearDown(c.dispose);
      c.read(keepAliveControllerProvider);
      await drain();
      expect(log, contains('stop'));
      expect(log, isNot(contains('start')));
    });

    test('关保活（main 预载初值）+ 有设备：激活即 stop，不闪 FGS', () async {
      final c = ProviderContainer(
        overrides: [
          keepAliveEnabledProvider.overrideWith(() => _StubSwitch(false)),
          deviceListProvider.overrideWith(() => _StubDevices([_device('d1')])),
        ],
      );
      addTearDown(c.dispose);
      c.read(keepAliveControllerProvider);
      await drain();
      expect(log, isNot(contains('start')));
      expect(log, contains('stop'));
    });

    test('回前台自愈：resumed 也不会拉起常驻服务', () async {
      final c = container();
      addTearDown(c.dispose);
      c.read(keepAliveControllerProvider);
      await drain();
      log.clear();
      c.read(appLifecycleProvider.notifier).set(AppLifecycleState.paused);
      await drain();
      expect(log, isEmpty);
      c.read(appLifecycleProvider.notifier).set(AppLifecycleState.resumed);
      await drain();
      expect(log, contains('stop'));
      expect(log, isNot(contains('start')));
    });
  });

  group('冷启动初始注入（main 预载）', () {
    test('initial=false 首读即持久值——关保活用户不闪 FGS', () async {
      SharedPreferences.setMockInitialValues({'zremote.keepalive': false});
      final c = ProviderContainer(
        overrides: [
          keepAliveEnabledProvider.overrideWith(
            () => KeepAliveEnabledNotifier(initial: false),
          ),
        ],
      );
      addTearDown(c.dispose);
      expect(c.read(keepAliveEnabledProvider), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(keepAliveEnabledProvider), isFalse);
    });
  });
}

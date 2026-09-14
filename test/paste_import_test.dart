import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/state/session_pool.dart';
import 'package:zremote/ui/manage_page.dart';

class _FakeDeviceListNotifier extends DeviceListNotifier {
  _FakeDeviceListNotifier(this.initial);

  final List<RemoteDevice> initial;

  @override
  List<RemoteDevice> build() => initial;

  @override
  Future<void> add(RemoteDevice device) async {
    state = [...state, device];
  }
}

RemoteDevice _device(String sid) => RemoteDevice(
  id: 'id-$sid',
  baseUrl: 'https://zcode.z.ai/remote/v4',
  params: {'sid': sid, 'hash': 'h'},
  label: '设备$sid',
  createdAt: DateTime(2026, 1, 1),
);

Future<void> _pumpManage(WidgetTester tester, List<RemoteDevice> devices) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        deviceListProvider.overrideWith(() => _FakeDeviceListNotifier(devices)),
      ],
      child: MaterialApp(
        // 点击类用例不依赖水波纹：本机测试环境缺 shaders/ink_sparkle.frag，
        // 用默认 theme 会抛 "Asset not found"（环境限制，与本用例无关）。
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ManagePage(),
      ),
    ),
  );
}

void main() {
  testWidgets('非法链接（解析失败）不炸元素树：snackbar 提示导入失败', (tester) async {
    final devices = [_device('testdup831')];
    await _pumpManage(tester, devices);
    await tester.pumpAndSettle();

    await tester.tap(find.text('链接'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'not-a-url');
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect(find.textContaining('导入失败'), findsOneWidget);
  });

  testWidgets('导入去重命中：同一链接第二次导入不新增条目', (tester) async {
    final devices = [_device('testdup831')];
    await _pumpManage(tester, devices);
    await tester.pumpAndSettle();

    const dupUrl = 'https://zcode.z.ai/remote/v4?sid=testdup831&hash=fake123';

    await tester.tap(find.text('链接'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), dupUrl);
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(find.text('设备testdup831'), findsOneWidget);
    expect(find.textContaining('已导入过'), findsOneWidget);
  });
}

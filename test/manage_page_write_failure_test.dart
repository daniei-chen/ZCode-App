import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/device_store.dart';
import 'package:zremote/state/session_pool.dart';
import 'package:zremote/ui/manage_page.dart';

/// W-018a（iter7 R-1/R-3 遗留）：manage_page 写失败路径的用户可见反馈。
/// 底层 notifier 抛异常时，UI 必须：弹"操作失败"提示 + 设备列表保持原状，
/// 不得假成功。
class _ThrowingDeviceListNotifier extends DeviceListNotifier {
  _ThrowingDeviceListNotifier(this.initial);

  final List<RemoteDevice> initial;

  @override
  List<RemoteDevice> build() => initial;

  @override
  Future<void> rename(String id, String label) async {
    throw const DeviceStoreUnavailableException('rename failed');
  }

  @override
  Future<void> remove(String id) async {
    throw const DeviceStoreUnavailableException('remove failed');
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
        deviceListProvider.overrideWith(
          () => _ThrowingDeviceListNotifier(devices),
        ),
      ],
      child: MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ManagePage(),
      ),
    ),
  );
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_horiz));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('改名写失败：弹"操作失败"，名字不变', (tester) async {
    await _pumpManage(tester, [_device('wfail01')]);
    await tester.pumpAndSettle();

    await _openMenu(tester);
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '不该生效的名字');
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('操作失败，请重试'), findsOneWidget);
    expect(find.text('不该生效的名字'), findsNothing);
    expect(find.text('设备wfail01'), findsOneWidget);
  });

  testWidgets('删除写失败：弹"操作失败"，设备仍在列表', (tester) async {
    await _pumpManage(tester, [_device('wfail02')]);
    await tester.pumpAndSettle();

    await _openMenu(tester);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    // 确认对话框：点击"删除"确认按钮（FilledButton）。
    await tester.tap(find.widgetWithText(FilledButton, '删除').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('操作失败，请重试'), findsOneWidget);
    expect(find.text('设备wfail02'), findsOneWidget);
  });
}

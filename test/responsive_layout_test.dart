import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/state/session_pool.dart';
import 'package:zremote/state/startup_target.dart';
import 'package:zremote/state/theme_mode.dart';
import 'package:zremote/ui/manage_page.dart';
import 'package:zremote/ui/section_label.dart';
import 'package:zremote/ui/settings_page.dart';

/// 布局与无障碍回归（PR22 / F25）。
///
/// 覆盖矩阵：字体缩放 100% / 130% / 200% × 最窄手机 320dp / 常规手机 411dp /
/// 平板竖屏 800dp / 横屏 1280×800。任何 RenderFlex 溢出都会以异常形式让用例失败，
/// 因此这里不单独断言像素，而是断言"元素树没有抛错 + 关键控件仍可达"。
class _StubDevices extends DeviceListNotifier {
  _StubDevices(this.seed);

  final List<RemoteDevice> seed;

  @override
  List<RemoteDevice> build() => seed;
}

RemoteDevice _device(String id, String label) => RemoteDevice(
  id: id,
  baseUrl: 'https://zcode.z.ai/remote/v4',
  params: {'sid': 'sid-$id', 'hash': 'h-$id'},
  label: label,
  createdAt: DateTime(2026, 1, 1),
);

const _longLabel = '家里的 Windows 台式机（长名字用于验证窄屏与大字体会换行而不是溢出）';

final _devices = [
  _device('a', _longLabel),
  _device('b', 'DESKTOP-ABC123'),
];

Future<void> _pumpFrame(
  WidgetTester tester, {
  required Size size,
  required double textScale,
  required Widget Function() build,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, content) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: content ?? const SizedBox.shrink(),
      ),
      home: build(),
    ),
  );
  // 设置页里有持续动画（加载态转圈），不能等 pumpAndSettle 收敛。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  final sizes = <String, Size>{
    '最窄手机 320dp': const Size(320, 640),
    '常规手机 411dp': const Size(411, 891),
    '平板竖屏 800dp': const Size(800, 1280),
    '横屏 1280x800': const Size(1280, 800),
  };

  for (final scale in const [1.0, 1.3, 2.0]) {
    for (final entry in sizes.entries) {
      final label = '${(scale * 100).round()}%';

      testWidgets('设备中心：${entry.key} × $label 无溢出', (tester) async {
        await _pumpFrame(
          tester,
          size: entry.value,
          textScale: scale,
          build: () => ProviderScope(
            overrides: [
              deviceListProvider.overrideWith(() => _StubDevices(_devices)),
            ],
            child: const ManagePage(),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.byType(ManagePage), findsOneWidget);
      });

      testWidgets('设置页：${entry.key} × $label 无溢出', (tester) async {
        await _pumpFrame(
          tester,
          size: entry.value,
          textScale: scale,
          build: () => ProviderScope(
            overrides: [
              startupTargetProvider.overrideWith(
                () => StartupTargetNotifier(initial: 'launcher'),
              ),
              themeModeProvider.overrideWith(ThemeModeNotifier.new),
              deviceListProvider.overrideWith(() => _StubDevices(_devices)),
            ],
            child: const SettingsPage(embedded: true),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('生物识别门禁'), findsOneWidget);
      });
    }
  }

  testWidgets('设备卡片在 200% 字体下不裁切标签（换行而非溢出）', (tester) async {
    await _pumpFrame(
      tester,
      size: const Size(320, 640),
      textScale: 2.0,
      build: () => ProviderScope(
        overrides: [
          deviceListProvider.overrideWith(() => _StubDevices(_devices)),
        ],
        child: const ManagePage(),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('家里的 Windows 台式机'), findsWidgets);
  });

  testWidgets('横屏下设置页仍可滚动到底部（内容不被裁掉）', (tester) async {
    await _pumpFrame(
      tester,
      size: const Size(1280, 800),
      textScale: 1.0,
      build: () => ProviderScope(
        overrides: [
          startupTargetProvider.overrideWith(
            () => StartupTargetNotifier(initial: 'launcher'),
          ),
          themeModeProvider.overrideWith(ThemeModeNotifier.new),
        ],
        child: const SettingsPage(embedded: true),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.byType(SectionLabel).last,
      200,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 40,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('图标按钮带无障碍标签（TalkBack 可读）', (tester) async {
    await _pumpFrame(
      tester,
      size: const Size(411, 891),
      textScale: 1.3,
      build: () => ProviderScope(
        overrides: [
          startupTargetProvider.overrideWith(
            () => StartupTargetNotifier(initial: 'launcher'),
          ),
          themeModeProvider.overrideWith(ThemeModeNotifier.new),
        ],
        child: const SettingsPage(),
      ),
    );
    expect(tester.takeException(), isNull);
    // 返回键是纯图标按钮：必须有可朗读标签（tooltip / semanticLabel）。
    expect(find.byTooltip('返回'), findsOneWidget);
  });

  testWidgets('开关类控件带可读标题（读屏能读出"生物识别门禁"状态）', (tester) async {
    await _pumpFrame(
      tester,
      size: const Size(411, 891),
      textScale: 1.0,
      build: () => ProviderScope(
        overrides: [
          startupTargetProvider.overrideWith(
            () => StartupTargetNotifier(initial: 'launcher'),
          ),
          themeModeProvider.overrideWith(ThemeModeNotifier.new),
        ],
        child: const SettingsPage(embedded: true),
      ),
    );
    final tile = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '生物识别门禁'),
    );
    expect(tile.value, isFalse, reason: '默认关闭');
    final semantics = tester.ensureSemantics();
    expect(
      // SwitchListTile 会把标题与副标题合并进同一个语义节点，
      // 这里用包含匹配（读屏会整段朗读）。
      find.bySemanticsLabel(RegExp('生物识别门禁')),
      findsWidgets,
      reason: '开关标题必须进入语义树（TalkBack 能读出状态）',
    );
    semantics.dispose();
  });

  group('弹窗可滚动（200% 字体下按钮不被挤出屏幕）', () {
    test('信息/确认类 AlertDialog 必须声明 scrollable', () {
      final sources = {
        'lib/main.dart': File('lib/main.dart').readAsStringSync(),
        'lib/ui/manage_page.dart': File(
          'lib/ui/manage_page.dart',
        ).readAsStringSync(),
        'lib/ui/settings_page.dart': File(
          'lib/ui/settings_page.dart',
        ).readAsStringSync(),
      };
      final offenders = <String>[];
      final summary = <String>[];
      for (final entry in sources.entries) {
        final text = entry.value;
        var index = text.indexOf('AlertDialog(');
        while (index >= 0) {
          // 取这一段 AlertDialog 的构造范围（到下一个 AlertDialog 或 1200 字符）。
          final next = text.indexOf('AlertDialog(', index + 12);
          final end = next < 0 ? text.length : next;
          final block = text.substring(index, end);
          final hasTextField = block.contains('TextField(');
          final scrollable = block.contains('scrollable: true');
          final line = text.substring(0, index).split('\n').length;
          if (!hasTextField && !scrollable) {
            offenders.add('${entry.key}:$line');
          }
          summary.add(
            '${entry.key}:$line${scrollable ? '(ok)' : hasTextField ? '(field)' : ''}',
          );
          index = next;
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: '这些弹窗没有 scrollable: true 也没有输入框，200% 字体下内容会被裁掉：$offenders',
      );
      expect(summary.length, greaterThanOrEqualTo(4), reason: '至少覆盖 4 个弹窗');
    });
  });
}

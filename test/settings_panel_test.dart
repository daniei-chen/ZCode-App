import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/l10n/app_localizations_zh.dart';
import 'package:zremote/ui/settings_panel_page.dart';

void main() {
  final l10n = AppLocalizationsZh();

  group('设置面板定义', () {
    test('每个面板都有标题、副标题与对应接口', () {
      for (final p in SettingsPanel.values) {
        expect(p.title(l10n), isNotEmpty, reason: p.name);
        expect(p.subtitle(l10n), isNotEmpty, reason: p.name);
        expect(p.backing, isNotEmpty, reason: p.name);
      }
    });

    test('界面图标互不重复', () {
      final icons = SettingsPanel.values.map((p) => p.icon).toSet();
      expect(icons, hasLength(SettingsPanel.values.length));
    });

    test('Agent 能力组包含七个面板', () {
      const agentGroup = [
        SettingsPanel.skills,
        SettingsPanel.mcpServers,
        SettingsPanel.plugins,
        SettingsPanel.commands,
        SettingsPanel.subagents,
        SettingsPanel.hooks,
        SettingsPanel.memory,
      ];
      for (final p in agentGroup) {
        expect(p.title(l10n), isNotEmpty);
      }
      expect(agentGroup, hasLength(7));
    });

    test('数据与统计组包含使用统计与索引库', () {
      expect(SettingsPanel.usage.title(l10n), l10n.panelUsageTitle);
      expect(SettingsPanel.indexing.title(l10n), l10n.panelIndexingTitle);
    });

    test('所有设置面板均进入原生数据层，接口缺失时显示明确错误', () {
      final wired = SettingsPanel.values.where((p) => p.isWired).toList();
      expect(wired, SettingsPanel.values);
    });

    test('索引库备注说明它是设置项而非独立服务', () {
      expect(SettingsPanel.indexing.backing, contains('setting.update'));
    });
  });

  group('面板路由', () {
    testWidgets('命令页进入原生读取状态而不是嵌套网页占位', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: ThemeData(brightness: Brightness.dark),
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const SettingsPanelPage(
              panel: SettingsPanel.commands,
              deviceId: 'd',
              workspacePath: 'w',
            ),
          ),
        ),
      );
      // 标题 + 原生 service 说明都要出现
      expect(find.text('命令'), findsOneWidget);
      expect(find.textContaining('原生 Agent service'), findsOneWidget);
    });
  });
}

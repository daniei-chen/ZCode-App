import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/native/bootstrap/native_bootstrap_state.dart';
import 'package:zremote/state/agent_capabilities.dart';
import 'package:zremote/state/panel_state.dart';
import 'package:zremote/state/relay_source.dart';
import 'package:zremote/state/session_pool.dart';
import 'package:zremote/ui/agent_usage_page.dart';
import 'package:zremote/ui/panels/usage_panel.dart';
import 'package:zremote/ui/panels_page.dart';
import 'package:zremote/ui/settings_panel_page.dart';

RemoteDevice relayDevice({String id = 'dev-1'}) => RemoteDevice(
  id: id,
  baseUrl: 'https://zcode.z.ai/remote/v4',
  params: const {
    'sid': 'd_EXAMPLE000000000000000',
    'hash': '/EXAMPLE+EXAMPLE/EXAMPLE=',
    'mid': '00000000-0000-4000-8000-000000000000',
    'name': 'DESKTOP',
    'app_version': '3.11.2',
  },
  label: 'PC',
  createdAt: DateTime(2026, 9, 11),
);

class _RelayStub extends RelaySourceNotifier {
  _RelayStub(this.states);

  final Map<String, RelaySourceState> states;

  @override
  Map<String, RelaySourceState> build() => states;
}

class _PanelsStub extends PanelDataNotifier {
  _PanelsStub(this.snapshot);

  final PanelSnapshot snapshot;

  @override
  Map<String, PanelSnapshot> build() => {'legacy-device': snapshot};
}

void main() {
  group('PanelsPage.nativeScope (P0-WORKBENCH-008 isolation)', () {
    test('prefers the device whose agent is ready with a workspace', () {
      final devices = [relayDevice(id: 'a'), relayDevice(id: 'b')];
      final relay = {
        'a': const RelaySourceState(
          kind: RelaySourceKind.live,
          agentPhase: AgentPhase.ready,
        ),
        'b': const RelaySourceState(
          kind: RelaySourceKind.live,
          agentPhase: AgentPhase.ready,
          workspaceKey: '/w',
          lastSyncAt: 1,
        ),
      };
      final scope = PanelsPage.nativeScope(devices, relay);
      expect(scope, isNotNull);
      expect(scope!.deviceId, 'b');
      expect(scope.ready, isTrue);
    });

    test('falls back to the first relay-capable device before readiness', () {
      final devices = [relayDevice(id: 'a')];
      final scope = PanelsPage.nativeScope(devices, const {});
      expect(scope, isNotNull);
      expect(scope!.deviceId, 'a');
      expect(scope.ready, isFalse);
      expect(scope.statusLabel, '正在连接桌面端');
    });

    test('honors the active device instead of mixing relay devices', () {
      final devices = [relayDevice(id: 'a'), relayDevice(id: 'b')];
      final relay = {
        'a': const RelaySourceState(
          kind: RelaySourceKind.live,
          agentPhase: AgentPhase.ready,
          workspaceKey: '/a',
          lastSyncAt: 1,
        ),
        'b': const RelaySourceState(
          kind: RelaySourceKind.live,
          agentPhase: AgentPhase.ready,
          workspaceKey: '/b',
          lastSyncAt: 2,
        ),
      };
      final scope = PanelsPage.nativeScope(
        devices,
        relay,
        preferredDeviceId: 'a',
      );
      expect(scope, isNotNull);
      expect(scope!.deviceId, 'a');
      expect(scope.workspacePath, '/a');
    });

    test('null when no relay-capable device exists (WebView legacy)', () {
      expect(PanelsPage.nativeScope(const [], const {}), isNull);
    });
  });

  group('workbench routing (S08–S11)', () {
    test(
      'output styles is a native capability with a verified read method',
      () {
        expect(SettingsPanel.outputStyles.isWired, isTrue);
        expect(SettingsPanel.outputStyles.backing, 'output-style.listStyles');
        expect(AgentCapability.outputStyles.key, 'outputStyles');
      },
    );

    testWidgets('relay device: usage card opens the native usage page, '
        'subtitle shows layered status and no remote-page hint', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            deviceListProvider.overrideWith(() => _Devices([relayDevice()])),
            relaySourceProvider.overrideWith(
              () => _RelayStub(const {
                'dev-1': RelaySourceState(
                  kind: RelaySourceKind.live,
                  agentPhase: AgentPhase.ready,
                  workspaceKey: '/w',
                  lastSyncAt: 1,
                  connectionEpoch: 1,
                ),
              }),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData(brightness: Brightness.dark),
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const PanelsPage(),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('可以开始新对话'), findsOneWidget);
      expect(find.textContaining('远控页'), findsNothing);

      await tester.tap(find.text('使用统计'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(AgentUsagePage), findsOneWidget);
      expect(find.byType(UsagePanelPage), findsNothing);
      // Never nests a web view for relay devices.
      expect(find.textContaining('远控页'), findsNothing);
    });

    testWidgets('WebView-only legacy device still gets the passive fallback', (
      tester,
    ) async {
      final legacy = RemoteDevice(
        id: 'legacy-device',
        baseUrl: 'https://zcode.z.ai/remote/v3',
        params: const {'foo': 'bar'},
        label: '旧设备',
        createdAt: DateTime(2026, 9, 11),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            deviceListProvider.overrideWith(() => _Devices([legacy])),
            panelDataProvider.overrideWith(
              () => _PanelsStub(
                const PanelSnapshot(updatedAt: 1789000000000, providers: []),
              ),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData(brightness: Brightness.dark),
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const PanelsPage(),
          ),
        ),
      );
      await tester.pump();
      // No relay device: the passive snapshot's sync time is shown, and the
      // copy never points at the remote web page any more.
      expect(find.textContaining('已同步'), findsOneWidget);
      expect(find.textContaining('远控页'), findsNothing);
    });
  });
}

class _Devices extends DeviceListNotifier {
  _Devices(this.list);

  final List<RemoteDevice> list;

  @override
  List<RemoteDevice> build() => list;
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/l10n/app_localizations.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/event_observer.dart';
import 'package:zremote/state/create_recovery.dart';
import 'package:zremote/state/session_index.dart';
import 'package:zremote/state/session_pool.dart';
import 'package:zremote/ui/conversation_page.dart';
import 'package:zremote/ui/native_device_view.dart';

RemoteDevice _device() => RemoteDevice(
  id: 'dev-1',
  baseUrl: 'https://example.invalid/remote/v4',
  params: const {},
  label: 'Fixture PC',
  createdAt: DateTime(2026, 9, 11),
);

Widget _app(Widget home) => ProviderScope(
  child: MaterialApp(
    theme: ThemeData(brightness: Brightness.dark),
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  ),
);

void main() {
  group('NativeDeviceView is the unified shell (P1-IA-009)', () {
    testWidgets('first screen is ConversationPage in draft mode', (
      tester,
    ) async {
      await tester.pumpWidget(_app(NativeDeviceView(device: _device())));
      await tester.pump();

      expect(find.byType(ConversationPage), findsOneWidget);
      // Draft title in the app bar, composer present, no "开始对话" button
      // and no oversized welcome artwork.
      expect(find.text('新对话'), findsWidgets);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('开始对话'), findsNothing);
      expect(find.byIcon(Icons.forum_outlined), findsNothing);
    });

    testWidgets('draft composer is disabled with a layer-specific hint', (
      tester,
    ) async {
      await tester.pumpWidget(_app(NativeDeviceView(device: _device())));
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.enabled, isFalse);
      // No workspace is known yet, so the hint must say so instead of the
      // old blanket "原生通道已连接".
      expect(field.decoration?.hintText, '原生通道连接后才能创建新对话');
      expect(find.text('原生通道已连接'), findsNothing);
    });

    testWidgets('opening the drawer and tapping "new" keeps one route', (
      tester,
    ) async {
      await tester.pumpWidget(_app(NativeDeviceView(device: _device())));
      await tester.pump();
      final state = tester.state<ScaffoldState>(find.byType(Scaffold).first);
      state.openDrawer();
      await tester.pumpAndSettle();
      expect(find.byType(ConversationDrawer), findsOneWidget);
      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationPage), findsOneWidget);
      expect(find.byType(ConversationDrawer), findsNothing);
    });
  });

  group('CreateRecovery (P1-IA-009 lost receipt)', () {
    const ws = 'D:\\work\\proj';
    SessionState s({
      required String id,
      String? title,
      String? path = ws,
      int? createdAt,
    }) => SessionState(
      sessionId: id,
      title: title,
      workspacePath: path,
      createdAt: createdAt,
    );

    test('adopts the new session titled from the first input', () {
      final id = CreateRecovery.findCreatedSession(
        sessions: [
          s(id: 'old', title: '你好', createdAt: 1000),
          s(id: 'new', title: '你好', createdAt: 5000),
        ],
        workspacePath: 'd:/work/proj/',
        firstInput: '你好',
        sinceMs: 4000,
        knownBefore: {'old'},
      );
      expect(id, 'new');
    });

    test('refuses a session from another workspace or an old one', () {
      expect(
        CreateRecovery.findCreatedSession(
          sessions: [
            s(id: 'x', title: '你好', path: 'D:\\other', createdAt: 5000),
          ],
          workspacePath: ws,
          firstInput: '你好',
          sinceMs: 4000,
        ),
        isNull,
      );
      expect(
        CreateRecovery.findCreatedSession(
          sessions: [s(id: 'x', title: '你好', createdAt: 3000)],
          workspacePath: ws,
          firstInput: '你好',
          sinceMs: 4000,
        ),
        isNull,
      );
    });

    test('short titles must match exactly; long ones may be truncated', () {
      expect(
        CreateRecovery.findCreatedSession(
          sessions: [s(id: 'x', title: '你', createdAt: 5000)],
          workspacePath: ws,
          firstInput: '你好',
          sinceMs: 4000,
        ),
        isNull,
      );
      expect(
        CreateRecovery.findCreatedSession(
          sessions: [s(id: 'y', title: '请帮我整理一下这个仓库的文档', createdAt: 5000)],
          workspacePath: ws,
          firstInput: '请帮我整理一下这个仓库的文档结构并给出建议',
          sinceMs: 4000,
        ),
        'y',
      );
    });
  });

  group('SessionRanking (P2-HISTORY-018)', () {
    test('pinned, then attention-needed, then recency, stable tie-break', () {
      final sessions = [
        const SessionState(sessionId: 'c', lastActivityAt: 30),
        const SessionState(sessionId: 'b', lastActivityAt: 50),
        const SessionState(sessionId: 'run', phase: 'running', createdAt: 1),
        const SessionState(sessionId: 'wait', permissionCount: 1, createdAt: 2),
        const SessionState(sessionId: 'pin', pinned: true, lastActivityAt: 1),
        const SessionState(sessionId: 'a', lastActivityAt: 50),
      ]..sort(SessionRanking.compareSessions);
      expect(sessions.map((s) => s.sessionId).toList(), [
        'pin',
        'wait',
        'run',
        'a',
        'b',
        'c',
      ]);
      // Sorting twice yields the same order (stability across refreshes).
      final again = [...sessions]..sort(SessionRanking.compareSessions);
      expect(again.map((s) => s.sessionId), sessions.map((s) => s.sessionId));
    });
  });

  group('drawer hierarchy (review P1-1)', () {
    testWidgets('two devices sharing one workspace path stay separate', (
      tester,
    ) async {
      final d1 = _device();
      final d2 = RemoteDevice(
        id: 'dev-2',
        baseUrl: 'https://example.invalid/remote/v4',
        params: const {},
        label: 'Second PC',
        createdAt: DateTime(2026, 9, 11),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            deviceListProvider.overrideWith(() => _TwoDevices([d1, d2])),
            sessionIndexProvider.overrideWith(
              () => _TwoDeviceIndex(const {
                'dev-1': {
                  's1': SessionState(
                    sessionId: 's1',
                    title: 'alpha',
                    workspacePath: '/same/path',
                  ),
                },
                'dev-2': {
                  's2': SessionState(
                    sessionId: 's2',
                    title: 'beta',
                    workspacePath: '/same/path',
                  ),
                },
              }),
            ),
          ],
          child: _app(NativeDeviceView(device: d1)),
        ),
      );
      await tester.pump();
      final state = tester.state<ScaffoldState>(find.byType(Scaffold).first);
      state.openDrawer();
      await tester.pumpAndSettle();

      // The device name shows in both the section header and the item
      // subtitle; the contract under test is workspace separation below.
      expect(find.text('Second PC'), findsNWidgets(2));
      // Both sessions are listed, each under its own device section (the
      // shared '/same/path' workspace never merges them into one group —
      // 'Second PC' would be absent otherwise).
      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('beta'), findsOneWidget);
    });
  });
}

class _TwoDevices extends DeviceListNotifier {
  _TwoDevices(this.list);
  final List<RemoteDevice> list;
  @override
  List<RemoteDevice> build() => list;
}

class _TwoDeviceIndex extends SessionIndexNotifier {
  _TwoDeviceIndex(this.state0);
  final Map<String, Map<String, SessionState>> state0;
  @override
  Map<String, Map<String, SessionState>> build() => state0;
}

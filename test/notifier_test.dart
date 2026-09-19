import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/l10n/app_localizations_zh.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/app_log.dart';
import 'package:zremote/services/event_observer.dart';
import 'package:zremote/services/notifier.dart';

RemoteDevice _device(String id) => RemoteDevice(
  id: id,
  baseUrl: 'https://zcode.z.ai/remote/v4',
  params: {'sid': 's', 'hash': 'h'},
  label: '',
  createdAt: DateTime(2026, 1, 1),
);

void main() {
  group('NotificationSpec.cancellableIds', () {
    test('恰为该会话审批/追问两类通知位 id（三元稳定同款算法）', () {
      final device = _device('d1');
      final ids = NotificationSpec.cancellableIds(device, 'sess_b');

      final perm = NotificationSpec.stableId(
        device,
        const ObservedEvent(type: 'permission_request', taskId: 'sess_b'),
      );
      final elicit = NotificationSpec.stableId(
        device,
        const ObservedEvent(type: 'elicitation_request', taskId: 'sess_b'),
      );
      expect(ids, {perm, elicit});
      expect(ids, hasLength(2));
    });

    test('不同会话/不同设备的 id 不同（撤回不误伤）', () {
      final a = NotificationSpec.cancellableIds(_device('d1'), 'sess_a');
      final b = NotificationSpec.cancellableIds(_device('d1'), 'sess_b');
      final c = NotificationSpec.cancellableIds(_device('d2'), 'sess_a');
      expect(a.intersection(b), isEmpty);
      expect(a.intersection(c), isEmpty);
    });

    test('完成/失败通知不在撤回集——语义独立', () {
      final device = _device('d1');
      final ids = NotificationSpec.cancellableIds(device, 'sess_b');
      final done = NotificationSpec.stableId(
        device,
        const ObservedEvent(type: 'completed', taskId: 'sess_b'),
      );
      expect(ids.contains(done), isFalse);
    });
  });

  group('锁屏可见性', () {
    test('生物锁开启 → private（锁屏不露正文）', () {
      expect(
        lockScreenVisibility(lockEnabled: true),
        NotificationVisibility.private,
      );
    });

    test('生物锁关闭 → public（完整展示）', () {
      expect(
        lockScreenVisibility(lockEnabled: false),
        NotificationVisibility.public,
      );
    });
  });

  test('事件通知 payload carries the session deep-link when available', () {
    final spec = NotificationSpec.from(
      _device('d1'),
      const ObservedEvent(
        type: 'completed',
        taskId: 'session-42',
        summary: 'done',
      ),
    );
    expect(spec, isNotNull);
    expect(spec!.payload, 'd1|session-42');
  });

  test('legacy event without a session keeps the device-only payload', () {
    final spec = NotificationSpec.from(
      _device('d1'),
      const ObservedEvent(type: 'error'),
    );
    expect(spec!.payload, 'd1');
  });

  group('notifyFrom 异常围栏（D-20260916-15）', () {
    // NotificationSpec.from 在兜底路径取本地化文案；构造抛错曾发生在
    // notifyFrom 的 try 之外，unawaited 调用链上成为 unhandled zone error。
    test('spec 构造抛错 → future 正常完成且记 NT501，不外溢', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      AppLog.resetForTest();
      final throwing = _ThrowingOnPermBodyZh();

      // 回退即失败：修复前 NotificationSpec.from 在 try 外抛出，await 直接爆。
      await expectLater(
        NotifierService.instance.notifyFrom(
          _device('d1'),
          const ObservedEvent(type: 'permission_request'),
          l10n: throwing,
        ),
        completes,
      );
      expect(
        AppLog.snapshot().any(
          (line) => line.contains('NT501') && line.contains('reason=spec'),
        ),
        isTrue,
        reason: '构造失败必须落 notificationShowFailed，且 reason 与 show 失败可区分',
      );
    });
  });
}

/// 只有 notifPermBody 会抛的本地化桩：触发 bodyFor 的兜底分支。
class _ThrowingOnPermBodyZh extends AppLocalizationsZh {
  @override
  String get notifPermBody => throw StateError('l10n boom');
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/event_observer.dart';
import 'package:zremote/state/session_index.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  SessionState sess(
    String id, {
    String? title,
    String? phase,
    bool? sessionEnded,
    int permissionCount = 0,
    int userInputCount = 0,
    int? lastActivityAt,
    int? createdAt,
    String? workspace,
    String? workspacePath,
    bool pinned = false,
  }) => SessionState(
    sessionId: id,
    title: title,
    phase: phase,
    sessionEnded: sessionEnded,
    permissionCount: permissionCount,
    userInputCount: userInputCount,
    lastActivityAt: lastActivityAt,
    createdAt: createdAt,
    workspace: workspace,
    workspacePath: workspacePath,
    pinned: pinned,
  );

  group('SessionRanking.compareSessions（比較器鏈：running 置頂）', () {
    test('running 恆置頂：壓過更新的非 running', () {
      final runningOld = sess(
        'r1',
        phase: 'running',
        lastActivityAt: 10,
        createdAt: 10,
      );
      final doneNew = sess(
        'd1',
        phase: 'completedSuccess',
        lastActivityAt: 999,
        createdAt: 999,
      );
      expect(SessionRanking.compareSessions(runningOld, doneNew), isNegative);
      expect(SessionRanking.compareSessions(doneNew, runningOld), isPositive);
    });

    test('prewarming 不置頂（只認 running；prewarming 組是另一列表）', () {
      final prewarm = sess('p1', phase: 'prewarming', lastActivityAt: 1);
      final done = sess('d1', phase: 'completedSuccess', lastActivityAt: 999);
      expect(SessionRanking.compareSessions(prewarm, done), isPositive);
      expect(SessionRanking.compareSessions(done, prewarm), isNegative);
    });

    test('running 組內：createdAt 降序（不比 lastActivityAt）', () {
      final createdFirst = sess(
        'r_old',
        phase: 'running',
        createdAt: 100,
        lastActivityAt: 999,
      );
      final createdLater = sess(
        'r_new',
        phase: 'running',
        createdAt: 200,
        lastActivityAt: 1,
      );
      expect(
        SessionRanking.compareSessions(createdLater, createdFirst),
        isNegative,
      );
    });

    test('running 組內 createdAt 同值 → sessionId 字典序', () {
      final a = sess('sess_a', phase: 'running', createdAt: 7);
      final b = sess('sess_b', phase: 'running', createdAt: 7);
      expect(SessionRanking.compareSessions(a, b), isNegative);
      expect(SessionRanking.compareSessions(b, a), isPositive);
      expect(SessionRanking.compareSessions(a, a), isZero);
    });

    test('非 running 組：lastActivityAt 降序（Sue updated 主鍵）', () {
      final old = sess('a', phase: 'completedSuccess', lastActivityAt: 100);
      final recent = sess('b', phase: 'completedSuccess', lastActivityAt: 200);
      expect(SessionRanking.compareSessions(recent, old), isNegative);
      expect(SessionRanking.compareSessions(old, recent), isPositive);
    });

    test('非 running 組 lastActivityAt null 視為最舊', () {
      final noStamp = sess('a');
      final stamped = sess('b', phase: 'error', lastActivityAt: 1);
      expect(SessionRanking.compareSessions(stamped, noStamp), isNegative);
      expect(SessionRanking.compareSessions(noStamp, stamped), isPositive);
    });

    test('非 running 組 lastActivityAt 同值 → createdAt 降序二級（Sue tie 鏈）', () {
      final createdOld = sess('a', lastActivityAt: 7, createdAt: 100);
      final createdNew = sess('b', lastActivityAt: 7, createdAt: 200);
      expect(
        SessionRanking.compareSessions(createdNew, createdOld),
        isNegative,
      );
    });

    test('非 running 組主鍵+createdAt 全同 → sessionId 字典序兜底（保證全序）', () {
      final a = sess('sess_a', phase: 'error', lastActivityAt: 7, createdAt: 7);
      final b = sess('sess_b', phase: 'error', lastActivityAt: 7, createdAt: 7);
      expect(SessionRanking.compareSessions(a, b), isNegative);
      expect(SessionRanking.compareSessions(b, a), isPositive);
      expect(SessionRanking.compareSessions(a, a), isZero);
    });

    // Sessions waiting for approval rank with running ones, ahead of plain
    // recency, so an approval is never buried under newer idle sessions.
    // (Changed 2026-09-11 from "不置頂".)
    test('待審批與 running 同組置頂，先於純時間序', () {
      final pendingOld = sess(
        'old_pending',
        permissionCount: 3,
        lastActivityAt: 10,
      );
      final plainRecent = sess('new_plain', lastActivityAt: 20);
      expect(
        SessionRanking.compareSessions(pendingOld, plainRecent),
        isNegative,
      );
      expect(
        SessionRanking.compareSessions(plainRecent, pendingOld),
        isPositive,
      );
    });

    test('pinned 永遠最前，即使沒有活動時間', () {
      final pinned = sess('pin', pinned: true);
      final running = sess('run', phase: 'running', createdAt: 9);
      expect(SessionRanking.compareSessions(pinned, running), isNegative);
    });

    test('排序可用於 List.sort 且結果穩定（混合序全鏈）', () {
      final list = [
        sess('c', lastActivityAt: null),
        sess('b', lastActivityAt: 300),
        sess('a', lastActivityAt: 100),
        sess('d', lastActivityAt: 200),
        sess('e', lastActivityAt: 300),
        sess('r1', phase: 'running', lastActivityAt: 1, createdAt: 50),
      ]..sort(SessionRanking.compareSessions);
      expect(list.map((s) => s.sessionId).toList(), [
        'r1',
        'b',
        'e',
        'd',
        'a',
        'c',
      ]);
    });
  });

  group('RelativeTime.format（词形：刚刚/N分钟/N小时/N天，无「前」）', () {
    test('null lastActivityAt → 刚刚', () {
      expect(RelativeTime.format(null, 1000), (kind: 'now', n: 0));
    });

    test('59 秒 → 刚刚；61 秒 → 1分钟', () {
      const nowMs = 10 * 60 * 1000;
      expect(RelativeTime.format(nowMs - 59 * 1000, nowMs), (
        kind: 'now',
        n: 0,
      ));
      expect(RelativeTime.format(nowMs - 61 * 1000, nowMs), (
        kind: 'minute',
        n: 1,
      ));
    });

    test('59 分钟 → 59分钟', () {
      const nowMs = 10 * 3600 * 1000;
      expect(RelativeTime.format(nowMs - 59 * 60 * 1000, nowMs), (
        kind: 'minute',
        n: 59,
      ));
    });

    test('61 分钟 → 1小时；23 小时 → 23小时', () {
      const nowMs = 10 * 3600 * 1000;
      expect(RelativeTime.format(nowMs - 61 * 60 * 1000, nowMs), (
        kind: 'hour',
        n: 1,
      ));
      expect(RelativeTime.format(nowMs - 23 * 3600 * 1000, nowMs), (
        kind: 'hour',
        n: 23,
      ));
    });

    test('25 小时 → 1天', () {
      const nowMs = 48 * 3600 * 1000;
      expect(RelativeTime.format(nowMs - 25 * 3600 * 1000, nowMs), (
        kind: 'day',
        n: 1,
      ));
    });

    test('未来值（时钟偏移）→ 刚刚', () {
      expect(RelativeTime.format(2000, 1000), (kind: 'now', n: 0));
    });
  });
}

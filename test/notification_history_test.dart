import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/services/notification_history.dart';

NotificationHistoryEntry entry(int id) => NotificationHistoryEntry(
      id: id,
      at: DateTime.fromMillisecondsSinceEpoch(1700000000000 + id),
      deviceId: 'dev$id',
      deviceName: 'PC-$id',
      type: 'completed',
      title: '会话 $id',
      body: '任务已完成',
      payload: 'dev$id|task$id',
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    NotificationHistory.loadPrefs = SharedPreferences.getInstance;
    NotificationHistory.resetForTest();
  });

  test('记录 → 倒序读取', () async {
    await NotificationHistory.record(entry(1));
    await NotificationHistory.record(entry(2));
    final entries = await NotificationHistory.load();
    expect(entries, hasLength(2));
    expect(entries.first.id, 2, reason: '最新的在前');
    expect(entries.last.id, 1);
  });

  test('持久化：重载后可读（模拟进程重启）', () async {
    await NotificationHistory.record(entry(1));
    await NotificationHistory.record(entry(2));
    // 模拟新进程：清缓存重新从 prefs 加载。
    NotificationHistory.resetForTest();
    final entries = await NotificationHistory.load();
    expect(entries, hasLength(2));
    expect(entries.first.payload, 'dev2|task2');
  });

  test('有界：超过 200 条挤掉最旧的', () async {
    for (var i = 0; i < NotificationHistory.maxEntries + 20; i++) {
      await NotificationHistory.record(entry(i));
    }
    final entries = await NotificationHistory.load();
    expect(entries, hasLength(NotificationHistory.maxEntries));
    expect(entries.first.id, NotificationHistory.maxEntries + 19);
    expect(entries.last.id, 20, reason: '最旧的 20 条被挤出');
  });

  test('清空后为空且持久化', () async {
    await NotificationHistory.record(entry(1));
    await NotificationHistory.clear();
    expect(await NotificationHistory.load(), isEmpty);
    NotificationHistory.resetForTest();
    expect(await NotificationHistory.load(), isEmpty);
  });

  test('fromJson：坏数据返回 null 不抛异常', () {
    expect(NotificationHistoryEntry.fromJson({'at': 'not-a-number'}), isNull);
    expect(NotificationHistoryEntry.fromJson({}), isNull);
  });
}
